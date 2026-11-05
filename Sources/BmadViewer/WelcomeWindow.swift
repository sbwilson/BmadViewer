import AppKit
import SwiftUI

/// The window the app falls back to when nothing is open: the folders it has
/// read lately, and the way into any other.
///
/// It is the app's front door twice over. Closing a project window hands over
/// to this one; closing this one ends the app, which is why
/// `applicationShouldTerminateAfterLastWindowClosed` says no and lets
/// `WindowRouter` decide — AppKit cannot tell the two kinds of window apart.
struct WelcomeWindowView: View {
    @Environment(\.openWindow) private var openWindow
    @State private var recents = WelcomeRecents()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // The window has no title bar of its own: the traffic lights float
            // over the content, which needs the room.
            Spacer(minLength: 26)
            header
            recentList
            Spacer(minLength: 0)
            Text("Right-click a folder to show it in Finder or drop it from this list.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 26)
        .padding(.bottom, 22)
        .frame(minWidth: 580, minHeight: 440, alignment: .topLeading)
        .background(VisualEffectBackdrop(material: .sidebar))
        .background(WindowRole(.welcome))
        .onAppear { recents.refresh() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 68, height: 68)
            VStack(alignment: .leading, spacing: 3) {
                Text("BMAD Viewer").font(.largeTitle.weight(.bold))
                Text("Pick a project to read its stories, queue and review order.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            Button("Open Project…") { ProjectPicker.present { openWindow(value: $0) } }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .fixedSize()
                .keyboardShortcut(.defaultAction)
        }
    }

    /// A card rather than a bare list: on this window the rows are the whole
    /// point, so they get a surface of their own.
    private var recentList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if recents.items.isEmpty {
                ContentUnavailableView {
                    Label("No recent projects", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("A folder you have opened appears here.")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(recents.items) { item in
                            RecentProjectRow(item: item) { openWindow(value: item.url) }
                                .contextMenu {
                                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                                    Button("Remove from This List") { recents.remove(item) }
                                }
                        }
                    }
                    .padding(6)
                }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.separator, lineWidth: 1)
        )
    }
}

/// One folder in the welcome window's list: what it is called, where it is, and
/// — when the folder has gone walkabout since — why it cannot be opened.
struct RecentProjectRow: View {
    let item: RecentProject
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(nsImage: item.icon)
                    .resizable()
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.url.lastPathComponent).font(.body.weight(.medium))
                    Text(item.container)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if item.exists {
                    if hovering {
                        Image(systemName: "arrow.up.forward")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    Text("not found")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering && item.exists ? Color.primary.opacity(0.07)
                                                : Color.primary.opacity(0),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!item.exists)
        .onHover { hovering = $0 }
        .help(item.url.path(percentEncoded: false))
    }
}

/// The recent folders as the welcome window sees them, read again every time it
/// is shown: projects are opened, moved and deleted while it is out of sight.
@MainActor
@Observable
final class WelcomeRecents {
    private(set) var items: [RecentProject] = []

    func refresh() { items = ProjectStore.recentProjects.map(RecentProject.init) }

    func remove(_ item: RecentProject) {
        ProjectStore.forget(item.url)
        refresh()
    }
}

/// A recent folder, with what the row needs to know about the disk.
struct RecentProject: Identifiable, Hashable {
    let url: URL
    let exists: Bool

    init(url: URL) {
        self.url = url
        exists = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    var id: String { url.path }

    /// The folder's own icon, badges and all — a project folder with a git mark
    /// on it says more about itself than the app could.
    var icon: NSImage {
        if exists { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSImage(systemSymbolName: "folder.badge.questionmark", accessibilityDescription: "missing folder")
            ?? NSWorkspace.shared.icon(forFile: "/" )
    }

    var container: String { url.deletingLastPathComponent().path(percentEncoded: false) }
}

/// Which windows this app has, and what closing one of them means: the last
/// project window hands over to the welcome window, and the welcome window
/// going is the app going.
@MainActor
final class WindowRouter: NSObject {
    static let shared = WindowRouter()

    /// The welcome scene's id, as the `Window` in `BmadViewerApp` declares it.
    static let welcomeScene = "welcome"

    /// `openWindow`, captured from the menu commands: AppKit cannot ask SwiftUI
    /// for a scene by id, so it borrows the environment value. Commands are
    /// alive for as long as the menu bar is, which is the whole of the app.
    private var opener: OpenWindowAction?
    private weak var welcome: NSWindow?
    private let projects = NSHashTable<NSWindow>.weakObjects()
    private var terminating = false

    func capture(_ opener: OpenWindowAction) { self.opener = opener }

    /// The project windows still around. `allObjects`, not `count`: a weak table
    /// keeps a slot until it is next touched.
    private var openProjects: [NSWindow] { projects.allObjects }

    /// A project window has appeared, so the welcome window steps aside. It is
    /// ordered out rather than closed: closing it is what ends the app.
    func projectWindowDidAppear(_ window: NSWindow) {
        guard !projects.contains(window) else { return }
        projects.add(window)
        welcome?.orderOut(nil)
    }

    /// The welcome window's content, tagged by itself: the router needs the
    /// window to raise and hide it, and it is a fallback rather than something
    /// worth restoring — a launch either has projects to show or shows nothing.
    func welcomeWindowDidAppear(_ window: NSWindow) {
        guard welcome !== window else { return }
        window.isRestorable = false
        window.tabbingMode = .disallowed
        // Vibrancy needs a window that is not painted first.
        window.isOpaque = false
        window.backgroundColor = .clear
        welcome = window
    }

    func showWelcome() {
        if let welcome {
            welcome.makeKeyAndOrderFront(nil)
        } else {
            opener?(id: Self.welcomeScene)
        }
        NSApp.activate()
    }

    /// Called once at launch: everything else is reaction to windows going away.
    func startWatching() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowWillClose(_:)),
                           name: NSWindow.willCloseNotification, object: nil)
        center.addObserver(self, selector: #selector(appWillTerminate),
                           name: NSApplication.willTerminateNotification, object: nil)
    }

    @objc private func windowWillClose(_ note: Notification) {
        guard !terminating, let window = note.object as? NSWindow else { return }
        if window === welcome {
            welcome = nil
            // Nothing to come back to: the welcome window is the last word.
            if openProjects.isEmpty { NSApp.terminate(nil) }
            return
        }
        guard projects.contains(window) else { return }
        projects.remove(window)
        guard openProjects.isEmpty else { return }
        // Next turn round the loop: this window is still being torn down, and a
        // scene asked for in the middle of that is not reliable.
        DispatchQueue.main.async { [weak self] in self?.showWelcome() }
    }

    @objc private func appWillTerminate() { terminating = true }
}

/// Hands the window this view lives in to `WindowRouter`. A view has no window
/// until it joins the hierarchy, so the first report is a step behind;
/// `updateNSView` catches up either way.
struct WindowRole: NSViewRepresentable {
    enum Kind { case project, welcome }
    let kind: Kind

    init(_ kind: Kind) { self.kind = kind }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { [weak view] in report(to: view?.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { report(to: view.window) }

    private func report(to window: NSWindow?) {
        guard let window else { return }
        switch kind {
        case .project: WindowRouter.shared.projectWindowDidAppear(window)
        case .welcome: WindowRouter.shared.welcomeWindowDidAppear(window)
        }
    }
}

/// The welcome window's backdrop: the desktop, blurred. The window itself is
/// painted nothing at all (see `WindowRouter`), so this is the only thing
/// between the content and the black the window server keeps underneath.
struct VisualEffectBackdrop: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) { view.material = material }
}

/// The "which folder?" panel, shared by the menu's Open Project… and the
/// welcome window's button.
enum ProjectPicker {
    @MainActor static func present(_ open: (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Open Project"
        panel.message = "Choose a folder containing a BMAD project"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }
}
