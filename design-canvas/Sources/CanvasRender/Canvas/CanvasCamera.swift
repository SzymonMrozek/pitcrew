import CoreGraphics
import Observation

/// Maps page coordinates to view coordinates: `view = page * scale + offset`.
@MainActor @Observable
public final class CanvasCamera {
    public static let scaleRange: ClosedRange<CGFloat> = 0.05...16

    public var offset: CGPoint
    public var scale: CGFloat
    /// The canvas view's size in points, kept current by the view.
    public var viewSize: CGSize = .zero

    public init(offset: CGPoint = CGPoint(x: 80, y: 100), scale: CGFloat = 0.75) {
        self.offset = offset
        self.scale = scale
    }

    public func pageToView(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * scale + offset.x, y: point.y * scale + offset.y)
    }

    public func pageToView(_ rect: CGRect) -> CGRect {
        CGRect(origin: pageToView(rect.origin), size: CGSize(width: rect.width * scale, height: rect.height * scale))
    }

    public func viewToPage(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - offset.x) / scale, y: (point.y - offset.y) / scale)
    }

    /// The page area currently on screen.
    public var visiblePageRect: CGRect {
        CGRect(origin: viewToPage(.zero), size: CGSize(width: viewSize.width / scale, height: viewSize.height / scale))
    }

    public func pan(by translation: CGSize) {
        offset.x += translation.width
        offset.y += translation.height
    }

    /// Zooms keeping `anchor` (view coordinates, default the view's center) fixed.
    public func zoom(by factor: CGFloat, around anchor: CGPoint? = nil) {
        let anchor = anchor ?? CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        let newScale = min(max(scale * factor, Self.scaleRange.lowerBound), Self.scaleRange.upperBound)
        let ratio = newScale / scale
        offset = CGPoint(x: anchor.x - (anchor.x - offset.x) * ratio, y: anchor.y - (anchor.y - offset.y) * ratio)
        scale = newScale
    }

    /// Fits a page rect into the view with some padding, never zooming past 100%.
    public func fit(_ rect: CGRect, padding: CGFloat = 60) {
        guard rect.width > 0, rect.height > 0, viewSize.width > 2 * padding, viewSize.height > 2 * padding else { return }
        let fitted = min((viewSize.width - 2 * padding) / rect.width, (viewSize.height - 2 * padding) / rect.height, 1)
        scale = min(max(fitted, Self.scaleRange.lowerBound), Self.scaleRange.upperBound)
        offset = CGPoint(
            x: (viewSize.width - rect.width * scale) / 2 - rect.minX * scale,
            y: (viewSize.height - rect.height * scale) / 2 - rect.minY * scale
        )
    }
}
