import CanvasCore
import CanvasEngine
import CanvasRender
import Observation
import SwiftUI

/// What the editor tells the preview device: the document revision, the screen to show
/// and the toggles switched in the preview.
struct PreviewState: Codable, Equatable {
    /// Changes when the editor restarts, whose revisions start over.
    var session: String
    var revision: Int
    var screen: String?
    var dark: Bool
    var toggles: [String: Bool]
    var interaction: Int
}

/// The preview link's side in the editor. The preview device polls `GET /preview/state`,
/// fetches `GET /preview/file` when the revision changes, posts its SwiftUI renders to
/// `POST /preview/frame?item=home%23light&revision=7&interaction=2`, and a toggle tapped
/// on it to `POST /preview/toggle?node=airplane&on=1`. It runs next to `/mcp`.
extension EditorStore {
    func previewRoute(_ method: String, _ path: String, _ body: Data) -> (status: Int, contentType: String?, body: Data)? {
        let components = URLComponents(string: path)
        let query = components?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        switch (method, components?.path) {
        case ("GET", "/preview/state"):
            markPreviewDeviceSeen(udid: value("device"))
            // Until a preview window picks a screen, the device follows the selection.
            let target = previewing ?? previewTarget
            let state = PreviewState(
                session: previewSession, revision: revision, screen: target?.screen, dark: target?.dark ?? false,
                toggles: activePreviewToggles, interaction: previewInteraction
            )
            return (try? JSONEncoder().encode(state)).map { (200, "application/json", $0) }
        case ("GET", "/preview/file"):
            return (try? snapshot.encoded()).map { (200, "application/json", $0) }
        case ("POST", "/preview/frame"):
            guard let item = value("item"), let frameRevision = value("revision").flatMap(Int.init),
                let interaction = value("interaction").flatMap(Int.init)
            else { return (400, nil, Data()) }
            receiveNativeFrame(item: item, revision: frameRevision, interaction: interaction, png: body)
            return (200, nil, Data())
        case ("POST", "/preview/toggle"):
            guard let node = value("node"), let on = value("on") else { return (400, nil, Data()) }
            setPreviewToggle(node, on: on == "1")
            return (204, nil, Data())
        default:
            return nil
        }
    }
}

/// The iOS app launched with `-previewHost YES`: instead of the editor, it shows the screen
/// the editor previews as its own root view, live and interactive, and renders every screen
/// for the editor's preview window and for agents.
@MainActor @Observable
final class PreviewDevice {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "previewHost") }

    private(set) var file: CanvasFile?
    private(set) var state: PreviewState?
    private(set) var status = "Connecting…"
    @ObservationIgnored private var fetched: (session: String, revision: Int)?
    /// What the editor has of each screen and appearance, so a toggle re-renders only its screen.
    @ObservationIgnored private var uploaded: [String: (session: String, revision: Int, screen: ResolvedNode)] = [:]
    /// Renders wait for a quiet moment: each one blocks this app's main thread, which would
    /// stutter the screen the editor streams while someone edits or taps.
    @ObservationIgnored private var uploadDue: ContinuousClock.Instant?
    private static let uploadDelay = Duration.milliseconds(600)
    private let port: Int
    private let base: URL
    /// Without a cache: polling the same URL must always reach the editor.
    private let urlSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    init() {
        let port = UserDefaults.standard.integer(forKey: "previewPort")
        self.port = port > 0 ? port : 7341
        base = URL(string: "http://127.0.0.1:\(self.port)/preview")!
    }

    /// Names the simulator, so the editor's window can stream its screen.
    private var stateURL: URL {
        let udid = ProcessInfo.processInfo.environment["SIMULATOR_UDID"]
        return base.appending(path: "state").appending(queryItems: udid.map { [URLQueryItem(name: "device", value: $0)] } ?? [])
    }

    var screen: ResolvedNode? {
        state?.screen.flatMap { resolve(NodeID($0)) }
    }

    /// A screen as the preview shows it, with its switched toggles.
    private func resolve(_ id: NodeID) -> ResolvedNode? {
        guard let screen = try? file?.document.resolve(id) else { return nil }
        return screen.setting(.isOn, (state?.toggles ?? [:]).mapValues(Value.bool))
    }

    /// A toggle tapped here: the editor keeps it, so its window and agents see it too.
    func switched(_ node: String, on: Bool) {
        let url = base.appending(path: "toggle").appending(queryItems: [
            URLQueryItem(name: "node", value: node), URLQueryItem(name: "on", value: on ? "1" : "0"),
        ])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        Task { _ = try? await urlSession.data(for: request) }
    }

    func run() async {
        while !Task.isCancelled {
            await poll()
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private func poll() async {
        do {
            let (data, _) = try await urlSession.data(from: stateURL)
            let next = try JSONDecoder().decode(PreviewState.self, from: data)
            if fetched?.session != next.session || fetched?.revision != next.revision {
                let (contents, _) = try await urlSession.data(from: base.appending(path: "file"))
                file = try CanvasFile.decode(contents)
                fetched = (next.session, next.revision)
                state = next
                uploadDue = .now + Self.uploadDelay
            } else if next != state {
                state = next
                uploadDue = .now + Self.uploadDelay
            }
            if let due = uploadDue, due <= .now {
                uploadDue = nil
                await upload()
            }
            setStatus("Connected to the editor on :\(port)")
        } catch {
            setStatus("Waiting for the editor on :\(port)")
        }
    }

    /// Observation notifies on every assignment; polling shouldn't re-render the screen.
    private func setStatus(_ text: String) {
        if status != text { status = text }
    }

    /// Every screen in both appearances that the editor doesn't have as shown now, the
    /// previewed one first so the editor's window updates soonest.
    private func upload() async {
        guard let document = file?.document, let state else { return }
        let screens = document.canvasItems.filter { $0.kind == .screen }
            .sorted { first, _ in first.id.rawValue == state.screen }
        for node in screens {
            guard let screen = resolve(node.id) else { continue }
            for appearance in Appearance.allCases {
                let item = "\(node.id)#\(appearance.rawValue)"
                if let last = uploaded[item], last.session == state.session, last.revision == state.revision,
                    last.screen == screen
                {
                    continue
                }
                guard let png = NativeSnapshot.png(screen, tokens: document.tokens, appearance: appearance) else { continue }
                let url = base.appending(path: "frame").appending(queryItems: [
                    URLQueryItem(name: "item", value: item),
                    URLQueryItem(name: "revision", value: String(state.revision)),
                    URLQueryItem(name: "interaction", value: String(state.interaction)),
                ])
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                if (try? await urlSession.upload(for: request, from: png)) != nil {
                    uploaded[item] = (state.session, state.revision, screen)
                }
            }
        }
    }
}

struct PreviewDeviceView: View {
    @State private var device = PreviewDevice()

    var body: some View {
        Group {
            if let screen = device.screen, let file = device.file {
                NativeAppScreen(screen, tokens: file.document.tokens, appearance: device.state?.dark == true ? .dark : .light)
                    .id(screen.source)
                    .environment(\.nativeToggleSwitched, NativeToggleAction(owner: device) { [device] in device.switched($0, on: $1) })
            } else {
                ContentUnavailableView {
                    Label("Canvas Preview", systemImage: "iphone")
                } description: {
                    Text("\(device.status)\nClick Preview in the editor to show a screen here.")
                }
            }
        }
        .task { await device.run() }
    }
}

#if targetEnvironment(macCatalyst)
import Darwin

/// Starts this app in preview mode on a booted simulator that has it installed, preferring
/// one named "Canvas Preview": the preview takes over the simulator's screen, so a
/// simulator of its own keeps it from interrupting other work there.
enum SimulatorLauncher {
    static let simulatorName = "Canvas Preview"

    static func launchPreview(port: UInt16) {
        let bundle = Bundle.main.bundleIdentifier ?? "dev.pitcrew.canvas-editor"
        let uuid = "[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}"
        // The preview window streams the simulator's screen, so Simulator.app isn't opened.
        let script = """
            booted=$(/usr/bin/xcrun simctl list devices booted | grep '(Booted)')
            own=$(echo "$booted" | grep '\(simulatorName) (' | grep -oE '\(uuid)')
            others=$(echo "$booted" | grep -v '\(simulatorName) (' | grep -oE '\(uuid)')
            for udid in $own $others; do
              if /usr/bin/xcrun simctl get_app_container "$udid" \(bundle) >/dev/null 2>&1; then
                # Its own simulator shows the status bar designs use.
                if [ "$udid" = "$own" ]; then
                  /usr/bin/xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged \
                    --batteryLevel 100 --wifiBars 3 --cellularBars 4 --dataNetwork wifi >/dev/null 2>&1
                fi
                /usr/bin/xcrun simctl launch --terminate-running-process "$udid" \(bundle) -previewHost YES \
                  -previewPort \(port) && exit 0
              fi
            done
            exit 1
            """
        var pid: pid_t = 0
        let arguments = ["/bin/sh", "-c", script].map { strdup($0) } + [nil]
        let environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (arguments + environment).forEach { free($0) } }
        _ = posix_spawn(&pid, "/bin/sh", nil, nil, arguments, environment)
    }
}
#endif
