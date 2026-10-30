import AppKit
import BmadKit
import SwiftUI

// MARK: Model

/// One tab in a detail view: a fixed view of the selected item (its ticket, plan,
/// epic document) or a file opened from a link, which can be closed.
struct DocTab: Identifiable, Hashable {
    let id: String
    let title: String
    let icon: String
    var url: URL?
    var markdown: String?
    var lines: LineRange?
    /// Bumped each time the tab is opened again, so the viewer re-scrolls to `lines`.
    var nonce = 0
    let closable: Bool
    /// The review pane of this story, rather than a document.
    var reviewOf: String?

    static func fixed(_ doc: StoryDocument) -> DocTab {
        let icon: String = switch doc.label {
        case "Ticket": "ticket"
        case "Plan": "list.bullet.clipboard"
        case "Epic definition": "text.book.closed"
        default: "doc.text"
        }
        return DocTab(id: "fixed:\(doc.label)", title: doc.label, icon: icon,
                      url: doc.markdown == nil ? doc.url : nil, markdown: doc.markdown, closable: false)
    }

    static func file(_ opened: OpenedDocument) -> DocTab {
        let url = URL(filePath: opened.path)
        return DocTab(id: opened.id, title: url.lastPathComponent, icon: FileKind.of(url).icon,
                      url: url, lines: opened.lines, nonce: opened.nonce, closable: true)
    }

    static func storyTabs(_ story: Story) -> [DocTab] {
        var tabs = story.documents.map(fixed)
        if story.review != nil || story.baseline != nil {
            tabs.append(DocTab(id: "fixed:Review", title: "Review", icon: "checklist.checked", closable: false, reviewOf: story.id))
        }
        return tabs
    }

    static func epicTabs(_ epic: Epic) -> [DocTab] {
        epic.documents.map { url in
            let name = url.deletingPathExtension().lastPathComponent
            let title = name == epic.id ? "Epic"
                : name.hasSuffix("-retrospective") || name.contains("-retro-") ? "Retrospective"
                : url.lastPathComponent
            return DocTab(id: "fixed:\(url.path(percentEncoded: false))", title: title, icon: FileKind.of(url).icon,
                          url: url, closable: false)
        }
    }

    static func workItemTabs(_ item: WorkItem) -> [DocTab] {
        [DocTab(id: "fixed:item", title: item.kind == .deferred ? "Entry" : item.kind == .humanRun ? "Run" : "Action", icon: "checklist",
                markdown: item.markdown, closable: false)]
    }
}

/// A file opened in a tab, remembered per story, ticket or epic.
struct OpenedDocument: Codable, Hashable, Identifiable {
    var path: String
    var lines: LineRange?
    var nonce = 0
    var id: String { "file:\(path)" }
}

struct TabSession: Codable, Equatable {
    var opened: [OpenedDocument] = []
    var selected: String?
}

/// What a link click does inside a tabbed detail view: open the file in a tab.
struct OpenDocumentAction {
    let open: @MainActor (URL, LineRange?) -> Void
    @MainActor func callAsFunction(_ url: URL, _ lines: LineRange? = nil) { open(url, lines) }
}

private struct OpenDocumentKey: EnvironmentKey {
    static let defaultValue: OpenDocumentAction? = nil
}

extension EnvironmentValues {
    var openDocument: OpenDocumentAction? {
        get { self[OpenDocumentKey.self] }
        set { self[OpenDocumentKey.self] = newValue }
    }
}

// MARK: Store

extension ProjectStore {
    func session(_ context: String) -> TabSession { tabSessions[context] ?? TabSession() }

    /// Opens `url` in `context`'s tabs: a fixed tab showing that file is selected
    /// instead, unless a line range asks for the file's source.
    func openDocument(_ url: URL, lines: LineRange?, context: String, fixed: [DocTab]) {
        guard url.isFileURL else { FileActions.open(url); return }
        let file = url.withoutFragment.standardizedFileURL
        var s = session(context)
        if lines == nil, let tab = fixed.first(where: { $0.url?.standardizedFileURL == file }) {
            s.selected = tab.id
        } else if let i = s.opened.firstIndex(where: { $0.path == file.path(percentEncoded: false) }) {
            if let lines { s.opened[i].lines = lines }
            s.opened[i].nonce += 1
            s.selected = s.opened[i].id
        } else {
            let doc = OpenedDocument(path: file.path(percentEncoded: false), lines: lines)
            s.opened.append(doc)
            s.selected = doc.id
        }
        tabSessions[context] = s
    }

    func selectTab(_ id: String, context: String) {
        var s = session(context)
        s.selected = id
        tabSessions[context] = s
    }

    /// Closes a file tab; the tab to its left (or the first fixed tab) takes its place.
    func closeTab(_ id: String, context: String, fixed: [DocTab]) {
        var s = session(context)
        guard let i = s.opened.firstIndex(where: { $0.id == id }) else { return }
        s.opened.remove(at: i)
        if s.selected == id {
            s.selected = i > 0 ? s.opened[i - 1].id : fixed.last?.id ?? s.opened.first?.id
        }
        tabSessions[context] = s
    }

    func closeTabs(context: String, keeping: String?, fixed: [DocTab], toTheRightOf: String? = nil) {
        var s = session(context)
        if let anchor = toTheRightOf, let i = s.opened.firstIndex(where: { $0.id == anchor }) {
            s.opened = Array(s.opened.prefix(i + 1))
        } else if let anchor = toTheRightOf, fixed.contains(where: { $0.id == anchor }) {
            s.opened = []
        } else {
            s.opened = s.opened.filter { $0.id == keeping }
        }
        if let sel = s.selected, !s.opened.contains(where: { $0.id == sel }), !fixed.contains(where: { $0.id == sel }) {
            s.selected = keeping ?? fixed.first?.id
        }
        tabSessions[context] = s
    }

    /// Shows an epic's own documents in the detail view, opening `url` there.
    func showEpicDocument(_ epic: Epic, url: URL, lines: LineRange?) {
        selectedStoryID = nil
        epicDocsShown = epic.id
        openDocument(url, lines: lines, context: "epic:\(epic.id)", fixed: DocTab.epicTabs(epic))
    }
}

// MARK: Views

/// A header, a browser-style tab bar, and the selected tab's content.
struct TabbedDocumentsView<Header: View>: View {
    @Environment(ProjectStore.self) private var store
    let context: String
    let fixed: [DocTab]
    let project: Project
    @ViewBuilder let header: () -> Header

    var body: some View {
        let session = store.session(context)
        let tabs = fixed + session.opened.map(DocTab.file)
        let selected = tabs.first { $0.id == session.selected } ?? tabs.first
        VStack(alignment: .leading, spacing: 0) {
            header()
            if tabs.count > 0 {
                TabBar(tabs: tabs, selected: selected?.id,
                       select: { store.selectTab($0, context: context) },
                       close: { store.closeTab($0, context: context, fixed: fixed) },
                       closeOthers: { store.closeTabs(context: context, keeping: $0, fixed: fixed) },
                       closeRight: { store.closeTabs(context: context, keeping: nil, fixed: fixed, toTheRightOf: $0) })
            } else {
                Divider()
            }
            if let selected {
                DocTabContent(tab: selected, project: project)
                    .id("\(context)#\(selected.id)#\(selected.nonce)")
            } else {
                ContentUnavailableView("No document", systemImage: "doc", description: Text("Nothing to show for this item."))
            }
        }
        .environment(\.openDocument, OpenDocumentAction { url, lines in
            store.openDocument(url, lines: lines, context: context, fixed: fixed)
        })
    }
}

struct TabBar: View {
    let tabs: [DocTab]
    let selected: String?
    let select: (String) -> Void
    let close: (String) -> Void
    let closeOthers: (String) -> Void
    let closeRight: (String) -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            ForEach(tabs) { tab in
                TabButton(tab: tab, isSelected: tab.id == selected, select: { select(tab.id) }, close: { close(tab.id) })
                    .contextMenu {
                        if tab.closable { Button("Close Tab") { close(tab.id) } }
                        Button("Close Other Tabs") { closeOthers(tab.id) }
                        Button("Close Tabs to the Right") { closeRight(tab.id) }
                        if let url = tab.url {
                            Divider()
                            FileContextMenu(url: url)
                        }
                    }
            }
            Rectangle().fill(.clear).frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottom) { hairline }
        }
        .frame(height: 30)
        .padding(.leading, 8)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
        .overlay(alignment: .bottomLeading) { hairline.frame(width: 8) }
    }

    private var hairline: some View {
        Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
    }
}

private struct TabButton: View {
    let tab: DocTab
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: tab.icon)
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? .primary : .secondary)
            Text(tab.title + (tab.lines.map { ":\($0.lower)" } ?? ""))
                .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isSelected ? .primary : .secondary)
            Spacer(minLength: 0)
            if tab.closable {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(isSelected || hovering ? 1 : 0)
                .help("Close tab")
            }
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 70, idealWidth: 160, maxWidth: 220, maxHeight: .infinity)
        .background {
            let shape = UnevenRoundedRectangle(topLeadingRadius: 7, topTrailingRadius: 7)
            if isSelected {
                shape.fill(Color(nsColor: .textBackgroundColor))
                    .overlay(shape.stroke(Color(nsColor: .separatorColor), lineWidth: 1).padding(.bottom, -1))
            } else if hovering {
                shape.fill(Color.primary.opacity(0.06))
            }
        }
        .overlay(alignment: .bottom) {
            if !isSelected { Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1) }
        }
        .padding(.top, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .help(tab.url?.path(percentEncoded: false) ?? tab.title)
    }
}

/// What a tab shows: assembled markdown, or a file in the viewer that suits it.
struct DocTabContent: View {
    @Environment(ProjectStore.self) private var store
    let tab: DocTab
    let project: Project

    var body: some View {
        if let id = tab.reviewOf, let story = project.story(id: id) {
            ReviewPaneView(story: story, project: project)
        } else if let markdown = tab.markdown {
            MarkdownTextView(
                key: "\(tab.id):\(store.lastLoaded?.timeIntervalSince1970 ?? 0)",
                markdown: markdown,
                baseURL: tab.url?.deletingLastPathComponent() ?? project.root,
                project: project
            )
        } else if let url = tab.url {
            FileViewer(url: url, lines: tab.lines, project: project)
        }
    }
}

/// An epic's own documents (epic file, tickets.toml, retrospective) filling the detail view.
struct EpicDocumentsView: View {
    let epic: Epic
    let project: Project

    var body: some View {
        TabbedDocumentsView(context: "epic:\(epic.id)", fixed: DocTab.epicTabs(epic), project: project) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(epic.number.map { "Epic \($0)" } ?? "Epic")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.secondary)
                    StatusBadge(status: epic.status)
                    let (done, total) = epic.progress
                    Text("\(done)/\(total) finished\(epic.builtCount > 0 ? " · \(epic.builtCount) built" : "")")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if let retro = epic.retrospective {
                        Text("retrospective \(retro.raw)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Text(epic.title).font(.title2.weight(.semibold)).lineLimit(1...2).textSelection(.enabled)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 10)
        }
    }
}
