import CoreGraphics
import Foundation
import Testing
@testable import CanvasCore

/// A small page like the team's: a panel with a heading and a chart, tokens on `:root`.
func webFixture(dark: Bool = true) -> WebSnapshot {
    let ink = dark ? "rgb(245, 245, 247)" : "rgb(26, 22, 18)"
    let panel = WebElement(
        path: "body>aside.panel", tag: "aside", classes: ["panel", "gl"], frame: [1052, 16, 372, 868],
        styles: ["backgroundColor": dark ? "rgba(22, 22, 24, 0.62)" : "rgba(250, 247, 240, 0.76)", "borderRadius": "22", "padding": "24"],
        children: [
            WebElement(path: "body>aside.panel>h2", tag: "h2", text: "Atakują często", frame: [1078, 60, 320, 30],
                       styles: ["color": ink, "fontSize": "26", "fontWeight": "700"]),
            WebElement(path: "body>aside.panel>p.hint", tag: "p", classes: ["hint"], text: "Najedź na nazwisko", frame: [1078, 100, 320, 40],
                       styles: ["color": "rgb(1, 2, 3)", "fontSize": "15"]),
        ]
    )
    let chart = WebElement(path: "#cv", tag: "canvas", id: "cv", label: "Pricing", frame: [0, 0, 1440, 900])
    return WebSnapshot(
        url: "http://localhost:8000/pricing.html#static=1", title: "Pricing", width: 1440, height: 900,
        background: dark ? "rgb(8, 8, 10)" : "rgb(243, 239, 230)",
        root: WebElement(path: "body", tag: "body", frame: [0, 0, 1440, 900], children: [chart, panel]),
        variables: [
            WebVariable(name: "ink", raw: dark ? "#F5F5F7" : "#1A1612", color: ink),
            WebVariable(name: "glass", raw: "rgba(22,22,24,.62)", color: dark ? "rgba(22, 22, 24, 0.62)" : "rgba(250, 247, 240, 0.76)"),
            WebVariable(name: "r-lg", raw: "22px", number: 22),
            WebVariable(name: "ui", raw: "\"Inter\", system-ui"),
            WebVariable(name: "ease", raw: "cubic-bezier(.32,.72,0,1)"),
        ]
    )
}

@Suite struct WebScreenTests {
    @Test func viewportsAreBrowserWindowsWithADesktopDefault() {
        #expect(WebViewport.all.map(\.name) == ["Desktop 1440", "Laptop 1280", "Tablet 768", "Mobile 390"])
        #expect(WebViewport.named("Mobile 390").size == CGSize(width: 390, height: 844))
        #expect(WebViewport.named("Tablet 768").size == CGSize(width: 768, height: 1024))
        #expect(WebViewport.named("Laptop 1280").size == CGSize(width: 1280, height: 800))
        #expect(WebViewport.named(nil).name == "Desktop 1440")
        #expect(WebViewport.preset("iPhone 17 Pro") == nil)
    }

    @Test func aWebScreenRoundTripsThroughTheFile() throws {
        var document = CanvasDocument()
        let screen = Node.webScreen(
            id: "pricing", parent: CanvasDocument.rootID, order: "a", name: "Pricing",
            url: "http://localhost:8000/pricing.html#static=1", viewport: WebViewport.named("Laptop 1280"),
            at: CGPoint(x: 100, y: 40)
        )
        try document.apply(.insert(screen))
        try document.apply(.set("pricing", .lightURL, .string("http://localhost:8000/pricing.html#static=1&theme=light")))

        let decoded = try CanvasFile.decode(try CanvasFile(document: document).encoded()).document
        #expect(decoded == document)
        let node = try #require(decoded["pricing"])
        #expect(node.isWebScreen)
        #expect(node.platform == .web)
        #expect(node[.url]?.string == "http://localhost:8000/pricing.html#static=1")
        #expect(decoded.viewport(of: node)?.name == "Laptop 1280")
        // iOS screens have no platform prop and stay iOS.
        #expect(CanvasDocument.sample()["settings"]?.platform == .ios)
    }

    @Test func darkCopiesSitAViewportWidthAway() throws {
        let document = CanvasDocument.sample()
        #expect(document.darkCopyOffset(of: try #require(document["settings"])) == 470)
        let desktop = Node.webScreen(parent: CanvasDocument.rootID, order: "a", name: "A", url: "http://x")
        #expect(document.darkCopyOffset(of: desktop) == 1440 + 80)
        var mobile = desktop
        mobile[.device] = .string("Mobile 390")
        #expect(document.darkCopyOffset(of: mobile) == 390 + 80)
    }

    @Test func webScreensDontOpenInTheSwiftUIPreview() throws {
        var document = CanvasDocument()
        try document.apply(.insert(Node.webScreen(id: "web", parent: CanvasDocument.rootID, order: "a", name: "W", url: "http://x")))
        #expect(document.previewScreen(onPage: CanvasDocument.rootID, selected: "web") == nil)
    }

    @Test func cssColorsParseAsBrowsersComputeThem() {
        #expect(RGBA(css: "rgb(245, 245, 247)")?.hex == "#F5F5F7")
        #expect(RGBA(css: "rgba(245, 245, 247, 0.64)")?.hex == "#F5F5F7A3")
        #expect(RGBA(css: "rgb(255 69 58 / 50%)")?.hex == "#FF453A80")
        #expect(RGBA(css: "color(srgb 1 0 0 / 0.5)")?.hex == "#FF000080")
        #expect(RGBA(css: "#08080A")?.hex == "#08080A")
        #expect(RGBA(css: "#fff")?.hex == "#FFFFFF")
        #expect(RGBA(css: "transparent")?.alpha == 0)
        #expect(RGBA(css: "linear-gradient(red, blue)") == nil)
    }

    @Test func theDOMBecomesReadOnlyElementsUnderTheScreen() throws {
        var document = CanvasDocument()
        try document.apply(.insert(Node.webScreen(id: "pricing", parent: CanvasDocument.rootID, order: "a", name: "R", url: "http://x")))
        document.tokens.tokens["web.ink"] = Token("web.ink", modes: ["light": .color(RGBA(hex: "#1A1612")!), "dark": .color(RGBA(hex: "#F5F5F7")!)])
        let screen = try document.resolve("pricing")
        let snapshot = webFixture()

        let tree = snapshot.tree(screen: screen, tokens: document.tokens, mode: "dark")
        #expect(tree.id == "pricing")
        #expect(tree.kind == .screen)
        let body = try #require(tree.children.first)
        #expect(body.id == "pricing:body")
        #expect(body.kind == .element)
        #expect(body.source == "pricing")
        let heading = try #require(tree.first { $0.id == "pricing:body>aside.panel>h2" })
        #expect(heading[.tag] == .string("h2"))
        #expect(heading[.text] == .string("Atakują często"))
        // A color equal to a token's value in the mode is that token; others stay literal.
        #expect(heading[.color] == .token("web.ink"))
        #expect(heading[.fontSize] == .number(26))
        let hint = try #require(tree.first { $0.id == "pricing:body>aside.panel>p.hint" })
        #expect(hint[.color] == .color(RGBA(hex: "#010203")!))
        let panel = try #require(tree.first { $0.id == "pricing:body>aside.panel" })
        #expect(panel[.classes] == .string("panel gl"))
        #expect(panel[.cssPadding] == .number(24))
        #expect(tree.first { $0.id == "pricing:#cv" }?[.ariaLabel] == .string("Pricing"))
        // In light, the dark value doesn't match.
        let light = snapshot.tree(screen: screen, tokens: document.tokens, mode: "light")
        #expect(light.first { $0.id == "pricing:body>aside.panel>h2" }?[.color] == .color(RGBA(hex: "#F5F5F7")!))

        let frames = snapshot.frames(screen: "pricing")
        #expect(frames["pricing"] == CGRect(x: 0, y: 0, width: 1440, height: 900))
        #expect(frames["pricing:body>aside.panel"] == CGRect(x: 1052, y: 16, width: 372, height: 868))
        #expect(frames.count == snapshot.elementCount + 1)
        #expect(Node.Kind.element.props.contains(.backgroundColor))
        #expect(Prop.backgroundColor.tokenKind == .color)
    }

    @Test func snapshotsDecodeFromThePageScriptsJSON() throws {
        let json = """
            {"url":"http://x/","title":"T","width":390,"height":844,"background":"rgb(0, 0, 0)",
             "root":{"path":"body","tag":"body","frame":[0,0,390,844],"children":[
               {"path":"#app","tag":"div","id":"app","classes":["a"],"frame":[0,0,390,10],"styles":{"display":"flex","gap":"8"}}]},
             "variables":[{"name":"ink","raw":"#fff","color":"rgb(255, 255, 255)"}]}
            """
        let snapshot = try WebSnapshot.decode(Data(json.utf8))
        #expect(snapshot.root.children?.first?.id == "app")
        #expect(snapshot.elementCount == 2)
        #expect(snapshot.variables.first?.color == "rgb(255, 255, 255)")
    }

    @Test func customPropertiesBecomeTokensInOneUndoStep() throws {
        var document = CanvasDocument.sample()
        let original = document
        let result = WebTokens.importEdit(
            dark: webFixture(dark: true).variables, light: webFixture(dark: false).variables, into: document.tokens
        )
        #expect(result.imported == ["web.glass", "web.ink", "web.r.lg"])
        #expect(result.skipped == ["ease", "ui"])

        var history = History()
        try history.perform(result.edit, on: &document)
        #expect(document.tokens.kind(of: "web.ink") == .color)
        #expect(try document.tokens.resolve("web.ink", mode: "dark") == .color(RGBA(hex: "#F5F5F7")!))
        #expect(try document.tokens.resolve("web.ink", mode: "light") == .color(RGBA(hex: "#1A1612")!))
        #expect(try document.tokens.resolve("web.glass", mode: "light") == .color(RGBA(css: "rgba(250, 247, 240, 0.76)")!))
        #expect(try document.tokens.resolve("web.r.lg", mode: "dark") == .number(22))

        // Importing the same values again changes nothing.
        let again = WebTokens.importEdit(dark: webFixture().variables, light: webFixture(dark: false).variables, into: document.tokens)
        #expect(again.edit == .batch([]))

        try history.undo(&document)
        #expect(document == original)
        #expect(WebTokens.tokenID(for: "glass-2") == "web.glass.2")
    }

    @Test func aTokenEditHasAnExactInverse() throws {
        var document = CanvasDocument.sample()
        let original = document
        let inverse = try document.apply(.token("color.accent", Token("color.accent", .color(RGBA(hex: "#FF0000")!))))
        #expect(document != original)
        try document.apply(inverse)
        #expect(document == original)
        #expect(throws: DocumentError.tokenMismatch("a")) { try document.apply(.token("a", Token("b", .number(1)))) }
    }
}
