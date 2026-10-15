import Foundation

/// Repository naming and exemption patterns; rule behavior and diagnostic identifiers stay fixed.
public struct LintConfiguration: Codable, Sendable {
    public var designSystemPrefix = "Design"
    public var colorFactory = "design"
    public var designSystemModulePattern = "^Design.+$"
    public var formatExcludedPrefixes: [String] = []

    public init() {}
}
