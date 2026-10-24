import BmadKit
import SwiftUI

/// Find in Project: the query and its options, then every matching line, grouped by file.
struct SearchView: View {
    @Environment(ProjectStore.self) private var store
    let project: Project
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find in project", text: $store.searchQuery)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .onSubmit { store.searchOptions = store.searchOptions }
                    if store.searching { ProgressView().controlSize(.small) }
                    option("textformat", "Match case", $store.searchOptions.caseSensitive)
                    option("w.square", "Whole word", $store.searchOptions.wholeWord)
                    option("asterisk", "Regular expression", $store.searchOptions.regex)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                Picker("Scope", selection: $store.searchOptions.scope) {
                    ForEach(TextSearch.Scope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                summary
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            Divider()
            results
        }
        .navigationTitle("Find in Project")
        .onAppear { focused = true }
        .onChange(of: store.focusSearch) { focused = true }
    }

    private func option(_ icon: String, _ help: String, _ on: Binding<Bool>) -> some View {
        Toggle(isOn: on) { Image(systemName: icon) }
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .help(help)
    }

    @ViewBuilder private var summary: some View {
        switch store.searchOutcome {
        case .success(let o)?:
            Text("\(o.matchCount) matches in \(o.files.count) files\(o.truncated ? " (stopped at \(o.matchCount); narrow the search)" : "") · \(String(format: "%.2f", store.searchDuration)) s")
        case .failure(let error)?:
            Text(error.localizedDescription).foregroundStyle(.orange)
        case nil:
            Text(store.searchOptions.scope == .artifacts
                 ? "Searches \(TextSearch.artifactFolders(project).map(\.lastPathComponent).joined(separator: ", "))."
                 : "Searches every file git lists in the project.")
        }
    }

    @ViewBuilder private var results: some View {
        @Bindable var store = store
        if case .success(let o)? = store.searchOutcome, !o.files.isEmpty {
            List(selection: $store.selectedSearchHit) {
                ForEach(o.files) { file in
                    Section {
                        ForEach(file.matches) { match in
                            SearchHitRow(match: match, item: store.workItem(at: file.url, line: match.line))
                                .tag(Optional("\(file.path)#\(match.line)"))
                        }
                    } header: {
                        SearchFileHeader(file: file, story: store.story(documentedAt: file.url))
                    }
                }
            }
        } else {
            ContentUnavailableView(store.searchQuery.isEmpty ? "Search the project" : store.searching ? "Searching…" : "No matches",
                                   systemImage: "text.magnifyingglass")
        }
    }
}

private struct SearchFileHeader: View {
    let file: TextSearch.FileMatches
    let story: Story?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: FileKind.of(file.url).icon).foregroundStyle(.secondary)
            Text((file.path as NSString).lastPathComponent).fontWeight(.semibold)
            Text((file.path as NSString).deletingLastPathComponent)
                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 4)
            if let story {
                Text("Story \(story.number)").font(.caption.weight(.medium)).foregroundStyle(.blue)
            }
            Text("\(file.matches.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .textCase(nil)
        .contextMenu { FileContextMenu(url: file.url) }
    }
}

private struct SearchHitRow: View {
    let match: TextSearch.Match
    let item: WorkItem?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(match.line)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(minWidth: 34, alignment: .trailing)
            Text(highlighted)
                .font(.callout.monospaced())
                .lineLimit(2)
            Spacer(minLength: 0)
            if let item {
                Text(item.label).font(.caption.weight(.medium)).foregroundStyle(.purple)
            }
        }
    }

    private var highlighted: AttributedString {
        let ns = match.preview as NSString
        var out = AttributedString()
        var cursor = 0
        for r in match.ranges where r.location >= cursor {
            out += AttributedString(ns.substring(with: NSRange(location: cursor, length: r.location - cursor)))
            var hit = AttributedString(ns.substring(with: r))
            hit.backgroundColor = Color.yellow.opacity(0.45)
            hit.foregroundColor = .primary
            out += hit
            cursor = NSMaxRange(r)
        }
        out += AttributedString(ns.substring(from: cursor))
        return out
    }
}

/// The selected match: its file at the line, with a way to the story or entry it belongs to.
struct SearchHitDetailView: View {
    @Environment(ProjectStore.self) private var store
    let hit: String
    let project: Project

    var body: some View {
        if let hash = hit.lastIndex(of: "#"), let line = Int(hit[hit.index(after: hash)...]) {
            let url = project.root.appending(path: String(hit[..<hash]))
            let story = store.story(documentedAt: url)
            let item = store.workItem(at: url, line: line)
            VStack(spacing: 0) {
                if story != nil || item != nil {
                    HStack(spacing: 12) {
                        if let story {
                            Button { store.select(storyNumber: story.number) } label: {
                                Label("Story \(story.number): \(story.title)", systemImage: "doc.text").lineLimit(1)
                            }
                        }
                        if let item {
                            Button {
                                store.sidebar = .deferredWork
                                store.selectedWorkItemID = item.id
                            } label: {
                                Label("\(item.label): \(item.title)", systemImage: "tray.and.arrow.down").lineLimit(1)
                            }
                        }
                        Spacer()
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    Divider()
                }
                FileViewer(url: url, lines: LineRange(line), project: project)
                    .id(hit)
            }
        }
    }
}
