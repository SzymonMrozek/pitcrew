import CanvasCore
import SwiftUI

/// Figma's left panel: the pages, then the layer tree of the page on the canvas, every
/// screen and component with its views, instances expanded. Selection and hover are
/// shared with the canvas.
struct LayersView: View {
    let store: EditorStore
    /// The page being renamed, and its name so far.
    @State private var renaming: CanvasPage?
    @State private var name = ""
    @FocusState private var isNaming: Bool
    /// Rows the designer opened or closed, keyed by item and node. System containers
    /// start open, everything else closed; the selection's ancestors always open.
    @State private var opened: Set<String> = []
    @State private var closed: Set<String> = []

    private struct Row: Identifiable {
        let item: String
        let node: ResolvedNode
        let depth: Int
        let insideInstance: Bool
        var id: String { "\(item)|\(node.id)" }
    }

    private struct Root: Identifiable {
        let item: String
        let title: String
        let isComponent: Bool
        let tree: ResolvedNode
        var id: String { item }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    pages
                    Divider().padding(.vertical, 6)
                    if store.isOnTokens {
                        Text("Token boards are drawn from the document's tokens. Edit tokens in the file or through MCP.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                    }
                    ForEach(roots) { root in
                        HStack(spacing: 6) {
                            Image(systemName: root.isComponent ? "diamond" : "iphone")
                                .foregroundStyle(root.isComponent ? Color.purple : Color.secondary)
                            Text(root.title).font(.subheadline.weight(.semibold))
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 14)
                        .padding(.bottom, 4)
                        ForEach(rows(of: root)) { row in
                            rowView(row).id(row.id)
                        }
                    }
                }
                .padding(.bottom, 20)
            }
            .onChange(of: store.selection) {
                guard let selection = store.selection, let key = revealSelection(selection) else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(key, anchor: .center) }
            }
        }
        .background(Color(uiColor: .secondarySystemBackground))
    }

    // MARK: - Pages

    private var pages: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Pages").font(.subheadline.weight(.semibold))
                Spacer()
                Button("Add Page", systemImage: "plus") { store.addPage() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
            ForEach(store.pageList, id: \.page) { entry in
                pageRow(entry.page, name: entry.name)
            }
        }
    }

    /// A button, so the page list works with the keyboard and accessibility too. Double
    /// click or the context menu renames a page.
    private func pageRow(_ page: CanvasPage, name pageName: String) -> some View {
        Button {
            store.page = page
        } label: {
            pageLabel(page, name: pageName)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded { startRenaming(page, name: pageName) })
        .contextMenu {
            if case .document = page {
                Button("Rename", systemImage: "pencil") { startRenaming(page, name: pageName) }
            }
        }
    }

    private func pageLabel(_ page: CanvasPage, name pageName: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: page == .tokens ? "swatchpalette" : "doc")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            if renaming == page, case .document(let id) = page {
                TextField("Page name", text: $name)
                    .font(.callout)
                    .focused($isNaming)
                    .onSubmit { finishRenaming(id) }
                    .onChange(of: isNaming) { if !isNaming { finishRenaming(id) } }
            } else {
                Text(pageName).font(.callout).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(store.page == page ? Color.accentColor.opacity(0.22) : .clear)
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
    }

    /// Tokens is drawn from the tokens, so only document pages take a name.
    private func startRenaming(_ page: CanvasPage, name pageName: String) {
        guard case .document = page else { return }
        name = pageName
        renaming = page
        isNaming = true
    }

    private func finishRenaming(_ id: NodeID) {
        guard renaming == .document(id) else { return }
        renaming = nil
        store.renamePage(id, to: name)
    }

    // MARK: - Tree

    /// The page's screens and components, each in the copy shown: the selected one if
    /// there are two, else light.
    private var roots: [Root] {
        guard case .document(let page) = store.page else { return [] }
        return store.document.items(onPage: page).compactMap { node in
            let ids = node.kind == .screen ? ["\(node.id)#light", "\(node.id)#dark"] : [node.id.rawValue, "\(node.id)#dark"]
            let shown = store.items.filter { ids.contains($0.id) }
            guard let item = shown.first(where: { $0.id == store.selection?.item }) ?? shown.first else { return nil }
            switch node.kind {
            case .screen:
                return Root(item: item.id, title: node[.name]?.string ?? node.id.rawValue, isComponent: false, tree: item.tree)
            case .component:
                return Root(item: item.id, title: store.name(ofComponent: node.id), isComponent: true, tree: item.tree)
            default:
                return nil
            }
        }
    }

    private func rows(of root: Root) -> [Row] {
        var rows: [Row] = []
        func visit(_ node: ResolvedNode, depth: Int, insideInstance: Bool) {
            let row = Row(item: root.item, node: node, depth: depth, insideInstance: insideInstance)
            rows.append(row)
            guard isOpen(row) else { return }
            let isInstance = node.instance == node.source && node.instance != nil
            for child in node.children {
                visit(child, depth: depth + 1, insideInstance: insideInstance || isInstance)
            }
        }
        visit(root.tree, depth: 0, insideInstance: false)
        return rows
    }

    private static let openByDefault: Set<Node.Kind> = [.screen, .navigationStack, .list, .section, .scroll]

    private func isOpen(_ row: Row) -> Bool {
        if opened.contains(row.id) { return true }
        if closed.contains(row.id) { return false }
        return row.depth == 0 || Self.openByDefault.contains(row.node.kind)
    }

    /// Opens the selection's ancestors and returns its row key.
    private func revealSelection(_ selection: Selection) -> String? {
        guard let root = roots.first(where: { $0.item == selection.item }),
            let path = root.tree.path(to: selection.node)
        else { return nil }
        for ancestor in path.dropLast() {
            let key = "\(root.item)|\(ancestor.id)"
            closed.remove(key)
            opened.insert(key)
        }
        return "\(root.item)|\(selection.node)"
    }

    // MARK: - Row

    private func rowView(_ row: Row) -> some View {
        let selection = Selection(item: row.item, node: row.node.id)
        let isSelected = store.selection == selection
        let isHovered = store.hovered == selection
        let isInstance = row.node.instance == row.node.source && row.node.instance != nil
        return HStack(spacing: 4) {
            Color.clear.frame(width: CGFloat(row.depth) * 14, height: 1)
            if row.node.children.isEmpty {
                Color.clear.frame(width: 16, height: 1)
            } else {
                Button {
                    if isOpen(row) {
                        opened.remove(row.id)
                        closed.insert(row.id)
                    } else {
                        closed.remove(row.id)
                        opened.insert(row.id)
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(isOpen(row) ? 90 : 0))
                        .frame(width: 16, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            Image(systemName: isInstance ? "diamond" : row.node.kind.symbol)
                .font(.caption)
                .foregroundStyle(isInstance || row.insideInstance ? Color.purple : Color.secondary)
                .frame(width: 18)
            Text(store.displayName(of: row.node).replacingOccurrences(of: "◇ ", with: ""))
                .font(.callout)
                .lineLimit(1)
                .foregroundStyle(row.insideInstance ? Color.secondary : Color.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor.opacity(0.22) : isHovered ? Color.primary.opacity(0.07) : .clear)
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onTapGesture { store.select(selection) }
        .onHover { inside in
            if inside { store.hovered = selection } else if store.hovered == selection { store.hovered = nil }
        }
    }
}
