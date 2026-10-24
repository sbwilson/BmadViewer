import BmadKit
import SwiftUI

/// A story's Suggested Review Order as a walkthrough: the stops on the left, the
/// selected stop's file on the right at its line, and below, the way to mark the
/// review complete.
struct ReviewPaneView: View {
    @Environment(ProjectStore.self) private var store
    let story: Story
    let review: ReviewOrder
    let project: Project

    var body: some View {
        let selection = Binding<Int?>(
            get: { store.reviewStop[story.id] ?? review.stops.first?.id },
            set: { store.reviewStop[story.id] = $0 }
        )
        let stop = review.stops.first { $0.id == selection.wrappedValue }
        VStack(spacing: 0) {
            HSplitView {
                List(selection: selection) {
                    ForEach(review.groups) { group in
                        Section(group.title) {
                            ForEach(group.stops) { ReviewStopRow(stop: $0).tag(Optional($0.id)) }
                        }
                    }
                }
                .frame(minWidth: 240, idealWidth: 330, maxWidth: 560)

                Group {
                    if let stop {
                        ReviewStopDetail(stop: stop, group: review.groups.first { $0.stops.contains(stop) }?.title,
                                         position: (review.stops.firstIndex(of: stop) ?? 0) + 1, count: review.stops.count,
                                         project: project,
                                         step: { move($0, from: stop, selection: selection) })
                            .id(stop.id)
                    } else {
                        ContentUnavailableView("Choose a stop", systemImage: "list.bullet.indent")
                    }
                }
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            ReviewCompletionBar(story: story, project: project)
        }
    }

    private func move(_ delta: Int, from stop: ReviewOrder.Stop, selection: Binding<Int?>) {
        let stops = review.stops
        guard let i = stops.firstIndex(of: stop) else { return }
        let j = min(max(i + delta, 0), stops.count - 1)
        selection.wrappedValue = stops[j].id
    }
}

private struct ReviewStopRow: View {
    let stop: ReviewOrder.Stop

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(inlineMarkdown(stop.framing.isEmpty ? (stop.label ?? "") : stop.framing))
                .lineLimit(3)
            HStack(spacing: 4) {
                if let label = stop.label {
                    Text(label).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
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
    }
}

private struct ReviewStopDetail: View {
    let stop: ReviewOrder.Stop
    let group: String?
    let position: Int
    let count: Int
    let project: Project
    let step: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Stop \(position) of \(count)\(group.map { " · \($0)" } ?? "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button { step(-1) } label: { Image(systemName: "chevron.up") }
                        .keyboardShortcut("[", modifiers: .command)
                        .help("Previous stop (⌘[)")
                        .disabled(position == 1)
                    Button { step(1) } label: { Image(systemName: "chevron.down") }
                        .keyboardShortcut("]", modifiers: .command)
                        .help("Next stop (⌘])")
                        .disabled(position == count)
                }
                .buttonStyle(.borderless)
                if !stop.framing.isEmpty {
                    Text(inlineMarkdown(stop.framing))
                        .font(.headline)
                        .lineLimit(1...3)
                        .textSelection(.enabled)
                }
                if let moved = stop.movedFrom {
                    Label("Linked as \(moved); shown from where it lives now. Line numbers may have drifted.",
                          systemImage: "arrow.triangle.turn.up.right.diamond")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            if let url = stop.url, stop.exists {
                FileViewer(url: url, lines: stop.lines, project: project)
            } else {
                ContentUnavailableView(
                    stop.url == nil ? "No file for this stop" : "No longer at this path",
                    systemImage: "questionmark.folder",
                    description: Text(stop.url.map { $0.path(percentEncoded: false) } ?? "The stop has no link.")
                )
            }
        }
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
