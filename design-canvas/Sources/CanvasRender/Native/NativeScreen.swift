import CanvasCore
import CanvasEngine
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// A screen rendered with real SwiftUI at its device's size, in an iPhone environment:
/// compact size classes, the device's safe area, the appearance and the document's tokens.
/// Scroll views scroll and toggles switch; the engine draws the same screen on the canvas.
public struct NativeScreen: View {
    let screen: ResolvedNode
    let tokens: TokenSet
    let appearance: Appearance

    public init(_ screen: ResolvedNode, tokens: TokenSet, appearance: Appearance) {
        self.screen = screen
        self.tokens = tokens
        self.appearance = appearance
    }

    public var device: DeviceSpec { DeviceSpec.named(screen[.device]?.string) }

    public var body: some View {
        let device = device
        let root = NativeRoot(screen: screen, styling: NativeStyling(tokens: tokens, appearance: appearance), device: device)
        Group {
            #if canImport(UIKit)
            PhoneHost(root: root)
            #else
            root
            #endif
        }
        .frame(width: device.size.width, height: device.size.height)
        .clipShape(RoundedRectangle(cornerRadius: device.cornerRadius, style: .continuous))
    }
}

/// A screen as an app's root view, for running on an iPhone or the simulator: the system
/// draws the status bar and home indicator, and the device supplies the safe area.
public struct NativeAppScreen: View {
    let screen: ResolvedNode
    let styling: NativeStyling

    public init(_ screen: ResolvedNode, tokens: TokenSet, appearance: Appearance) {
        self.screen = screen
        styling = NativeStyling(tokens: tokens, appearance: appearance)
    }

    public var body: some View {
        NativeNodeView(screen)
            .background(Color(uiColorNamed: "systemBackground", styling: styling))
            .environment(\.nativeStyling, styling)
            .preferredColorScheme(styling.appearance == .dark ? .dark : .light)
    }
}

struct NativeRoot: View {
    let screen: ResolvedNode
    let styling: NativeStyling
    let device: DeviceSpec

    func drawsSame(as other: NativeRoot) -> Bool {
        screen == other.screen && styling.tokens == other.styling.tokens && styling.appearance == other.styling.appearance
            && device.name == other.device.name
    }

    var colorScheme: ColorScheme { styling.appearance == .dark ? .dark : .light }

    var body: some View {
        // Content keeps the safe area, like an app's root view; backgrounds extend under the bars.
        NativeNodeView(screen)
            .background(Color(uiColorNamed: "systemBackground", styling: styling))
            .overlay(alignment: .top) { StatusBar(device: device).ignoresSafeArea() }
            .environment(\.nativeStyling, styling)
            .environment(\.colorScheme, colorScheme)
            #if os(iOS)
            .environment(\.horizontalSizeClass, .compact)
            .environment(\.verticalSizeClass, .regular)
            #endif
    }
}

extension Color {
    fileprivate init(uiColorNamed name: String, styling: NativeStyling) {
        self = styling.color(.string(name)) ?? .clear
    }
}

/// The status bar, drawn so a screen reads as a device. It isn't part of the screen's content.
private struct StatusBar: View {
    let device: DeviceSpec

    var body: some View {
        if device.safeTop > 40 {
            let row = device.island?.midY ?? device.safeTop / 2
            ZStack {
                HStack {
                    Text("9:41").font(.system(size: 17, weight: .semibold)).frame(width: 110)
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: "cellularbars")
                        Image(systemName: "wifi")
                        Image(systemName: "battery.100")
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 110)
                }
                .position(x: device.size.width / 2, y: row)
                if let island = device.island {
                    Capsule().fill(.black)
                        .frame(width: island.width, height: island.height)
                        .position(x: island.midX, y: island.midY)
                }
            }
            .frame(width: device.size.width, height: device.safeTop)
            .foregroundStyle(.primary)
            .allowsHitTesting(false)
        }
    }
}

#if canImport(UIKit)
/// Each screen gets its own hosting controller. That keeps the screen's `NavigationStack`
/// from merging with the editor's, and lets UIKit-backed views (lists, bars) read real
/// trait overrides: the phone idiom, compact width and the device's safe area.
private struct PhoneHost: UIViewControllerRepresentable {
    let root: NativeRoot

    func makeUIViewController(context: Context) -> PhoneHostingController {
        PhoneHostingController(root: root)
    }

    func updateUIViewController(_ host: PhoneHostingController, context: Context) {
        host.update(root)
    }
}

final class PhoneHostingController: UIHostingController<NativeRoot> {
    init(root: NativeRoot) {
        super.init(rootView: root)
        view.backgroundColor = .clear
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func update(_ root: NativeRoot) {
        // A new root re-renders the whole screen, so only assign one that draws differently.
        if !rootView.drawsSame(as: root) { rootView = root }
        configure()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        fitSafeArea()
    }

    private func configure() {
        overrideUserInterfaceStyle = rootView.colorScheme == .dark ? .dark : .light
        traitOverrides.horizontalSizeClass = .compact
        traitOverrides.verticalSizeClass = .regular
        traitOverrides.userInterfaceIdiom = .phone
        fitSafeArea()
    }

    /// The device's safe area, whatever the window around the preview adds.
    private func fitSafeArea() {
        let device = rootView.device
        let current = view.safeAreaInsets
        let inherited = UIEdgeInsets(
            top: current.top - additionalSafeAreaInsets.top, left: current.left - additionalSafeAreaInsets.left,
            bottom: current.bottom - additionalSafeAreaInsets.bottom, right: current.right - additionalSafeAreaInsets.right
        )
        let wanted = UIEdgeInsets(
            top: device.safeTop - inherited.top, left: -inherited.left, bottom: device.safeBottom - inherited.bottom,
            right: -inherited.right
        )
        if additionalSafeAreaInsets != wanted { additionalSafeAreaInsets = wanted }
    }
}

/// Native renders as PNGs, for agents comparing SwiftUI with the canvas.
@MainActor
public enum NativeSnapshot {
    /// Draws the screen with SwiftUI in a window behind the editor's, at `scale` pixels
    /// per point. `ImageRenderer` can't: it draws placeholders for UIKit-backed views like `List`.
    public static func png(_ screen: ResolvedNode, tokens: TokenSet, appearance: Appearance, scale: CGFloat = 3) -> Data? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return nil }
        let root = NativeRoot(screen: screen, styling: NativeStyling(tokens: tokens, appearance: appearance), device: DeviceSpec.named(screen[.device]?.string))
        let size = root.device.size
        let window = UIWindow(windowScene: scene)
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue - 1)
        window.frame = CGRect(origin: .zero, size: size)
        let host = PhoneHostingController(root: root)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.frame = CGRect(origin: .zero, size: size)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.preferredRange = .standard
        format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds, format: format).image { _ in
            _ = host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        return image.pngData()
    }
}
#endif
