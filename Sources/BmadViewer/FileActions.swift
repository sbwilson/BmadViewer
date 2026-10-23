import AppKit
import SwiftUI

/// Opening files the way Finder does: the default app on click, any capable
/// app from "Open With".
@MainActor
enum FileActions {
    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    static func open(_ url: URL, with app: URL) {
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func copyPath(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.isFileURL ? url.path(percentEncoded: false) : url.absoluteString, forType: .string)
    }

    static func defaultApplication(for url: URL) -> URL? {
        NSWorkspace.shared.urlForApplication(toOpen: url)
    }

    /// Every app that claims the file's type, default first, then by name.
    static func applications(for url: URL) -> [URL] {
        let all = NSWorkspace.shared.urlsForApplications(toOpen: url)
        let def = defaultApplication(for: url)
        let rest = all.filter { $0 != def }.sorted { displayName($0).localizedCaseInsensitiveCompare(displayName($1)) == .orderedAscending }
        return (def.map { [$0] } ?? []) + rest
    }

    static func displayName(_ app: URL) -> String {
        FileManager.default.displayName(atPath: app.path(percentEncoded: false))
            .replacingOccurrences(of: ".app", with: "")
    }

    static func icon(_ app: URL, size: CGFloat = 16) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: app.path(percentEncoded: false))
        image.size = NSSize(width: size, height: size)
        return image
    }

    static func chooseApplication(for url: URL) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(filePath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Open"
        panel.message = "Choose an application to open \(url.lastPathComponent)"
        if panel.runModal() == .OK, let app = panel.url { open(url, with: app) }
    }

    // MARK: AppKit menus (document view)

    static func openWithMenu(for url: URL) -> NSMenu {
        let menu = NSMenu(title: "Open With")
        let apps = applications(for: url)
        let def = defaultApplication(for: url)
        for app in apps {
            let title = displayName(app) + (app == def ? " (default)" : "")
            menu.addItem(ClosureMenuItem(title, image: icon(app)) { open(url, with: app) })
            if app == def, apps.count > 1 { menu.addItem(.separator()) }
        }
        if url.isFileURL {
            if !apps.isEmpty { menu.addItem(.separator()) }
            menu.addItem(ClosureMenuItem("Other…") { chooseApplication(for: url) })
        }
        return menu
    }

    /// Items for a link's context menu. `showInViewer` is offered for markdown.
    static func linkMenuItems(for url: URL, showInViewer: ((URL) -> Void)?) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        items.append(ClosureMenuItem(url.isFileURL ? "Open" : "Open in Browser") { open(url) })
        let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        openWith.submenu = openWithMenu(for: url)
        items.append(openWith)
        if url.isFileURL {
            if url.pathExtension.lowercased() == "md", let showInViewer {
                items.append(ClosureMenuItem("Show in BMAD Viewer") { showInViewer(url) })
            }
            items.append(ClosureMenuItem("Reveal in Finder") { reveal(url) })
            items.append(ClosureMenuItem("Copy Path") { copyPath(url) })
        } else {
            items.append(ClosureMenuItem("Copy Link") { copyPath(url) })
        }
        return items
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, image: NSImage? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        self.image = image
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}

// MARK: SwiftUI menus (headers, lists)

/// The same actions as the document view's link menu, for SwiftUI `.contextMenu`.
struct FileContextMenu: View {
    let url: URL
    var showInViewer: ((URL) -> Void)?

    var body: some View {
        Button("Open") { FileActions.open(url) }
        Menu("Open With") {
            let apps = FileActions.applications(for: url)
            let def = FileActions.defaultApplication(for: url)
            ForEach(apps, id: \.self) { app in
                Button {
                    FileActions.open(url, with: app)
                } label: {
                    Label {
                        Text(FileActions.displayName(app) + (app == def ? " (default)" : ""))
                    } icon: {
                        Image(nsImage: FileActions.icon(app))
                    }
                }
                if app == def, apps.count > 1 { Divider() }
            }
            Divider()
            Button("Other…") { FileActions.chooseApplication(for: url) }
        }
        if url.pathExtension.lowercased() == "md", let showInViewer {
            Button("Show in BMAD Viewer") { showInViewer(url) }
        }
        Divider()
        Button("Reveal in Finder") { FileActions.reveal(url) }
        Button("Copy Path") { FileActions.copyPath(url) }
    }
}

/// A file name that opens in its default app on click and offers Open With on right-click.
struct FileLink: View {
    let url: URL
    var label: String?
    var showInViewer: ((URL) -> Void)?

    var body: some View {
        Button {
            FileActions.open(url)
        } label: {
            Label(label ?? url.lastPathComponent, systemImage: "doc.text")
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .buttonStyle(.link)
        .help(url.path(percentEncoded: false))
        .contextMenu { FileContextMenu(url: url, showInViewer: showInViewer) }
    }
}
