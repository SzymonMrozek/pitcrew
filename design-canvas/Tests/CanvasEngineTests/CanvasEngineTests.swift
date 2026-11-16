import CanvasCore
import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import CanvasEngine

/// Frames the native SwiftUI render of the sample produced on the iOS 26 simulator
/// (iPhone 17 Pro). The engine must match them within half a point.
@Suite struct FidelityTests {
    let layout = LayoutEngine(tokens: CanvasDocument.sample().tokens, appearance: .light)
        .screen(try! CanvasDocument.sample().resolve("settings"), device: .named("iPhone 17 Pro"))

    private func expectFrame(_ id: String, _ expected: CGRect, tolerance: CGFloat = 0.5, sourceLocation: SourceLocation = #_sourceLocation) {
        guard let frame = layout.frames[id] else {
            Issue.record("No frame for \(id)", sourceLocation: sourceLocation)
            return
        }
        for (actual, wanted) in [(frame.minX, expected.minX), (frame.minY, expected.minY), (frame.width, expected.width), (frame.height, expected.height)] {
            #expect(abs(actual - wanted) <= tolerance, "\(id): \(frame) vs \(expected)", sourceLocation: sourceLocation)
        }
    }

    @Test func listRowsMatchTheNativeRender() {
        expectFrame("settings.profile", CGRect(x: 32, y: 183, width: 249.5, height: 41.5))
        expectFrame("settings.profile/profileRow.name", CGRect(x: 86, y: 183, width: 147, height: 24))
        expectFrame("settings.airplane", CGRect(x: 32, y: 313.5, width: 338, height: 20.5))
        expectFrame("settings.wifi", CGRect(x: 32, y: 364.5, width: 338, height: 30))
        expectFrame("settings.wifi/settingRow.title", CGRect(x: 74, y: 369.5, width: 40.5, height: 20.5))
        expectFrame("settings.wifi/settingRow.value", CGRect(x: 324.5, y: 369.5, width: 45.5, height: 20.5))
        expectFrame("settings.bluetooth", CGRect(x: 32, y: 424.5, width: 338, height: 30))
        expectFrame("settings.signOut", CGRect(x: 32, y: 520.5, width: 66, height: 20.5))
    }

    @Test func symbolsTakeTheirImageSize() {
        expectFrame("settings.profile/profileRow.avatar", CGRect(x: 32, y: 184, width: 40, height: 40), tolerance: 1)
        expectFrame("settings.wifi/settingRow.icon.symbol", CGRect(x: 36.5, y: 372, width: 21, height: 15.5), tolerance: 1)
    }

    @Test func hitTestingFindsTheDeepestNode() {
        #expect(layout.hitTest(CGPoint(x: 90, y: 378)) == "settings.wifi/settingRow.title")
        #expect(layout.hitTest(CGPoint(x: 40, y: 378))?.hasPrefix("settings.wifi/settingRow.icon") == true)
    }
}

@Suite struct EngineTests {
    @Test func appearanceResolvesSemanticColors() throws {
        let tokens = CanvasDocument.sample().tokens
        let light = LayoutEngine(tokens: tokens, appearance: .light)
        let dark = LayoutEngine(tokens: tokens, appearance: .dark)
        #expect(light.color(.token("color.label"))?.hex == "#000000")
        #expect(dark.color(.token("color.label"))?.hex == "#FFFFFF")
        #expect(dark.color(.token("color.accent"))?.hex == "#0A84FF")
        #expect(light.color(.string("systemRed"))?.hex == "#FF383C")
        #expect(light.number(.token("space.row")) == 12)
        #expect(light.textStyle(.token("text.rowDetail")) == "body")
    }

    @Test func serifTokensDrawInTheSystemSerif() throws {
        let tokens = TokenSet(tokens: [Token("type.article", .textStyle("body", design: "serif")), Token("type.ui", .textStyle("body"))])
        let engine = LayoutEngine(tokens: tokens, appearance: .light)
        #expect(engine.fontDesign(.token("type.article")) == "serif")
        #expect(engine.fontDesign(.token("type.ui")) == nil)
        #expect(engine.textStyle(.token("type.article")) == "body")
        let serif = TextEngine.font(size: 17, weight: 0, design: "serif")
        let plain = TextEngine.font(size: 17, weight: 0)
        #expect((CTFontCopyPostScriptName(serif) as String).contains("NewYork"))
        #expect(!(CTFontCopyPostScriptName(plain) as String).contains("NewYork"))
    }

    @Test func screensUseTheGroupedBackgroundUnderAList() throws {
        let document = CanvasDocument.sample()
        let layout = LayoutEngine(tokens: document.tokens, appearance: .dark).screen(try document.resolve("settings"), device: .named(nil))
        #expect(layout.background.hex == "#000000")
        #expect(layout.size == CGSize(width: 402, height: 874))
    }

    @Test func stacksGiveSpacersWhatIsLeft() throws {
        let document = CanvasDocument.sample()
        let layout = LayoutEngine(tokens: document.tokens, appearance: .light).component(try document.resolve("settingRow"), width: 360)
        let spacer = try #require(layout.frames["settingRow.spacer"])
        let value = try #require(layout.frames["settingRow.value"])
        #expect(layout.frames["settingRow"]?.width == 328)
        #expect(abs(spacer.maxX + 12 - value.minX) < 0.01)
    }

    @Test func textFitsItsOwnMeasuredWidth() {
        // At 11 pt semibold "Later+" is a hair over a pixel boundary, 35.334 pt.
        let spec = TextSpec(string: "Later+", size: 11, weight: 0.3, color: RGBA(hex: "#000000")!, lineHeight: 13.127, ascender: 10.474)
        let ideal = TextEngine.measure(spec, maxWidth: nil)
        #expect(TextEngine.measure(spec, maxWidth: ideal.width) == ideal)
    }

    @Test func stacksKeepIdealSizesThatFit() throws {
        var document = CanvasDocument()
        func add(_ id: NodeID, _ kind: Node.Kind, under parent: NodeID, _ props: [Prop: Value] = [:]) throws {
            try document.apply(.insert(Node(id: id, kind: kind, parent: parent, order: document.appendOrder(in: parent), props: props)))
        }
        try add("component.row", .component, under: CanvasDocument.rootID)
        try add("row", .vstack, under: "component.row", [.alignment: .string("leading"), .maxWidth: .string("infinity")])
        try add("row.meta", .hstack, under: "row", [.spacing: .number(8)])
        try add("row.tag", .text, under: "row.meta", [.text: .string("Full • 12m"), .font: .string("caption2"), .padding: .number(8)])
        try add("row.detail", .text, under: "row.meta", [.text: .string("PL · playing"), .font: .string("caption")])
        let layout = LayoutEngine(tokens: document.tokens, appearance: .light).component(try document.resolve("row"), width: 360)
        let meta = try #require(layout.frames["row.meta"])
        let tag = try #require(layout.frames["row.tag"])
        let detail = try #require(layout.frames["row.detail"])
        #expect(tag.height < 30)
        #expect(abs(tag.width + 8 + detail.width - meta.width) < 0.01)
    }

    @Test func rendersAPNGAtAnyScale() throws {
        let document = CanvasDocument.sample()
        let layout = LayoutEngine(tokens: document.tokens, appearance: .light).screen(try document.resolve("settings"), device: .named(nil))
        let image = try #require(Rasterizer.image(layout, scale: 2))
        #expect(image.width == 804)
        #expect(Rasterizer.png(layout, scale: 1) != nil)
    }
}

@Suite struct TokenBoardTests {
    @Test func boardsAreGroupsInRowsByKind() {
        let tokens = TokenSet(tokens: [
            Token("color.text.ink", modes: ["light": .color(RGBA(hex: "#111318")!), "dark": .color(RGBA(hex: "#F1F2F5")!)]),
            Token("color.accent.base", .system("systemBlue")),
            Token("type.ui.body", .textStyle("body")),
            Token("space.4", .number(16)), Token("space.1", .number(4)),
        ])
        let boards = tokens.boards()
        #expect(boards.map(\.id) == ["color.accent", "color.text", "type.ui", "space"])
        #expect(boards[0].origin.y == boards[1].origin.y && boards[1].origin.x > boards[0].origin.x)
        #expect(boards[2].origin.y > boards[0].origin.y && boards[3].origin.y > boards[2].origin.y)
        // Numbers read smallest first, and a color shows both modes' values.
        #expect(boards[3].root.children.map(\.id) == ["tokens.space.1", "tokens.space.4"])
        let detail = boards[1].root.first { $0.id == "tokens.color.text.ink.detail" }?[.text]?.string
        #expect(detail == "#111318 / #F1F2F5")
    }

    @Test func aGroupAroundADeeperOneIsOneBoard() {
        let tokens = TokenSet(tokens: [
            Token("color.a", .system("label")), Token("color.b.c", .system("label")), Token("color.z", .system("label")),
        ])
        #expect(tokens.boards().map(\.id) == ["color", "color.b"])
    }
}

@Suite struct ContentHeightTests {
    /// A list longer than the screen, under a large title.
    private func longList() throws -> ResolvedNode {
        var document = CanvasDocument.sample()
        let screen = Node(id: "long", kind: .screen, parent: CanvasDocument.rootID, order: "z", props: [.device: .string("iPhone 17 Pro")])
        let stack = Node(id: "long.nav", kind: .navigationStack, parent: "long", order: "a", props: [.title: .string("Long")])
        let list = Node(id: "long.list", kind: .list, parent: "long.nav", order: "a")
        var edits: [Edit] = [.insert(screen), .insert(stack), .insert(list)]
        for index in 0..<40 {
            let order = String(format: "a%03d", index)
            edits.append(.insert(Node(id: NodeID("long.row\(index)"), kind: .text, parent: "long.list", order: order, props: [.text: .string("Row \(index)")])))
        }
        _ = try document.apply(.batch(edits))
        return try document.resolve("long")
    }

    @Test func fittingContentShowsEveryListRow() throws {
        let engine = LayoutEngine(tokens: CanvasDocument.sample().tokens, appearance: .light)
        let device = DeviceSpec.named("iPhone 17 Pro")
        let screen = try longList()
        let cut = engine.screen(screen, device: device)
        let full = engine.screen(screen, device: device, fitsContent: true)
        #expect(cut.size.height == device.size.height)
        let last = try #require(full.frames["long.row39"])
        #expect(last.maxY < full.size.height - device.safeBottom)
        #expect(full.size.height > device.size.height)
        // Rows above the cut sit where they did.
        #expect(full.frames["long.row0"] == cut.frames["long.row0"])
    }

    @Test func fittingContentKeepsScreensThatFit() throws {
        let document = CanvasDocument.sample()
        let engine = LayoutEngine(tokens: document.tokens, appearance: .light)
        let full = engine.screen(try document.resolve("settings"), device: .named("iPhone 17 Pro"), fitsContent: true)
        #expect(full.size.height == 874)
    }
}

@Suite struct WebScreenLayoutTests {
    private func webScreen(_ device: String) throws -> ResolvedNode {
        var document = CanvasDocument()
        var node = Node.webScreen(id: "web", parent: CanvasDocument.rootID, order: "a", name: "Web", url: "http://localhost:8000/a.html")
        node[.device] = .string(device)
        try document.apply(.insert(node))
        return try document.resolve("web")
    }

    @Test func webViewportsHaveNoStatusBarSafeAreasOrCorners() throws {
        let device = DeviceSpec.named("Mobile 390")
        #expect(device.size == CGSize(width: 390, height: 844))
        #expect(device.safeTop == 0 && device.safeBottom == 0 && device.cornerRadius == 0 && device.island == nil)
        #expect(device.isWeb)
        #expect(!DeviceSpec.named("iPhone 17 Pro").isWeb)

        // Outside the editor a web screen draws a placeholder: no status bar, square, viewport-sized.
        let screen = try webScreen("Tablet 768")
        let layout = LayoutEngine(tokens: TokenSet(), appearance: .light).screen(screen, device: DeviceSpec.of(screen))
        #expect(layout.size == CGSize(width: 768, height: 1024))
        #expect(layout.cornerRadius == 0)
        #expect(layout.frames["web"] == CGRect(x: 0, y: 0, width: 768, height: 1024))
        let texts = layout.ops.compactMap { op -> String? in if case .text(let spec, _) = op { spec.string } else { nil } }
        #expect(texts.first == "http://localhost:8000/a.html")
        #expect(!texts.contains { $0.contains(":") && $0.count <= 5 })  // no status bar clock
    }

    @Test func aPictureFillsTheViewportAndRasterizes() throws {
        let screen = try webScreen("Mobile 390")
        let context = try #require(Rasterizer.makeContext(width: 4, height: 4, scale: 1))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let picture = ImageBox(try #require(context.makeImage()))
        let layout = LayoutEngine(tokens: TokenSet(), appearance: .dark)
            .webScreen(screen, picture: picture, frames: ["web:body": CGRect(x: 0, y: 0, width: 390, height: 844)])
        guard case .image(let box, let rect)? = layout.ops.first else { Issue.record("no image op"); return }
        #expect(box === picture)
        #expect(rect == CGRect(x: 0, y: 0, width: 390, height: 844))
        #expect(layout.hitTest(CGPoint(x: 10, y: 10)) != nil)
        let image = try #require(Rasterizer.image(layout, scale: 1))
        let pixel = try #require(image.dataProvider?.data as Data?)
        #expect(pixel[0] > 200 && pixel[1] < 30)  // red, from the picture
    }
}
