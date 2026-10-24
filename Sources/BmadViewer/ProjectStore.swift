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
    case search

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
    var selectedStoryID: Story.ID? {
        didSet { if selectedStoryID != nil { epicDocsShown = nil } }
    }
    var selectedWorkItemID: WorkItem.ID?
    /// Sort and filters for the retro-action and deferred-work lists, saved per project.
    var workQueries: [String: WorkItemQuery] = [:] {
        didSet { if workQueries != oldValue { saveQueries() } }
    }
    // MARK: Find in project

    var searchQuery = "" { didSet { if searchQuery != oldValue { scheduleSearch() } } }
    var searchOptions = TextSearch.Options() { didSet { if searchOptions != oldValue { scheduleSearch(now: true) } } }
    private(set) var searchOutcome: Result<TextSearch.Outcome, Error>?
    private(set) var searchDuration: TimeInterval = 0
    private(set) var searching = false
    var selectedSearchHit: String?
    /// Bumped to move keyboard focus to the search field.
    var focusSearch = 0
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    func showSearch(_ query: String? = nil, wholeWord: Bool? = nil) {
        sidebar = .search
        if let wholeWord { searchOptions.wholeWord = wholeWord }
        if let query { searchQuery = query }
        focusSearch += 1
    }

    /// Everything in the BMAD artifacts that mentions a story or entry. A story
    /// number also matches its key spelling: `9.16` finds `9-16-capture-…` too.
    func findReferences(_ key: String) {
        searchOptions.scope = .artifacts
        if let m = key.wholeMatch(of: /(\d+)\.(\d+[a-z]?)/) {
            searchOptions.regex = true
            showSearch("\\b\(m.1)[.-]\(m.2)\\b", wholeWord: false)
        } else {
            searchOptions.regex = false
            showSearch(key, wholeWord: true)
        }
    }

    private func scheduleSearch(now: Bool = false) {
        searchTask?.cancel()
        let query = searchQuery
        let options = searchOptions
        guard let project, !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            searchOutcome = nil
            searching = false
            return
        }
        let root = project.root
        let folders = TextSearch.artifactFolders(project)
        searching = true
        searchTask = Task {
            if !now { try? await Task.sleep(for: .milliseconds(220)) }
            guard !Task.isCancelled else { return }
            let start = Date()
            let result = await Task.detached(priority: .userInitiated) {
                Result { try TextSearch.run(query, options: options, root: root, folders: folders) }
            }.value
            guard !Task.isCancelled else { return }
            searchOutcome = result
            searchDuration = Date().timeIntervalSince(start)
            searching = false
            if let hit = selectedSearchHit, case .success(let o) = result,
               !o.files.contains(where: { f in f.matches.contains { "\(f.path)#\($0.line)" == hit } }) {
                selectedSearchHit = nil
            }
        }
    }

    /// The story whose own document is `url`.
    func story(documentedAt url: URL) -> Story? {
        let file = url.standardizedFileURL
        return project?.allStories.first { $0.files.contains { $0.standardizedFileURL == file } }
    }

    /// The deferred-work entry a line of the ledger belongs to.
    func workItem(at url: URL, line: Int) -> WorkItem? {
        guard let project, project.deferredWorkFile?.standardizedFileURL == url.standardizedFileURL else { return nil }
        return project.deferredWork.filter { ($0.line ?? .max) <= line }.max { ($0.line ?? 0) < ($1.line ?? 0) }
    }

    /// Everything ⌘K can jump to; files arrive a moment after the project loads.
    private(set) var quickOpenItems: [QuickOpenItem] = []
    var showQuickOpen = false
    /// Quick-open picks, most recent first.
    var quickOpenRecent: [String] = []
    /// Lines to show when a project document opens from quick open.
    var documentLines: [URL: LineRange] = [:]
    /// The selected stop or changed file in each story's review pane.
    var reviewSelection: [Story.ID: String] = [:]
    /// Where each story's review range ends.
    var reviewEnd: [Story.ID: GitDiff.End] = [:]
    /// The epic whose own documents fill the detail view, until a story is chosen.
    var epicDocsShown: String?
    /// Open file tabs per story, ticket, epic or work item, saved per project.
    var tabSessions: [String: TabSession] = [:] {
        didSet { if tabSessions != oldValue { saveTabs() } }
    }
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
                if rewatch {
                    loadTabs(p.root)
                    loadQueries(p.root)
                }
                indexQuickOpen(p, fresh: rewatch)
            case .failure(let e):
                error = e.localizedDescription
                if project?.root != root { project = nil }
            }
        }
    }

    private func tabsKey(_ root: URL) -> String { "openTabs:\(root.path(percentEncoded: false))" }

    private func loadTabs(_ root: URL) {
        guard let data = UserDefaults.standard.data(forKey: tabsKey(root)),
              let saved = try? JSONDecoder().decode([String: TabSession].self, from: data) else {
            tabSessions = [:]
            return
        }
        // Drop files that have gone since.
        tabSessions = saved.mapValues { s in
            var s = s
            s.opened = s.opened.filter { FileManager.default.fileExists(atPath: $0.path) }
            return s
        }
    }

    /// Stories and work items at once; files once git has listed them.
    private func indexQuickOpen(_ p: Project, fresh: Bool) {
        if fresh || quickOpenItems.isEmpty { quickOpenItems = QuickOpen.items(for: p, files: []) }
        Task {
            let items = await Task.detached(priority: .utility) {
                QuickOpen.items(for: p, files: QuickOpen.listFiles(root: p.root))
            }.value
            if project?.root == p.root { quickOpenItems = items }
        }
    }

    /// The tabbed detail view on screen, if any: where a file from quick open goes.
    func currentTabContext() -> (context: String, fixed: [DocTab])? {
        if let kind = sidebar?.workItemKind, let item = selectedWorkItem {
            return ("work:\(kind.rawValue):\(item.id)", DocTab.workItemTabs(item))
        }
        if let story = selectedStory { return ("story:\(story.id)", DocTab.storyTabs(story)) }
        if let id = epicDocsShown, let epic = project?.epics.first(where: { $0.id == id }) {
            return ("epic:\(epic.id)", DocTab.epicTabs(epic))
        }
        return nil
    }

    func open(_ result: QuickOpen.Result, external: Bool = false) {
        showQuickOpen = false
        quickOpenRecent.removeAll { $0 == result.item.id }
        quickOpenRecent.insert(result.item.id, at: 0)
        if quickOpenRecent.count > 12 { quickOpenRecent.removeLast() }
        switch result.item.target {
        case .story(let id):
            guard let story = project?.story(id: id) else { return }
            if external, let file = story.primaryFile { FileActions.open(file); return }
            select(storyNumber: story.number)
            selectedStoryID = id
        case .epic(let id):
            selectedStoryID = nil
            sidebar = .epic(id)
        case .workItem(let kind, let id):
            sidebar = kind == .deferred ? .deferredWork : .retroActions
            selectedWorkItemID = id
        case .document(let url):
            if external { FileActions.open(url); return }
            documentLines[url] = result.lines
            sidebar = .document(url)
        case .file(let url):
            if external { FileActions.open(url); return }
            if let (context, fixed) = currentTabContext() {
                openDocument(url, lines: result.lines, context: context, fixed: fixed)
            } else {
                documentLines[url] = result.lines
                sidebar = .document(url)
            }
        }
    }

    func query(_ kind: WorkItem.Kind) -> WorkItemQuery { workQueries[kind.rawValue] ?? WorkItemQuery() }

    func setQuery(_ query: WorkItemQuery, for kind: WorkItem.Kind) { workQueries[kind.rawValue] = query }

    private func queriesKey(_ root: URL) -> String { "workQueries:\(root.path(percentEncoded: false))" }

    private func loadQueries(_ root: URL) {
        workQueries = UserDefaults.standard.data(forKey: queriesKey(root))
            .flatMap { try? JSONDecoder().decode([String: WorkItemQuery].self, from: $0) } ?? [:]
    }

    private func saveQueries() {
        guard let root = project?.root, let data = try? JSONEncoder().encode(workQueries) else { return }
        UserDefaults.standard.set(data, forKey: queriesKey(root))
    }

    private func saveTabs() {
        guard let root = project?.root else { return }
        let worth = tabSessions.filter { !$0.value.opened.isEmpty || $0.value.selected != nil }
        if let data = try? JSONEncoder().encode(worth) { UserDefaults.standard.set(data, forKey: tabsKey(root)) }
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
        case .queue, .document, .retroActions, .deferredWork, .search: stories = []
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
