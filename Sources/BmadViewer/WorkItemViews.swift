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
                    if let ft = item.followThrough { FollowThroughBadge(followThrough: ft) }
                    if !item.linkedStories.isEmpty, item.kind != .humanRun || item.section != "Human-in-the-loop tickets" {
                        Text("→ \(item.linkedStories.joined(separator: ", "))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.blue).lineLimit(1)
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

    // The ledger append plans line edits and applies them through
    // `ReviewCompletion`, the review completion's lines-then-confirm mechanism.
    @State private var showAdd = false
    @State private var addTitle = ""
    @State private var addSeverity = ""
    @State private var addOwner = ""
    @State private var addDetail = ""
    @State private var pending: [ReviewCompletion.Edit]?
    @State private var failure: String?

    var body: some View {
        @Bindable var store = store
        let query = store.query(kind)
        let all = project.workItems(kind)
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
        .toolbar {
            ToolbarItemGroup {
                sortMenu(query)
                filterMenu(query, all: all)
                if kind == .deferred, let url = project.deferredWorkFile {
                    Button { showAdd = true } label: { Label("Add Entry…", systemImage: "plus") }
                        .help("Append DW-\(WorkItemEdits.nextLedgerNumber(project)) to \(url.lastPathComponent)")
                    Button { store.showDocument(url) } label: { Label("Show deferred-work.md", systemImage: "doc.text") }
                        .help("Show deferred-work.md")
                }
            }
        }
        .sheet(isPresented: $showAdd) { addForm }
        .alert("Append to \(project.deferredWorkFile?.lastPathComponent ?? "deferred-work.md")?",
               isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Append") { apply() }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text(editConfirmation(pending ?? []))
        }
        .alert("Could not append", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) { failure = nil }
        } message: {
            Text(failure ?? "")
        }
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New deferred work entry").font(.headline)
            TextField("What is owed", text: $addTitle, axis: .vertical).lineLimit(1...3)
            Picker("Severity", selection: $addSeverity) {
                Text("None").tag("")
                ForEach(["critical", "high", "medium", "low"], id: \.self) { Text($0).tag($0) }
            }
            .fixedSize()
            TextField("Owner", text: $addOwner)
            TextField("Detail", text: $addDetail, axis: .vertical).lineLimit(2...6)
            Text("Appends `### DW-\(WorkItemEdits.nextLedgerNumber(project)):` to "
                + "\(project.deferredWorkFile?.lastPathComponent ?? "deferred-work.md"), status open, created today. "
                + "You confirm the lines before anything is written.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { showAdd = false }
                Button("Continue") { planAdd() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(addTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func planAdd() {
        let result = WorkItemEdits.ledgerAppend(
            title: addTitle,
            severity: addSeverity.isEmpty ? nil : addSeverity,
            owner: addOwner.isEmpty ? nil : addOwner,
            detail: addDetail.isEmpty ? nil : addDetail,
            to: project.deferredWorkFile,
            number: WorkItemEdits.nextLedgerNumber(project)
        )
        switch result {
        case .success(let edits):
            showAdd = false
            pending = edits
        case .failure(let refusal):
            failure = refusal.localizedDescription
        }
    }

    private func apply() {
        guard let edits = pending else { return }
        pending = nil
        do {
            try ReviewCompletion.apply(edits)
            addTitle = ""
            addSeverity = ""
            addOwner = ""
            addDetail = ""
            store.reload()
        } catch {
            failure = error.localizedDescription
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

    // The write paths below plan line edits and apply them through
    // `ReviewCompletion`, the review completion's lines-then-confirm mechanism.
    @State private var pending: [ReviewCompletion.Edit]?
    @State private var pendingTitle = "Record this?"
    @State private var failure: String?
    @State private var showRecord = false
    @State private var progress = ""
    @State private var resolution = ""

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
                    if item.kind == .deferred, item.label.hasPrefix("DW-") {
                        Button { store.findReferences(item.label) } label: {
                            Label("Find References", systemImage: "text.magnifyingglass")
                        }
                        .buttonStyle(.borderless)
                        .help("Everything in the BMAD artifacts that mentions \(item.label)")
                    }
                    if canMarkPassed {
                        Button("Mark Passed…") { planPass() }
                            .help("Write this \((item.section ?? "run").lowercased())'s status as passed, dated today")
                    }
                    if canRecord {
                        Button("Record Progress…") { openRecord() }
                            .help("Add a progress or resolution note to this item's block in \(project.sources.statusFile?.lastPathComponent ?? "sprint-status.yaml")")
                    }
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

                if !item.linkedStories.isEmpty {
                    HStack(spacing: 10) {
                        Text(item.kind == .retroAction ? "Became" : "Story").font(.callout).foregroundStyle(.secondary)
                        ForEach(item.linkedStories, id: \.self) { number in
                            if let story = project.story(number: number) {
                                Button { store.select(storyNumber: number) } label: {
                                    HStack(spacing: 4) {
                                        Text(number).monospacedDigit().fontWeight(.semibold)
                                        Text(story.title).lineLimit(1)
                                        StatusBadge(status: story.status)
                                    }
                                }
                                .buttonStyle(.link)
                            } else {
                                Text(number).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.callout)
                }
                if let ft = item.followThrough {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        FollowThroughBadge(followThrough: ft)
                        Text(inlineMarkdown(ft.text + (ft.evidence.map { " · \($0)" } ?? "")))
                            .font(.callout).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                        Spacer(minLength: 0)
                        FileLink(url: ft.source, label: "\(ft.source.lastPathComponent):\(ft.line)", lines: LineRange(ft.line))
                            .font(.caption)
                    }
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
        .alert(pendingTitle, isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Record") { apply() }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text(editConfirmation(pending ?? []))
        }
        .alert("Could not record", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) { failure = nil }
        } message: {
            Text(failure ?? "")
        }
        .sheet(isPresented: $showRecord) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Record on \(item.id)").font(.headline).textSelection(.enabled)
                TextField("Progress — where it stands now", text: $progress, axis: .vertical)
                    .lineLimit(2...5)
                TextField("Resolution — what settled it", text: $resolution, axis: .vertical)
                    .lineLimit(2...5)
                Text("Each line added to, or replaced on, the item's block in "
                    + "\(project.sources.statusFile?.lastPathComponent ?? "sprint-status.yaml"). You confirm the lines before anything is written.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { showRecord = false }
                    Button("Continue") { planRecord() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(progress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  && resolution.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(20)
            .frame(width: 440)
        }
    }

    // MARK: Writing

    private var isSmokeTest: Bool { item.section == "Smoke tests" }

    private var canMarkPassed: Bool {
        item.kind == .humanRun && item.status.kind != .done && (isSmokeTest || item.section == "Checkpoints")
    }

    private var canRecord: Bool {
        item.kind == .retroAction && item.source != nil && item.source == project.sources.statusFile
    }

    private func planPass() {
        let result = isSmokeTest ? WorkItemEdits.smokeTestPass(item) : WorkItemEdits.checkpointPass(item)
        switch result {
        case .success(let edits):
            pendingTitle = "Mark \(item.label) passed?"
            pending = edits
        case .failure(let refusal):
            failure = refusal.localizedDescription
        }
    }

    private func openRecord() {
        progress = item.value("progress") ?? ""
        resolution = item.value("resolution") ?? ""
        showRecord = true
    }

    private func planRecord() {
        switch WorkItemEdits.retroActionRecord(item, in: project, progress: progress, resolution: resolution) {
        case .success(let edits):
            showRecord = false
            pendingTitle = "Record on \(item.id)?"
            pending = edits
        case .failure(let refusal):
            failure = refusal.localizedDescription
        }
    }

    private func apply() {
        guard let edits = pending else { return }
        pending = nil
        do {
            try ReviewCompletion.apply(edits)
            store.reload()
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// What the next retrospective found: landed, partly, not landed.
struct FollowThroughBadge: View {
    let followThrough: WorkItem.FollowThrough

    var body: some View {
        let (icon, label, color): (String, String, Color) = switch followThrough.verdict {
        case .landed: ("checkmark.circle.fill", "landed", .green)
        case .partly: ("circle.lefthalf.filled", "partly", .orange)
        case .notLanded: ("xmark.circle.fill", "not landed", .red)
        case .unclear: ("questionmark.circle", "checked", .secondary)
        }
        Label(label, systemImage: icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .labelStyle(.titleAndIcon)
            .help("Next retrospective: \(followThrough.text)")
    }
}
