import CanvasCore
import CanvasEngine
import CanvasRender
import SwiftUI

/// What the preview window opens: a screen and the appearance it starts in.
struct PreviewTarget: Hashable, Codable {
    var screen: String
    var dark = false
}

/// A screen rendered with real SwiftUI on iOS, live with every edit. Compare puts the
/// canvas engine's drawing beside it.
///
/// On the Mac, SwiftUI would draw macOS's type and controls, so the screen runs on the
/// preview device: this app in the iOS Simulator, whose screen the window streams, with
/// clicks, scrolling and keys going back to it. Without streaming, the window shows the
/// device's renders and a click on a toggle still switches it. On iOS the window renders
/// the screen itself.
struct PreviewView: View {
    let store: EditorStore
    @State private var dark: Bool
    @State private var mode = Mode.native
    /// Set once the window got its first size, so a size the designer picks, or one
    /// restored with the window, stays.
    @SceneStorage("preview.sized") private var isSized = false
    #if targetEnvironment(macCatalyst)
    /// The simulator's screen is streaming; until then, and without it, renders show.
    @State private var isLive = false
    @State private var streamFailure: String?
    #endif
    private let screenID: NodeID

    enum Mode: String, CaseIterable {
        case native = "SwiftUI"
        case compare = "Compare"
    }

    init(store: EditorStore, target: PreviewTarget) {
        self.store = store
        screenID = NodeID(target.screen)
        _dark = State(initialValue: target.dark)
    }

    private var appearance: Appearance { dark ? .dark : .light }
    private var target: PreviewTarget { PreviewTarget(screen: screenID.rawValue, dark: dark) }
    /// The screen with the toggles switched in the preview, so Compare matches it.
    private var screen: ResolvedNode? {
        (try? store.document.resolve(screenID))?.setting(.isOn, store.activePreviewToggles.mapValues(Value.bool))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let screen {
                GeometryReader { proxy in
                    stage(screen, in: proxy.size)
                }
            } else {
                ContentUnavailableView("Screen deleted", systemImage: "iphone.slash")
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .background(WindowSceneReader(onScene: sizeNewWindow))
        .onAppear { store.previewing = target }
        .onChange(of: dark) { store.previewing = target }
    }

    /// Gives a new preview window a device's proportions. It asks only this window's scene,
    /// so the editor's window keeps its size.
    private func sizeNewWindow(_ scene: UIWindowScene) {
        guard !isSized else { return }
        isSized = true
        #if targetEnvironment(macCatalyst)
        let frame = scene.effectiveGeometry.systemFrame
        scene.requestGeometryUpdate(.Mac(systemFrame: CGRect(origin: frame.origin, size: CGSize(width: 520, height: 1000))))
        #endif
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Text(screen?[.name]?.string ?? screenID.rawValue).font(.headline)
                Text(DeviceSpec.named(screen?[.device]?.string).name).font(.caption).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Spacer()
            #if targetEnvironment(macCatalyst)
            connection
            #endif
            Picker("Renderer", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Toggle("Dark", systemImage: "circle.lefthalf.filled", isOn: $dark)
                .toggleStyle(.button)
                .labelStyle(.iconOnly)
                .help("Dark appearance")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    /// The device, scaled down to fit the window but never up, so 1:1 stays crisp.
    private func stage(_ screen: ResolvedNode, in available: CGSize) -> some View {
        let device = DeviceSpec.named(screen[.device]?.string)
        let gap: CGFloat = 32
        let caption: CGFloat = mode == .compare ? 24 : 0
        let count: CGFloat = mode == .compare ? 2 : 1
        let content = CGSize(width: device.size.width * count + gap * (count - 1), height: device.size.height + caption)
        let scale = min(1, (available.width - gap) / content.width, (available.height - gap) / content.height)
        return HStack(alignment: .top, spacing: gap) {
            if mode == .compare {
                captioned("Canvas") { canvasImage(screen, device: device, scale: scale) }
                captioned("SwiftUI") { native(screen, device: device) }
            } else {
                native(screen, device: device)
            }
        }
        .frame(width: content.width, height: content.height)
        .scaleEffect(scale)
        .frame(width: available.width, height: available.height)
    }

    @ViewBuilder
    private func native(_ screen: ResolvedNode, device: DeviceSpec) -> some View {
        #if targetEnvironment(macCatalyst)
        let frame = store.nativeFrames["\(screenID)#\(appearance.rawValue)"]
        ZStack {
            // Decoding renders while the stream covers them would only cost frames.
            if !isLive {
                renders(screen, device: device, frame: frame)
                    .clipShape(RoundedRectangle(cornerRadius: device.cornerRadius, style: .continuous))
            }
            if let udid = store.previewDeviceUDID, streamFailure == nil {
                SimulatorLiveView(
                    udid: udid, cornerRadius: device.cornerRadius, onFirstFrame: { isLive = true },
                    onFailure: { streamFailure = $0 }
                )
                .id(udid)
                .opacity(isLive ? 1 : 0)
            }
        }
        .frame(width: device.size.width, height: device.size.height)
        .onChange(of: store.previewDeviceUDID) {
            isLive = false
            streamFailure = nil
        }
        #else
        NativeScreen(screen, tokens: store.document.tokens, appearance: appearance)
        #endif
    }

    #if targetEnvironment(macCatalyst)
    /// The preview device's last render of the screen, where a click switches a toggle.
    @ViewBuilder
    private func renders(_ screen: ResolvedNode, device: DeviceSpec, frame: (revision: Int, interaction: Int, png: Data)?) -> some View {
        Group {
            if let frame, let image = UIImage(data: frame.png) {
                Image(uiImage: image).resizable()
                    .onTapGesture { switchToggle(at: $0, in: screen, device: device) }
                    .overlay(alignment: .bottom) {
                        if frame.revision != store.revision {
                            Text("Updating…").font(.caption.weight(.semibold)).padding(.horizontal, 10).padding(.vertical, 4)
                                .background(.thinMaterial, in: Capsule()).padding(.bottom, 48)
                        }
                    }
            } else {
                ContentUnavailableView {
                    Label("Starting the iOS preview", systemImage: "iphone")
                } description: {
                    Text("The screen renders in the iOS Simulator, where Canvas Editor needs to be installed.")
                } actions: {
                    Button("Start on Simulator") { SimulatorLauncher.launchPreview(port: store.port) }
                }
            }
        }
    }

    /// A click switches the toggle under it, found in the engine's layout of the screen.
    private func switchToggle(at point: CGPoint, in screen: ResolvedNode, device: DeviceSpec) {
        let frames = LayoutEngine(tokens: store.document.tokens, appearance: appearance).screen(screen, device: device).frames
        guard let toggle = screen.first(where: { $0.kind == .toggle && frames[$0.id]?.contains(point) == true }) else { return }
        store.setPreviewToggle(toggle.id, on: toggle[.isOn]?.bool != true)
    }

    private var connection: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let connected = store.isPreviewDeviceConnected
            let help = !connected ? "The preview device isn't running"
                : isLive ? "Streaming the iOS Simulator; clicks, scrolling and keys go to it"
                : "Rendered by SwiftUI in the iOS Simulator; click a toggle to switch it"
                    + (streamFailure.map { ". Not streaming: \($0)" } ?? "")
            Menu {
                Button("Restart on Simulator", systemImage: "arrow.clockwise") { SimulatorLauncher.launchPreview(port: store.port) }
            } label: {
                Label(connected ? (isLive ? "Live" : "iOS Simulator") : "Not connected", systemImage: connected ? "iphone" : "iphone.slash")
                    .font(.caption)
                    .foregroundStyle(connected ? Color.secondary : Color.orange)
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help(help)
        }
    }
    #endif

    private func captioned(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    /// The canvas engine's drawing of the same screen, at the pixels the preview shows it at.
    private func canvasImage(_ screen: ResolvedNode, device: DeviceSpec, scale: CGFloat) -> some View {
        let layout = LayoutEngine(tokens: store.document.tokens, appearance: appearance).screen(screen, device: device)
        let pixels = max(1, (scale * UITraitCollection.current.displayScale).rounded(.up))
        return Group {
            if let image = Rasterizer.image(layout, scale: pixels) {
                Image(decorative: image, scale: pixels).resizable()
            } else {
                Color.clear
            }
        }
        .frame(width: device.size.width, height: device.size.height)
    }
}

/// Opens the selected screen's preview: a window where the platform has them, a sheet on iPhone.
struct PreviewButton: View {
    let store: EditorStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows

    var body: some View {
        Button("Preview", systemImage: "play") {
            guard let target = store.previewTarget else { return }
            store.previewing = target
            #if targetEnvironment(macCatalyst)
            if !store.isPreviewDeviceConnected { SimulatorLauncher.launchPreview(port: store.port) }
            #endif
            if supportsMultipleWindows {
                openWindow(id: "preview", value: target)
            } else {
                store.previewSheet = target
            }
        }
        .disabled(store.previewTarget == nil)
        .help("Preview the selected screen with SwiftUI (⌥⌘↩)")
    }
}

/// Hands over the window scene a view is in, once it's in a window.
private struct WindowSceneReader: UIViewRepresentable {
    let onScene: (UIWindowScene) -> Void

    func makeUIView(context: Context) -> SceneView {
        let view = SceneView()
        view.onScene = onScene
        return view
    }

    func updateUIView(_ view: SceneView, context: Context) {
        view.onScene = onScene
    }

    final class SceneView: UIView {
        var onScene: (UIWindowScene) -> Void = { _ in }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            // After the update that put the view in its window, which mustn't change state.
            guard let scene = window?.windowScene else { return }
            DispatchQueue.main.async { [onScene] in onScene(scene) }
        }
    }
}
