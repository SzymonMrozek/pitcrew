import CanvasCore
import CanvasMCP
import CanvasRender
import Observation
import SwiftUI

/// One rendered copy of a screen or component on the canvas. A screen can appear in
/// light and dark at once; both copies show the same document nodes.
struct CanvasItem: Identifiable {
    enum Content {
        case screen(ResolvedNode, ColorScheme)
        case component(name: String, root: ResolvedNode)
    }

    let id: String
    let origin: CGPoint
    let content: Content
}

struct Selection: Equatable {
    let item: String
    let node: String
}

@MainActor @Observable
final class EditorStore {
    private(set) var document: CanvasDocument
    private var history = History()
    var selection: Selection?
    var showsDarkCopies = true
    private(set) var lastError: String?
    private(set) var mcpStatus = "MCP off"

    /// Measured frames per canvas item. Not observed: views observe the registries.
    @ObservationIgnored private var registries: [String: FrameRegistry] = [:]
    @ObservationIgnored private var mcp: (server: CanvasMCPServer, transport: HTTPTransport)?

    init(document: CanvasDocument = .sample()) {
        self.document = document
    }

    func registry(for item: String) -> FrameRegistry {
        if let registry = registries[item] { return registry }
        let registry = FrameRegistry()
        registries[item] = registry
        return registry
    }

    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }

    var items: [CanvasItem] {
        document.children(of: CanvasDocument.rootID).flatMap { node -> [CanvasItem] in
            let origin = CGPoint(x: node[.x]?.number ?? 0, y: node[.y]?.number ?? 0)
            switch node.kind {
            case .screen:
                guard let screen = try? document.resolve(node.id) else { return [] }
                let light = CanvasItem(id: "\(node.id)#light", origin: origin, content: .screen(screen, .light))
                guard showsDarkCopies else { return [light] }
                let darkOrigin = CGPoint(x: origin.x + 470, y: origin.y)
                return [light, CanvasItem(id: "\(node.id)#dark", origin: darkOrigin, content: .screen(screen, .dark))]
            case .component:
                guard let root = document.children(of: node.id).first,
                    let resolved = try? document.resolve(root.id)
                else { return [] }
                let name = node[.name]?.string ?? node.id.rawValue
                return [CanvasItem(id: node.id.rawValue, origin: origin, content: .component(name: name, root: resolved))]
            default:
                return []
            }
        }
    }

    var selectedNode: ResolvedNode? {
        guard let selection, let item = items.first(where: { $0.id == selection.item }) else { return nil }
        let tree: ResolvedNode = switch item.content {
        case .screen(let screen, _): screen
        case .component(_, let root): root
        }
        return tree.first { $0.id == selection.node }
    }

    /// Edits a property of a resolved node. Inside an instance the edit becomes an
    /// override on that instance, like editing an instance layer in Figma.
    func set(_ prop: Prop, to value: Value?, on node: ResolvedNode) {
        if let instance = node.instance, instance != node.source {
            perform(.override(instance, target: node.source, prop, value))
        } else {
            perform(.set(node.source, prop, value))
        }
    }

    func perform(_ edit: Edit) {
        do {
            try apply(edit)
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    func undo() { try? history.undo(&document) }
    func redo() { try? history.redo(&document) }

    /// Serves MCP on `127.0.0.1:<port>/mcp`. `CANVAS_MCP_PORT` overrides the port.
    func startMCP(defaultPort: UInt16 = 7341) {
        guard mcp == nil else { return }
        let port = ProcessInfo.processInfo.environment["CANVAS_MCP_PORT"].flatMap(UInt16.init) ?? defaultPort
        let server = CanvasMCPServer(host: self)
        do {
            let transport = try HTTPTransport(port: port) { [weak server] body in
                await MainActor.run { server?.handle(data: body) }
            }
            transport.start { [weak self] state in
                let status: String = switch state {
                case .ready: "MCP :\(port)"
                case .failed(let error): "MCP failed: \(error)"
                default: "MCP …"
                }
                Task { @MainActor in self?.mcpStatus = status }
            }
            mcp = (server, transport)
        } catch {
            mcpStatus = "MCP failed: \(error)"
        }
    }
}

extension EditorStore: CanvasHost {
    func apply(_ edit: Edit) throws {
        try history.perform(edit, on: &document)
    }

    var selected: (item: String, node: String)? {
        selection.map { ($0.item, $0.node) }
    }

    func measuredFrames(item: String) -> [String: CGRect] {
        registries[item]?.frames ?? [:]
    }

    func snapshotPNG(item: String) -> Data? {
        if let png = registries[item]?.snapshotPNG() { return png }
        // Components are plain SwiftUI without UIKit-backed views, so ImageRenderer draws them.
        guard case .component(_, let root)? = items.first(where: { $0.id == item })?.content else { return nil }
        let renderer = ImageRenderer(content: ComponentPreview(root, tokens: document.tokens))
        renderer.scale = 3
        return renderer.uiImage?.pngData()
    }
}
