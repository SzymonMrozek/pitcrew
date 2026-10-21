import Foundation

/// What CI knows about the build it uploads.
public struct BuildMetadata: Equatable, Sendable {
    public var idempotencyKey: String
    public var commitSHA: String?
    public var branch: String?
    public var pullRequest: Int?
    public var runURL: String?
    public var commitMessage: String?
    public var releaseNotes: String?

    public init(
        idempotencyKey: String,
        commitSHA: String? = nil,
        branch: String? = nil,
        pullRequest: Int? = nil,
        runURL: String? = nil,
        commitMessage: String? = nil,
        releaseNotes: String? = nil
    ) {
        self.idempotencyKey = idempotencyKey
        self.commitSHA = commitSHA
        self.branch = branch
        self.pullRequest = pullRequest
        self.runURL = runURL
        self.commitMessage = commitMessage
        self.releaseNotes = releaseNotes
    }
}

/// A file to upload: `kind` is `ipa` or `dsyms`.
public struct LocalArtifact: Equatable, Sendable {
    public var kind: String
    public var fileURL: URL
    public var size: Int

    public init(kind: String, fileURL: URL) throws {
        self.kind = kind
        self.fileURL = fileURL
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        size = (attributes[.size] as? NSNumber)?.intValue ?? 0
    }
}

public struct Build: Decodable, Equatable, Sendable {
    public var id: Int
    public var number: Int
    public var state: String
    public var url: String
    public var failureReason: String?
    public var displayName: String?
    public var version: String?
    public var buildVersion: String?
    public var artifacts: [Artifact]

    public struct Artifact: Decodable, Equatable, Sendable {
        public var kind: String
        public var size: Int
        public var partSize: Int
        public var partCount: Int
        public var uploaded: Bool
    }
}

struct PartURLs: Decodable {
    var uploaded: [Int]
    var urls: [String: String]
    var partSize: Int
    var partCount: Int
}

struct StartRequest: Encodable {
    var idempotencyKey: String
    var commitSha: String?
    var branch: String?
    var prNumber: Int?
    var runUrl: String?
    var commitMessage: String?
    var releaseNotes: String?
    var artifacts: [Artifact]

    struct Artifact: Encodable {
        var kind: String
        var size: Int
        var filename: String
    }
}

struct ServerError: Decodable {
    var error: String
    var kind: String?
    var missingParts: [Int]?
}

public enum UploadError: Error, Equatable, CustomStringConvertible {
    /// The server or the bucket answered with an error that retrying won't fix.
    case rejected(status: Int, message: String)
    /// Parts still missing after every retry round.
    case incomplete(kind: String, missingParts: [Int])
    case buildFailed(reason: String)
    case timedOut(state: String)

    public var description: String {
        switch self {
        case let .rejected(status, message): "The server rejected the request (\(status)): \(message)"
        case let .incomplete(kind, parts): "\(kind) is still missing parts \(parts) after retrying"
        case let .buildFailed(reason): "The build failed: \(reason)"
        case let .timedOut(state): "Gave up waiting; the build is still \(state)"
        }
    }
}
