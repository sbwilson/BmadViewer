import AppKit
import BmadKit
import SwiftUI

struct ContentView: View {
    @Environment(ProjectStore.self) private var store

    var body: some View {
        Group {
            if let project = store.project {
                ProjectView(project: project)
            } else {
                WelcomeView()
            }
        }
        // No view carries a `navigationTitle`: in a split view one takes the window
        // title for itself, which is why the project name never showed. The window
        // is titled here — the project prominent, the place within it as subtitle.
        .background(WindowTitle(title: windowTitle, subtitle: windowSubtitle))
    }

    private var windowTitle: String { store.project?.name ?? "BMAD Viewer" }

    /// Where in the project, in the same words back and forward use; the dashboard
    /// keeps the progress the title bar's subtitle used to carry.
    private var windowSubtitle: String {
        guard let project = store.project else { return "" }
        let where_ = store.describe(store.location)
        guard case .dashboard? = store.sidebar else { return where_ }
        let done = project.allStories.filter(\.status.isTerminal).count
        return "\(where_) · \(done)/\(project.allStories.count) finished"
    }
}

/// Writes the window's title and subtitle, which SwiftUI won't take from the
/// content while the `WindowGroup` carries its own title.
private struct WindowTitle: NSViewRepresentable {
    let title: String
    let subtitle: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // The view has no window until it joins the hierarchy.
        DispatchQueue.main.async { [weak view] in apply(to: view?.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        apply(to: view.window)
    }

    private func apply(to window: NSWindow?) {
        guard let window, window.title != title || window.subtitle != subtitle else { return }
        window.title = title
        window.subtitle = subtitle
    }
}

struct WelcomeView: View {
    @Environment(ProjectStore.self) private var store

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("Open a BMAD project").font(.title2)
            if store.isLoading {
                ProgressView().controlSize(.small)
            } else if let error = store.error {
                Text(error).foregroundStyle(.red).multilineTextAlignment(.center).frame(maxWidth: 420)
            }
            Button("Open Project…") { store.showOpenPanel() }
                .keyboardShortcut(.defaultAction)
            if !store.recents.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent").font(.caption).foregroundStyle(.secondary)
                    ForEach(store.recents.prefix(5), id: \.self) { url in
                        Button(url.path(percentEncoded: false)) { store.open(url) }
                            .buttonStyle(.link)
                    }
                }
                .padding(.top, 8)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ProjectView: View {
    @Environment(ProjectStore.self) private var store
    let project: Project

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            SidebarView(project: project)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 340)
        } content: {
            Group {
                switch store.sidebar {
                case .queue: QueueView(project: project)
                case .document(let url): DocumentDetailView(url: url, project: project)
                case .dashboard: DashboardView(project: project)
                case .search: SearchView(project: project)
                case .graph: GraphControlsView(project: project)
                case .burnup: BurnupControlsView(project: project)
                case .humanRuns: WorkItemListView(project: project, kind: .humanRun)
                case .retroActions: WorkItemListView(project: project, kind: .retroAction)
                case .deferredWork: WorkItemListView(project: project, kind: .deferred)
                default: StoryListView(project: project)
                }
            }
            // The dashboard's overview wants more width than a list does; the
            // cards that sit beside it in the detail column want less.
            .navigationSplitViewColumnWidth(
                min: store.sidebar == .dashboard ? 480 : 280,
                ideal: store.sidebar == .dashboard ? 640 : 360,
                max: store.sidebar == .dashboard ? 900 : 520)
        } detail: {
            if store.sidebar == .dashboard {
                DashboardCardsView(project: project)
                    .navigationSplitViewColumnWidth(min: 280, ideal: 360, max: 480)
            } else if store.sidebar == .graph {
                DependencyGraphView(project: project)
            } else if store.sidebar == .burnup {
                BurnupChartView(project: project)
            } else if store.sidebar == .search {
                if let hit = store.selectedSearchHit {
                    SearchHitDetailView(hit: hit, project: project)
                } else {
                    ContentUnavailableView("No match selected", systemImage: "text.magnifyingglass",
                                           description: Text("Choose a line to see it in its file."))
                }
            } else if store.sidebar?.workItemKind != nil {
                if let item = store.selectedWorkItem {
                    WorkItemDetailView(item: item, project: project)
                } else {
                    ContentUnavailableView("Nothing selected", systemImage: "checklist",
                                           description: Text("Choose an item to read it."))
                }
            } else if let story = store.selectedStory {
                StoryDetailView(story: story, project: project)
            } else if case .epic(let id) = store.sidebar, store.epicDocsShown == id,
                      let epic = project.epics.first(where: { $0.id == id }) {
                EpicDocumentsView(epic: epic, project: project)
            } else {
                ContentUnavailableView("No story selected", systemImage: "doc.text",
                                       description: Text("Choose a story to read its document."))
            }
        }
        .onChange(of: store.location, initial: true) { _, loc in store.record(loc) }
        .overlay(alignment: .top) {
            if store.showQuickOpen {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.12)
                        .ignoresSafeArea()
                        .onTapGesture { store.showQuickOpen = false }
                    QuickOpenPanel().padding(.top, 70)
                }
            }
        }
        .searchable(text: $store.search, placement: .sidebar, prompt: "Number or title")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { store.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                    .disabled(!store.canGoBack)
                    .help(store.canGoBack ? "Back to \(store.describe(store.history[store.historyIndex - 1])) (⌘[)" : "Back (⌘[)")
                Button { store.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                    .disabled(!store.canGoForward)
                    .help(store.canGoForward ? "Forward to \(store.describe(store.history[store.historyIndex + 1])) (⌘])" : "Forward (⌘])")
            }
            ToolbarItemGroup {
                Toggle(isOn: $store.hideFinished) {
                    Label("Hide finished", systemImage: "line.3.horizontal.decrease.circle")
                }
                .help("Hide done and superseded stories")
                Button { store.reload() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                    .help("Reload (files are also watched)")
                Button { FileActions.reveal(project.root) } label: { Label("Reveal", systemImage: "folder") }
                    .help(project.root.path(percentEncoded: false))
            }
        }
    }
}
