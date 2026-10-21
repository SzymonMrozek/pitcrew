@testable import BuildDistroUpload
import Foundation
import Testing

/// A fake GitHub API holding one pull request's comments.
final class FakeGitHub: HTTPTransport, @unchecked Sendable {
    struct Call: Equatable {
        var method: String
        var path: String
        var body: [String: String]?
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    var comments: [(id: Int, body: String)]
    var failWith: Int?

    init(comments: [(id: Int, body: String)] = [], failWith: Int? = nil) {
        self.comments = comments
        self.failWith = failWith
    }

    var calls: [Call] { lock.withLock { _calls } }
    var writes: [Call] { calls.filter { $0.method != "GET" } }

    func send(_ request: URLRequest, body: Data?) async throws -> (Data, HTTPURLResponse) {
        let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
        let call = Call(method: request.httpMethod!, path: request.url!.path, body: json)
        lock.withLock { _calls.append(call) }
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer job-token")

        func respond(_ status: Int, _ data: Data) -> (Data, HTTPURLResponse) {
            (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }

        if let failWith { return respond(failWith, Data(#"{"message":"Resource not accessible by integration"}"#.utf8)) }
        if call.method == "GET" {
            let list = comments.map { ["id": $0.id, "body": $0.body] as [String: Any] }
            return respond(200, try JSONSerialization.data(withJSONObject: list))
        }
        return respond(call.method == "POST" ? 201 : 200, Data(#"{"id":99}"#.utf8))
    }
}

@Suite struct GitHubReporterTests {
    let build = Build(
        id: 7, number: 12, state: "ready", url: "https://builds.example/myapp/builds/12",
        failureReason: nil, displayName: "My App", version: "1.4.0", buildVersion: "412", artifacts: []
    )

    func reporter(_ github: FakeGitHub, pullRequest: Int? = 42, log: @escaping @Sendable (String) -> Void = { _ in }) -> GitHubReporter {
        GitHubReporter(
            target: .init(apiURL: URL(string: "https://api.github.com")!, repository: "example/app", commitSHA: "abc1234def", pullRequest: pullRequest),
            token: "job-token",
            transport: github,
            retry: RetryPolicy(attempts: 1, sleep: { _ in }),
            log: log
        )
    }

    @Test func marksTheCommitPendingWithoutCommentingYet() async {
        let github = FakeGitHub()
        var uploading = build
        uploading.state = "uploading"

        await reporter(github).started(uploading)

        #expect(github.writes == [.init(method: "POST", path: "/repos/example/app/statuses/abc1234def", body: [
            "state": "pending", "description": "Uploading build #12",
            "target_url": "https://builds.example/myapp/builds/12", "context": "build-distro",
        ])])
    }

    @Test func aReadyBuildSucceedsAndComments() async throws {
        let github = FakeGitHub()
        await reporter(github).finished(build)

        #expect(github.writes.map(\.method) == ["POST", "POST"])
        #expect(github.writes[0].body?["state"] == "success")
        #expect(github.writes[0].body?["description"] == "Ready to install: 1.4.0 (412)")
        let comment = try #require(github.writes[1])
        #expect(comment.path == "/repos/example/app/issues/42/comments")
        #expect(comment.body?["body"]?.contains("<!-- build-distro: https://builds.example/myapp -->") == true)
        #expect(comment.body?["body"]?.contains("**My App 1.4.0 (412)** is ready to install") == true)
    }

    @Test func laterBuildsEditTheirProjectsComment() async {
        let github = FakeGitHub(comments: [
            (1, "Looks good to me"),
            (2, "<!-- build-distro: https://builds.example/other -->\nBuild #3 is ready."),
            (3, "<!-- build-distro: https://builds.example/myapp -->\nBuild #11 is ready."),
        ])

        await reporter(github).finished(build)

        #expect(github.writes.last?.method == "PATCH")
        #expect(github.writes.last?.path == "/repos/example/app/issues/comments/3")
    }

    @Test func aStartingBuildUpdatesAnExistingComment() async {
        let github = FakeGitHub(comments: [(3, "<!-- build-distro: https://builds.example/myapp -->\nold")])
        var uploading = build
        uploading.state = "uploading"

        await reporter(github).started(uploading)

        #expect(github.writes.last?.path == "/repos/example/app/issues/comments/3")
        #expect(github.writes.last?.body?["body"]?.contains("Build #12 is uploading") == true)
    }

    @Test func pushesGetOnlyAStatus() async {
        let github = FakeGitHub()
        await reporter(github, pullRequest: nil).finished(build)

        #expect(github.calls.map(\.path) == ["/repos/example/app/statuses/abc1234def"])
    }

    @Test func missingPermissionsWarnInsteadOfFailing() async {
        let github = FakeGitHub(failWith: 403)
        let lines = LockedLines()

        await reporter(github, log: { lines.append($0) }).finished(build)

        #expect(lines.all.contains { $0.contains("statuses: write") })
    }
}

final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}
