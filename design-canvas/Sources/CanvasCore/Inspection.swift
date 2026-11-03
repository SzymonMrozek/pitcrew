import Foundation

/// What a token stands for once aliases are followed. A property accepts tokens of one
/// kind, which is how the inspector filters the token picker.
public enum TokenKind: String, CaseIterable, Codable, Sendable {
    case color
    case number
    case textStyle
}

extension TokenValue {
    /// The kind of a concrete value; nil for an alias, which takes its target's kind.
    public var kind: TokenKind? {
        switch self {
        case .color, .system: .color
        case .number: .number
        case .textStyle: .textStyle
        case .alias: nil
        }
    }
}

extension TokenSet {
    public func kind(of id: TokenID) -> TokenKind? {
        (try? resolve(id, mode: Self.defaultMode))?.kind
    }

    /// Tokens of one kind, sorted by ID.
    public func ids(of kind: TokenKind) -> [TokenID] {
        tokens.keys.filter { self.kind(of: $0) == kind }.sorted()
    }

    /// Tokens of one kind, grouped by the ID up to its last dot: `color.text.ink` is in
    /// `color.text`, `space.4` in `space`. Groups and their tokens are sorted by ID.
    public func groups(of kind: TokenKind) -> [(name: String, ids: [TokenID])] {
        var groups: [(name: String, ids: [TokenID])] = []
        for id in ids(of: kind) {
            let name = id.rawValue.lastIndex(of: ".").map { String(id.rawValue[..<$0]) } ?? ""
            if groups.last?.name == name { groups[groups.count - 1].ids.append(id) } else { groups.append((name, [id])) }
        }
        return groups
    }

    /// The literal a token resolves to in a mode, for detaching a property from it.
    public func literal(_ id: TokenID, mode: String = TokenSet.defaultMode) -> Value? {
        switch try? resolve(id, mode: mode) {
        case .color(let rgba): .color(rgba)
        case .system(let name): .string(name)
        case .number(let number): .number(number)
        case .textStyle(let style): .string(style)
        case .alias, nil: nil
        }
    }
}

/// The inspector section a property belongs to.
public enum PropGroup: String, CaseIterable, Sendable {
    case content
    case layout
    case typography
    case color
    case other
}

extension Prop {
    /// The token kind this property takes, or nil when it takes no tokens.
    public var tokenKind: TokenKind? {
        switch self {
        case .foreground, .background, .fill, .border, .shadowColor: .color
        case .spacing, .padding, .paddingHorizontal, .paddingVertical, .width, .height, .maxWidth, .maxHeight,
            .cornerRadius, .borderWidth, .shadowRadius, .shadowY, .opacity: .number
        case .font: .textStyle
        default: nil
        }
    }

    public var group: PropGroup {
        switch self {
        case .text, .title, .symbol, .isOn, .style, .component: .content
        case .spacing, .alignment, .padding, .paddingHorizontal, .paddingVertical, .width, .height, .maxWidth,
            .maxHeight, .frameAlignment, .cornerRadius, .borderWidth, .shadowRadius, .shadowY, .opacity: .layout
        case .font, .weight, .multilineTextAlignment: .typography
        case .foreground, .background, .fill, .border, .shadowColor: .color
        default: .other
        }
    }
}

extension Node.Kind {
    /// Properties the renderer reads for this kind, in inspector order.
    public var props: [Prop] {
        let content: [Prop] = switch self {
        case .text: [.text, .multilineTextAlignment]
        case .image: [.symbol]
        case .label: [.title, .symbol]
        case .button: [.title, .style]
        case .toggle: [.title, .isOn]
        case .navigationStack, .section: [.title]
        case .list: [.style]
        case .vstack, .hstack: [.spacing, .alignment]
        case .zstack: [.alignment]
        case .scroll: [.spacing]
        case .rectangle: [.fill]
        default: []
        }
        // Sections stay bare for List, so they take no modifiers.
        guard self != .section, self != .page, self != .component, self != .instance else { return content }
        return content + [
            .font, .weight, .foreground, .padding, .paddingHorizontal, .paddingVertical, .width, .height, .maxWidth,
            .maxHeight, .frameAlignment, .background, .border, .borderWidth, .cornerRadius, .shadowRadius, .shadowY,
            .shadowColor, .opacity,
        ]
    }
}

extension CanvasDocument {
    /// How many properties and overrides refer to each token, directly.
    public func tokenUsage() -> [TokenID: Int] {
        var usage: [TokenID: Int] = [:]
        func count(_ props: [Prop: Value]) {
            for case .token(let id) in props.values { usage[id, default: 0] += 1 }
        }
        for node in nodes.values {
            count(node.props)
            node.overrides.values.forEach(count)
        }
        for token in tokens.tokens.values {
            for case .alias(let target) in token.values.values { usage[target, default: 0] += 1 }
        }
        return usage
    }
}
