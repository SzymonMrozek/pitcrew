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
    static let designer = "Designer"

    private(set) var document: CanvasDocument
    private var history = History()
    private(set) var selection: Selection?
    var comments = CommentStore()
    /// Comment tool: a tap pins a new comment instead of selecting.
    var isCommenting = false
    private(set) var selectedThread: String?
    /// The anchor of a comment being written.
    private(set) var draft: CommentAnchor?
    var showsDarkCopies = true
    private(set) var lastError: String?
    private(set) var mcpStatus = "MCP off"
    /// Bumped by every document change, so views can refresh derived state.
    private(set) var revision = 0
    /// The node under the pointer, for the hover outline.
    var hovered: Selection?

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

    func canvasOrigin(item: String) -> CGPoint? {
        items.first { $0.id == item }?.origin
    }

    // MARK: - Selection

    func select(_ selection: Selection?) {
        self.selection = selection
        selectedThread = nil
    }

    func selectThread(_ id: String) {
        selectedThread = id
        selection = nil
        draft = nil
    }

    func clearSelection() {
        selection = nil
        selectedThread = nil
        draft = nil
    }

    // MARK: - Comments

    /// Unresolved threads, plus the selected one even when resolved.
    var visibleThreads: [CommentThread] {
        comments.ordered.filter { !$0.isResolved || $0.id == selectedThread }
    }

    /// Where a pin's tip sits in page coordinates. A node pin follows its node's measured
    /// frame and falls back to its last known point when the node isn't rendered.
    func pinPoint(for anchor: CommentAnchor) -> CGPoint {
        if let node = anchor.node, let origin = canvasOrigin(item: node.item),
            let frame = registries[node.item]?.frames[node.node]
        {
            return CGPoint(x: origin.x + frame.minX + node.dx, y: origin.y + frame.minY + node.dy)
        }
        return CGPoint(x: anchor.x, y: anchor.y)
    }

    func startDraft(at anchor: CommentAnchor) {
        draft = anchor
        selection = nil
        selectedThread = nil
    }

    /// Starts a comment on a tap inside a canvas item, pinned to the node under the tap.
    func startDraft(in item: CanvasItem, at point: CGPoint, on node: String?, frame: CGRect?) {
        let page = CGPoint(x: item.origin.x + point.x, y: item.origin.y + point.y)
        var pinned: CommentAnchor.NodeAnchor?
        if let node, let frame {
            pinned = .init(item: item.id, node: node, dx: point.x - frame.minX, dy: point.y - frame.minY)
        }
        startDraft(at: CommentAnchor(x: page.x, y: page.y, node: pinned))
    }

    func postDraft(_ body: String) {
        guard let draft else { return }
        do {
            let thread = try comments.start(at: draft, author: Self.designer, body: body)
            self.draft = nil
            isCommenting = false
            selectedThread = thread.id
        } catch {
            lastError = String(describing: error)
        }
    }

    func cancelDraft() { draft = nil }

    func reply(to thread: String, _ body: String) {
        do { try comments.reply(to: thread, author: Self.designer, body: body) } catch { lastError = String(describing: error) }
    }

    func setResolved(_ thread: String, _ isResolved: Bool) {
        try? comments.setResolved(thread, isResolved)
    }

    func deleteThread(_ thread: String) {
        try? comments.delete(thread)
        if selectedThread == thread { selectedThread = nil }
    }

    // MARK: - Editing

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

    func undo() {
        try? history.undo(&document)
        revision += 1
    }

    func redo() {
        try? history.redo(&document)
        revision += 1
    }

    // MARK: - Canvas geometry

    func size(of item: CanvasItem) -> CGSize {
        switch item.content {
        case .screen(let screen, _): return Device.named(screen[.device]?.string).size
        case .component:
            let measured = registries[item.id]?.size ?? .zero
            return measured.width > 0 ? measured : CGSize(width: 360, height: 60)
        }
    }

    func pageRect(of item: CanvasItem) -> CGRect {
        CGRect(origin: item.origin, size: size(of: item))
    }

    var contentBounds: CGRect {
        items.map(pageRect(of:)).reduce(CGRect.null) { $0.union($1) }
    }

    /// The canvas item and node under a page point.
    func hit(atPage page: CGPoint) -> (item: CanvasItem, local: CGPoint, node: String?)? {
        guard let item = items.last(where: { pageRect(of: $0).contains(page) }) else { return nil }
        let local = CGPoint(x: page.x - item.origin.x, y: page.y - item.origin.y)
        return (item, local, registry(for: item.id).hitTest(local))
    }

    func handleTap(atPage page: CGPoint) {
        if let (item, local, node) = hit(atPage: page) {
            if isCommenting {
                startDraft(in: item, at: local, on: node, frame: node.flatMap { registry(for: item.id).frames[$0] })
            } else {
                select(node.map { Selection(item: item.id, node: $0) })
            }
        } else if isCommenting {
            startDraft(at: CommentAnchor(x: page.x, y: page.y))
        } else {
            clearSelection()
        }
    }

    func hover(atPage page: CGPoint?) {
        let hit = page.flatMap { self.hit(atPage: $0) }
        let next = hit.flatMap { hit in hit.node.map { Selection(item: hit.item.id, node: $0) } }
        if hovered != next { hovered = next }
    }

    /// Changes whenever the pixels of an item would.
    func contentKey(of item: CanvasItem) -> Int {
        var hasher = Hasher()
        hasher.combine(document.tokens)
        switch item.content {
        case .screen(let screen, let scheme):
            hasher.combine(screen)
            hasher.combine(scheme == .dark)
        case .component(_, let root):
            hasher.combine(root)
        }
        return hasher.finalize()
    }

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
        revision += 1
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
