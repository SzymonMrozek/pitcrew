import CanvasCore
import CanvasEngine
import CanvasRender
import SwiftUI

/// The canvas in two layers:
///
/// 1. Metal: the dot grid, each item's shadow, and tiles drawn by the layout engine
///    from the document, on background threads, at the resolution the zoom needs.
/// 2. Overlay: titles, selection and hover outlines, measurements, comment pins and the
///    composer, positioned with the camera.
struct CanvasView: View {
    @Bindable var store: EditorStore
    let scene: CanvasScene

    var body: some View {
        let items = store.items
        // The Metal view alone sizes the canvas, so nothing the overlay lays out, such as
        // a title as wide as a zoomed-in screen, can change the camera's view size.
        metal(items)
            .overlay(alignment: .topLeading) { CanvasOverlay(store: store, camera: scene.camera, items: items) }
            .clipped()
    }

    @ViewBuilder
    private func metal(_ items: [CanvasItem]) -> some View {
        Group {
            if scene.renderer != nil {
                MetalCanvas(
                    scene: scene,
                    quads: items.map { item in
                        let layout = store.layout(of: item.id)
                        return CanvasQuad(
                            id: item.id, rect: store.pageRect(of: item), cornerRadius: layout?.cornerRadius ?? 0,
                            background: layout?.background ?? RGBA(red: 1, green: 1, blue: 1)
                        )
                    },
                    items: items.compactMap { item in
                        store.layout(of: item.id).map {
                            SceneItem(id: item.id, origin: item.origin, layout: $0, version: store.contentKey(of: item))
                        }
                    },
                    onTap: { point, click in
                        store.handleTap(atPage: scene.camera.viewToPage(point), drill: click == .double, deep: click == .deep)
                    },
                    onHover: { store.hover(atPage: $0.map(scene.camera.viewToPage)) },
                    onOptionKey: { if store.isOptionDown != $0 { store.isOptionDown = $0 } }
                )
            } else {
                ContentUnavailableView("Metal is unavailable", systemImage: "exclamationmark.triangle")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CanvasOverlay: View {
    let store: EditorStore
    let camera: CanvasCamera
    let items: [CanvasItem]

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(items) { item in
                let rect = camera.pageToView(store.pageRect(of: item))
                Text(title(of: item))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: min(max(rect.width, 1), max(camera.viewSize.width, 1)), alignment: .leading)
                    .offset(x: rect.minX, y: rect.minY - 20)
            }
            .allowsHitTesting(false)

            if let hovered = store.hovered, hovered != store.selection {
                outline(hovered, width: 1)
            }
            if let selection = store.selection {
                outline(selection, width: 2, color: isComponent(selection) ? .purple : .accentColor)
                measurements(for: selection)
                labels(for: selection)
            }

            ForEach(store.visibleThreads) { thread in
                pinned(at: camera.pageToView(store.pinPoint(for: thread.anchor))) {
                    CommentPin(
                        number: store.comments.number(of: thread.id) ?? 0,
                        isResolved: thread.isResolved,
                        byAgent: thread.comments.first?.author != EditorStore.designer,
                        isSelected: store.selectedThread == thread.id
                    )
                    .onTapGesture { store.selectThread(thread.id) }
                }
            }
            if let draft = store.draft {
                pinned(at: camera.pageToView(store.pinPoint(for: draft))) {
                    CommentComposer(store: store)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func outline(_ selection: Selection, width: CGFloat, color: Color = .accentColor) -> some View {
        if let item = items.first(where: { $0.id == selection.item }),
            let frame = store.frames(of: item.id)[selection.node]
        {
            let rect = camera.pageToView(frame.offsetBy(dx: item.origin.x, dy: item.origin.y))
            Rectangle()
                .strokeBorder(color, lineWidth: width)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
        }
    }

    private var isMeasuring: Bool { store.isOptionDown || store.showsSpacing }

    private func isComponent(_ selection: Selection) -> Bool {
        store.context(of: selection).flatMap(store.component(of:)) != nil
    }

    private func viewRect(of selection: Selection) -> CGRect? {
        guard let item = items.first(where: { $0.id == selection.item }),
            let frame = store.frames(of: item.id)[selection.node]
        else { return nil }
        return camera.pageToView(frame.offsetBy(dx: item.origin.x, dy: item.origin.y))
    }

    /// The selection's name above it, purple for components, and its size below, like Figma.
    @ViewBuilder
    private func labels(for selection: Selection) -> some View {
        // Measurements carry their own labels; the inspector still names the selection.
        if !isMeasuring, let rect = viewRect(of: selection), let context = store.context(of: selection) {
            let component = store.component(of: context)
            let name = component.map { $0.isRoot ? "◇ \($0.name)" : "\(context.node.kind.title) · ◇ \($0.name)" }
                ?? context.node.kind.title
            placed(at: CGPoint(x: rect.minX, y: rect.minY - 3), .bottomLeading) {
                CanvasBadge(text: name, color: component == nil ? .accentColor : .purple)
            }
            if let frame = store.frames(of: selection.item)[selection.node] {
                placed(at: CGPoint(x: rect.midX, y: rect.maxY + 4), .top) {
                    CanvasBadge(text: "\(frame.width.rounded1) × \(frame.height.rounded1)", color: component == nil ? .accentColor : .purple)
                }
            }
        }
    }

    /// Padding and gaps of the selection with ⌥ or the Spacing toggle; with ⌥ over
    /// another node of the same item, the distance to it instead.
    @ViewBuilder
    private func measurements(for selection: Selection) -> some View {
        if let item = items.first(where: { $0.id == selection.item }), isMeasuring {
            let lines = store.measurements
            let origin = item.origin
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                let from = camera.pageToView(CGPoint(x: origin.x + line.from.x, y: origin.y + line.from.y))
                let to = camera.pageToView(CGPoint(x: origin.x + line.to.x, y: origin.y + line.to.y))
                RedlinePath(from: from, to: to)
                    .stroke(CanvasBadge.redline, lineWidth: 1)
                    .allowsHitTesting(false)
                placed(at: CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2), line.isHorizontal ? .bottom : .leading) {
                    CanvasBadge(text: line.length.rounded1, color: CanvasBadge.redline)
                        .padding(line.isHorizontal ? .bottom : .leading, 3)
                }
            }
        }
    }

    /// Places content so that its `alignment` point sits on a view point.
    private func placed(at point: CGPoint, _ alignment: Alignment, @ViewBuilder content: () -> some View) -> some View {
        Color.clear
            .frame(width: 0, height: 0)
            .overlay(alignment: alignment) { content().fixedSize() }
            .offset(x: point.x, y: point.y)
            .allowsHitTesting(false)
    }

    private func title(of item: CanvasItem) -> String {
        switch item.content {
        case .screen(let screen, let scheme):
            "\(screen[.name]?.string ?? "Screen") · \(scheme == .dark ? "Dark" : "Light")"
        case .component(let name, _):
            "◇ \(name)"
        }
    }

    /// Places content with its bottom-left corner on a view point, like a pin's tip.
    private func pinned(at point: CGPoint, @ViewBuilder content: () -> some View) -> some View {
        Color.clear
            .frame(width: 0, height: 0)
            .overlay(alignment: .bottomLeading) { content().fixedSize() }
            .offset(x: point.x, y: point.y)
    }
}

private struct CanvasBadge: View {
    static let redline = Color(red: 0.95, green: 0.28, blue: 0.13)

    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color, in: RoundedRectangle(cornerRadius: 3))
    }
}

/// A measured distance with short ticks at both ends.
private struct RedlinePath: Shape {
    let from: CGPoint
    let to: CGPoint

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: from)
        path.addLine(to: to)
        let horizontal = from.y == to.y
        for end in [from, to] {
            path.move(to: horizontal ? CGPoint(x: end.x, y: end.y - 4) : CGPoint(x: end.x - 4, y: end.y))
            path.addLine(to: horizontal ? CGPoint(x: end.x, y: end.y + 4) : CGPoint(x: end.x + 4, y: end.y))
        }
        return path
    }
}

private struct CommentPin: View {
    let number: Int
    let isResolved: Bool
    let byAgent: Bool
    let isSelected: Bool

    var body: some View {
        Text("\(number)")
            .font(.system(size: 13, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white)
            .frame(minWidth: 28, minHeight: 28)
            .background(
                UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 2, bottomTrailingRadius: 14, topTrailingRadius: 14)
                    .fill(isResolved ? Color.gray : byAgent ? Color.purple : Color.accentColor)
            )
            .overlay(
                UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 2, bottomTrailingRadius: 14, topTrailingRadius: 14)
                    .strokeBorder(.white, lineWidth: isSelected ? 2.5 : 1.5)
            )
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            .contentShape(Rectangle())
    }
}

private struct CommentComposer: View {
    let store: EditorStore
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            CommentPin(number: store.comments.threads.count + 1, isResolved: false, byAgent: false, isSelected: true)
            VStack(alignment: .trailing, spacing: 8) {
                TextField("Add a comment", text: $text, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($isFocused)
                    .onSubmit(post)
                HStack {
                    Button("Cancel", role: .cancel) { store.cancelDraft() }
                        .keyboardShortcut(.escape, modifiers: [])
                    Button("Post", action: post)
                        .buttonStyle(.borderedProminent)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .controlSize(.small)
            }
            .padding(12)
            .frame(width: 260)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .onAppear { isFocused = true }
    }

    private func post() {
        store.postDraft(text)
        text = ""
    }
}
