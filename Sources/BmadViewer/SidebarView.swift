import BmadKit
import SwiftUI

struct SidebarView: View {
    @Environment(ProjectStore.self) private var store
    let project: Project

    var body: some View {
        @Bindable var store = store
        List(selection: $store.sidebar) {
            Section {
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
            }

            if !project.retroActions.isEmpty || !project.deferredWork.isEmpty {
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
                }
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
            store.epicDocsShown = nil
            if case .queue = item { return }
            if item?.workItemKind != nil {
                store.selectedWorkItemID = nil
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
            ProgressRing(fraction: total == 0 ? 0 : Double(finished) / Double(total), status: epic.status)
            VStack(alignment: .leading, spacing: 1) {
                Text(epic.title).lineLimit(2)
                Text("\(epic.number.map { "Epic \($0) · " } ?? "")\(finished)/\(total)\(epic.builtCount > 0 ? " · \(epic.builtCount) built" : "") · \(epic.status.raw)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .help(epic.retrospective.map { "Retrospective: \($0.raw)" } ?? "")
    }
}

struct ProgressRing: View {
    let fraction: Double
    let status: Status

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 3)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(status.color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 16, height: 16)
    }
}
