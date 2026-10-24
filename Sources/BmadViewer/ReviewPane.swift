import BmadKit
import SwiftUI

/// One thing to look at in a review: a stop from the Suggested Review Order, or a
/// file the story's range changed that no stop points at.
enum ReviewItem: Identifiable, Hashable {
    case stop(ReviewOrder.Stop, group: String)
    case file(GitDiff.FileChange)

    var id: String {
        switch self {
        case .stop(let s, _): "stop:\(s.id)"
        case .file(let f): "file:\(f.path)"
        }
    }
}

/// What the story changed, loaded off the main thread.
struct ReviewChanges: Equatable {
    let range: GitDiff.Range
    let files: [GitDiff.FileChange]

    var additions: Int { files.compactMap(\.additions).reduce(0, +) }
    var deletions: Int { files.compactMap(\.deletions).reduce(0, +) }

    func change(for url: URL) -> GitDiff.FileChange? {
        let rel = GitDiff.relativePath(url, in: range.repository)
        return files.first { $0.path == rel }
    }

    /// The stop's file in this range: at its path today, or, for a file that has
    /// moved since, at the path the review linked (where it lived back then).
    func change(for stop: ReviewOrder.Stop, projectRoot: URL) -> GitDiff.FileChange? {
        if let url = stop.url, let c = change(for: url) { return c }
        return stop.movedFrom.flatMap { change(for: projectRoot.appending(path: $0)) }
    }

    func paths(of stop: ReviewOrder.Stop, projectRoot: URL) -> [String] {
        [stop.url, stop.movedFrom.map { projectRoot.appending(path: $0) }].compactMap { $0 }
            .map { GitDiff.relativePath($0, in: range.repository) }
    }
}

/// A story's review: its stops (and the other files it changed) on the left; the
/// selected one on the right as a diff of the story's range or the file itself;
/// and below, the way to mark the review complete.
struct ReviewPaneView: View {
    @Environment(ProjectStore.self) private var store
    let story: Story
    let project: Project

    @State private var changes: Result<ReviewChanges, Error>?

    var body: some View {
        let end = store.reviewEnd[story.id] ?? .story
        let loaded = try? changes?.get()
        let groups = itemGroups(loaded)
        let items = groups.flatMap(\.items)
        let selection = Binding<String?>(
            get: { store.reviewSelection[story.id] ?? items.first?.id },
            set: { store.reviewSelection[story.id] = $0 }
        )
        let selected = items.first { $0.id == selection.wrappedValue }
        VStack(spacing: 0) {
            RangeBar(story: story, end: end, changes: changes) { store.reviewEnd[story.id] = $0 }
            Divider()
            HSplitView {
                List(selection: selection) {
                    ForEach(groups, id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.items) { ReviewItemRow(item: $0, changes: loaded, projectRoot: project.root).tag(Optional($0.id)) }
                        }
                    }
                }
                .frame(minWidth: 240, idealWidth: 330, maxWidth: 560)
                .overlay {
                    if items.isEmpty {
                        ContentUnavailableView(changes == nil && story.baseline != nil ? "Reading the story's changes…" : "Nothing to review",
                                               systemImage: "doc.text.magnifyingglass")
                    }
                }

                Group {
                    if let selected {
                        ReviewItemDetail(item: selected, position: (items.firstIndex(of: selected) ?? 0) + 1, count: items.count,
                                         changes: loaded, project: project,
                                         step: { move($0, from: selected, in: items, selection: selection) })
                            .id("\(selected.id)#\(loaded?.range.label ?? "")")
                    } else {
                        ContentUnavailableView("Choose a stop", systemImage: "list.bullet.indent")
                    }
                }
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            }
            if case .failure(.unsupportedLayout) = ReviewCompletion.edits(for: story, in: project) {
                // Marking done is a sprint-status.yaml edit; ticket-tree reviews only read.
            } else {
                Divider()
                ReviewCompletionBar(story: story, project: project)
            }
        }
        .task(id: "\(story.id)#\(end.rawValue)#\(store.lastLoaded?.timeIntervalSince1970 ?? 0)") { await load(end) }
    }

    private func load(_ end: GitDiff.End) async {
        guard let baseline = story.baseline else { changes = nil; return }
        let document = story.primaryFile
        let root = project.root
        let result = await Task.detached(priority: .userInitiated) {
            Result<ReviewChanges, Error> {
                let range = try GitDiff.range(baseline: baseline, end: end, document: document, projectRoot: root)
                return ReviewChanges(range: range, files: try GitDiff.changedFiles(in: range))
            }
        }.value
        changes = result
    }

    struct ItemGroup { let title: String; let items: [ReviewItem] }

    /// The review order's concerns, then the files it changed that no stop names.
    private func itemGroups(_ changes: ReviewChanges?) -> [ItemGroup] {
        var groups: [ItemGroup] = (story.review?.groups ?? []).map { g in
            ItemGroup(title: g.title, items: g.stops.map { .stop($0, group: g.title) })
        }
        if let changes {
            let named = Set((story.review?.stops ?? []).flatMap { changes.paths(of: $0, projectRoot: project.root) })
            let rest = changes.files.filter { !named.contains($0.path) }.sorted { $0.path < $1.path }
            if !rest.isEmpty {
                groups.append(ItemGroup(title: story.review == nil ? "Changed files" : "Other changed files", items: rest.map { .file($0) }))
            }
        }
        return groups
    }

    private func move(_ delta: Int, from item: ReviewItem, in items: [ReviewItem], selection: Binding<String?>) {
        guard let i = items.firstIndex(of: item) else { return }
        selection.wrappedValue = items[min(max(i + delta, 0), items.count - 1)].id
    }
}

/// The range being reviewed, how it was chosen, and what it changed.
private struct RangeBar: View {
    let story: Story
    let end: GitDiff.End
    let changes: Result<ReviewChanges, Error>?
    let choose: @MainActor (GitDiff.End) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
            if story.baseline == nil {
                Text("No baseline recorded, so there is no diff to show.").foregroundStyle(.secondary)
            } else {
                switch changes {
                case .success(let c)?:
                    Text(c.range.label).font(.callout.monospaced()).textSelection(.enabled)
                    Text("\(c.files.count) files").foregroundStyle(.secondary)
                    Text("+\(c.additions)").foregroundStyle(.green)
                    Text("−\(c.deletions)").foregroundStyle(.red)
                    if let note = c.range.note {
                        Text("· \(note)").foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    }
                case .failure(let error)?:
                    Label(error.localizedDescription, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).lineLimit(1)
                case nil:
                    ProgressView().controlSize(.small)
                    Text("Reading git…").foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Picker("Ends at", selection: Binding(get: { end }, set: { choose($0) })) {
                    ForEach(GitDiff.End.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .help("Where the reviewed range ends; it always starts at the story's baseline")
            }
            if story.baseline == nil { Spacer() }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .frame(height: 32)
    }
}

private struct ReviewItemRow: View {
    let item: ReviewItem
    let changes: ReviewChanges?
    let projectRoot: URL

    var body: some View {
        switch item {
        case .stop(let stop, _):
            VStack(alignment: .leading, spacing: 3) {
                Text(inlineMarkdown(stop.framing.isEmpty ? (stop.label ?? "") : stop.framing)).lineLimit(3)
                HStack(spacing: 4) {
                    if let label = stop.label {
                        Text(label).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    if let changes, stop.url != nil, changes.change(for: stop, projectRoot: projectRoot) == nil {
                        Text("unchanged").font(.caption).foregroundStyle(.tertiary)
                            .help("This file did not change in the reviewed range")
                    }
                    if stop.movedFrom != nil {
                        Image(systemName: "arrow.triangle.turn.up.right.diamond").font(.caption).foregroundStyle(.orange)
                            .help("Moved since the review was written")
                    } else if !stop.exists {
                        Image(systemName: "questionmark.folder").font(.caption).foregroundStyle(.red)
                            .help("This file no longer exists")
                    }
                }
            }
            .padding(.vertical, 2)
        case .file(let f):
            HStack(spacing: 6) {
                Text(String(f.status))
                    .font(.caption.monospaced().weight(.bold))
                    .foregroundStyle(statusColor(f.status))
                    .frame(width: 12)
                VStack(alignment: .leading, spacing: 1) {
                    Text((f.path as NSString).lastPathComponent).lineLimit(1)
                    Text((f.path as NSString).deletingLastPathComponent)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                Spacer(minLength: 4)
                if let a = f.additions, let d = f.deletions {
                    Text("+\(a)").font(.caption.monospacedDigit()).foregroundStyle(.green)
                    Text("−\(d)").font(.caption.monospacedDigit()).foregroundStyle(.red)
                } else {
                    Text("binary").font(.caption).foregroundStyle(.secondary)
                }
            }
            .help(f.oldPath.map { "\($0) → \(f.path)" } ?? f.path)
        }
    }
}

func statusColor(_ status: Character) -> Color {
    switch status {
    case "A": .green
    case "D": .red
    case "R", "C": .purple
    default: .orange
    }
}

private struct ReviewItemDetail: View {
    let item: ReviewItem
    let position: Int
    let count: Int
    let changes: ReviewChanges?
    let project: Project
    let step: (Int) -> Void

    enum Mode: String, CaseIterable { case diff = "Diff", file = "File" }
    @State private var mode: Mode?
    @State private var diff: Result<GitDiff.FileDiff, Error>?

    var body: some View {
        let target = self.target
        let change: GitDiff.FileChange? = switch item {
        case .stop(let s, _): changes?.change(for: s, projectRoot: project.root)
        case .file(let f): f
        }
        let current = mode ?? (change != nil ? .diff : .file)
        VStack(alignment: .leading, spacing: 0) {
            header(change: change, current: current)
            Divider()
            switch current {
            case .diff:
                diffBody(change: change, target: target)
            case .file:
                if let url = target.url, FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                    FileViewer(url: url, lines: target.lines, project: project)
                } else {
                    ContentUnavailableView(target.url == nil ? "No file for this stop" : "Not in the working tree",
                                           systemImage: "questionmark.folder",
                                           description: Text(target.url?.path(percentEncoded: false) ?? "The stop has no link."))
                }
            }
        }
        .task(id: change) { await loadDiff(change) }
    }

    /// The file, lines and change this item points at.
    private var target: (url: URL?, lines: LineRange?, change: GitDiff.FileChange?, framing: String?, group: String?, moved: String?) {
        switch item {
        case .stop(let s, let group):
            return (s.url, s.lines, nil, s.framing.isEmpty ? nil : s.framing, group, s.movedFrom)
        case .file(let f):
            return (changes.map { $0.range.repository.appending(path: f.path) }, nil, f, nil, nil, nil)
        }
    }

    private func header(change: GitDiff.FileChange?, current: Mode) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("\(position) of \(count)\(target.group.map { " · \($0)" } ?? "")")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Picker("View", selection: Binding(get: { current }, set: { mode = $0 })) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .disabled(change == nil)
                Button { step(-1) } label: { Image(systemName: "chevron.up") }
                    .keyboardShortcut("[", modifiers: .command)
                    .help("Previous (⌘[)")
                    .disabled(position == 1)
                Button { step(1) } label: { Image(systemName: "chevron.down") }
                    .keyboardShortcut("]", modifiers: .command)
                    .help("Next (⌘])")
                    .disabled(position == count)
            }
            .buttonStyle(.borderless)
            if let framing = target.framing {
                Text(inlineMarkdown(framing)).font(.headline).lineLimit(1...3).textSelection(.enabled)
            }
            HStack(spacing: 6) {
                if let change {
                    Text(String(change.status)).font(.caption.monospaced().weight(.bold)).foregroundStyle(statusColor(change.status))
                    Text(change.oldPath.map { "\($0) → \(change.path)" } ?? change.path)
                        .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    if let a = change.additions, let d = change.deletions {
                        Text("+\(a)").font(.caption.monospacedDigit()).foregroundStyle(.green)
                        Text("−\(d)").font(.caption.monospacedDigit()).foregroundStyle(.red)
                    }
                } else if changes != nil, target.url != nil {
                    Text("Not changed in this range: showing the file.").font(.caption).foregroundStyle(.secondary)
                }
                if let lines = target.lines {
                    Text(lines.label)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.yellow.opacity(0.25), in: Capsule())
                }
            }
            if let moved = target.moved {
                Label("Linked as \(moved); shown from where it lives now. Line numbers may have drifted.",
                      systemImage: "arrow.triangle.turn.up.right.diamond")
                    .font(.caption).foregroundStyle(.orange).lineLimit(2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder private func diffBody(change: GitDiff.FileChange?, target: (url: URL?, lines: LineRange?, change: GitDiff.FileChange?, framing: String?, group: String?, moved: String?)) -> some View {
        switch diff {
        case .success(let d)?:
            if d.isBinary {
                ContentUnavailableView("Binary file", systemImage: "doc.zipper", description: Text("git reports a binary change."))
            } else if d.isEmpty {
                ContentUnavailableView(change?.status == "R" ? "Renamed, no line changes" : "No line changes", systemImage: "equal")
            } else {
                DiffView(diff: d, url: target.url ?? URL(filePath: change?.path ?? "x"), highlight: target.lines,
                         key: "\(change?.path ?? "")#\(changes?.range.label ?? "")#\(d.hunks.count)")
            }
        case .failure(let error)?:
            ContentUnavailableView("Could not read the diff", systemImage: "exclamationmark.triangle",
                                   description: Text(error.localizedDescription))
        case nil:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The change with some context; the whole file when the stop's lines fall outside it.
    private func loadDiff(_ change: GitDiff.FileChange?) async {
        guard let change, let range = changes?.range else { diff = nil; return }
        let lines = target.lines
        diff = await Task.detached(priority: .userInitiated) {
            Result<GitDiff.FileDiff, Error> {
                let d = try GitDiff.diff(range, path: change.path, oldPath: change.oldPath, context: 6)
                if let lines, !d.isBinary, !d.isEmpty, !d.shows(lines) {
                    return try GitDiff.diff(range, path: change.path, oldPath: change.oldPath, context: nil)
                }
                return d
            }
        }.value
    }
}

/// What marking this review complete would do, and the button to do it.
struct ReviewCompletionBar: View {
    @Environment(ProjectStore.self) private var store
    let story: Story
    let project: Project
    @State private var pending: [ReviewCompletion.Edit]?
    @State private var failure: String?

    var body: some View {
        HStack(spacing: 10) {
            switch ReviewCompletion.edits(for: story, in: project) {
            case .success(let edits):
                Image(systemName: "eye").foregroundStyle(.purple)
                Text("This story is \(story.status.raw). Walk the stops, then mark the review complete.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Mark Review Complete…") { pending = edits }
                    .buttonStyle(.borderedProminent)
            case .failure(.alreadyDone):
                Label("Review complete: the story is done.", systemImage: "checkmark.seal.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
                Spacer()
            case .failure(let refusal):
                Label(refusal.localizedDescription, systemImage: refusalIcon(refusal))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .alert("Mark story \(story.number) done?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Mark Done") { complete() }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text(confirmation)
        }
        .alert("Could not mark the review complete", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) { failure = nil }
        } message: {
            Text(failure ?? "")
        }
    }

    private var confirmation: String {
        let lines = (pending ?? []).map { edit in
            "• \(edit.url.lastPathComponent):\(edit.line)\n   \(edit.before.trimmingCharacters(in: .whitespaces))\n→ \(edit.after.trimmingCharacters(in: .whitespaces))"
        }
        return lines.joined(separator: "\n") + "\n\nOnly these lines change. Nothing is committed."
    }

    private func complete() {
        guard let edits = pending else { return }
        pending = nil
        do {
            try ReviewCompletion.apply(edits)
            store.reload()
        } catch {
            failure = error.localizedDescription
        }
    }

    private func refusalIcon(_ refusal: ReviewCompletion.Refusal) -> String {
        if case .queued = refusal { return "list.number" }
        return "info.circle"
    }
}

extension ReviewOrder.Stop {
    var exists: Bool { url.map { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) } ?? false }
}
