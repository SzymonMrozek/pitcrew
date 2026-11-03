#if targetEnvironment(macCatalyst)
import Metal
import QuartzCore
import Synchronization
import SwiftUI
import UIKit

/// The preview device's screen, live: the simulator's framebuffer drawn as it updates, with
/// clicks and drags as touches, trackpad scrolling as a finger's drag and keys typed into it.
/// `onFailure` reports why streaming isn't possible, so the window falls back to renders.
struct SimulatorLiveView: UIViewRepresentable {
    let udid: String
    /// The device's screen corners, drawn by the layer so frames aren't masked offscreen.
    var cornerRadius: CGFloat = 0
    var onFirstFrame: () -> Void = {}
    var onFailure: (String) -> Void = { _ in }

    func makeUIView(context: Context) -> SimulatorScreenView {
        let view = SimulatorScreenView()
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ view: SimulatorScreenView, context: Context) {
        view.onFirstFrame = onFirstFrame
        view.onFailure = onFailure
        view.layer.cornerRadius = cornerRadius
        view.connect(udid)
    }

    static func dismantleUIView(_ view: SimulatorScreenView, coordinator: ()) {
        view.disconnect()
    }
}

final class SimulatorScreenView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    var onFirstFrame: () -> Void = {}
    var onFailure: (String) -> Void = { _ in }

    private var screen: SimulatorScreen?
    private var renderer: SimulatorRenderer?
    private var udid: String?
    /// Where a scroll gesture's finger went down, in the unit square.
    private var scrollStart: CGPoint?

    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
        metalLayer.contentsGravity = .resizeAspect
        metalLayer.isOpaque = false
        metalLayer.cornerCurve = .continuous
        metalLayer.masksToBounds = true
        isMultipleTouchEnabled = false
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
        scroll.allowedScrollTypesMask = .all
        scroll.allowedTouchTypes = []
        addGestureRecognizer(scroll)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func connect(_ udid: String) {
        guard udid != self.udid else { return }
        disconnect()
        self.udid = udid
        do {
            let screen = try SimulatorScreen(udid: udid)
            let renderer = SimulatorRenderer(layer: metalLayer) { [weak self] in
                Task { @MainActor in self?.onFirstFrame() }
            }
            screen.frameHandler = { renderer.draw($0) }
            self.screen = screen
            self.renderer = renderer
        } catch {
            onFailure(error.localizedDescription)
        }
    }

    func disconnect() {
        screen?.invalidate()
        screen = nil
        renderer = nil
        udid = nil
    }

    /// A point in the unit square of the screen the layer shows, aspect-fit in the view.
    private func unitPoint(_ location: CGPoint) -> CGPoint {
        let pixels = renderer?.pixelSize ?? .zero
        guard pixels.width > 0, pixels.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / pixels.width, bounds.height / pixels.height)
        let shown = CGSize(width: pixels.width * scale, height: pixels.height * scale)
        let origin = CGPoint(x: (bounds.width - shown.width) / 2, y: (bounds.height - shown.height) / 2)
        return CGPoint(x: (location.x - origin.x) / shown.width, y: (location.y - origin.y) / shown.height)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        becomeFirstResponder()
        send(.began, touches)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { send(.moved, touches) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { send(.ended, touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { send(.ended, touches) }

    private func send(_ phase: SimulatorTouchPhase, _ touches: Set<UITouch>) {
        guard let touch = touches.first else { return }
        screen?.sendTouch(phase, at: unitPoint(touch.location(in: self)))
    }

    /// iOS has no scroll wheel, so a scroll is a finger dragging the content, and lifting it
    /// at speed flings it, as on a device.
    @objc private func scrolled(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        switch gesture.state {
        case .began:
            let start = unitPoint(gesture.location(in: self))
            scrollStart = start
            screen?.sendTouch(.began, at: start)
        case .changed:
            guard let start = scrollStart else { return }
            screen?.sendTouch(.moved, at: moved(start, by: translation))
        default:
            guard let start = scrollStart else { return }
            screen?.sendTouch(.ended, at: moved(start, by: translation))
            scrollStart = nil
        }
    }

    private func moved(_ start: CGPoint, by translation: CGPoint) -> CGPoint {
        let origin = unitPoint(.zero)
        let unit = unitPoint(CGPoint(x: translation.x, y: translation.y))
        return CGPoint(x: start.x + unit.x - origin.x, y: start.y + unit.y - origin.y)
    }

    override var canBecomeFirstResponder: Bool { true }

    /// Keys go to the simulator, except shortcuts with ⌘, which stay the editor's.
    private func keys(_ presses: Set<UIPress>) -> [UIKey]? {
        let keys = presses.compactMap(\.key)
        guard screen != nil, !keys.contains(where: { $0.modifierFlags.contains(.command) }) else { return nil }
        return keys
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let keys = keys(presses) else { return super.pressesBegan(presses, with: event) }
        for key in keys { screen?.sendKey(UInt32(key.keyCode.rawValue), down: true) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let keys = keys(presses) else { return super.pressesEnded(presses, with: event) }
        for key in keys { screen?.sendKey(UInt32(key.keyCode.rawValue), down: false) }
    }
}

/// Draws the simulator's frames into the layer on the screen's frame queue, which is the
/// only caller of `draw`, so a busy main thread never holds a frame back.
private final class SimulatorRenderer: @unchecked Sendable {
    private let layer: CAMetalLayer
    private let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private let onFirstFrame: @Sendable () -> Void
    /// The texture over the current framebuffer, which the simulator replaces on rotation.
    private var texture: (surface: IOSurfaceRef, texture: MTLTexture)?
    private var drewFrame = false
    /// Frames the GPU hasn't finished. Past two, a frame is skipped rather than queued,
    /// so a slow moment shows the newest frame instead of a backlog.
    private let inFlight = Mutex(0)
    private let size = Mutex(CGSize.zero)

    init(layer: CAMetalLayer, onFirstFrame: @escaping @Sendable () -> Void) {
        self.layer = layer
        device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
        self.onFirstFrame = onFirstFrame
        layer.device = device
    }

    /// The framebuffer's size in pixels, for mapping clicks.
    var pixelSize: CGSize { size.withLock { $0 } }

    func draw(_ surface: IOSurfaceRef) {
        guard let device, let queue, inFlight.withLock({ $0 }) < 2 else { return }
        if texture?.surface !== surface {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: IOSurfaceGetWidth(surface), height: IOSurfaceGetHeight(surface),
                mipmapped: false
            )
            descriptor.usage = .shaderRead
            texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0).map { (surface, $0) }
        }
        guard let source = texture?.texture else { return }
        let pixels = CGSize(width: source.width, height: source.height)
        if layer.drawableSize != pixels {
            layer.drawableSize = pixels
            size.withLock { $0 = pixels }
        }
        guard let drawable = layer.nextDrawable(), let commands = queue.makeCommandBuffer(),
            let blit = commands.makeBlitCommandEncoder()
        else { return }
        blit.copy(from: source, to: drawable.texture)
        blit.endEncoding()
        inFlight.withLock { $0 += 1 }
        commands.addCompletedHandler { _ in self.inFlight.withLock { $0 -= 1 } }
        commands.present(drawable)
        commands.commit()
        if !drewFrame {
            drewFrame = true
            onFirstFrame()
        }
    }
}
#endif
