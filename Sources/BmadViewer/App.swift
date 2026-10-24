import AppKit
import BmadKit
import SwiftUI

@main
struct BmadViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // One window per project; the window's value is the project's folder, so
        // macOS reopens each project in its own window on the next launch.
        WindowGroup("BMAD Viewer", id: "project", for: URL.self) { $root in
            ProjectWindow(root: $root)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1440, height: 900)
        .commands { AppCommands() }
    }
}

/// A window and the project it shows.
struct ProjectWindow: View {
    @Binding var root: URL?
    @State private var store = ProjectStore()
    @Environment(\.openWindow) private var openWindow

    /// Only the first window of a launch falls back to the argument or the last project.
    @MainActor static var openedInitial = false

    var body: some View {
        ContentView()
            .environment(store)
            .focusedSceneValue(\.projectStore, store)
            .focusedSceneValue(\.openProject, OpenProjectAction { url in
                if store.project == nil { store.open(url) } else { openWindow(value: url) }
            })
            .task { openInitial() }
            .onChange(of: store.project?.root) { _, new in
                if let new, new != root { root = new }
            }
    }

    /// A restored window reopens its project; a launch with none restores the path
    /// argument (`BmadViewer ~/dev/Qubric`) or the most recent project.
    private func openInitial() {
        guard store.project == nil else { return }
        if let root {
            store.open(root)
        } else if !Self.openedInitial {
            Self.openedInitial = true
            let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
            if let path = args.first {
                store.open(URL(filePath: NSString(string: path).expandingTildeInPath))
            } else if let recent = store.recents.first {
                store.open(recent)
            }
        }
    }
}

struct OpenProjectAction {
    let open: @MainActor (URL) -> Void
    @MainActor func callAsFunction(_ url: URL) { open(url) }
}

extension FocusedValues {
    @Entry var projectStore: ProjectStore?
    @Entry var openProject: OpenProjectAction?
}

/// The menus, acting on whichever project window is in front.
struct AppCommands: Commands {
    @FocusedValue(\.projectStore) private var store
    @FocusedValue(\.openProject) private var openProject
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Project…") { chooseProject() }
                .keyboardShortcut("o")
            Menu("Open Recent") {
                ForEach(ProjectStore.recentProjects, id: \.self) { url in
                    Button(url.path(percentEncoded: false)) { open(url) }
                }
            }
            Button("New Window") { openWindow(id: "project") }
                .keyboardShortcut("n")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") { closeTabOrWindow() }
                .keyboardShortcut("w")
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: [.command, .shift])
        }
        CommandMenu("Go") {
            Button("Back") { store?.goBack() }
                .keyboardShortcut("[")
                .disabled(!(store?.canGoBack ?? false))
            Button("Forward") { store?.goForward() }
                .keyboardShortcut("]")
                .disabled(!(store?.canGoForward ?? false))
            Divider()
            Button("Quick Open…") { store?.showQuickOpen.toggle() }
                .keyboardShortcut("k")
                .disabled(store?.project == nil)
            Button("Quick Open… ") { store?.showQuickOpen.toggle() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(store?.project == nil)
            Button("Find in Project…") { store?.showSearch() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(store?.project == nil)
            Divider()
            Button("Next Tab") { store?.selectAdjacentTab(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { store?.selectAdjacentTab(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            ForEach(1..<10) { n in
                Button(n == 9 ? "Last Tab" : "Tab \(n)") { store?.selectTab(number: n) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")))
            }
        }
        CommandGroup(after: .toolbar) {
            Button("Reload") { store?.reload() }
                .keyboardShortcut("r")
                .disabled(store?.project == nil)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Find…") { DocumentFind.perform(.showFindInterface) }
                .keyboardShortcut("f")
            Button("Find Next") { DocumentFind.perform(.nextMatch) }
                .keyboardShortcut("g")
            Button("Find Previous") { DocumentFind.perform(.previousMatch) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
        }
    }

    private func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Open Project"
        panel.message = "Choose a folder containing a BMAD project"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    /// Into the front window when it is empty; otherwise its own window (an open
    /// project's window comes to the front instead of opening twice).
    private func open(_ url: URL) {
        if let openProject { openProject(url) } else { openWindow(value: url) }
    }

    /// ⌘W closes the selected file tab; with no file tabs open it closes the window.
    private func closeTabOrWindow() {
        if store?.closeSelectedTab() == true { return }
        if store?.hasOpenFileTabs == true { NSSound.beep(); return }
        NSApp.keyWindow?.performClose(nil)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// `BmadViewer --dump <project>` prints what the loader read and exits: a check
    /// against `tickets.py next` or the sprint file without opening a window.
    func applicationWillFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--dump") else { return }
        let path = args.count > i + 1 ? args[i + 1] : FileManager.default.currentDirectoryPath
        do {
            let p = try ProjectLoader.load(root: URL(filePath: NSString(string: path).expandingTildeInPath))
            print("\(p.name) · \(p.layout.rawValue) · \(p.epics.count) epics · \(p.allStories.count) stories")
            for e in p.epics {
                print("  \(e.id): \(e.title) [\(e.status.raw)] \(e.progress.finished)/\(e.progress.total), \(e.builtCount) built")
            }
            for s in p.queue {
                print("\(s.heading): \(s.entries.map(\.storyNumber).joined(separator: " "))")
            }
            for (name, items) in [("Retro actions", p.retroActions), ("Deferred work", p.deferredWork)] {
                let counts = Dictionary(grouping: items, by: \.status.raw).mapValues(\.count)
                    .sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
                print("\(name): \(items.count) (\(counts))")
            }
            let reviewed = p.allStories.filter { $0.review != nil }
            print("Review orders: \(reviewed.count) stories, \(reviewed.reduce(0) { $0 + ($1.review?.stops.count ?? 0) }) stops, \(reviewed.reduce(0) { $0 + ($1.review?.stops.filter { $0.url == nil }.count ?? 0) }) without a link")
            if ProcessInfo.processInfo.environment["BMADV_REVIEW_DETAIL"] != nil {
                let moved = reviewed.reduce(0) { $0 + $1.review!.stops.filter { $0.movedFrom != nil }.count }
                print("  moved: \(moved)")
                for s in reviewed { for stop in s.review!.stops where stop.url == nil || !FileManager.default.fileExists(atPath: stop.url!.path(percentEncoded: false)) {
                    print("  \(s.number): \(stop.url == nil ? "no link" : "missing \(stop.url!.path(percentEncoded: false))") — \(stop.framing.prefix(70))")
                } }
            }
            for s in p.allStories where s.status.kind == .review {
                let verdict: String = switch ReviewCompletion.edits(for: s, in: p) {
                case .success(let edits): "can mark done (\(edits.count) edits)"
                case .failure(let refusal): "refused: \(refusal.localizedDescription)"
                }
                print("  \(s.number) [\(s.status.raw)] review order: \(s.review != nil) · \(verdict)")
            }
            if let number = ProcessInfo.processInfo.environment["BMADV_DIFF"], let story = p.story(number: number), let baseline = story.baseline {
                let range = try GitDiff.range(baseline: baseline, end: .story, document: story.primaryFile, projectRoot: p.root)
                let files = try GitDiff.changedFiles(in: range)
                print("Diff \(number): \(range.label) (\(range.note ?? "")) · \(files.count) files")
                for stop in story.review?.stops ?? [] {
                    guard let url = stop.url else { print("  stop \(stop.id): no link"); continue }
                    let rels = [url, stop.movedFrom.map { p.root.appending(path: $0) }].compactMap { $0 }.map { GitDiff.relativePath($0, in: range.repository) }
                    let rel = rels[0]
                    guard let change = files.first(where: { rels.contains($0.path) }) else { print("  stop \(stop.id) \(rel): unchanged in range"); continue }
                    var d = try GitDiff.diff(range, path: change.path, oldPath: change.oldPath)
                    var full = false
                    if let lines = stop.lines, !d.shows(lines) { d = try GitDiff.diff(range, path: change.path, oldPath: change.oldPath, context: nil); full = true }
                    let lit = stop.lines.map { d.shows($0) } ?? true
                    print("  stop \(stop.id) \(rel) [\(change.status)] hunks \(d.hunks.count)\(full ? " (whole file)" : "") · line \(stop.lines?.label ?? "-") shown: \(lit)")
                }
                let named = Set((story.review?.stops ?? []).flatMap { s in [s.url, s.movedFrom.map { p.root.appending(path: $0) }].compactMap { $0 }.map { GitDiff.relativePath($0, in: range.repository) } })
                print("  other changed files: \(files.filter { !named.contains($0.path) }.map(\.path).joined(separator: ", "))")
            }
            if let q = ProcessInfo.processInfo.environment["BMADV_QUICKOPEN"] {
                var t = Date()
                let files = QuickOpen.listFiles(root: p.root)
                let items = QuickOpen.items(for: p, files: files)
                print("Quick open: \(items.count) items (\(files.count) files) indexed in \(Int(Date().timeIntervalSince(t) * 1000)) ms")
                for query in q.split(separator: "|").map(String.init) {
                    t = Date()
                    let results = QuickOpen.search(query, in: items)
                    print("  \"\(query)\" \(Int(Date().timeIntervalSince(t) * 1000)) ms: " + results.prefix(4).map { "\($0.item.kind.label) \($0.item.title.prefix(40))\($0.lines.map { " @\($0.lower)" } ?? "")" }.joined(separator: " | "))
                }
            }
            if let q = ProcessInfo.processInfo.environment["BMADV_SEARCH"] {
                for query in q.split(separator: "|").map(String.init) {
                    for scope in TextSearch.Scope.allCases {
                        let t = Date()
                        let regex = query.contains("\\")
                        let o = try TextSearch.run(query, options: .init(wholeWord: !regex, regex: regex, scope: scope), root: p.root, folders: TextSearch.artifactFolders(p))
                        print("Search \"\(query)\" [\(scope.rawValue)] \(Int(Date().timeIntervalSince(t) * 1000)) ms: \(o.matchCount) matches in \(o.files.count) files\(o.truncated ? " (truncated)" : "") · " + o.files.prefix(3).map { "\($0.path.split(separator: "/").last!) ×\($0.matches.count)" }.joined(separator: ", "))
                    }
                }
            }
            if ProcessInfo.processInfo.environment["BMADV_INSIGHTS"] != nil {
                let deps = p.allStories.reduce(0) { $0 + $1.dependsOn.count }
                let graph = DependencyGraph.build(p, epic: nil, hideFinished: false)
                print("Dependencies: \(deps) edges over \(p.allStories.filter { !$0.dependsOn.isEmpty }.count) stories · \(graph.layers) layers · longest remaining chain: \(graph.longestChain.compactMap { p.story(id: $0)?.number }.joined(separator: " → "))")
                let ft = p.retroActions.compactMap(\.followThrough)
                print("Follow-through: \(ft.count) of \(p.retroActions.count) actions checked (" + ["landed", "partly", "notLanded", "unclear"].map { v in "\(v) \(ft.filter { $0.verdict.rawValue == v }.count)" }.joined(separator: ", ") + ")")
                let linked = p.retroActions.filter { !$0.linkedStories.isEmpty }
                print("Linked stories: \(linked.count) actions · " + linked.prefix(4).map { "\($0.label)→\($0.linkedStories.joined(separator: ","))" }.joined(separator: "  "))
                let t = Date()
                let history = try Burnup.history(p)
                if let first = history.first, let last = history.last {
                    let a = first.counts(epic: nil), b = last.counts(epic: nil)
                    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
                    print("Burn-up: \(history.count) snapshots in \(Int(Date().timeIntervalSince(t) * 1000)) ms · \(f.string(from: first.date)) \(a.done)/\(a.total) → \(f.string(from: last.date)) \(b.done)/\(b.total) done, \(b.built) built")
                    let now = p.allStories.filter { !$0.status.isTerminal || $0.status.kind == .done }
                    for epic in p.epics {
                        let c = last.counts(epic: epic.id)
                        let doneNow = epic.stories.filter { $0.status.kind == .done }.count
                        let totalNow = epic.stories.filter { $0.status.kind != .superseded }.count
                        if c.done != doneNow || c.total != totalNow { print("  epic \(epic.id): replay \(c.done)/\(c.total) now \(doneNow)/\(totalNow)") }
                    }
                    let m = Burnup.milestones(history)
                    let f2 = DateFormatter(); f2.dateFormat = "MM-dd"
                    let recentDone = m.done.sorted { $0.value > $1.value }.prefix(4).compactMap { id, d in p.story(id: id).map { "\($0.number)@\(f2.string(from: d))" } }
                    let recentNew = m.created.sorted { $0.value > $1.value }.prefix(4).compactMap { id, d in p.story(id: id).map { "\($0.number)@\(f2.string(from: d))" } }
                    print("  milestones: created \(m.created.count), built \(m.built.count), done \(m.done.count) · recent done \(recentDone) · recent new \(recentNew) · weeks \(m.finishedPerWeek.count)")
                    print("  loader now: \(p.allStories.filter { $0.status.kind == .done }.count)/\(now.count) done, \(p.allStories.filter { $0.status.kind == .built }.count) built")
                }
                let counts = Dictionary(grouping: p.humanRuns, by: { $0.section ?? "" }).map { "\($0.key) \($0.value.count)" }.sorted().joined(separator: ", ")
                print("Human runs: \(p.humanRuns.count) (\(counts)) · open \(p.humanRuns.filter { !$0.status.isTerminal }.count): " + p.humanRuns.filter { !$0.status.isTerminal }.prefix(6).map { "\($0.label) [\($0.status.raw)]" }.joined(separator: ", "))
            }
            for w in p.warnings { print("warning: \(w)") }
            exit(0)
        } catch {
            print("error: \(error.localizedDescription)")
            exit(1)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // When run unbundled (`swift run`) the process starts as a background app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Routes Find menu commands to the document's text view, wherever focus is.
@MainActor
enum DocumentFind {
    static func perform(_ action: NSTextFinder.Action) {
        guard let window = NSApp.keyWindow, let textView = firstTextView(in: window.contentView) else { return }
        window.makeFirstResponder(textView)
        let item = NSMenuItem()
        item.tag = action.rawValue
        textView.performFindPanelAction(item)
    }

    private static func firstTextView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let tv = view as? NSTextView, !tv.isEditable { return tv }
        for sub in view.subviews { if let tv = firstTextView(in: sub) { return tv } }
        return nil
    }
}
