import CoreGraphics
import Foundation

// MARK: - Web screens

/// A screen's platform. iOS screens are SwiftUI trees drawn by the engine; web screens
/// show a live page, loaded from `url` and rendered by WebKit at a viewport size.
public enum Platform: String, Hashable, Codable, Sendable, CaseIterable {
    case ios
    case web
}

extension Prop {
    /// `ios` (the default) or `web`, on a screen.
    public static let platform: Prop = "platform"
    /// A web screen's page, such as `http://localhost:8000/pricing.html`.
    public static let url: Prop = "url"
    /// The page to load for the light appearance, for pages that keep their theme in
    /// script state. Without it the light copy loads `url` with `data-theme="light"` on
    /// the root element and `prefers-color-scheme: light`.
    public static let lightURL: Prop = "lightUrl"

    // A DOM element's content, as captured from the page.
    public static let tag: Prop = "tag"
    /// The element's `id` attribute.
    public static let htmlID: Prop = "htmlId"
    /// The element's classes, space-separated.
    public static let classes: Prop = "classes"
    public static let role: Prop = "role"
    /// `aria-label`, or `alt` on an image.
    public static let ariaLabel: Prop = "ariaLabel"

    // A DOM element's computed style, in CSS pixels where a number.
    public static let color: Prop = "color"
    public static let backgroundColor: Prop = "backgroundColor"
    public static let borderColor: Prop = "borderColor"
    public static let fontSize: Prop = "fontSize"
    public static let fontWeight: Prop = "fontWeight"
    public static let fontFamily: Prop = "fontFamily"
    public static let lineHeight: Prop = "lineHeight"
    public static let borderRadius: Prop = "borderRadius"
    /// A number when all four sides match, else `top right bottom left`.
    public static let cssPadding: Prop = "cssPadding"
    public static let gap: Prop = "gap"
    public static let display: Prop = "display"
    public static let flexDirection: Prop = "flexDirection"
    public static let backdropFilter: Prop = "backdropFilter"
}

/// A web viewport preset: a browser window's inner size. Web screens have no status
/// bar, no safe areas and square corners.
public struct WebViewport: Hashable, Sendable {
    public let name: String
    public let width: Double
    public let height: Double

    public init(name: String, width: Double, height: Double) {
        self.name = name
        self.width = width
        self.height = height
    }

    public static let all: [WebViewport] = [
        WebViewport(name: "Desktop 1440", width: 1440, height: 900),
        WebViewport(name: "Laptop 1280", width: 1280, height: 800),
        WebViewport(name: "Tablet 768", width: 768, height: 1024),
        WebViewport(name: "Mobile 390", width: 390, height: 844),
    ]

    /// The preset with this name, or nil for a name that isn't a web viewport.
    public static func preset(_ name: String?) -> WebViewport? { all.first { $0.name == name } }

    /// The preset with this name, else Desktop 1440.
    public static func named(_ name: String?) -> WebViewport { preset(name) ?? all[0] }

    public var size: CGSize { CGSize(width: width, height: height) }
}

extension Node {
    public var platform: Platform { props[.platform]?.string.flatMap(Platform.init(rawValue:)) ?? .ios }
    public var isWebScreen: Bool { kind == .screen && platform == .web }

    /// A new web screen at a page point.
    public static func webScreen(
        id: NodeID = .random(), parent: NodeID, order: String, name: String, url: String,
        viewport: WebViewport = WebViewport.all[0], at origin: CGPoint = .zero
    ) -> Node {
        Node(id: id, kind: .screen, parent: parent, order: order, props: [
            .name: .string(name), .platform: .string(Platform.web.rawValue), .url: .string(url),
            .device: .string(viewport.name), .x: .number(origin.x), .y: .number(origin.y),
        ])
    }
}

extension ResolvedNode {
    public var isWebScreen: Bool { kind == .screen && props[.platform]?.string == Platform.web.rawValue }
    /// A DOM element of a web screen's page.
    public var isElement: Bool { kind == .element }
}

extension CanvasDocument {
    /// Gap between a screen and its dark copy, beside it on the canvas.
    public static let darkCopyGap: Double = 68

    /// How far right of a screen its dark copy sits. iOS screens keep the fixed 470 points
    /// earlier files were laid out with; a web screen's copy sits a viewport width plus
    /// a gap away, since viewports are much wider than phones.
    public func darkCopyOffset(of screen: Node) -> Double {
        guard screen.isWebScreen else { return 470 }
        return WebViewport.named(screen[.device]?.string).width + 80
    }

    /// A web screen's viewport.
    public func viewport(of screen: Node) -> WebViewport? {
        screen.isWebScreen ? WebViewport.named(screen[.device]?.string) : nil
    }
}

// MARK: - DOM snapshots

/// One visible element of a captured page, as the page script reports it. Wrapper-only
/// elements are already collapsed and invisible ones left out.
public struct WebElement: Hashable, Codable, Sendable {
    /// A stable element path, unique in the page: `body>main.grid>div.panel[2]`, or
    /// `#chart` from the nearest ancestor with an `id`. Not a CSS selector.
    public var path: String
    public var tag: String
    public var id: String?
    public var classes: [String]?
    public var role: String?
    public var label: String?
    /// The element's own text, whitespace collapsed and shortened.
    public var text: String?
    /// `x, y, width, height` in CSS pixels from the viewport's top-left corner.
    public var frame: [Double]
    /// Computed styles by camelCase CSS name, as the browser reports them.
    public var styles: [String: String]?
    public var children: [WebElement]?

    public init(
        path: String, tag: String, id: String? = nil, classes: [String]? = nil, role: String? = nil,
        label: String? = nil, text: String? = nil, frame: [Double], styles: [String: String]? = nil,
        children: [WebElement]? = nil
    ) {
        self.path = path
        self.tag = tag
        self.id = id
        self.classes = classes
        self.role = role
        self.label = label
        self.text = text
        self.frame = frame
        self.styles = styles
        self.children = children
    }

    public var rect: CGRect {
        guard frame.count == 4 else { return .zero }
        return CGRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3])
    }
}

/// A CSS custom property from the page's `:root`, with what it computes to.
public struct WebVariable: Hashable, Codable, Sendable {
    /// Without the leading dashes: `ink` for `--ink`.
    public var name: String
    public var raw: String
    /// The computed color, as the browser writes it (`rgba(245, 245, 247, 0.64)`), when
    /// the value is a color.
    public var color: String?
    /// CSS pixels, when the value is a length in px or rem, or a plain number.
    public var number: Double?

    public init(name: String, raw: String, color: String? = nil, number: Double? = nil) {
        self.name = name
        self.raw = raw
        self.color = color
        self.number = number
    }
}

/// What a page looked like in one appearance: its visible DOM and its design tokens.
/// Captured by the editor, never stored in the document, like layout.
public struct WebSnapshot: Hashable, Codable, Sendable {
    public var url: String
    public var title: String
    public var width: Double
    public var height: Double
    /// The page's background: the body's, else the root element's.
    public var background: String?
    public var root: WebElement
    public var variables: [WebVariable]

    public init(
        url: String, title: String, width: Double, height: Double, background: String? = nil, root: WebElement,
        variables: [WebVariable] = []
    ) {
        self.url = url
        self.title = title
        self.width = width
        self.height = height
        self.background = background
        self.root = root
        self.variables = variables
    }

    public static func decode(_ json: Data) throws -> WebSnapshot {
        try JSONDecoder().decode(WebSnapshot.self, from: json)
    }

    /// A DOM node's resolved ID: the screen's ID, a colon and the element path, so it is
    /// unique across the canvas, like `pricing:body>main>#cv`.
    public static func nodeID(screen: NodeID, path: String) -> String { "\(screen.rawValue):\(path)" }

    /// The screen with the page's elements as its children: what the layers panel,
    /// inspector, hit testing and agents read. Colors equal to a token's value in `mode`
    /// become that token, so a literal is one the design system doesn't have.
    public func tree(screen: ResolvedNode, tokens: TokenSet, mode: String) -> ResolvedNode {
        let palette = Self.palette(tokens, mode: mode)
        return ResolvedNode(
            id: screen.id, source: screen.source, instance: nil, kind: .screen, props: screen.props,
            children: [element(root, screen: screen.source, palette: palette)]
        )
    }

    /// Every element's frame by resolved ID, plus the screen's own.
    public func frames(screen: NodeID) -> [String: CGRect] {
        var frames = [screen.rawValue: CGRect(x: 0, y: 0, width: width, height: height)]
        func visit(_ element: WebElement) {
            frames[Self.nodeID(screen: screen, path: element.path)] = element.rect
            element.children?.forEach(visit)
        }
        visit(root)
        return frames
    }

    public var elementCount: Int {
        func count(_ element: WebElement) -> Int { 1 + (element.children ?? []).map(count).reduce(0, +) }
        return count(root)
    }

    /// Hex colors to tokens, preferring `web.` tokens, then the first ID.
    static func palette(_ tokens: TokenSet, mode: String) -> [String: TokenID] {
        var palette: [String: TokenID] = [:]
        for id in tokens.ids(of: .color).sorted(by: { ($0.rawValue.hasPrefix("web.") ? 0 : 1, $0) < ($1.rawValue.hasPrefix("web.") ? 0 : 1, $1) }) {
            guard case .color(let rgba) = try? tokens.resolve(id, mode: mode) else { continue }
            if palette[rgba.hex] == nil { palette[rgba.hex] = id }
        }
        return palette
    }

    private func element(_ element: WebElement, screen: NodeID, palette: [String: TokenID]) -> ResolvedNode {
        var props: [Prop: Value] = [.tag: .string(element.tag)]
        if let id = element.id, !id.isEmpty { props[.htmlID] = .string(id) }
        if let classes = element.classes, !classes.isEmpty { props[.classes] = .string(classes.joined(separator: " ")) }
        if let role = element.role, !role.isEmpty { props[.role] = .string(role) }
        if let label = element.label, !label.isEmpty { props[.ariaLabel] = .string(label) }
        if let text = element.text, !text.isEmpty { props[.text] = .string(text) }
        for (name, css) in element.styles ?? [:] {
            let prop = Prop(rawValue: name == "padding" ? Prop.cssPadding.rawValue : name)
            if prop.tokenKind == .color {
                guard let rgba = RGBA(css: css) else { continue }
                props[prop] = palette[rgba.hex].map(Value.token) ?? .color(rgba)
            } else if let number = Double(css) {
                props[prop] = .number(number)
            } else {
                props[prop] = .string(css)
            }
        }
        return ResolvedNode(
            id: Self.nodeID(screen: screen, path: element.path), source: screen, instance: nil, kind: .element,
            props: props, children: (element.children ?? []).map { self.element($0, screen: screen, palette: palette) }
        )
    }
}

// MARK: - CSS values

extension RGBA {
    /// A CSS color as browsers compute it: `rgb(1, 2, 3)`, `rgba(1, 2, 3, 0.5)`,
    /// `rgb(1 2 3 / 50%)`, `color(srgb 0.1 0.2 0.3 / 0.5)` or a hex color. Nil for
    /// anything else, such as `transparent` keywords other browsers keep.
    public init?(css: String) {
        let value = css.trimmingCharacters(in: .whitespaces).lowercased()
        if value.hasPrefix("#") {
            var digits = String(value.dropFirst())
            if digits.count == 3 || digits.count == 4 { digits = digits.map { "\($0)\($0)" }.joined() }
            guard let rgba = RGBA(hex: digits) else { return nil }
            self = rgba
            return
        }
        if value == "transparent" {
            self.init(red: 0, green: 0, blue: 0, alpha: 0)
            return
        }
        guard let open = value.firstIndex(of: "("), value.hasSuffix(")") else { return nil }
        let function = value[..<open]
        let inner = value[value.index(after: open)..<value.index(before: value.endIndex)]
        let parts = inner.replacingOccurrences(of: ",", with: " ").replacingOccurrences(of: "/", with: " ")
            .split(separator: " ").map(String.init)
        func component(_ text: String, scale: Double) -> Double? {
            if text.hasSuffix("%") { return Double(text.dropLast()).map { $0 / 100 } }
            return Double(text).map { $0 / scale }
        }
        let channels: [Double]
        switch function {
        case "rgb", "rgba":
            guard parts.count >= 3, let r = component(parts[0], scale: 255), let g = component(parts[1], scale: 255),
                let b = component(parts[2], scale: 255)
            else { return nil }
            channels = [r, g, b, parts.count > 3 ? component(parts[3], scale: 1) ?? 1 : 1]
        case "color":
            guard parts.count >= 4, parts[0] == "srgb", let r = component(parts[1], scale: 1),
                let g = component(parts[2], scale: 1), let b = component(parts[3], scale: 1)
            else { return nil }
            channels = [r, g, b, parts.count > 4 ? component(parts[4], scale: 1) ?? 1 : 1]
        default:
            return nil
        }
        // Channels are stored rounded to 8 bits, like the hex the file writes, so equal
        // colors compare equal.
        let round = channels.map { (min(max($0, 0), 1) * 255).rounded() / 255 }
        self.init(red: round[0], green: round[1], blue: round[2], alpha: round[3])
    }
}

// MARK: - Tokens from CSS

public enum WebTokens {
    /// A token ID for a custom property: `--ink` is `web.ink`, `--glass-2` `web.glass.2`.
    public static func tokenID(for name: String, prefix: String = "web") -> TokenID {
        let parts = name.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init).filter { !$0.isEmpty }
        return TokenID(rawValue: ([prefix] + parts).joined(separator: "."))
    }

    /// The edit that writes a page's custom properties as tokens: colors as colors,
    /// lengths and numbers as numbers, with a light and a dark value each. Other values
    /// (fonts, easings, shadows) are skipped. One batch, so it undoes as one step.
    public static func importEdit(
        dark: [WebVariable], light: [WebVariable], into tokens: TokenSet, prefix: String = "web"
    ) -> (edit: Edit, imported: [TokenID], skipped: [String]) {
        let lightByName = Dictionary(light.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var edits: [Edit] = []
        var imported: [TokenID] = []
        var skipped: [String] = []
        var seen: Set<String> = []
        for variable in dark + light where seen.insert(variable.name).inserted {
            let darkValue = dark.first { $0.name == variable.name } ?? variable
            let lightValue = lightByName[variable.name] ?? darkValue
            guard let darkToken = tokenValue(darkValue), let lightToken = tokenValue(lightValue),
                darkToken.kind == lightToken.kind
            else {
                skipped.append(variable.name)
                continue
            }
            let id = tokenID(for: variable.name, prefix: prefix)
            let token = Token(id, modes: [TokenSet.defaultMode: lightToken, "dark": darkToken])
            if tokens.tokens[id] != token { edits.append(.token(id, token)) }
            imported.append(id)
        }
        return (.batch(edits), imported.sorted(), skipped.sorted())
    }

    static func tokenValue(_ variable: WebVariable) -> TokenValue? {
        if let css = variable.color, let rgba = RGBA(css: css) { return .color(rgba) }
        if let number = variable.number { return .number(number) }
        return nil
    }
}
