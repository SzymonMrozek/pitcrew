import CanvasRender
import SwiftUI

@main
struct CanvasEditorApp: App {
    @State private var store = EditorStore()

    var body: some Scene {
        WindowGroup {
            EditorView(store: store)
                .task { store.startMCP() }
        }
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { store.undo() }
                    .keyboardShortcut("z")
                    .disabled(!store.canUndo)
                Button("Redo") { store.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!store.canRedo)
            }
        }
    }
}

struct EditorView: View {
    @Bindable var store: EditorStore
    @State private var scene = CanvasScene()
    @State private var showsInspector = UIDevice.current.userInterfaceIdiom != .phone
    @Environment(\.horizontalSizeClass) private var sizeClass

    // No NavigationStack here: SwiftUI would hand its navigation controller to every
    // rendered screen's NavigationStack, and their titles would land in the editor's bar.
    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            CanvasView(store: store, scene: scene)
                .ignoresSafeArea(edges: .bottom)
        }
        .inspector(isPresented: $showsInspector) {
            InspectorView(store: store)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
        }
    }

    private var toolbar: some View {
        HStack(spacing: sizeClass == .compact ? 12 : 16) {
            Button("Undo", systemImage: "arrow.uturn.backward") { store.undo() }
                .disabled(!store.canUndo)
            Button("Redo", systemImage: "arrow.uturn.forward") { store.redo() }
                .disabled(!store.canRedo)
            Spacer()
            Label(store.mcpStatus, systemImage: "point.3.connected.trianglepath.dotted")
                .labelStyle(sizeClass == .compact ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
                .lineLimit(1)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Button("Copy node ID", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = store.selection?.node
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(store.selection == nil)
            Toggle("Comment", systemImage: "bubble.left", isOn: $store.isCommenting)
                .toggleStyle(.button)
                .keyboardShortcut("c", modifiers: [])
            Toggle("Dark copies", systemImage: "circle.lefthalf.filled", isOn: $store.showsDarkCopies)
                .toggleStyle(.button)
            Button("Zoom out", systemImage: "minus.magnifyingglass") { scene.camera.zoom(by: 1 / 1.25) }
                .keyboardShortcut("-")
            Button("\(Int((scene.camera.scale * 100).rounded()))%") { scene.camera.fit(store.contentBounds) }
                .keyboardShortcut("1", modifiers: .shift)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 52)
                .help("Zoom to fit (⇧1)")
            Button("Zoom in", systemImage: "plus.magnifyingglass") { scene.camera.zoom(by: 1.25) }
                .keyboardShortcut("=")
            Button("Inspector", systemImage: "sidebar.trailing") { showsInspector.toggle() }
        }
        .labelStyle(.iconOnly)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

private struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView

    init(_ style: some LabelStyle) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
