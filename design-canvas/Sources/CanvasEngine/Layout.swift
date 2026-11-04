import CanvasCore
import CoreGraphics

/// Lays out a resolved node tree the way SwiftUI would on iOS and emits what to draw.
///
/// Stacks follow SwiftUI's algorithm: children are offered space in order of how
/// flexible they are, so fixed views get their size and spacers take the rest.
/// Modifiers apply in the document's fixed order (font, foreground, padding, frame,
/// background, corner radius, opacity). System components (navigation stack, inset
/// grouped list, toggle, button) use `AppleMetrics`.
public struct LayoutEngine: Sendable {
    public let tokens: TokenSet
    public let appearance: Appearance

    public init(tokens: TokenSet, appearance: Appearance) {
        self.tokens = tokens
        self.appearance = appearance
    }

    /// A screen at its device's size, with the status bar.
    public func screen(_ root: ResolvedNode, device: DeviceSpec) -> LayoutResult {
        let pass = Pass(engine: self, device: device)
        let rect = CGRect(origin: .zero, size: device.size)
        let grouped = root.first { $0.kind == .list && ($0[.style]?.string ?? "insetGrouped") != "plain" } != nil
        var ops: [DrawOp] = []
        pass.place(root, in: rect, env: pass.rootEnvironment, ops: &ops)
        ops += pass.statusBar()
        return LayoutResult(
            size: device.size,
            background: system(grouped ? "systemGroupedBackground" : "systemBackground"),
            cornerRadius: device.cornerRadius,
            ops: ops,
            frames: pass.frames,
            rows: pass.rows
        )
    }

    /// A component on its own, on a card like a list row.
    public func component(_ root: ResolvedNode, width: CGFloat = 360) -> LayoutResult {
        let pass = Pass(engine: self, device: nil)
        let padding = CGSize(width: AppleMetrics.cellPadding, height: 11)
        let size = pass.size(root, Proposal(width: width - 2 * padding.width, height: nil), env: pass.rootEnvironment)
        let height = max(size.height + 2 * padding.height, 44)
        var ops: [DrawOp] = []
        let rect = CGRect(x: padding.width, y: (height - size.height) / 2, width: size.width, height: size.height)
        pass.place(root, in: rect, env: pass.rootEnvironment, ops: &ops)
        return LayoutResult(
            size: CGSize(width: width, height: height),
            background: system("secondarySystemGroupedBackground"),
            cornerRadius: 10,
            ops: ops,
            frames: pass.frames,
            rows: pass.rows
        )
    }

    /// A frame limit: a number, or `infinity` for `.frame(maxWidth: .infinity)`.
    public func limit(_ value: Value?) -> CGFloat? {
        if value?.string == "infinity" { return .infinity }
        return number(value)
    }

    func system(_ name: String) -> RGBA {
        AppleColors.color(name, appearance) ?? RGBA(red: 1, green: 0, blue: 1)
    }

    // MARK: - Values

    public func number(_ value: Value?) -> CGFloat? {
        switch value {
        case .number(let number): CGFloat(number)
        case .token(let id):
            if case .number(let number) = try? tokens.resolve(id, mode: appearance.mode) { CGFloat(number) } else { nil }
        default: nil
        }
    }

    public func color(_ value: Value?) -> RGBA? {
        switch value {
        case .color(let rgba): rgba
        case .string(let name): AppleColors.color(name, appearance)
        case .token(let id):
            switch try? tokens.resolve(id, mode: appearance.mode) {
            case .color(let rgba): rgba
            case .system(let name): AppleColors.color(name, appearance)
            default: nil
            }
        default: nil
        }
    }

    public func textStyle(_ value: Value?) -> String? {
        switch value {
        case .string(let name): AppleType.styles[name] == nil ? nil : name
        case .token(let id):
            if case .textStyle(let name, _) = try? tokens.resolve(id, mode: appearance.mode) { name } else { nil }
        default: nil
        }
    }

    /// The system font design a font value asks for, such as `serif`; nil for the default design.
    public func fontDesign(_ value: Value?) -> String? {
        guard case .token(let id) = value, case .textStyle(_, let design) = try? tokens.resolve(id, mode: appearance.mode)
        else { return nil }
        return design
    }
}

struct Proposal {
    var width: CGFloat?
    var height: CGFloat?

    static let unspecified = Proposal(width: nil, height: nil)
    /// Stands in for an infinite proposal when measuring how far a view can grow.
    static let huge: CGFloat = 100_000
}

/// Inherited values, like SwiftUI's environment.
struct Environment {
    var style = "body"
    /// A fixed point size, from `.font(.system(size:))`; overrides the style's size.
    var size: CGFloat?
    /// The system font design, like `.fontDesign(.serif)`; nil for SF Pro.
    var design: String?
    var textAlignment: TextSpec.TextAlignment = .leading
    var weight: CGFloat?
    var foreground: RGBA
    var tint: RGBA
    var inList = false
}

/// One layout pass: sizes are cached per node and proposal, frames collected on placement.
final class Pass {
    let engine: LayoutEngine
    let device: DeviceSpec?
    private(set) var frames: [String: CGRect] = [:]
    private(set) var rows: [String: CGRect] = [:]
    private var sizes: [SizeKey: CGSize] = [:]

    private struct SizeKey: Hashable {
        let node: String
        let width: CGFloat?
        let height: CGFloat?
        let style: String
        let fontSize: CGFloat?
        let design: String?
        let weight: CGFloat?
        let inList: Bool
    }

    init(engine: LayoutEngine, device: DeviceSpec?) {
        self.engine = engine
        self.device = device
    }

    var rootEnvironment: Environment {
        Environment(foreground: engine.system("label"), tint: engine.system("systemBlue"))
    }

    // MARK: - Modifiers

    private func modified(_ env: Environment, _ node: ResolvedNode) -> Environment {
        var env = env
        if let style = engine.textStyle(node[.font]) {
            env.style = style
            env.size = nil
            env.design = engine.fontDesign(node[.font])
            env.weight = nil
        } else if let size = engine.number(node[.font]) {
            env.size = size
            env.design = nil
            env.weight = nil
        }
        switch node[.multilineTextAlignment]?.string {
        case "center": env.textAlignment = .center
        case "trailing": env.textAlignment = .trailing
        case "leading": env.textAlignment = .leading
        default: break
        }
        if let weight = node[.weight]?.string.flatMap({ AppleType.weights[$0] }) { env.weight = weight }
        if let color = engine.color(node[.foreground]) { env.foreground = color }
        return env
    }

    /// Padding per axis: `padding` on all sides, overridden by `paddingHorizontal` and `paddingVertical`.
    private func padding(_ node: ResolvedNode) -> CGSize {
        let all = engine.number(node[.padding]) ?? 0
        return CGSize(width: engine.number(node[.paddingHorizontal]) ?? all, height: engine.number(node[.paddingVertical]) ?? all)
    }

    func size(_ node: ResolvedNode, _ proposal: Proposal, env: Environment) -> CGSize {
        let key = SizeKey(
            node: node.id, width: proposal.width, height: proposal.height, style: env.style, fontSize: env.size,
            design: env.design, weight: env.weight, inList: env.inList
        )
        if let size = sizes[key] { return size }
        let env = modified(env, node)
        let padding = padding(node)
        let width = engine.number(node[.width])
        let height = engine.number(node[.height])
        let maxWidth = engine.limit(node[.maxWidth])
        let maxHeight = engine.limit(node[.maxHeight])
        // What the frame offers its content: a fixed size, or the proposal capped at the maximum.
        func offer(_ fixed: CGFloat?, _ limit: CGFloat?, _ proposed: CGFloat?) -> CGFloat? {
            fixed ?? limit.flatMap { limit in proposed.map { min($0, limit) } } ?? proposed
        }
        let inner = Proposal(
            width: offer(width, maxWidth, proposal.width).map { max($0 - 2 * padding.width, 0) },
            height: offer(height, maxHeight, proposal.height).map { max($0 - 2 * padding.height, 0) }
        )
        let content = contentSize(node, inner, env: env)
        // A flexible frame takes the proposal, up to its maximum, but never less than its content.
        func resolve(_ fixed: CGFloat?, _ limit: CGFloat?, _ proposed: CGFloat?, _ content: CGFloat) -> CGFloat {
            if let fixed { return fixed }
            guard let limit else { return content }
            return min(limit, max(content, proposed ?? content))
        }
        let size = CGSize(
            width: resolve(width, maxWidth, proposal.width, content.width + 2 * padding.width),
            height: resolve(height, maxHeight, proposal.height, content.height + 2 * padding.height)
        )
        sizes[key] = size
        return size
    }

    func place(_ node: ResolvedNode, in rect: CGRect, env: Environment, ops: inout [DrawOp]) {
        let env = modified(env, node)
        if node.kind != .section { frames[node.id] = rect }
        let padding = padding(node)
        let area = rect.insetBy(dx: padding.width, dy: padding.height)
        // A frame larger than the content centers it unless aligned, like SwiftUI's `frame`.
        let content = contentSize(node, Proposal(width: area.width, height: area.height), env: env)
        let contentRect = aligned(content, in: area, node[.frameAlignment]?.string)
        var inner: [DrawOp] = []
        placeContent(node, in: contentRect, env: env, ops: &inner)

        let radius = node.kind == .rectangle ? 0 : engine.number(node[.cornerRadius]) ?? 0
        var result: [DrawOp] = []
        if let background = engine.color(node[.background]) {
            result.append(.fill(rect, radius: radius, color: background))
        }
        result.append(contentsOf: radius > 0 ? [.group(clip: rect, radius: radius, opacity: 1, ops: inner)] : inner)
        if let border = engine.color(node[.border]) {
            let shapeRadius = node.kind == .rectangle ? engine.number(node[.cornerRadius]) ?? 0 : radius
            result.append(.stroke(rect, radius: shapeRadius, width: engine.number(node[.borderWidth]) ?? 1, color: border))
        }
        if let shadow = engine.number(node[.shadowRadius]), shadow > 0 {
            // SwiftUI's default shadow color is black at a third opacity.
            let color = engine.color(node[.shadowColor]) ?? RGBA(red: 0, green: 0, blue: 0, alpha: 0.33)
            result = [.shadow(radius: shadow, y: engine.number(node[.shadowY]) ?? 0, color: color, ops: result)]
        }
        if let opacity = engine.number(node[.opacity]), opacity < 1 {
            result = [.group(clip: nil, radius: 0, opacity: opacity, ops: result)]
        }
        ops.append(contentsOf: result)
    }

    /// Places `size` in `area` by a SwiftUI alignment name such as `topLeading`; centered by default.
    private func aligned(_ size: CGSize, in area: CGRect, _ alignment: String?) -> CGRect {
        let name = (alignment ?? "center").lowercased()
        let x: CGFloat = name.hasSuffix("leading") ? 0 : name.hasSuffix("trailing") ? 1 : 0.5
        let y: CGFloat = name.hasPrefix("top") ? 0 : name.hasPrefix("bottom") ? 1 : 0.5
        return CGRect(
            x: area.minX + (area.width - size.width) * x, y: area.minY + (area.height - size.height) * y,
            width: size.width, height: size.height
        )
    }

    // MARK: - Content

    private func contentSize(_ node: ResolvedNode, _ proposal: Proposal, env: Environment) -> CGSize {
        switch node.kind {
        case .page, .component, .instance, .section:
            return .zero
        case .screen, .navigationStack:
            return CGSize(width: proposal.width ?? device?.size.width ?? 0, height: proposal.height ?? device?.size.height ?? 0)
        case .list:
            let width = proposal.width ?? device?.size.width ?? 402
            return CGSize(width: width, height: proposal.height ?? listHeight(node, width: width, env: env))
        case .text:
            return TextEngine.measure(textSpec(node[.text]?.string ?? "", env), maxWidth: proposal.width)
        case .image:
            return Symbols.size(symbolSpec(node, env))
        case .label:
            let icon = Symbols.size(symbolSpec(node, env))
            let text = TextEngine.measure(textSpec(node[.title]?.string ?? "", env), maxWidth: proposal.width.map { $0 - icon.width - AppleMetrics.labelSpacing })
            return CGSize(width: icon.width + AppleMetrics.labelSpacing + text.width, height: max(icon.height, text.height))
        case .rectangle:
            return CGSize(width: proposal.width ?? 10, height: proposal.height ?? 10)
        case .spacer:
            return CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
        case .hstack, .vstack:
            let axis: Axis = node.kind == .hstack ? .horizontal : .vertical
            let sizes = stackSizes(node, axis: axis, proposal, env: env)
            return stackSize(sizes, axis: axis, spacing: spacing(node))
        case .zstack:
            return node.children.reduce(CGSize.zero) { result, child in
                let size = size(child, proposal, env: env)
                return CGSize(width: max(result.width, size.width), height: max(result.height, size.height))
            }
        case .scroll:
            let sizes = stackSizes(node, axis: .vertical, Proposal(width: proposal.width, height: nil), env: env)
            let content = stackSize(sizes, axis: .vertical, spacing: spacing(node))
            return CGSize(width: proposal.width ?? content.width, height: proposal.height ?? content.height)
        case .toggle:
            let label = TextEngine.measure(textSpec(node[.title]?.string ?? "", env), maxWidth: nil)
            let minimum = label.width + AppleMetrics.labelSpacing + AppleMetrics.switchSize.width
            return CGSize(width: max(proposal.width ?? minimum, minimum), height: label.height)
        case .button:
            let text = TextEngine.measure(textSpec(node[.title]?.string ?? "Button", env), maxWidth: proposal.width)
            guard !env.inList, let style = node[.style]?.string, style.hasPrefix("bordered") else { return text }
            return CGSize(width: text.width + 28, height: text.height + 14)
        }
    }

    private func placeContent(_ node: ResolvedNode, in rect: CGRect, env: Environment, ops: inout [DrawOp]) {
        switch node.kind {
        case .page, .component, .instance, .section, .spacer:
            return
        case .screen:
            // Content sits in the safe area; a navigation stack handles the safe area itself.
            var area = rect
            if let device, node.children.first?.kind != .navigationStack {
                area = CGRect(x: rect.minX, y: rect.minY + device.safeTop, width: rect.width, height: rect.height - device.safeTop - device.safeBottom)
            }
            placeStack(node, axis: .vertical, in: area, env: env, spacing: 0, ops: &ops)
        case .navigationStack:
            placeNavigation(node, in: rect, env: env, ops: &ops)
        case .list:
            placeList(node, in: rect, env: env, ops: &ops)
        case .text:
            ops.append(.text(textSpec(node[.text]?.string ?? "", env), rect: rect))
        case .image:
            ops.append(.symbol(symbolSpec(node, env), rect: rect))
        case .label:
            let icon = Symbols.size(symbolSpec(node, env))
            ops.append(.symbol(symbolSpec(node, env), rect: CGRect(x: rect.minX, y: rect.midY - icon.height / 2, width: icon.width, height: icon.height)))
            let x = rect.minX + icon.width + AppleMetrics.labelSpacing
            ops.append(.text(textSpec(node[.title]?.string ?? "", env), rect: CGRect(x: x, y: rect.minY, width: rect.maxX - x, height: rect.height)))
        case .rectangle:
            let color = engine.color(node[.fill]) ?? env.foreground
            ops.append(.fill(rect, radius: engine.number(node[.cornerRadius]) ?? 0, color: color))
        case .hstack, .vstack:
            placeStack(node, axis: node.kind == .hstack ? .horizontal : .vertical, in: rect, env: env, spacing: spacing(node), ops: &ops)
        case .zstack:
            for child in node.children {
                let size = size(child, Proposal(width: rect.width, height: rect.height), env: env)
                place(child, in: aligned(size, in: rect, node[.alignment]?.string), env: env, ops: &ops)
            }
        case .scroll:
            // Content gets its ideal height and is clipped to the scroll view.
            var content: [DrawOp] = []
            placeStack(node, axis: .vertical, in: rect, env: env, spacing: spacing(node), scrolls: true, ops: &content)
            // A scroll view ending at the bottom safe area scrolls on under the home indicator.
            var clip = rect
            if let device, abs(rect.maxY - (device.size.height - device.safeBottom)) < 0.5 {
                clip.size.height += device.safeBottom
            }
            ops.append(.group(clip: clip, radius: 0, opacity: 1, ops: content))
        case .toggle:
            placeToggle(node, in: rect, env: env, ops: &ops)
        case .button:
            placeButton(node, in: rect, env: env, ops: &ops)
        }
    }

    // MARK: - Stacks

    enum Axis { case horizontal, vertical }

    private func spacing(_ node: ResolvedNode) -> CGFloat {
        engine.number(node[.spacing]) ?? AppleMetrics.defaultStackSpacing
    }

    private func along(_ size: CGSize, _ axis: Axis) -> CGFloat { axis == .horizontal ? size.width : size.height }
    private func across(_ size: CGSize, _ axis: Axis) -> CGFloat { axis == .horizontal ? size.height : size.width }

    private func proposal(along: CGFloat?, across: CGFloat?, _ axis: Axis) -> Proposal {
        axis == .horizontal ? Proposal(width: along, height: across) : Proposal(width: across, height: along)
    }

    /// SwiftUI's stack layout: the least flexible child is offered its share first.
    /// Spacers only take what the other children leave, never less than their minimum
    /// length, so a text next to a spacer gets the whole row before it wraps.
    private func stackSizes(_ node: ResolvedNode, axis: Axis, _ offer: Proposal, env: Environment, spacing override: CGFloat? = nil) -> [CGSize] {
        let children = node.children
        guard !children.isEmpty else { return [] }
        let spacing = override ?? spacing(node)
        let alongOffer = axis == .horizontal ? offer.width : offer.height
        let acrossOffer = axis == .horizontal ? offer.height : offer.width

        let minimum = AppleMetrics.spacerMinLength
        func spacer(_ length: CGFloat) -> CGSize {
            axis == .horizontal ? CGSize(width: length, height: 0) : CGSize(width: 0, height: length)
        }
        guard let alongOffer else {
            return children.map { child in
                child.kind == .spacer ? spacer(minimum) : size(child, proposal(along: nil, across: acrossOffer, axis), env: env)
            }
        }
        let spacers = children.indices.filter { children[$0].kind == .spacer }
        let views = children.indices.filter { children[$0].kind != .spacer }
        let flexibility: [Int: CGFloat] = Dictionary(uniqueKeysWithValues: views.map { index in
            let child = children[index]
            let smallest = along(size(child, proposal(along: 0, across: acrossOffer, axis), env: env), axis)
            let largest = along(size(child, proposal(along: Proposal.huge, across: acrossOffer, axis), env: env), axis)
            return (index, largest - smallest)
        })
        var sizes = [CGSize](repeating: .zero, count: children.count)
        let reserved = minimum * CGFloat(spacers.count)
        var remaining = alongOffer - spacing * CGFloat(children.count - 1) - reserved
        var left = views.count
        for index in views.sorted(by: { flexibility[$0]! < flexibility[$1]! }) {
            let share = max(remaining / CGFloat(left), 0)
            sizes[index] = size(children[index], proposal(along: share, across: acrossOffer, axis), env: env)
            remaining -= along(sizes[index], axis)
            left -= 1
        }
        if !spacers.isEmpty {
            let length = max((remaining + reserved) / CGFloat(spacers.count), minimum)
            for index in spacers { sizes[index] = spacer(length) }
        }
        return sizes
    }

    private func stackSize(_ sizes: [CGSize], axis: Axis, spacing: CGFloat) -> CGSize {
        guard !sizes.isEmpty else { return .zero }
        let total = sizes.reduce(0) { $0 + along($1, axis) } + spacing * CGFloat(sizes.count - 1)
        let cross = sizes.map { across($0, axis) }.max() ?? 0
        return axis == .horizontal ? CGSize(width: total, height: cross) : CGSize(width: cross, height: total)
    }

    private func placeStack(_ node: ResolvedNode, axis: Axis, in rect: CGRect, env: Environment, spacing: CGFloat, scrolls: Bool = false, ops: inout [DrawOp]) {
        let offer = Proposal(width: rect.width, height: scrolls ? nil : rect.height)
        let sizes = stackSizes(node, axis: axis, offer, env: env, spacing: spacing)
        var cursor = axis == .horizontal ? rect.minX : rect.minY
        let alignment = node[.alignment]?.string
        for (child, size) in zip(node.children, sizes) {
            let frame: CGRect
            if axis == .horizontal {
                let y: CGFloat = switch alignment {
                case "top": rect.minY
                case "bottom": rect.maxY - size.height
                default: rect.midY - size.height / 2
                }
                frame = CGRect(x: cursor, y: y, width: size.width, height: child.kind == .spacer ? rect.height : size.height)
                cursor += size.width + spacing
            } else {
                let x: CGFloat = switch alignment {
                case "leading": rect.minX
                case "trailing": rect.maxX - size.width
                default: rect.midX - size.width / 2
                }
                frame = CGRect(x: x, y: cursor, width: child.kind == .spacer ? rect.width : size.width, height: size.height)
                cursor += size.height + spacing
            }
            place(child, in: frame, env: env, ops: &ops)
        }
    }

    // MARK: - Navigation

    private func placeNavigation(_ node: ResolvedNode, in rect: CGRect, env: Environment, ops: inout [DrawOp]) {
        let safeTop = device?.safeTop ?? 0
        let title = node[.title]?.string ?? ""
        if !title.isEmpty {
            let metrics = AppleType.styles["largeTitle"]!
            let spec = TextSpec(
                string: title, size: metrics.size, weight: AppleType.weights["bold"]!, color: engine.system("label"),
                lineHeight: metrics.lineHeight, ascender: metrics.ascender
            )
            let size = TextEngine.measure(spec, maxWidth: rect.width - 32)
            let top = rect.minY + safeTop + AppleMetrics.largeTitleBaseline - metrics.ascender
            ops.append(.text(spec, rect: CGRect(x: rect.minX + 16, y: top, width: size.width, height: size.height)))
        }
        let contentTop = safeTop + (title.isEmpty ? AppleMetrics.inlineContentTop : AppleMetrics.largeTitleContentTop)
        let content = CGRect(x: rect.minX, y: rect.minY + contentTop, width: rect.width, height: rect.height - contentTop)
        // Content that doesn't fill the space centers in it, as in a NavigationStack.
        let sizes = stackSizes(node, axis: .vertical, Proposal(width: content.width, height: content.height), env: env, spacing: 0)
        let total = stackSize(sizes, axis: .vertical, spacing: 0)
        let stack = CGRect(x: content.minX, y: content.minY + max((content.height - total.height) / 2, 0), width: content.width, height: total.height)
        placeStack(node, axis: .vertical, in: stack, env: env, spacing: 0, ops: &ops)
    }

    // MARK: - Lists

    private struct ListSection {
        var header: String?
        var rows: [ResolvedNode]
    }

    private func sections(of list: ResolvedNode) -> [ListSection] {
        var sections: [ListSection] = []
        var loose: [ResolvedNode] = []
        for child in list.children {
            if child.kind == .section {
                if !loose.isEmpty { sections.append(ListSection(header: nil, rows: loose)); loose = [] }
                sections.append(ListSection(header: child[.title]?.string, rows: child.children))
            } else {
                loose.append(child)
            }
        }
        if !loose.isEmpty { sections.append(ListSection(header: nil, rows: loose)) }
        return sections
    }

    private func listHeight(_ list: ResolvedNode, width: CGFloat, env: Environment) -> CGFloat {
        var ops: [DrawOp] = []
        return layoutList(list, in: CGRect(x: 0, y: 0, width: width, height: 0), env: env, ops: &ops, emit: false)
    }

    private func placeList(_ list: ResolvedNode, in rect: CGRect, env: Environment, ops: inout [DrawOp]) {
        let plain = list[.style]?.string == "plain"
        ops.append(.fill(rect, radius: 0, color: engine.system(plain ? "systemBackground" : "systemGroupedBackground")))
        _ = layoutList(list, in: rect, env: env, ops: &ops, emit: true)
    }

    /// Lays out sections as inset grouped cards, or full-width rows for a plain list.
    /// Returns the content height.
    @discardableResult
    private func layoutList(_ list: ResolvedNode, in rect: CGRect, env: Environment, ops: inout [DrawOp], emit: Bool) -> CGFloat {
        let plain = list[.style]?.string == "plain"
        let margin = plain ? 0 : AppleMetrics.listMargin
        let card = CGRect(x: rect.minX + margin, y: 0, width: rect.width - 2 * margin, height: 0)
        let contentWidth = card.width - 2 * AppleMetrics.cellPadding
        var rowEnv = env
        rowEnv.inList = true
        var y = rect.minY

        for (index, section) in sections(of: list).enumerated() {
            if index > 0 { y += AppleMetrics.sectionSpacing }
            if let header = section.header, !header.isEmpty {
                y += index == 0 ? 12 + AppleMetrics.headerHeight : AppleMetrics.headerHeight
                if emit {
                    let metrics = AppleType.styles["headline"]!
                    let spec = TextSpec(
                        string: header, size: metrics.size, weight: metrics.weight, color: engine.system("secondaryLabel"),
                        lineHeight: metrics.lineHeight, ascender: metrics.ascender
                    )
                    let top = y - AppleMetrics.headerBaselineToCard - metrics.ascender
                    let size = TextEngine.measure(spec, maxWidth: contentWidth)
                    ops.append(.text(spec, rect: CGRect(x: card.minX + AppleMetrics.cellPadding, y: top, width: size.width, height: size.height)))
                }
            }
            let cardTop = y
            var cells: [(row: ResolvedNode, rect: CGRect, content: CGRect)] = []
            for row in section.rows {
                let size = size(row, Proposal(width: contentWidth, height: nil), env: rowEnv)
                let height = max(AppleMetrics.minRowHeight, size.height + 2 * AppleMetrics.cellVerticalPadding)
                let cell = CGRect(x: card.minX, y: y, width: card.width, height: height)
                let content = CGRect(
                    x: card.minX + AppleMetrics.cellPadding, y: y + (height - size.height) / 2,
                    width: min(size.width, contentWidth), height: size.height
                )
                cells.append((row, cell, content))
                y += height
            }
            guard emit, !cells.isEmpty else { continue }
            let cardRect = CGRect(x: card.minX, y: cardTop, width: card.width, height: y - cardTop)
            ops.append(.fill(cardRect, radius: plain ? 0 : AppleMetrics.cardRadius, color: engine.system(plain ? "systemBackground" : "secondarySystemGroupedBackground")))
            for (offset, cell) in cells.enumerated() {
                rows[cell.row.id] = cell.rect
                place(cell.row, in: cell.content, env: rowEnv, ops: &ops)
                guard offset < cells.count - 1 else { continue }
                // Separators start under the row's text, like UIKit's layout margins.
                let leading = cell.row.first { $0.kind == .text || $0.kind == .toggle || $0.kind == .button || $0.kind == .label }
                    .flatMap { frames[$0.id]?.minX } ?? cell.content.minX
                let lineY = cell.rect.maxY - AppleMetrics.separatorWidth / 2
                ops.append(.line(
                    from: CGPoint(x: leading, y: lineY), to: CGPoint(x: cell.rect.maxX - AppleMetrics.cellPadding, y: lineY),
                    width: AppleMetrics.separatorWidth, color: engine.system("separator")
                ))
            }
        }
        return y - rect.minY + AppleMetrics.sectionSpacing
    }

    // MARK: - Controls

    private func placeToggle(_ node: ResolvedNode, in rect: CGRect, env: Environment, ops: inout [DrawOp]) {
        let spec = textSpec(node[.title]?.string ?? "", env)
        let label = TextEngine.measure(spec, maxWidth: rect.width - AppleMetrics.switchSize.width - AppleMetrics.labelSpacing)
        ops.append(.text(spec, rect: CGRect(x: rect.minX, y: rect.midY - label.height / 2, width: label.width, height: label.height)))
        // The switch pokes 2 pt past the row's trailing margin, as in UIKit.
        let track = CGRect(
            x: rect.maxX + 2 - AppleMetrics.switchSize.width, y: rect.midY - AppleMetrics.switchSize.height / 2,
            width: AppleMetrics.switchSize.width, height: AppleMetrics.switchSize.height
        )
        let isOn = node[.isOn]?.bool ?? false
        ops.append(.fill(track, radius: track.height / 2, color: engine.system(isOn ? "systemGreen" : "switchTrack")))
        let knob = AppleMetrics.switchKnob
        let inset = (track.height - knob.height) / 2
        let knobRect = CGRect(
            x: isOn ? track.maxX - inset - knob.width : track.minX + inset, y: track.minY + inset,
            width: knob.width, height: knob.height
        )
        ops.append(.fill(knobRect, radius: knob.height / 2, color: engine.system("white")))
    }

    private func placeButton(_ node: ResolvedNode, in rect: CGRect, env: Environment, ops: inout [DrawOp]) {
        let tint = engine.color(node[.foreground]) ?? env.tint
        let style = env.inList ? nil : node[.style]?.string
        var text = env
        text.foreground = style == "borderedProminent" ? engine.system("white") : tint
        let spec = textSpec(node[.title]?.string ?? "Button", text)
        switch style {
        case "bordered", "borderedProminent":
            let fill = style == "bordered" ? RGBA(red: tint.red, green: tint.green, blue: tint.blue, alpha: 0.15) : tint
            ops.append(.fill(rect, radius: rect.height / 2, color: fill))
            let size = TextEngine.measure(spec, maxWidth: rect.width - 28)
            ops.append(.text(spec, rect: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)))
        default:
            ops.append(.text(spec, rect: rect))
        }
    }

    // MARK: - Text and symbols

    private func metrics(_ env: Environment) -> TextStyleMetrics {
        env.size.map(AppleType.metrics(size:)) ?? AppleType.styles[env.style] ?? AppleType.styles["body"]!
    }

    func textSpec(_ string: String, _ env: Environment) -> TextSpec {
        let metrics = metrics(env)
        return TextSpec(
            string: string, size: metrics.size, weight: env.weight ?? metrics.weight, color: env.foreground,
            lineHeight: metrics.lineHeight, ascender: metrics.ascender, alignment: env.textAlignment, design: env.design
        )
    }

    private func symbolSpec(_ node: ResolvedNode, _ env: Environment) -> SymbolSpec {
        let metrics = metrics(env)
        return SymbolSpec(
            name: node[.symbol]?.string ?? "questionmark.square.dashed", pointSize: metrics.size,
            weight: env.weight ?? metrics.weight, color: env.foreground
        )
    }

    // MARK: - Status bar

    func statusBar() -> [DrawOp] {
        guard let device, device.safeTop > 40 else { return [] }
        let color = engine.system("label")
        let metrics = AppleType.styles["body"]!
        let time = TextSpec(
            string: "9:41", size: 17, weight: AppleType.weights["semibold"]!, color: color,
            lineHeight: metrics.lineHeight, ascender: metrics.ascender
        )
        let timeSize = TextEngine.measure(time, maxWidth: nil)
        let centerY: CGFloat = 31
        var ops: [DrawOp] = [
            .text(time, rect: CGRect(x: 55.3 - timeSize.width / 2, y: 37.1 - metrics.ascender, width: timeSize.width, height: timeSize.height)),
        ]
        // Right edges and sizes measured from iOS's status bar, from the screen's trailing edge.
        let icons: [(name: String, pointSize: CGFloat, trailing: CGFloat)] = [
            ("battery.100percent", 14.5, 12.9), ("wifi", 15, 46.33), ("cellularbars", 15, 72),
        ]
        for icon in icons {
            let spec = SymbolSpec(name: icon.name, pointSize: icon.pointSize, weight: AppleType.weights["semibold"]!, color: color)
            let size = Symbols.size(spec)
            let x = device.size.width - icon.trailing - size.width
            ops.append(.symbol(spec, rect: CGRect(x: x, y: centerY - size.height / 2, width: size.width, height: size.height)))
        }
        if let island = device.island {
            ops.append(.fill(island, radius: island.height / 2, color: engine.system("black")))
        }
        return ops
    }
}
