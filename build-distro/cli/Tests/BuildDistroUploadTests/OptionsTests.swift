@testable import BuildDistroUpload
import Foundation
import Testing

@Suite struct OptionsTests {
    @Test func readsPullRequestsFromTheGitHubEvent() throws {
        let event = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json")
        try Data(#"{"pull_request":{"number":42,"title":"Add widgets","head":{"sha":"abc123def4567"}}}"#.utf8).write(to: event)

        let options = try Options(arguments: ["--ipa", "App.ipa", "--wait"], environment: [
            "BUILD_DISTRO_URL": "https://builds.example",
            "BUILD_DISTRO_API_KEY": "bd_key",
            "GITHUB_ACTIONS": "true",
            "GITHUB_EVENT_PATH": event.path,
            "GITHUB_SHA": "merge-commit",
            "GITHUB_HEAD_REF": "feature/widgets",
            "GITHUB_REF_NAME": "42/merge",
            "GITHUB_RUN_ID": "1001",
            "GITHUB_RUN_ATTEMPT": "2",
            "GITHUB_JOB": "build",
            "GITHUB_SERVER_URL": "https://github.com",
            "GITHUB_REPOSITORY": "example/app",
        ])

        #expect(options.metadata == BuildMetadata(
            idempotencyKey: "github-1001-2-build",
            commitSHA: "abc123def4567",
            branch: "feature/widgets",
            pullRequest: 42,
            runURL: "https://github.com/example/app/actions/runs/1001/attempts/2",
            commitMessage: "Add widgets"
        ))
        #expect(options.wait)
    }

    @Test func flagsOverrideTheEnvironment() throws {
        let options = try Options(
            arguments: ["--server", "https://other.example", "--ipa", "A.ipa", "--branch", "main", "--idempotency-key", "k", "--pr", "7"],
            environment: ["BUILD_DISTRO_API_KEY": "bd_key", "BUILD_DISTRO_URL": "https://builds.example"]
        )

        #expect(options.server.absoluteString == "https://other.example")
        #expect(options.metadata.branch == "main")
        #expect(options.metadata.idempotencyKey == "k")
        #expect(options.metadata.pullRequest == 7)
    }

    @Test func reportsToGitHubWithTheJobToken() throws {
        let environment = [
            "BUILD_DISTRO_URL": "https://builds.example", "BUILD_DISTRO_API_KEY": "bd_key",
            "GITHUB_TOKEN": "job-token", "GITHUB_REPOSITORY": "example/app", "GITHUB_API_URL": "https://ghe.example/api/v3",
        ]
        let options = try Options(arguments: ["--ipa", "A.ipa", "--commit", "abc1234", "--pr", "5"], environment: environment)

        #expect(options.gitHub == GitHubReporter.Target(apiURL: URL(string: "https://ghe.example/api/v3")!, repository: "example/app", commitSHA: "abc1234", pullRequest: 5))
        #expect(options.gitHubToken == "job-token")

        let disabled = try Options(arguments: ["--ipa", "A.ipa", "--commit", "abc1234", "--no-github"], environment: environment)
        #expect(disabled.gitHub == nil)

        let noToken = try Options(arguments: ["--ipa", "A.ipa", "--commit", "abc1234"], environment: environment.filter { $0.key != "GITHUB_TOKEN" })
        #expect(noToken.gitHub == nil)
    }

    @Test func requiresTheEssentials() {
        #expect(throws: Options.ParseError.missing("BUILD_DISTRO_API_KEY")) {
            try Options(arguments: ["--server", "https://b.example", "--ipa", "A.ipa"], environment: [:])
        }
        #expect(throws: Options.ParseError.missing("--ipa")) {
            try Options(arguments: ["--server", "https://b.example"], environment: ["BUILD_DISTRO_API_KEY": "k"])
        }
    }
}
