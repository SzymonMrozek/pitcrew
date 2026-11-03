import Foundation

public struct NodeID: RawRepresentable, Hashable, Comparable, Codable, CodingKeyRepresentable, Sendable,
    ExpressibleByStringLiteral, CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public init(from decoder: any Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func random() -> NodeID { NodeID(String(UUID().uuidString.prefix(8)).lowercased()) }
    public static func < (lhs: NodeID, rhs: NodeID) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { rawValue }
}

/// A property name. The set is open: the renderer ignores props it doesn't know,
/// so a newer document still opens in an older editor.
public struct Prop: RawRepresentable, Hashable, Comparable, Codable, CodingKeyRepresentable, Sendable,
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

    public static func < (lhs: Prop, rhs: Prop) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { rawValue }

    // Identity and canvas placement
    public static let name: Prop = "name"
    public static let x: Prop = "x"
    public static let y: Prop = "y"
    public static let device: Prop = "device"
    public static let appearance: Prop = "appearance"
    public static let component: Prop = "component"

    // Content
    public static let text: Prop = "text"
    public static let title: Prop = "title"
    public static let symbol: Prop = "symbol"
    public static let isOn: Prop = "isOn"
    public static let style: Prop = "style"

    // Layout
    public static let spacing: Prop = "spacing"
    public static let alignment: Prop = "alignment"
    public static let padding: Prop = "padding"
    public static let width: Prop = "width"
    public static let height: Prop = "height"
    /// A number or `infinity`, like `.frame(maxWidth: .infinity)`.
    public static let maxWidth: Prop = "maxWidth"
    public static let maxHeight: Prop = "maxHeight"
    /// Where content sits in a frame larger than it, like `.frame(alignment:)`.
    public static let frameAlignment: Prop = "frameAlignment"
    /// Override `padding` on one axis, like `.padding(.horizontal, 20)`.
    public static let paddingHorizontal: Prop = "paddingHorizontal"
    public static let paddingVertical: Prop = "paddingVertical"
    public static let multilineTextAlignment: Prop = "multilineTextAlignment"

    // Appearance
    public static let font: Prop = "font"
    public static let weight: Prop = "weight"
    public static let foreground: Prop = "foreground"
    public static let background: Prop = "background"
    public static let fill: Prop = "fill"
    public static let cornerRadius: Prop = "cornerRadius"
    /// A stroke inside the node's rounded shape, like `.overlay(shape.strokeBorder(...))`.
    public static let border: Prop = "border"
    public static let borderWidth: Prop = "borderWidth"
    public static let shadowRadius: Prop = "shadowRadius"
    public static let shadowY: Prop = "shadowY"
    public static let shadowColor: Prop = "shadowColor"
    public static let opacity: Prop = "opacity"
}

public struct RGBA: Hashable, Codable, Sendable, CustomStringConvertible {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// `#RRGGBB` or `#RRGGBBAA`.
    public init?(hex: String) {
        var digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if digits.count == 6 { digits += "FF" }
        guard digits.count == 8, let value = UInt32(digits, radix: 16) else { return nil }
        red = Double((value >> 24) & 0xFF) / 255
        green = Double((value >> 16) & 0xFF) / 255
        blue = Double((value >> 8) & 0xFF) / 255
        alpha = Double(value & 0xFF) / 255
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let hex = try container.decode(String.self)
        guard let color = RGBA(hex: hex) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid color \(hex)")
        }
        self = color
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }

    public var hex: String {
        let channels = [red, green, blue, alpha].map { Int(($0 * 255).rounded()) }
        let rgb = channels[..<3].map { String(format: "%02X", $0) }.joined()
        return "#" + rgb + (channels[3] == 255 ? "" : String(format: "%02X", channels[3]))
    }

    public var description: String { hex }
}

/// A property value. Encoded as a single-key object (`{"number": 16}`) so the
/// JSON stays readable for agents and survives new cases.
public enum Value: Hashable, Codable, Sendable, CustomStringConvertible {
    case string(String)
    case number(Double)
    case bool(Bool)
    case color(RGBA)
    case token(TokenID)

    private enum CodingKeys: String, CodingKey { case string, number, bool, color, token }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try container.decodeIfPresent(String.self, forKey: .string) { self = .string(value) }
        else if let value = try container.decodeIfPresent(Double.self, forKey: .number) { self = .number(value) }
        else if let value = try container.decodeIfPresent(Bool.self, forKey: .bool) { self = .bool(value) }
        else if let value = try container.decodeIfPresent(RGBA.self, forKey: .color) { self = .color(value) }
        else if let value = try container.decodeIfPresent(TokenID.self, forKey: .token) { self = .token(value) }
        else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown value"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .string(let value): try container.encode(value, forKey: .string)
        case .number(let value): try container.encode(value, forKey: .number)
        case .bool(let value): try container.encode(value, forKey: .bool)
        case .color(let value): try container.encode(value, forKey: .color)
        case .token(let value): try container.encode(value, forKey: .token)
        }
    }

    public var string: String? { if case .string(let value) = self { value } else { nil } }
    public var number: Double? { if case .number(let value) = self { value } else { nil } }
    public var bool: Bool? { if case .bool(let value) = self { value } else { nil } }

    public var description: String {
        switch self {
        case .string(let value): "\"\(value)\""
        case .number(let value): value.formatted()
        case .bool(let value): String(value)
        case .color(let value): value.hex
        case .token(let value): "{\(value.rawValue)}"
        }
    }
}
