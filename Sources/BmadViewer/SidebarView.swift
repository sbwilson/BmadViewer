import BmadKit
import SwiftUI

struct SidebarView: View {
    @Environment(ProjectStore.self) private var store
    let project: Project

    var body: some View {
        @Bindable var store = store
        List(selection: $store.sidebar) {
            Section {
                Label("Dashboard", systemImage: "gauge.with.dots.needle.67percent")
                    .tag(SidebarItem.dashboard)
                if !project.queue.isEmpty {
                    row(project.layout == .ticketTree ? "Next" : "Build order", systemImage: "list.number",
                        count: project.layout == .ticketTree
                            ? project.queue.filter { $0.heading != "Blocked" }.reduce(0) { $0 + $1.entries.count }
                            : project.queue.first?.entries.count ?? 0)
                        .tag(SidebarItem.queue)
                }
                row("Active", systemImage: "bolt", count: project.allStories.filter(\.status.isActive).count)
                    .tag(SidebarItem.active)
                row("All stories", systemImage: "tray.full", count: project.allStories.count)
                    .tag(SidebarItem.all)
                Label("Find in Project", systemImage: "text.magnifyingglass")
                    .tag(SidebarItem.search)
            }

            if !project.retroActions.isEmpty || !project.deferredWork.isEmpty || !project.humanRuns.isEmpty {
                Section("Review") {
                    if !project.retroActions.isEmpty {
                        row("Retro actions", systemImage: "arrow.uturn.backward.circle",
                            count: project.retroActions.filter { !$0.status.isTerminal }.count)
                            .tag(SidebarItem.retroActions)
                            .help("Open items; finished ones are in the list too")
                    }
                    if !project.deferredWork.isEmpty {
                        row("Deferred work", systemImage: "tray.and.arrow.down",
                            count: project.deferredWork.filter { !$0.status.isTerminal }.count)
                            .tag(SidebarItem.deferredWork)
                    }
                    if !project.humanRuns.isEmpty {
                        row("Human runs", systemImage: "person.badge.clock",
                            count: project.humanRuns.filter { !$0.status.isTerminal }.count)
                            .tag(SidebarItem.humanRuns)
                            .help("Smoke tests, checkpoints and human-in-the-loop tickets still owed")
                    }
                }
            }

            Section("Views") {
                Label("Dependencies", systemImage: "point.3.connected.trianglepath.dotted")
                    .tag(SidebarItem.graph)
                Label("Burn-up", systemImage: "chart.line.uptrend.xyaxis")
                    .tag(SidebarItem.burnup)
            }

            Section("Epics") {
                ForEach(project.epics) { epic in
                    EpicRow(epic: epic).tag(SidebarItem.epic(epic.id))
                }
            }

            let docs = project.documents
            if !docs.isEmpty {
                Section("Documents") {
                    ForEach(docs, id: \.self) { url in
                        Label(url.lastPathComponent, systemImage: "doc.plaintext")
                            .tag(SidebarItem.document(url))
                            .contextMenu { FileContextMenu(url: url) }
                    }
                }
            }

            if !project.warnings.isEmpty {
                Section("Warnings") {
                    ForEach(project.warnings, id: \.self) { w in
                        Label(w, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .lineLimit(3)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: store.sidebar) { _, item in
            // Back and forward set the whole location themselves.
            guard !store.restoringHistory else { return }
            store.epicDocsShown = nil
            if case .queue = item { return }
            if let kind = item?.workItemKind {
                let list = project.workItems(kind)
                if let id = store.selectedWorkItemID, !list.contains(where: { $0.id == id }) { store.selectedWorkItemID = nil }
                return
            }
            if let id = store.selectedStoryID, !store.visibleStories.contains(where: { $0.id == id }) {
                store.selectedStoryID = nil
            }
        }
    }

    private func row(_ title: String, systemImage: String, count: Int) -> some View {
        Label(title, systemImage: systemImage)
            .badge(count)
    }
}

struct EpicRow: View {
    let epic: Epic

    var body: some View {
        let (finished, total) = epic.progress
        HStack(spacing: 8) {
            ProgressRing(breakdown: epic.statusBreakdown, total: total)
            VStack(alignment: .leading, spacing: 1) {
                Text(epic.title).lineLimit(2)
                Text("\(epic.number.map { "Epic \($0) · " } ?? "")\(finished)/\(total)\(epic.builtCount > 0 ? " · \(epic.builtCount) built" : "") · \(epic.status.raw)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .help(hint)
    }

    /// What the ring's arcs stand for, since six of them at sixteen points
    /// across is not something anyone can name by colour alone.
    private var hint: String {
        let counts = epic.statusBreakdown.map { "\($0.count) \($0.kind.label.lowercased())" }.joined(separator: " · ")
        let retro = epic.retrospective.map { "Retrospective: \($0.raw)" }
        return [counts.isEmpty ? nil : counts, retro].compactMap { $0 }.joined(separator: "\n")
    }
}

/// How far an epic has come, drawn one arc per status in the badges' colours —
/// green done, indigo built, purple review — so an epic that is half built and
/// half done reads that way rather than as stalled.
struct ProgressRing: View {
    /// The statuses present, in chart order.
    let breakdown: [StatusCount]
    let total: Int

    var body: some View {
        Canvas { context, size in
            let line = 3.0
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = (min(size.width, size.height) - line) / 2
            var track = Path()
            track.addArc(center: centre, radius: radius, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
            context.stroke(track, with: .style(.quaternary), lineWidth: line)
            guard total > 0 else { return }
            // A hair of daylight between arcs, so an equal pair does not read as
            // one colour — but never so much that a lone story disappears. Flat
            // caps: a round one reaches beyond its arc by half the line width,
            // which at this radius is more than the gap itself.
            let gap = breakdown.count > 1 ? 4.0 : 0.0
            var start = Angle.degrees(-90)
            for slice in breakdown {
                let sweep = Angle.degrees(360 * Double(slice.count) / Double(total))
                let inset = min(gap / 2, sweep.degrees / 4)
                var arc = Path()
                arc.addArc(center: centre, radius: radius, startAngle: start + .degrees(inset),
                           endAngle: start + sweep - .degrees(inset), clockwise: false)
                context.stroke(arc, with: .color(slice.kind.color), lineWidth: line)
                start += sweep
            }
        }
        .frame(width: 16, height: 16)
    }
}
