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
/// Retro actions or deferred work, sorted by key, state or priority, with filters.
struct WorkItemListView: View {
    @Environment(ProjectStore.self) private var store
    let project: Project
    let kind: WorkItem.Kind

    var body: some View {
        @Bindable var store = store
        let query = store.query(kind)
        let all = kind == .deferred ? project.deferredWork : project.retroActions
        let sections = query.apply(store.visibleWorkItems(kind))
        let shown = sections.reduce(0) { $0 + $1.items.count }
        List(selection: $store.selectedWorkItemID) {
            ForEach(sections, id: \.title) { section in
                Section("\(title(section)) (\(section.items.count))") {
                    ForEach(section.items) { WorkItemRow(item: $0).tag($0.id) }
                }
            }
        }
        .overlay {
            if shown == 0 {
                VStack(spacing: 10) {
                    ContentUnavailableView(store.search.isEmpty ? "Nothing here" : "No matches", systemImage: "checkmark.circle",
                                           description: Text(emptyText(query)))
                    if query.activeFilterCount > 0 {
                        Button("Clear Filters") { clearFilters() }
                    }
                }
            }
        }
        .navigationTitle(kind.rawValue)
        .navigationSubtitle("\(shown) of \(all.count)")
        .toolbar {
            ToolbarItemGroup {
                sortMenu(query)
                filterMenu(query, all: all)
                if kind == .deferred, let url = project.deferredWorkFile {
                    Button { store.showDocument(url) } label: { Label("Show deferred-work.md", systemImage: "doc.text") }
                        .help("Show deferred-work.md")
                }
            }
        }
    }

    private func update(_ change: (inout WorkItemQuery) -> Void) {
        var q = store.query(kind)
        change(&q)
        store.setQuery(q, for: kind)
    }

    private func clearFilters() {
        update { $0.states = []; $0.priorities = []; $0.epics = [] }
    }

    private func sortMenu(_ query: WorkItemQuery) -> some View {
        Menu {
            Picker("Sort by", selection: Binding(get: { query.sort }, set: { s in update { $0.sort = s } })) {
                ForEach(WorkItemQuery.Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.inline)
            Picker("Order", selection: Binding(get: { query.ascending }, set: { a in update { $0.ascending = a } })) {
                Text("Newest first").tag(false)
                Text("Oldest first").tag(true)
            }
            .pickerStyle(.inline)
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .help("Sort by \(query.sort.rawValue.lowercased()), \(query.ascending ? "oldest" : "newest") first")
    }

    private func filterMenu(_ query: WorkItemQuery, all: [WorkItem]) -> some View {
        let states = Set(all.map(\.status.raw)).sorted { (WorkItemQuery.stateRank($0), $0) < (WorkItemQuery.stateRank($1), $1) }
        let priorities = Set(all.map(\.priority)).sorted()
        let epics = kind == .retroAction ? orderedEpics(all) : []
        return Menu {
            Section("State") {
                ForEach(states, id: \.self) { state in
                    Toggle(isOn: Binding(get: { query.states.contains(state) }, set: { on in update { if on { $0.states.insert(state) } else { $0.states.remove(state) } } })) {
                        Text("\(state.prefix(1).uppercased() + state.dropFirst()) (\(all.filter { $0.status.raw == state }.count))")
                    }
                }
            }
            if priorities.count > 1 || priorities.first != .unspecified {
                Section("Priority") {
                    ForEach(priorities, id: \.self) { p in
                        Toggle(isOn: Binding(get: { query.priorities.contains(p) }, set: { on in update { if on { $0.priorities.insert(p) } else { $0.priorities.remove(p) } } })) {
                            Text("\(p.label) (\(all.filter { $0.priority == p }.count))")
                        }
                    }
                }
            }
            if !epics.isEmpty {
                Section("Epic") {
                    ForEach(epics, id: \.self) { epic in
                        Toggle(isOn: Binding(get: { query.epics.contains(epic) }, set: { on in update { if on { $0.epics.insert(epic) } else { $0.epics.remove(epic) } } })) {
                            Text(epicTitle(epic))
                        }
                    }
                }
            }
            Divider()
            Button("Clear Filters") { clearFilters() }
                .disabled(query.activeFilterCount == 0)
        } label: {
            Label(query.activeFilterCount > 0 ? "Filters (\(query.activeFilterCount))" : "Filter",
                  systemImage: query.activeFilterCount > 0 ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .help(query.activeFilterCount > 0 ? "\(query.activeFilterCount) filters on" : "Filter by state, priority or epic")
    }

    private func orderedEpics(_ items: [WorkItem]) -> [String] {
        var seen: [String] = []
        for item in items { if let e = item.epic, !seen.contains(e) { seen.append(e) } }
        return seen
    }

    private func epicTitle(_ id: String) -> String {
        project.epics.first { $0.id == id }.map { "Epic \($0.number ?? $0.id): \($0.title)" } ?? "Epic \(id)"
    }

    private func title(_ section: WorkItemQuery.Section) -> String {
        section.epic.map(epicTitle) ?? section.title
    }

    private func emptyText(_ query: WorkItemQuery) -> String {
        if query.activeFilterCount > 0 { return "No items match the filters." }
        if store.hideFinished { return "Finished items are hidden." }
        return kind == .deferred ? "No deferred-work.md entries." : "No retrospective action items."
    }
}

struct WorkItemDetailView: View {
    @Environment(ProjectStore.self) private var store
    let item: WorkItem
    let project: Project

    var body: some View {
        TabbedDocumentsView(context: "work:\(item.kind.rawValue):\(item.id)", fixed: DocTab.workItemTabs(item), project: project) {
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
                                 lines: item.line.map { line in LineRange(line, line + max(0, item.fields.count)) })
                    }
                    ForEach(item.related, id: \.self) { url in
                        FileLink(url: url)
                    }
                    Spacer(minLength: 0)
                }
                .font(.callout)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 10)
        }
        .navigationTitle(item.label)
    }
}
