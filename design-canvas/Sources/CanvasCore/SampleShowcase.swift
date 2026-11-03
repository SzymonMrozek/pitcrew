extension CanvasDocument {
    /// A brand design system on top of Apple's: colors with light and dark values, radii,
    /// spacing and a card shadow. The custom screens use only these and Apple's tokens.
    static var showcaseTokens: [Token] {
        func color(_ light: String, _ dark: String) -> [String: TokenValue] {
            ["light": .color(RGBA(hex: light)!), "dark": .color(RGBA(hex: dark)!)]
        }
        return [
            Token("brand.primary", modes: color("#5B47E0", "#8C7BFF")),
            Token("brand.primarySoft", modes: color("#ECE9FF", "#29244D")),
            Token("brand.onPrimary", .color(RGBA(hex: "#FFFFFF")!)),
            Token("brand.canvas", modes: color("#F7F5F0", "#0E0E11")),
            Token("brand.surface", modes: color("#FFFFFF", "#1C1C21")),
            Token("brand.outline", .system("separator")),
            Token("brand.track", .system("systemFill")),
            Token("brand.shadow", modes: color("#2A20601F", "#00000080")),
            Token("brand.coral", modes: color("#FF7A59", "#FF8E72")),
            Token("brand.teal", modes: color("#1FA99B", "#35C8B8")),
            Token("brand.amber", modes: color("#F2B33D", "#FFC65C")),
            Token("radius.card", .number(20)),
            Token("radius.thumb", .number(14)),
            Token("radius.button", .number(16)),
            Token("radius.pill", .number(999)),
            Token("space.screen", .number(20)),
            Token("space.card", .number(14)),
            Token("space.section", .number(24)),
            Token("shadow.card", .number(10)),
        ]
    }

    /// Three screens that don't look like stock iOS: a reading list with cards and a
    /// floating tab bar, an audio player and a welcome screen, built from five components.
    static func addShowcase(_ b: inout SampleBuilder) {
        let label = Value.token("color.label")
        let secondary = Value.token("color.secondaryLabel")
        let primary = Value.token("brand.primary")
        let onPrimary = Value.token("brand.onPrimary")
        let surface = Value.token("brand.surface")
        let infinity = Value.string("infinity")

        // MARK: Components

        b.add("component.articleCard", .component, under: rootID, [.name: .string("ArticleCard"), .x: .number(980), .y: .number(290)])
        b.add("articleCard", .hstack, under: "component.articleCard", [
            .spacing: .number(14), .padding: .token("space.card"), .maxWidth: infinity, .frameAlignment: .string("leading"),
            .background: surface, .cornerRadius: .token("radius.card"),
            .shadowRadius: .token("shadow.card"), .shadowY: .number(4), .shadowColor: .token("brand.shadow"),
        ])
        b.add("articleCard.thumb", .zstack, under: "articleCard")
        b.add("articleCard.thumb.fill", .rectangle, under: "articleCard.thumb", [
            .fill: .token("brand.coral"), .width: .number(72), .height: .number(72), .cornerRadius: .token("radius.thumb"),
        ])
        b.add("articleCard.thumb.symbol", .image, under: "articleCard.thumb", [
            .symbol: .string("doc.text.fill"), .font: .string("title2"), .foreground: onPrimary,
        ])
        b.add("articleCard.text", .vstack, under: "articleCard", [.alignment: .string("leading"), .spacing: .number(4)])
        b.add("articleCard.source", .text, under: "articleCard.text", [
            .text: .string("Field Notes"), .font: .string("caption"), .weight: .string("semibold"), .foreground: primary,
        ])
        b.add("articleCard.title", .text, under: "articleCard.text", [
            .text: .string("How cities learn to breathe again"), .font: .string("headline"), .foreground: label,
        ])
        b.add("articleCard.meta", .hstack, under: "articleCard.text", [.spacing: .number(5)])
        b.add("articleCard.meta.icon", .image, under: "articleCard.meta", [
            .symbol: .string("clock"), .font: .string("caption"), .foreground: secondary,
        ])
        b.add("articleCard.meta.text", .text, under: "articleCard.meta", [
            .text: .string("12 min read"), .font: .string("caption"), .foreground: secondary,
        ])

        b.add("component.chip", .component, under: rootID, [.name: .string("Chip"), .x: .number(980), .y: .number(450)])
        b.add("chip", .text, under: "component.chip", [
            .text: .string("Articles"), .font: .string("subheadline"), .weight: .string("medium"), .foreground: label,
            .paddingHorizontal: .number(14), .paddingVertical: .number(8), .background: surface,
            .border: .token("brand.outline"), .cornerRadius: .token("radius.pill"),
        ])

        b.add("component.primaryButton", .component, under: rootID, [.name: .string("PrimaryButton"), .x: .number(980), .y: .number(550)])
        b.add("primaryButton", .button, under: "component.primaryButton", [
            .title: .string("Continue"), .font: .string("headline"), .foreground: onPrimary, .background: primary,
            .height: .number(54), .maxWidth: infinity, .cornerRadius: .token("radius.button"),
        ])

        b.add("component.tabBar", .component, under: rootID, [.name: .string("TabBar"), .x: .number(980), .y: .number(670)])
        b.add("tabBar", .hstack, under: "component.tabBar", [
            .spacing: .number(0), .paddingVertical: .number(10), .paddingHorizontal: .number(8), .maxWidth: infinity,
            .background: surface, .cornerRadius: .token("radius.pill"),
            .shadowRadius: .number(16), .shadowY: .number(6), .shadowColor: .token("brand.shadow"),
        ])
        for (index, tab) in [("house.fill", "Home"), ("magnifyingglass", "Search"), ("headphones", "Listen"), ("person.crop.circle", "Profile")].enumerated() {
            let id = NodeID("tabBar.\(tab.1.lowercased())")
            let color = index == 0 ? primary : secondary
            b.add(id, .vstack, under: "tabBar", [.spacing: .number(3), .maxWidth: infinity])
            b.add(NodeID("\(id).icon"), .image, under: id, [.symbol: .string(tab.0), .font: .string("title3"), .foreground: color])
            b.add(NodeID("\(id).title"), .text, under: id, [
                .text: .string(tab.1), .font: .string("caption2"), .weight: .string("medium"), .foreground: color,
            ])
        }

        b.add("component.featureRow", .component, under: rootID, [.name: .string("FeatureRow"), .x: .number(980), .y: .number(800)])
        b.add("featureRow", .hstack, under: "component.featureRow", [
            .spacing: .number(14), .maxWidth: infinity, .frameAlignment: .string("leading"),
        ])
        b.add("featureRow.badge", .zstack, under: "featureRow")
        b.add("featureRow.badge.fill", .rectangle, under: "featureRow.badge", [
            .fill: .token("brand.primarySoft"), .width: .number(44), .height: .number(44), .cornerRadius: .number(12),
        ])
        b.add("featureRow.badge.symbol", .image, under: "featureRow.badge", [
            .symbol: .string("bookmark.fill"), .font: .string("body"), .weight: .string("semibold"), .foreground: primary,
        ])
        b.add("featureRow.text", .vstack, under: "featureRow", [.alignment: .string("leading"), .spacing: .number(2)])
        b.add("featureRow.title", .text, under: "featureRow.text", [
            .text: .string("Save from anywhere"), .font: .string("headline"), .foreground: label,
        ])
        b.add("featureRow.detail", .text, under: "featureRow.text", [
            .text: .string("Share any link to your list"), .font: .string("subheadline"), .foreground: secondary,
        ])

        // MARK: Reading list

        b.add("home", .screen, under: rootID, [
            .name: .string("Reading List"), .device: .string("iPhone 17 Pro"), .x: .number(0), .y: .number(1000),
            .background: .token("brand.canvas"),
        ])
        b.add("home.stack", .zstack, under: "home", [.alignment: .string("bottom")])
        b.add("home.scroll", .scroll, under: "home.stack")
        b.add("home.content", .vstack, under: "home.scroll", [
            .alignment: .string("leading"), .spacing: .token("space.section"), .paddingHorizontal: .token("space.screen"),
            .paddingVertical: .number(8),
        ])

        b.add("home.header", .hstack, under: "home.content", [.spacing: .number(12)])
        b.add("home.greeting", .vstack, under: "home.header", [.alignment: .string("leading"), .spacing: .number(2)])
        b.add("home.date", .text, under: "home.greeting", [
            .text: .string("MONDAY, 2 NOVEMBER"), .font: .string("caption"), .weight: .string("semibold"), .foreground: secondary,
        ])
        b.add("home.title", .text, under: "home.greeting", [
            .text: .string("Good morning"), .font: .number(32), .weight: .string("bold"), .foreground: label,
        ])
        b.add("home.header.spacer", .spacer, under: "home.header")
        b.add("home.avatar", .text, under: "home.header", [
            .text: .string("JA"), .font: .string("subheadline"), .weight: .string("bold"), .foreground: primary,
            .width: .number(44), .height: .number(44), .background: .token("brand.primarySoft"), .cornerRadius: .token("radius.pill"),
        ])

        b.add("home.hero", .vstack, under: "home.content", [
            .alignment: .string("leading"), .spacing: .number(14), .padding: .number(20), .maxWidth: infinity,
            .frameAlignment: .string("leading"), .background: primary, .cornerRadius: .number(26),
            .shadowRadius: .number(18), .shadowY: .number(8), .shadowColor: .token("brand.shadow"),
        ])
        b.add("home.hero.kicker", .hstack, under: "home.hero", [.spacing: .number(6)])
        b.add("home.hero.kicker.icon", .image, under: "home.hero.kicker", [
            .symbol: .string("waveform"), .font: .string("caption"), .weight: .string("bold"), .foreground: onPrimary,
        ])
        b.add("home.hero.kicker.text", .text, under: "home.hero.kicker", [
            .text: .string("CONTINUE LISTENING"), .font: .string("caption"), .weight: .string("bold"), .foreground: onPrimary,
            .opacity: .number(0.85),
        ])
        b.add("home.hero.title", .text, under: "home.hero", [
            .text: .string("The quiet revolution in how we read on screens"), .font: .string("title2"), .weight: .string("bold"),
            .foreground: onPrimary,
        ])
        b.add("home.hero.progress", .zstack, under: "home.hero", [.alignment: .string("leading")])
        b.add("home.hero.progress.track", .rectangle, under: "home.hero.progress", [
            .fill: .color(RGBA(hex: "#FFFFFF40")!), .height: .number(4), .cornerRadius: .number(2),
        ])
        b.add("home.hero.progress.value", .rectangle, under: "home.hero.progress", [
            .fill: onPrimary, .width: .number(170), .height: .number(4), .cornerRadius: .number(2),
        ])
        b.add("home.hero.footer", .hstack, under: "home.hero")
        b.add("home.hero.time", .text, under: "home.hero.footer", [
            .text: .string("18 of 32 min"), .font: .string("footnote"), .weight: .string("medium"), .foreground: onPrimary,
            .opacity: .number(0.85),
        ])
        b.add("home.hero.footer.spacer", .spacer, under: "home.hero.footer")
        b.add("home.hero.play", .zstack, under: "home.hero.footer")
        b.add("home.hero.play.fill", .rectangle, under: "home.hero.play", [
            .fill: onPrimary, .width: .number(44), .height: .number(44), .cornerRadius: .token("radius.pill"),
        ])
        b.add("home.hero.play.icon", .image, under: "home.hero.play", [
            .symbol: .string("play.fill"), .font: .string("body"), .foreground: primary,
        ])

        b.add("home.filters", .hstack, under: "home.content", [.spacing: .number(8)])
        b.add("home.filter.all", .instance, under: "home.filters", [.component: .string("component.chip")], overrides: [
            "chip": [.text: .string("All"), .background: primary, .foreground: onPrimary, .border: .string("clear")],
        ])
        for name in ["Articles", "Newsletters", "Saved"] {
            b.add(NodeID("home.filter.\(name.lowercased())"), .instance, under: "home.filters", [.component: .string("component.chip")], overrides: [
                "chip": [.text: .string(name)],
            ])
        }

        b.add("home.upNext", .hstack, under: "home.content")
        b.add("home.upNext.title", .text, under: "home.upNext", [
            .text: .string("Up next"), .font: .string("title3"), .weight: .string("bold"), .foreground: label,
        ])
        b.add("home.upNext.spacer", .spacer, under: "home.upNext")
        b.add("home.upNext.all", .text, under: "home.upNext", [
            .text: .string("See all"), .font: .string("subheadline"), .weight: .string("medium"), .foreground: primary,
        ])

        b.add("home.cards", .vstack, under: "home.content", [.spacing: .number(12)])
        let cards: [(String, String, String, String, String, String, String)] = [
            ("one", "brand.coral", "doc.text.fill", "Field Notes", "How cities learn to breathe again", "clock", "12 min read"),
            ("two", "brand.teal", "headphones", "The Long Read", "What octopuses can teach us about minds", "headphones", "24 min · Listen"),
            ("three", "brand.amber", "lightbulb.fill", "Design Matters", "Calm technology, ten years on", "text.alignleft", "Summary · 3 min"),
        ]
        for card in cards {
            b.add(NodeID("home.card.\(card.0)"), .instance, under: "home.cards", [.component: .string("component.articleCard")], overrides: [
                "articleCard.thumb.fill": [.fill: .token(TokenID(rawValue: card.1))],
                "articleCard.thumb.symbol": [.symbol: .string(card.2)],
                "articleCard.source": [.text: .string(card.3)],
                "articleCard.title": [.text: .string(card.4)],
                "articleCard.meta.icon": [.symbol: .string(card.5)],
                "articleCard.meta.text": [.text: .string(card.6)],
            ])
        }
        // Room to scroll past the floating tab bar.
        b.add("home.content.inset", .rectangle, under: "home.content", [.fill: .string("clear"), .height: .number(72)])
        b.add("home.tabBar.inset", .vstack, under: "home.stack", [.paddingHorizontal: .number(28)])
        b.add("home.tabBar", .instance, under: "home.tabBar.inset", [.component: .string("component.tabBar")])

        // MARK: Player

        b.add("player", .screen, under: rootID, [
            .name: .string("Now Playing"), .device: .string("iPhone 17 Pro"), .x: .number(940), .y: .number(1000),
            .background: .token("brand.canvas"),
        ])
        b.add("player.content", .vstack, under: "player", [
            .spacing: .number(28), .paddingHorizontal: .number(24), .paddingVertical: .number(8), .maxHeight: infinity,
        ])

        b.add("player.top", .hstack, under: "player.content")
        func roundButton(_ id: NodeID, under parent: NodeID, symbol: String) {
            b.add(id, .image, under: parent, [
                .symbol: .string(symbol), .font: .string("subheadline"), .weight: .string("semibold"), .foreground: label,
                .width: .number(40), .height: .number(40), .background: surface, .cornerRadius: .token("radius.pill"),
            ])
        }
        roundButton("player.close", under: "player.top", symbol: "chevron.down")
        b.add("player.top.spacer1", .spacer, under: "player.top")
        b.add("player.source", .vstack, under: "player.top", [.spacing: .number(1)])
        b.add("player.source.kicker", .text, under: "player.source", [
            .text: .string("PLAYING FROM"), .font: .string("caption2"), .weight: .string("semibold"), .foreground: secondary,
        ])
        b.add("player.source.name", .text, under: "player.source", [
            .text: .string("Up next"), .font: .string("footnote"), .weight: .string("semibold"), .foreground: label,
        ])
        b.add("player.top.spacer2", .spacer, under: "player.top")
        roundButton("player.more", under: "player.top", symbol: "ellipsis")

        b.add("player.art", .zstack, under: "player.content", [
            .alignment: .string("bottomLeading"), .cornerRadius: .number(28),
            .shadowRadius: .number(24), .shadowY: .number(12), .shadowColor: .token("brand.shadow"),
        ])
        b.add("player.art.fill", .rectangle, under: "player.art", [.fill: .token("brand.teal"), .height: .number(340)])
        b.add("player.art.symbol", .image, under: "player.art", [
            .symbol: .string("headphones"), .font: .number(120), .weight: .string("light"), .foreground: onPrimary,
            .opacity: .number(0.25), .maxWidth: infinity, .height: .number(340),
        ])
        b.add("player.art.label", .text, under: "player.art", [
            .text: .string("THE LONG READ"), .font: .string("caption"), .weight: .string("heavy"), .foreground: onPrimary,
            .padding: .number(20),
        ])

        b.add("player.info", .hstack, under: "player.content", [.spacing: .number(16)])
        b.add("player.info.text", .vstack, under: "player.info", [
            .alignment: .string("leading"), .spacing: .number(4), .maxWidth: infinity, .frameAlignment: .string("leading"),
        ])
        b.add("player.title", .text, under: "player.info.text", [
            .text: .string("What octopuses can teach us about minds"), .font: .string("title3"), .weight: .string("bold"),
            .foreground: label,
        ])
        b.add("player.byline", .text, under: "player.info.text", [
            .text: .string("The Long Read · Narrated"), .font: .string("subheadline"), .foreground: secondary,
        ])
        b.add("player.like", .image, under: "player.info", [.symbol: .string("heart"), .font: .string("title3"), .foreground: primary])

        b.add("player.progress", .vstack, under: "player.content", [.spacing: .number(8)])
        b.add("player.progress.bar", .zstack, under: "player.progress", [.alignment: .string("leading")])
        b.add("player.progress.track", .rectangle, under: "player.progress.bar", [
            .fill: .token("brand.track"), .height: .number(6), .cornerRadius: .number(3),
        ])
        b.add("player.progress.value", .rectangle, under: "player.progress.bar", [
            .fill: primary, .width: .number(150), .height: .number(6), .cornerRadius: .number(3),
        ])
        b.add("player.progress.times", .hstack, under: "player.progress")
        b.add("player.progress.elapsed", .text, under: "player.progress.times", [
            .text: .string("11:24"), .font: .string("caption"), .weight: .string("medium"), .foreground: secondary,
        ])
        b.add("player.progress.spacer", .spacer, under: "player.progress.times")
        b.add("player.progress.remaining", .text, under: "player.progress.times", [
            .text: .string("−12:36"), .font: .string("caption"), .weight: .string("medium"), .foreground: secondary,
        ])

        b.add("player.controls", .hstack, under: "player.content", [.spacing: .number(0)])
        b.add("player.controls.spacer1", .spacer, under: "player.controls")
        b.add("player.back", .image, under: "player.controls", [.symbol: .string("gobackward.15"), .font: .string("title"), .foreground: label])
        b.add("player.controls.spacer2", .spacer, under: "player.controls")
        b.add("player.pause", .image, under: "player.controls", [
            .symbol: .string("pause.fill"), .font: .number(30), .foreground: onPrimary, .width: .number(76), .height: .number(76),
            .background: primary, .cornerRadius: .token("radius.pill"),
            .shadowRadius: .number(14), .shadowY: .number(6), .shadowColor: .token("brand.shadow"),
        ])
        b.add("player.controls.spacer3", .spacer, under: "player.controls")
        b.add("player.forward", .image, under: "player.controls", [.symbol: .string("goforward.30"), .font: .string("title"), .foreground: label])
        b.add("player.controls.spacer4", .spacer, under: "player.controls")

        b.add("player.content.spacer", .spacer, under: "player.content")
        b.add("player.bottom", .hstack, under: "player.content")
        b.add("player.volume", .image, under: "player.bottom", [
            .symbol: .string("speaker.wave.2.fill"), .font: .string("body"), .foreground: secondary,
        ])
        b.add("player.bottom.spacer1", .spacer, under: "player.bottom")
        b.add("player.speed", .instance, under: "player.bottom", [.component: .string("component.chip")], overrides: [
            "chip": [.text: .string("1.2×")],
        ])
        b.add("player.bottom.spacer2", .spacer, under: "player.bottom")
        b.add("player.queue", .image, under: "player.bottom", [
            .symbol: .string("list.bullet"), .font: .string("body"), .foreground: secondary,
        ])

        // MARK: Welcome

        b.add("welcome", .screen, under: rootID, [
            .name: .string("Welcome"), .device: .string("iPhone 17 Pro"), .x: .number(1880), .y: .number(1000),
            .background: .token("brand.canvas"),
        ])
        b.add("welcome.content", .vstack, under: "welcome", [
            .spacing: .number(0), .paddingHorizontal: .number(24), .paddingVertical: .number(8), .maxHeight: infinity,
        ])
        b.add("welcome.spacer1", .spacer, under: "welcome.content")
        b.add("welcome.hero", .vstack, under: "welcome.content", [.spacing: .number(18)])
        b.add("welcome.icon", .image, under: "welcome.hero", [
            .symbol: .string("bookmark.fill"), .font: .number(40), .foreground: onPrimary,
            .width: .number(92), .height: .number(92), .background: primary, .cornerRadius: .number(26),
            .shadowRadius: .number(18), .shadowY: .number(10), .shadowColor: .token("brand.shadow"),
        ])
        b.add("welcome.title", .text, under: "welcome.hero", [
            .text: .string("Read it later.\nListen anytime."), .font: .number(34), .weight: .string("bold"), .foreground: label,
            .multilineTextAlignment: .string("center"),
        ])
        b.add("welcome.subtitle", .text, under: "welcome.hero", [
            .text: .string("Save articles from anywhere. Read them in full or as a summary, or listen on the go."),
            .font: .string("body"), .foreground: secondary, .multilineTextAlignment: .string("center"),
        ])
        b.add("welcome.spacer2", .spacer, under: "welcome.content")
        b.add("welcome.features", .vstack, under: "welcome.content", [
            .alignment: .string("leading"), .spacing: .number(18), .padding: .number(20), .maxWidth: infinity,
            .background: surface, .cornerRadius: .token("radius.card"),
        ])
        let features: [(String, String, String, String)] = [
            ("save", "bookmark.fill", "Save from anywhere", "Share any link to your list"),
            ("listen", "waveform", "Listen on the go", "Natural voices, offline too"),
            ("summary", "text.alignleft", "Short on time?", "Get a summary in your language"),
        ]
        for feature in features {
            b.add(NodeID("welcome.feature.\(feature.0)"), .instance, under: "welcome.features", [.component: .string("component.featureRow")], overrides: [
                "featureRow.badge.symbol": [.symbol: .string(feature.1)],
                "featureRow.title": [.text: .string(feature.2)],
                "featureRow.detail": [.text: .string(feature.3)],
            ])
        }
        b.add("welcome.spacer3", .spacer, under: "welcome.content")
        b.add("welcome.actions", .vstack, under: "welcome.content", [.spacing: .number(14)])
        b.add("welcome.start", .instance, under: "welcome.actions", [.component: .string("component.primaryButton")], overrides: [
            "primaryButton": [.title: .string("Get started")],
        ])
        b.add("welcome.signIn", .button, under: "welcome.actions", [
            .title: .string("I already have an account"), .font: .string("subheadline"), .weight: .string("semibold"),
            .foreground: primary,
        ])
    }
}
