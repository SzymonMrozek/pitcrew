import CanvasCore
import CanvasEngine
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// Renders one resolved node with real SwiftUI: the code a design exports to, running.
/// The preview shows it next to the canvas, so a difference from the engine is visible.
struct NativeNodeView: View {
    let node: ResolvedNode

    @Environment(\.nativeStyling) private var styling

    init(_ node: ResolvedNode) { self.node = node }

    var body: some View {
        // A modifier on a Section turns it into a single row, so sections stay bare
        // for List to see.
        if node.kind == .section {
            content
        } else {
            content.modifier(NativeModifiers(node: node, styling: styling))
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
            ScrollView {
                VStack(alignment: NativeStyling.horizontal(node[.alignment]), spacing: styling.number(node[.spacing])) {
                    children
                }
            }
        case .vstack:
            VStack(alignment: NativeStyling.horizontal(node[.alignment]), spacing: styling.number(node[.spacing])) {
                children
            }
        case .hstack:
            HStack(alignment: NativeStyling.vertical(node[.alignment]), spacing: styling.number(node[.spacing])) {
                children
            }
        case .zstack:
            ZStack(alignment: NativeStyling.alignment(node[.alignment]) ?? .center) { children }
        case .spacer:
            Spacer()
        case .text:
            Text(node[.text]?.string ?? "")
        case .image:
            Image(systemName: node[.symbol]?.string ?? "questionmark.square.dashed")
        case .label:
            Label(node[.title]?.string ?? "", systemImage: node[.symbol]?.string ?? "circle")
        case .rectangle:
            let shape = RoundedRectangle(cornerRadius: styling.number(node[.cornerRadius]) ?? 0)
            if let fill = styling.color(node[.fill]) { shape.fill(fill) } else { shape }
        case .button:
            Button(node[.title]?.string ?? "Button") {}
                .modifier(ButtonStyleModifier(style: node[.style]?.string))
        case .toggle:
            NativeToggle(id: node.id, title: node[.title]?.string ?? "", isOn: node[.isOn]?.bool ?? false)
        }
    }

    private var children: some View {
        ForEach(node.children) { NativeNodeView($0) }
    }
}

/// A toggle that switches when tapped in the preview and follows the document when it changes.
private struct NativeToggle: View {
    let id: String
    let title: String
    let isOn: Bool
    @State private var state: Bool?
    @Environment(\.nativeToggleSwitched) private var switched

    var body: some View {
        Toggle(title, isOn: Binding(get: { state ?? isOn }, set: { state = $0; switched?(id, $0) }))
            .onChange(of: isOn) { state = nil }
    }
}

/// The engine's modifier order (`Pass.place`), which is also the order code export
/// writes them in. A prop that isn't set adds no modifier, so fonts and colors inherit.
private struct NativeModifiers: ViewModifier {
    let node: ResolvedNode
    let styling: NativeStyling

    func body(content: Content) -> some View {
        let all = styling.number(node[.padding])
        let horizontal = styling.number(node[.paddingHorizontal]) ?? all
        let vertical = styling.number(node[.paddingVertical]) ?? all
        let width = styling.number(node[.width])
        let height = styling.number(node[.height])
        let maxWidth = styling.limit(node[.maxWidth])
        let maxHeight = styling.limit(node[.maxHeight])
        let alignment = NativeStyling.alignment(node[.frameAlignment]) ?? .center
        // A rectangle is its own shape; other nodes clip to their rounded corners.
        let radius = styling.number(node[.cornerRadius])
        let clip = node.kind == .rectangle ? nil : radius
        let shadowRadius = styling.number(node[.shadowRadius]).flatMap { $0 > 0 ? $0 : nil }
        content
            .ifLet(styling.font(node[.font], weight: node[.weight])) { $0.font($1) }
            .ifLet(styling.font(node[.font], weight: nil) == nil ? NativeStyling.weight(node[.weight]) : nil) { $0.fontWeight($1) }
            .ifLet(styling.color(node[.foreground])) { $0.foregroundStyle($1) }
            .ifLet(NativeStyling.textAlignment(node[.multilineTextAlignment])) { $0.multilineTextAlignment($1) }
            .ifLet(horizontal) { $0.padding(.horizontal, $1) }
            .ifLet(vertical) { $0.padding(.vertical, $1) }
            .ifLet(width != nil || height != nil ? alignment : nil) { $0.frame(width: width, height: height, alignment: $1) }
            .ifLet(maxWidth != nil || maxHeight != nil ? alignment : nil) {
                $0.frame(maxWidth: maxWidth, maxHeight: maxHeight, alignment: $1)
            }
            .ifLet(styling.color(node[.background])) { $0.background($1) }
            .ifLet(clip) { $0.clipShape(RoundedRectangle(cornerRadius: $1)) }
            .ifLet(styling.color(node[.border])) { view, color in
                view.overlay {
                    RoundedRectangle(cornerRadius: radius ?? 0).strokeBorder(color, lineWidth: styling.number(node[.borderWidth]) ?? 1)
                }
            }
            .ifLet(shadowRadius) { view, radius in
                // SwiftUI's default shadow color is black at a third opacity.
                view.shadow(
                    color: styling.color(node[.shadowColor]) ?? Color(.sRGB, white: 0, opacity: 0.33), radius: radius,
                    y: styling.number(node[.shadowY]) ?? 0
                )
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

extension EnvironmentValues {
    @Entry var nativeStyling = NativeStyling(tokens: TokenSet(), appearance: .light)
    @Entry public var nativeToggleSwitched: NativeToggleAction?
}

/// What a tap that switches a toggle calls, with the toggle's resolved ID. Actions of the
/// same owner are equal, so passing one down doesn't invalidate the screen.
public struct NativeToggleAction: Equatable, Sendable {
    private let owner: ObjectIdentifier
    private let action: @MainActor @Sendable (String, Bool) -> Void

    public init(owner: AnyObject, _ action: @escaping @MainActor @Sendable (String, Bool) -> Void) {
        self.owner = ObjectIdentifier(owner)
        self.action = action
    }

    @MainActor func callAsFunction(_ node: String, _ on: Bool) { action(node, on) }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.owner == rhs.owner }
}

/// Turns document values into SwiftUI values. Numbers, limits and text styles resolve
/// like the engine's; Apple semantic colors become the platform's own dynamic colors.
struct NativeStyling {
    let tokens: TokenSet
    let appearance: Appearance

    private var engine: LayoutEngine { LayoutEngine(tokens: tokens, appearance: appearance) }

    func number(_ value: Value?) -> CGFloat? { engine.number(value) }
    func limit(_ value: Value?) -> CGFloat? { engine.limit(value) }

    func color(_ value: Value?) -> Color? {
        switch value {
        case .color(let rgba): Color(rgba)
        case .string(let name): systemColor(name)
        case .token(let id):
            switch try? tokens.resolve(id, mode: appearance.mode) {
            case .color(let rgba): Color(rgba)
            case .system(let name): systemColor(name)
            default: nil
            }
        default: nil
        }
    }

    /// A text style, or `.system(size:)` for a number, with the weight applied.
    func font(_ value: Value?, weight: Value?) -> Font? {
        let font: Font
        if let style = engine.textStyle(value).flatMap({ NativeStyling.textStyles[$0] }) {
            font = .system(style, design: NativeStyling.designs[engine.fontDesign(value) ?? ""])
        } else if let size = number(value) {
            font = .system(size: size)
        } else {
            return nil
        }
        return NativeStyling.weight(weight).map { font.weight($0) } ?? font
    }

    private func systemColor(_ name: String) -> Color? {
        #if canImport(UIKit)
        if let color = NativeStyling.uiColors[name] { return Color(uiColor: color) }
        #endif
        return AppleColors.color(name, appearance).map(Color.init)
    }

    #if canImport(UIKit)
    private static let uiColors: [String: UIColor] = [
        "label": .label, "secondaryLabel": .secondaryLabel, "tertiaryLabel": .tertiaryLabel,
        "quaternaryLabel": .quaternaryLabel, "systemBackground": .systemBackground,
        "secondarySystemBackground": .secondarySystemBackground, "tertiarySystemBackground": .tertiarySystemBackground,
        "systemGroupedBackground": .systemGroupedBackground,
        "secondarySystemGroupedBackground": .secondarySystemGroupedBackground,
        "tertiarySystemGroupedBackground": .tertiarySystemGroupedBackground, "separator": .separator,
        "opaqueSeparator": .opaqueSeparator, "systemFill": .systemFill, "secondarySystemFill": .secondarySystemFill,
        "tertiarySystemFill": .tertiarySystemFill, "systemBlue": .systemBlue, "systemRed": .systemRed,
        "systemGreen": .systemGreen, "systemOrange": .systemOrange, "systemYellow": .systemYellow,
        "systemPink": .systemPink, "systemPurple": .systemPurple, "systemTeal": .systemTeal,
        "systemIndigo": .systemIndigo, "systemCyan": .systemCyan, "systemMint": .systemMint,
        "systemBrown": .systemBrown, "systemGray": .systemGray, "systemGray2": .systemGray2,
        "systemGray3": .systemGray3, "systemGray4": .systemGray4, "systemGray5": .systemGray5,
        "systemGray6": .systemGray6, "tint": .tintColor, "link": .link, "placeholderText": .placeholderText,
        "white": .white, "black": .black, "clear": .clear,
    ]
    #endif

    static func horizontal(_ value: Value?) -> HorizontalAlignment {
        switch value?.string {
        case "leading": .leading
        case "trailing": .trailing
        default: .center
        }
    }

    static func vertical(_ value: Value?) -> VerticalAlignment {
        switch value?.string {
        case "top": .top
        case "bottom": .bottom
        case "firstTextBaseline": .firstTextBaseline
        default: .center
        }
    }

    static func alignment(_ value: Value?) -> Alignment? {
        switch value?.string {
        case "topLeading": .topLeading
        case "top": .top
        case "topTrailing": .topTrailing
        case "leading": .leading
        case "center": .center
        case "trailing": .trailing
        case "bottomLeading": .bottomLeading
        case "bottom": .bottom
        case "bottomTrailing": .bottomTrailing
        default: nil
        }
    }

    static func textAlignment(_ value: Value?) -> TextAlignment? {
        switch value?.string {
        case "leading": .leading
        case "center": .center
        case "trailing": .trailing
        default: nil
        }
    }

    static func weight(_ value: Value?) -> Font.Weight? { value?.string.flatMap { weights[$0] } }

    static let designs: [String: Font.Design] = ["serif": .serif, "rounded": .rounded, "monospaced": .monospaced]

    static let textStyles: [String: Font.TextStyle] = [
        "largeTitle": .largeTitle, "title": .title, "title2": .title2, "title3": .title3,
        "headline": .headline, "subheadline": .subheadline, "body": .body, "callout": .callout,
        "footnote": .footnote, "caption": .caption, "caption2": .caption2,
    ]

    static let weights: [String: Font.Weight] = [
        "ultraLight": .ultraLight, "thin": .thin, "light": .light, "regular": .regular, "medium": .medium,
        "semibold": .semibold, "bold": .bold, "heavy": .heavy, "black": .black,
    ]
}

extension Color {
    init(_ rgba: RGBA) {
        self.init(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha)
    }
}
