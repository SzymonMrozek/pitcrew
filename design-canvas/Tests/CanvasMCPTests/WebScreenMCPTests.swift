import CoreGraphics
import Foundation
import Testing
@testable import CanvasCore
@testable import CanvasMCP

/// A host with the sample document plus one web screen whose page is already captured.
@MainActor
private final class WebHost: CanvasHost {
    var document = CanvasDocument.sample()
    var history = History()
    var selected: (item: String, node: String)?
    var comments = CommentStore()
    var captured = true
    var reloads = 0

    init() {
        let screen = Node.webScreen(
            id: "pricing", parent: CanvasDocument.rootID, order: "zz", name: "Pricing",
            url: "http://localhost:8000/pricing.html#static=1", at: CGPoint(x: 0, y: 1200)
        )
        try! document.apply(.insert(screen))
    }

    func snapshot(dark: Bool) -> WebSnapshot {
        let ink = dark ? "rgb(245, 245, 247)" : "rgb(26, 22, 18)"
        let heading = WebElement(
            path: "body>aside.panel>h2", tag: "h2", text: "Atakują często", frame: [1078, 60, 320, 30],
            styles: ["color": ink, "fontSize": "26", "borderRadius": "4"]
        )
        let panel = WebElement(
            path: "body>aside.panel", tag: "aside", classes: ["panel"], frame: [1052, 16, 372, 868],
            styles: ["backgroundColor": "rgba(22, 22, 24, 0.62)"], children: [heading]
        )
        let chart = WebElement(path: "#cv", tag: "canvas", id: "cv", frame: [0, 0, 1040, 900])
        return WebSnapshot(
            url: "http://localhost:8000/pricing.html#static=1", title: "Pricing", width: 1440, height: 900,
            root: WebElement(path: "body", tag: "body", frame: [0, 0, 1440, 900], children: [chart, panel]),
            variables: [
                WebVariable(name: "ink", raw: "x", color: ink),
                WebVariable(name: "hot", raw: "#FF453A", color: dark ? "rgb(255, 69, 58)" : "rgb(217, 58, 30)"),
                WebVariable(name: "r", raw: "14px", number: 14),
                WebVariable(name: "ui", raw: "Inter"),
            ]
        )
    }

    func webSnapshot(screen: NodeID, appearance: String) -> WebSnapshot? {
        screen == "pricing" && captured ? snapshot(dark: appearance == "dark") : nil
    }

    func webStatus(screen: NodeID) -> String? { screen == "pricing" ? (captured ? "loaded" : "loading") : nil }

    func reloadWebScreen(_ screen: NodeID) async throws {
        reloads += 1
        captured = true
    }

    func canvasOrigin(item: String) -> CGPoint? { item == "pricing#light" ? CGPoint(x: 0, y: 1200) : nil }

    func apply(_ edit: Edit) throws { try history.perform(edit, on: &document) }

    func measuredFrames(item: String) -> [String: CGRect] {
        guard item.hasPrefix("pricing#"), captured else { return [:] }
        return snapshot(dark: item.hasSuffix("#dark")).frames(screen: "pricing")
    }

    func snapshotPNG(item: String) -> Data? { item.hasPrefix("pricing#") ? Data([0x89, 0x50, 0x4E, 0x47]) : nil }
}

@MainActor
private func call(_ server: CanvasMCPServer, _ tool: String, _ arguments: JSON = [:]) async throws -> (JSON, Bool) {
    let response = try #require(await server.respond(to: [
        "jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": .string(tool), "arguments": arguments],
    ]))
    let result = try #require(response["result"])
    let content = try #require(result["content"]?.array?.first)
    let isError = result["isError"]?.bool ?? false
    if content["type"] == "text", let text = content["text"]?.string, !isError,
        let parsed = try? JSONDecoder().decode(JSON.self, from: Data(text.utf8))
    {
        return (parsed, false)
    }
    return (result, isError)
}

@MainActor
@Suite struct WebScreenMCPTests {
    @Test func listItemsShowsPlatformURLAndViewport() async throws {
        let host = WebHost()
        let server = CanvasMCPServer(host: host)
        let (items, _) = try await call(server, "list_items")
        let web = try #require(items.array?.first { $0["id"] == "pricing" })
        #expect(web["platform"] == "web")
        #expect(web["url"] == "http://localhost:8000/pricing.html#static=1")
        #expect(web["device"] == "Desktop 1440")
        #expect(web["viewport"]?["width"] == 1440)
        #expect(web["status"] == "loaded")
        #expect(web["title"] == "Pricing")
        #expect(web["elements"] == 4)
        #expect(items.array?.first { $0["id"] == "settings" }?["platform"] == "ios")
    }

    @Test func getTreeReturnsTheDOMWithFramesAndStyles() async throws {
        let host = WebHost()
        let server = CanvasMCPServer(host: host)
        let (tree, isError) = try await call(server, "get_tree", ["node_id": "pricing"])
        #expect(!isError)
        #expect(tree["kind"] == "screen")
        let body = try #require(tree["children"]?.array?.first)
        #expect(body["id"] == "pricing:body")
        #expect(body["kind"] == "element")
        #expect(body["frame"]?["width"] == 1440)
        let panel = try #require(body["children"]?.array?.last)
        #expect(panel["props"]?["classes"] == "panel")
        #expect(panel["props"]?["backgroundColor"]?["color"] == "#1616189E")

        // A subtree, by element ID, in dark.
        let (heading, _) = try await call(server, "get_tree", ["node_id": "pricing:body>aside.panel>h2", "appearance": "dark"])
        #expect(heading["props"]?["text"] == "Atakują często")
        #expect(heading["props"]?["color"]?["color"] == "#F5F5F7")
        #expect(heading["frame"]?["x"] == 1078)
    }

    @Test func inspectingAnElementFlagsLiteralColorsAndExplainsEditing() async throws {
        let host = WebHost()
        let server = CanvasMCPServer(host: host)
        let (node, _) = try await call(server, "inspect_node", ["node_id": "pricing:body>aside.panel>h2"])
        #expect(node["kind"] == "element")
        #expect(node["unbound"]?["color"] != nil)
        // Lengths aren't candidates for tokens: they're whatever the CSS computes.
        #expect(node["unbound"]?["borderRadius"] == nil)
        #expect(node["editing"]?.string?.contains("read-only") == true)
        #expect(node["ancestors"]?.array?.count == 3)

        let (_, refused) = try await call(server, "set_property", ["node_id": "pricing:body>aside.panel>h2", "prop": "text", "value": "x"])
        #expect(refused)
        let (_, inserted) = try await call(server, "apply_edits", ["edits": [["op": "insert", "kind": "element", "parent": "root"]]])
        #expect(inserted)
        // The screen itself takes edits.
        let (_, failed) = try await call(server, "set_property", ["node_id": "pricing", "prop": "device", "value": "Mobile 390"])
        #expect(!failed)
        #expect(host.document["pricing"]?[.device] == .string("Mobile 390"))
    }

    @Test func importedTokensBindTheDOMsColors() async throws {
        let host = WebHost()
        let server = CanvasMCPServer(host: host)
        let original = host.document
        let (result, isError) = try await call(server, "import_web_tokens", ["screen_id": "pricing"])
        #expect(!isError)
        #expect(result["imported"] == ["web.hot", "web.ink", "web.r"])
        #expect(result["skipped"] == ["ui"])
        #expect(try host.document.tokens.resolve("web.hot", mode: "light") == .color(RGBA(hex: "#D93A1E")!))
        #expect(try host.document.tokens.resolve("web.r", mode: "dark") == .number(14))

        let (heading, _) = try await call(server, "inspect_node", ["node_id": "pricing:body>aside.panel>h2", "appearance": "dark"])
        #expect(heading["props"]?["color"]?["token"] == "web.ink")
        #expect(heading["unbound"]?["color"] == nil)
        #expect(heading["tokens"]?["color"]?["dark"] == "#F5F5F7")

        try host.history.undo(&host.document)
        #expect(host.document == original)
        let (_, missing) = try await call(server, "import_web_tokens", ["screen_id": "settings"])
        #expect(missing)
    }

    @Test func commentsPinToDOMElements() async throws {
        let host = WebHost()
        let server = CanvasMCPServer(host: host)
        let (thread, _) = try await call(server, "add_comment", ["node_id": "pricing:body>aside.panel>h2", "body": "Bigger heading"])
        let id = try #require(thread["thread_id"]?.string)
        let anchor = try #require(host.comments.threads[id]?.anchor)
        #expect(anchor.node?.item == "pricing#light")
        #expect(anchor.node?.node == "pricing:body>aside.panel>h2")
        #expect(anchor.x == 1078 + 320 && anchor.y == 1200 + 60)

        let (list, _) = try await call(server, "list_comments")
        let pinned = try #require(list.array?.first?["pinned_to"])
        #expect(pinned["kind"] == "element")
        #expect(pinned["tag"] == "h2")
        #expect(pinned["text"] == "Atakują często")
    }

    @Test func screenshotsAndReloads() async throws {
        let host = WebHost()
        let server = CanvasMCPServer(host: host)
        let (shot, isError) = try await call(server, "screenshot", ["screen_id": "pricing"])
        #expect(!isError)
        #expect(shot["content"]?.array?.last?["text"]?.string?.contains("WebKit") == true)
        let (_, native) = try await call(server, "screenshot", ["screen_id": "pricing", "renderer": "native"])
        #expect(native)

        host.captured = false
        let (pending, failed) = try await call(server, "screenshot", ["screen_id": "pricing"])
        #expect(!failed)  // the fake still has a PNG; frames are what's missing
        _ = pending
        let (tree, _) = try await call(server, "get_tree", ["node_id": "pricing"])
        #expect(tree["children"] == nil)

        let (reloaded, reloadFailed) = try await call(server, "reload_web_screen", ["screen_id": "pricing"])
        #expect(!reloadFailed)
        #expect(host.reloads == 1)
        #expect(reloaded["status"] == "loaded")
        #expect(reloaded["elements"] == 4)
        let (_, notWeb) = try await call(server, "reload_web_screen", ["screen_id": "settings"])
        #expect(notWeb)
    }

    @Test func theInstructionsCoverWebScreens() {
        #expect(CanvasMCPServer.instructions.contains("web screens"))
        #expect(CanvasMCPServer.tools.contains { $0["name"] == "import_web_tokens" })
        #expect(CanvasMCPServer.tools.contains { $0["name"] == "reload_web_screen" })
    }
}
