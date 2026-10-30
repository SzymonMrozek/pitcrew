import CanvasCore
import CanvasRender
import SwiftUI

/// Prototype canvas: SwiftUI transforms for pan and zoom. It exists to check render
/// fidelity and the inspection loop; the production canvas composites cached
/// screen textures in Metal and keeps live views only for the screen being edited.
struct CanvasView: View {
    @Bindable var store: EditorStore
    @Binding var scale: CGFloat
    @State private var offset = CGSize(width: 80, height: 80)
    @GestureState private var drag = CGSize.zero
    @GestureState private var magnification: CGFloat = 1

    var body: some View {
        // Items sit in an overlay so their combined size never sizes the canvas itself.
        Color(uiColor: .systemGray5)
            .contentShape(Rectangle())
            .onTapGesture { store.selection = nil }
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    ForEach(store.items) { item in
                        CanvasItemView(item: item, store: store, scale: scale * magnification)
                            .offset(x: item.origin.x, y: item.origin.y)
                    }
                }
                .fixedSize()
                .scaleEffect(scale * magnification, anchor: .topLeading)
                .offset(x: offset.width + drag.width, y: offset.height + drag.height)
            }
            .clipped()
        .simultaneousGesture(
            DragGesture(minimumDistance: 6)
                .updating($drag) { value, state, _ in state = value.translation }
                .onEnded { value in
                    offset.width += value.translation.width
                    offset.height += value.translation.height
                }
        )
        .simultaneousGesture(
            MagnifyGesture()
                .updating($magnification) { value, state, _ in state = value.magnification }
                .onEnded { value in scale = min(max(scale * value.magnification, 0.1), 4) }
        )
    }
}

private struct CanvasItemView: View {
    let item: CanvasItem
    let store: EditorStore
    let scale: CGFloat

    private var frames: FrameRegistry { store.registry(for: item.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13 / max(scale, 0.25), weight: .medium))
                .foregroundStyle(.secondary)
            rendered
                .allowsHitTesting(false)
                .overlay(alignment: .topLeading) { selectionOutline }
                .overlay {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(coordinateSpace: .local) { point in
                            store.selection = frames.hitTest(point).map { Selection(item: item.id, node: $0) }
                        }
                }
        }
    }

    private var title: String {
        switch item.content {
        case .screen(let screen, let scheme):
            "\(screen[.name]?.string ?? "Screen") · \(scheme == .dark ? "Dark" : "Light")"
        case .component(let name, _):
            "◇ \(name)"
        }
    }

    @ViewBuilder
    private var rendered: some View {
        switch item.content {
        case .screen(let screen, let scheme):
            ScreenView(screen, tokens: store.document.tokens, colorScheme: scheme, frames: frames)
        case .component(_, let root):
            ComponentPreview(root, tokens: store.document.tokens, frames: frames)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder
    private var selectionOutline: some View {
        if let selection = store.selection, selection.item == item.id, let frame = frames.frames[selection.node] {
            Rectangle()
                .strokeBorder(Color.accentColor, lineWidth: 2 / max(scale, 0.1))
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
                .allowsHitTesting(false)
        }
    }
}
