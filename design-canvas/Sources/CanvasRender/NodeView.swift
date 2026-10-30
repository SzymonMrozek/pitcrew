import CanvasCore
import SwiftUI

/// Renders one resolved node with real SwiftUI. Children are keyed by their resolved ID,
/// so an edit re-renders only the views whose node changed.
public struct NodeView: View {
    let node: ResolvedNode

    @Environment(\.canvasTokens) private var tokens
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.canvasFrames) private var frames

    public init(_ node: ResolvedNode) { self.node = node }

    private var styling: Styling { Styling(tokens: tokens, mode: colorScheme == .dark ? "dark" : "light") }

    public var body: some View {
        // A modifier on a Section turns it into a single row, so sections stay bare
        // for List to see. Their rows and header are measured instead.
        if node.kind == .section {
            content
        } else {
            content
                .modifier(CommonModifiers(node: node, styling: styling))
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                    frames?.report(node.id, frame: $0)
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch node.kind {
        case .page, .component, .instance:
            EmptyView()
        case .screen:
            VStack(spacing: 0) { children }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        case .navigationStack:
            NavigationStack {
                VStack(spacing: 0) { children }
                    .navigationTitle(node[.title]?.string ?? "")
            }
        case .list:
            List { children }
                .modifier(ListStyleModifier(style: node[.style]?.string))
        case .section:
            if let title = node[.title]?.string {
                Section(title) { children }
            } else {
                Section { children }
            }
        case .scroll:
            ScrollView { VStack(spacing: styling.number(node[.spacing])) { children } }
        case .vstack:
            VStack(alignment: Styling.alignment(node[.alignment]), spacing: styling.number(node[.spacing])) {
                children
            }
        case .hstack:
            HStack(alignment: Styling.verticalAlignment(node[.alignment]), spacing: styling.number(node[.spacing])) {
                children
            }
        case .zstack:
            ZStack { children }
        case .spacer:
            Spacer(minLength: 0)
        case .text:
            Text(node[.text]?.string ?? "")
        case .image:
            Image(systemName: node[.symbol]?.string ?? "questionmark.square.dashed")
        case .label:
            Label(node[.title]?.string ?? "", systemImage: node[.symbol]?.string ?? "circle")
        case .rectangle:
            RoundedRectangle(cornerRadius: styling.number(node[.cornerRadius]) ?? 0)
                .fill(styling.color(node[.fill]) ?? .secondary)
        case .button:
            Button(node[.title]?.string ?? "Button") {}
                .modifier(ButtonStyleModifier(style: node[.style]?.string))
        case .toggle:
            Toggle(node[.title]?.string ?? "", isOn: .constant(node[.isOn]?.bool ?? false))
        }
    }

    private var children: some View {
        ForEach(node.children) { NodeView($0) }
    }
}

/// Fixed modifier order, which is also the order code export writes them in. A prop
/// that isn't set adds no modifier, so fonts and colors inherit like in hand-written SwiftUI.
private struct CommonModifiers: ViewModifier {
    let node: ResolvedNode
    let styling: Styling

    func body(content: Content) -> some View {
        let width = styling.number(node[.width])
        let height = styling.number(node[.height])
        let frame: CGSize? = width == nil && height == nil ? nil : CGSize(width: width ?? -1, height: height ?? -1)
        content
            .ifLet(styling.font(node[.font], weight: node[.weight])) { $0.font($1) }
            .ifLet(styling.color(node[.foreground])) { $0.foregroundStyle($1) }
            .ifLet(styling.number(node[.padding])) { $0.padding($1) }
            .ifLet(frame) { view, size in
                view.frame(width: size.width < 0 ? nil : size.width, height: size.height < 0 ? nil : size.height)
            }
            .ifLet(styling.color(node[.background])) { $0.background($1) }
            .ifLet(node.kind == .rectangle ? nil : styling.number(node[.cornerRadius])) {
                $0.clipShape(RoundedRectangle(cornerRadius: $1))
            }
            .ifLet(styling.number(node[.opacity])) { $0.opacity(Double($1)) }
    }
}

extension View {
    @ViewBuilder
    func ifLet<T, Modified: View>(_ value: T?, _ transform: (Self, T) -> Modified) -> some View {
        if let value { transform(self, value) } else { self }
    }
}

private struct ListStyleModifier: ViewModifier {
    let style: String?

    func body(content: Content) -> some View {
        switch style {
        case "plain": content.listStyle(.plain)
        #if os(iOS)
        case "grouped": content.listStyle(.grouped)
        case "insetGrouped": content.listStyle(.insetGrouped)
        #endif
        default: content
        }
    }
}

private struct ButtonStyleModifier: ViewModifier {
    let style: String?

    func body(content: Content) -> some View {
        switch style {
        case "bordered": content.buttonStyle(.bordered)
        case "borderedProminent": content.buttonStyle(.borderedProminent)
        case "plain": content.buttonStyle(.plain)
        default: content
        }
    }
}
