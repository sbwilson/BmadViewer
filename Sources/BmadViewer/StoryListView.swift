import BmadKit
import SwiftUI

extension Status {
    var color: Color {
        switch kind {
        case .inProgress: .blue
        case .review: .purple
        case .ready: .teal
        case .backlog: .gray
        case .built: .indigo
        case .done: .green
        case .superseded: .brown
        case .optional: .secondary
        case .other: .orange
        }
    }
}

struct StatusBadge: View {
    let status: Status

    var body: some View {
        Text(status.raw)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(status.color)
            .background(status.color.opacity(0.14), in: Capsule())
            .fixedSize()
    }
}

struct StoryRow: View {
    let story: Story

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(story.number)
                .font(.callout.monospacedDigit().weight(.semibold))
                .frame(minWidth: 38, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(story.title).lineLimit(2)
                HStack(spacing: 6) {
                    StatusBadge(status: story.status)
                    if story.documentURL == nil {
                        Text(story.epicsExcerpt == nil ? "no document" : "epics.md only")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            if let url = story.documentURL { FileContextMenu(url: url) }
        }
    }
}

struct StoryListView: View {
    @Environment(ProjectStore.self) private var store
    let project: Project

    var body: some View {
        @Bindable var store = store
        let stories = store.visibleStories
        List(selection: $store.selectedStoryID) {
            if case .epic = store.sidebar {
                ForEach(stories) { StoryRow(story: $0).tag($0.id) }
            } else {
                // Grouped by status, most active first.
                let groups = Dictionary(grouping: stories, by: \.status.kind)
                ForEach(groups.keys.sorted(), id: \.self) { kind in
                    Section("\(kind.label) (\(groups[kind]!.count))") {
                        ForEach(groups[kind]!) { StoryRow(story: $0).tag($0.id) }
                    }
                }
            }
        }
        .overlay {
            if stories.isEmpty {
                ContentUnavailableView(store.search.isEmpty ? "No stories" : "No matches", systemImage: "tray")
            }
        }
        .navigationTitle(title)
    }

    private var title: String {
        switch store.sidebar {
        case .epic(let id): project.epics.first { $0.id == id }.map { "Epic \($0.id)" } ?? "Epic"
        case .active: "Active"
        default: "All stories"
        }
    }
}

struct QueueView: View {
    @Environment(ProjectStore.self) private var store
    let project: Project

    var body: some View {
        @Bindable var store = store
        List(selection: $store.selectedStoryID) {
            ForEach(project.queue) { section in
                Section {
                    if section.entries.isEmpty {
                        Text("Drained — no stories queued")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                    ForEach(section.entries) { entry in
                        QueueRow(entry: entry, story: project.story(number: entry.storyNumber))
                            .tag(project.story(number: entry.storyNumber)?.id ?? entry.id)
                    }
                } header: {
                    Text(section.heading).lineLimit(2)
                }
            }
        }
        .navigationTitle("Build order")
        .toolbar {
            if let url = project.sources.buildOrderFile {
                ToolbarItem {
                    Button { store.showDocument(url) } label: { Label("Show build-order.md", systemImage: "doc.text") }
                        .help("Show build-order.md")
                }
            }
        }
    }
}

struct QueueRow: View {
    let entry: QueueEntry
    let story: Story?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.position)
                .font(.title3.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(minWidth: 22, alignment: .trailing)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.storyNumber).font(.callout.monospacedDigit().weight(.semibold))
                    if let story { StatusBadge(status: story.status) }
                }
                Text(story?.title ?? "Not in the tracking file").lineLimit(3)
                if !entry.reason.isEmpty {
                    Text(inlineMarkdown(entry.reason))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
                if !entry.waitsOn.isEmpty {
                    Text("Waits on \(entry.waitsOn.joined(separator: ", "))")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

func inlineMarkdown(_ text: String) -> AttributedString {
    (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(text)
}
