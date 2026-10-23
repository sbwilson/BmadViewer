import BmadKit
import SwiftUI

struct StoryDetailView: View {
    @Environment(ProjectStore.self) private var store
    let story: Story
    let project: Project

    enum Source: String, CaseIterable, Identifiable {
        case storyFile = "Story file"
        case epics = "Epic definition"
        var id: Self { self }
    }

    @State private var source: Source = .storyFile

    var body: some View {
        let effective = effectiveSource
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            switch effective {
            case .storyFile:
                if let url = story.documentURL {
                    MarkdownFileView(url: url, project: project, version: store.lastLoaded)
                }
            case .epics:
                if let excerpt = story.epicsExcerpt {
                    MarkdownTextView(
                        key: "epics:\(story.id):\(store.lastLoaded?.timeIntervalSince1970 ?? 0)",
                        markdown: excerpt,
                        baseURL: project.sources.epicsFile?.deletingLastPathComponent() ?? project.root,
                        project: project
                    )
                } else {
                    ContentUnavailableView("No document", systemImage: "doc",
                                           description: Text("This story has no story file and no section in epics.md."))
                }
            }
        }
        .navigationTitle("Story \(story.number)")
    }

    private var effectiveSource: Source {
        if story.documentURL == nil { return .epics }
        if story.epicsExcerpt == nil { return .storyFile }
        return source
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Story \(story.number)")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.secondary)
                StatusBadge(status: story.status)
                if let fmStatus = story.frontMatter["status"], fmStatus != story.status.raw {
                    Text("file says \(fmStatus)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help("The story file's front matter disagrees with sprint-status.yaml")
                }
                Spacer()
                if story.documentURL != nil, story.epicsExcerpt != nil {
                    Picker("Source", selection: $source) {
                        ForEach(Source.allCases) { Text($0.rawValue).tag($0) }
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
                    Text("#\(entry.position) in \(entry.section)")
                        + Text(entry.waitsOn.isEmpty ? "" : " · waits on \(entry.waitsOn.joined(separator: ", "))")
                } icon: {
                    Image(systemName: "list.number")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            HStack(spacing: 14) {
                if let url = story.documentURL {
                    FileLink(url: url, showInViewer: store.showDocument)
                } else {
                    Text("No story file").font(.callout).foregroundStyle(.tertiary)
                }
                if let epics = project.sources.epicsFile {
                    FileLink(url: epics, showInViewer: store.showDocument)
                }
                Spacer(minLength: 0)
            }
            .font(.callout)

            let meta = ["type", "created", "baseline_commit"].compactMap { key in
                story.frontMatter[key].map { "\(key.replacingOccurrences(of: "_", with: " ")): \(key == "baseline_commit" ? String($0.prefix(8)) : $0)" }
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
