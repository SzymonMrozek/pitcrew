import CanvasCore
import CoreGraphics
import CoreText
import Foundation
import Synchronization

/// Text shaping and drawing with Core Text and the system font (SF Pro, or one of its designs). Line height
/// and baseline come from iOS's metrics, not the font's, so text sits the same on a Mac
/// as on an iPhone. Shaped lines are cached; drawing happens on tile threads.
enum TextEngine {
    private final class Lines: @unchecked Sendable {
        let lines: [CTLine]
        let widths: [CGFloat]
        init(lines: [CTLine], widths: [CGFloat]) {
            self.lines = lines
            self.widths = widths
        }
    }

    private struct Key: Hashable {
        let spec: TextSpec
        let width: CGFloat?
    }

    /// Core Text objects are immutable and thread-safe, but not marked Sendable.
    private final class FontBox: @unchecked Sendable {
        let font: CTFont
        init(_ font: CTFont) { self.font = font }
    }

    private static let fonts = Mutex<[FontKey: FontBox]>([:])
    private static let cache = Mutex<[Key: Lines]>([:])

    private struct FontKey: Hashable {
        let size: CGFloat
        let weight: CGFloat
        let design: String?
    }

    /// Core Text's trait values for the system font designs, as in `UIFontDescriptor.SystemDesign`.
    private static let designs = [
        "serif": "NSCTFontUIFontDesignSerif",
        "rounded": "NSCTFontUIFontDesignRounded",
        "monospaced": "NSCTFontUIFontDesignMonospaced",
    ]

    static func font(size: CGFloat, weight: CGFloat, design: String? = nil) -> CTFont {
        let key = FontKey(size: size, weight: weight, design: design)
        if let box = fonts.withLock({ $0[key] }) { return box.font }
        let base = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        var traits: [String: Any] = [kCTFontWeightTrait as String: weight]
        if let trait = design.flatMap({ designs[$0] }) { traits["NSCTFontUIFontDesignTrait"] = trait }
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(
            CTFontCopyFontDescriptor(base), [kCTFontTraitsAttribute: traits] as CFDictionary
        )
        let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        let box = FontBox(font)
        fonts.withLock { $0[key] = box }
        return font
    }

    /// The size text takes when wrapped to `maxWidth`, or on one line per paragraph when
    /// nil, rounded up to device pixels like SwiftUI does.
    static func measure(_ spec: TextSpec, maxWidth: CGFloat?) -> CGSize {
        let shaped = lines(spec, width: maxWidth)
        let width = shaped.widths.max() ?? 0
        let height = CGFloat(max(shaped.lines.count, 1)) * spec.lineHeight
        return CGSize(width: pixelCeil(width), height: pixelCeil(height))
    }

    /// Draws in a top-left origin context.
    static func draw(_ spec: TextSpec, in rect: CGRect, context: CGContext) {
        let shaped = lines(spec, width: rect.width + 0.5)
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for (index, line) in shaped.lines.enumerated() {
            let width = shaped.widths[index]
            let x: CGFloat = switch spec.alignment {
            case .leading: rect.minX
            case .center: rect.minX + (rect.width - width) / 2
            case .trailing: rect.maxX - width
            }
            context.textPosition = CGPoint(x: x, y: rect.minY + spec.ascender + CGFloat(index) * spec.lineHeight)
            CTLineDraw(line, context)
        }
        context.restoreGState()
    }

    private static func lines(_ spec: TextSpec, width: CGFloat?) -> Lines {
        let key = Key(spec: spec, width: width.map { ($0 * 3).rounded(.down) / 3 })
        if let cached = cache.withLock({ $0[key] }) { return cached }

        let color = CGColor(srgbRed: spec.color.red, green: spec.color.green, blue: spec.color.blue, alpha: spec.color.alpha)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font(size: spec.size, weight: spec.weight, design: spec.design),
            kCTForegroundColorAttributeName: color,
        ]
        var lines: [CTLine] = []
        var widths: [CGFloat] = []
        // Each paragraph breaks on its own; an empty string still takes one line.
        for paragraph in spec.string.components(separatedBy: "\n") {
            let attributed = CFAttributedStringCreate(nil, paragraph as CFString, attributes as CFDictionary)!
            let typesetter = CTTypesetterCreateWithAttributedString(attributed)
            let length = CFAttributedStringGetLength(attributed)
            var start = 0
            repeat {
                let count = width.map { CTTypesetterSuggestLineBreak(typesetter, start, Double(max($0, 1))) } ?? (length - start)
                let line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: max(count, 0)))
                lines.append(line)
                widths.append(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line)))
                start += max(count, 1)
            } while start < length
        }
        let shaped = Lines(lines: lines, widths: widths)
        cache.withLock {
            if $0.count > 4000 { $0.removeAll() }
            $0[key] = shaped
        }
        return shaped
    }

    static func pixelCeil(_ value: CGFloat) -> CGFloat { (value * 3 - 0.01).rounded(.up) / 3 }
}
