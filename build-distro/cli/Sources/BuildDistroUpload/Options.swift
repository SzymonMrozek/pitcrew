import Foundation

/// Command-line options, with defaults read from GitHub Actions' environment.
public struct Options: Equatable, Sendable {
    public var server: URL
    public var apiKey: String
    public var ipa: URL
    public var dsyms: URL?
    public var metadata: BuildMetadata
    public var concurrency = 6
    public var wait = false
    public var timeout = Duration.seconds(600)
    /// Where to report the build on GitHub, set when a token and repository are known.
    public var gitHub: GitHubReporter.Target?
    public var gitHubToken: String?

    public static let usage = """
    Usage: build-distro-upload --server URL --ipa PATH [options]

      --server URL            build-distro address, or BUILD_DISTRO_URL
      --ipa PATH              the ad hoc IPA
      --dsyms PATH            a dSYMs zip or folder (a folder is zipped)
      --api-key KEY           or BUILD_DISTRO_API_KEY (preferred: keeps it out of logs)
      --idempotency-key KEY   the same key resumes the same build; defaults to
                              the GitHub run, attempt and job
      --branch NAME --commit SHA --pr NUMBER --run-url URL
      --message TEXT --notes TEXT
                              default to what GitHub Actions knows
      --concurrency N         parallel part uploads (default 6)
      --github-token TOKEN    or GITHUB_TOKEN: sets a commit status and, for pull
                              requests, one comment that later builds update.
                              In Actions, pass the job's token; it needs
                              statuses: write and pull-requests: write
      --github-repository O/R defaults to GITHUB_REPOSITORY
      --base-ref BRANCH       the branch a pull request merges into, for its
                              changelog; defaults to the PR's base on GitHub
      --no-github             don't report to GitHub or fetch a changelog
      --wait                  wait until the build is ready; fail if it fails
      --timeout SECONDS       how long --wait waits (default 600)
    """

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case missing(String)
        case invalid(String)
        case help

        public var description: String {
            switch self {
            case let .missing(name): "Missing \(name).\n\n\(Options.usage)"
            case let .invalid(message): "\(message)\n\n\(Options.usage)"
            case .help: Options.usage
            }
        }
    }

    public init(arguments: [String], environment: [String: String]) throws {
        var values: [String: String] = [:]
        var flags: Set<String> = []
        var iterator = arguments.makeIterator()

        while let argument = iterator.next() {
            switch argument {
            case "-h", "--help": throw ParseError.help
            case "--wait", "--no-github": flags.insert(argument)
            case let name where name.hasPrefix("--"):
                guard let value = iterator.next() else { throw ParseError.invalid("\(name) needs a value") }
                values[name] = value
            default: throw ParseError.invalid("Unexpected argument \(argument)")
            }
        }

        guard let serverString = values["--server"] ?? environment["BUILD_DISTRO_URL"] else { throw ParseError.missing("--server") }
        guard let server = URL(string: serverString), server.scheme != nil else { throw ParseError.invalid("--server isn't a URL") }
        guard let apiKey = values["--api-key"] ?? environment["BUILD_DISTRO_API_KEY"], !apiKey.isEmpty else {
            throw ParseError.missing("BUILD_DISTRO_API_KEY")
        }
        guard let ipa = values["--ipa"] else { throw ParseError.missing("--ipa") }

        self.server = server
        self.apiKey = apiKey
        self.ipa = URL(fileURLWithPath: ipa)
        dsyms = values["--dsyms"].map { URL(fileURLWithPath: $0) }
        wait = flags.contains("--wait")

        if let concurrency = values["--concurrency"] {
            guard let value = Int(concurrency), value > 0 else { throw ParseError.invalid("--concurrency must be a positive number") }
            self.concurrency = value
        }
        if let timeout = values["--timeout"] {
            guard let value = Int(timeout), value > 0 else { throw ParseError.invalid("--timeout must be a positive number") }
            self.timeout = .seconds(value)
        }
        if let pr = values["--pr"], Int(pr) == nil { throw ParseError.invalid("--pr must be a number") }

        let context = GitHubContext(environment: environment)
        metadata = BuildMetadata(
            idempotencyKey: values["--idempotency-key"] ?? context.idempotencyKey ?? UUID().uuidString,
            commitSHA: values["--commit"] ?? context.commitSHA,
            branch: values["--branch"] ?? context.branch,
            pullRequest: values["--pr"].flatMap(Int.init) ?? context.pullRequest,
            runURL: values["--run-url"] ?? context.runURL,
            commitMessage: values["--message"] ?? context.message,
            releaseNotes: values["--notes"]
        )

        let token = values["--github-token"] ?? environment["GITHUB_TOKEN"]
        let repository = values["--github-repository"] ?? environment["GITHUB_REPOSITORY"]
        let apiURL = URL(string: environment["GITHUB_API_URL"] ?? "https://api.github.com")
        if !flags.contains("--no-github"), let token, !token.isEmpty, let repository, let apiURL, let commit = metadata.commitSHA {
            gitHub = GitHubReporter.Target(
                apiURL: apiURL, repository: repository, commitSHA: commit,
                pullRequest: metadata.pullRequest, baseRef: values["--base-ref"] ?? context.baseRef
            )
            gitHubToken = token
        }
    }
}

/// What GitHub Actions tells a job about the code it builds. Pull request
/// events build a merge commit, so the PR's head commit and title come from the
/// event payload instead.
struct GitHubContext {
    var idempotencyKey: String?
    var commitSHA: String?
    var branch: String?
    var pullRequest: Int?
    var runURL: String?
    var message: String?
    var baseRef: String?

    init(environment: [String: String]) {
        guard environment["GITHUB_ACTIONS"] == "true" else { return }

        let event = environment["GITHUB_EVENT_PATH"]
            .flatMap { FileManager.default.contents(atPath: $0) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let pullRequest = event?["pull_request"] as? [String: Any]
        let head = pullRequest?["head"] as? [String: Any]

        if let runID = environment["GITHUB_RUN_ID"] {
            let attempt = environment["GITHUB_RUN_ATTEMPT"] ?? "1"
            idempotencyKey = ["github", runID, attempt, environment["GITHUB_JOB"]].compactMap { $0 }.joined(separator: "-")
            if let server = environment["GITHUB_SERVER_URL"], let repository = environment["GITHUB_REPOSITORY"] {
                runURL = "\(server)/\(repository)/actions/runs/\(runID)/attempts/\(attempt)"
            }
        }

        commitSHA = head?["sha"] as? String ?? environment["GITHUB_SHA"]
        branch = (environment["GITHUB_HEAD_REF"]).flatMap { $0.isEmpty ? nil : $0 } ?? environment["GITHUB_REF_NAME"]
        self.pullRequest = pullRequest?["number"] as? Int
        baseRef = (pullRequest?["base"] as? [String: Any])?["ref"] as? String
        message = pullRequest?["title"] as? String ?? (event?["head_commit"] as? [String: Any])?["message"] as? String
    }
}
