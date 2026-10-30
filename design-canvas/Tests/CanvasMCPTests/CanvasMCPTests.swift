import CoreGraphics
import Foundation
import Network
import Testing
@testable import CanvasCore
@testable import CanvasMCP

@MainActor
private final class FakeHost: CanvasHost {
    var document = CanvasDocument.sample()
    var history = History()
    var selected: (item: String, node: String)?

    func apply(_ edit: Edit) throws { try history.perform(edit, on: &document) }

    func measuredFrames(item: String) -> [String: CGRect] {
        item == "settings#light" ? ["settings.wifi/settingRow.title": CGRect(x: 74, y: 369.4, width: 40.7, height: 20.3)] : [:]
    }

    func snapshotPNG(item: String) -> Data? { item == "settings#light" ? Data([0x89, 0x50]) : nil }
}

@MainActor
private func call(_ server: CanvasMCPServer, _ tool: String, _ arguments: JSON = [:]) throws -> (JSON, Bool) {
    let response = try #require(server.handle([
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
@Suite struct ProtocolTests {
    @Test func initializeNegotiatesTheVersion() throws {
        let host = FakeHost()
        let server = CanvasMCPServer(host: host)
        let known = try #require(server.handle([
            "jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-03-26"],
        ]))
        #expect(known["result"]?["protocolVersion"] == "2025-03-26")
        #expect(known["result"]?["capabilities"]?["tools"] != nil)

        let unknown = try #require(server.handle([
            "jsonrpc": "2.0", "id": "a", "method": "initialize", "params": ["protocolVersion": "1999-01-01"],
        ]))
        #expect(unknown["id"] == "a")
        #expect(unknown["result"]?["protocolVersion"] == .string(CanvasMCPServer.supportedVersions[0]))
    }

    @Test func notificationsGetNoResponseAndUnknownMethodsFail() {
        let host = FakeHost()
        let server = CanvasMCPServer(host: host)
        #expect(server.handle(["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)
        #expect(server.handle(["jsonrpc": "2.0", "id": 2, "method": "nope"])?["error"]?["code"] == -32601)
    }

    @Test func everyToolHasASchema() throws {
        let host = FakeHost()
        let server = CanvasMCPServer(host: host)
        let tools = try #require(server.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/list"])?["result"]?["tools"]?.array)
        #expect(tools.count == 8)
        for tool in tools { #expect(tool["inputSchema"]?["type"] == "object") }
    }
}

@MainActor
@Suite struct ToolTests {
    @Test func treeShowsInstancePathsAndMeasuredFrames() throws {
        let host = FakeHost()
        let server = CanvasMCPServer(host: host)
        let (tree, _) = try call(server, "get_tree", ["node_id": "settings"])
        let text = String(decoding: tree.serialized(), as: UTF8.self)
        #expect(text.contains("\"settings.wifi/settingRow.title\""))
        #expect(text.contains("\"width\":40.5"))

        let (shallow, _) = try call(server, "get_tree", ["node_id": "settings", "depth": 0])
        #expect(shallow["childCount"] == 1)
        #expect(shallow["children"] == nil)
    }

    @Test func inspectResolvesTokensAndExplainsOverrides() throws {
        let host = FakeHost()
        let server = CanvasMCPServer(host: host)
        let (node, _) = try call(server, "inspect_node", ["node_id": "settings.wifi/settingRow.icon.background"])
        #expect(node["tokens"]?["fill"]?["dark"] == "#0A84FF")
        #expect(node["tokens"]?["fill"]?["light"] == "#007AFF")
        #expect(node["editing"]?.string?.contains("settings.wifi") == true)
        #expect(node["ancestors"]?.array?.first == "screen settings")
    }

    @Test func setPropertyInsideAnInstanceWritesAnOverride() throws {
        let host = FakeHost()
        let server = CanvasMCPServer(host: host)
        _ = try call(server, "set_property", ["node_id": "settings.wifi/settingRow.title", "prop": "text", "value": "WLAN"])
        #expect(host.document["settings.wifi"]?.overrides["settingRow.title"]?[.text] == .string("WLAN"))
        #expect(host.document["settingRow.title"]?[.text] == .string("Title"))

        _ = try call(server, "set_property", ["node_id": "settingRow.title", "prop": "foreground", "value": ["token": "color.accent"]])
        #expect(host.document["settingRow.title"]?[.foreground] == .token("color.accent"))
    }

    @Test func applyEditsIsOneUndoStep() throws {
        let host = FakeHost()
        let original = host.document
        let server = CanvasMCPServer(host: host)
        let (result, isError) = try call(server, "apply_edits", ["edits": [
            ["op": "insert", "id": "settings.cellular", "kind": "instance", "parent": "settings.general", "index": 1,
             "props": ["component": "component.settingRow"],
             "overrides": ["settingRow.title": ["text": "Cellular"], "settingRow.icon.symbol": ["symbol": "antenna.radiowaves.left.and.right"]]],
            ["op": "set", "node": "settings.cellular", "prop": "opacity", "value": 0.5],
        ]])
        #expect(!isError)
        #expect(result["created"] == ["settings.cellular"])
        #expect(host.document.children(of: "settings.general").map(\.id) == [
            "settings.airplane", "settings.cellular", "settings.wifi", "settings.bluetooth",
        ])

        try host.history.undo(&host.document)
        #expect(host.document == original)
    }

    @Test func badEditsChangeNothingAndSayWhich() throws {
        let host = FakeHost()
        let original = host.document
        let server = CanvasMCPServer(host: host)
        let (result, isError) = try call(server, "apply_edits", ["edits": [
            ["op": "set", "node": "settings.nav", "prop": "title", "value": "x"],
            ["op": "insert", "kind": "carousel", "parent": "settings.list"],
        ]])
        #expect(isError)
        #expect(result["content"]?.array?.first?["text"]?.string?.hasPrefix("Edit 1: Unknown kind carousel") == true)
        #expect(host.document == original)
    }

    @Test func selectionAndScreenshot() throws {
        let host = FakeHost()
        let server = CanvasMCPServer(host: host)
        #expect(try call(server, "get_selection").0["selected"] == .null)

        host.selected = (item: "settings#light", node: "settings.wifi/settingRow.title")
        let (selection, _) = try call(server, "get_selection")
        #expect(selection["node"]?["props"]?["text"] == "Wi-Fi")
        #expect(selection["node"]?["frame"]?["y"] == 369.5)

        let shot = try #require(server.handle([
            "jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "screenshot", "arguments": ["screen_id": "settings"]],
        ])?["result"])
        #expect(shot["content"]?.array?.first?["mimeType"] == "image/png")
        #expect(try call(server, "screenshot", ["screen_id": "settings", "appearance": "dark"]).1)
    }
}

@Suite struct HTTPTests {
    @Test func parsesRequestsAcrossChunks() {
        let request = Data("POST /mcp HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\nOrigin: http://localhost:3000\r\n\r\n{}".utf8)
        #expect(HTTPRequest.parse(request) == .incomplete)
        guard case .complete(let parsed) = HTTPRequest.parse(request + Data("\n\n".utf8)) else {
            Issue.record("Expected a complete request")
            return
        }
        #expect(parsed.method == "POST")
        #expect(parsed.headers["origin"] == "http://localhost:3000")
        #expect(parsed.body == Data("{}\n\n".utf8))
    }

    @Test func onlyLocalOriginsPass() {
        #expect(HTTPTransport.isLocal(origin: "http://localhost:6274"))
        #expect(HTTPTransport.isLocal(origin: "http://127.0.0.1"))
        #expect(!HTTPTransport.isLocal(origin: "https://evil.example"))
        #expect(!HTTPTransport.isLocal(origin: "http://localhost.evil.example"))
    }

    @Test func servesJSONRPCOverLoopback() async throws {
        let transport = try HTTPTransport(port: 0) { body in
            await MainActor.run { CanvasMCPServer(host: FakeHostBox.shared).handle(data: body) }
        }
        let ready = AsyncStream<Void> { continuation in
            transport.start { state in if case .ready = state { continuation.yield() } }
        }
        for await _ in ready { break }
        defer { transport.stop() }
        let port = try #require(transport.port)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"jsonrpc":"2.0","id":7,"method":"tools/list"}"#.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let json = try JSONDecoder().decode(JSON.self, from: data)
        #expect(json["id"] == 7)
        #expect(json["result"]?["tools"]?.array?.count == 8)

        request.httpBody = Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
        let (_, accepted) = try await URLSession.shared.data(for: request)
        #expect((accepted as? HTTPURLResponse)?.statusCode == 202)

        request.setValue("https://evil.example", forHTTPHeaderField: "Origin")
        let (_, forbidden) = try await URLSession.shared.data(for: request)
        #expect((forbidden as? HTTPURLResponse)?.statusCode == 403)
    }
}

@MainActor
private enum FakeHostBox {
    static let shared = FakeHost()
}
