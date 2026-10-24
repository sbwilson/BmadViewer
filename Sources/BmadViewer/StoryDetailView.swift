import BmadKit
import SwiftUI

struct StoryDetailView: View {
    @Environment(ProjectStore.self) private var store
    let story: Story
    let project: Project

    var body: some View {
        TabbedDocumentsView(context: "story:\(story.id)", fixed: DocTab.storyTabs(story), project: project) {
            header
        }
        .navigationTitle("Story \(story.number)")
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
                    FileLink(url: url)
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
        .padding(.top, 14)
        .padding(.bottom, 10)
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
    @Environment(\.openDocument) private var openDocument
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
            onOpenFile: openDocument
        )
    }
}

/// A project document (build-order.md, epics.md, sprint-status.yaml) in the middle column.
struct DocumentDetailView: View {
    @Environment(ProjectStore.self) private var store
    let url: URL
    let project: Project

    var body: some View {
        FileViewer(url: url, lines: store.documentLines[url], project: project)
            .id("\(url.path(percentEncoded: false))#\(store.documentLines[url]?.fragment ?? "")")
            .navigationTitle(url.lastPathComponent)
    }
}
