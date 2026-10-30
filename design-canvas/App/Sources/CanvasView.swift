import CanvasCore
import CanvasRender
import SwiftUI

/// The canvas in three layers:
///
/// 1. Offscreen renderers: every item rendered live with real SwiftUI at 1:1, under
///    the Metal view. Pan and zoom never touch them, so layout and measured frames stay
///    still while the camera moves.
/// 2. Metal: draws each item from a texture snapshot of its renderer. A snapshot is
///    retaken only when the item's content changes or the zoom needs more pixels.
/// 3. Overlay: titles, selection and hover outlines, comment pins and the composer,
///    positioned with the camera.
struct CanvasView: View {
    @Bindable var store: EditorStore
    let scene: CanvasScene

    var body: some View {
        let items = store.items
        ZStack(alignment: .topLeading) {
            OffscreenRenderers(store: store, items: items)
            if scene.renderer != nil {
                MetalCanvas(
                    scene: scene,
                    quads: items.map { CanvasQuad(id: $0.id, rect: store.pageRect(of: $0), cornerRadius: cornerRadius(of: $0)) },
                    onTap: { store.handleTap(atPage: scene.camera.viewToPage($0)) },
                    onHover: { store.hover(atPage: $0.map(scene.camera.viewToPage)) }
                )
            } else {
                ContentUnavailableView("Metal is unavailable", systemImage: "exclamationmark.triangle")
            }
            CanvasOverlay(store: store, camera: scene.camera, items: items)
            TextureRefresher(store: store, scene: scene, items: items)
        }
        .clipped()
    }

    private func cornerRadius(of item: CanvasItem) -> CGFloat {
        switch item.content {
        case .screen(let screen, _): Device.named(screen[.device]?.string).cornerRadius
        case .component: 10
        }
    }
}

/// Live renderers stacked at the origin and covered by the opaque Metal view.
private struct OffscreenRenderers: View {
    let store: EditorStore
    let items: [CanvasItem]

    var body: some View {
        Color.clear
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    ForEach(items) { item in
                        switch item.content {
                        case .screen(let screen, let scheme):
                            ScreenView(screen, tokens: store.document.tokens, colorScheme: scheme, frames: store.registry(for: item.id))
                        case .component(_, let root):
                            ComponentPreview(root, tokens: store.document.tokens, frames: store.registry(for: item.id))
                        }
                    }
                }
                .fixedSize()
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Retakes texture snapshots when content changes or the zoom needs a sharper level.
/// Only this small view observes the camera, so panning re-evaluates nothing else.
private struct TextureRefresher: View {
    let store: EditorStore
    let scene: CanvasScene
    let items: [CanvasItem]
    @State private var keys: [String: Int] = [:]

    /// Pixels per point of a texture. Capped: a 6x iPhone screen is ~70 MB with mips.
    private static let levels: [CGFloat] = [1, 2, 3, 4]

    private var level: CGFloat {
        Self.levels.first { $0 >= scene.displayScale } ?? Self.levels.last!
    }

    private struct Trigger: Equatable {
        let revision: Int
        let items: [String]
        let level: CGFloat
        let sizes: [CGSize]
    }

    var body: some View {
        let trigger = Trigger(
            revision: store.revision,
            items: items.map(\.id),
            level: level,
            sizes: items.map { store.size(of: $0) }
        )
        Color.clear
            .allowsHitTesting(false)
            .task(id: trigger) {
                // Wait for the offscreen renderers to show the new state, then retry
                // items that were not on screen yet.
                for attempt in 0..<20 {
                    try? await Task.sleep(for: .milliseconds(attempt == 0 ? 30 : 150))
                    if Task.isCancelled || refresh() { break }
                }
            }
    }

    /// Returns true when every item has an up-to-date texture.
    @MainActor
    private func refresh() -> Bool {
        guard let renderer = scene.renderer else { return true }
        let visible = scene.camera.visiblePageRect
        var complete = true
        for item in items {
            let key = store.contentKey(of: item)
            let current = renderer.textureScale(for: item.id)
            // Off-screen items keep their resolution; only visible ones sharpen.
            let wanted = store.pageRect(of: item).intersects(visible) ? level : max(current ?? 1, 1)
            guard keys[item.id] != key || (current ?? 0) < wanted else { continue }
            guard let image = snapshot(item, scale: wanted) else {
                complete = false
                continue
            }
            renderer.setTexture(image, scale: wanted, for: item.id)
            keys[item.id] = key
        }
        renderer.removeTextures(except: Set(items.map(\.id)))
        scene.setNeedsDisplay()
        return complete
    }

    @MainActor
    private func snapshot(_ item: CanvasItem, scale: CGFloat) -> CGImage? {
        switch item.content {
        case .screen:
            return store.registry(for: item.id).snapshot(scale: scale)?.cgImage
        case .component(_, let root):
            // Plain SwiftUI without UIKit-backed views, so ImageRenderer draws it faithfully.
            let renderer = ImageRenderer(content: ComponentPreview(root, tokens: store.document.tokens))
            renderer.scale = scale
            return renderer.cgImage
        }
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
                    .frame(width: max(rect.width, 1), alignment: .leading)
                    .offset(x: rect.minX, y: rect.minY - 20)
            }
            .allowsHitTesting(false)

            if let hovered = store.hovered, hovered != store.selection {
                outline(hovered, width: 1)
            }
            if let selection = store.selection {
                outline(selection, width: 2)
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
    private func outline(_ selection: Selection, width: CGFloat) -> some View {
        if let item = items.first(where: { $0.id == selection.item }),
            let frame = store.registry(for: item.id).frames[selection.node]
        {
            let rect = camera.pageToView(frame.offsetBy(dx: item.origin.x, dy: item.origin.y))
            Rectangle()
                .strokeBorder(Color.accentColor, lineWidth: width)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
        }
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
