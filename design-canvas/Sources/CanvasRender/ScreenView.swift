import CanvasCore
import Observation
import SwiftUI

public struct Device: Sendable {
    public let name: String
    public let size: CGSize
    /// Status bar and home indicator areas, applied as the screen's safe area.
    public let safeArea: EdgeInsets
    public let cornerRadius: CGFloat

    public static let all: [Device] = [
        Device(
            name: "iPhone 17 Pro", size: CGSize(width: 402, height: 874),
            safeArea: EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0), cornerRadius: 54
        ),
        Device(
            name: "iPhone 17 Pro Max", size: CGSize(width: 440, height: 956),
            safeArea: EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0), cornerRadius: 54
        ),
        Device(
            name: "iPhone SE", size: CGSize(width: 375, height: 667),
            safeArea: EdgeInsets(top: 20, leading: 0, bottom: 0, trailing: 0), cornerRadius: 0
        ),
    ]

    public static func named(_ name: String?) -> Device {
        all.first { $0.name == name } ?? all[0]
    }
}

/// Measured frames of rendered nodes in screen points, keyed by resolved node ID.
/// The inspector, hit testing and agents read layout from here instead of
/// reimplementing SwiftUI layout.
///
/// Nodes report window coordinates, not a named coordinate space: rows inside a
/// `List` live in UIKit-hosted cells where named spaces don't resolve. The registry
/// converts with the measured frame of the screen root, which undoes canvas pan and zoom.
@MainActor @Observable
public final class FrameRegistry {
    private var windowFrames: [String: CGRect] = [:]
    private var rootFrame: CGRect = .zero
    private var rootWidth: CGFloat = 1

    public init() {}

    public var frames: [String: CGRect] {
        guard rootFrame.width > 0 else { return [:] }
        let scale = rootWidth / rootFrame.width
        return windowFrames.mapValues { frame in
            CGRect(
                x: (frame.minX - rootFrame.minX) * scale,
                y: (frame.minY - rootFrame.minY) * scale,
                width: frame.width * scale,
                height: frame.height * scale
            )
        }
    }

    func report(_ id: String, frame: CGRect) {
        if windowFrames[id] != frame { windowFrames[id] = frame }
    }

    /// The rendered root's size in points: the device for a screen, the measured
    /// content for a component.
    public var size: CGSize {
        guard rootFrame.width > 0 else { return .zero }
        let scale = rootWidth / rootFrame.width
        return CGSize(width: rootFrame.width * scale, height: rootFrame.height * scale)
    }

    func reportRoot(_ frame: CGRect, width: CGFloat) {
        if rootFrame != frame { rootFrame = frame }
        if rootWidth != width { rootWidth = width }
    }

    /// The smallest node containing `point`, which is the deepest one in practice.
    public func hitTest(_ point: CGPoint) -> String? {
        frames.filter { $0.value.contains(point) }
            .min { $0.value.width * $0.value.height < $1.value.width * $1.value.height }?
            .key
    }

    #if canImport(UIKit)
    /// The screen's hosting view, for pixel snapshots.
    @ObservationIgnored weak var hostView: UIView?

    /// The screen at device size and `scale` pixels per point, drawn by UIKit from the
    /// live hosted view. `ImageRenderer` can't do this: it draws placeholders for
    /// UIKit-backed views like `List`. Standard range keeps pixels in sRGB.
    public func snapshot(scale: CGFloat) -> UIImage? {
        guard let view = hostView, view.window != nil, view.bounds.width > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.preferredRange = .standard
        format.opaque = true
        return UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            _ = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
    }

    public func snapshotPNG() -> Data? {
        snapshot(scale: hostView?.window?.screen.scale ?? 3)?.pngData()
    }
    #endif
}

extension EnvironmentValues {
    @Entry var canvasTokens = TokenSet()
    @Entry var canvasFrames: FrameRegistry? = nil
}

/// A screen rendered in a device-sized frame with an iPhone environment: compact
/// size classes, the device's safe area, the screen's appearance and the document's tokens.
///
/// On UIKit platforms each screen gets its own hosting controller. That keeps the
/// screen's `NavigationStack` from merging with the editor's, and lets UIKit-backed
/// views (lists, bars) read real trait overrides instead of SwiftUI-only environment.
public struct ScreenView: View {

    let screen: ResolvedNode
    let tokens: TokenSet
    let colorScheme: ColorScheme
    let frames: FrameRegistry?

    public init(_ screen: ResolvedNode, tokens: TokenSet, colorScheme: ColorScheme, frames: FrameRegistry? = nil) {
        self.screen = screen
        self.tokens = tokens
        self.colorScheme = colorScheme
        self.frames = frames
    }

    public var device: Device { Device.named(screen[.device]?.string) }

    public var body: some View {
        let device = device
        let root = ScreenRoot(screen: screen, tokens: tokens, colorScheme: colorScheme, frames: frames, device: device)
        Group {
            #if canImport(UIKit)
            IsolatedHost(root: root, colorScheme: colorScheme, safeArea: device.safeArea)
            #else
            root
            #endif
        }
        .frame(width: device.size.width, height: device.size.height)
        // Measured outside the hosted root, whose own frame is already inset by the safe area.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { [frames] in
            frames?.reportRoot($0, width: device.size.width)
        }
        .clipShape(RoundedRectangle(cornerRadius: device.cornerRadius, style: .continuous))
    }
}

private struct ScreenRoot: View {
    let screen: ResolvedNode
    let tokens: TokenSet
    let colorScheme: ColorScheme
    let frames: FrameRegistry?
    let device: Device

    /// The hosting controller gets a new root only when something it draws changed;
    /// reassigning `rootView` re-renders the whole screen.
    func drawsSame(as other: ScreenRoot) -> Bool {
        screen == other.screen && tokens == other.tokens && colorScheme == other.colorScheme
            && frames === other.frames && device.name == other.device.name
    }

    var body: some View {
        // The root ignores the safe area so measured frames start at the device's
        // top-left corner; navigation and list content still inset for the bars.
        NodeView(screen)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Styling.systemColor("systemBackground") ?? .white)
            .ignoresSafeArea()
            // Inside the hosted root, so snapshots include it.
            .overlay(alignment: .top) {
                StatusBar(colorScheme: colorScheme, height: device.safeArea.top).ignoresSafeArea()
            }
            .environment(\.canvasTokens, tokens)
            .environment(\.canvasFrames, frames)
            .environment(\.colorScheme, colorScheme)
            #if os(iOS)
            .environment(\.horizontalSizeClass, .compact)
            .environment(\.verticalSizeClass, .regular)
            #endif
    }
}

#if canImport(UIKit)
private struct IsolatedHost: UIViewControllerRepresentable {
    let root: ScreenRoot
    let colorScheme: ColorScheme
    let safeArea: EdgeInsets

    func makeUIViewController(context: Context) -> UIHostingController<ScreenRoot> {
        let host = UIHostingController(rootView: root)
        host.view.backgroundColor = .clear
        root.frames?.hostView = host.view
        configure(host)
        return host
    }

    func updateUIViewController(_ host: UIHostingController<ScreenRoot>, context: Context) {
        if !host.rootView.drawsSame(as: root) { host.rootView = root }
        configure(host)
    }

    private func configure(_ host: UIHostingController<ScreenRoot>) {
        host.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        host.traitOverrides.horizontalSizeClass = .compact
        host.traitOverrides.verticalSizeClass = .regular
        host.traitOverrides.userInterfaceIdiom = .phone
        let insets = UIEdgeInsets(top: safeArea.top, left: safeArea.leading, bottom: safeArea.bottom, right: safeArea.trailing)
        if host.additionalSafeAreaInsets != insets { host.additionalSafeAreaInsets = insets }
    }
}
#endif

/// A drawn status bar, so screens read as a device on the canvas.
private struct StatusBar: View {
    let colorScheme: ColorScheme
    let height: CGFloat

    var body: some View {
        if height > 40 {
            HStack {
                Text("9:41").font(.system(size: 17, weight: .semibold)).frame(width: 110)
                Spacer()
                Capsule().fill(.black).frame(width: 124, height: 36)
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "cellularbars")
                    Image(systemName: "wifi")
                    Image(systemName: "battery.100")
                }
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 110)
            }
            .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
            .frame(height: height)
            .allowsHitTesting(false)
        }
    }
}

/// A component's root rendered on its own, at a row-like width, for the components
/// area of the canvas.
public struct ComponentPreview: View {
    let root: ResolvedNode
    let tokens: TokenSet
    let width: CGFloat
    let frames: FrameRegistry?

    public init(_ root: ResolvedNode, tokens: TokenSet, width: CGFloat = 360, frames: FrameRegistry? = nil) {
        self.root = root
        self.tokens = tokens
        self.width = width
        self.frames = frames
    }

    public var body: some View {
        NodeView(root)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(width: width, alignment: .leading)
            .background(Styling.systemColor("secondarySystemGroupedBackground") ?? .white)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { [frames, width] in
                frames?.reportRoot($0, width: width)
            }
            .environment(\.canvasTokens, tokens)
            .environment(\.canvasFrames, frames)
            #if os(iOS)
            .environment(\.horizontalSizeClass, .compact)
            #endif
    }
}
