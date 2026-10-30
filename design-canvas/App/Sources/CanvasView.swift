import CanvasCore
import CanvasRender
import SwiftUI

/// Prototype canvas: SwiftUI transforms for pan and zoom. It exists to check render
/// fidelity and the inspection loop; the production canvas composites cached
/// screen textures in Metal and keeps live views only for the screen being edited.
///
/// Page coordinates: an item's origin is the top-left of its rendered content, so a
/// point inside an item is `item.origin + local point`. Comment pins live in page
/// coordinates, above every item.
struct CanvasView: View {
    @Bindable var store: EditorStore
    @Binding var scale: CGFloat
    @State private var offset = CGSize(width: 80, height: 100)
    @GestureState private var drag = CGSize.zero
    @GestureState private var magnification: CGFloat = 1

    private var effectiveScale: CGFloat { scale * magnification }
    private var effectiveOffset: CGSize { CGSize(width: offset.width + drag.width, height: offset.height + drag.height) }

    var body: some View {
        // Items sit in an overlay so their combined size never sizes the canvas itself.
        Color(uiColor: .systemGray5)
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { point in
                if store.isCommenting {
                    let page = CGPoint(
                        x: (point.x - effectiveOffset.width) / effectiveScale,
                        y: (point.y - effectiveOffset.height) / effectiveScale
                    )
                    store.startDraft(at: CommentAnchor(x: page.x, y: page.y))
                } else {
                    store.clearSelection()
                }
            }
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    ForEach(store.items) { item in
                        CanvasItemView(item: item, store: store, scale: effectiveScale)
                            .offset(x: item.origin.x, y: item.origin.y)
                    }
                    CommentLayer(store: store, scale: effectiveScale)
                }
                .fixedSize()
                .scaleEffect(effectiveScale, anchor: .topLeading)
                .offset(effectiveOffset)
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
        rendered
            .allowsHitTesting(false)
            .overlay(alignment: .topLeading) { selectionOutline }
            .overlay {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { point in
                        let node = frames.hitTest(point)
                        if store.isCommenting {
                            store.startDraft(in: item, at: point, on: node, frame: node.flatMap { frames.frames[$0] })
                        } else {
                            store.select(node.map { Selection(item: item.id, node: $0) })
                        }
                    }
            }
            // The title sits above the content without taking layout space, so the
            // item's origin stays the content's top-left corner.
            .overlay(alignment: .topLeading) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .scaleEffect(1 / max(scale, 0.25), anchor: .bottomLeading)
                    .alignmentGuide(.top) { $0[.bottom] + 8 }
                    .allowsHitTesting(false)
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

/// Pins for every visible thread plus the composer for a new one. Pins keep their
/// on-screen size at any zoom, and their tip sits exactly on the anchored point.
private struct CommentLayer: View {
    let store: EditorStore
    let scale: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(store.visibleThreads) { thread in
                pinned(at: store.pinPoint(for: thread.anchor)) {
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
                pinned(at: store.pinPoint(for: draft)) {
                    CommentComposer(store: store)
                }
            }
        }
    }

    private func pinned(at point: CGPoint, @ViewBuilder content: () -> some View) -> some View {
        Color.clear
            .frame(width: 0, height: 0)
            .overlay(alignment: .bottomLeading) {
                content()
                    .fixedSize()
                    .scaleEffect(1 / max(scale, 0.1), anchor: .bottomLeading)
            }
            .offset(x: point.x, y: point.y)
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
            CommentPin(number: (store.comments.threads.count) + 1, isResolved: false, byAgent: false, isSelected: true)
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
