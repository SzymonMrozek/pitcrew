import CanvasCore
import CanvasEngine
import SwiftUI

/// What a value looks like once rendered, for the inspector. It reads the same tables
/// the engine draws with, so the inspector and the canvas never disagree.
public enum StyleInfo {
    public static let textStyles = [
        "largeTitle", "title", "title2", "title3", "headline", "body", "callout", "subheadline", "footnote",
        "caption", "caption2",
    ]
    public static let weights = ["ultraLight", "thin", "light", "regular", "medium", "semibold", "bold", "heavy", "black"]

    /// The color a value renders in light or dark appearance, as `#RRGGBB`.
    public static func hex(_ value: Value?, tokens: TokenSet, dark: Bool) -> String? {
        LayoutEngine(tokens: tokens, appearance: dark ? .dark : .light).color(value)?.hex
    }

    /// The number a value resolves to in light mode.
    public static func number(_ value: Value?, tokens: TokenSet) -> Double? {
        LayoutEngine(tokens: tokens, appearance: .light).number(value).map(Double.init)
    }

    /// The text style name a font value resolves to.
    public static func textStyle(_ value: Value?, tokens: TokenSet) -> String? {
        LayoutEngine(tokens: tokens, appearance: .light).textStyle(value)
    }

    /// For example `SF Pro · 17 pt · Regular`, at the default Dynamic Type size.
    public static func font(style: String, weight: String?) -> String {
        guard let metrics = AppleType.styles[style] else { return style }
        let name = weight ?? AppleType.weights.min { abs($0.value - metrics.weight) < abs($1.value - metrics.weight) }?.key ?? "regular"
        return "SF Pro · \(metrics.size.formatted()) pt · \(name.prefix(1).uppercased() + name.dropFirst())"
    }
}

extension Color {
    /// A color from `#RRGGBB` or `#RRGGBBAA`; clear when the string isn't one.
    public init(hex: String) {
        if let rgba = RGBA(hex: hex) {
            self.init(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha)
        } else {
            self = .clear
        }
    }
}
