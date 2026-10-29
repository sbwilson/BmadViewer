import BmadKit
import SwiftUI

/// A `tickets.toml` as a list: an epic's entries with their live status, or an
/// initiative's epics with what each needs from the others.
struct TicketsTomlView: View {
    @Environment(ProjectStore.self) private var store
    let url: URL
    let project: Project

    var body: some View {
        switch Result(catching: { try TicketsFile.load(url) }) {
        case .failure(let error):
            ContentUnavailableView("Could not read tickets.toml", systemImage: "exclamationmark.triangle",
                                   description: Text(error.localizedDescription))
        case .success(let file):
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !file.epics.isEmpty {
                        ForEach(Array(file.epics.enumerated()), id: \.element.id) { i, epic in
                            EpicTomlRow(position: i + 1, row: epic, project: project)
                            Divider()
                        }
                    }
                    let number = epicNumber
                    ForEach(Array(file.entries.enumerated()), id: \.element.id) { i, entry in
                        EntryTomlRow(position: i + 1, entry: entry, epicNumber: number, project: project)
                        Divider()
                    }
                    if file.entries.isEmpty && file.epics.isEmpty {
                        Text("No `[[entry]]` or `[[epic]]` tables.").foregroundStyle(.secondary).padding()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
        }
    }

    /// The epic this file belongs to: the folder it sits in, or the one holding `tickets/`.
    private var epicNumber: String? {
        var folder = url.deletingLastPathComponent()
        if folder.lastPathComponent == "tickets" { folder = folder.deletingLastPathComponent() }
        return project.epics.first { $0.id == folder.lastPathComponent }?.number
    }
}

private struct EntryTomlRow: View {
    @Environment(ProjectStore.self) private var store
    let position: Int
    let entry: TicketsFile.Entry
    let epicNumber: String?
    let project: Project
    @State private var expanded = false

    var body: some View {
        let number = epicNumber.map { "\($0).\(entry.id)" }
        let story = number.flatMap { project.story(number: $0) }
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(position)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(minWidth: 20, alignment: .trailing)
                Text(number ?? "#\(entry.id)")
                    .font(.callout.monospacedDigit().weight(.semibold))
                if entry.type != "story" {
                    Text(entry.type).font(.caption.weight(.medium)).foregroundStyle(entry.type == "bug" ? .red : .orange)
                }
                Button {
                    if let number { store.select(storyNumber: number) }
                } label: {
                    Text(entry.title).multilineTextAlignment(.leading)
                }
                .buttonStyle(.link)
                .disabled(story == nil)
                .help(story == nil ? "" : "Show this ticket")
                Spacer(minLength: 8)
                if let story { StatusBadge(status: story.status) }
                if let risk = entry.risk { Text("risk \(risk)").font(.caption).foregroundStyle(risk == "high" ? .orange : .secondary) }
                if entry.hitl { Image(systemName: "person.fill.questionmark").help("Human in the loop") }
                if entry.refine { Image(systemName: "wand.and.stars").help("Needs refining before it starts") }
            }
            if !entry.after.isEmpty {
                HStack(spacing: 4) {
                    Text("after").font(.caption).foregroundStyle(.secondary)
                    ForEach(entry.after, id: \.self) { ref in
                        let target = resolve(ref)
                        Button(target ?? ref) { if let target { store.select(storyNumber: target) } }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .disabled(target.flatMap { project.story(number: $0) } == nil)
                    }
                }
                .padding(.leading, 28)
            }
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 8) {
                    section("Delivers", entry.description)
                    section("Verify", entry.verify)
                    section("Unknown", entry.unknown)
                    if !entry.covers.isEmpty { section("Covers", entry.covers.joined(separator: ", ")) }
                }
                .padding(.top, 4)
            } label: {
                Text(entry.description ?? "")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(expanded ? 0 : 2)
                    .opacity(expanded ? 0 : 1)
            }
            .padding(.leading, 28)
        }
        .padding(.vertical, 10)
    }

    /// A bare id is a sibling: it takes this epic's number.
    private func resolve(_ ref: String) -> String? {
        if ref.wholeMatch(of: /[0-9A-Za-z]+/) != nil { return epicNumber.map { "\($0).\(ref)" } }
        if ref.wholeMatch(of: /[0-9A-Za-z]+\.[0-9A-Za-z]+/) != nil { return ref }
        return nil
    }

    @ViewBuilder private func section(_ title: String, _ text: String?) -> some View {
        if let text, !text.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(inlineMarkdown(text)).font(.callout).textSelection(.enabled)
            }
        }
    }
}

private struct EpicTomlRow: View {
    @Environment(ProjectStore.self) private var store
    let position: Int
    let row: TicketsFile.EpicRow
    let project: Project

    var body: some View {
        let epic = project.epics.first { $0.id == row.slug }
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(position)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(minWidth: 20, alignment: .trailing)
                Text("Epic \(row.id)").font(.callout.monospacedDigit().weight(.semibold))
                Button(row.title ?? row.slug) { store.sidebar = .epic(row.slug) }
                    .buttonStyle(.link)
                    .disabled(epic == nil)
                Spacer(minLength: 8)
                if let epic {
                    let (done, total) = epic.progress
                    Text("\(done)/\(total)\(epic.builtCount > 0 ? " · \(epic.builtCount) built" : "")")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    StatusBadge(status: epic.status)
                }
            }
            ForEach(row.after, id: \.self) { need in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("needs").font(.caption).foregroundStyle(.secondary)
                    Text(epicName(need.epic)).font(.caption.weight(.medium))
                    if let needs = need.needs { Text(inlineMarkdown(needs)).font(.caption).foregroundStyle(.secondary) }
                }
                .padding(.leading, 28)
            }
        }
        .padding(.vertical, 10)
    }

    private func epicName(_ ref: String) -> String {
        let epic = project.epics.first { $0.number == ref || $0.id == ref }
        return epic.map { "Epic \($0.number ?? ref): \($0.title)" } ?? ref
    }
}
