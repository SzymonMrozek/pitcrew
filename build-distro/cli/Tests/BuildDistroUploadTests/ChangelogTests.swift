@testable import BuildDistroUpload
import Foundation
import Testing

/// A fake GitHub answering the compare and commit endpoints.
final class FakeCompare: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _paths: [String] = []
    let commitCount: Int
    let failing: Bool

    init(commitCount: Int = 3, failing: Bool = false) {
        self.commitCount = commitCount
        self.failing = failing
    }

    var paths: [String] { lock.withLock { _paths } }

    func send(_ request: URLRequest, body: Data?) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        lock.withLock { _paths.append(url.path + (url.query.map { "?" + $0 } ?? "")) }
        func respond(_ status: Int, _ object: Any) throws -> (Data, HTTPURLResponse) {
            (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        if failing { return try respond(403, ["message": "Resource not accessible by integration"]) }

        func entry(_ index: Int, parents: Int = 1) -> [String: Any] {
            [
                "sha": String(format: "%040x", index),
                "commit": ["message": "feat: change \(index)", "author": ["name": "Author \(index)"]],
                "author": ["login": "dev\(index)"],
                "parents": Array(repeating: ["sha": "p"], count: parents),
            ]
        }

        if url.path.contains("/commits/") { return try respond(200, entry(0)) }

        let page = Int(URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "page" }!.value!)!
        let range = ((page - 1) * 100) ..< min(page * 100, commitCount)
        var commits = range.map { entry($0 + 1) }
        if page == 1 { commits.insert(entry(999, parents: 2), at: 0) }
        return try respond(200, ["merge_base_commit": ["sha": String(repeating: "b", count: 40)], "total_commits": commitCount + 1, "commits": commits])
    }
}

@Suite struct ChangelogTests {
    func reporter(_ github: FakeCompare, baseRef: String? = nil) -> GitHubReporter {
        GitHubReporter(
            target: .init(apiURL: URL(string: "https://api.github.com")!, repository: "example/app", commitSHA: "head123", pullRequest: 4, baseRef: baseRef),
            token: "job-token", transport: github, retry: RetryPolicy(attempts: 1, sleep: { _ in }), log: { _ in }
        )
    }

    func build(bucket: String, previous: String? = nil) -> Build {
        Build(id: 1, number: 2, state: "uploading", bucket: bucket, mainBranch: "main", previousCommitSha: previous, url: "https://b.example/app/builds/2", artifacts: [])
    }

    @Test func aPullRequestListsWhatItAddsToItsBase() async throws {
        let github = FakeCompare()
        let changelog = try #require(await reporter(github, baseRef: "develop").changelog(for: build(bucket: "pull_requests")))

        #expect(github.paths == ["/repos/example/app/compare/develop...head123?per_page=100&page=1"])
        #expect(changelog.kind == "pull_request")
        #expect(changelog.base == String(repeating: "b", count: 40))
        #expect(changelog.commits.map(\.message) == ["feat: change 1", "feat: change 2", "feat: change 3"])
        #expect(changelog.commits.first?.author == "dev1")
        #expect(!changelog.truncated)
    }

    @Test func aMainBuildListsEverythingSinceThePreviousOne() async throws {
        let github = FakeCompare(commitCount: 12)
        let changelog = try #require(await reporter(github).changelog(for: build(bucket: "main", previous: "prev456")))

        #expect(github.paths == ["/repos/example/app/compare/prev456...head123?per_page=100&page=1"])
        #expect(changelog.kind == "main")
        #expect(changelog.commits.count == 12)
    }

    @Test func theFirstMainBuildListsItsOwnCommit() async throws {
        let github = FakeCompare()
        let changelog = try #require(await reporter(github).changelog(for: build(bucket: "main")))

        #expect(github.paths == ["/repos/example/app/commits/head123"])
        #expect(changelog.kind == "first")
        #expect(changelog.commits.count == 1)
    }

    @Test func otherBranchesCompareWithMain() async throws {
        let github = FakeCompare()
        let changelog = try #require(await reporter(github).changelog(for: build(bucket: "manual")))

        #expect(github.paths == ["/repos/example/app/compare/main...head123?per_page=100&page=1"])
        #expect(changelog.kind == "branch")
    }

    @Test func pagesThroughLongComparisons() async throws {
        let github = FakeCompare(commitCount: 150)
        let changelog = try #require(await reporter(github).changelog(for: build(bucket: "main", previous: "prev456")))

        #expect(github.paths.count == 2)
        #expect(changelog.commits.count == 150)
    }

    @Test func noChangelogWhenGitHubRefuses() async {
        #expect(await reporter(FakeCompare(failing: true)).changelog(for: build(bucket: "main", previous: "prev456")) == nil)
    }
}
