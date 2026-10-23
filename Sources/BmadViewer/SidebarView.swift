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
                    row("Build order", systemImage: "list.number",
                        count: project.queue.first?.entries.count ?? 0)
                        .tag(SidebarItem.queue)
                }
                row("Active", systemImage: "bolt", count: project.allStories.filter(\.status.isActive).count)
                    .tag(SidebarItem.active)
                row("All stories", systemImage: "tray.full", count: project.allStories.count)
                    .tag(SidebarItem.all)
            }

            Section("Epics") {
                ForEach(project.epics) { epic in
                    EpicRow(epic: epic).tag(SidebarItem.epic(epic.id))
                }
            }

            let docs = [project.sources.buildOrderFile, project.sources.epicsFile, project.sources.statusFile].compactMap { $0 }
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
            if case .queue = item { return }
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
                Text("Epic \(epic.id) · \(finished)/\(total) · \(epic.status.raw)")
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
