import CanvasCore
import CoreGraphics

/// iOS's look as data: the type ramp, the semantic colors and the system components'
/// metrics. Values come from UIKit on the iOS 26 simulator and from measuring native
/// renders, so a screen draws the same on a Mac as on an iPhone.
public enum Appearance: String, Sendable, CaseIterable {
    case light
    case dark

    /// The token mode for this appearance.
    public var mode: String { rawValue }
}

/// A Dynamic Type style at the default text size, as UIKit reports it.
public struct TextStyleMetrics: Sendable {
    public let size: CGFloat
    public let lineHeight: CGFloat
    public let ascender: CGFloat
    public let descender: CGFloat
    /// Core Text weight, -1...1.
    public let weight: CGFloat
}

public enum AppleType {
    public static let styles: [String: TextStyleMetrics] = [
        "largeTitle": .init(size: 34, lineHeight: 40.574, ascender: 32.373, descender: 8.201, weight: 0),
        "title": .init(size: 28, lineHeight: 33.414, ascender: 26.660, descender: 6.754, weight: 0),
        "title2": .init(size: 22, lineHeight: 26.254, ascender: 20.947, descender: 5.307, weight: 0),
        "title3": .init(size: 20, lineHeight: 23.867, ascender: 19.043, descender: 4.824, weight: 0),
        "headline": .init(size: 17, lineHeight: 20.287, ascender: 16.187, descender: 4.101, weight: 0.3),
        "body": .init(size: 17, lineHeight: 20.287, ascender: 16.187, descender: 4.101, weight: 0),
        "callout": .init(size: 16, lineHeight: 19.094, ascender: 15.234, descender: 3.859, weight: 0),
        "subheadline": .init(size: 15, lineHeight: 17.900, ascender: 14.282, descender: 3.618, weight: 0),
        "footnote": .init(size: 13, lineHeight: 15.514, ascender: 12.378, descender: 3.136, weight: 0),
        "caption": .init(size: 12, lineHeight: 14.320, ascender: 11.426, descender: 2.895, weight: 0),
        "caption2": .init(size: 11, lineHeight: 13.127, ascender: 10.474, descender: 2.653, weight: 0),
    ]

    public static let weights: [String: CGFloat] = [
        "ultraLight": -0.8, "thin": -0.6, "light": -0.4, "regular": 0, "medium": 0.23,
        "semibold": 0.3, "bold": 0.4, "heavy": 0.56, "black": 0.62,
    ]

    /// SF Pro's metrics scale linearly with size, so any size derives from body.
    public static func metrics(size: CGFloat) -> TextStyleMetrics {
        let body = styles["body"]!
        let ratio = size / body.size
        return .init(
            size: size, lineHeight: body.lineHeight * ratio, ascender: body.ascender * ratio,
            descender: body.descender * ratio, weight: 0
        )
    }
}

public enum AppleColors {
    /// Light and dark values of UIKit's semantic and system colors on iOS 26.
    public static let table: [String: (light: RGBA, dark: RGBA)] = {
        let raw: [(String, String, String)] = [
            ("label", "#000000", "#FFFFFF"),
            ("secondaryLabel", "#3C3C4399", "#EBEBF599"),
            ("tertiaryLabel", "#3C3C434C", "#EBEBF54C"),
            ("quaternaryLabel", "#3C3C432D", "#EBEBF528"),
            ("systemBackground", "#FFFFFF", "#000000"),
            ("secondarySystemBackground", "#F2F2F7", "#1C1C1E"),
            ("tertiarySystemBackground", "#FFFFFF", "#2C2C2E"),
            ("systemGroupedBackground", "#F2F2F7", "#000000"),
            ("secondarySystemGroupedBackground", "#FFFFFF", "#1C1C1E"),
            ("tertiarySystemGroupedBackground", "#F2F2F7", "#2C2C2E"),
            ("separator", "#3C3C431F", "#54545880"),
            ("opaqueSeparator", "#E7E7E8", "#2A2A2C"),
            ("systemFill", "#78788033", "#7878805C"),
            ("secondarySystemFill", "#78788029", "#78788052"),
            ("tertiarySystemFill", "#7676801F", "#7676803D"),
            ("systemBlue", "#0088FF", "#0091FF"),
            ("systemRed", "#FF383C", "#FF4245"),
            ("systemGreen", "#34C759", "#30D158"),
            ("systemOrange", "#FF8D28", "#FF9230"),
            ("systemYellow", "#FFCC00", "#FFD600"),
            ("systemPink", "#FF2D55", "#FF375F"),
            ("systemPurple", "#CB30E0", "#DB34F2"),
            ("systemTeal", "#00C3D0", "#00D2E0"),
            ("systemIndigo", "#6155F5", "#6D7CFF"),
            ("systemCyan", "#00C0E8", "#3CD3FE"),
            ("systemMint", "#00C8B3", "#00DAC3"),
            ("systemBrown", "#AC7F5E", "#B78A66"),
            ("systemGray", "#8E8E93", "#8E8E93"),
            ("systemGray2", "#AEAEB2", "#636366"),
            ("systemGray3", "#C7C7CC", "#48484A"),
            ("systemGray4", "#D1D1D6", "#3A3A3C"),
            ("systemGray5", "#E5E5EA", "#2C2C2E"),
            ("systemGray6", "#F2F2F7", "#1C1C1E"),
            ("tint", "#0088FF", "#0091FF"),
            ("link", "#007AFF", "#0984FF"),
            ("placeholderText", "#3C3C434C", "#EBEBF54C"),
            ("white", "#FFFFFF", "#FFFFFF"),
            ("black", "#000000", "#000000"),
            ("clear", "#00000000", "#00000000"),
            // The switch's off track, measured: it isn't a public semantic color.
            ("switchTrack", "#C5C5C7", "#5A5A5E"),
        ]
        var table: [String: (RGBA, RGBA)] = [:]
        for (name, light, dark) in raw { table[name] = (RGBA(hex: light)!, RGBA(hex: dark)!) }
        return table
    }()

    public static func color(_ name: String, _ appearance: Appearance) -> RGBA? {
        table[name].map { appearance == .dark ? $0.dark : $0.light }
    }

    public static var names: [String] { table.keys.sorted() }
}

/// A device frame: its size, safe areas and screen corner.
public struct DeviceSpec: Sendable {
    public let name: String
    public let size: CGSize
    public let safeTop: CGFloat
    public let safeBottom: CGFloat
    public let cornerRadius: CGFloat
    /// The Dynamic Island, in screen points.
    public let island: CGRect?

    public static let all: [DeviceSpec] = [
        DeviceSpec(
            name: "iPhone 17 Pro", size: CGSize(width: 402, height: 874), safeTop: 62, safeBottom: 34,
            cornerRadius: 54, island: CGRect(x: 139, y: 13, width: 124, height: 36)
        ),
        DeviceSpec(
            name: "iPhone 17 Pro Max", size: CGSize(width: 440, height: 956), safeTop: 62, safeBottom: 34,
            cornerRadius: 54, island: CGRect(x: 158, y: 13, width: 124, height: 36)
        ),
        DeviceSpec(name: "iPhone SE", size: CGSize(width: 375, height: 667), safeTop: 20, safeBottom: 0, cornerRadius: 0, island: nil),
    ]

    public static func named(_ name: String?) -> DeviceSpec {
        all.first { $0.name == name } ?? all[0]
    }

    /// The same device with a taller or shorter screen, for screens drawn at their content's height.
    func withHeight(_ height: CGFloat) -> DeviceSpec {
        DeviceSpec(
            name: name, size: CGSize(width: size.width, height: height), safeTop: safeTop, safeBottom: safeBottom,
            cornerRadius: cornerRadius, island: island
        )
    }
}

/// System component metrics, measured from native iOS 26 renders.
public enum AppleMetrics {
    // Inset grouped lists
    public static let listMargin: CGFloat = 16
    public static let cellPadding: CGFloat = 16
    public static let cellVerticalPadding: CGFloat = 15
    public static let minRowHeight: CGFloat = 52
    public static let cardRadius: CGFloat = 26
    public static let sectionSpacing: CGFloat = 35
    /// Extra height a section header adds above its card, beyond the section spacing.
    public static let headerHeight: CGFloat = 23
    /// From a header's baseline to the top of its card.
    public static let headerBaselineToCard: CGFloat = 14
    public static let separatorWidth: CGFloat = 1.0 / 3.0

    // Navigation
    /// From the top safe area to the large title's baseline.
    public static let largeTitleBaseline: CGFloat = 89.67
    /// From the top safe area to the content under a large title.
    public static let largeTitleContentTop: CGFloat = 106
    /// From the top safe area to the content under an inline title.
    public static let inlineContentTop: CGFloat = 54

    // Controls
    public static let switchSize = CGSize(width: 63, height: 28)
    public static let switchKnob = CGSize(width: 37, height: 24)
    public static let labelSpacing: CGFloat = 8
    public static let defaultStackSpacing: CGFloat = 8
    /// A `Spacer()`'s default minimum length.
    public static let spacerMinLength: CGFloat = 8
}
