#if canImport(UIKit)
import MetalKit
import Observation
import SwiftUI
import UIKit

/// The camera and renderer of one canvas. The app keeps it to push textures and to
/// drive zoom from commands; the view keeps it to draw.
@MainActor
public final class CanvasScene {
    public let camera: CanvasCamera
    public let renderer: CanvasRenderer?
    weak var view: MTKView?

    public init(camera: CanvasCamera = CanvasCamera()) {
        self.camera = camera
        renderer = CanvasRenderer(camera: camera)
    }

    public func setNeedsDisplay() { view?.setNeedsDisplay() }

    /// Pixels per page point the display needs at the current zoom.
    public var displayScale: CGFloat { (view?.contentScaleFactor ?? 2) * camera.scale }
}

/// An on-demand MTKView with Figma-style navigation: two-finger trackpad scroll and
/// drag pan, pinch and ⌘ or ⌃ scroll zoom around the pointer, tap to hit test.
final class MetalCanvasUIView: MTKView {
    let scene: CanvasScene
    var onTap: ((CGPoint, CanvasClick) -> Void)?
    var onHover: ((CGPoint?) -> Void)?
    /// Reports whether ⌥ is held, for Figma's measure-on-hover.
    var onOptionKey: ((Bool) -> Void)?

    init(scene: CanvasScene) {
        self.scene = scene
        super.init(frame: .zero, device: scene.renderer?.device)
        colorPixelFormat = .bgra8Unorm_srgb
        isPaused = true
        enableSetNeedsDisplay = true
        autoResizeDrawable = true
        delegate = self
        scene.view = self

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        pan.allowedScrollTypesMask = .all
        pan.maximumNumberOfTouches = 2
        addGestureRecognizer(pan)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
        addGestureRecognizer(pinch)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.delegate = self
        addGestureRecognizer(tap)
        // Not exclusive with the single tap: the first click selects at once and the
        // second goes one level deeper, without delaying every click.
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = self
        addGestureRecognizer(doubleTap)
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(handleHover)))

        scene.renderer?.tiles.onTileReady = { [weak self] in self?.setNeedsDisplay() }
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: MetalCanvasUIView, _) in view.updateColors() }
        updateColors()
        observeCamera()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // First responder, so ⌥ presses reach the canvas without moving the pointer.
    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { becomeFirstResponder() }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: Self.isOption) { onOptionKey?(true) } else { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: Self.isOption) { onOptionKey?(false) } else { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: Self.isOption) { onOptionKey?(false) } else { super.pressesCancelled(presses, with: event) }
    }

    private static func isOption(_ press: UIPress) -> Bool {
        press.key?.keyCode == .keyboardLeftAlt || press.key?.keyCode == .keyboardRightAlt
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if scene.camera.viewSize != bounds.size { scene.camera.viewSize = bounds.size }
        scene.renderer?.pixelRatio = Float(contentScaleFactor)
        setNeedsDisplay()
    }

    // Redraw whenever the camera moves, including moves made by commands.
    private func observeCamera() {
        withObservationTracking {
            _ = scene.camera.offset
            _ = scene.camera.scale
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.setNeedsDisplay()
                self?.observeCamera()
            }
        }
    }

    private func updateColors() {
        let background = UIColor.systemGray5.resolvedColor(with: traitCollection)
        let dots = UIColor.label.resolvedColor(with: traitCollection).withAlphaComponent(0.14)
        scene.renderer?.clearColor = Self.linearClearColor(background)
        scene.renderer?.gridColor = Self.linearColor(dots)
        setNeedsDisplay()
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)
        if gesture.modifierFlags.contains(.command) || gesture.modifierFlags.contains(.control) {
            // Like Figma: scrolling up zooms in.
            scene.camera.zoom(by: exp(translation.y * 0.01), around: gesture.location(in: self))
        } else {
            scene.camera.pan(by: CGSize(width: translation.x, height: translation.y))
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        scene.camera.zoom(by: gesture.scale, around: gesture.location(in: self))
        gesture.scale = 1
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        becomeFirstResponder()
        onTap?(gesture.location(in: self), gesture.modifierFlags.contains(.command) ? .deep : .single)
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        onTap?(gesture.location(in: self), .double)
    }

    @objc private func handleHover(_ gesture: UIHoverGestureRecognizer) {
        switch gesture.state {
        case .began, .changed:
            onOptionKey?(gesture.modifierFlags.contains(.alternate))
            onHover?(gesture.location(in: self))
        default: onHover?(nil)
        }
    }

    // sRGB render targets take clear colors in linear light.
    private static func linearColor(_ color: UIColor) -> SIMD4<Float> {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func linear(_ value: CGFloat) -> Float {
            let value = Float(value)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return SIMD4(linear(red), linear(green), linear(blue), Float(alpha))
    }

    private static func linearClearColor(_ color: UIColor) -> MTLClearColor {
        let linear = linearColor(color)
        return MTLClearColor(red: Double(linear.x), green: Double(linear.y), blue: Double(linear.z), alpha: 1)
    }
}

extension MetalCanvasUIView: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gestureRecognizer is UITapGestureRecognizer && other is UITapGestureRecognizer
    }
}

/// How the canvas was clicked: once, twice, or with ⌘ to reach the innermost element.
public enum CanvasClick: Sendable {
    case single
    case double
    case deep
}

extension MetalCanvasUIView: MTKViewDelegate {
    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { scene.renderer?.draw(in: view) }
    }
}

public struct MetalCanvas: UIViewRepresentable {
    let scene: CanvasScene
    let quads: [CanvasQuad]
    let items: [SceneItem]
    let onTap: (CGPoint, CanvasClick) -> Void
    let onHover: (CGPoint?) -> Void
    let onOptionKey: (Bool) -> Void

    public init(
        scene: CanvasScene,
        quads: [CanvasQuad],
        items: [SceneItem],
        onTap: @escaping (CGPoint, CanvasClick) -> Void,
        onHover: @escaping (CGPoint?) -> Void = { _ in },
        onOptionKey: @escaping (Bool) -> Void = { _ in }
    ) {
        self.scene = scene
        self.quads = quads
        self.items = items
        self.onTap = onTap
        self.onHover = onHover
        self.onOptionKey = onOptionKey
    }

    public func makeUIView(context: Context) -> UIView {
        let view = MetalCanvasUIView(scene: scene)
        update(view)
        return view
    }

    public func updateUIView(_ view: UIView, context: Context) {
        guard let view = view as? MetalCanvasUIView else { return }
        update(view)
    }

    private func update(_ view: MetalCanvasUIView) {
        view.onTap = onTap
        view.onHover = onHover
        view.onOptionKey = onOptionKey
        if scene.renderer?.quads != quads {
            scene.renderer?.quads = quads
        }
        scene.renderer?.setItems(items)
        view.setNeedsDisplay()
    }
}
#endif
