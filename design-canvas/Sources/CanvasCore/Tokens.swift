import Foundation

public struct TokenID: RawRepresentable, Hashable, Comparable, Codable, CodingKeyRepresentable, Sendable,
    ExpressibleByStringLiteral, CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public init(from decoder: any Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: TokenID, rhs: TokenID) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { rawValue }
}

public enum TokenValue: Hashable, Codable, Sendable {
    case color(RGBA)
    /// An Apple semantic color such as `label` or `systemBlue`. The renderer maps it
    /// to the platform color, which adapts to appearance and contrast on its own.
    case system(String)
    case number(Double)
    /// A Dynamic Type text style: `body`, `headline`, `largeTitle`...
    case textStyle(String)
    case alias(TokenID)

    private enum CodingKeys: String, CodingKey { case color, system, number, textStyle, alias }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try container.decodeIfPresent(RGBA.self, forKey: .color) { self = .color(value) }
        else if let value = try container.decodeIfPresent(String.self, forKey: .system) { self = .system(value) }
        else if let value = try container.decodeIfPresent(Double.self, forKey: .number) { self = .number(value) }
        else if let value = try container.decodeIfPresent(String.self, forKey: .textStyle) { self = .textStyle(value) }
        else if let value = try container.decodeIfPresent(TokenID.self, forKey: .alias) { self = .alias(value) }
        else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown token value"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .color(let value): try container.encode(value, forKey: .color)
        case .system(let value): try container.encode(value, forKey: .system)
        case .number(let value): try container.encode(value, forKey: .number)
        case .textStyle(let value): try container.encode(value, forKey: .textStyle)
        case .alias(let value): try container.encode(value, forKey: .alias)
        }
    }
}

public struct Token: Hashable, Codable, Sendable {
    public var id: TokenID
    /// Value per mode. A mode without its own value falls back to the default mode.
    public var values: [String: TokenValue]

    public init(_ id: TokenID, _ value: TokenValue) {
        self.id = id
        values = [TokenSet.defaultMode: value]
    }

    public init(_ id: TokenID, modes values: [String: TokenValue]) {
        self.id = id
        self.values = values
    }
}

public enum TokenError: Error, Equatable {
    case unknownToken(TokenID)
    case aliasCycle(TokenID)
}

public struct TokenSet: Hashable, Codable, Sendable {
    public static let defaultMode = "light"

    public var modes: [String]
    public var tokens: [TokenID: Token]

    public init(modes: [String] = [TokenSet.defaultMode, "dark"], tokens: [Token] = []) {
        self.modes = modes
        self.tokens = Dictionary(tokens.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// Resolves aliases until a concrete value. Each alias hop resolves in the same mode,
    /// so `accent -> blue` picks dark blue in dark mode.
    public func resolve(_ id: TokenID, mode: String) throws -> TokenValue {
        var visited: Set<TokenID> = []
        var current = id
        while true {
            guard visited.insert(current).inserted else { throw TokenError.aliasCycle(id) }
            guard let token = tokens[current] else { throw TokenError.unknownToken(current) }
            guard let value = token.values[mode] ?? token.values[TokenSet.defaultMode] ?? token.values.values.first
            else { throw TokenError.unknownToken(current) }
            guard case .alias(let next) = value else { return value }
            current = next
        }
    }
}
