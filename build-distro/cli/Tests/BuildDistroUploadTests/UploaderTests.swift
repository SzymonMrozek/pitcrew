@testable import BuildDistroUpload
import Foundation
import Testing

/// A fake server: answers the API from a script and records part uploads.
final class FakeServer: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [(method: String, path: String)] = []
    private var _storedParts: Set<Int> = []
    private var failuresLeft: [Int: Int] = [:]
    let partCount: Int
    var completeAnswersIncompleteOnce: [Int] = []

    init(partCount: Int, alreadyStored: Set<Int> = [], failingParts: [Int: Int] = [:]) {
        self.partCount = partCount
        _storedParts = alreadyStored
        failuresLeft = failingParts
    }

    var requests: [(method: String, path: String)] { lock.withLock { _requests } }
    var storedParts: Set<Int> { lock.withLock { _storedParts } }
    var uploads: [String] { requests.filter { $0.method == "PUT" }.map(\.path) }

    func send(_ request: URLRequest, body: Data?) async throws -> (Data, HTTPURLResponse) {
        let path = request.url!.path
        let method = request.httpMethod ?? "GET"
        lock.withLock { _requests.append((method, path)) }

        func respond(_ status: Int, _ json: String) -> (Data, HTTPURLResponse) {
            (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }

        if method == "PUT" {
            let number = Int(path.split(separator: "/").last!)!
            let shouldFail = lock.withLock {
                guard let left = failuresLeft[number], left > 0 else { return false }
                failuresLeft[number] = left - 1
                return true
            }
            if shouldFail { return respond(500, "") }
            lock.withLock { _ = _storedParts.insert(number) }
            return respond(200, "")
        }

        switch path {
        case "/api/v1/builds":
            return respond(200, build(state: "uploading"))
        case "/api/v1/builds/7/artifacts/ipa/parts":
            let requested = (try JSONSerialization.jsonObject(with: body!) as! [String: [Int]])["part_numbers"]!
            let stored = storedParts
            let urls = requested.filter { !stored.contains($0) }.map { #""\#($0)":"https://bucket.example/part/\#($0)""# }
            return respond(200, #"{"uploaded":\#(stored.sorted()),"urls":{\#(urls.joined(separator: ","))},"part_size":4,"part_count":\#(partCount)}"#)
        case "/api/v1/builds/7/artifacts/ipa/progress":
            return respond(204, "")
        case "/api/v1/builds/7/complete":
            let missing = lock.withLock { () -> [Int] in
                if !completeAnswersIncompleteOnce.isEmpty {
                    defer { completeAnswersIncompleteOnce = [] }
                    _storedParts.subtract(completeAnswersIncompleteOnce)
                    return completeAnswersIncompleteOnce
                }
                return (1 ... partCount).filter { !_storedParts.contains($0) }
            }
            if missing.isEmpty { return respond(200, build(state: "processing")) }
            return respond(409, #"{"error":"parts are missing","kind":"ipa","missing_parts":\#(missing)}"#)
        default:
            return respond(404, #"{"error":"not found"}"#)
        }
    }

    private func build(state: String) -> String {
        #"{"id":7,"number":3,"state":"\#(state)","url":"https://builds.example/app/builds/3","artifacts":[{"kind":"ipa","size":\#(partCount * 4),"part_size":4,"part_count":\#(partCount),"uploaded":false}]}"#
    }
}

func ipaFile(parts: Int) throws -> LocalArtifact {
    let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).ipa")
    try Data(repeating: 1, count: parts * 4).write(to: url)
    return try LocalArtifact(kind: "ipa", fileURL: url)
}

func uploader(_ server: FakeServer) -> Uploader {
    let retry = RetryPolicy(attempts: 3, sleep: { _ in })
    let client = BuildDistroClient(server: URL(string: "https://builds.example")!, apiKey: "bd_test", transport: server, retry: retry)
    return Uploader(client: client, concurrency: 3, log: { _ in })
}

@Suite struct UploaderTests {
    let metadata = BuildMetadata(idempotencyKey: "run-1")

    @Test func uploadsEveryPartAndCompletes() async throws {
        let server = FakeServer(partCount: 10)
        let build = try await uploader(server).upload([try ipaFile(parts: 10)], metadata: metadata)

        #expect(build.state == "processing")
        #expect(server.storedParts == Set(1 ... 10))
    }

    @Test func resumesWithoutUploadingStoredPartsAgain() async throws {
        let server = FakeServer(partCount: 5, alreadyStored: [1, 2, 3])
        _ = try await uploader(server).upload([try ipaFile(parts: 5)], metadata: metadata)

        #expect(server.uploads.sorted() == ["/part/4", "/part/5"])
    }

    @Test func retriesAFlakyPart() async throws {
        let server = FakeServer(partCount: 3, failingParts: [2: 2])
        _ = try await uploader(server).upload([try ipaFile(parts: 3)], metadata: metadata)

        #expect(server.uploads.filter { $0 == "/part/2" }.count == 3)
    }

    @Test func aPartThatKeepsFailingIsRetriedInTheNextRound() async throws {
        let server = FakeServer(partCount: 3, failingParts: [2: 4])
        _ = try await uploader(server).upload([try ipaFile(parts: 3)], metadata: metadata)

        #expect(server.storedParts == [1, 2, 3])
    }

    @Test func reuploadsPartsTheServerReportsMissing() async throws {
        let server = FakeServer(partCount: 4)
        server.completeAnswersIncompleteOnce = [3]
        _ = try await uploader(server).upload([try ipaFile(parts: 4)], metadata: metadata)

        #expect(server.uploads.filter { $0 == "/part/3" }.count == 2)
    }

    @Test func givesUpWithTheMissingParts() async throws {
        let server = FakeServer(partCount: 2, failingParts: [1: 100])

        await #expect(throws: UploadError.incomplete(kind: "ipa", missingParts: [1])) {
            _ = try await uploader(server).upload([try ipaFile(parts: 2)], metadata: metadata)
        }
    }

    @Test func doesNotRetryARejectedKey() async throws {
        struct Unauthorized: HTTPTransport {
            func send(_ request: URLRequest, body: Data?) async throws -> (Data, HTTPURLResponse) {
                (Data(#"{"error":"invalid API key"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
            }
        }
        let client = BuildDistroClient(server: URL(string: "https://builds.example")!, apiKey: "bad", transport: Unauthorized(), retry: RetryPolicy(sleep: { _ in Issue.record("retried") }))

        await #expect(throws: UploadError.rejected(status: 401, message: #"{"error":"invalid API key"}"#)) {
            _ = try await Uploader(client: client, log: { _ in }).upload([try ipaFile(parts: 1)], metadata: metadata)
        }
    }
}
