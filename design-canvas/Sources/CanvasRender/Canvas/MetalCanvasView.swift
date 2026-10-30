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
    var onTap: ((CGPoint) -> Void)?
    var onHover: ((CGPoint?) -> Void)?

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
        addGestureRecognizer(tap)
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(handleHover)))

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: MetalCanvasUIView, _) in view.updateColors() }
        updateColors()
        observeCamera()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

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
            scene.camera.zoom(by: exp(-translation.y * 0.01), around: gesture.location(in: self))
        } else {
            scene.camera.pan(by: CGSize(width: translation.x, height: translation.y))
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        scene.camera.zoom(by: gesture.scale, around: gesture.location(in: self))
        gesture.scale = 1
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        onTap?(gesture.location(in: self))
    }

    @objc private func handleHover(_ gesture: UIHoverGestureRecognizer) {
        switch gesture.state {
        case .began, .changed: onHover?(gesture.location(in: self))
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

extension MetalCanvasUIView: MTKViewDelegate {
    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { scene.renderer?.draw(in: view) }
    }
}

public struct MetalCanvas: UIViewRepresentable {
    let scene: CanvasScene
    let quads: [CanvasQuad]
    let onTap: (CGPoint) -> Void
    let onHover: (CGPoint?) -> Void

    public init(scene: CanvasScene, quads: [CanvasQuad], onTap: @escaping (CGPoint) -> Void, onHover: @escaping (CGPoint?) -> Void = { _ in }) {
        self.scene = scene
        self.quads = quads
        self.onTap = onTap
        self.onHover = onHover
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
        if scene.renderer?.quads != quads {
            scene.renderer?.quads = quads
            view.setNeedsDisplay()
        }
    }
}
#endif
