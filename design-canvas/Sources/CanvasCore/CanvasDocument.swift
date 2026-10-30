/// An edit. Every change to a document is one of these, so the same values feed undo,
/// multiplayer sync and agent writes. Each case touches as little state as possible:
/// `set` changes one property, which is the unit of last-writer-wins on the server.
public indirect enum Edit: Hashable, Codable, Sendable {
    /// Adds a node under `node.parent`. The parent must exist.
    case insert(Node)
    /// Removes a node and its subtree.
    case delete(NodeID)
    /// Sets or clears (`nil`) one property.
    case set(NodeID, Prop, Value?)
    /// Re-parents or re-orders a node.
    case move(NodeID, parent: NodeID, order: String)
    /// Sets or clears one override on an instance.
    case override(NodeID, target: NodeID, Prop, Value?)
    case batch([Edit])
}

public enum DocumentError: Error, Equatable {
    case unknownNode(NodeID)
    case duplicateNode(NodeID)
    case moveIntoDescendant(NodeID)
    case rootIsPermanent
    case notAnInstance(NodeID)
}

public struct CanvasDocument: Hashable, Codable, Sendable {
    public static let rootID: NodeID = "root"

    public private(set) var nodes: [NodeID: Node]
    public var tokens: TokenSet
    /// Parent -> children sorted by order. Derived, rebuilt on decode.
    private var childIndex: [NodeID: [NodeID]] = [:]

    private enum CodingKeys: String, CodingKey { case nodes, tokens }

    public init(tokens: TokenSet = TokenSet()) {
        let root = Node(id: CanvasDocument.rootID, kind: .page)
        nodes = [root.id: root]
        self.tokens = tokens
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nodes = try container.decode([NodeID: Node].self, forKey: .nodes)
        tokens = try container.decode(TokenSet.self, forKey: .tokens)
        rebuildIndex()
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(nodes, forKey: .nodes)
        try container.encode(tokens, forKey: .tokens)
    }

    public subscript(id: NodeID) -> Node? { nodes[id] }

    public func children(of id: NodeID) -> [Node] {
        (childIndex[id] ?? []).compactMap { nodes[$0] }
    }

    /// An order key that places a new child after the current last child.
    public func appendOrder(in parent: NodeID) -> String {
        FractionalIndex.between(childIndex[parent]?.last.flatMap { nodes[$0]?.order }, nil)
    }

    public func isDescendant(_ id: NodeID, of ancestor: NodeID) -> Bool {
        var current = nodes[id]?.parent
        while let parent = current {
            if parent == ancestor { return true }
            current = nodes[parent]?.parent
        }
        return false
    }

    /// Applies an edit and returns its inverse. A failing edit leaves the
    /// document unchanged: single steps validate before they mutate, and a batch
    /// rolls back the steps it already applied. No step copies the document.
    @discardableResult
    public mutating func apply(_ edit: Edit) throws -> Edit {
        switch edit {
        case .insert(let node):
            guard nodes[node.id] == nil else { throw DocumentError.duplicateNode(node.id) }
            guard let parent = node.parent, nodes[parent] != nil else {
                throw DocumentError.unknownNode(node.parent ?? node.id)
            }
            nodes[node.id] = node
            link(node.id, under: parent)
            return .delete(node.id)

        case .delete(let id):
            guard id != CanvasDocument.rootID else { throw DocumentError.rootIsPermanent }
            guard let node = nodes[id], let parent = node.parent else { throw DocumentError.unknownNode(id) }
            let removed = subtree(of: id)
            unlink(id, from: parent)
            for removedID in removed.map(\.id) {
                nodes[removedID] = nil
                childIndex[removedID] = nil
            }
            return .batch(removed.map(Edit.insert))

        case .set(let id, let prop, let value):
            guard var node = nodes[id] else { throw DocumentError.unknownNode(id) }
            let previous = node.props[prop]
            node.props[prop] = value
            nodes[id] = node
            return .set(id, prop, previous)

        case .move(let id, let newParent, let order):
            guard id != CanvasDocument.rootID else { throw DocumentError.rootIsPermanent }
            guard var node = nodes[id], let oldParent = node.parent else { throw DocumentError.unknownNode(id) }
            guard nodes[newParent] != nil else { throw DocumentError.unknownNode(newParent) }
            guard newParent != id, !isDescendant(newParent, of: id) else { throw DocumentError.moveIntoDescendant(id) }
            let oldOrder = node.order
            unlink(id, from: oldParent)
            node.parent = newParent
            node.order = order
            nodes[id] = node
            link(id, under: newParent)
            return .move(id, parent: oldParent, order: oldOrder)

        case .override(let id, let target, let prop, let value):
            guard var node = nodes[id] else { throw DocumentError.unknownNode(id) }
            guard node.kind == .instance else { throw DocumentError.notAnInstance(id) }
            let previous = node.overrides[target]?[prop]
            node.overrides[target, default: [:]][prop] = value
            if node.overrides[target]?.isEmpty == true { node.overrides[target] = nil }
            nodes[id] = node
            return .override(id, target: target, prop, previous)

        case .batch(let edits):
            var inverses: [Edit] = []
            do {
                for edit in edits { inverses.append(try apply(edit)) }
            } catch {
                for inverse in inverses.reversed() { _ = try? apply(inverse) }
                throw error
            }
            return .batch(inverses.reversed())
        }
    }

    /// The node and its descendants, parents before children.
    public func subtree(of id: NodeID) -> [Node] {
        guard let node = nodes[id] else { return [] }
        return [node] + children(of: id).flatMap { subtree(of: $0.id) }
    }

    private mutating func link(_ id: NodeID, under parent: NodeID) {
        var siblings = childIndex[parent] ?? []
        let key = sortKey(id)
        let index = siblings.firstIndex { sortKey($0) > key } ?? siblings.endIndex
        siblings.insert(id, at: index)
        childIndex[parent] = siblings
    }

    private mutating func unlink(_ id: NodeID, from parent: NodeID) {
        childIndex[parent]?.removeAll { $0 == id }
    }

    // Ties on order (two clients picking the same key) break on ID, so every replica agrees.
    private func sortKey(_ id: NodeID) -> SortKey { SortKey(order: nodes[id]?.order ?? "", id: id) }

    private mutating func rebuildIndex() {
        childIndex = [:]
        for node in nodes.values {
            guard let parent = node.parent else { continue }
            childIndex[parent, default: []].append(node.id)
        }
        childIndex = childIndex.mapValues { $0.sorted { sortKey($0) < sortKey($1) } }
    }
}

private struct SortKey: Comparable {
    let order: String
    let id: NodeID

    static func < (lhs: SortKey, rhs: SortKey) -> Bool { (lhs.order, lhs.id) < (rhs.order, rhs.id) }
}

/// Undo and redo over edit inverses.
public struct History: Sendable {
    private var undoStack: [Edit] = []
    private var redoStack: [Edit] = []

    public init() {}

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public mutating func perform(_ edit: Edit, on document: inout CanvasDocument) throws {
        undoStack.append(try document.apply(edit))
        redoStack.removeAll()
    }

    public mutating func undo(_ document: inout CanvasDocument) throws {
        guard let inverse = undoStack.popLast() else { return }
        redoStack.append(try document.apply(inverse))
    }

    public mutating func redo(_ document: inout CanvasDocument) throws {
        guard let edit = redoStack.popLast() else { return }
        undoStack.append(try document.apply(edit))
    }
}
