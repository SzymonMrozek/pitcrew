import CanvasCore
import CoreGraphics
import Synchronization

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// SF Symbols, measured and drawn as vectors through the platform's image API, so they
/// stay sharp at any zoom.
enum Symbols {
    private struct Key: Hashable {
        let name: String
        let pointSize: CGFloat
        let weight: CGFloat
    }

    private static let sizes = Mutex<[Key: CGSize]>([:])

    /// The symbol's size at a point size, like `Image(systemName:)` reports it.
    static func size(_ spec: SymbolSpec) -> CGSize {
        let key = Key(name: spec.name, pointSize: spec.pointSize, weight: spec.weight)
        if let size = sizes.withLock({ $0[key] }) { return size }
        let size = image(spec)?.size ?? CGSize(width: spec.pointSize, height: spec.pointSize)
        sizes.withLock { $0[key] = size }
        return size
    }

    /// Draws in a top-left origin context.
    static func draw(_ spec: SymbolSpec, in rect: CGRect, context: CGContext) {
        guard let image = image(spec) else { return }
        #if canImport(UIKit)
        UIGraphicsPushContext(context)
        image.draw(in: rect)
        UIGraphicsPopContext()
        #elseif canImport(AppKit)
        // Draw the template, then paint it: palette colors would fill a symbol's
        // cut-outs, like the person in person.crop.circle.fill.
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        context.saveGState()
        context.beginTransparencyLayer(in: rect, auxiliaryInfo: nil)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        context.setBlendMode(.sourceIn)
        context.setFillColor(CGColor(srgbRed: spec.color.red, green: spec.color.green, blue: spec.color.blue, alpha: spec.color.alpha))
        context.fill(rect)
        context.endTransparencyLayer()
        context.restoreGState()
        NSGraphicsContext.current = previous
        #endif
    }

    #if canImport(UIKit)
    private static func image(_ spec: SymbolSpec) -> UIImage? {
        let configuration = UIImage.SymbolConfiguration(pointSize: spec.pointSize, weight: uiWeight(spec.weight), scale: .medium)
        let color = UIColor(red: spec.color.red, green: spec.color.green, blue: spec.color.blue, alpha: spec.color.alpha)
        return UIImage(systemName: spec.name, withConfiguration: configuration)?.withTintColor(color, renderingMode: .alwaysOriginal)
    }

    private static func uiWeight(_ weight: CGFloat) -> UIImage.SymbolWeight {
        switch weight {
        case ..<(-0.7): .ultraLight
        case ..<(-0.5): .thin
        case ..<(-0.2): .light
        case ..<0.1: .regular
        case ..<0.26: .medium
        case ..<0.35: .semibold
        case ..<0.5: .bold
        case ..<0.6: .heavy
        default: .black
        }
    }
    #elseif canImport(AppKit)
    private static func image(_ spec: SymbolSpec) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: spec.pointSize, weight: NSFont.Weight(spec.weight), scale: .medium)
        return NSImage(systemSymbolName: spec.name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
    }
    #else
    private static func image(_ spec: SymbolSpec) -> Never? { nil }
    #endif
}
