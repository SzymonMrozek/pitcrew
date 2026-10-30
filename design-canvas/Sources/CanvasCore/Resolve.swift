/// A node with instances expanded: what the renderer draws and the inspector shows.
public struct ResolvedNode: Hashable, Sendable, Identifiable {
    /// Unique within one resolved tree: the instance path plus the source node,
    /// for example `profile/settingRow.title`.
    public let id: String
    /// The document node that defines this node.
    public let source: NodeID
    /// The nearest instance this node was expanded from. Edits to a node inside
    /// an instance become overrides on this instance.
    public let instance: NodeID?
    public let kind: Node.Kind
    public let props: [Prop: Value]
    public let children: [ResolvedNode]

    public subscript(prop: Prop) -> Value? { props[prop] }

    public func first(where predicate: (ResolvedNode) -> Bool) -> ResolvedNode? {
        if predicate(self) { return self }
        for child in children {
            if let match = child.first(where: predicate) { return match }
        }
        return nil
    }
}

public enum ResolveError: Error, Equatable {
    case unknownNode(NodeID)
    case unknownComponent(NodeID)
    case componentWithoutRoot(NodeID)
    case componentCycle(NodeID)
}

extension CanvasDocument {
    public func resolve(_ id: NodeID) throws -> ResolvedNode {
        try resolve(id, path: "", instance: nil, overrides: [:], expanding: [])
    }

    private func resolve(
        _ id: NodeID,
        path: String,
        instance: NodeID?,
        overrides: [NodeID: [Prop: Value]],
        expanding: Set<NodeID>
    ) throws -> ResolvedNode {
        guard let node = nodes[id] else { throw ResolveError.unknownNode(id) }
        let props = node.props.merging(overrides[id] ?? [:]) { _, override in override }

        if node.kind == .instance {
            return try expand(node, props: props, path: path, expanding: expanding)
        }

        let resolvedID = path.isEmpty ? id.rawValue : "\(path)/\(id.rawValue)"
        let children = try children(of: id).map {
            try resolve($0.id, path: path, instance: instance, overrides: overrides, expanding: expanding)
        }
        return ResolvedNode(
            id: resolvedID, source: id, instance: instance, kind: node.kind, props: props, children: children
        )
    }

    /// An instance resolves to its component's root with the instance's props on top
    /// and the instance's overrides applied to the component's inner nodes.
    private func expand(
        _ instance: Node,
        props: [Prop: Value],
        path: String,
        expanding: Set<NodeID>
    ) throws -> ResolvedNode {
        guard let componentID = props[.component]?.string.map(NodeID.init(_:)),
            let component = nodes[componentID], component.kind == .component
        else { throw ResolveError.unknownComponent(instance.id) }
        guard !expanding.contains(componentID) else { throw ResolveError.componentCycle(componentID) }
        guard let root = children(of: componentID).first else { throw ResolveError.componentWithoutRoot(componentID) }

        let instancePath = path.isEmpty ? instance.id.rawValue : "\(path)/\(instance.id.rawValue)"
        let resolvedRoot = try resolve(
            root.id,
            path: instancePath,
            instance: instance.id,
            overrides: instance.overrides,
            expanding: expanding.union([componentID])
        )
        var rootProps = resolvedRoot.props
        for (prop, value) in props where prop != .component && prop != .name { rootProps[prop] = value }
        return ResolvedNode(
            id: instancePath,
            source: instance.id,
            instance: instance.id,
            kind: resolvedRoot.kind,
            props: rootProps,
            children: resolvedRoot.children
        )
    }
}
