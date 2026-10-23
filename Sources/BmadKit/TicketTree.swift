import Foundation
import TOMLDecoder
import Yams

/// Reads a BMAD v7 ticket tree, following the rules of the project's own
/// `_bmad/method/scripts/tickets.py`:
///
/// - An initiative folder holds `<initiative>.md`, a `tickets.toml` of `[[epic]]`
///   tables in build order, and one `epic-<slug>/` folder per epic.
/// - An epic folder holds `epic-<slug>.md`, a `tickets.toml` of `[[entry]]` tables in
///   build order, leaf files `<story|spike|bug>-<slug>.md` that join their entry by
///   `id`, and plans: any other `.md` whose front matter has `ticket`.
/// - A ticket's `status` is its plan's, else its leaf file's; with neither it is
///   `planned` (no file) or not started.
/// - `after` names a sibling by bare integer, another epic's entry as `"<epic id>.<entry id>"`,
///   a whole epic as `"epic-<slug>"`, or a sibling's file name.
public enum TicketTree {
    static let leafTypes: Set<String> = ["story", "spike", "bug"]

    // MARK: tickets.toml

    struct Breakdown: Decodable {
        var entry: [Entry]?
        var epic: [EpicRow]?
    }

    struct Entry: Decodable {
        var id: Int
        var type: String?
        var title: String?
        var description: String?
        var verify: String?
        var unknown: String?
        var covers: [String]?
        var after: [Ref]?
        var hitl: Bool?
        var refine: Bool?
        var risk: String?
        var references: [String]?
        var notes: [String]?
    }

    struct EpicRow: Decodable {
        var id: Int
        var slug: String
        var title: String?
        var after: [EpicAfter]?
    }

    struct EpicAfter: Decodable {
        var epic: Ref
        var needs: String?
    }

    enum Ref: Decodable, Hashable, CustomStringConvertible {
        case int(Int)
        case string(String)

        init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let i = try? c.decode(Int.self) { self = .int(i) } else { self = .string(try c.decode(String.self)) }
        }

        var description: String {
            switch self {
            case .int(let i): "\(i)"
            case .string(let s): s
            }
        }
    }

    static func breakdown(in folder: URL) throws -> Breakdown? {
        let url = folder.appending(path: "tickets.toml")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        do {
            return try TOMLDecoder().decode(Breakdown.self, from: text)
        } catch {
            throw Failure.malformed("\(folder.lastPathComponent)/tickets.toml: \(error)")
        }
    }

    public enum Failure: Error, LocalizedError {
        case malformed(String)
        public var errorDescription: String? {
            if case .malformed(let s) = self { return s }
            return nil
        }
    }

    // MARK: Locating

    /// The active initiative's folder, else the first `initiative-*` under the store root.
    public static func findInitiative(root: URL, paths: ConfigResolver.Paths) -> URL? {
        let store = storeRoot(root: root, paths: paths)
        if let name = paths.activeInitiative, !name.isEmpty {
            let u = store.appending(path: name)
            if isDirectory(u) { return u }
        }
        let children = (try? FileManager.default.contentsOfDirectory(at: store, includingPropertiesForKeys: nil)) ?? []
        return children
            .filter { $0.lastPathComponent.hasPrefix("initiative-") && isDirectory($0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
    }

    /// `[tickets] root` from the store config, defaulting to the output folder.
    static func storeRoot(root: URL, paths: ConfigResolver.Paths) -> URL {
        let output = paths.output ?? root.appending(path: "_bmad-output")
        guard let raw = paths.ticketsRoot, !raw.isEmpty else { return output }
        let path = raw
            .replacingOccurrences(of: "{output_folder}", with: output.path(percentEncoded: false))
            .replacingOccurrences(of: "{project-root}", with: root.path(percentEncoded: false))
        return path.hasPrefix("/") ? URL(filePath: path) : root.appending(path: path)
    }

    // MARK: Loading

    /// One ticket while loading, before references resolve.
    struct Row {
        var folder: URL
        var epicSlug: String
        var id: Int?
        var number: String
        var type: String
        var title: String
        var entry: Entry?
        var leaf: URL?
        var leafFields: [String: Any] = [:]
        var plan: URL?
        var status = ""
        var blockedAt = ""
        var rawAfter: [Ref] = []
        var after: [String] = []      // resolved keys
        var gatedBy: [String] = []    // epic slugs
        var refined = false

        var key: String { id.map { "\(epicSlug)/\($0)" } ?? "\(epicSlug)/\(leaf?.lastPathComponent ?? title)" }

        /// tickets.py's `state`.
        var state: String {
            if leaf == nil, plan == nil { return "planned" }
            if let t = leafFields["tracker_status"] as? String, !t.isEmpty { return t }
            switch status {
            case "", "draft", "ready-for-dev": return "backlog"
            case "in-progress", "blocked": return "in-progress"
            case "in-review", "built": return "review"
            default: return status
            }
        }
    }

    public static func load(root: URL, initiative: URL, paths: ConfigResolver.Paths) throws -> Project {
        var warnings: [String] = []
        let initiativeBreakdown = try breakdown(in: initiative)
        let listed = initiativeBreakdown?.epic ?? []
        let epicIDs = Dictionary(listed.map { ($0.slug, $0.id) }, uniquingKeysWith: { a, _ in a })
        let slugByID = Dictionary(listed.map { ($0.id, $0.slug) }, uniquingKeysWith: { a, _ in a })

        // Epic folders in the initiative's build order, unlisted ones after, by name.
        let order = listed.map(\.slug)
        let folders = ((try? FileManager.default.contentsOfDirectory(at: initiative, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("epic-") && isDirectory($0) }
            .filter { exists($0.appending(path: "\($0.lastPathComponent).md")) || exists($0.appending(path: "tickets.toml")) }
            .sorted {
                let a = order.firstIndex(of: $0.lastPathComponent) ?? order.count
                let b = order.firstIndex(of: $1.lastPathComponent) ?? order.count
                return a != b ? a < b : $0.lastPathComponent < $1.lastPathComponent
            }

        var rows: [Row] = []
        var containers: [String: (fields: [String: Any], url: URL?)] = [:]
        for folder in folders {
            let slug = folder.lastPathComponent
            let epicNumber = epicIDs[slug].map(String.init) ?? slug
            let containerURL = folder.appending(path: "\(slug).md")
            containers[slug] = (frontMatter(containerURL) ?? [:], exists(containerURL) ? containerURL : nil)
            do {
                rows += try loadFolder(folder, epicNumber: epicNumber)
            } catch {
                warnings.append(error.localizedDescription)
            }
        }

        // The backlog: leaf files belonging to no epic, beside the initiative folders.
        let backlog = storeRoot(root: root, paths: paths).appending(path: "backlog")
        var backlogRows: [Row] = []
        if isDirectory(backlog) {
            do {
                backlogRows = try loadFolder(backlog, epicNumber: "B")
            } catch {
                warnings.append(error.localizedDescription)
            }
        }

        resolve(&rows, slugByID: slugByID, containers: containers, warnings: &warnings)
        resolve(&backlogRows, slugByID: [:], containers: [:], warnings: &warnings)

        // Build the model.
        let all = rows + backlogRows
        let byKey = Dictionary(all.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let doneEpics = Set(containers.filter { ($0.value.fields["status"] as? String) == "done" }.keys)
        let done = Set(all.filter { $0.state == "done" }.map(\.key)).union(doneEpics)
        let met = done.union(all.filter { $0.state == "review" }.map(\.key))
        let epicTitle: (String) -> String = { slug in
            listed.first { $0.slug == slug }?.title ?? (containers[slug]?.fields["title"] as? String) ?? slug
        }
        func display(_ key: String) -> String {
            if let r = byKey[key] { return r.number }
            return epicTitle(key)
        }

        func story(_ r: Row) -> Story {
            let statusWord: String = {
                if !r.status.isEmpty { return r.blockedAt.isEmpty ? r.status : "blocked" }
                if !r.blockedAt.isEmpty { return "blocked" }
                if let t = r.leafFields["tracker_status"] as? String, !t.isEmpty { return t }
                return r.state == "planned" ? "planned" : "not started"
            }()
            var s = Story(id: r.key, number: r.number, epicID: r.epicSlug, title: r.title, status: Status(statusWord))
            s.type = r.type
            s.risk = r.entry?.risk ?? (r.leafFields["risk"] as? String)
            // Only a ticket that has not started is waiting; a built one is past its prerequisites.
            if ["planned", "backlog"].contains(r.state) {
                s.waitsOn = r.after.filter { !met.contains($0) }.map(display)
                    + r.gatedBy.filter { !done.contains($0) }.map(display)
            }
            s.documents.append(StoryDocument(label: "Ticket", markdown: ticketMarkdown(r, display: display, byKey: byKey),
                                             url: r.entry == nil ? nil : r.folder.appending(path: "tickets.toml")))
            if let leaf = r.leaf {
                s.documents.append(StoryDocument(label: "Story file", url: leaf))
                s.frontMatter = r.leafFields.mapValues { "\($0)" }
            }
            if let plan = r.plan {
                s.documents.append(StoryDocument(label: "Plan", url: plan))
                if let fm = frontMatter(plan) {
                    for key in ["created", "baseline_revision", "route", "review"] where fm[key] != nil {
                        s.frontMatter[key] = "\(fm[key]!)"
                    }
                }
            }
            return s
        }

        var epics: [Epic] = folders.map { folder in
            let slug = folder.lastPathComponent
            let stories = rows.filter { $0.epicSlug == slug }.map(story)
            var epic = Epic(id: slug, title: epicTitle(slug),
                            status: Status(containerStatus(containers[slug]?.fields, stories: stories)),
                            stories: stories)
            epic.number = epicIDs[slug].map(String.init)
            let retro = folder.appending(path: "\(slug)-retrospective.md")
            if exists(retro) { epic.retrospective = Status("done") }
            epic.documents = [containers[slug]?.url, folder.appending(path: "tickets.toml"), retro].compactMap { $0 }.filter(exists)
            return epic
        }
        if !backlogRows.isEmpty {
            var b = Epic(id: "backlog", title: "Backlog", status: Status("backlog"), stories: backlogRows.map(story))
            b.documents = [backlog]
            epics.append(b)
        }

        // "What next", grouped the way `tickets.py next` groups it.
        var groups: [(String, [Story])] = [("In progress", []), ("Built — awaiting done", []), ("Ready to start", []),
                                           ("Ready to refine", []), ("Blocked", [])]
        for r in rows {
            let s = story(r)
            switch r.state {
            case "done", "dropped": continue
            case _ where r.status == "blocked" || !r.blockedAt.isEmpty: groups[4].1.append(s)
            case "in-progress": groups[0].1.append(s)
            case "review": groups[1].1.append(s)
            default:
                if !(r.after.allSatisfy(met.contains) && r.gatedBy.allSatisfy(done.contains)) {
                    groups[4].1.append(s)
                } else if (r.entry?.refine ?? (r.entry == nil)) && !r.refined {
                    groups[3].1.append(s)
                } else {
                    groups[2].1.append(s)
                }
            }
        }
        let queue = groups.map { heading, stories in
            QueueSection(heading: heading, entries: stories.enumerated().map { i, s in
                QueueEntry(section: heading, position: "\(i + 1)", storyNumber: s.number, waitsOn: s.waitsOn,
                           reason: epicTitle(s.epicID))
            })
        }.filter { !$0.entries.isEmpty }

        let initiativeDoc = initiative.appending(path: "\(initiative.lastPathComponent).md")
        let name = (frontMatter(initiativeDoc)?["title"] as? String) ?? initiative.lastPathComponent
        var project = Project(
            root: root, name: name, layout: .ticketTree, epics: epics, queue: queue,
            sources: .init(storyDirectory: storeRoot(root: root, paths: paths), planningDirectory: initiative),
            warnings: warnings
        )
        project.documents = [initiativeDoc, initiative.appending(path: "tickets.toml")].filter(exists)
        return project
    }

    /// Rows for one epic or backlog folder: every `[[entry]]`, joined to its leaf
    /// file by `id`, then leaf files the breakdown does not list, then plans.
    static func loadFolder(_ folder: URL, epicNumber: String) throws -> [Row] {
        let slug = folder.lastPathComponent
        var rows: [Row] = (try breakdown(in: folder)?.entry ?? []).map { e in
            Row(folder: folder, epicSlug: slug, id: e.id, number: "\(epicNumber).\(e.id)",
                type: e.type ?? "story", title: e.title ?? "Entry \(e.id)", entry: e, rawAfter: e.after ?? [])
        }
        var plans: [(URL, [String: Any])] = []
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var extra: [Row] = []
        for file in files {
            guard let fm = frontMatter(file) else { continue }
            let type = fm["type"] as? String ?? ""
            guard leafTypes.contains(type) else {
                if fm["ticket"] != nil { plans.append((file, fm)) }
                continue
            }
            let id = fm["id"] as? Int
            let index = id.flatMap { id in rows.firstIndex { $0.id == id } }
            var row = index.map { rows[$0] } ?? Row(
                folder: folder, epicSlug: slug, id: id,
                number: id.map { "\(epicNumber).\($0)" } ?? "\(epicNumber).\(file.deletingPathExtension().lastPathComponent)",
                type: type, title: "", entry: nil
            )
            row.leaf = file
            row.leafFields = fm
            row.type = type
            if let t = fm["title"] as? String, !t.isEmpty { row.title = t }
            row.status = fm["status"] as? String ?? ""
            row.blockedAt = "\(fm["blocked_at"] ?? "")"
            row.refined = (fm["refined"] as? Bool) ?? false
            if let after = fm["after"] as? [Any] {
                row.rawAfter = after.map { ($0 as? Int).map(Ref.int) ?? .string("\($0)") }
            }
            if let index { rows[index] = row } else { extra.append(row) }
        }
        rows += extra

        for (plan, fm) in plans {
            let ticket = fm["ticket"]
            let target: Int? = {
                if let i = ticket as? Int { return rows.firstIndex { $0.id == i } }
                if let s = ticket as? String, let i = Int(s) { return rows.firstIndex { $0.id == i } }
                if let s = ticket as? String { return rows.firstIndex { $0.leaf?.deletingPathExtension().lastPathComponent == s } }
                return nil
            }()
            guard let target else {
                throw Failure.malformed("\(slug)/\(plan.lastPathComponent): ticket \(ticket ?? "?") names no entry or leaf file")
            }
            rows[target].plan = plan
            rows[target].status = "\(fm["status"] ?? "")"
            rows[target].blockedAt = "\(fm["blocked_at"] ?? "")"
        }
        return rows
    }

    static func resolve(_ rows: inout [Row], slugByID: [Int: String],
                        containers: [String: (fields: [String: Any], url: URL?)], warnings: inout [String]) {
        let keys = Set(rows.map(\.key))
        for i in rows.indices {
            let r = rows[i]
            var resolved: [String] = []
            for ref in r.rawAfter {
                var key: String?
                switch ref {
                case .int(let n):
                    key = keys.contains("\(r.epicSlug)/\(n)") ? "\(r.epicSlug)/\(n)" : nil
                case .string(let s):
                    if let m = s.wholeMatch(of: /(\d+)\.(\d+)/), let slug = slugByID[Int(m.1)!] {
                        key = "\(slug)/\(Int(m.2)!)"
                    } else if s.hasPrefix("epic-"), containers[s] != nil {
                        key = s
                    } else {
                        key = rows.first { $0.epicSlug == r.epicSlug && ($0.leaf?.lastPathComponent == s || $0.leaf?.deletingPathExtension().lastPathComponent == s) }?.key
                    }
                }
                if let key, keys.contains(key) || containers[key] != nil {
                    if !resolved.contains(key) { resolved.append(key) }
                } else {
                    warnings.append("\(r.epicSlug) \(r.number): after \(ref) matches no ticket")
                }
            }
            rows[i].after = resolved
            if let gates = containers[r.epicSlug]?.fields["after"] as? [Any] {
                rows[i].gatedBy = gates.map { "\($0)" }.filter { containers[$0] != nil }
            }
        }
    }

    /// The container's own status when ticketing set one; else derived from its tickets.
    static func containerStatus(_ fields: [String: Any]?, stories: [Story]) -> String {
        if let s = fields?["status"] as? String, !s.isEmpty { return s }
        if stories.isEmpty { return fields?["refined"] as? Bool == false ? "not refined" : "planned" }
        if stories.allSatisfy(\.status.isTerminal) { return "done" }
        if stories.contains(where: { ![.backlog, .other].contains($0.status.kind) }) { return "in-progress" }
        return "planned"
    }

    /// The entry as readable markdown: what it delivers, how it is verified, what it waits on.
    static func ticketMarkdown(_ r: Row, display: (String) -> String, byKey: [String: Row]) -> String {
        var md = "## \(r.title)\n\n"
        var facts = ["**\(r.type.capitalized)** \(r.number)"]
        if let risk = r.entry?.risk ?? r.leafFields["risk"] as? String, !risk.isEmpty { facts.append("risk **\(risk)**") }
        if r.entry?.hitl == true || r.leafFields["hitl"] as? Bool == true { facts.append("**human in the loop**") }
        if let sev = r.leafFields["severity"] as? String { facts.append("severity **\(sev)**") }
        md += facts.joined(separator: " · ") + "\n\n"
        guard let e = r.entry else {
            md += "_No `tickets.toml` entry: this ticket exists only as its file._\n"
            return md
        }
        if let d = e.description, !d.isEmpty { md += "### Delivers\n\n\(d)\n\n" }
        if let v = e.verify, !v.isEmpty { md += "### Verify\n\n\(v)\n\n" }
        if let u = e.unknown, !u.isEmpty { md += "### Unknown\n\n\(u)\n\n" }
        if !r.after.isEmpty {
            md += "### After\n\n"
            for key in r.after {
                if let other = byKey[key] {
                    md += "- Story \(other.number) — \(other.title)\n"
                } else {
                    md += "- \(display(key)) (whole epic)\n"
                }
            }
            md += "\n"
        }
        if let c = e.covers, !c.isEmpty { md += "**Covers:** \(c.joined(separator: ", "))\n\n" }
        if let refs = e.references, !refs.isEmpty { md += "### References\n\n" + refs.map { "- \($0)" }.joined(separator: "\n") + "\n\n" }
        if let notes = e.notes, !notes.isEmpty { md += "### Notes\n\n" + notes.map { "- \($0)" }.joined(separator: "\n") + "\n\n" }
        return md
    }

    // MARK: Helpers

    static func frontMatter(_ url: URL) -> [String: Any]? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return FrontMatter.raw(text)
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    static func isDirectory(_ url: URL) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &dir) && dir.boolValue
    }
}
