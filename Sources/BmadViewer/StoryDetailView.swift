import BmadKit
import SwiftUI

struct StoryDetailView: View {
    @Environment(ProjectStore.self) private var store
    let story: Story
    let project: Project

    @State private var selectedLabel: String?

    var body: some View {
        let document = currentDocument
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let document {
                if let markdown = document.markdown {
                    MarkdownTextView(
                        key: "\(story.id):\(document.label):\(store.lastLoaded?.timeIntervalSince1970 ?? 0)",
                        markdown: markdown,
                        baseURL: document.url?.deletingLastPathComponent() ?? project.root,
                        project: project
                    )
                } else if let url = document.url {
                    MarkdownFileView(url: url, project: project, version: store.lastLoaded)
                }
            } else {
                ContentUnavailableView("No document", systemImage: "doc",
                                       description: Text("This story has no file and no planning entry."))
            }
        }
        .navigationTitle("Story \(story.number)")
    }

    private var currentDocument: StoryDocument? {
        story.documents.first { $0.label == selectedLabel } ?? story.documents.first
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(story.type?.capitalized ?? "Story") \(story.number)")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.secondary)
                StatusBadge(status: story.status)
                if let fmStatus = story.frontMatter["status"], fmStatus != story.status.raw, project.layout == .sprintStatus {
                    Text("file says \(fmStatus)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help("The story file's front matter disagrees with sprint-status.yaml")
                }
                if let risk = story.risk, !risk.isEmpty {
                    Text("risk \(risk)").font(.caption).foregroundStyle(risk == "high" ? .orange : .secondary)
                }
                Spacer()
                if story.documents.count > 1 {
                    Picker("Source", selection: Binding(
                        get: { currentDocument?.label ?? "" },
                        set: { selectedLabel = $0 }
                    )) {
                        ForEach(story.documents, id: \.label) { Text($0.label).tag($0.label) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            Text(story.title)
                .font(.title2.weight(.semibold))
                .lineLimit(1...3)
                .textSelection(.enabled)
                .help(story.title)

            if let entry = store.queueEntry(for: story) {
                Label {
                    Text(project.layout == .ticketTree ? entry.section : "#\(entry.position) in \(entry.section)")
                        + Text(entry.waitsOn.isEmpty ? "" : " · waits on \(entry.waitsOn.joined(separator: ", "))")
                } icon: {
                    Image(systemName: "list.number")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            } else if !story.waitsOn.isEmpty, !story.status.isTerminal {
                Label("Waits on \(story.waitsOn.joined(separator: ", "))", systemImage: "hourglass")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }

            HStack(spacing: 14) {
                let files = Array(Set(story.files)).sorted { $0.lastPathComponent < $1.lastPathComponent }
                if files.isEmpty {
                    Text("No files").font(.callout).foregroundStyle(.tertiary)
                }
                ForEach(files, id: \.self) { url in
                    FileLink(url: url, showInViewer: store.showDocument)
                }
                Spacer(minLength: 0)
            }
            .font(.callout)

            let meta = ["type", "created", "baseline_commit", "baseline_revision", "route"].compactMap { key in
                story.frontMatter[key].map { "\(key.replacingOccurrences(of: "_", with: " ")): \(key.hasPrefix("baseline") ? String($0.prefix(8)) : $0)" }
            }
            if !meta.isEmpty {
                Text(meta.joined(separator: "   "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .onChange(of: story.id) { selectedLabel = nil }
    }
}

/// A markdown file rendered in the viewer, front matter removed.
struct MarkdownFileView: View {
    let url: URL
    let project: Project
    /// Bumps when the project reloads, so edits on disk show.
    let version: Date?

    var body: some View {
        let isMarkdown = ["md", "markdown"].contains(url.pathExtension.lowercased())
        MarkdownTextView(
            key: "\(url.path(percentEncoded: false)):\(version?.timeIntervalSince1970 ?? 0)",
            markdown: {
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? "*Could not read \(url.lastPathComponent).*"
                if isMarkdown { return FrontMatter.split(text).body }
                // Anything else (sprint-status.yaml) as a code block.
                return "```\(url.pathExtension)\n\(text)\n```"
            }(),
            baseURL: url.deletingLastPathComponent(),
            project: project
        )
    }
}

struct MarkdownTextView: View {
    @Environment(ProjectStore.self) private var store
    let key: String
    let markdown: String
    let baseURL: URL
    let project: Project

    var body: some View {
        let numbers = Set(project.allStories.map(\.number))
        let root = project.root
        let markdown = markdown
        let baseURL = baseURL
        DocumentView(
            key: key,
            render: {
                MarkdownRenderer(baseURL: baseURL, projectRoot: root, storyNumbers: numbers).render(markdown)
            },
            onStoryLink: { store.select(storyNumber: $0) },
            onShowInViewer: { store.showDocument($0) }
        )
    }
}

/// A non-story document (build-order.md, epics.md, a linked file) in the middle column.
struct DocumentDetailView: View {
    @Environment(ProjectStore.self) private var store
    let url: URL
    let project: Project

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                FileLink(url: url, showInViewer: nil)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()
            MarkdownFileView(url: url, project: project, version: store.lastLoaded)
        }
        .navigationTitle(url.lastPathComponent)
    }
}
