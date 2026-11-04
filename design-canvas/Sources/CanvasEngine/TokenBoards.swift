import CanvasCore
import CoreGraphics

/// A document's tokens drawn as cards, one per group (`color.text`, `space`), for the
/// canvas's Tokens view. Boards are built from the tokens whenever they change and never
/// stored, so they can't drift from the document.
public struct TokenBoard: Sendable {
    /// The group, for example `color.text`.
    public let id: String
    public let title: String
    /// The board's top-left on the page.
    public let origin: CGPoint
    public let root: ResolvedNode
}

extension TokenSet {
    /// One row per kind (colors, then text styles, then numbers), its groups side by side.
    public func boards() -> [TokenBoard] {
        let gap: CGFloat = 48
        let light = LayoutEngine(tokens: self, appearance: .light)
        let dark = LayoutEngine(tokens: self, appearance: .dark)
        var boards: [TokenBoard] = []
        var y: CGFloat = 0
        for kind in [TokenKind.color, .textStyle, .number] {
            var x: CGFloat = 0
            var rowHeight: CGFloat = 0
            for group in groups(of: kind) {
                let name = group.name.isEmpty ? kind.boardTitle : group.name
                var document = CanvasDocument(tokens: self)
                let root = NodeID("tokens.\(name)")
                document.add(root, .vstack, under: CanvasDocument.rootID, [
                    .alignment: .string("leading"), .spacing: .number(12), .maxWidth: .string("infinity"),
                    .frameAlignment: .string("leading"),
                ])
                // Numbers read as a scale, smallest first; the rest stay sorted by name.
                let ids = kind == .number ? group.ids.sorted { (light.number(.token($0)) ?? 0) < (light.number(.token($1)) ?? 0) } : group.ids
                for id in ids {
                    let leaf = group.name.isEmpty ? id.rawValue : String(id.rawValue.dropFirst(group.name.count + 1))
                    document.addRow(for: id, named: leaf, kind: kind, group: group.name, in: root, light: light, dark: dark)
                }
                guard let tree = try? document.resolve(root) else { continue }
                boards.append(TokenBoard(id: name, title: name, origin: CGPoint(x: x, y: y), root: tree))
                x += 360 + gap
                rowHeight = max(rowHeight, light.component(tree).size.height)
            }
            if rowHeight > 0 { y += rowHeight + gap * 2 }
        }
        return boards
    }
}

extension TokenKind {
    fileprivate var boardTitle: String {
        switch self {
        case .color: "color"
        case .number: "number"
        case .textStyle: "type"
        }
    }
}

extension CanvasDocument {
    fileprivate mutating func add(_ id: NodeID, _ kind: Node.Kind, under parent: NodeID, _ props: [Prop: Value] = [:]) {
        _ = try? apply(.insert(Node(id: id, kind: kind, parent: parent, order: appendOrder(in: parent), props: props)))
    }

    private func text(_ string: String, _ style: String, secondary: Bool = false, weight: String? = nil) -> [Prop: Value] {
        var props: [Prop: Value] = [.text: .string(string), .font: .string(style)]
        if secondary { props[.foreground] = .string("secondaryLabel") }
        if let weight { props[.weight] = .string(weight) }
        return props
    }

    /// A color shows its light and dark swatches, a text style a sample in it, a number a
    /// bar as long as its value (a rounded square for radii).
    fileprivate mutating func addRow(
        for token: TokenID, named name: String, kind: TokenKind, group: String, in parent: NodeID,
        light: LayoutEngine, dark: LayoutEngine
    ) {
        let row = NodeID("\(parent).\(name)")
        switch kind {
        case .color:
            add(row, .hstack, under: parent, [.spacing: .number(12)])
            for (mode, engine) in [("light", light), ("dark", dark)] {
                add(NodeID("\(row).\(mode)"), .rectangle, under: row, [
                    .fill: engine.color(.token(token)).map(Value.color) ?? .string("clear"), .width: .number(36), .height: .number(36),
                    .cornerRadius: .number(8), .border: .string("separator"),
                ])
            }
            add(NodeID("\(row).text"), .vstack, under: row, [.alignment: .string("leading"), .spacing: .number(1)])
            add(NodeID("\(row).name"), .text, under: NodeID("\(row).text"), text(name, "callout", weight: "medium"))
            var detail = [light, dark].compactMap { $0.color(.token(token))?.hex }.joined(separator: " / ")
            if case .alias(let target)? = tokens.tokens[token]?.values[TokenSet.defaultMode] { detail = "→ \(target) · " + detail }
            if case .system(let system)? = try? tokens.resolve(token, mode: TokenSet.defaultMode) { detail = "\(system) · " + detail }
            add(NodeID("\(row).detail"), .text, under: NodeID("\(row).text"), text(detail, "caption", secondary: true))
        case .textStyle:
            add(row, .vstack, under: parent, [.alignment: .string("leading"), .spacing: .number(2)])
            add(NodeID("\(row).sample"), .text, under: row, [.text: .string(name), .font: .token(token)])
            let style = light.textStyle(.token(token)) ?? ""
            let size = AppleType.styles[style].map { " \(Int($0.size))" } ?? ""
            let design = light.fontDesign(.token(token)).map { " · \($0)" } ?? ""
            add(NodeID("\(row).detail"), .text, under: row, text("\(style)\(size)\(design)", "caption", secondary: true))
        case .number:
            let value = light.number(.token(token)) ?? 0
            add(row, .hstack, under: parent, [.spacing: .number(12)])
            let isRadius = group.split(separator: ".").last?.lowercased().contains("radius") == true
            add(NodeID("\(row).box"), .hstack, under: row, [.width: .number(isRadius ? 36 : 120), .frameAlignment: .string("leading")])
            if isRadius {
                add(NodeID("\(row).shape"), .rectangle, under: NodeID("\(row).box"), [
                    .fill: .string("tertiarySystemFill"), .width: .number(36), .height: .number(36),
                    .cornerRadius: .number(Double(min(value, 18))), .border: .string("systemBlue"),
                ])
            } else {
                add(NodeID("\(row).bar"), .rectangle, under: NodeID("\(row).box"), [
                    .fill: .string("systemBlue"), .width: .number(Double(min(value, 120))), .height: .number(8),
                    .cornerRadius: .number(4),
                ])
            }
            add(NodeID("\(row).name"), .text, under: row, text(name, "callout", weight: "medium"))
            add(NodeID("\(row).spacer"), .spacer, under: row)
            add(NodeID("\(row).value"), .text, under: row, text(Double(value).formatted(), "callout", secondary: true))
        }
    }
}
