import CanvasCore
import CoreGraphics
import Foundation

/// The live editor, as the MCP server sees it. Agents read and write the same document
/// the designer has open, so they see the current selection, measured layout and pixels.
@MainActor
public protocol CanvasHost: AnyObject {
    var document: CanvasDocument { get }
    /// Applies an edit through the editor's history, so the designer can undo it.
    func apply(_ edit: Edit) throws
    /// The selected canvas item (`settings#light`) and resolved node ID.
    var selected: (item: String, node: String)? { get }
    /// Measured frames in screen points for one rendered canvas item.
    func measuredFrames(item: String) -> [String: CGRect]
    /// The list row each row's content sits in, keyed like `measuredFrames`.
    func measuredRows(item: String) -> [String: CGRect]
    func snapshotPNG(item: String) -> Data?
    /// The same screen rendered with real SwiftUI, or nil where SwiftUI can't render it.
    func nativeSnapshotPNG(item: String) -> Data?
    /// Page position of a canvas item's top-left corner.
    func canvasOrigin(item: String) -> CGPoint?
    var comments: CommentStore { get set }
}

extension CanvasHost {
    public func measuredRows(item: String) -> [String: CGRect] { [:] }
    public func nativeSnapshotPNG(item: String) -> Data? { nil }
}

/// MCP over JSON-RPC: `initialize`, `ping`, `tools/list` and `tools/call`.
/// Transport-agnostic; `HTTPTransport` serves it on localhost.
@MainActor
public final class CanvasMCPServer {
    public static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    private weak var host: (any CanvasHost)?
    /// Author name for agent comments, from the client's `initialize`.
    private var clientName = "agent"

    public init(host: any CanvasHost) {
        self.host = host
    }

    /// Handles one JSON-RPC message. Returns nil for notifications.
    public func handle(_ message: JSON) -> JSON? {
        guard let method = message["method"]?.string else {
            return message["id"].map { failure(id: $0, code: -32600, "Invalid request") }
        }
        guard let id = message["id"] else { return nil }
        let params = message["params"] ?? [:]

        switch method {
        case "initialize":
            if let name = params["clientInfo"]?["name"]?.string, !name.isEmpty { clientName = name }
            let requested = params["protocolVersion"]?.string ?? ""
            let version = Self.supportedVersions.contains(requested) ? requested : Self.supportedVersions[0]
            return success(id: id, [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "design-canvas", "version": "0.1.0"],
                "instructions": .string(Self.instructions),
            ])
        case "ping":
            return success(id: id, [:])
        case "tools/list":
            return success(id: id, ["tools": .array(Self.tools)])
        case "tools/call":
            guard let name = params["name"]?.string else { return failure(id: id, code: -32602, "Missing tool name") }
            return success(id: id, call(name, arguments: params["arguments"] ?? [:]))
        default:
            return failure(id: id, code: -32601, "Unknown method \(method)")
        }
    }

    public func handle(data: Data) -> Data? {
        guard let message = try? JSONDecoder().decode(JSON.self, from: data) else {
            return failure(id: .null, code: -32700, "Parse error").serialized()
        }
        return handle(message)?.serialized()
    }

    // MARK: - Tools

    private struct ToolError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    private func call(_ name: String, arguments: JSON) -> JSON {
        guard let host else { return toolError("The editor is not running") }
        do {
            switch name {
            case "list_items": return text(listItems(host))
            case "get_tree": return text(try tree(host, arguments))
            case "inspect_node": return text(try inspect(host, arguments))
            case "get_selection": return text(try selection(host))
            case "get_tokens": return text(tokens(host.document.tokens))
            case "screenshot": return try screenshot(host, arguments)
            case "set_property": return text(try setProperty(host, arguments))
            case "apply_edits": return text(try applyEdits(host, arguments))
            case "list_comments": return text(listComments(host, arguments))
            case "add_comment": return text(try addComment(host, arguments))
            case "resolve_comment": return text(try resolveComment(host, arguments))
            default: return toolError("Unknown tool \(name)")
            }
        } catch let error as ToolError {
            return toolError(error.message)
        } catch {
            return toolError(String(describing: error))
        }
    }

    private struct Root {
        let node: Node
        let tree: ResolvedNode
        /// The canvas item whose measured frames describe this tree.
        let item: String
    }

    private func roots(_ document: CanvasDocument) -> [Root] {
        document.children(of: CanvasDocument.rootID).compactMap { node in
            switch node.kind {
            case .screen:
                return (try? document.resolve(node.id)).map { Root(node: node, tree: $0, item: "\(node.id)#light") }
            case .component:
                guard let root = document.children(of: node.id).first, let tree = try? document.resolve(root.id)
                else { return nil }
                return Root(node: node, tree: tree, item: node.id.rawValue)
            default:
                return nil
            }
        }
    }

    /// The resolved node, its ancestors (outermost first) and the root it belongs to.
    private func find(_ id: String, in document: CanvasDocument) throws -> (ResolvedNode, [ResolvedNode], Root) {
        for root in roots(document) {
            if let path = root.tree.path(to: id) {
                return (path.last!, Array(path.dropLast()), root)
            }
        }
        throw ToolError("No node \(id). Use get_tree for resolved IDs; nodes inside instances use instance/node paths.")
    }

    private func item(_ root: Root, appearance: String?) -> String {
        guard root.node.kind == .screen, let appearance else { return root.item }
        return "\(root.node.id)#\(appearance)"
    }

    private func listItems(_ host: any CanvasHost) -> JSON {
        .array(roots(host.document).map { root in
            var entry: [String: JSON] = [
                "id": .string(root.node.id.rawValue),
                "kind": .string(root.node.kind.rawValue),
                "name": .string(root.node[.name]?.string ?? root.node.id.rawValue),
                "root": .string(root.tree.id),
            ]
            if let device = root.node[.device]?.string { entry["device"] = .string(device) }
            return .object(entry)
        })
    }

    private func tree(_ host: any CanvasHost, _ arguments: JSON) throws -> JSON {
        guard let id = arguments["node_id"]?.string else { throw ToolError("node_id is required") }
        let document = host.document
        let roots = roots(document)
        let (node, _, root) = try roots.first { $0.node.id.rawValue == id }
            .map { ($0.tree, [], $0) } ?? find(id, in: document)
        let frames = host.measuredFrames(item: item(root, appearance: arguments["appearance"]?.string))
        return Self.treeJSON(node, frames: frames, depth: arguments["depth"]?.int)
    }

    private func inspect(_ host: any CanvasHost, _ arguments: JSON) throws -> JSON {
        guard let id = arguments["node_id"]?.string else { throw ToolError("node_id is required") }
        let document = host.document
        let (node, ancestors, root) = try find(id, in: document)
        let measured = item(root, appearance: arguments["appearance"]?.string)
        let frames = host.measuredFrames(item: measured)
        guard case .object(var result) = Self.treeJSON(node, frames: frames, depth: 0) else { return [:] }

        result["ancestors"] = .array(ancestors.map { .string("\($0.kind.rawValue) \($0.id)") })
        result["children"] = .array(node.children.map { .string("\($0.kind.rawValue) \($0.id)") })
        var resolvedTokens: [String: JSON] = [:]
        for (prop, value) in node.props {
            guard case .token(let token) = value else { continue }
            resolvedTokens[prop.rawValue] = tokenJSON(token, in: document.tokens)
        }
        if !resolvedTokens.isEmpty { result["tokens"] = .object(resolvedTokens) }
        // Literal values where the design system has tokens of that kind: candidates to bind.
        let unbound = node.props.keys.sorted().filter { prop in
            guard let kind = prop.tokenKind, !document.tokens.ids(of: kind).isEmpty else { return false }
            if case .token? = node[prop] { return false }
            // `infinity` is a frame limit, not a number a token could stand for.
            return node[prop] != .string("infinity")
        }
        if !unbound.isEmpty {
            result["unbound"] = .object(Dictionary(uniqueKeysWithValues: unbound.map { prop in
                (prop.rawValue, JSON.array(document.tokens.ids(of: prop.tokenKind!).map { .string($0.rawValue) }))
            }))
        }
        if let instance = node.instance, let component = document[instance]?[.component]?.string {
            let name = document[NodeID(component)]?[.name]?.string ?? component
            var info: [String: JSON] = ["component": .string(component), "name": .string(name), "instance": .string(instance.rawValue)]
            if instance == node.source, let overrides = document[instance]?.overrides, !overrides.isEmpty {
                info["overrides"] = .object(Dictionary(uniqueKeysWithValues: overrides.map { target, props in
                    (target.rawValue, JSON.object(Dictionary(uniqueKeysWithValues: props.map { ($0.key.rawValue, JSON.string($0.value.description)) })))
                }))
            }
            result["component"] = .object(info)
        }
        if let spacing = Spacing(of: node.id, in: root.tree, frames: frames, rows: host.measuredRows(item: measured)) {
            // Padding to the parent per side, and gaps to the neighbours.
            var entry: [String: JSON] = [:]
            if let container = spacing.container {
                entry["container"] = .string(container)
                entry["measured_to"] = .string(spacing.inRow ? "list row in container" : "container")
            }
            for inset in spacing.insets { entry[inset.side.rawValue] = .number(Self.rounded(inset.value)) }
            for (key, gap) in [("gap_to_previous", spacing.previous), ("gap_to_next", spacing.next)] {
                if let gap { entry[key] = ["sibling": .string(gap.sibling), "value": .number(Self.rounded(gap.value))] }
            }
            result["spacing"] = .object(entry)
        }
        if let instance = node.instance, instance != node.source {
            result["editing"] = .string(
                "Inside instance \(instance) of a component. set_property writes an override on that instance; "
                    + "edit \(node.source) directly to change every instance."
            )
        }
        return .object(result)
    }

    /// Points to one decimal, which is what a designer reads.
    private static func rounded(_ value: CGFloat) -> Double { (Double(value) * 10).rounded() / 10 }

    private func selection(_ host: any CanvasHost) throws -> JSON {
        guard let selected = host.selected else { return ["selected": nil] }
        let appearance = selected.item.split(separator: "#").dropFirst().first.map(String.init)
        var arguments: [String: JSON] = ["node_id": .string(selected.node)]
        if let appearance { arguments["appearance"] = .string(appearance) }
        return ["item": .string(selected.item), "node": try inspect(host, .object(arguments))]
    }

    private func tokens(_ tokens: TokenSet) -> JSON {
        var entries: [String: JSON] = [:]
        for id in tokens.tokens.keys { entries[id.rawValue] = tokenJSON(id, in: tokens) }
        return ["modes": .array(tokens.modes.map(JSON.string)), "tokens": .object(entries)]
    }

    private func tokenJSON(_ id: TokenID, in tokens: TokenSet) -> JSON {
        var modes: [String: JSON] = ["token": .string(id.rawValue)]
        if let kind = tokens.kind(of: id) { modes["kind"] = .string(kind.rawValue) }
        for mode in tokens.modes {
            let value: JSON = switch try? tokens.resolve(id, mode: mode) {
            case .color(let rgba): .string(rgba.hex)
            case .system(let name): .string("system:\(name)")
            case .number(let number): .number(number)
            case .textStyle(let style): .string("textStyle:\(style)")
            case .alias(let target): .string("alias:\(target)")
            case nil: .null
            }
            modes[mode] = value
        }
        if case .alias(let target)? = tokens.tokens[id]?.values[TokenSet.defaultMode] {
            modes["alias"] = .string(target.rawValue)
        }
        return .object(modes)
    }

    private func screenshot(_ host: any CanvasHost, _ arguments: JSON) throws -> JSON {
        guard let id = arguments["screen_id"]?.string else { throw ToolError("screen_id is required") }
        let appearance = arguments["appearance"]?.string ?? "light"
        guard let root = roots(host.document).first(where: { $0.node.id.rawValue == id }) else {
            throw ToolError("No screen or component \(id). Use list_items.")
        }
        let item = item(root, appearance: appearance)
        let caption: String
        let png: Data?
        switch arguments["renderer"]?.string ?? "canvas" {
        case "canvas":
            png = host.snapshotPNG(item: item)
            caption = "\(item), drawn by the canvas engine, at 3 pixels per point"
        case "native":
            guard root.node.kind == .screen else { throw ToolError("Only screens render natively") }
            guard let native = host.nativeSnapshotPNG(item: item) else {
                throw ToolError("No SwiftUI render of \(item) for the current document yet. Open Preview in the editor, which runs it on the iOS Simulator, then retry.")
            }
            png = native
            caption = "\(item), rendered by SwiftUI on iOS, at 3 pixels per point"
        case let other:
            throw ToolError("Unknown renderer \(other). Use canvas or native.")
        }
        guard let png else { throw ToolError("\(item) is not rendered right now") }
        return [
            "content": [
                ["type": "image", "data": .string(png.base64EncodedString()), "mimeType": "image/png"],
                ["type": "text", "text": .string(caption)],
            ],
        ]
    }

    private func setProperty(_ host: any CanvasHost, _ arguments: JSON) throws -> JSON {
        guard let id = arguments["node_id"]?.string, let prop = arguments["prop"]?.string else {
            throw ToolError("node_id and prop are required")
        }
        let (node, _, _) = try find(id, in: host.document)
        let value = try Self.value(arguments["value"] ?? .null)
        let edit: Edit = if let instance = node.instance, instance != node.source {
            .override(instance, target: node.source, Prop(rawValue: prop), value)
        } else {
            .set(node.source, Prop(rawValue: prop), value)
        }
        try host.apply(edit)
        return ["applied": .string(Self.describe(edit))]
    }

    private func applyEdits(_ host: any CanvasHost, _ arguments: JSON) throws -> JSON {
        guard let requests = arguments["edits"]?.array, !requests.isEmpty else { throw ToolError("edits must be a non-empty array") }
        // Translate against a scratch copy so later edits see earlier inserts and moves.
        var scratch = host.document
        var edits: [Edit] = []
        var created: [JSON] = []
        for (index, request) in requests.enumerated() {
            do {
                let edit = try Self.edit(from: request, in: scratch)
                try scratch.apply(edit)
                edits.append(edit)
                if case .insert(let node) = edit { created.append(.string(node.id.rawValue)) }
            } catch let error as ToolError {
                throw ToolError("Edit \(index): \(error.message)")
            } catch {
                throw ToolError("Edit \(index): \(error)")
            }
        }
        try host.apply(.batch(edits))
        return ["applied": .number(Double(edits.count)), "created": .array(created), "undo": "One undo step in the editor"]
    }

    // MARK: - Comments

    private func listComments(_ host: any CanvasHost, _ arguments: JSON) -> JSON {
        let includeResolved = arguments["include_resolved"]?.bool ?? false
        let store = host.comments
        return .array(store.ordered.filter { includeResolved || !$0.isResolved }.map { thread in
            var entry: [String: JSON] = [
                "thread_id": .string(thread.id),
                "number": .number(Double(store.number(of: thread.id) ?? 0)),
                "resolved": .bool(thread.isResolved),
                "comments": .array(thread.comments.map { comment in
                    ["author": .string(comment.author), "body": .string(comment.body),
                     "created_at": .string(comment.createdAt.ISO8601Format())]
                }),
            ]
            if let anchor = thread.anchor.node {
                var pinned: [String: JSON] = ["node_id": .string(anchor.node), "item": .string(anchor.item)]
                if let (node, _, _) = try? find(anchor.node, in: host.document) {
                    pinned["kind"] = .string(node.kind.rawValue)
                    for prop in [Prop.text, .title, .symbol] { if let value = node[prop] { pinned[prop.rawValue] = Self.json(value) } }
                } else {
                    pinned["missing"] = "The node no longer exists; the pin shows at its last position."
                }
                entry["pinned_to"] = .object(pinned)
            } else {
                entry["pinned_at"] = ["x": .number(thread.anchor.x.rounded()), "y": .number(thread.anchor.y.rounded())]
            }
            return .object(entry)
        })
    }

    private func addComment(_ host: any CanvasHost, _ arguments: JSON) throws -> JSON {
        guard let body = arguments["body"]?.string else { throw ToolError("body is required") }
        if let threadID = arguments["thread_id"]?.string {
            try host.comments.reply(to: threadID, author: clientName, body: body)
            return ["thread_id": .string(threadID), "replied": true]
        }
        let anchor: CommentAnchor
        if let id = arguments["node_id"]?.string {
            let (node, _, root) = try find(id, in: host.document)
            let item = item(root, appearance: arguments["appearance"]?.string)
            // Pin at the node's top-right corner, like a designer would.
            let frame = host.measuredFrames(item: item)[node.id] ?? .zero
            let origin = host.canvasOrigin(item: item) ?? .zero
            anchor = CommentAnchor(
                x: Double(origin.x + frame.maxX), y: Double(origin.y + frame.minY),
                node: .init(item: item, node: node.id, dx: Double(frame.width), dy: 0)
            )
        } else if let x = arguments["x"]?.number, let y = arguments["y"]?.number {
            anchor = CommentAnchor(x: x, y: y)
        } else {
            throw ToolError("Pass thread_id to reply, node_id to pin to a node, or x and y for a page point")
        }
        let thread = try host.comments.start(at: anchor, author: clientName, body: body)
        return ["thread_id": .string(thread.id), "number": .number(Double(host.comments.number(of: thread.id) ?? 0))]
    }

    private func resolveComment(_ host: any CanvasHost, _ arguments: JSON) throws -> JSON {
        guard let threadID = arguments["thread_id"]?.string else { throw ToolError("thread_id is required") }
        if let reply = arguments["reply"]?.string, !reply.isEmpty {
            try host.comments.reply(to: threadID, author: clientName, body: reply)
        }
        let resolved = arguments["resolved"]?.bool ?? true
        try host.comments.setResolved(threadID, resolved)
        return ["thread_id": .string(threadID), "resolved": .bool(resolved)]
    }

    // MARK: - Mapping

    static func edit(from request: JSON, in document: CanvasDocument) throws -> Edit {
        func required(_ key: String) throws -> String {
            guard let value = request[key]?.string else { throw ToolError("\(key) is required") }
            return value
        }
        switch request["op"]?.string {
        case "insert":
            let kindName = try required("kind")
            guard let kind = Node.Kind(rawValue: kindName) else {
                throw ToolError("Unknown kind \(kindName). Kinds: \(Node.Kind.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            let parent = NodeID(try required("parent"))
            guard document[parent] != nil else { throw ToolError("No parent \(parent)") }
            var props: [Prop: Value] = [:]
            for (key, value) in request["props"].flatMap(objectEntries) ?? [] { props[Prop(rawValue: key)] = try Self.value(value) }
            var overrides: [NodeID: [Prop: Value]] = [:]
            for (target, values) in request["overrides"].flatMap(objectEntries) ?? [] {
                for (key, value) in objectEntries(values) ?? [] {
                    overrides[NodeID(target), default: [:]][Prop(rawValue: key)] = try Self.value(value)
                }
            }
            return .insert(Node(
                id: request["id"]?.string.map(NodeID.init(_:)) ?? .random(),
                kind: kind,
                parent: parent,
                order: document.orderKey(in: parent, at: request["index"]?.int),
                props: props,
                overrides: overrides
            ))
        case "delete":
            return .delete(NodeID(try required("node")))
        case "set":
            return .set(NodeID(try required("node")), Prop(rawValue: try required("prop")), try Self.value(request["value"] ?? .null))
        case "override":
            return .override(
                NodeID(try required("instance")),
                target: NodeID(try required("target")),
                Prop(rawValue: try required("prop")),
                try Self.value(request["value"] ?? .null)
            )
        case "move":
            let node = NodeID(try required("node"))
            let parent = NodeID(try required("parent"))
            return .move(node, parent: parent, order: document.orderKey(in: parent, at: request["index"]?.int, excluding: node))
        default:
            throw ToolError("op must be insert, delete, set, override or move")
        }
    }

    private static func objectEntries(_ json: JSON) -> [(String, JSON)]? {
        if case .object(let object) = json { object.sorted { $0.key < $1.key } } else { nil }
    }

    /// Plain JSON values map directly; `{"token": ...}` and `{"color": ...}` use the document encoding.
    static func value(_ json: JSON) throws -> Value? {
        switch json {
        case .null: return nil
        case .string(let string): return .string(string)
        case .number(let number): return .number(number)
        case .bool(let bool): return .bool(bool)
        case .object: return try JSON.decode(Value.self, from: json)
        case .array: throw ToolError("A property value can't be an array")
        }
    }

    static func json(_ value: Value) -> JSON {
        switch value {
        case .string(let string): .string(string)
        case .number(let number): .number(number)
        case .bool(let bool): .bool(bool)
        case .color(let rgba): ["color": .string(rgba.hex)]
        case .token(let token): ["token": .string(token.rawValue)]
        }
    }

    static func treeJSON(_ node: ResolvedNode, frames: [String: CGRect], depth: Int?) -> JSON {
        var object: [String: JSON] = [
            "id": .string(node.id),
            "kind": .string(node.kind.rawValue),
        ]
        if !node.props.isEmpty {
            object["props"] = .object(Dictionary(uniqueKeysWithValues: node.props.map { ($0.key.rawValue, json($0.value)) }))
        }
        if node.source.rawValue != node.id { object["source"] = .string(node.source.rawValue) }
        if let instance = node.instance { object["instance"] = .string(instance.rawValue) }
        if let frame = frames[node.id] {
            let round = { (value: CGFloat) in JSON.number((Double(value) * 2).rounded() / 2) }
            object["frame"] = ["x": round(frame.minX), "y": round(frame.minY), "width": round(frame.width), "height": round(frame.height)]
        }
        if !node.children.isEmpty {
            if let depth, depth <= 0 {
                object["childCount"] = .number(Double(node.children.count))
            } else {
                object["children"] = .array(node.children.map { treeJSON($0, frames: frames, depth: depth.map { $0 - 1 }) })
            }
        }
        return .object(object)
    }

    private static func describe(_ edit: Edit) -> String {
        switch edit {
        case .set(let node, let prop, let value): "set \(node).\(prop) = \(value?.description ?? "nil")"
        case .override(let instance, let target, let prop, let value):
            "override \(instance) \(target).\(prop) = \(value?.description ?? "nil")"
        default: "\(edit)"
        }
    }

    // MARK: - JSON-RPC

    private func text(_ payload: JSON) -> JSON {
        ["content": [["type": "text", "text": .string(String(decoding: payload.serialized(pretty: true), as: UTF8.self))]]]
    }

    private func toolError(_ message: String) -> JSON {
        ["content": [["type": "text", "text": .string(message)]], "isError": true]
    }

    private func success(id: JSON, _ result: JSON) -> JSON {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private func failure(id: JSON, code: Int, _ message: String) -> JSON {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]]
    }
}
