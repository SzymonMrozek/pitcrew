extension CanvasDocument {
    /// A Settings screen built from two components and Apple semantic tokens. The app
    /// opens it and the tests use it, so it stays small and covers every resolve path.
    public static func sample() -> CanvasDocument {
        var document = CanvasDocument(tokens: TokenSet(tokens: [
            Token("color.accent", modes: [
                "light": .color(RGBA(hex: "#007AFF")!),
                "dark": .color(RGBA(hex: "#0A84FF")!),
            ]),
            Token("color.label", .system("label")),
            Token("color.secondaryLabel", .system("secondaryLabel")),
            Token("color.destructive", .system("systemRed")),
            Token("color.iconForeground", .color(RGBA(hex: "#FFFFFF")!)),
            Token("color.avatar", .system("systemGray")),
            Token("radius.icon", .number(7)),
            Token("size.icon", .number(30)),
            Token("space.row", .number(12)),
            Token("text.row", .textStyle("body")),
            Token("text.rowDetail", .alias("text.row")),
        ]))

        var builder = Builder(document: document)

        builder.add("component.settingRow", .component, under: CanvasDocument.rootID, [
            .name: .string("SettingRow"), .x: .number(980), .y: .number(0),
        ])
        builder.add("settingRow", .hstack, under: "component.settingRow", [.spacing: .token("space.row")])
        builder.add("settingRow.icon", .zstack, under: "settingRow")
        builder.add("settingRow.icon.background", .rectangle, under: "settingRow.icon", [
            .fill: .token("color.accent"), .cornerRadius: .token("radius.icon"),
            .width: .token("size.icon"), .height: .token("size.icon"),
        ])
        builder.add("settingRow.icon.symbol", .image, under: "settingRow.icon", [
            .symbol: .string("gear"), .foreground: .token("color.iconForeground"), .font: .string("callout"),
        ])
        builder.add("settingRow.title", .text, under: "settingRow", [
            .text: .string("Title"), .font: .token("text.row"), .foreground: .token("color.label"),
        ])
        builder.add("settingRow.spacer", .spacer, under: "settingRow")
        builder.add("settingRow.value", .text, under: "settingRow", [
            .text: .string(""), .font: .token("text.rowDetail"), .foreground: .token("color.secondaryLabel"),
        ])

        builder.add("component.profileRow", .component, under: CanvasDocument.rootID, [
            .name: .string("ProfileRow"), .x: .number(980), .y: .number(140),
        ])
        builder.add("profileRow", .hstack, under: "component.profileRow", [.spacing: .number(14)])
        builder.add("profileRow.avatar", .image, under: "profileRow", [
            .symbol: .string("person.crop.circle.fill"), .font: .string("largeTitle"),
            .foreground: .token("color.avatar"),
        ])
        builder.add("profileRow.text", .vstack, under: "profileRow", [
            .alignment: .string("leading"), .spacing: .number(2),
        ])
        builder.add("profileRow.name", .text, under: "profileRow.text", [
            .text: .string("Jane Appleseed"), .font: .string("title3"), .weight: .string("semibold"),
        ])
        builder.add("profileRow.detail", .text, under: "profileRow.text", [
            .text: .string("Apple Account, iCloud and more"), .font: .string("footnote"),
            .foreground: .token("color.secondaryLabel"),
        ])

        builder.add("settings", .screen, under: CanvasDocument.rootID, [
            .name: .string("Settings"), .device: .string("iPhone 17 Pro"), .x: .number(0), .y: .number(0),
        ])
        builder.add("settings.nav", .navigationStack, under: "settings", [.title: .string("Settings")])
        builder.add("settings.list", .list, under: "settings.nav", [.style: .string("insetGrouped")])
        builder.add("settings.account", .section, under: "settings.list")
        builder.add("settings.profile", .instance, under: "settings.account", [
            .component: .string("component.profileRow"),
        ])
        builder.add("settings.general", .section, under: "settings.list", [.title: .string("Connectivity")])
        builder.add("settings.airplane", .toggle, under: "settings.general", [
            .title: .string("Airplane Mode"), .isOn: .bool(false),
        ])
        builder.add("settings.wifi", .instance, under: "settings.general", [
            .component: .string("component.settingRow"),
        ], overrides: [
            "settingRow.icon.symbol": [.symbol: .string("wifi")],
            "settingRow.title": [.text: .string("Wi-Fi")],
            "settingRow.value": [.text: .string("Home")],
        ])
        builder.add("settings.bluetooth", .instance, under: "settings.general", [
            .component: .string("component.settingRow"),
        ], overrides: [
            "settingRow.icon.symbol": [.symbol: .string("antenna.radiowaves.left.and.right")],
            "settingRow.title": [.text: .string("Bluetooth")],
            "settingRow.value": [.text: .string("On")],
        ])
        builder.add("settings.signOutSection", .section, under: "settings.list")
        builder.add("settings.signOut", .button, under: "settings.signOutSection", [
            .title: .string("Sign Out"), .foreground: .token("color.destructive"),
        ])

        document = builder.document
        return document
    }

    private struct Builder {
        var document: CanvasDocument

        mutating func add(
            _ id: NodeID,
            _ kind: Node.Kind,
            under parent: NodeID,
            _ props: [Prop: Value] = [:],
            overrides: [NodeID: [Prop: Value]] = [:]
        ) {
            let node = Node(
                id: id, kind: kind, parent: parent, order: document.appendOrder(in: parent),
                props: props, overrides: overrides
            )
            do { try document.apply(.insert(node)) } catch { preconditionFailure("Sample node \(id): \(error)") }
        }
    }
}
