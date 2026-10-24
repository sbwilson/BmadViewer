import BmadKit
import SwiftUI

/// ⌘K: type to jump to a story, ticket, epic, retro action, deferred entry or file.
struct QuickOpenPanel: View {
    @Environment(ProjectStore.self) private var store
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    var body: some View {
        let results = self.results
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Story, ticket, DW-12, retro action or file (core.rs:42 jumps to the line)", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onKeyPress(.downArrow) { move(1, count: results.count); return .handled }
                    .onKeyPress(.upArrow) { move(-1, count: results.count); return .handled }
                    .onKeyPress(.escape) { store.showQuickOpen = false; return .handled }
                    .onKeyPress(keys: [.return]) { press in
                        guard results.indices.contains(selection) else { return .handled }
                        store.open(results[selection], external: press.modifiers.contains(.command))
                        return .handled
                    }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            if results.isEmpty {
                Text(query.isEmpty ? "Type to search \(store.quickOpenItems.count) items." : "No matches.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            if query.isEmpty {
                                header(store.quickOpenRecent.isEmpty ? "Active" : "Recent and active")
                            }
                            ForEach(Array(results.enumerated()), id: \.element.id) { i, result in
                                QuickOpenRow(result: result, selected: i == selection)
                                    .id(i)
                                    .contentShape(Rectangle())
                                    .onTapGesture { store.open(result) }
                                    .onHover { if $0 { selection = i } }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 420)
                    .onChange(of: selection) { _, i in proxy.scrollTo(i) }
                }
            }
            Divider()
            HStack(spacing: 14) {
                hint("↩", "open")
                hint("⌘↩", "open in default app")
                hint("↑↓", "choose")
                hint("esc", "close")
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
        }
        .frame(width: 680)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(nsColor: .separatorColor)))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
        .onAppear { focused = true }
        .onChange(of: query) { selection = 0 }
    }

    private var results: [QuickOpen.Result] {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            return QuickOpen.search(query, in: store.quickOpenItems)
        }
        // Nothing typed: recent picks, then what is active.
        let byID = Dictionary(store.quickOpenItems.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out = store.quickOpenRecent.compactMap { byID[$0] }
        let active = store.quickOpenItems.filter { $0.kind == .story && ($0.status?.isActive ?? false) && !out.contains($0) }
        out += active
        return out.prefix(20).map { QuickOpen.Result(item: $0, score: 0, lines: nil) }
    }

    private func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    private func header(_ title: String) -> some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 4)
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.caption.monospaced().weight(.semibold))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))
            Text(text)
        }
    }
}

private struct QuickOpenRow: View {
    let result: QuickOpen.Result
    let selected: Bool

    var body: some View {
        let item = result.item
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 18)
                .foregroundStyle(selected ? .white : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(inlineMarkdown(item.title) + AttributedString(result.lines.map { ":\($0.lower)" } ?? ""))
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let status = item.status, item.kind != .file { StatusBadge(status: status) }
            Text(item.kind.label)
                .font(.caption)
                .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
        }
        .foregroundStyle(selected ? .white : .primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 6)
    }

    private var icon: String {
        switch result.item.kind {
        case .story: result.item.subtitle.hasPrefix("Bug") ? "ladybug" : result.item.subtitle.hasPrefix("Spike") ? "bolt" : "doc.text"
        case .epic: "square.stack.3d.up"
        case .retro: "arrow.uturn.backward.circle"
        case .deferred: "tray.and.arrow.down"
        case .document: "doc.plaintext"
        case .file:
            if case .file(let url) = result.item.target { FileKind.of(url).icon } else { "doc" }
        }
    }
}
