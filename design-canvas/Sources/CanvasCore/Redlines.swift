import CoreGraphics

/// A measured distance drawn on the canvas, like Figma's red spacing lines.
public struct Redline: Equatable, Sendable {
    public var from: CGPoint
    public var to: CGPoint

    public init(from: CGPoint, to: CGPoint) {
        self.from = from
        self.to = to
    }

    public var length: CGFloat { abs(to.x - from.x) + abs(to.y - from.y) }
    public var isHorizontal: Bool { from.y == to.y }
}

/// Distances between measured frames. Frames come from the native render, so the numbers
/// include spacing the system adds, such as List cell insets.
public enum Redlines {
    /// Edges shorter than this aren't worth a line.
    static let minimum: CGFloat = 0.5

    /// From each edge of `inner` out to the same edge of `outer`: the padding.
    public static func insets(of inner: CGRect, in outer: CGRect) -> [Redline] {
        let y = inner.midY, x = inner.midX
        return [
            Redline(from: CGPoint(x: outer.minX, y: y), to: CGPoint(x: inner.minX, y: y)),
            Redline(from: CGPoint(x: inner.maxX, y: y), to: CGPoint(x: outer.maxX, y: y)),
            Redline(from: CGPoint(x: x, y: outer.minY), to: CGPoint(x: x, y: inner.minY)),
            Redline(from: CGPoint(x: x, y: inner.maxY), to: CGPoint(x: x, y: outer.maxY)),
        ].filter { $0.length >= minimum }
    }

    /// The horizontal and vertical gaps between two rects that don't overlap on that axis.
    /// A line runs through the middle of the rects' shared span, or from `a`'s middle.
    public static func gaps(from a: CGRect, to b: CGRect) -> [Redline] {
        var lines: [Redline] = []
        let overlapY = max(a.minY, b.minY)...max(min(a.maxY, b.maxY), max(a.minY, b.minY))
        let y = overlapY.upperBound > overlapY.lowerBound ? (overlapY.lowerBound + overlapY.upperBound) / 2 : a.midY
        if b.minX >= a.maxX {
            lines.append(Redline(from: CGPoint(x: a.maxX, y: y), to: CGPoint(x: b.minX, y: y)))
        } else if a.minX >= b.maxX {
            lines.append(Redline(from: CGPoint(x: b.maxX, y: y), to: CGPoint(x: a.minX, y: y)))
        }
        let overlapX = max(a.minX, b.minX)...max(min(a.maxX, b.maxX), max(a.minX, b.minX))
        let x = overlapX.upperBound > overlapX.lowerBound ? (overlapX.lowerBound + overlapX.upperBound) / 2 : a.midX
        if b.minY >= a.maxY {
            lines.append(Redline(from: CGPoint(x: x, y: a.maxY), to: CGPoint(x: x, y: b.minY)))
        } else if a.minY >= b.maxY {
            lines.append(Redline(from: CGPoint(x: x, y: b.maxY), to: CGPoint(x: x, y: a.minY)))
        }
        return lines.filter { $0.length >= minimum }
    }

    /// Figma's ⌥-hover: insets when one rect contains the other, gaps otherwise.
    public static func between(_ selected: CGRect, _ other: CGRect) -> [Redline] {
        if other.contains(selected) { return insets(of: selected, in: other) }
        if selected.contains(other) { return insets(of: other, in: selected) }
        return gaps(from: selected, to: other)
    }
}

/// The space around one node, measured from the layout: its padding to its parent on
/// each side, and the gaps to its neighbours.
public struct Spacing: Equatable, Sendable {
    public enum Side: String, CaseIterable, Sendable {
        case leading, trailing, top, bottom
    }

    public struct Inset: Equatable, Sendable {
        public var side: Side
        public var value: CGFloat
        /// The ancestor whose edge this side measures to: the parent.
        public var container: String
        public var line: Redline
    }

    public struct Gap: Equatable, Sendable {
        public var sibling: String
        public var value: CGFloat
        public var line: Redline
    }

    /// The parent the insets measure to: the nearest ancestor with a frame.
    public var container: String?
    /// True when the parent is a list row, which isn't a node: `container` is then the
    /// row's section or list.
    public var inRow = false
    /// One per side, zero included.
    public var insets: [Inset] = []
    public var previous: Gap?
    public var next: Gap?
    /// The measured node's frame.
    public var frame: CGRect

    public var leading: CGFloat? { inset(.leading)?.value }
    public var trailing: CGFloat? { inset(.trailing)?.value }
    public var top: CGFloat? { inset(.top)?.value }
    public var bottom: CGFloat? { inset(.bottom)?.value }
    public func inset(_ side: Side) -> Inset? { insets.first { $0.side == side } }

    /// The insets worth drawing: zero padding gets no line.
    public var insetLines: [Redline] { insets.map(\.line).filter { $0.length >= Redlines.minimum } }

    /// One line per side, like Figma's auto layout overlay: the gap to a neighbour on
    /// that side, or the padding to the parent when there is none.
    public var redlines: [Redline] {
        let gaps = [previous, next].compactMap { $0?.line }
        let covered = Set(gaps.map(side(of:)))
        return gaps + insets.filter { !covered.contains($0.side) }.map(\.line).filter { $0.length >= Redlines.minimum }
    }

    private func side(of line: Redline) -> Side {
        if line.isHorizontal { return max(line.from.x, line.to.x) <= frame.midX ? .leading : .trailing }
        return max(line.from.y, line.to.y) <= frame.midY ? .top : .bottom
    }

    /// Measures the node with `id` in `tree` against its parent, like Figma does by
    /// default; hold ⌥ over another element to measure to that one instead. The parent
    /// is the nearest ancestor with a frame. A list row's content measures to its row,
    /// from `rows`, since rows aren't nodes.
    public init?(of id: String, in tree: ResolvedNode, frames: [String: CGRect], rows: [String: CGRect] = [:]) {
        guard let path = tree.path(to: id), let frame = frames[id] else { return nil }
        self.frame = frame
        let ancestors = Array(path.dropLast().reversed())

        let parent: (id: String, frame: CGRect)?
        if let row = rows[id], let owner = ancestors.first {
            parent = (owner.id, row)
            inRow = true
        } else {
            parent = ancestors.lazy.compactMap { ancestor in frames[ancestor.id].map { (ancestor.id, $0) } }.first
        }
        container = parent?.id

        if let parent {
            let outer = parent.frame
            for side in Side.allCases {
                let value: CGFloat = switch side {
                case .leading: frame.minX - outer.minX
                case .trailing: outer.maxX - frame.maxX
                case .top: frame.minY - outer.minY
                case .bottom: outer.maxY - frame.maxY
                }
                let line: Redline = switch side {
                case .leading: Redline(from: CGPoint(x: outer.minX, y: frame.midY), to: CGPoint(x: frame.minX, y: frame.midY))
                case .trailing: Redline(from: CGPoint(x: frame.maxX, y: frame.midY), to: CGPoint(x: outer.maxX, y: frame.midY))
                case .top: Redline(from: CGPoint(x: frame.midX, y: outer.minY), to: CGPoint(x: frame.midX, y: frame.minY))
                case .bottom: Redline(from: CGPoint(x: frame.midX, y: frame.maxY), to: CGPoint(x: frame.midX, y: outer.maxY))
                }
                insets.append(Inset(side: side, value: value, container: parent.id, line: line))
            }
        }

        // List rows are separate cells, so their neighbours aren't gaps.
        if !inRow, let owner = ancestors.first, let index = owner.children.firstIndex(where: { $0.id == id }) {
            func gap(_ candidates: some Sequence<ResolvedNode>) -> Gap? {
                guard let sibling = candidates.first(where: { $0.kind != .spacer && frames[$0.id] != nil }),
                    let other = frames[sibling.id], let line = Redlines.gaps(from: frame, to: other).first
                else { return nil }
                return Gap(sibling: sibling.id, value: line.length, line: line)
            }
            previous = gap(owner.children[..<index].reversed())
            next = gap(owner.children[(index + 1)...])
        }
    }
}

extension ResolvedNode {
    /// This node down to the node with `id`, or nil when it isn't in this tree.
    public func path(to id: String) -> [ResolvedNode]? {
        if self.id == id { return [self] }
        for child in children {
            if let path = child.path(to: id) { return [self] + path }
        }
        return nil
    }
}
