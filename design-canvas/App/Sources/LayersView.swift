import CanvasCore
import SwiftUI

/// The layer tree, like Figma's left panel: every screen and component with its views,
/// instances expanded. Selection and hover are shared with the canvas.
struct LayersView: View {
    let store: EditorStore
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

    // MARK: - Tree

    /// Screens use their light copy, unless the selection is on the dark one.
    private var roots: [Root] {
        store.document.children(of: CanvasDocument.rootID).compactMap { node in
            switch node.kind {
            case .screen:
                let light = "\(node.id)#light"
                let selected = store.selection?.item
                let item = selected?.hasPrefix("\(node.id)#") == true ? selected! : light
                guard let tree = store.items.first(where: { $0.id == item })?.tree else { return nil }
                return Root(item: item, title: node[.name]?.string ?? node.id.rawValue, isComponent: false, tree: tree)
            case .component:
                guard let tree = store.items.first(where: { $0.id == node.id.rawValue })?.tree else { return nil }
                return Root(item: node.id.rawValue, title: store.name(ofComponent: node.id), isComponent: true, tree: tree)
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
