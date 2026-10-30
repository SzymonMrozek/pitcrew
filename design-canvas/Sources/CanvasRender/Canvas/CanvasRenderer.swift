import CoreGraphics
import Metal
import MetalKit
import simd

/// One textured rectangle on the page: a rendered screen or component.
public struct CanvasQuad: Equatable, Sendable {
    public var id: String
    public var rect: CGRect
    public var cornerRadius: CGFloat

    public init(id: String, rect: CGRect, cornerRadius: CGFloat) {
        self.id = id
        self.rect = rect
        self.cornerRadius = cornerRadius
    }
}

/// Draws the canvas: background, dot grid, and each quad as a cached texture with
/// rounded corners and a soft shadow. Draws on demand only; nothing runs while idle.
///
/// One draw call per quad keeps the code simple. Hundreds of screens would want a
/// texture array and instancing, which this layout allows without API changes.
@MainActor
public final class CanvasRenderer: NSObject {
    public let device: MTLDevice
    private let queue: MTLCommandQueue
    private let itemPipeline: MTLRenderPipelineState
    private let gridPipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let camera: CanvasCamera

    public var quads: [CanvasQuad] = []
    /// Linear-light background, set by the view from the current appearance.
    var clearColor = MTLClearColor(red: 0.85, green: 0.85, blue: 0.86, alpha: 1)
    var gridColor = SIMD4<Float>(0, 0, 0, 0.12)
    var pixelRatio: Float = 2

    private var textures: [String: (texture: MTLTexture, scale: CGFloat)] = [:]

    public init?(camera: CanvasCamera, device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let queue = device.makeCommandQueue() else { return nil }
        do {
            let library = try device.makeLibrary(source: Self.shaders, options: nil)
            itemPipeline = try Self.pipeline(device, library, vertex: "item_vertex", fragment: "item_fragment")
            gridPipeline = try Self.pipeline(device, library, vertex: "grid_vertex", fragment: "grid_fragment")
        } catch {
            assertionFailure("Canvas shaders: \(error)")
            return nil
        }
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .linear
        samplerDescriptor.maxAnisotropy = 4
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else { return nil }
        self.device = device
        self.queue = queue
        self.sampler = sampler
        self.camera = camera
    }

    // MARK: - Textures

    /// The pixels-per-point of the cached texture for a quad, if any.
    public func textureScale(for id: String) -> CGFloat? { textures[id]?.scale }

    /// Uploads a snapshot as an sRGB texture with mipmaps, so zoomed-out screens stay smooth.
    public func setTexture(_ image: CGImage, scale: CGFloat, for id: String) {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm_srgb, width: width, height: height, mipmapped: true
        )
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor),
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else { return }

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)

        if let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            commands.commit()
        }
        textures[id] = (texture, scale)
    }

    public func removeTextures(except ids: Set<String>) {
        textures = textures.filter { ids.contains($0.key) }
    }

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
        var hasTexture: Float
        /// 0 draws the item, 1 its shadow.
        var mode: Float
        /// How far the quad extends past the rect, in page points, for the shadow blur.
        var expand: Float
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
        encoder.setFragmentSamplerState(sampler, index: 0)

        let visible = camera.visiblePageRect.insetBy(dx: -80, dy: -80)
        for quad in quads where quad.rect.intersects(visible) {
            let texture = textures[quad.id]?.texture
            let rect = SIMD4(Float(quad.rect.minX), Float(quad.rect.minY), Float(quad.rect.width), Float(quad.rect.height))
            let radius = Float(quad.cornerRadius)
            let blur = Float(18 / max(camera.scale, 0.25))
            var shadow = ItemData(rect: rect, tint: .zero, radius: radius, hasTexture: 0, mode: 1, expand: blur)
            var item = ItemData(rect: rect, tint: SIMD4(1, 1, 1, 1), radius: radius, hasTexture: texture == nil ? 0 : 1, mode: 0, expand: 0)

            encoder.setVertexBytes(&shadow, length: MemoryLayout<ItemData>.stride, index: 1)
            encoder.setFragmentBytes(&shadow, length: MemoryLayout<ItemData>.stride, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

            encoder.setVertexBytes(&item, length: MemoryLayout<ItemData>.stride, index: 1)
            encoder.setFragmentBytes(&item, length: MemoryLayout<ItemData>.stride, index: 1)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
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
        struct ItemData { float4 rect; float4 tint; float radius; float hasTexture; float mode; float expand; };
        struct ItemOut { float4 position [[position]]; float2 local; };

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

        fragment float4 item_fragment(ItemOut in [[stage_in]], constant Uniforms& u [[buffer(0)]], constant ItemData& item [[buffer(1)]],
                                      texture2d<float> texture [[texture(0)]], sampler smp [[sampler(0)]]) {
            float2 halfSize = item.rect.zw * 0.5;
            float distance = roundedRect(in.local - halfSize, halfSize, item.radius);
            if (item.mode > 0.5) {
                float alpha = 0.22 * (1.0 - smoothstep(-item.expand * 0.5, item.expand, distance));
                return float4(0.0, 0.0, 0.0, alpha);
            }
            float pixel = 1.0 / (u.scale * u.pixelRatio);
            float coverage = clamp(0.5 - distance / pixel, 0.0, 1.0);
            if (coverage <= 0.0) { discard_fragment(); }
            float4 color = item.hasTexture > 0.5 ? texture.sample(smp, in.local / item.rect.zw) : item.tint;
            return color * coverage;
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
