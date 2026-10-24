import AppKit
import BmadKit
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
        let def = defaultApplication(for: url)
        // One row per app: a second copy of an app (another Pages.app) has the same bundle id.
        var seen = Set(def.flatMap { Bundle(url: $0)?.bundleIdentifier }.map { [$0] } ?? [])
        let all = NSWorkspace.shared.urlsForApplications(toOpen: url).filter { app in
            guard app != def else { return true }
            guard let id = Bundle(url: app)?.bundleIdentifier else { return true }
            return seen.insert(id).inserted
        }
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

    /// Items for a link's context menu; "Open in Tab" first when the view has tabs.
    static func linkMenuItems(for url: URL, openInTab: (() -> Void)?) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if url.isFileURL, let openInTab { items.append(ClosureMenuItem("Open in Tab", handler: openInTab)) }
        items.append(ClosureMenuItem(url.isFileURL ? openTitle(url) : "Open in Browser") { open(url) })
        let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        openWith.submenu = openWithMenu(for: url)
        items.append(openWith)
        if url.isFileURL {
            items.append(ClosureMenuItem("Reveal in Finder") { reveal(url) })
            items.append(ClosureMenuItem("Copy Path") { copyPath(url) })
        } else {
            items.append(ClosureMenuItem("Copy Link") { copyPath(url) })
        }
        return items
    }

    /// "Open in TextMate", naming the default app, or plain "Open".
    static func openTitle(_ url: URL) -> String {
        defaultApplication(for: url).map { "Open in \(displayName($0))" } ?? "Open"
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
    var openInTab: (() -> Void)?

    var body: some View {
        if let openInTab { Button("Open in Tab", action: openInTab) }
        Button(FileActions.openTitle(url)) { FileActions.open(url) }
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
        Divider()
        Button("Reveal in Finder") { FileActions.reveal(url) }
        Button("Copy Path") { FileActions.copyPath(url) }
    }
}

/// A file name. Inside a tabbed view a click opens it in a tab; elsewhere in its
/// default app. Right-click offers both, Open With, Reveal and Copy Path.
struct FileLink: View {
    @Environment(\.openDocument) private var openDocument
    let url: URL
    var label: String?
    var lines: LineRange?

    var body: some View {
        Button {
            if let openDocument { openDocument(url, lines) } else { FileActions.open(url) }
        } label: {
            Label(label ?? url.lastPathComponent, systemImage: FileKind.of(url).icon)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .buttonStyle(.link)
        .help(url.path(percentEncoded: false))
        .contextMenu { FileContextMenu(url: url, openInTab: openDocument.map { open in { open(url, lines) } }) }
    }
}
