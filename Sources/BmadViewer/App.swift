import AppKit
import BmadKit
import SwiftUI

@main
struct BmadViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = ProjectStore()

    var body: some Scene {
        Window("BMAD Viewer", id: "main") {
            ContentView()
                .environment(store)
                .frame(minWidth: 900, minHeight: 560)
                .task { openInitialProject() }
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Project…") { store.showOpenPanel() }
                    .keyboardShortcut("o")
                Menu("Open Recent") {
                    ForEach(store.recents, id: \.self) { url in
                        Button(url.path(percentEncoded: false)) { store.open(url) }
                    }
                }
            }
            CommandMenu("Go") {
                Button("Quick Open…") { store.showQuickOpen.toggle() }
                    .keyboardShortcut("k")
                    .disabled(store.project == nil)
                Button("Quick Open… ") { store.showQuickOpen.toggle() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(store.project == nil)
            }
            CommandGroup(after: .toolbar) {
                Button("Reload") { store.reload() }
                    .keyboardShortcut("r")
                    .disabled(store.project == nil)
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
    }

    /// A path argument wins (handy from a terminal: `BmadViewer ~/dev/Qubric`),
    /// then the most recent project.
    private func openInitialProject() {
        guard store.project == nil else { return }
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        if let path = args.first {
            store.open(URL(filePath: NSString(string: path).expandingTildeInPath))
        } else if let recent = store.recents.first {
            store.open(recent)
        }
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
