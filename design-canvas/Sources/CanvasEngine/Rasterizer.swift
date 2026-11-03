import CanvasCore
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Draws display lists with Core Graphics: vectors and Core Text at whatever scale the
/// context has, so a tile at 16 px per point is as sharp as one at 1.
public enum Rasterizer {
    /// Draws `ops` into a context whose origin is top-left and whose units are points.
    public static func draw(_ ops: [DrawOp], in context: CGContext) {
        for op in ops {
            switch op {
            case .fill(let rect, let radius, let color):
                context.setFillColor(cgColor(color))
                if radius > 0 {
                    context.addPath(roundedPath(rect, radius: radius))
                    context.fillPath()
                } else {
                    context.fill(rect)
                }
            case .stroke(let rect, let radius, let width, let color):
                let inset = rect.insetBy(dx: width / 2, dy: width / 2)
                context.setStrokeColor(cgColor(color))
                context.setLineWidth(width)
                context.addPath(roundedPath(inset, radius: max(radius - width / 2, 0)))
                context.strokePath()
            case .shadow(let radius, let y, let color, let children):
                // Shadow offsets and blur are in device pixels with y up, whatever the CTM.
                let scale = abs(context.ctm.a)
                context.saveGState()
                context.setShadow(offset: CGSize(width: 0, height: -y * scale), blur: radius * 2 * scale, color: cgColor(color))
                context.beginTransparencyLayer(auxiliaryInfo: nil)
                draw(children, in: context)
                context.endTransparencyLayer()
                context.restoreGState()
            case .line(let from, let to, let width, let color):
                context.setStrokeColor(cgColor(color))
                context.setLineWidth(width)
                context.strokeLineSegments(between: [from, to])
            case .text(let spec, let rect):
                TextEngine.draw(spec, in: rect, context: context)
            case .symbol(let spec, let rect):
                Symbols.draw(spec, in: rect, context: context)
            case .group(let clip, let radius, let opacity, let children):
                context.saveGState()
                if let clip {
                    context.addPath(roundedPath(clip, radius: radius))
                    context.clip()
                }
                if opacity < 1 {
                    context.setAlpha(opacity)
                    context.beginTransparencyLayer(auxiliaryInfo: nil)
                    draw(children, in: context)
                    context.endTransparencyLayer()
                } else {
                    draw(children, in: context)
                }
                context.restoreGState()
            }
        }
    }

    /// Draws a laid-out item: background clipped to its corners, then its ops. The
    /// context's origin is the item's top-left corner.
    public static func drawItem(_ layout: LayoutResult, in context: CGContext) {
        let bounds = CGRect(origin: .zero, size: layout.size)
        context.saveGState()
        context.addPath(roundedPath(bounds, radius: layout.cornerRadius))
        context.clip()
        context.setFillColor(cgColor(layout.background))
        context.fill(bounds)
        draw(layout.ops, in: context)
        context.restoreGState()
    }

    /// A bitmap context with a top-left origin in points at `scale` pixels per point.
    public static func makeContext(width: Int, height: Int, scale: CGFloat) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.setShouldSmoothFonts(false)
        context.interpolationQuality = .high
        return context
    }

    public static func image(_ layout: LayoutResult, scale: CGFloat) -> CGImage? {
        let width = Int((layout.size.width * scale).rounded(.up))
        let height = Int((layout.size.height * scale).rounded(.up))
        guard let context = makeContext(width: width, height: height, scale: scale) else { return nil }
        drawItem(layout, in: context)
        return context.makeImage()
    }

    public static func png(_ layout: LayoutResult, scale: CGFloat) -> Data? {
        guard let image = image(layout, scale: scale) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    static func cgColor(_ color: RGBA) -> CGColor {
        CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }

    /// Circular corners: at these radii they match iOS's cards within a pixel.
    static func roundedPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
        let radius = min(radius, rect.width / 2, rect.height / 2)
        guard radius > 0 else { return CGPath(rect: rect, transform: nil) }
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
}
