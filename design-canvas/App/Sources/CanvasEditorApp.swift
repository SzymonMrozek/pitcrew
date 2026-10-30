import SwiftUI

@main
struct CanvasEditorApp: App {
    @State private var store = EditorStore()

    var body: some Scene {
        WindowGroup {
            EditorView(store: store)
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
    @State private var scale: CGFloat = 0.75
    @State private var showsInspector = UIDevice.current.userInterfaceIdiom != .phone

    // No NavigationStack here: SwiftUI would hand its navigation controller to every
    // rendered screen's NavigationStack, and their titles would land in the editor's bar.
    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            CanvasView(store: store, scale: $scale)
                .ignoresSafeArea(edges: .bottom)
        }
        .inspector(isPresented: $showsInspector) {
            InspectorView(store: store)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 16) {
            Button("Undo", systemImage: "arrow.uturn.backward") { store.undo() }
                .disabled(!store.canUndo)
            Button("Redo", systemImage: "arrow.uturn.forward") { store.redo() }
                .disabled(!store.canRedo)
            Spacer()
            Toggle("Dark copies", systemImage: "circle.lefthalf.filled", isOn: $store.showsDarkCopies)
                .toggleStyle(.button)
            Button("Zoom out", systemImage: "minus.magnifyingglass") { scale = max(scale / 1.25, 0.1) }
                .keyboardShortcut("-")
            Text("\(Int((scale * 100).rounded()))%")
                .monospacedDigit()
                .frame(minWidth: 44)
            Button("Zoom in", systemImage: "plus.magnifyingglass") { scale = min(scale * 1.25, 4) }
                .keyboardShortcut("=")
            Button("Inspector", systemImage: "sidebar.trailing") { showsInspector.toggle() }
        }
        .labelStyle(.iconOnly)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
