import CanvasCore
import CanvasEngine
import CanvasMCP
import CanvasRender
import Observation
import SwiftUI

/// One rendered copy of a screen or component on the canvas. A screen can appear in
/// light and dark at once; both copies show the same document nodes.
struct CanvasItem: Identifiable {
    enum Content {
        case screen(ResolvedNode, ColorScheme)
        case component(name: String, root: ResolvedNode, ColorScheme)
        /// A group of tokens, built from the tokens rather than from document nodes.
        case tokens(name: String, root: ResolvedNode, ColorScheme)
    }

    let id: String
    let origin: CGPoint
    let content: Content
    /// The page the item is on.
    let page: CanvasPage

    var scheme: ColorScheme {
        switch content {
        case .screen(_, let scheme), .component(_, _, let scheme), .tokens(_, _, let scheme): scheme
        }
    }

    func moved(to origin: CGPoint) -> CanvasItem { CanvasItem(id: id, origin: origin, content: content, page: page) }
}

extension CanvasItem {
    var tree: ResolvedNode {
        switch content {
        case .screen(let screen, _): screen
        case .component(_, let root, _), .tokens(_, let root, _): root
        }
    }
}

/// A page of the canvas: one of the document's pages, or the tokens, which the editor
/// draws from the tokens and never stores.
enum CanvasPage: Hashable {
    case document(NodeID)
    case tokens
}

/// Which appearances the canvas draws. Screens show both side by side; components and
/// token boards, which sit close together, show light.
enum CanvasTheme: String, CaseIterable {
    case light = "Light"
    case dark = "Dark"
    case both = "Light and dark"

    var symbol: String {
        switch self {
        case .light: "sun.max"
        case .dark: "moon"
        case .both: "circle.lefthalf.filled"
        }
    }
}

/// How tall the canvas draws screens: cut at the device's screen, or as tall as their
/// content, with every list row and scroll view's content shown.
enum ScreenHeight: String, CaseIterable {
    case device = "Device height"
    case content = "Full content"

    var symbol: String {
        switch self {
        case .device: "iphone"
        case .content: "arrow.up.and.down.text.horizontal"
        }
    }
}

struct Selection: Equatable {
    let item: String
    let node: String
}

@MainActor @Observable
final class EditorStore {
    static let designer = "Designer"

    private(set) var document: CanvasDocument {
        didSet { rebuildItems() }
    }
    private var history = History()
    private(set) var selection: Selection?
    private var commentStore = CommentStore()
    /// Every change, from the UI or from MCP, is saved with the file.
    var comments: CommentStore {
        get { commentStore }
        set {
            commentStore = newValue
            persist()
        }
    }
    /// Comment tool: a tap pins a new comment instead of selecting.
    var isCommenting = false
    private(set) var selectedThread: String?
    /// The anchor of a comment being written.
    private(set) var draft: CommentAnchor?
    /// View preferences, kept across launches.
    var theme = UserDefaults.standard.string(forKey: "theme").flatMap(CanvasTheme.init(rawValue:)) ?? .both {
        didSet {
            guard theme != oldValue else { return }
            UserDefaults.standard.set(theme.rawValue, forKey: "theme")
            showItems()
        }
    }
    var screenHeight = UserDefaults.standard.string(forKey: "screenHeight").flatMap(ScreenHeight.init(rawValue:)) ?? .device {
        didSet {
            guard screenHeight != oldValue else { return }
            UserDefaults.standard.set(screenHeight.rawValue, forKey: "screenHeight")
            rebuildItems()
        }
    }
    /// The page on the canvas. Token boards aren't document nodes, so the Tokens page has
    /// no selection or comments.
    var page = CanvasPage.document(CanvasDocument.rootID) {
        didSet {
            guard page != oldValue else { return }
            if page == .tokens { isCommenting = false }
            if selection.map({ item in items.contains { $0.id == item.item } }) != true { clearSelection() }
            hovered = nil
            showItems()
            focusTarget = contentBounds.insetBy(dx: -80, dy: -80)
        }
    }
    var isOnTokens: Bool { page == .tokens }
    private(set) var lastError: String?
    private(set) var mcpStatus = "MCP off"
    /// Bumped by every document change, so views can refresh derived state.
    private(set) var revision = 0
    /// The node under the pointer, for the hover outline.
    var hovered: Selection?
    /// Draws the selection's padding and gaps on the canvas. Holding ⌥ shows them too.
    var showsSpacing = false
    /// The pointer's page point, for the comment cursor.
    private(set) var pointer: CGPoint?
    var isOptionDown = false
    /// The preview shown as a sheet where the platform has no windows.
    var previewSheet: PreviewTarget?
    /// The screen the preview device shows, set by the preview window.
    var previewing: PreviewTarget?
    /// SwiftUI renders from the preview device, keyed like canvas items, with the revision
    /// and preview interaction they show.
    private(set) var nativeFrames: [String: (revision: Int, interaction: Int, png: Data)] = [:]
    /// Toggles switched in the preview, keyed by resolved node ID. Like state in Xcode's
    /// previews, they last until the document changes.
    private var previewToggles: [String: Bool] = [:]
    @ObservationIgnored private var previewTogglesRevision = 0
    /// Bumped by every switch in the preview, so frames sort by what they show.
    private(set) var previewInteraction = 0
    @ObservationIgnored private var previewDeviceSeen: Date?
    /// The simulator the preview device runs in, which the Mac's preview window streams.
    private(set) var previewDeviceUDID: String?
    /// Tells the preview device that revisions started over.
    let previewSession = UUID().uuidString
    /// A page rect the canvas should bring into view, consumed by the view.
    var focusTarget: CGRect?

    /// Each item laid out by the engine, kept while its content key is unchanged.
    private var layoutCache: [String: (key: Int, layout: LayoutResult)] = [:]
    @ObservationIgnored private var mcp: (server: CanvasMCPServer, transport: HTTPTransport)?
    let file: CanvasFileStore
    enum FilePicker { case open, saveAs }
    var isPickingFile: FilePicker?

    /// Opens the file, or starts it from the sample document when it doesn't exist yet.
    init(file: CanvasFileStore = CanvasFileStore(url: CanvasFileStore.initialURL())) {
        self.file = file
        do {
            if let contents = try file.load() {
                document = contents.document
                commentStore = contents.comments
            } else {
                document = .sample()
                persist()
            }
        } catch {
            document = .sample()
            lastError = "Couldn't open \(file.fileName): \(error.localizedDescription)"
        }
        page = document.pages.first.map { .document($0.id) } ?? .tokens
        rebuildItems()
        file.onExternalChange = { [weak self] contents in self?.replaceContents(with: contents) }
    }

    // MARK: - File

    private func persist() {
        file.scheduleSave { [unowned self] in CanvasFile(document: document, comments: commentStore) }
    }

    /// Replaces everything with another file's contents. Undo history doesn't carry over.
    func replaceContents(with contents: CanvasFile) {
        document = contents.document
        commentStore = contents.comments
        if case .document(let id) = page, !document.pages.contains(where: { $0.id == id }) {
            page = document.pages.first.map { .document($0.id) } ?? .tokens
        }
        history = History()
        selection = nil
        selectedThread = nil
        draft = nil
        hovered = nil
        revision += 1
    }

    func open(_ url: URL) {
        do {
            if let contents = try file.switchTo(url) { replaceContents(with: contents) }
        } catch {
            lastError = "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func saveAs(_ url: URL) {
        do {
            try file.switchTo(url, writing: CanvasFile(document: document, comments: commentStore))
        } catch {
            lastError = "Couldn't save \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    var snapshot: CanvasFile { CanvasFile(document: document, comments: commentStore) }

    func layout(of item: String) -> LayoutResult? { layoutCache[item]?.layout }

    /// Every node's frame in an item, in item coordinates.
    func frames(of item: String) -> [String: CGRect] { layoutCache[item]?.layout.frames ?? [:] }

    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }

    /// The rendered screens and components on the page, in the theme. Pan, zoom and hover
    /// read it every frame, so it must not resolve the document each time.
    private(set) var items: [CanvasItem] = []
    /// Every page's items in every appearance, so agents can measure any of them.
    private var allItems: [CanvasItem] = []

    private func rebuildItems() {
        allItems = makeItems()
        var next: [String: (key: Int, layout: LayoutResult)] = [:]
        for item in allItems {
            let key = contentKey(of: item)
            if let cached = layoutCache[item.id], cached.key == key {
                next[item.id] = cached
            } else {
                next[item.id] = (key, makeLayout(item))
            }
        }
        layoutCache = next
        if screenHeight == .content { allItems = makingRoomForTallScreens(allItems) }
        showItems()
    }

    /// Screens drawn taller than their device would cover the rows below them, so each
    /// item moves down by how much the tallest screen grew in every row above it.
    private func makingRoomForTallScreens(_ items: [CanvasItem]) -> [CanvasItem] {
        var growth: [CanvasPage: [(bottom: CGFloat, extra: CGFloat)]] = [:]
        for item in items {
            guard case .screen(let screen, _) = item.content, let layout = layout(of: item.id) else { continue }
            let device = DeviceSpec.named(screen[.device]?.string)
            let extra = layout.size.height - device.size.height
            if extra > 0 { growth[item.page, default: []].append((item.origin.y + device.size.height, extra)) }
        }
        guard !growth.isEmpty else { return items }
        return items.map { item in
            let above = (growth[item.page] ?? []).filter { $0.bottom <= item.origin.y }
            let rows = Dictionary(grouping: above, by: \.bottom).values.map { $0.map(\.extra).max() ?? 0 }
            let shift = rows.reduce(0, +)
            return shift > 0 ? item.moved(to: CGPoint(x: item.origin.x, y: item.origin.y + shift)) : item
        }
    }

    /// Picks the page's items in the theme. With only dark, dark copies take the light ones'
    /// places.
    private func showItems() {
        items = allItems.compactMap { item in
            guard item.page == page else { return nil }
            let isDark = item.scheme == .dark
            switch theme {
            case .light: return isDark ? nil : item
            case .both:
                if case .screen = item.content { return item }
                return isDark ? nil : item
            case .dark:
                guard isDark else { return nil }
                if case .screen(let screen, _) = item.content,
                    let light = allItems.first(where: { $0.id == "\(screen.source)#light" })
                {
                    return item.moved(to: light.origin)
                }
                return item
            }
        }
    }

    /// The pages in the page list: the document's, then Tokens.
    var pageList: [(page: CanvasPage, name: String)] {
        document.pages.enumerated().map { index, node in
            (.document(node.id), node[.name]?.string ?? "Page \(index + 1)")
        } + [(.tokens, "Tokens")]
    }

    /// Adds a page after the last one and shows it.
    func addPage() {
        var edits: [Edit] = []
        var pages = document.pages
        // A file from before pages keeps its items on the root; they become the first page.
        if pages.first?.id == CanvasDocument.rootID {
            let first = Node(id: .random(), kind: .page, parent: CanvasDocument.rootID, order: FractionalIndex.between(nil, nil), props: [.name: .string("Page 1")])
            edits.append(.insert(first))
            for item in document.items(onPage: CanvasDocument.rootID) {
                edits.append(.move(item.id, parent: first.id, order: item.order))
            }
            pages = [first]
        }
        let order = FractionalIndex.between(pages.last?.order, nil)
        let node = Node(id: .random(), kind: .page, parent: CanvasDocument.rootID, order: order, props: [.name: .string("Page \(pages.count + 1)")])
        edits.append(.insert(node))
        perform(.batch(edits))
        page = .document(node.id)
    }

    func renamePage(_ id: NodeID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, document[id]?[.name]?.string != name else { return }
        perform(.set(id, .name, .string(name)))
    }

    private func makeLayout(_ item: CanvasItem) -> LayoutResult {
        switch item.content {
        case .screen(let screen, let scheme):
            LayoutEngine(tokens: document.tokens, appearance: scheme == .dark ? .dark : .light)
                .screen(screen, device: DeviceSpec.named(screen[.device]?.string), fitsContent: screenHeight == .content)
        case .component(_, let root, let scheme), .tokens(_, let root, let scheme):
            LayoutEngine(tokens: document.tokens, appearance: scheme == .dark ? .dark : .light).component(root)
        }
    }

    /// Items keep their IDs across themes: a screen is `<id>#light` and `<id>#dark`, a
    /// component its node ID, and its dark copy `<id>#dark`.
    private func makeItems() -> [CanvasItem] {
        let boards = document.tokens.boards().flatMap { board in
            [ColorScheme.light, .dark].map { scheme in
                CanvasItem(
                    id: "tokens/\(board.id)" + (scheme == .dark ? "#dark" : ""), origin: board.origin,
                    content: .tokens(name: board.title, root: board.root, scheme), page: .tokens
                )
            }
        }
        return document.pages.flatMap { page in
            document.items(onPage: page.id).flatMap { node -> [CanvasItem] in
                let origin = CGPoint(x: node[.x]?.number ?? 0, y: node[.y]?.number ?? 0)
                switch node.kind {
                case .screen:
                    guard let screen = try? document.resolve(node.id) else { return [] }
                    let darkOrigin = CGPoint(x: origin.x + 470, y: origin.y)
                    return [
                        CanvasItem(id: "\(node.id)#light", origin: origin, content: .screen(screen, .light), page: .document(page.id)),
                        CanvasItem(id: "\(node.id)#dark", origin: darkOrigin, content: .screen(screen, .dark), page: .document(page.id)),
                    ]
                case .component:
                    guard let root = document.children(of: node.id).first,
                        let resolved = try? document.resolve(root.id)
                    else { return [] }
                    let name = node[.name]?.string ?? node.id.rawValue
                    return [ColorScheme.light, .dark].map { scheme in
                        CanvasItem(
                            id: node.id.rawValue + (scheme == .dark ? "#dark" : ""), origin: origin,
                            content: .component(name: name, root: resolved, scheme), page: .document(page.id)
                        )
                    }
                default:
                    return []
                }
            }
        } + boards
    }

    func markPreviewDeviceSeen(udid: String?) {
        previewDeviceSeen = .now
        if let udid, udid != previewDeviceUDID { previewDeviceUDID = udid }
    }

    /// The preview device asked for the state within the last two seconds.
    var isPreviewDeviceConnected: Bool { previewDeviceSeen.map { $0.timeIntervalSinceNow > -2 } ?? false }

    func receiveNativeFrame(item: String, revision: Int, interaction: Int, png: Data) {
        let shown = nativeFrames[item].map { ($0.revision, $0.interaction) } ?? (-1, -1)
        if shown <= (revision, interaction) { nativeFrames[item] = (revision, interaction, png) }
    }

    /// The preview's switched toggles, while the document is unchanged since.
    var activePreviewToggles: [String: Bool] { previewTogglesRevision == revision ? previewToggles : [:] }

    func setPreviewToggle(_ node: String, on: Bool) {
        if previewTogglesRevision != revision {
            previewToggles = [:]
            previewTogglesRevision = revision
        }
        previewToggles[node] = on
        previewInteraction += 1
    }

    /// The screen the preview opens: the selected one, else the first on the page.
    var previewTarget: PreviewTarget? {
        let screens = document.canvasItems.filter { $0.kind == .screen }
        if let item = selection?.item {
            let parts = item.split(separator: "#").map(String.init)
            if let id = parts.first, screens.contains(where: { $0.id.rawValue == id }) {
                return PreviewTarget(screen: id, dark: parts.last == "dark")
            }
        }
        return screens.first.map { PreviewTarget(screen: $0.id.rawValue) }
    }

    var selectedNode: ResolvedNode? { context(of: selection)?.path.last }

    /// A selected or hovered node with its canvas item, its tree and the path down to it.
    struct NodeContext {
        let item: CanvasItem
        let tree: ResolvedNode
        /// From the tree's root down to the node.
        let path: [ResolvedNode]
        var node: ResolvedNode { path.last! }
        var ancestors: ArraySlice<ResolvedNode> { path.dropLast() }
    }

    func context(of selection: Selection?) -> NodeContext? {
        guard let selection, let item = items.first(where: { $0.id == selection.item }) else { return nil }
        let tree = item.tree
        guard let path = tree.path(to: selection.node) else { return nil }
        return NodeContext(item: item, tree: tree, path: path)
    }

    func canvasOrigin(item: String) -> CGPoint? {
        items.first { $0.id == item }?.origin
    }

    // MARK: - Design system

    /// The component a node belongs to: as an instance on a screen, or as the main
    /// component itself.
    struct ComponentInfo {
        let id: NodeID
        let name: String
        /// The instance the node was expanded from; nil inside the main component.
        let instance: Node?
        /// True for the instance's root or the main component's root.
        let isRoot: Bool
    }

    func component(of context: NodeContext) -> ComponentInfo? {
        let node = context.node
        if let instanceID = node.instance, let instance = document[instanceID],
            let component = instance[.component]?.string.map(NodeID.init(_:))
        {
            return ComponentInfo(id: component, name: name(ofComponent: component), instance: instance, isRoot: node.source == instanceID)
        }
        guard case .component = context.item.content else { return nil }
        let id = NodeID(context.item.id.replacingOccurrences(of: "#dark", with: ""))
        return ComponentInfo(id: id, name: name(ofComponent: id), instance: nil, isRoot: context.path.count == 1)
    }

    func name(ofComponent id: NodeID) -> String { document[id]?[.name]?.string ?? id.rawValue }

    /// How the inspector names a node: an instance by its component and first text,
    /// like `◇ SettingRow · Bluetooth`.
    func displayName(of node: ResolvedNode) -> String {
        guard node.instance == node.source, let instance = node.instance,
            let component = document[instance]?[.component]?.string
        else { return node.displayName }
        let name = "◇ " + name(ofComponent: NodeID(component))
        let text = node.first { $0.kind == .text && !($0[.text]?.string ?? "").isEmpty }?[.text]?.string
        return text.map { "\(name) · \($0)" } ?? name
    }

    var components: [Node] { document.canvasItems.filter { $0.kind == .component } }

    func instanceCount(of component: NodeID) -> Int {
        document.nodes.values.count { $0.kind == .instance && $0[.component]?.string == component.rawValue }
    }

    /// Selects a component's main definition and brings it into view.
    func showMainComponent(_ id: NodeID) {
        if let page = document.page(of: id) { self.page = .document(page) }
        guard let item = items.first(where: { $0.id == id.rawValue || $0.id == "\(id.rawValue)#dark" }) else { return }
        select(Selection(item: item.id, node: item.tree.id))
        focusTarget = pageRect(of: item).insetBy(dx: -200, dy: -200)
    }

    /// Where a new instance goes: right after the selected node, or after the instance
    /// it belongs to. Nil when nothing suitable is selected.
    private func insertionPoint() -> (parent: NodeID, order: String, resolvedID: String, item: String)? {
        guard let selection, let context = context(of: selection) else { return nil }
        let node = context.node
        let anchorID = node.instance ?? node.source
        guard let anchor = document[anchorID], let parent = anchor.parent, document[parent]?.kind != .page else { return nil }
        let index = document.children(of: parent).firstIndex { $0.id == anchorID } ?? 0
        let anchorResolved = context.path.last { $0.source == anchorID }?.id ?? node.id
        let prefix = anchorResolved.split(separator: "/").dropLast().joined(separator: "/")
        return (parent, document.orderKey(in: parent, at: index + 1), prefix, selection.item)
    }

    var canInsertInstance: Bool { insertionPoint() != nil }

    func insertInstance(of component: NodeID) {
        guard let point = insertionPoint() else { return }
        let id = NodeID.random()
        let node = Node(id: id, kind: .instance, parent: point.parent, order: point.order, props: [.component: .string(component.rawValue)])
        // An instance inside its own component would never finish resolving.
        var trial = document
        do {
            try trial.apply(.insert(node))
            for root in trial.canvasItems where root.kind == .screen { _ = try trial.resolve(root.id) }
            for component in trial.canvasItems where component.kind == .component {
                if let root = trial.children(of: component.id).first { _ = try trial.resolve(root.id) }
            }
        } catch {
            lastError = "Can't insert \(name(ofComponent: component)) here: \(error)"
            return
        }
        perform(.insert(node))
        let resolvedID = point.resolvedID.isEmpty ? id.rawValue : "\(point.resolvedID)/\(id.rawValue)"
        select(Selection(item: point.item, node: resolvedID))
    }

    /// The override an instance holds for a node's prop, if any.
    func override(of prop: Prop, on node: ResolvedNode) -> Value? {
        guard let instance = node.instance, let props = document[instance]?.overrides[node.source] else { return nil }
        return props[prop]
    }

    func resetOverride(_ prop: Prop, on node: ResolvedNode) {
        guard let instance = node.instance else { return }
        perform(.override(instance, target: node.source, prop, nil))
    }

    func resetOverrides(of instance: NodeID, target: NodeID) {
        guard let props = document[instance]?.overrides[target] else { return }
        perform(.batch(props.keys.map { .override(instance, target: target, $0, nil) }))
    }

    /// Measured padding and gaps of the selected node.
    var selectedSpacing: Spacing? {
        guard let context = context(of: selection) else { return nil }
        return Spacing(
            of: context.node.id, in: context.tree, frames: frames(of: context.item.id), rows: layout(of: context.item.id)?.rows ?? [:]
        )
    }

    // MARK: - Selection

    func select(_ selection: Selection?) {
        self.selection = selection
        selectedThread = nil
    }

    func selectThread(_ id: String) {
        if let anchor = comments.threads[id]?.anchor, !isOnPage(anchor) {
            if let node = anchor.node, let item = allItems.first(where: { $0.id == node.item }) {
                page = item.page
            } else if let free = anchor.page.map(NodeID.init(_:)), document[free] != nil {
                page = .document(free)
            }
        }
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
        comments.ordered.filter { ($0.isResolved == false || $0.id == selectedThread) && isOnPage($0.anchor) }
    }

    /// A free pin records its page; nil means the first one.
    private var freePinPage: String? {
        guard case .document(let id) = page, id != document.pages.first?.id else { return nil }
        return id.rawValue
    }

    /// A node pin is on the page of its item, a free pin on the page it records.
    private func isOnPage(_ anchor: CommentAnchor) -> Bool {
        if let node = anchor.node, let item = allItems.first(where: { $0.id == node.item }) { return item.page == page }
        guard case .document(let id) = page else { return false }
        return (anchor.page.map(NodeID.init(_:)) ?? document.pages.first?.id) == id
    }

    /// Where a pin's tip sits in page coordinates. A node pin follows its node's measured
    /// frame and falls back to its last known point when the node isn't rendered.
    func pinPoint(for anchor: CommentAnchor) -> CGPoint {
        if let node = anchor.node, let origin = canvasOrigin(item: node.item),
            let frame = frames(of: node.item)[node.node]
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
    /// `live` edits, such as typing, share one undo step while they target the same prop.
    func set(_ prop: Prop, to value: Value?, on node: ResolvedNode, live: Bool = false) {
        let key = live ? "\(node.instance?.rawValue ?? "")/\(node.source)/\(prop)" : nil
        if let instance = node.instance, instance != node.source {
            perform(.override(instance, target: node.source, prop, value), coalescing: key)
        } else {
            perform(.set(node.source, prop, value), coalescing: key)
        }
    }

    func perform(_ edit: Edit, coalescing key: String? = nil) {
        do {
            try apply(edit, coalescing: key)
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    func apply(_ edit: Edit, coalescing key: String?) throws {
        try history.perform(edit, on: &document, coalescing: key)
        revision += 1
        persist()
    }

    func undo() {
        try? history.undo(&document)
        revision += 1
        persist()
    }

    func redo() {
        try? history.redo(&document)
        revision += 1
        persist()
    }

    // MARK: - Canvas geometry

    func size(of item: CanvasItem) -> CGSize {
        layout(of: item.id)?.size ?? CGSize(width: 360, height: 60)
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
        return (item, local, layout(of: item.id)?.hitTest(local))
    }

    /// Figma's click: selects the outermost element under the pointer, or one at the
    /// depth of the current selection. `drill` (double click) goes one level deeper,
    /// `deep` (⌘ click) straight to the innermost element.
    func handleTap(atPage page: CGPoint, drill: Bool = false, deep: Bool = false) {
        guard !isOnTokens else { return }
        if let (item, local, node) = hit(atPage: page) {
            if isCommenting {
                startDraft(in: item, at: local, on: node, frame: node.flatMap { frames(of: item.id)[$0] })
            } else {
                let target = node.map { deep ? $0 : selectionTarget(in: item, innermost: $0, drill: drill) }
                select(target.map { Selection(item: item.id, node: $0) })
            }
        } else if isCommenting {
            startDraft(at: CommentAnchor(x: page.x, y: page.y, page: freePinPage))
        } else {
            clearSelection()
        }
    }

    /// System containers that a click passes through: their rows are what people pick.
    private static let passThrough: Set<Node.Kind> = [.screen, .navigationStack, .list, .section, .scroll]

    private func selectionTarget(in item: CanvasItem, innermost: String, drill: Bool) -> String {
        guard let path = item.tree.path(to: innermost) else { return innermost }
        let candidates = path.enumerated().filter { !Self.passThrough.contains($0.element.kind) }
        guard let outermost = candidates.first else { return innermost }
        guard let current = selection, current.item == item.id, let currentPath = item.tree.path(to: current.node) else {
            return outermost.element.id
        }
        if let index = candidates.firstIndex(where: { $0.element.id == current.node }) {
            // Inside the selection: a double click goes one level in.
            return drill ? candidates[min(index + 1, candidates.count - 1)].element.id : current.node
        }
        // Stay at the selection's depth: the innermost element whose parent contains the selection.
        let containing = Set(currentPath.dropLast().map(\.id))
        let sibling = candidates.last { $0.offset > 0 && containing.contains(path[$0.offset - 1].id) }
        return (sibling ?? outermost).element.id
    }

    /// The hover outline shows what a click would select, like Figma.
    func hover(atPage page: CGPoint?) {
        pointer = page
        guard !isOnTokens else { return }
        let hit = page.flatMap { self.hit(atPage: $0) }
        let next = hit.flatMap { hit in
            hit.node.map { Selection(item: hit.item.id, node: selectionTarget(in: hit.item, innermost: $0, drill: false)) }
        }
        if hovered != next { hovered = next }
    }

    /// The lines ⌥ or the Spacing toggle draw, in the selected item's coordinates. With ⌥
    /// over another element, the distance to it; over the selection itself, its insets
    /// to the nearest enclosing edges, the way Figma measures to the parent.
    var measurements: [Redline] {
        guard let selection, isOptionDown || showsSpacing, let spacing = selectedSpacing else { return [] }
        guard isOptionDown, let hovered, hovered.item == selection.item else { return spacing.redlines }
        if hovered == selection { return spacing.insetLines }
        guard let other = frames(of: selection.item)[hovered.node] else { return spacing.redlines }
        return Redlines.between(spacing.frame, other)
    }

    /// Changes whenever the pixels of an item would.
    func contentKey(of item: CanvasItem) -> Int {
        var hasher = Hasher()
        hasher.combine(document.tokens)
        switch item.content {
        case .screen(let screen, let scheme):
            hasher.combine(screen)
            hasher.combine(scheme == .dark)
            hasher.combine(screenHeight)
        case .component(_, let root, let scheme), .tokens(_, let root, let scheme):
            hasher.combine(root)
            hasher.combine(scheme == .dark)
        }
        return hasher.finalize()
    }

    /// Serves MCP on `127.0.0.1:<port>/mcp`. `CANVAS_MCP_PORT` overrides the port.
    /// The port of the MCP server and the preview link.
    var port: UInt16 { ProcessInfo.processInfo.environment["CANVAS_MCP_PORT"].flatMap(UInt16.init) ?? 7341 }

    func startMCP() {
        guard mcp == nil else { return }
        let port = port
        let server = CanvasMCPServer(host: self)
        do {
            let route: HTTPTransport.Route = { [weak self] method, path, body in
                await MainActor.run { self?.previewRoute(method, path, body) }
            }
            let transport = try HTTPTransport(port: port, route: route) { [weak server] body in
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
        try apply(edit, coalescing: nil)
    }

    var selected: (item: String, node: String)? {
        selection.map { ($0.item, $0.node) }
    }

    func measuredFrames(item: String) -> [String: CGRect] {
        frames(of: item)
    }

    func measuredRows(item: String) -> [String: CGRect] {
        layout(of: item)?.rows ?? [:]
    }

    func snapshotPNG(item: String) -> Data? {
        layout(of: item).flatMap { Rasterizer.png($0, scale: 3) }
    }

    /// On the Mac, SwiftUI draws macOS's controls and type, so native renders come from the
    /// preview device and only count while they show the current revision. On iOS the
    /// editor renders them itself.
    func nativeSnapshotPNG(item: String) -> Data? {
        #if targetEnvironment(macCatalyst)
        guard let frame = nativeFrames[item], frame.revision == revision else { return nil }
        return frame.png
        #else
        let parts = item.split(separator: "#").map(String.init)
        guard let id = parts.first, let screen = try? document.resolve(NodeID(id)), screen.kind == .screen else { return nil }
        return NativeSnapshot.png(screen, tokens: document.tokens, appearance: parts.last == "dark" ? .dark : .light)
        #endif
    }
}
