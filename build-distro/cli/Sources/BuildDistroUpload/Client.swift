import Foundation

/// Sends one HTTP request. `URLSession` in production, a fake in tests.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest, body: Data?) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: HTTPTransport {
    public func send(_ request: URLRequest, body: Data?) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = if let body {
            try await upload(for: request, from: body)
        } else {
            try await data(for: request)
        }
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, response)
    }
}

/// Retries what's worth retrying: network failures, 5xx, 408 and 429. Every
/// call to the server is idempotent, so retrying blindly is safe.
public struct RetryPolicy: Sendable {
    public var attempts: Int
    public var baseDelay: Duration
    public var maxDelay: Duration
    public var sleep: @Sendable (Duration) async throws -> Void

    public init(
        attempts: Int = 8,
        baseDelay: Duration = .milliseconds(500),
        maxDelay: Duration = .seconds(30),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.attempts = attempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.sleep = sleep
    }

    func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        var attempt = 1
        while true {
            do {
                return try await operation()
            } catch where attempt < attempts && Self.isRetryable(error) {
                let delay = min(baseDelay * (1 << min(attempt - 1, 16)), maxDelay)
                // Jitter keeps parallel part uploads from retrying in lockstep.
                try await sleep(delay * Double.random(in: 0.5 ... 1.0))
                attempt += 1
            }
        }
    }

    static func isRetryable(_ error: any Error) -> Bool {
        switch error {
        case let HTTPStatusError.status(code, _): code >= 500 || code == 408 || code == 429
        case let error as URLError: error.code != .cancelled && error.code != .userAuthenticationRequired
        default: false
        }
    }
}

enum HTTPStatusError: Error {
    case status(Int, Data)
}

/// The build-distro API, one call per endpoint.
public struct BuildDistroClient: Sendable {
    var server: URL
    var apiKey: String
    var transport: any HTTPTransport
    var retry: RetryPolicy

    public init(server: URL, apiKey: String, transport: any HTTPTransport = URLSession.shared, retry: RetryPolicy = RetryPolicy()) {
        self.server = server
        self.apiKey = apiKey
        self.transport = transport
        self.retry = retry
    }

    func start(_ request: StartRequest) async throws -> Build {
        try await call("POST", "builds", body: request)
    }

    func build(id: Int) async throws -> Build {
        try await call("GET", "builds/\(id)", body: Optional<String>.none)
    }

    func partURLs(buildID: Int, kind: String, numbers: [Int]) async throws -> PartURLs {
        try await call("POST", "builds/\(buildID)/artifacts/\(kind)/parts", body: ["part_numbers": numbers])
    }

    /// Progress only drives the build page, so it's tried once and never fails an upload.
    func reportProgress(buildID: Int, kind: String, part: Int, size: Int) async {
        var request = request("POST", "builds/\(buildID)/artifacts/\(kind)/progress")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = try? encoder.encode(["part_number": part, "size": size])
        _ = try? await transport.send(request, body: body)
    }

    enum Completion: Equatable {
        case completed(Build)
        case incomplete(kind: String, missingParts: [Int])
    }

    func complete(buildID: Int) async throws -> Completion {
        do {
            return .completed(try await call("POST", "builds/\(buildID)/complete", body: [String: String]()))
        } catch let UploadError.rejected(409, message) {
            if let error = try? decoder.decode(ServerError.self, from: Data(message.utf8)),
               let kind = error.kind, let missing = error.missingParts {
                return .incomplete(kind: kind, missingParts: missing)
            }
            throw UploadError.rejected(status: 409, message: message)
        }
    }

    /// PUTs one part to its presigned URL. Throws `HTTPStatusError` so the caller
    /// can tell an expired URL (403) from a transient failure.
    func uploadPart(to url: URL, data: Data) async throws {
        var request = URLRequest(url: url, timeoutInterval: 300)
        request.httpMethod = "PUT"
        let (body, response) = try await transport.send(request, body: data)
        guard (200 ..< 300).contains(response.statusCode) else {
            throw HTTPStatusError.status(response.statusCode, body)
        }
    }

    private func call<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        _ method: String, _ path: String, body: Body?
    ) async throws -> Response {
        var request = request(method, path)
        let data = try body.map { try encoder.encode($0) }
        if data != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }

        do {
            let responseBody = try await retry.run { [transport, request] in
                let (responseBody, response) = try await transport.send(request, body: data)
                guard (200 ..< 300).contains(response.statusCode) else {
                    throw HTTPStatusError.status(response.statusCode, responseBody)
                }
                return responseBody
            }
            return try decoder.decode(Response.self, from: responseBody)
        } catch let HTTPStatusError.status(code, body) {
            throw UploadError.rejected(status: code, message: String(decoding: body, as: UTF8.self))
        }
    }

    private func request(_ method: String, _ path: String) -> URLRequest {
        var request = URLRequest(url: server.appending(path: "api/v1/" + path), timeoutInterval: 60)
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
