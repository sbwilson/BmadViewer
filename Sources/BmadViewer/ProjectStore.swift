import AppKit
import BmadKit
import Observation

enum SidebarItem: Hashable {
    case queue
    case active
    case all
    case epic(String)
    case document(URL)
    case retroActions
    case deferredWork

    var workItemKind: WorkItem.Kind? {
        switch self {
        case .retroActions: .retroAction
        case .deferredWork: .deferred
        default: nil
        }
    }
}

@MainActor
@Observable
final class ProjectStore {
    private(set) var project: Project?
    private(set) var error: String?
    private(set) var isLoading = false
    private(set) var lastLoaded: Date?

    var sidebar: SidebarItem? = .queue
    var selectedStoryID: Story.ID?
    var selectedWorkItemID: WorkItem.ID?
    var search = ""
    var hideFinished = false

    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?

    static let recentsKey = "recentProjects"

    var recents: [URL] {
        (UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? []).map { URL(filePath: $0) }
    }

    func open(_ url: URL) {
        sidebar = .queue
        selectedStoryID = nil
        load(url)
        var list = recents.map { $0.path(percentEncoded: false) }.filter { $0 != url.path(percentEncoded: false) }
        list.insert(url.path(percentEncoded: false), at: 0)
        UserDefaults.standard.set(Array(list.prefix(10)), forKey: Self.recentsKey)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    func reload() {
        guard let root = project?.root else { return }
        load(root)
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Open Project"
        panel.message = "Choose a folder containing a BMAD project"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    private func load(_ root: URL) {
        isLoading = true
        reloadTask?.cancel()
        reloadTask = Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try ProjectLoader.load(root: root) }
            }.value
            guard !Task.isCancelled else { return }
            isLoading = false
            switch result {
            case .success(let p):
                let rewatch = project?.root != p.root
                project = p
                error = nil
                lastLoaded = Date()
                if selectedStoryID.map({ p.story(id: $0) == nil }) == true { selectedStoryID = nil }
                if rewatch || watcher == nil { watch(p) }
            case .failure(let e):
                error = e.localizedDescription
                if project?.root != root { project = nil }
            }
        }
    }

    private func watch(_ p: Project) {
        var dirs = p.sources.watched
        dirs.append(p.root.appending(path: "_bmad"))
        let unique = Array(Set(dirs.map(\.standardizedFileURL)))
        watcher = FileWatcher(directories: unique) { [weak self] in
            Task { @MainActor in self?.reload() }
        }
    }

    // MARK: Derived

    var selectedStory: Story? {
        selectedStoryID.flatMap { project?.story(id: $0) }
    }

    /// Stories for the current sidebar item, after search and the finished filter.
    var visibleStories: [Story] {
        guard let project else { return [] }
        var stories: [Story]
        switch sidebar {
        case .epic(let id): stories = project.epics.first { $0.id == id }?.stories ?? []
        case .active: stories = project.allStories.filter(\.status.isActive)
        case .all, .none: stories = project.allStories
        case .queue, .document, .retroActions, .deferredWork: stories = []
        }
        if hideFinished, sidebar != .active { stories = stories.filter { !$0.status.isTerminal } }
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            stories = stories.filter {
                $0.number.hasPrefix(q) || $0.title.localizedCaseInsensitiveContains(q) || $0.id.localizedCaseInsensitiveContains(q)
            }
        }
        return stories
    }

    var selectedWorkItem: WorkItem? {
        guard let id = selectedWorkItemID, let kind = sidebar?.workItemKind, let project else { return nil }
        return (kind == .deferred ? project.deferredWork : project.retroActions).first { $0.id == id }
    }

    /// Items of one kind after search and the finished filter.
    func visibleWorkItems(_ kind: WorkItem.Kind) -> [WorkItem] {
        guard let project else { return [] }
        var items = kind == .deferred ? project.deferredWork : project.retroActions
        if hideFinished { items = items.filter { !$0.status.isTerminal } }
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            items = items.filter { item in
                item.label.localizedCaseInsensitiveContains(q) || item.id.localizedCaseInsensitiveContains(q)
                    || item.title.localizedCaseInsensitiveContains(q) || (item.owner?.localizedCaseInsensitiveContains(q) ?? false)
                    || item.fields.contains { $0.value.localizedCaseInsensitiveContains(q) }
            }
        }
        return items
    }

    func queueEntry(for story: Story) -> QueueEntry? {
        project?.queue.lazy.flatMap(\.entries).first { $0.storyNumber == story.number }
    }

    /// Follow a `bmadviewer://story/<n>` link.
    func select(storyNumber: String) {
        guard let story = project?.story(number: storyNumber) else { NSSound.beep(); return }
        if !visibleStories.contains(where: { $0.id == story.id }), sidebar != .queue {
            sidebar = .epic(story.epicID)
        }
        if case .document = sidebar { sidebar = .epic(story.epicID) }
        selectedStoryID = story.id
    }

    func showDocument(_ url: URL) {
        sidebar = .document(url)
    }
}
