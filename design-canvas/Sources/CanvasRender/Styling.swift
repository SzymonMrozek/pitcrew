import CanvasCore
import SwiftUI

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Turns document values into SwiftUI values. Tokens resolve in the mode that matches
/// the frame's color scheme; Apple semantic colors stay dynamic platform colors.
struct Styling {
    let tokens: TokenSet
    let mode: String

    func number(_ value: Value?) -> CGFloat? {
        switch value {
        case .number(let number): CGFloat(number)
        case .token(let id):
            if case .number(let number) = try? tokens.resolve(id, mode: mode) { CGFloat(number) } else { nil }
        default: nil
        }
    }

    func color(_ value: Value?) -> Color? {
        switch value {
        case .color(let rgba): Color(rgba)
        case .string(let name): Styling.systemColor(name)
        case .token(let id):
            switch try? tokens.resolve(id, mode: mode) {
            case .color(let rgba): Color(rgba)
            case .system(let name): Styling.systemColor(name)
            default: nil
            }
        default: nil
        }
    }

    func font(_ value: Value?, weight: Value?) -> Font? {
        let style: String? = switch value {
        case .string(let name): name
        case .token(let id):
            if case .textStyle(let name) = try? tokens.resolve(id, mode: mode) { name } else { nil }
        default: nil
        }
        guard let textStyle = style.flatMap(Styling.textStyles.get) else { return nil }
        let font = Font.system(textStyle)
        guard let weight = weight?.string.flatMap(Styling.weights.get) else { return font }
        return font.weight(weight)
    }

    static func alignment(_ value: Value?) -> HorizontalAlignment {
        switch value?.string {
        case "leading": .leading
        case "trailing": .trailing
        default: .center
        }
    }

    static func verticalAlignment(_ value: Value?) -> VerticalAlignment {
        switch value?.string {
        case "top": .top
        case "bottom": .bottom
        case "firstTextBaseline": .firstTextBaseline
        default: .center
        }
    }

    static let textStyles: [String: Font.TextStyle] = [
        "largeTitle": .largeTitle, "title": .title, "title2": .title2, "title3": .title3,
        "headline": .headline, "subheadline": .subheadline, "body": .body, "callout": .callout,
        "footnote": .footnote, "caption": .caption, "caption2": .caption2,
    ]

    static let weights: [String: Font.Weight] = [
        "ultraLight": .ultraLight, "thin": .thin, "light": .light, "regular": .regular, "medium": .medium,
        "semibold": .semibold, "bold": .bold, "heavy": .heavy, "black": .black,
    ]

    #if canImport(UIKit)
    static func systemColor(_ name: String) -> Color? {
        let color: UIColor? = switch name {
        case "label": .label
        case "secondaryLabel": .secondaryLabel
        case "tertiaryLabel": .tertiaryLabel
        case "quaternaryLabel": .quaternaryLabel
        case "systemBackground": .systemBackground
        case "secondarySystemBackground": .secondarySystemBackground
        case "systemGroupedBackground": .systemGroupedBackground
        case "secondarySystemGroupedBackground": .secondarySystemGroupedBackground
        case "separator": .separator
        case "systemFill": .systemFill
        case "systemBlue": .systemBlue
        case "systemRed": .systemRed
        case "systemGreen": .systemGreen
        case "systemOrange": .systemOrange
        case "systemYellow": .systemYellow
        case "systemPink": .systemPink
        case "systemPurple": .systemPurple
        case "systemTeal": .systemTeal
        case "systemIndigo": .systemIndigo
        case "systemGray": .systemGray
        case "tint": .tintColor
        default: nil
        }
        return color.map(Color.init(uiColor:))
    }
    #else
    static func systemColor(_ name: String) -> Color? {
        let color: NSColor? = switch name {
        case "label": .labelColor
        case "secondaryLabel": .secondaryLabelColor
        case "tertiaryLabel": .tertiaryLabelColor
        case "quaternaryLabel": .quaternaryLabelColor
        case "systemBackground", "systemGroupedBackground": .windowBackgroundColor
        case "secondarySystemBackground", "secondarySystemGroupedBackground": .controlBackgroundColor
        case "separator": .separatorColor
        case "systemFill": .controlColor
        case "systemBlue": .systemBlue
        case "systemRed": .systemRed
        case "systemGreen": .systemGreen
        case "systemOrange": .systemOrange
        case "systemYellow": .systemYellow
        case "systemPink": .systemPink
        case "systemPurple": .systemPurple
        case "systemTeal": .systemTeal
        case "systemIndigo": .systemIndigo
        case "systemGray": .systemGray
        case "tint": .controlAccentColor
        default: nil
        }
        return color.map(Color.init(nsColor:))
    }
    #endif
}

extension Color {
    init(_ rgba: RGBA) {
        self.init(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha)
    }
}

extension Dictionary {
    fileprivate func get(_ key: Key) -> Value? { self[key] }
}
