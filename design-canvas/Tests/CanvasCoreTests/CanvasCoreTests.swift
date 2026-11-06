import Foundation
import Testing
@testable import CanvasCore

@Suite struct FractionalIndexTests {
    @Test func keysSortBetweenTheirBounds() {
        var keys = FractionalIndex.sequence(after: nil, count: 50)
        #expect(keys == keys.sorted())

        // Repeatedly insert at the front, the middle and the back.
        for step in 0..<200 {
            let index = [0, keys.count / 2, keys.count][step % 3]
            let lower = index == 0 ? nil : keys[index - 1]
            let upper = index == keys.count ? nil : keys[index]
            let key = FractionalIndex.between(lower, upper)
            if let lower { #expect(lower < key) }
            if let upper { #expect(key < upper) }
            #expect(!key.hasSuffix("0"))
            keys.insert(key, at: index)
        }
        #expect(keys == keys.sorted())
        #expect(Set(keys).count == keys.count)
    }
}

@Suite struct DocumentTests {
    @Test func everyOperationHasAnInverse() throws {
        var document = CanvasDocument.sample()
        let original = document

        let edits: [Edit] = [
            .set("settings.airplane", .isOn, .bool(true)),
            .set("settings.airplane", .opacity, .number(0.5)),
            .override("settings.wifi", target: "settingRow.title", .text, .string("WLAN")),
            .move("settings.signOut", parent: "settings.account", order: "a"),
            .delete("settings.general"),
            .insert(Node(id: "new", kind: .text, parent: "settings.list", order: "z", props: [.text: .string("Hi")])),
        ]
        var inverses: [Edit] = []
        for edit in edits { inverses.append(try document.apply(edit)) }
        #expect(document != original)

        for inverse in inverses.reversed() { try document.apply(inverse) }
        #expect(document == original)
    }

    @Test func aFailingBatchChangesNothing() {
        var document = CanvasDocument.sample()
        let original = document
        #expect(throws: DocumentError.unknownNode("missing")) {
            try document.apply(.batch([
                .set("settings.airplane", .isOn, .bool(true)),
                .delete("settings.general"),
                .set("missing", .text, .string("x")),
            ]))
        }
        #expect(document == original)
    }

    @Test func aNodeCannotMoveIntoItsOwnSubtree() {
        var document = CanvasDocument.sample()
        #expect(throws: DocumentError.moveIntoDescendant("settings.nav")) {
            try document.apply(.move("settings.nav", parent: "settings.general", order: "a"))
        }
    }

    @Test func historyUndoesAndRedoes() throws {
        var document = CanvasDocument.sample()
        var history = History()
        try history.perform(.set("settings.nav", .title, .string("Ustawienia")), on: &document)
        #expect(document["settings.nav"]?[.title] == .string("Ustawienia"))

        try history.undo(&document)
        #expect(document["settings.nav"]?[.title] == .string("Settings"))

        try history.redo(&document)
        #expect(document["settings.nav"]?[.title] == .string("Ustawienia"))
    }

    @Test func childrenFollowOrderAndBreakTiesOnID() throws {
        var document = CanvasDocument()
        for id in ["b", "a", "c"] {
            try document.apply(.insert(Node(id: NodeID(id), kind: .text, parent: CanvasDocument.rootID, order: "V")))
        }
        try document.apply(.insert(Node(id: "first", kind: .text, parent: CanvasDocument.rootID, order: "1")))
        #expect(document.children(of: CanvasDocument.rootID).map(\.id) == ["first", "a", "b", "c"])
    }

    @Test func roundTripsThroughJSON() throws {
        let document = CanvasDocument.sample()
        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(CanvasDocument.self, from: data)
        #expect(decoded == document)
        #expect(decoded.children(of: "settings.list").map(\.id) == document.children(of: "settings.list").map(\.id))
    }
}

@Suite struct TokenTests {
    @Test func aliasesResolvePerMode() throws {
        let tokens = TokenSet(tokens: [
            Token("blue", modes: ["light": .color(RGBA(hex: "#007AFF")!), "dark": .color(RGBA(hex: "#0A84FF")!)]),
            Token("accent", .alias("blue")),
        ])
        #expect(try tokens.resolve("accent", mode: "dark") == .color(RGBA(hex: "#0A84FF")!))
        #expect(try tokens.resolve("accent", mode: "light") == .color(RGBA(hex: "#007AFF")!))
        #expect(try tokens.resolve("accent", mode: "highContrast") == .color(RGBA(hex: "#007AFF")!))
    }

    @Test func textStylesKeepTheirDesignThroughJSON() throws {
        let serif = TokenValue.textStyle("body", design: "serif")
        let json = try JSONEncoder().encode(serif)
        #expect(try JSONDecoder().decode(TokenValue.self, from: json) == serif)
        let plain = try JSONDecoder().decode(TokenValue.self, from: Data(#"{"textStyle":"body"}"#.utf8))
        #expect(plain == .textStyle("body"))
    }

    @Test func aliasCyclesAreReported() {
        let tokens = TokenSet(tokens: [Token("a", .alias("b")), Token("b", .alias("a"))])
        #expect(throws: TokenError.aliasCycle("a")) { try tokens.resolve("a", mode: "light") }
    }
}

@Suite struct ResolveTests {
    @Test func instancesExpandWithOverrides() throws {
        let screen = try CanvasDocument.sample().resolve("settings")
        let wifi = try #require(screen.first { $0.source == "settings.wifi" })
        #expect(wifi.kind == .hstack)
        #expect(wifi.id == "settings.wifi")

        let title = try #require(wifi.first { $0.source == "settingRow.title" })
        #expect(title[.text] == .string("Wi-Fi"))
        #expect(title.instance == "settings.wifi")
        #expect(title.id == "settings.wifi/settingRow.title")

        let bluetoothTitle = try #require(
            screen.first { $0.source == "settingRow.title" && $0.instance == "settings.bluetooth" }
        )
        #expect(bluetoothTitle[.text] == .string("Bluetooth"))
    }

    @Test func settingReplacesAPropByResolvedID() throws {
        let screen = try CanvasDocument.sample().resolve("settings")
        let isOn = screen.first { $0.id == "settings.airplane" }?[.isOn]?.bool ?? false
        let switched = screen.setting(.isOn, ["settings.airplane": .bool(!isOn)])
        #expect(switched.first { $0.id == "settings.airplane" }?[.isOn] == .bool(!isOn))
        #expect(switched.first { $0.id == "settings.wifi" } == screen.first { $0.id == "settings.wifi" })
        #expect(screen.setting(.isOn, [:]) == screen)
    }

    @Test func instancePropsReplaceTheComponentRoot() throws {
        var document = CanvasDocument.sample()
        try document.apply(.set("settings.wifi", .spacing, .number(20)))
        let wifi = try #require(try document.resolve("settings").first { $0.source == "settings.wifi" })
        #expect(wifi[.spacing] == .number(20))
        #expect(wifi[.component] == nil)
    }

    @Test func componentEditsReachEveryInstance() throws {
        var document = CanvasDocument.sample()
        try document.apply(.set("settingRow.icon.background", .cornerRadius, .number(15)))
        let screen = try document.resolve("settings")
        var found = 0
        func visit(_ node: ResolvedNode) {
            if node.source == "settingRow.icon.background" {
                #expect(node[.cornerRadius] == .number(15))
                found += 1
            }
            node.children.forEach(visit)
        }
        visit(screen)
        #expect(found == 2)
    }

    @Test func componentCyclesAreReported() throws {
        var document = CanvasDocument.sample()
        try document.apply(.insert(Node(
            id: "loop", kind: .instance, parent: "settingRow", order: "z",
            props: [.component: .string("component.settingRow")]
        )))
        #expect(throws: ResolveError.componentCycle("component.settingRow")) { try document.resolve("settings") }
    }
}

@Suite struct CommentTests {
    @Test func threadsNumberOldestFirstAndCollectReplies() throws {
        var store = CommentStore()
        let early = Date(timeIntervalSince1970: 100)
        let pinned = CommentAnchor(
            x: 10, y: 20, node: .init(item: "settings#light", node: "settings.wifi/settingRow.title", dx: 30, dy: 0)
        )
        let second = try store.start(at: CommentAnchor(x: 900, y: 40), author: "designer", body: "Spacing?", now: early.addingTimeInterval(60))
        let first = try store.start(at: pinned, author: "designer", body: "  Make this bold  ", now: early)
        #expect(store.ordered.map(\.id) == [first.id, second.id])
        #expect(store.number(of: second.id) == 2)
        #expect(first.title == "Make this bold")

        try store.reply(to: first.id, author: "claude-code", body: "Done")
        try store.setResolved(first.id, true)
        #expect(store.threads[first.id]?.comments.map(\.author) == ["designer", "claude-code"])
        #expect(store.threads[first.id]?.isResolved == true)
    }

    @Test func rejectsEmptyBodiesAndUnknownThreads() {
        var store = CommentStore()
        #expect(throws: CommentError.emptyBody) { try store.start(at: CommentAnchor(x: 0, y: 0), author: "a", body: " \n") }
        #expect(throws: CommentError.unknownThread("nope")) { try store.reply(to: "nope", author: "a", body: "x") }
        #expect(throws: CommentError.unknownThread("nope")) { try store.delete("nope") }
    }
}

@Suite struct CanvasFileTests {
    private func sampleFile() throws -> CanvasFile {
        var comments = CommentStore()
        try comments.start(
            at: CommentAnchor(x: 1, y: 2, node: .init(item: "settings#light", node: "settings.wifi/settingRow.title", dx: 3, dy: 4)),
            author: "Designer", body: "Bold?", now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        return CanvasFile(document: .sample(), comments: comments)
    }

    @Test func roundTripsDocumentAndComments() throws {
        let file = try sampleFile()
        let decoded = try CanvasFile.decode(try file.encoded())
        #expect(decoded == file)
        #expect(decoded.document.children(of: "settings.general").map(\.id) == file.document.children(of: "settings.general").map(\.id))
    }

    @Test func theSameDocumentWritesTheSameBytes() throws {
        let file = try sampleFile()
        let first = try file.encoded()
        let second = try CanvasFile.decode(first).encoded()
        #expect(first == second)
        let text = String(decoding: first, as: UTF8.self)
        #expect(text.contains("\"createdAt\" : \"2027-01-15T08:00:00Z\""))
        #expect(text.contains("\"settings.wifi/settingRow.title\""))
    }

    @Test func rejectsOtherFilesAndNewerVersions() {
        #expect(throws: CanvasFileError.notACanvasFile) { try CanvasFile.decode(Data(#"{"nodes": {}}"#.utf8)) }
        #expect(throws: CanvasFileError.notACanvasFile) { try CanvasFile.decode(Data("not json".utf8)) }
        #expect(throws: CanvasFileError.unsupportedVersion(2)) {
            try CanvasFile.decode(Data(#"{"format": "design-canvas", "version": 2}"#.utf8))
        }
    }
}

@MainActor @Suite struct CanvasFileStoreTests {
    @Test func openingAFileThatIsNotACanvasKeepsTheCurrentFile() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let canvasURL = directory.appending(path: "Screens.canvas")
        let otherURL = directory.appending(path: "package.json")
        let other = Data(#"{"name": "app"}"#.utf8)
        try CanvasFile(document: .sample()).encoded().write(to: canvasURL)
        try other.write(to: otherURL)

        let store = CanvasFileStore(url: canvasURL)
        var file = try #require(try store.load())
        #expect(throws: CanvasFileError.notACanvasFile) { try store.switchTo(otherURL) }
        #expect(store.url == canvasURL)

        _ = try file.document.apply(.set("settings.airplane", .isOn, .bool(true)))
        store.scheduleSave { [file] in file }
        store.saveNow()
        #expect(try Data(contentsOf: otherURL) == other)
        #expect(try CanvasFile.decode(Data(contentsOf: canvasURL)) == file)
    }
}

@Suite struct InspectionTests {
    @Test func tokensAreGroupedByWhatTheyResolveTo() {
        let tokens = CanvasDocument.sample().tokens
        #expect(tokens.ids(of: .textStyle) == ["text.row", "text.rowDetail"])
        #expect(tokens.ids(of: .number).starts(with: ["radius.button", "radius.card", "radius.icon"]))
        #expect(!tokens.ids(of: .number).contains("color.label"))
        #expect(tokens.ids(of: .color).contains("color.label"))
        #expect(tokens.kind(of: "missing") == nil)
    }

    @Test func tokenGroupsFollowTheIDPath() {
        let tokens = TokenSet(tokens: [
            Token("color.text.ink", .system("label")), Token("color.text.muted", .system("secondaryLabel")),
            Token("color.accent.base", .system("systemBlue")), Token("space.4", .number(16)), Token("gap", .number(8)),
        ])
        #expect(tokens.groups(of: .color).map(\.name) == ["color.accent", "color.text"])
        #expect(tokens.groups(of: .color).last?.ids == ["color.text.ink", "color.text.muted"])
        #expect(tokens.groups(of: .number).map(\.name) == ["", "space"])
    }

    @Test func tokenGroupsStayWholeAroundDeeperIDs() {
        let tokens = TokenSet(tokens: [
            Token("color.z", .system("label")), Token("color.b.c", .system("label")), Token("color.a", .system("label")),
        ])
        let groups = tokens.groups(of: .color)
        #expect(groups.map(\.name) == ["color", "color.b"])
        #expect(groups.map(\.ids) == [["color.a", "color.z"], ["color.b.c"]])
    }

    @Test func detachingATokenGivesItsLiteral() {
        let tokens = CanvasDocument.sample().tokens
        #expect(tokens.literal("space.row") == .number(12))
        #expect(tokens.literal("color.label") == .string("label"))
        #expect(tokens.literal("color.accent", mode: "dark") == .color(RGBA(hex: "#0A84FF")!))
        #expect(tokens.literal("text.rowDetail") == .string("body"))
    }

    @Test func propertiesTakeTokensOfOneKind() {
        #expect(Prop.fill.tokenKind == .color)
        #expect(Prop.spacing.tokenKind == .number)
        #expect(Prop.font.tokenKind == .textStyle)
        #expect(Prop.text.tokenKind == nil)
        #expect(Node.Kind.section.props == [.title])
        #expect(Node.Kind.text.props.first == .text)
    }

    @Test func usageCountsPropsOverridesAndAliases() {
        let usage = CanvasDocument.sample().tokenUsage()
        #expect(usage["space.row"] == 1)
        #expect(usage["text.row"] == 2)  // the title and the alias text.rowDetail
        #expect(usage["brand.coral"] == 2)  // the card's thumbnail and one instance override
        #expect(usage["brand.outline"] == 1)
    }
}

@Suite struct RedlineTests {
    @Test func insetsMeasureEveryEdge() {
        let lines = Redlines.insets(of: CGRect(x: 16, y: 8, width: 100, height: 30), in: CGRect(x: 0, y: 0, width: 132, height: 46))
        #expect(lines.map(\.length) == [16, 16, 8, 8])
        #expect(lines[0] == Redline(from: CGPoint(x: 0, y: 23), to: CGPoint(x: 16, y: 23)))
    }

    @Test func gapsRunThroughTheSharedSpan() {
        let icon = CGRect(x: 0, y: 0, width: 30, height: 30)
        let title = CGRect(x: 42, y: 5, width: 60, height: 20)
        #expect(Redlines.gaps(from: icon, to: title) == [Redline(from: CGPoint(x: 30, y: 15), to: CGPoint(x: 42, y: 15))])
        #expect(Redlines.gaps(from: title, to: icon).map(\.length) == [12])
        let below = CGRect(x: 10, y: 50, width: 10, height: 10)
        #expect(Redlines.gaps(from: icon, to: below) == [Redline(from: CGPoint(x: 15, y: 30), to: CGPoint(x: 15, y: 50))])
    }

    @Test func betweenPicksInsetsForNestedRects() {
        let outer = CGRect(x: 0, y: 0, width: 100, height: 100)
        let inner = CGRect(x: 10, y: 10, width: 10, height: 10)
        #expect(Redlines.between(inner, outer).count == 4)
        #expect(Redlines.between(outer, inner).count == 4)
    }

    @Test func spacingOfARowInAnHStack() throws {
        let tree = try CanvasDocument.sample().resolve("settingRow")
        let frames: [String: CGRect] = [
            "settingRow": CGRect(x: 0, y: 0, width: 300, height: 30),
            "settingRow.icon": CGRect(x: 0, y: 0, width: 30, height: 30),
            "settingRow.title": CGRect(x: 42, y: 5, width: 60, height: 20),
            "settingRow.spacer": CGRect(x: 114, y: 0, width: 100, height: 30),
            "settingRow.value": CGRect(x: 226, y: 5, width: 74, height: 20),
        ]
        let spacing = try #require(Spacing(of: "settingRow.title", in: tree, frames: frames))
        #expect(spacing.container == "settingRow")
        #expect(spacing.leading == 42)
        #expect(spacing.top == 5)
        #expect(spacing.previous?.sibling == "settingRow.icon")
        #expect(spacing.previous?.value == 12)
        // The spacer is skipped: the gap runs to the value.
        #expect(spacing.next?.sibling == "settingRow.value")
        #expect(spacing.next?.value == 124)
        // Gaps replace the padding on their side: left and right are gaps, top and bottom padding.
        #expect(spacing.redlines.map(\.length) == [12, 124, 5, 5])
    }

    @Test func listRowContentMeasuresToItsRow() throws {
        let tree = try CanvasDocument.sample().resolve("settings")
        let frames: [String: CGRect] = [
            "settings.list": CGRect(x: 0, y: 100, width: 402, height: 700),
            "settings.wifi": CGRect(x: 32, y: 301, width: 338, height: 30),
        ]
        let rows = ["settings.wifi": CGRect(x: 16, y: 290, width: 370, height: 52)]
        let spacing = try #require(Spacing(of: "settings.wifi", in: tree, frames: frames, rows: rows))
        #expect(spacing.inRow)
        #expect(spacing.container == "settings.general")
        #expect([spacing.leading, spacing.trailing, spacing.top, spacing.bottom] == [16, 16, 11, 11])
        // Rows are separate cells: no gaps to the rows around it.
        #expect(spacing.previous == nil && spacing.next == nil)
    }

    @Test func paddingMeasuresToTheParent() throws {
        let tree = try CanvasDocument.sample().resolve("settings")
        let frames: [String: CGRect] = [
            "settings.profile": CGRect(x: 0, y: 0, width: 300, height: 60),
            "settings.profile/profileRow.avatar": CGRect(x: 0, y: 8, width: 44, height: 44),
            "settings.profile/profileRow.text": CGRect(x: 58, y: 10, width: 200, height: 40),
            "settings.profile/profileRow.name": CGRect(x: 58, y: 10, width: 120, height: 22),
            "settings.profile/profileRow.detail": CGRect(x: 58, y: 34, width: 200, height: 16),
        ]
        let spacing = try #require(Spacing(of: "settings.profile/profileRow.name", in: tree, frames: frames))
        // The parent is the VStack, even where its edge is the name's own.
        #expect(spacing.container == "settings.profile/profileRow.text")
        #expect(spacing.insets.allSatisfy { $0.container == "settings.profile/profileRow.text" })
        #expect([spacing.leading, spacing.trailing, spacing.top, spacing.bottom] == [0, 80, 0, 18])
        #expect(spacing.next?.value == 2)
        // Zero padding draws nothing; the gap below replaces the bottom padding.
        #expect(spacing.redlines.map(\.length) == [2, 80])
    }

    @Test func typingCoalescesIntoOneUndoStep() throws {
        var document = CanvasDocument.sample()
        var history = History()
        for text in ["W", "WL", "WLA", "WLAN"] {
            try history.perform(.set("settingRow.title", .text, .string(text)), on: &document, coalescing: "title")
        }
        try history.perform(.set("settingRow.title", .opacity, .number(0.5)), on: &document)
        try history.undo(&document)
        #expect(document["settingRow.title"]?[.text] == .string("WLAN"))
        try history.undo(&document)
        #expect(document["settingRow.title"]?[.text] == .string("Title"))
        try history.redo(&document)
        #expect(document["settingRow.title"]?[.text] == .string("WLAN"))
    }
}

@Suite struct PageTests {
    @Test func aFileFromBeforePagesIsOnePage() {
        let document = CanvasDocument.sample()
        #expect(document.pages.map(\.id) == [CanvasDocument.rootID])
        #expect(document.canvasItems == document.children(of: CanvasDocument.rootID))
        #expect(document.page(of: document.canvasItems[0].id) == CanvasDocument.rootID)
    }

    @Test func pagesHoldTheirItemsInOrder() throws {
        var document = CanvasDocument()
        let flows = Node(id: "flows", kind: .page, parent: CanvasDocument.rootID, order: "a", props: [.name: .string("Flows")])
        let parts = Node(id: "parts", kind: .page, parent: CanvasDocument.rootID, order: "b")
        try document.apply(.batch([
            .insert(parts), .insert(flows),
            .insert(Node(id: "home", kind: .screen, parent: "flows", order: "a")),
            .insert(Node(id: "button", kind: .component, parent: "parts", order: "a")),
        ]))
        #expect(document.pages.map(\.id) == ["flows", "parts"])
        #expect(document.canvasItems.map(\.id) == ["home", "button"])
        #expect(document.page(of: "button") == "parts")
        #expect(document.items(onPage: CanvasDocument.rootID).isEmpty)
    }

    @Test func undoingAnAddedPageFallsBackToTheFirst() throws {
        var document = CanvasDocument()
        var history = History()
        let flows = Node(id: "flows", kind: .page, parent: CanvasDocument.rootID, order: "a")
        try history.perform(.insert(flows), on: &document)
        try history.perform(.insert(Node(id: "parts", kind: .page, parent: CanvasDocument.rootID, order: "b")), on: &document)
        #expect(document.existingPage("parts") == "parts")
        try history.undo(&document)
        #expect(document.existingPage("parts") == "flows")
        #expect(document.existingPage("flows") == "flows")
    }

    @Test func previewStaysOnItsPage() throws {
        var document = CanvasDocument()
        try document.apply(.batch([
            .insert(Node(id: "flows", kind: .page, parent: CanvasDocument.rootID, order: "a")),
            .insert(Node(id: "parts", kind: .page, parent: CanvasDocument.rootID, order: "b")),
            .insert(Node(id: "empty", kind: .page, parent: CanvasDocument.rootID, order: "c")),
            .insert(Node(id: "home", kind: .screen, parent: "flows", order: "a")),
            .insert(Node(id: "settings", kind: .screen, parent: "flows", order: "b")),
            .insert(Node(id: "button", kind: .component, parent: "parts", order: "a")),
        ]))
        #expect(document.previewScreen(onPage: "flows", selected: nil) == "home")
        #expect(document.previewScreen(onPage: "flows", selected: "settings") == "settings")
        // A selected component isn't a screen, and a screen on another page doesn't count.
        #expect(document.previewScreen(onPage: "flows", selected: "button") == "home")
        #expect(document.previewScreen(onPage: "parts", selected: "settings") == nil)
        #expect(document.previewScreen(onPage: "empty", selected: nil) == nil)
    }
}
