import Foundation

/// Repository naming and exemption patterns; rule behavior and diagnostic identifiers stay fixed.
public struct LintConfiguration: Codable, Sendable {
    public var designSystemPrefix = "Design"
    public var colorFactory = "design"
    public var designSystemModulePattern = "^Design.+$"
    public var formatExcludedPrefixes: [String] = []
    /// Directory treated as the repository root, for Swift code in a monorepo subdirectory.
    public var sourceRoot = ""
    /// Rules whose findings are not reported. The self-test still runs every rule.
    public var disabledRules: [Rule] = []
    /// Static `Font` members that are design-system fonts, accepted by `.font(...)`.
    public var fontFactories: [String] = []
    /// Comment prefixes `no_comments` accepts besides tool directives, such as a tracked shortcut marker.
    public var allowedCommentPrefixes: [String] = []

    public init() {}

    enum CodingKeys: String, CodingKey {
        case designSystemPrefix, colorFactory, designSystemModulePattern, formatExcludedPrefixes
        case sourceRoot, disabledRules, fontFactories, allowedCommentPrefixes
    }

    /// The first four fields stay required; later ones are optional so existing files keep working.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        designSystemPrefix = try container.decode(String.self, forKey: .designSystemPrefix)
        colorFactory = try container.decode(String.self, forKey: .colorFactory)
        designSystemModulePattern = try container.decode(String.self, forKey: .designSystemModulePattern)
        formatExcludedPrefixes = try container.decode([String].self, forKey: .formatExcludedPrefixes)
        let root = try container.decodeIfPresent(String.self, forKey: .sourceRoot) ?? ""
        guard !root.hasPrefix("/"), !root.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .sourceRoot,
                in: container,
                debugDescription: "sourceRoot must be a relative path inside the repository"
            )
        }
        sourceRoot = root.isEmpty || root.hasSuffix("/") ? root : root + "/"
        disabledRules = try container.decodeIfPresent([Rule].self, forKey: .disabledRules) ?? []
        fontFactories = try container.decodeIfPresent([String].self, forKey: .fontFactories) ?? []
        allowedCommentPrefixes = try container.decodeIfPresent([String].self, forKey: .allowedCommentPrefixes) ?? []
    }

    /// The path rules and exclusions see for a repository path; nil outside the source root.
    public func rulePath(_ path: String) -> String? {
        path.hasPrefix(sourceRoot) ? String(path.dropFirst(sourceRoot.count)) : nil
    }
}
