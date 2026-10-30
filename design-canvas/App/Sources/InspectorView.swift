import CanvasCore
import SwiftUI

struct InspectorView: View {
    @Bindable var store: EditorStore

    var body: some View {
        Form {
            if let node = store.selectedNode {
                NodeInspector(node: node, store: store)
            } else {
                TokensInspector(tokens: store.document.tokens)
            }
            if let error = store.lastError {
                Section("Last error") { Text(error).foregroundStyle(.red).font(.footnote) }
            }
        }
    }
}

private struct NodeInspector: View {
    let node: ResolvedNode
    let store: EditorStore

    var body: some View {
        Section("Node") {
            LabeledContent("Kind", value: node.kind.rawValue)
            LabeledContent("Source", value: node.source.rawValue)
            if let instance = node.instance {
                LabeledContent("Instance", value: instance.rawValue)
            }
        }
        Section("Properties") {
            ForEach(node.props.keys.sorted(), id: \.self) { prop in
                PropRow(prop: prop, value: node[prop]) { store.set(prop, to: $0, on: node) }
            }
        }
    }
}

private struct PropRow: View {
    let prop: Prop
    let value: Value?
    let commit: (Value?) -> Void
    @State private var draft = ""

    var body: some View {
        switch value {
        case .string(let string):
            TextField(prop.rawValue, text: $draft)
                .onAppear { draft = string }
                .onChange(of: string) { draft = string }
                .onSubmit { commit(.string(draft)) }
                .overlay(alignment: .leading) { label }
        case .number(let number):
            TextField(prop.rawValue, text: $draft)
                .keyboardType(.decimalPad)
                .onAppear { draft = number.formatted() }
                .onChange(of: number) { draft = number.formatted() }
                .onSubmit { Double(draft).map { commit(.number($0)) } }
                .overlay(alignment: .leading) { label }
        case .bool(let bool):
            Toggle(prop.rawValue, isOn: Binding(get: { bool }, set: { commit(.bool($0)) }))
        case .color, .token, nil:
            LabeledContent(prop.rawValue, value: value?.description ?? "–")
        }
    }

    private var label: some View {
        Text(prop.rawValue).foregroundStyle(.secondary).font(.caption).offset(y: -18)
    }
}

private struct TokensInspector: View {
    let tokens: TokenSet

    var body: some View {
        Section("Tokens") {
            ForEach(tokens.tokens.keys.sorted(), id: \.self) { id in
                LabeledContent(id.rawValue) {
                    Text(tokens.modes.map { describe(id, mode: $0) }.joined(separator: " · "))
                        .font(.caption.monospaced())
                }
            }
        }
    }

    private func describe(_ id: TokenID, mode: String) -> String {
        switch try? tokens.resolve(id, mode: mode) {
        case .color(let rgba): rgba.hex
        case .system(let name): name
        case .number(let number): number.formatted()
        case .textStyle(let style): style
        case .alias(let target): "→ \(target)"
        case nil: "?"
        }
    }
}
