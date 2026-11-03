import CanvasCore
import CoreGraphics

/// A run of text, styled and ready to draw.
public struct TextSpec: Hashable, Sendable {
    public var string: String
    public var size: CGFloat
    /// Core Text weight, -1...1.
    public var weight: CGFloat
    public var color: RGBA
    public var lineHeight: CGFloat
    /// From the top of a line box to its baseline.
    public var ascender: CGFloat
    public var alignment: TextAlignment = .leading

    public enum TextAlignment: Hashable, Sendable { case leading, center, trailing }
}

/// An SF Symbol at a point size and weight.
public struct SymbolSpec: Hashable, Sendable {
    public var name: String
    public var pointSize: CGFloat
    public var weight: CGFloat
    public var color: RGBA
}

/// What the layout engine emits and the rasterizer draws, in screen points. Plain values,
/// so tiles can be drawn on any thread.
public indirect enum DrawOp: Sendable {
    case fill(CGRect, radius: CGFloat, color: RGBA)
    /// A stroke inside a rounded rect's edge.
    case stroke(CGRect, radius: CGFloat, width: CGFloat, color: RGBA)
    case line(from: CGPoint, to: CGPoint, width: CGFloat, color: RGBA)
    /// Text laid out in `rect`; the first baseline is `rect.minY + spec.ascender`.
    case text(TextSpec, rect: CGRect)
    case symbol(SymbolSpec, rect: CGRect)
    /// Children clipped to a rounded rect and drawn at an opacity.
    case group(clip: CGRect?, radius: CGFloat, opacity: CGFloat, ops: [DrawOp])
    /// Children drawn as one layer that casts a shadow, like SwiftUI's `shadow`.
    case shadow(radius: CGFloat, y: CGFloat, color: RGBA, ops: [DrawOp])
}

/// A laid-out screen or component: its size, background, what to draw and every
/// node's frame, keyed by resolved node ID.
public struct LayoutResult: Sendable {
    public var size: CGSize
    public var background: RGBA
    public var cornerRadius: CGFloat
    public var ops: [DrawOp]
    public var frames: [String: CGRect]
    /// The list row each row's content sits in, keyed by the content's ID. Rows aren't
    /// nodes, so they aren't in `frames`, but they are what a row's padding measures to.
    public var rows: [String: CGRect]

    public init(
        size: CGSize, background: RGBA, cornerRadius: CGFloat, ops: [DrawOp], frames: [String: CGRect],
        rows: [String: CGRect] = [:]
    ) {
        self.size = size
        self.background = background
        self.cornerRadius = cornerRadius
        self.ops = ops
        self.frames = frames
        self.rows = rows
    }

    /// The smallest node containing `point`, which is the deepest one in practice.
    public func hitTest(_ point: CGPoint) -> String? {
        frames.filter { $0.value.contains(point) }
            .min { $0.value.width * $0.value.height < $1.value.width * $1.value.height }?
            .key
    }
}
