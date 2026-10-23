import BmadKit
import SwiftUI

struct WorkItemRow: View {
    let item: WorkItem
    var epicTitle: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(item.label)
                .font(.callout.monospacedDigit().weight(.semibold))
                .frame(minWidth: 44, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(inlineMarkdown(item.title)).lineLimit(3)
                HStack(spacing: 6) {
                    StatusBadge(status: item.status)
                    if let severity = item.severity {
                        Text(severity)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(severityColor(severity))
                    }
                    if !item.gates.isEmpty {
                        Label("gates \(item.gates.joined(separator: ", "))", systemImage: "hand.raised.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }
                    if let owner = item.owner, !owner.isEmpty {
                        Text(owner).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            if let url = item.source { FileContextMenu(url: url) }
        }
    }
}

func severityColor(_ severity: String) -> Color {
    switch severity.lowercased() {
    case "critical": .red
    case "high": .orange
    case "medium": .yellow
    default: .secondary
    }
}

/// Retro actions grouped by epic, or deferred work grouped by status, open first.
struct WorkItemListView: View {
    @Environment(ProjectStore.self) private var store
    let project: Project
    let kind: WorkItem.Kind

    var body: some View {
        @Bindable var store = store
        let items = store.visibleWorkItems(kind)
        List(selection: $store.selectedWorkItemID) {
            ForEach(groups(items), id: \.title) { group in
                Section("\(group.title) (\(group.items.count))") {
                    ForEach(group.items) { WorkItemRow(item: $0).tag($0.id) }
                }
            }
        }
        .overlay {
            if items.isEmpty {
                ContentUnavailableView(store.search.isEmpty ? "Nothing here" : "No matches", systemImage: "checkmark.circle",
                                       description: Text(emptyText))
            }
        }
        .navigationTitle(kind.rawValue)
        .toolbar {
            if kind == .deferred, let url = project.deferredWorkFile {
                ToolbarItem {
                    Button { store.showDocument(url) } label: { Label("Show deferred-work.md", systemImage: "doc.text") }
                        .help("Show deferred-work.md")
                }
            }
        }
    }

    private var emptyText: String {
        store.hideFinished ? "Finished items are hidden." : (kind == .deferred ? "No deferred-work.md entries." : "No retrospective action items.")
    }

    struct Group { let title: String; let items: [WorkItem] }

    /// Canonical entries by DW number, ahead of legacy bullets, which go by line.
    private func recency(_ item: WorkItem) -> (Int, Int) {
        if let n = Int(item.label.dropFirst(3)), item.label.hasPrefix("DW-") { return (1, n) }
        return (0, item.line ?? 0)
    }

    private func groups(_ items: [WorkItem]) -> [Group] {
        switch kind {
        case .retroAction:
            // By epic, newest retrospective first, keeping each epic's own order.
            var order: [String] = []
            var byEpic: [String: [WorkItem]] = [:]
            for item in items {
                let key = item.epic ?? "—"
                if byEpic[key] == nil { order.append(key) }
                byEpic[key, default: []].append(item)
            }
            return order.reversed().map { key in
                let title = project.epics.first { $0.id == key }.map { "Epic \($0.number ?? $0.id): \($0.title)" } ?? "Epic \(key)"
                return Group(title: title, items: byEpic[key]!)
            }
        case .deferred:
            let byStatus = Dictionary(grouping: items, by: \.status.raw)
            let rank: (String) -> Int = { ["open": 0, "in-progress": 1, "done": 3][$0] ?? 2 }
            return byStatus.keys.sorted { (rank($0), $0) < (rank($1), $1) }.map { status in
                // Newest first within a status: highest DW number, then legacy bullets by line.
                Group(title: status.prefix(1).uppercased() + status.dropFirst(),
                      items: byStatus[status]!.sorted { recency($0) > recency($1) })
            }
        }
    }
}

struct WorkItemDetailView: View {
    @Environment(ProjectStore.self) private var store
    let item: WorkItem
    let project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.kind == .deferred ? item.label : "\(item.kind.rawValue) \(item.label)")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.secondary)
                    StatusBadge(status: item.status)
                    if let severity = item.severity {
                        Text(severity).font(.caption.weight(.medium)).foregroundStyle(severityColor(severity))
                    }
                    Spacer()
                }
                Text(inlineMarkdown(item.title))
                    .font(.title2.weight(.semibold))
                    .lineLimit(1...4)
                    .textSelection(.enabled)

                let facts = [
                    item.owner.map { "Owner: \($0)" },
                    item.epic.flatMap { id in project.epics.first { $0.id == id }.map { "Epic \($0.number ?? $0.id): \($0.title)" } },
                    item.section,
                    item.gates.isEmpty ? nil : "Gates \(item.gates.joined(separator: ", "))",
                ].compactMap { $0 }
                if !facts.isEmpty {
                    Text(facts.joined(separator: " · "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }

                HStack(spacing: 14) {
                    if let source = item.source {
                        FileLink(url: source, label: source.lastPathComponent + (item.line.map { ":\($0)" } ?? ""),
                                 showInViewer: store.showDocument)
                    }
                    ForEach(item.related, id: \.self) { url in
                        FileLink(url: url, showInViewer: store.showDocument)
                    }
                    Spacer(minLength: 0)
                }
                .font(.callout)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider()
            MarkdownTextView(
                key: "\(item.kind.rawValue):\(item.id):\(store.lastLoaded?.timeIntervalSince1970 ?? 0)",
                markdown: item.markdown,
                baseURL: item.source?.deletingLastPathComponent() ?? project.root,
                project: project
            )
        }
        .navigationTitle(item.label)
    }
}
