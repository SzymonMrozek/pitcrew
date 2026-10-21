import Foundation

/// Reports the build to GitHub with the job's own token: a commit status and,
/// for pull requests, one comment that later builds edit. Nothing is stored on
/// the server; the comment is found again by a hidden marker.
///
/// Reporting never fails the upload: the build is distributed either way.
public struct GitHubReporter: Sendable {
    public struct Target: Equatable, Sendable {
        public var apiURL: URL
        public var repository: String
        public var commitSHA: String
        public var pullRequest: Int?
        /// The branch a pull request merges into.
        public var baseRef: String?

        public init(apiURL: URL, repository: String, commitSHA: String, pullRequest: Int?, baseRef: String? = nil) {
            self.apiURL = apiURL
            self.repository = repository
            self.commitSHA = commitSHA
            self.pullRequest = pullRequest
            self.baseRef = baseRef
        }
    }

    var target: Target
    var token: String
    var transport: any HTTPTransport
    var retry: RetryPolicy
    var log: @Sendable (String) -> Void

    static let context = "build-distro"

    public init(
        target: Target,
        token: String,
        transport: any HTTPTransport = URLSession.shared,
        retry: RetryPolicy = RetryPolicy(attempts: 3),
        log: @escaping @Sendable (String) -> Void = { print($0) }
    ) {
        self.target = target
        self.token = token
        self.transport = transport
        self.retry = retry
        self.log = log
    }

    /// Called once the build exists, before its parts upload.
    public func started(_ build: Build) async {
        await status("pending", "Uploading build #\(build.number)", build.url)
        // An earlier build's comment shows this one is on its way.
        if let comment = await findComment(for: build) {
            await editComment(comment, body: body(for: build))
        }
    }

    /// Called with the build's final known state.
    public func finished(_ build: Build) async {
        switch build.state {
        case "ready": await status("success", "Ready to install: \(version(build))", build.url)
        case "failed": await status("failure", String((build.failureReason ?? "Failed").prefix(140)), build.url)
        default: await status("pending", "Processing build #\(build.number)", build.url)
        }
        await upsertComment(for: build)
    }

    /// Called when the upload itself failed after the build was created.
    public func uploadFailed(_ build: Build, error: any Error) async {
        await status("failure", String("Upload failed: \(error)".prefix(140)), build.url)
    }

    // MARK: - Changelog

    private struct Comparison: Decodable {
        var mergeBaseCommit: Parent
        var commits: [Entry]

        struct Parent: Decodable { var sha: String }

        struct Entry: Decodable {
            var sha: String
            var commit: Details
            var author: Account?
            var parents: [Parent]

            struct Details: Decodable {
                var message: String
                var author: Person?
            }

            struct Person: Decodable { var name: String? }
            struct Account: Decodable { var login: String }
            struct Parent: Decodable { var sha: String }
        }
    }

    /// What the build adds, from GitHub's compare API: a pull request against
    /// its base branch, a main build since the previous ready main build, any
    /// other branch against main. Merge commits are left out, so merging main
    /// into a branch doesn't list main's changes again. Nil when GitHub can't
    /// be asked.
    public func changelog(for build: Build) async -> Changelog? {
        let head = target.commitSHA
        let mainBranch = build.mainBranch ?? "main"

        let (kind, base): (String, String?) = switch build.bucket {
        case "pull_requests": ("pull_request", target.baseRef ?? mainBranch)
        case "main": build.previousCommitSha.map { ("main", $0) } ?? ("first", nil)
        default: ("branch", mainBranch)
        }

        guard let base else {
            // A first main build has nothing to compare with; it lists its own commit.
            guard let data = await send("GET", "repos/\(target.repository)/commits/\(head)", Optional<String>.none),
                  let entry = try? decoder.decode(Comparison.Entry.self, from: data)
            else { return nil }
            return Changelog(kind: kind, base: nil, head: head, commits: [commit(entry)], truncated: false)
        }

        var commits: [Changelog.Commit] = []
        var mergeBase: String?
        var truncated = true
        for page in 1 ... 10 {
            let path = "repos/\(target.repository)/compare/\(escape(base))...\(head)?per_page=100&page=\(page)"
            guard let data = await send("GET", path, Optional<String>.none),
                  let comparison = try? decoder.decode(Comparison.self, from: data)
            else { return nil }

            // The commit the branch left main at; a compare link starts there.
            mergeBase = comparison.mergeBaseCommit.sha
            commits += comparison.commits.filter { $0.parents.count < 2 }.map(commit)
            if comparison.commits.count < 100 {
                truncated = false
                break
            }
        }

        return Changelog(kind: kind, base: mergeBase, head: head, commits: commits, truncated: truncated)
    }

    private func commit(_ entry: Comparison.Entry) -> Changelog.Commit {
        Changelog.Commit(sha: entry.sha, message: entry.commit.message, author: entry.author?.login ?? entry.commit.author?.name)
    }

    private func escape(_ ref: String) -> String {
        ref.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ref
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    // MARK: - Statuses

    private func status(_ state: String, _ description: String, _ url: String) async {
        let body: [String: String] = ["state": state, "description": description, "target_url": url, "context": Self.context]
        if await send("POST", "repos/\(target.repository)/statuses/\(target.commitSHA)", body) == nil {
            log("::warning::Couldn't set the GitHub commit status. Does the job have `statuses: write`?")
        }
    }

    // MARK: - Pull request comment

    private struct Comment: Decodable {
        var id: Int
        var body: String?
    }

    private func upsertComment(for build: Build) async {
        guard let pullRequest = target.pullRequest else { return }
        let body = body(for: build)

        if let comment = await findComment(for: build) {
            await editComment(comment, body: body)
        } else if await send("POST", "repos/\(target.repository)/issues/\(pullRequest)/comments", ["body": body]) == nil {
            log("::warning::Couldn't comment on the pull request. Does the job have `pull-requests: write`?")
        }
    }

    private func editComment(_ comment: Comment, body: String) async {
        if await send("PATCH", "repos/\(target.repository)/issues/comments/\(comment.id)", ["body": body]) == nil {
            log("::warning::Couldn't update the pull request comment.")
        }
    }

    /// Pages through the PR's comments; PRs rarely have more than a few hundred.
    private func findComment(for build: Build) async -> Comment? {
        guard let pullRequest = target.pullRequest else { return nil }
        let marker = marker(for: build)

        for page in 1 ... 10 {
            guard let data = await send("GET", "repos/\(target.repository)/issues/\(pullRequest)/comments?per_page=100&page=\(page)", Optional<String>.none),
                  let comments = try? JSONDecoder().decode([Comment].self, from: data)
            else { return nil }

            if let comment = comments.first(where: { $0.body?.contains(marker) == true }) { return comment }
            if comments.count < 100 { return nil }
        }
        return nil
    }

    /// One comment per build-distro project: the project's address is in every
    /// build URL, before `/builds/`.
    func marker(for build: Build) -> String {
        let project = build.url.components(separatedBy: "/builds/").first ?? build.url
        return "<!-- build-distro: \(project) -->"
    }

    func body(for build: Build) -> String {
        let name = build.displayName ?? "The app"
        let status = switch build.state {
        case "ready": "**\(name) \(version(build))** is ready to install. [Open build #\(build.number)](\(build.url))"
        case "failed": "Build #\(build.number) failed: \(build.failureReason ?? "unknown reason"). [Details](\(build.url))"
        default: "Build #\(build.number) is \(build.state). [Follow it live](\(build.url))"
        }

        return """
        \(marker(for: build))
        \(status)

        Commit `\(target.commitSHA.prefix(7))`
        """
    }

    private func version(_ build: Build) -> String {
        switch (build.version, build.buildVersion) {
        case let (version?, buildVersion?): "\(version) (\(buildVersion))"
        case let (version?, nil): version
        default: "build #\(build.number)"
        }
    }

    // MARK: - HTTP

    /// Returns the response body, or `nil` after logging when GitHub refused or
    /// couldn't be reached.
    private func send<Body: Encodable & Sendable>(_ method: String, _ path: String, _ body: Body?) async -> Data? {
        let base = target.apiURL.absoluteString.hasSuffix("/") ? target.apiURL.absoluteString : target.apiURL.absoluteString + "/"
        guard let url = URL(string: base + path) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let data = body.flatMap { try? JSONEncoder().encode($0) }
        if data != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }

        do {
            return try await retry.run { [transport, request] in
                let (responseBody, response) = try await transport.send(request, body: data)
                guard (200 ..< 300).contains(response.statusCode) else {
                    throw HTTPStatusError.status(response.statusCode, responseBody)
                }
                return responseBody
            }
        } catch let HTTPStatusError.status(code, responseBody) {
            log("GitHub answered \(code) for \(method) \(path): \(String(decoding: responseBody.prefix(300), as: UTF8.self))")
            return nil
        } catch {
            log("GitHub request \(method) \(path) failed: \(error)")
            return nil
        }
    }
}
