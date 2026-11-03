import CanvasCore
import CoreGraphics
import Metal
import MetalKit
import simd

/// One item's footprint on the page: where its shadow and placeholder go.
public struct CanvasQuad: Equatable, Sendable {
    public var id: String
    public var rect: CGRect
    public var cornerRadius: CGFloat
    /// Shown until the item's tiles arrive.
    public var background: RGBA

    public init(id: String, rect: CGRect, cornerRadius: CGFloat, background: RGBA) {
        self.id = id
        self.rect = rect
        self.cornerRadius = cornerRadius
        self.background = background
    }
}

/// Draws the canvas: background, dot grid, each item's shadow and placeholder, then the
/// tiles that hold the items' pixels. Draws on demand only; nothing runs while idle.
@MainActor
public final class CanvasRenderer: NSObject {
    public let device: MTLDevice
    private let queue: MTLCommandQueue
    private let itemPipeline: MTLRenderPipelineState
    private let gridPipeline: MTLRenderPipelineState
    private let tilePipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let camera: CanvasCamera
    let tiles: TileCache

    public var quads: [CanvasQuad] = []
    /// Linear-light background, set by the view from the current appearance.
    var clearColor = MTLClearColor(red: 0.85, green: 0.85, blue: 0.86, alpha: 1)
    var gridColor = SIMD4<Float>(0, 0, 0, 0.12)
    var pixelRatio: Float = 2

    public init?(camera: CanvasCamera, device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let queue = device.makeCommandQueue() else { return nil }
        do {
            let library = try device.makeLibrary(source: Self.shaders, options: nil)
            itemPipeline = try Self.pipeline(device, library, vertex: "item_vertex", fragment: "item_fragment")
            gridPipeline = try Self.pipeline(device, library, vertex: "grid_vertex", fragment: "grid_fragment")
            tilePipeline = try Self.pipeline(device, library, vertex: "tile_vertex", fragment: "tile_fragment")
        } catch {
            assertionFailure("Canvas shaders: \(error)")
            return nil
        }
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else { return nil }
        self.device = device
        self.queue = queue
        self.sampler = sampler
        self.camera = camera
        tiles = TileCache(device: device, queue: queue)
    }

    /// The laid-out items whose pixels the tiles hold.
    public func setItems(_ items: [SceneItem]) { tiles.setItems(items) }

    // MARK: - Drawing

    private struct Uniforms {
        var viewSize: SIMD2<Float>
        var offset: SIMD2<Float>
        var scale: Float
        var pixelRatio: Float
    }

    private struct ItemData {
        var rect: SIMD4<Float>
        var tint: SIMD4<Float>
        var radius: Float
        /// 0 draws the item's placeholder, 1 its shadow.
        var mode: Float
        /// How far the quad extends past the rect, in page points, for the shadow blur.
        var expand: Float
        var padding: Float = 0
    }

    private struct TileData {
        var rect: SIMD4<Float>
        var uv: SIMD4<Float>
    }

    func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
            let commands = queue.makeCommandBuffer()
        else { return }
        pass.colorAttachments[0].clearColor = clearColor
        pass.colorAttachments[0].loadAction = .clear
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }

        var uniforms = Uniforms(
            viewSize: SIMD2(Float(camera.viewSize.width), Float(camera.viewSize.height)),
            offset: SIMD2(Float(camera.offset.x), Float(camera.offset.y)),
            scale: Float(camera.scale),
            pixelRatio: pixelRatio
        )

        encoder.setRenderPipelineState(gridPipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        var grid = gridColor
        encoder.setFragmentBytes(&grid, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        encoder.setRenderPipelineState(itemPipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)

        let visible = camera.visiblePageRect
        let margin = visible.insetBy(dx: -80, dy: -80)
        for quad in quads where quad.rect.intersects(margin) {
            let rect = SIMD4(Float(quad.rect.minX), Float(quad.rect.minY), Float(quad.rect.width), Float(quad.rect.height))
            let radius = Float(quad.cornerRadius)
            let blur = Float(18 / max(camera.scale, 0.25))
            let shadow = ItemData(rect: rect, tint: .zero, radius: radius, mode: 1, expand: blur)
            let placeholder = ItemData(rect: rect, tint: Self.linear(quad.background), radius: radius, mode: 0, expand: 0)
            for var data in [shadow, placeholder] {
                encoder.setVertexBytes(&data, length: MemoryLayout<ItemData>.stride, index: 1)
                encoder.setFragmentBytes(&data, length: MemoryLayout<ItemData>.stride, index: 1)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
        }

        encoder.setRenderPipelineState(tilePipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        let displayScale = CGFloat(pixelRatio) * camera.scale
        for draw in tiles.draws(visible: visible, displayScale: displayScale) {
            var data = TileData(
                rect: SIMD4(Float(draw.rect.minX), Float(draw.rect.minY), Float(draw.rect.width), Float(draw.rect.height)),
                uv: SIMD4(Float(draw.uv.minX), Float(draw.uv.minY), Float(draw.uv.width), Float(draw.uv.height))
            )
            encoder.setVertexBytes(&data, length: MemoryLayout<TileData>.stride, index: 1)
            encoder.setFragmentTexture(draw.texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }

    /// sRGB render targets take colors in linear light, premultiplied here.
    static func linear(_ color: RGBA) -> SIMD4<Float> {
        func channel(_ value: Double) -> Float {
            let value = Float(value)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let alpha = Float(color.alpha)
        return SIMD4(channel(color.red) * alpha, channel(color.green) * alpha, channel(color.blue) * alpha, alpha)
    }

    private static func pipeline(_ device: MTLDevice, _ library: MTLLibrary, vertex: String, fragment: String) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: vertex)
        descriptor.fragmentFunction = library.makeFunction(name: fragment)
        let color = descriptor.colorAttachments[0]!
        color.pixelFormat = .bgra8Unorm_srgb
        color.isBlendingEnabled = true
        color.sourceRGBBlendFactor = .one
        color.sourceAlphaBlendFactor = .one
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// Compiled at runtime, so the package needs no Metal build step or resource bundle.
    private static let shaders = """
        #include <metal_stdlib>
        using namespace metal;

        struct Uniforms { float2 viewSize; float2 offset; float scale; float pixelRatio; };
        struct ItemData { float4 rect; float4 tint; float radius; float mode; float expand; float padding; };
        struct ItemOut { float4 position [[position]]; float2 local; };
        struct TileData { float4 rect; float4 uv; };
        struct TileOut { float4 position [[position]]; float2 uv; };

        float2 toClip(float2 page, constant Uniforms& u) {
            float2 view = page * u.scale + u.offset;
            return float2(view.x / u.viewSize.x * 2.0 - 1.0, 1.0 - view.y / u.viewSize.y * 2.0);
        }

        // Signed distance to a rounded rectangle centered at the origin.
        float roundedRect(float2 p, float2 halfSize, float radius) {
            float2 q = abs(p) - halfSize + radius;
            return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
        }

        vertex ItemOut item_vertex(uint vid [[vertex_id]], constant Uniforms& u [[buffer(0)]], constant ItemData& item [[buffer(1)]]) {
            float2 corner = float2(vid & 1, vid >> 1);
            float2 shift = item.mode > 0.5 ? float2(0.0, item.expand * 0.25) : float2(0.0);
            float2 origin = item.rect.xy - item.expand + shift;
            float2 page = origin + corner * (item.rect.zw + 2.0 * item.expand);
            ItemOut out;
            out.position = float4(toClip(page, u), 0.0, 1.0);
            out.local = page - item.rect.xy - shift;
            return out;
        }

        fragment float4 item_fragment(ItemOut in [[stage_in]], constant Uniforms& u [[buffer(0)]], constant ItemData& item [[buffer(1)]]) {
            float2 halfSize = item.rect.zw * 0.5;
            float distance = roundedRect(in.local - halfSize, halfSize, item.radius);
            if (item.mode > 0.5) {
                float alpha = 0.22 * (1.0 - smoothstep(-item.expand * 0.5, item.expand, distance));
                return float4(0.0, 0.0, 0.0, alpha);
            }
            float pixel = 1.0 / (u.scale * u.pixelRatio);
            float coverage = clamp(0.5 - distance / pixel, 0.0, 1.0);
            if (coverage <= 0.0) { discard_fragment(); }
            return item.tint * coverage;
        }

        vertex TileOut tile_vertex(uint vid [[vertex_id]], constant Uniforms& u [[buffer(0)]], constant TileData& tile [[buffer(1)]]) {
            float2 corner = float2(vid & 1, vid >> 1);
            TileOut out;
            out.position = float4(toClip(tile.rect.xy + corner * tile.rect.zw, u), 0.0, 1.0);
            out.uv = tile.uv.xy + corner * tile.uv.zw;
            return out;
        }

        fragment float4 tile_fragment(TileOut in [[stage_in]], texture2d<float> texture [[texture(0)]], sampler smp [[sampler(0)]]) {
            return texture.sample(smp, in.uv);
        }

        struct GridOut { float4 position [[position]]; };

        vertex GridOut grid_vertex(uint vid [[vertex_id]]) {
            float2 corner = float2(vid & 1, vid >> 1);
            GridOut out;
            out.position = float4(corner.x * 2.0 - 1.0, 1.0 - corner.y * 2.0, 0.0, 1.0);
            return out;
        }

        // Dots every 16 page points, fading in as the canvas zooms past 60%.
        fragment float4 grid_fragment(GridOut in [[stage_in]], constant Uniforms& u [[buffer(0)]], constant float4& color [[buffer(1)]]) {
            float fade = smoothstep(0.6, 1.2, u.scale);
            if (fade <= 0.0) { discard_fragment(); }
            float2 view = in.position.xy / u.pixelRatio;
            float2 page = (view - u.offset) / u.scale;
            float2 cell = page - 16.0 * round(page / 16.0);
            float radius = 1.0 / u.scale;
            float alpha = (1.0 - smoothstep(radius * 0.5, radius, length(cell))) * fade * color.a;
            if (alpha <= 0.0) { discard_fragment(); }
            return float4(color.rgb * alpha, alpha);
        }
        """
}
