/// One node of the document tree. The kinds are a subset of SwiftUI, so a screen
/// renders with the real framework and exports to code without guessing.
public struct Node: Hashable, Codable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Codable, Sendable, CaseIterable {
        /// The canvas page. Its children are screens and components placed at `x`/`y`.
        case page
        /// A device-sized frame rendered with its own environment.
        case screen
        /// A reusable definition with exactly one root child.
        case component
        /// A use of a component. Its own props apply to the component's root,
        /// and `overrides` change the component's inner nodes.
        case instance

        case navigationStack, list, section, scroll
        case vstack, hstack, zstack, spacer
        case text, image, label, rectangle, button, toggle
    }

    public var id: NodeID
    public var kind: Kind
    public var parent: NodeID?
    /// Sort key among siblings, see `FractionalIndex`.
    public var order: String
    public var props: [Prop: Value]
    /// Instance only: component child -> props that replace the component's values.
    public var overrides: [NodeID: [Prop: Value]]

    public init(
        id: NodeID = .random(),
        kind: Kind,
        parent: NodeID? = nil,
        order: String = "",
        props: [Prop: Value] = [:],
        overrides: [NodeID: [Prop: Value]] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.parent = parent
        self.order = order
        self.props = props
        self.overrides = overrides
    }

    public subscript(prop: Prop) -> Value? {
        get { props[prop] }
        set { props[prop] = newValue }
    }
}
