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
