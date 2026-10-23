import AppKit
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
