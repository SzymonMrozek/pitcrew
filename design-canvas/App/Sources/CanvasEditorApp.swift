import CanvasCore
import CanvasRender
import SwiftUI
import UniformTypeIdentifiers

@main
struct CanvasEditorApp: App {
    @State private var store = EditorStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            if PreviewDevice.isEnabled {
                PreviewDeviceView()
            } else {
                EditorView(store: store)
                    .task { store.startMCP() }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { store.file.saveNow() }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { store.isPickingFile = .open }
                    .keyboardShortcut("o")
                Button("Save As…") { store.isPickingFile = .saveAs }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandGroup(after: .toolbar) {
                PreviewButton(store: store)
                    .keyboardShortcut(.return, modifiers: [.command, .option])
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { store.undo() }
                    .keyboardShortcut("z")
                    .disabled(!store.canUndo)
                Button("Redo") { store.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!store.canRedo)
            }
        }

        // A window on the Mac and iPad, so the preview sits beside the canvas while editing.
        WindowGroup("Preview", id: "preview", for: PreviewTarget.self) { $target in
            if let target {
                PreviewView(store: store, target: target)
            }
        }
        .defaultSize(width: 520, height: 1000)
    }
}

struct EditorView: View {
    @Bindable var store: EditorStore
    @State private var scene = CanvasScene()
    @State private var showsInspector = UIDevice.current.userInterfaceIdiom != .phone
    @State private var showsLayers = UIDevice.current.userInterfaceIdiom != .phone
    @Environment(\.horizontalSizeClass) private var sizeClass

    // No NavigationStack here: SwiftUI would hand its navigation controller to every
    // rendered screen's NavigationStack, and their titles would land in the editor's bar.
    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                if showsLayers && sizeClass != .compact {
                    LayersView(store: store)
                        .frame(width: 250)
                    Divider()
                }
                CanvasView(store: store, scene: scene)
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .sheet(isPresented: Binding(get: { showsLayers && sizeClass == .compact }, set: { showsLayers = $0 })) {
            LayersView(store: store)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: Binding(get: { store.previewSheet != nil }, set: { if !$0 { store.previewSheet = nil } })) {
            if let target = store.previewSheet {
                PreviewView(store: store, target: target)
            }
        }
        .onChange(of: store.focusTarget) {
            guard let rect = store.focusTarget else { return }
            scene.camera.fit(rect)
            store.focusTarget = nil
        }
        .inspector(isPresented: $showsInspector) {
            InspectorView(store: store)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
        }
        .fileImporter(
            isPresented: Binding(get: { store.isPickingFile == .open }, set: { if !$0 { store.isPickingFile = nil } }),
            allowedContentTypes: [.canvas, .json]
        ) { result in
            if case .success(let url) = result { store.open(url) }
        }
        .fileExporter(
            isPresented: Binding(get: { store.isPickingFile == .saveAs }, set: { if !$0 { store.isPickingFile = nil } }),
            document: CanvasExport(file: store.snapshot),
            contentType: .canvas,
            defaultFilename: store.file.url.deletingPathExtension().lastPathComponent
        ) { result in
            // The exporter wrote the file; continue editing it there.
            if case .success(let url) = result { store.open(url) }
        }
    }

    private var fileStatus: some View {
        let status: String = switch store.file.status {
        case .saved: "Saved"
        case .saving: "Saving…"
        case .failed(let message): message
        }
        return Menu {
            Button("Open…", systemImage: "folder") { store.isPickingFile = .open }
            Button("Save As…", systemImage: "square.and.arrow.down") { store.isPickingFile = .saveAs }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text(store.file.fileName).font(.subheadline.weight(.semibold))
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(store.file.status == .saved ? Color.secondary : store.file.status == .saving ? Color.secondary : Color.red)
            }
            .lineLimit(1)
        }
        .menuIndicator(.hidden)
        .help(store.file.url.path(percentEncoded: false))
    }

    private var toolbar: some View {
        // On a phone the secondary actions move into a menu so the toolbar fits.
        let compact = sizeClass == .compact
        return HStack(spacing: compact ? 12 : 16) {
            if !compact { layersToggle }
            Button("Undo", systemImage: "arrow.uturn.backward") { store.undo() }
                .disabled(!store.canUndo)
            Button("Redo", systemImage: "arrow.uturn.forward") { store.redo() }
                .disabled(!store.canRedo)
            if !compact { fileStatus }
            Spacer()
            pagePicker
            Spacer()
            if !compact {
                Label(store.mcpStatus, systemImage: "point.3.connected.trianglepath.dotted")
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                copyNodeID
            }
            Toggle("Comment", systemImage: "bubble.left", isOn: $store.isCommenting)
                .toggleStyle(.button)
                .keyboardShortcut("c", modifiers: [])
                .disabled(store.isOnTokens)
            Toggle("Spacing", systemImage: "ruler", isOn: $store.showsSpacing)
                .toggleStyle(.button)
                .help("Show the selection's padding and gaps (or hold ⌥)")
            if !compact {
                darkCopies
                zoomOut
            }
            Button("\(Int((scene.camera.scale * 100).rounded()))%") { scene.camera.fit(store.contentBounds) }
                .keyboardShortcut("1", modifiers: .shift)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 52)
                .help("Zoom to fit (⇧1)")
            if compact {
                Menu {
                    Text(store.mcpStatus)
                    layersToggle
                    copyNodeID
                    darkCopies
                    zoomOut
                    zoomIn
                    Button("Open…", systemImage: "folder") { store.isPickingFile = .open }
                    Button("Save As…", systemImage: "square.and.arrow.down") { store.isPickingFile = .saveAs }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            } else {
                zoomIn
            }
            PreviewButton(store: store)
            Button("Inspector", systemImage: "sidebar.trailing") { showsInspector.toggle() }
        }
        .labelStyle(.iconOnly)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var layersToggle: some View {
        Toggle("Layers", systemImage: "sidebar.leading", isOn: $showsLayers)
            .toggleStyle(.button)
            .keyboardShortcut("l", modifiers: [.command, .option])
    }

    private var copyNodeID: some View {
        Button("Copy node ID", systemImage: "doc.on.doc") {
            UIPasteboard.general.string = store.selection?.node
        }
        .keyboardShortcut("c", modifiers: [.command, .shift])
        .disabled(store.selection == nil)
    }

    /// The pages, like Figma's page list, also in the layers panel.
    private var pagePicker: some View {
        Menu {
            Picker("Page", selection: $store.page) {
                ForEach(store.pageList, id: \.page) { entry in
                    Label(entry.name, systemImage: entry.page == .tokens ? "swatchpalette" : "doc").tag(entry.page)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Add Page", systemImage: "plus") { store.addPage() }
        } label: {
            Label(store.pageList.first { $0.page == store.page }?.name ?? "Page", systemImage: "doc.on.doc")
                .labelStyle(.titleAndIcon)
                .font(.subheadline.weight(.semibold))
        }
        .menuIndicator(.visible)
        .fixedSize()
        .help("Pages")
    }

    private var darkCopies: some View {
        Menu {
            Picker("Theme", selection: $store.theme) {
                ForEach(CanvasTheme.allCases, id: \.self) { Label($0.rawValue, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Theme", systemImage: store.theme.symbol)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Theme: \(store.theme.rawValue)")
    }

    private var zoomOut: some View {
        Button("Zoom out", systemImage: "minus.magnifyingglass") { scene.camera.zoom(by: 1 / 1.25) }
            .keyboardShortcut("-")
    }

    private var zoomIn: some View {
        Button("Zoom in", systemImage: "plus.magnifyingglass") { scene.camera.zoom(by: 1.25) }
            .keyboardShortcut("=")
    }
}

private struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView

    init(_ style: some LabelStyle) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

extension UTType {
    /// Declared by extension only; the file is JSON underneath.
    static let canvas = UTType(filenameExtension: CanvasFile.fileExtension, conformingTo: .json) ?? .json
}

/// Hands the current contents to the system's save panel.
struct CanvasExport: FileDocument {
    static let readableContentTypes: [UTType] = [.canvas, .json]

    let file: CanvasFile

    init(file: CanvasFile) {
        self.file = file
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        file = try CanvasFile.decode(data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try file.encoded())
    }
}
