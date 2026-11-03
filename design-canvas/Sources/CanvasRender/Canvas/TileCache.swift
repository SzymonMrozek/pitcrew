import CanvasEngine
import CoreGraphics
import Foundation
import Metal

/// A laid-out screen or component placed on the page.
public struct SceneItem: Sendable {
    public let id: String
    public let origin: CGPoint
    public let layout: LayoutResult
    /// Changes whenever the item's pixels would, so its tiles redraw.
    public let version: Int

    public init(id: String, origin: CGPoint, layout: LayoutResult, version: Int) {
        self.id = id
        self.origin = origin
        self.layout = layout
        self.version = version
    }

    public var rect: CGRect { CGRect(origin: origin, size: layout.size) }
}

/// The canvas as map-style tiles: square textures of 512 px at power-of-two levels of
/// pixels per point, drawn from display lists with Core Graphics on background threads.
///
/// Only visible tiles at the level the zoom needs are drawn. While one is missing, a
/// coarser tile stands in, scaled, like a map loading. A tile whose items changed keeps
/// showing until its replacement is ready, so edits never flash.
@MainActor
public final class TileCache {
    public nonisolated static let tilePixels = 512
    nonisolated static let levels = -4...6
    static let capacity = 160

    struct Key: Hashable, Sendable {
        let level: Int
        let x: Int
        let y: Int
    }

    private struct Tile {
        let texture: MTLTexture
        let hash: Int
        var lastUsed: Int
    }

    public struct Draw {
        let texture: MTLTexture
        let rect: CGRect
        /// The part of the texture to show, in texture coordinates.
        let uv: CGRect
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var items: [SceneItem] = []
    private var tiles: [Key: Tile] = [:]
    private var pending: [Key: (hash: Int, operation: Operation)] = [:]
    private let workers: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private var frame = 0
    /// Called on the main actor when a tile finishes, to redraw.
    var onTileReady: (() -> Void)?

    init(device: MTLDevice, queue: MTLCommandQueue) {
        self.device = device
        self.queue = queue
    }

    func setItems(_ items: [SceneItem]) { self.items = items }

    nonisolated static func level(for displayScale: CGFloat) -> Int {
        min(max(Int(log2(max(displayScale, 0.01)).rounded(.up)), levels.lowerBound), levels.upperBound)
    }

    nonisolated static func pageRect(_ key: Key) -> CGRect {
        let size = tileSize(key.level)
        return CGRect(x: CGFloat(key.x) * size, y: CGFloat(key.y) * size, width: size, height: size)
    }

    nonisolated static func tileSize(_ level: Int) -> CGFloat { CGFloat(tilePixels) / pow(2, CGFloat(level)) }

    /// What to draw for the visible page rect, requesting tiles that are missing or stale.
    func draws(visible: CGRect, displayScale: CGFloat) -> [Draw] {
        frame += 1
        let level = Self.level(for: displayScale)
        let size = Self.tileSize(level)
        var current: [Draw] = []
        var fallbacks: [Draw] = []
        var wanted: Set<Key> = []
        let columns = Int((visible.minX / size).rounded(.down))...Int((visible.maxX / size).rounded(.down))
        let rows = Int((visible.minY / size).rounded(.down))...Int((visible.maxY / size).rounded(.down))
        for y in rows {
            for x in columns {
                let key = Key(level: level, x: x, y: y)
                let rect = Self.pageRect(key)
                let hits = items.filter { $0.rect.intersects(rect) }
                guard !hits.isEmpty else { continue }
                wanted.insert(key)
                let hash = Self.hash(hits)
                if var tile = tiles[key] {
                    tile.lastUsed = frame
                    tiles[key] = tile
                    current.append(Draw(texture: tile.texture, rect: rect, uv: CGRect(x: 0, y: 0, width: 1, height: 1)))
                    if tile.hash != hash { request(key, hash: hash, items: hits) }
                } else {
                    request(key, hash: hash, items: hits)
                    if let fallback = fallback(for: key) { fallbacks.append(fallback) }
                }
            }
        }
        // Tiles for a level the camera left aren't worth finishing.
        for (key, job) in pending where key.level != level && !wanted.contains(key) {
            job.operation.cancel()
            pending[key] = nil
        }
        evict()
        return fallbacks + current
    }

    /// The nearest coarser tile covering `key`, cropped to its area.
    private func fallback(for key: Key) -> Draw? {
        let rect = Self.pageRect(key)
        for steps in 1...4 {
            let parent = Key(level: key.level - steps, x: key.x >> steps, y: key.y >> steps)
            guard Self.levels.contains(parent.level), var tile = tiles[parent] else { continue }
            tile.lastUsed = frame
            tiles[parent] = tile
            let parentRect = Self.pageRect(parent)
            let uv = CGRect(
                x: (rect.minX - parentRect.minX) / parentRect.width, y: (rect.minY - parentRect.minY) / parentRect.height,
                width: rect.width / parentRect.width, height: rect.height / parentRect.height
            )
            return Draw(texture: tile.texture, rect: rect, uv: uv)
        }
        return nil
    }

    private static func hash(_ items: [SceneItem]) -> Int {
        var hasher = Hasher()
        for item in items {
            hasher.combine(item.id)
            hasher.combine(item.version)
            hasher.combine(item.origin.x)
            hasher.combine(item.origin.y)
        }
        return hasher.finalize()
    }

    private func request(_ key: Key, hash: Int, items: [SceneItem]) {
        if pending[key]?.hash == hash { return }
        pending[key]?.operation.cancel()
        let device = device
        let queue = queue
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard operation?.isCancelled == false, let texture = Self.render(key, items: items, device: device, queue: queue) else { return }
            Task { @MainActor in self?.finish(key, hash: hash, texture: texture) }
        }
        // Coarse tiles first: they stand in for everything finer.
        operation.queuePriority = key.level < 0 ? .high : .normal
        pending[key] = (hash, operation)
        workers.addOperation(operation)
    }

    private func finish(_ key: Key, hash: Int, texture: MTLTexture) {
        guard pending[key]?.hash == hash else { return }
        pending[key] = nil
        tiles[key] = Tile(texture: texture, hash: hash, lastUsed: frame)
        onTileReady?()
    }

    private func evict() {
        guard tiles.count > Self.capacity else { return }
        let old = tiles.sorted { $0.value.lastUsed < $1.value.lastUsed }.prefix(tiles.count - Self.capacity)
        for (key, _) in old { tiles[key] = nil }
    }

    /// Draws one tile's items into a mipmapped sRGB texture. Runs on a worker thread.
    nonisolated private static func render(_ key: Key, items: [SceneItem], device: MTLDevice, queue: MTLCommandQueue) -> MTLTexture? {
        let pixels = tilePixels
        let rect = pageRect(key)
        guard let context = Rasterizer.makeContext(width: pixels, height: pixels, scale: pow(2, CGFloat(key.level))) else { return nil }
        context.translateBy(x: -rect.minX, y: -rect.minY)
        for item in items {
            context.saveGState()
            context.translateBy(x: item.origin.x, y: item.origin.y)
            Rasterizer.drawItem(item.layout, in: context)
            context.restoreGState()
        }
        guard let data = context.data else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: pixels, height: pixels, mipmapped: true)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, pixels, pixels), mipmapLevel: 0, withBytes: data, bytesPerRow: context.bytesPerRow)
        if let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            commands.commit()
            commands.waitUntilCompleted()
        }
        return texture
    }
}
