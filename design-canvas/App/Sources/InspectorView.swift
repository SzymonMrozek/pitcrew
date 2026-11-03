import CanvasCore
import CanvasRender
import SwiftUI

struct InspectorView: View {
    @Bindable var store: EditorStore
    @State private var tab = Tab.inspect

    enum Tab: String, CaseIterable {
        case inspect = "Inspect"
        case assets = "Assets"
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Panel", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Form {
                switch tab {
                case .inspect: inspect
                case .assets: AssetsView(store: store)
                }
                if let error = store.lastError {
                    Section("Last error") { Text(error).foregroundStyle(.red).font(.footnote) }
                }
            }
        }
        .onChange(of: store.selectedThread) { if store.selectedThread != nil { tab = .inspect } }
    }

    @ViewBuilder
    private var inspect: some View {
        if let id = store.selectedThread, let thread = store.comments.threads[id] {
            ThreadInspector(thread: thread, store: store)
        } else if let context = store.context(of: store.selection) {
            NodeInspector(context: context, store: store)
        } else {
            Section {
                Text("Select an element on the canvas to see its component, layout, typography and colors.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            CommentList(store: store)
        }
    }
}

// MARK: - Node

private struct NodeInspector: View {
    let context: EditorStore.NodeContext
    let store: EditorStore

    private var node: ResolvedNode { context.node }

    var body: some View {
        header
        if let component = store.component(of: context) {
            ComponentSection(component: component, store: store)
        }
        ForEach([PropGroup.content, .layout, .typography, .color], id: \.self) { group in
            PropSection(group: group, context: context, store: store)
        }
        MeasuredSection(context: context, store: store)
    }

    private var header: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: store.component(of: context)?.isRoot == true ? "diamond" : node.kind.symbol)
                    .font(.title3)
                    .foregroundStyle(store.component(of: context) == nil ? Color.secondary : Color.purple)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            if !context.ancestors.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(context.ancestors.enumerated()), id: \.element.id) { index, ancestor in
                            if index > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                            Button(store.displayName(of: ancestor)) {
                                store.select(Selection(item: context.item.id, node: ancestor.id))
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        }
                    }
                }
            }
        }
    }

    private var title: String {
        if let component = store.component(of: context), component.isRoot { return component.name }
        return node.displayName
    }

    private var subtitle: String {
        let kind = node.kind.title
        if let component = store.component(of: context) {
            if component.isRoot { return component.instance == nil ? "Main component" : "\(kind) · instance" }
            return "\(kind) in ◇ \(component.name)"
        }
        return node.kind.isSystemControl ? "\(kind) · system control" : kind
    }
}

private struct ComponentSection: View {
    let component: EditorStore.ComponentInfo
    let store: EditorStore

    var body: some View {
        Section("Component") {
            LabeledContent("◇ \(component.name)") {
                if component.instance != nil {
                    Button("Show main") { store.showMainComponent(component.id) }
                        .buttonStyle(.borderless)
                } else {
                    Text(instancesLabel(store.instanceCount(of: component.id))).foregroundStyle(.secondary)
                }
            }
            if component.isRoot, let instance = component.instance {
                let overrides = instance.overrides.sorted { $0.key < $1.key }
                if overrides.isEmpty {
                    Text("No overrides: this instance looks like its component.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(overrides, id: \.key) { target, props in
                    ForEach(props.keys.sorted(), id: \.self) { prop in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(target.rawValue.split(separator: ".").last.map(String.init) ?? target.rawValue).font(.callout)
                                Text(prop.rawValue).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(props[prop]?.plain ?? "").lineLimit(1).foregroundStyle(.secondary)
                            Button("Reset", systemImage: "arrow.uturn.backward") {
                                store.perform(.override(instance.id, target: target, prop, nil))
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Reset to the component's value")
                        }
                    }
                }
            }
        }
    }
}

private struct PropSection: View {
    let group: PropGroup
    let context: EditorStore.NodeContext
    let store: EditorStore

    private var node: ResolvedNode { context.node }
    private var props: [Prop] { node.kind.props.filter { $0.group == group } }
    private var setProps: [Prop] { props.filter { node[$0] != nil } }
    private var unsetProps: [Prop] { props.filter { node[$0] == nil } }

    var body: some View {
        if !props.isEmpty {
            Section {
                ForEach(setProps, id: \.self) { prop in
                    PropRow(prop: prop, node: node, store: store)
                }
                inherited
            } header: {
                HStack {
                    Text(group.title)
                    Spacer()
                    if !unsetProps.isEmpty {
                        Menu {
                            ForEach(unsetProps, id: \.self) { prop in
                                Button(prop.label) { store.set(prop, to: defaultValue(for: prop), on: node) }
                            }
                        } label: {
                            Image(systemName: "plus")
                        }
                        .menuIndicator(.hidden)
                        .help("Add a property")
                    }
                }
            }
        }
    }

    /// What the node gets from its ancestors or the system when it sets nothing itself.
    @ViewBuilder
    private var inherited: some View {
        let tokens = store.document.tokens
        switch group {
        case .typography where node[.font] == nil && node.kind.showsText:
            let source = context.ancestors.last { $0[.font] != nil }
            let style = source.flatMap { StyleInfo.textStyle($0[.font], tokens: tokens) } ?? "body"
            let weight = node[.weight]?.string ?? source?[.weight]?.string
            Inherited(
                label: "font",
                value: StyleInfo.font(style: style, weight: weight),
                from: source.map { "from \(store.displayName(of: $0))" } ?? "system default · \(style)"
            )
        case .typography where node.kind.showsText:
            if let style = StyleInfo.textStyle(node[.font], tokens: tokens) {
                Text(StyleInfo.font(style: style, weight: node[.weight]?.string))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        case .color where node[.foreground] == nil && node.kind.showsText:
            let source = context.ancestors.last { $0[.foreground] != nil }
            Inherited(
                label: "foreground",
                value: source.flatMap { $0[.foreground]?.plain } ?? "label",
                from: source.map { "from \(store.displayName(of: $0))" } ?? "system default"
            )
        default:
            EmptyView()
        }
    }

    private func defaultValue(for prop: Prop) -> Value {
        if prop == .maxWidth || prop == .maxHeight { return .string("infinity") }
        if let kind = prop.tokenKind, let token = store.document.tokens.ids(of: kind).first { return .token(token) }
        return switch prop {
        case .isOn: .bool(false)
        case .alignment: .string("center")
        case .weight: .string("regular")
        case .style: .string(node.kind == .list ? "insetGrouped" : "bordered")
        case .padding, .paddingHorizontal, .paddingVertical: .number(16)
        case .frameAlignment: .string("leading")
        case .multilineTextAlignment: .string("center")
        case .borderWidth: .number(1)
        case .shadowRadius: .number(10)
        case .shadowY: .number(4)
        case .opacity: .number(1)
        case .width, .height: .number(44)
        case .spacing, .cornerRadius: .number(8)
        case .font: .string("body")
        case .foreground, .background, .fill: .string("label")
        default: .string("")
        }
    }
}

private struct Inherited: View {
    let label: String
    let value: String
    let from: String

    var body: some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 1) {
                Text(value).font(.caption.monospaced())
                Text(from).font(.caption2).foregroundStyle(.tertiary)
            }
        } label: {
            Text(label).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Property rows

/// One property: a token chip when bound to the design system, an editor plus a
/// "no token" mark when it holds a literal of a kind the design system covers.
private struct PropRow: View {
    let prop: Prop
    let node: ResolvedNode
    let store: EditorStore

    private var value: Value? { node[prop] }
    private var tokens: TokenSet { store.document.tokens }
    private var candidates: [TokenID] { prop.tokenKind.map(tokens.ids(of:)) ?? [] }
    private var isOverridden: Bool { node.instance != node.source && store.override(of: prop, on: node) != nil }

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                editor
                menu
            }
        } label: {
            HStack(spacing: 4) {
                Text(prop.label)
                if isOverridden {
                    Circle().fill(.purple).frame(width: 6, height: 6).help("Overridden in this instance")
                }
            }
        }
    }

    @ViewBuilder
    private var editor: some View {
        switch value {
        case .token(let id):
            TokenChip(id: id, tokens: tokens)
        case .number(let number):
            NumberField(value: number) { set(.number($0), live: true) }
            unboundMark
        case .color(let rgba):
            ColorPicker(prop.label, selection: Binding(get: { Color(hex: rgba.hex) }, set: { set(.color(RGBA($0))) }))
                .labelsHidden()
            Text(rgba.hex).font(.caption.monospaced()).foregroundStyle(.secondary)
            unboundMark
        case .string(let string) where prop.tokenKind == .color:
            Swatch(light: StyleInfo.hex(value, tokens: tokens, dark: false), dark: StyleInfo.hex(value, tokens: tokens, dark: true))
            Text(string).font(.caption.monospaced())
            unboundMark
        case .string(let string) where prop == .font:
            Picker(prop.label, selection: Binding(get: { string }, set: { set(.string($0)) })) {
                ForEach(StyleInfo.textStyles, id: \.self) { Text($0) }
            }
            .labelsHidden()
            unboundMark
        case .string(let string) where prop.options != nil:
            Picker(prop.label, selection: Binding(get: { string }, set: { set(.string($0)) })) {
                ForEach(prop.options ?? [], id: \.self) { Text($0) }
            }
            .labelsHidden()
        case .string(let string):
            TextDraftField(value: string) { set(.string($0), live: true) }
        case .bool(let bool):
            Toggle(prop.label, isOn: Binding(get: { bool }, set: { set(.bool($0)) })).labelsHidden()
        case nil:
            EmptyView()
        }
    }

    /// Marks a literal that could come from the design system, like Figma's detached style.
    @ViewBuilder
    private var unboundMark: some View {
        if !candidates.isEmpty {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .help("Not from the design system. Pick a token.")
        }
    }

    private var menu: some View {
        Menu {
            if !candidates.isEmpty {
                Section("Tokens") {
                    ForEach(candidates, id: \.self) { id in
                        Toggle(isOn: Binding(get: { value == .token(id) }, set: { _ in set(.token(id)) })) {
                            Text(id.rawValue)
                            Text(TokenChip.summary(id, tokens: tokens))
                        }
                    }
                }
            }
            if case .token(let id) = value, let literal = tokens.literal(id) {
                Button("Detach from token", systemImage: "link.badge.plus") { set(literal) }
            }
            if isOverridden {
                Button("Reset to component", systemImage: "arrow.uturn.backward") { store.resetOverride(prop, on: node) }
            }
            Button("Remove", systemImage: "minus.circle", role: .destructive) { set(nil) }
        } label: {
            Image(systemName: candidates.isEmpty ? "ellipsis" : "circle.hexagongrid")
                .foregroundStyle(.secondary)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help(candidates.isEmpty ? "More" : "Tokens")
    }

    private func set(_ value: Value?, live: Bool = false) { store.set(prop, to: value, on: node, live: live) }
}

/// A token reference: its name and what it resolves to, with a swatch for colors.
private struct TokenChip: View {
    let id: TokenID
    let tokens: TokenSet

    var body: some View {
        let kind = tokens.kind(of: id)
        HStack(spacing: 5) {
            if kind == .color {
                Swatch(light: StyleInfo.hex(.token(id), tokens: tokens, dark: false), dark: StyleInfo.hex(.token(id), tokens: tokens, dark: true))
            }
            Text(id.rawValue).font(.caption.monospaced())
            if kind != .color {
                Text(Self.summary(id, tokens: tokens)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .foregroundStyle(kind == nil ? Color.red : Color.primary)
        .lineLimit(1)
        .help(kind == nil ? "Missing token" : "\(id.rawValue): \(Self.summary(id, tokens: tokens))")
    }

    static func summary(_ id: TokenID, tokens: TokenSet) -> String {
        var parts: [String] = []
        if case .alias(let target)? = tokens.tokens[id]?.values[TokenSet.defaultMode] { parts.append("→ \(target)") }
        switch try? tokens.resolve(id, mode: TokenSet.defaultMode) {
        case .color(let rgba): parts.append(rgba.hex)
        case .system(let name): parts.append(name)
        case .number(let number): parts.append(number.formatted())
        case .textStyle(let style): parts.append(style)
        case .alias, nil: parts.append("missing")
        }
        return parts.joined(separator: " ")
    }
}

/// Light and dark halves of a color.
private struct Swatch: View {
    let light: String?
    let dark: String?

    var body: some View {
        HStack(spacing: 0) {
            Color(hex: light ?? "#00000000")
            Color(hex: dark ?? light ?? "#00000000")
        }
        .frame(width: 16, height: 16)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
    }
}

private struct NumberField: View {
    let value: Double
    let commit: (Double) -> Void
    @State private var draft = ""

    var body: some View {
        TextField("0", text: $draft)
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.trailing)
            .frame(width: 64)
            .onAppear { draft = value.formatted() }
            .onChange(of: value) { if parsed != value { draft = value.formatted() } }
            // Live, like Figma: the canvas follows every keystroke.
            .onChange(of: draft) { if let parsed, parsed != value { commit(parsed) } }
    }

    private var parsed: Double? {
        Double(draft.replacingOccurrences(of: ",", with: ".").filter { !$0.isWhitespace })
    }
}

private struct TextDraftField: View {
    let value: String
    let commit: (String) -> Void
    @State private var draft = ""

    var body: some View {
        TextField("Text", text: $draft)
            .multilineTextAlignment(.trailing)
            .onAppear { draft = value }
            .onChange(of: value) { if draft != value { draft = value } }
            // Live, like Figma: the canvas follows every keystroke.
            .onChange(of: draft) { if draft != value { commit(draft) } }
    }
}

// MARK: - Measured

private struct MeasuredSection: View {
    let context: EditorStore.NodeContext
    let store: EditorStore

    var body: some View {
        let frames = store.frames(of: context.item.id)
        if let frame = frames[context.node.id] {
            Section {
                LabeledContent("Size", value: "\(frame.width.rounded1) × \(frame.height.rounded1)")
                LabeledContent("Position", value: "\(frame.minX.rounded1), \(frame.minY.rounded1)")
                if let spacing = store.selectedSpacing {
                    ForEach(spacing.insets, id: \.side) { inset in
                        LabeledContent("\(Self.arrows[inset.side] ?? "") \(inset.side.rawValue.capitalized)") {
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(inset.value.rounded1).font(.callout.monospacedDigit())
                                Text(spacing.inRow ? "to its row" : "to \(name(of: inset.container))")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let gap = spacing.previous { gapRow("Gap before", gap) }
                    if let gap = spacing.next { gapRow("Gap after", gap) }
                }
            } header: {
                Text("Measured")
            } footer: {
                Text("Padding to the parent, from the layout, system insets included. Hold ⌥ and point at another element to measure to it.")
            }
        }
    }

    private static let arrows: [Spacing.Side: String] = [.leading: "←", .trailing: "→", .top: "↑", .bottom: "↓"]

    private func name(of id: String) -> String {
        context.path.first { $0.id == id }.map(store.displayName(of:)) ?? id
    }

    private func gapRow(_ label: String, _ gap: Spacing.Gap) -> some View {
        let name = context.tree.first { $0.id == gap.sibling }.map(store.displayName(of:)) ?? gap.sibling
        return LabeledContent(label) {
            Text("\(gap.value.rounded1)  ·  \(name)").font(.callout.monospacedDigit())
        }
    }
}

// MARK: - Assets

private struct AssetsView: View {
    let store: EditorStore

    var body: some View {
        let tokens = store.document.tokens
        let usage = store.document.tokenUsage()
        Section {
            ForEach(store.components, id: \.id) { component in
                HStack {
                    Button {
                        store.showMainComponent(component.id)
                    } label: {
                        HStack {
                            Image(systemName: "diamond").foregroundStyle(.purple)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(store.name(ofComponent: component.id))
                                Text(instancesLabel(store.instanceCount(of: component.id)))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button("Insert", systemImage: "plus.square.on.square") { store.insertInstance(of: component.id) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .disabled(!store.canInsertInstance)
                        .help("Insert an instance after the selected element")
                }
            }
        } header: {
            Text("Components")
        } footer: {
            Text(store.canInsertInstance ? "Insert places an instance after the selected element." : "Select an element on a screen to insert an instance after it.")
        }
        ForEach(TokenKind.allCases, id: \.self) { kind in
            Section(kind.title) {
                ForEach(tokens.ids(of: kind), id: \.self) { id in
                    HStack(spacing: 8) {
                        if kind == .color {
                            Swatch(light: StyleInfo.hex(.token(id), tokens: tokens, dark: false), dark: StyleInfo.hex(.token(id), tokens: tokens, dark: true))
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(id.rawValue).font(.callout.monospaced())
                            Text(summary(id, kind: kind, tokens: tokens)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(usage[id] ?? 0)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .help("Uses")
                    }
                }
            }
        }
    }

    private func summary(_ id: TokenID, kind: TokenKind, tokens: TokenSet) -> String {
        switch kind {
        case .color:
            let modes = tokens.modes.compactMap { StyleInfo.hex(.token(id), tokens: tokens, dark: $0 == "dark") }
            var alias = ""
            if case .alias(let target)? = tokens.tokens[id]?.values[TokenSet.defaultMode] { alias = "→ \(target) · " }
            if case .system(let name)? = try? tokens.resolve(id, mode: TokenSet.defaultMode) { alias += "\(name) · " }
            return alias + modes.joined(separator: " / ")
        case .textStyle:
            let base = TokenChip.summary(id, tokens: tokens)
            guard let style = StyleInfo.textStyle(.token(id), tokens: tokens) else { return base }
            return "\(base) · \(StyleInfo.font(style: style, weight: nil))"
        case .number:
            return TokenChip.summary(id, tokens: tokens)
        }
    }
}

// MARK: - Comments

private struct ThreadInspector: View {
    let thread: CommentThread
    let store: EditorStore
    @State private var reply = ""

    var body: some View {
        Section("Comment \(store.comments.number(of: thread.id) ?? 0)") {
            if let node = thread.anchor.node {
                LabeledContent("Pinned to", value: node.node)
                    .font(.caption)
            } else {
                LabeledContent("Pinned at", value: "\(Int(thread.anchor.x)), \(Int(thread.anchor.y))")
                    .font(.caption)
            }
            ForEach(thread.comments) { comment in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(comment.author).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(comment.createdAt, format: .relative(presentation: .named))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(comment.body)
                }
                .padding(.vertical, 2)
            }
            TextField("Reply", text: $reply, axis: .vertical)
                .onSubmit(send)
            Button("Reply", action: send)
                .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        Section {
            Button(thread.isResolved ? "Reopen" : "Resolve", systemImage: thread.isResolved ? "arrow.uturn.backward" : "checkmark.circle") {
                store.setResolved(thread.id, !thread.isResolved)
            }
            Button("Delete thread", systemImage: "trash", role: .destructive) { store.deleteThread(thread.id) }
        }
    }

    private func send() {
        store.reply(to: thread.id, reply)
        reply = ""
    }
}

private struct CommentList: View {
    let store: EditorStore

    var body: some View {
        let threads = store.comments.ordered
        if !threads.isEmpty {
            Section("Comments") {
                ForEach(threads) { thread in
                    Button {
                        store.selectThread(thread.id)
                    } label: {
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(store.comments.number(of: thread.id) ?? 0)")
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .foregroundStyle(thread.isResolved ? Color.secondary : Color.accentColor)
                            VStack(alignment: .leading) {
                                Text(thread.title).lineLimit(2)
                                Text("\(thread.comments.count) · \(thread.comments.last?.author ?? "")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .opacity(thread.isResolved ? 0.5 : 1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Labels

private func instancesLabel(_ count: Int) -> String { count == 1 ? "1 instance" : "\(count) instances" }

extension Node.Kind {
    var title: String {
        switch self {
        case .navigationStack: "NavigationStack"
        case .vstack: "VStack"
        case .hstack: "HStack"
        case .zstack: "ZStack"
        case .scroll: "ScrollView"
        default: rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }

    var symbol: String {
        switch self {
        case .page, .screen: "iphone"
        case .component, .instance: "diamond"
        case .navigationStack: "rectangle.topthird.inset.filled"
        case .list, .section: "list.bullet.rectangle"
        case .scroll: "scroll"
        case .vstack: "square.split.1x2"
        case .hstack: "square.split.2x1"
        case .zstack: "square.stack"
        case .spacer: "arrow.left.and.right"
        case .text: "textformat"
        case .image: "photo"
        case .label: "tag"
        case .rectangle: "rectangle"
        case .button: "button.horizontal"
        case .toggle: "switch.2"
        }
    }

    /// Views whose look and spacing come from the system, not the document.
    var isSystemControl: Bool { [.navigationStack, .list, .section, .button, .toggle].contains(self) }

    /// Kinds that draw text or symbols, so font and foreground apply to them.
    var showsText: Bool { [.text, .image, .label, .button, .toggle].contains(self) }
}

extension ResolvedNode {
    var displayName: String {
        if let title = self[.title]?.string, !title.isEmpty { return title }
        if kind == .text, let text = self[.text]?.string, !text.isEmpty { return "“\(text.prefix(24))”" }
        if kind == .image, let symbol = self[.symbol]?.string { return symbol }
        if let name = self[.name]?.string { return name }
        return kind.title
    }
}

extension PropGroup {
    var title: String {
        switch self {
        case .content: "Content"
        case .layout: "Layout"
        case .typography: "Typography"
        case .color: "Colors"
        case .other: "Other"
        }
    }
}

extension TokenKind {
    var title: String {
        switch self {
        case .color: "Color tokens"
        case .number: "Number tokens"
        case .textStyle: "Text style tokens"
        }
    }
}

extension Prop {
    var label: String { rawValue }

    /// Fixed choices for props that take a keyword.
    var options: [String]? {
        switch self {
        case .alignment, .frameAlignment:
            ["leading", "center", "trailing", "top", "bottom", "topLeading", "topTrailing", "bottomLeading", "bottomTrailing"]
        case .multilineTextAlignment: ["leading", "center", "trailing"]
        case .weight: StyleInfo.weights
        case .style: ["plain", "grouped", "insetGrouped", "bordered", "borderedProminent"]
        default: nil
        }
    }
}

extension Value {
    /// The value without JSON quoting, for display.
    var plain: String {
        switch self {
        case .string(let value): value
        case .token(let id): id.rawValue
        default: description
        }
    }
}

extension CGFloat {
    /// One decimal at most: `16`, `20.3`.
    var rounded1: String { ((self * 10).rounded() / 10).formatted() }
}

extension RGBA {
    init(_ color: Color) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let clamp = { (value: CGFloat) in Double(min(max(value, 0), 1)) }
        self.init(red: clamp(red), green: clamp(green), blue: clamp(blue), alpha: clamp(alpha))
    }
}
