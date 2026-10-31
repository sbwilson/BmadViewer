import AppKit
import BmadKit
import SwiftUI

/// The About window's release notes: GitHub Releases is the source of truth,
/// so the list is fetched from the API and cached on disk — the window opens
/// instantly from the cache and the network replaces it when it answers.
@MainActor
@Observable
final class ReleaseNotesModel {
    static let repoURL = URL(string: "https://github.com/sbwilson/BmadViewer")!
    private static let apiURL = URL(string: "https://api.github.com/repos/sbwilson/BmadViewer/releases")!

    private(set) var releases: [Release] = []
    /// When the notes last came from GitHub; a cache read shows the file's own date.
    private(set) var refreshedAt: Date?
    private(set) var fromCache = false
    private(set) var isBusy = false
    /// A failed refresh keeps whatever is on screen and says so here.
    private(set) var error: String?

    func load() {
        guard releases.isEmpty, refreshedAt == nil else { return }
        readCache()
        refresh()
    }

    func refresh() { Task { await fetch() } }

    var caption: String? {
        guard let refreshedAt else { return nil }
        let ago = refreshedAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
        return fromCache ? "cached copy, saved \(ago)" : "synced with GitHub \(ago)"
    }

    /// GitHub could not be reached this time; the list on screen is the cache.
    var isStale: Bool { error != nil && fromCache }

    private var cacheFile: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "net.xeosdd.BmadViewer/release-notes.json")
    }

    private func readCache() {
        guard let data = try? Data(contentsOf: cacheFile),
              let list = try? ReleaseNotes.releases(from: data) else { return }
        releases = list
        refreshedAt = (try? cacheFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        fromCache = true
    }

    private func fetch() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        var request = URLRequest(url: Self.apiURL)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("BmadViewer", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 else {
                throw NSError(domain: "BmadViewer", code: status,
                              userInfo: [NSLocalizedDescriptionKey: "GitHub replied \(status)."])
            }
            releases = try ReleaseNotes.releases(from: data)
            refreshedAt = Date()
            fromCache = false
            error = nil
            try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: cacheFile)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// The app's own window: who made it, which version this is, where the code
/// lives, and the release notes synced from GitHub Releases.
struct AboutView: View {
    @Environment(\.openURL) private var openURL
    @State private var notes = ReleaseNotesModel()

    static var shortVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0" }
    static var build: String? { Bundle.main.infoDictionary?["CFBundleVersion"] as? String }
    /// A bare `swift run` binary carries no release identity; then no release is
    /// marked "this version" against it.
    static var currentVersion: String? { Bundle.main.bundleURL.pathExtension == "app" ? shortVersion : nil }

    var body: some View {
        VStack(spacing: 0) {
            hero
            Divider()
            notesHeader
            notesBody
            Divider()
            footer
        }
        .frame(minWidth: 580, minHeight: 520)
        .task { notes.load() }
    }

    private var hero: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 108, height: 108)
            Text("BMAD Viewer").font(.largeTitle.weight(.bold))
            Text("A simple macOS viewer for BMAD Method projects — v6 sprint-status boards and v7 ticket trees, read as the tools write them.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 440)
            HStack(spacing: 8) {
                Text("Version \(Self.shortVersion)")
                    .font(.callout.weight(.medium).monospacedDigit())
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                if let build = Self.build, build != Self.shortVersion {
                    Text("build \(build)").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                Text("Developed by").font(.callout).foregroundStyle(.secondary)
                Button("Simon Wilson") { openURL(URL(string: "https://github.com/sbwilson")!) }
                    .buttonStyle(.link)
                Text("·").foregroundStyle(.tertiary)
                Button("simon@xeosdd.net") { openURL(URL(string: "mailto:simon@xeosdd.net")!) }
                    .buttonStyle(.link)
            }
            .font(.callout)
            HStack(spacing: 12) {
                Button { openURL(ReleaseNotesModel.repoURL) } label: {
                    Label("GitHub repository", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Button { openURL(ReleaseNotesModel.repoURL.appending(path: "releases")) } label: {
                    Label("All releases", systemImage: "list.bullet.rectangle")
                }
                Button { openURL(ReleaseNotesModel.repoURL.appending(path: "issues")) } label: {
                    Label("Report an issue", systemImage: "exclamationmark.bubble")
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 32)
        .padding(.top, 30)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity)
        .background(LinearGradient(colors: [Color.accentColor.opacity(0.10), .clear],
                                   startPoint: .top, endPoint: .bottom))
    }

    private var notesHeader: some View {
        HStack(spacing: 8) {
            Text("Release notes").font(.headline)
            Spacer()
            if let caption = notes.caption {
                Text(notes.isStale ? "GitHub not reached — \(caption)" : caption)
                    .font(.caption)
                    .foregroundStyle(notes.isStale ? .orange : .secondary)
            }
            if notes.isBusy { ProgressView().controlSize(.small) }
            Button { notes.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Check GitHub Releases for updates")
                .disabled(notes.isBusy)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var notesBody: some View {
        if notes.releases.isEmpty {
            VStack(spacing: 12) {
                if notes.isBusy {
                    ProgressView("Loading release notes from GitHub…").padding(.top, 40)
                } else {
                    ContentUnavailableView {
                        Label("No release notes", systemImage: "tag")
                    } description: {
                        Text(notes.error ?? "Releases published on GitHub appear here.")
                            .frame(maxWidth: 360)
                    } actions: {
                        Button("Try Again") { notes.refresh() }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // One composed document: the same renderer story files get, so the
            // notes have real links, lists and headings, and Find works on them.
            DocumentView(
                key: "releases:\(notes.releases.map(\.tagName).joined(separator: ","))",
                render: {
                    let repository = ReleaseNotesModel.repoURL
                    return MarkdownRenderer(baseURL: repository, projectRoot: repository,
                                            storyNumbers: [], bodySize: 12.5)
                        .render(ReleaseNotes.notesMarkdown(notes.releases, currentVersion: Self.currentVersion))
                },
                onStoryLink: { _ in },
                onOpenFile: nil
            )
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private var footer: some View {
        HStack {
            Text("© 2026 Simon Wilson").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("GNU GPLv3") { openURL(URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!) }
                .buttonStyle(.link).font(.caption)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
}
