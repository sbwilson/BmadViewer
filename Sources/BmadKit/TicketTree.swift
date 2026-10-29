import Foundation
import TOMLDecoder
import Yams

/// Reads a BMAD v7 ticket tree, following the rules of the project's own
/// `_bmad/method/scripts/tickets.py`:
///
/// - An initiative folder holds `<initiative>.md` and its tickets: a `tickets.toml` of
///   `[[epic]]` tables in build order and one `epic-<slug>/` folder per epic. Since v7's
///   first release those sit in the container's `tickets/` subfolder; the earlier layout
///   kept them beside the container's own file, and both are read.
/// - An epic folder holds `epic-<slug>.md` and its tickets: a `tickets.toml` of `[[entry]]`
///   tables in build order, leaf files `<story|spike|bug>-<slug>.md` that join their entry
///   by `id`, plans: any other `.md` whose front matter has `ticket`, and a spike's findings
///   file, whose front matter has `spike` instead.
/// - An `id` is a whole number or letters and digits, and `"6"` and `6` are one id.
/// - A ticket's `status` is its plan's, else its leaf file's; with neither it is
///   `planned` (no file) or not started.
/// - `after` names a sibling by bare integer, string id or file name, another epic's entry
///   as `"<epic id>.<entry id>"`, a whole epic as `"epic-<slug>"`, or a tracker id.
public enum TicketTree {
    static let leafTypes: Set<String> = ["story", "spike", "bug"]
    /// A plan's `status` as `tickets.py` knows it; anything else blocks the ticket.
    static let planStatuses: Set<String> =
        ["draft", "ready-for-dev", "in-progress", "in-review", "built", "done", "blocked", "dropped"]

    // MARK: Layout

    /// Where a folder keeps its `tickets.toml`, epic folders, leaf files and plans:
    /// `tickets/` beside the container's own file since v7's first release, the folder
    /// itself in the earlier layout and in a backlog, which has no file of its own.
    static func ticketsDir(of folder: URL) -> URL {
        if exists(folder.appending(path: "tickets.toml")) { return folder }
        let sub = folder.appending(path: "tickets")
        return isDirectory(sub) ? sub : folder
    }

    static func breakdownURL(of folder: URL) -> URL { ticketsDir(of: folder).appending(path: "tickets.toml") }

    // MARK: tickets.toml

    struct Breakdown: Decodable {
        var entry: [Entry]?
        var epic: [EpicRow]?
        var initiative: [InitiativeRow]?
    }

    struct Entry: Decodable {
        var id: TicketID
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
        var estimate: Ref?
        var references: [String]?
        var notes: [String]?
    }

    struct EpicRow: Decodable {
        var id: TicketID
        var slug: String
        var title: String?
        var after: [EpicAfter]?
    }

    struct InitiativeRow: Decodable {
        var id: TicketID
        var slug: String
        var title: String?
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

    /// A ticket, epic or initiative `id` as the tree compares it (`tickets.py`'s `_id`):
    /// a number, or letters and digits; digits alone, quoted like a front-matter value, are the number.
    public enum TicketID: Hashable, Sendable, CustomStringConvertible, Decodable {
        case int(Int)
        case string(String)

        public init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let i = try? c.decode(Int.self) { self = .int(i); return }
            let s = try c.decode(String.self)
            guard let id = TicketID(s) else {
                throw TicketTree.Failure.malformed("id \(s.debugDescription) is not a number or letters and digits")
            }
            self = id
        }

        /// nil when the value cannot be an id: not a number, not letters and digits, or a boolean.
        init?(_ value: Any) {
            if value is Bool { return nil }
            switch value {
            case let i as Int: self = .int(i)
            case let s as String:
                guard s != "true", s != "false" else { return nil }
                guard s.wholeMatch(of: /[0-9A-Za-z]+/) != nil else { return nil }
                self = s.wholeMatch(of: /[0-9]+/).map { .int(Int($0.0)!) } ?? .string(s)
            default: return nil
            }
        }

        /// A written reference read as an id, keeping anything odd as its string.
        static func reference(_ s: String) -> TicketID { TicketID(s) ?? .string(s) }

        public var description: String {
            switch self {
            case .int(let i): "\(i)"
            case .string(let s): s
            }
        }
    }

    static func breakdown(in folder: URL) throws -> Breakdown? {
        let url = breakdownURL(of: folder)
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
        var id: TicketID?
        var number: String
        var type: String
        var title: String
        var entry: Entry?
        var leaf: URL?
        var leafFields: [String: Any] = [:]
        var plan: URL?
        var findings: URL?
        var status = ""
        var blockedAt = ""
        var unknown = ""
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
        let initiativeDoc = initiative.appending(path: "\(initiative.lastPathComponent).md")
        let name = (frontMatter(initiativeDoc)?["title"] as? String) ?? initiative.lastPathComponent
        if let children = initiativeBreakdown?.initiative, !children.isEmpty {
            // tickets.py refuses a parent: it holds initiative folders, not tickets.
            warnings.append("\(initiative.lastPathComponent) is a parent initiative: open one of its children "
                + "— \(children.map(\.slug).joined(separator: ", "))")
            var parent = Project(
                root: root, name: name, layout: .ticketTree, epics: [], queue: [],
                sources: .init(storyDirectory: storeRoot(root: root, paths: paths), planningDirectory: initiative),
                warnings: warnings
            )
            parent.documents = [initiativeDoc, breakdownURL(of: initiative)].filter(exists)
            return parent
        }
        let epicIDs = Dictionary(listed.map { ($0.slug, $0.id) }, uniquingKeysWith: { a, _ in a })
        let slugByID = Dictionary(listed.map { ($0.id, $0.slug) }, uniquingKeysWith: { a, _ in a })

        // Epic folders in the initiative's build order, unlisted ones after, by name.
        let order = listed.map(\.slug)
        let folders = ((try? FileManager.default.contentsOfDirectory(at: ticketsDir(of: initiative), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("epic-") && isDirectory($0) }
            .filter { exists($0.appending(path: "\($0.lastPathComponent).md")) || exists(breakdownURL(of: $0)) }
            .sorted {
                let a = order.firstIndex(of: $0.lastPathComponent) ?? order.count
                let b = order.firstIndex(of: $1.lastPathComponent) ?? order.count
                return a != b ? a < b : $0.lastPathComponent < $1.lastPathComponent
            }

        var rows: [Row] = []
        var containers: [String: (fields: [String: Any], url: URL?)] = [:]
        for folder in folders {
            let slug = folder.lastPathComponent
            let epicNumber = epicIDs[slug].map { "\($0)" } ?? slug
            let containerURL = folder.appending(path: "\(slug).md")
            containers[slug] = (frontMatter(containerURL) ?? [:], exists(containerURL) ? containerURL : nil)
            do {
                rows += try loadFolder(folder, epicNumber: epicNumber, problems: &warnings)
            } catch {
                warnings.append(error.localizedDescription)
            }
        }

        // The backlog: leaf files belonging to no epic, beside the initiative folders.
        let backlog = storeRoot(root: root, paths: paths).appending(path: "backlog")
        var backlogRows: [Row] = []
        if isDirectory(backlog) {
            do {
                backlogRows = try loadFolder(backlog, epicNumber: "B", problems: &warnings)
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
            s.dependsOn = r.after.filter { byKey[$0] != nil }
            s.dependsOnEpics = r.after.filter { byKey[$0] == nil } + r.gatedBy
            s.hitl = r.entry?.hitl == true || r.leafFields["hitl"] as? Bool == true
            // Only a ticket that has not started is waiting; a built one is past its prerequisites.
            if ["planned", "backlog"].contains(r.state) {
                var waiting = r.after.filter { !met.contains($0) }.map(display) + r.gatedBy.filter { !done.contains($0) }.map(display)
                waiting = waiting.reduce(into: []) { if $0.last != $1 { $0.append($1) } }
                s.waitsOn = waiting
            }
            s.documents.append(StoryDocument(label: "Ticket", markdown: ticketMarkdown(r, display: display, byKey: byKey),
                                             url: r.entry == nil ? nil : breakdownURL(of: r.folder)))
            if let leaf = r.leaf {
                s.documents.append(StoryDocument(label: "Story file", url: leaf))
                s.frontMatter = r.leafFields.mapValues { "\($0)" }
            }
            for doc in [r.leaf, r.plan].compactMap({ $0 }) where s.review == nil {
                if let text = try? String(contentsOf: doc, encoding: .utf8) {
                    s.review = ReviewOrder.parse(text, document: doc, projectRoot: root)
                }
            }
            if let plan = r.plan {
                s.documents.append(StoryDocument(label: "Plan", url: plan))
                if let fm = frontMatter(plan) {
                    for key in ["created", "baseline_revision", "route", "review"] where fm[key] != nil {
                        s.frontMatter[key] = "\(fm[key]!)"
                    }
                }
            }
            if let findings = r.findings {
                s.documents.append(StoryDocument(label: "Findings", url: findings))
            }
            return s
        }

        var epics: [Epic] = folders.map { folder in
            let slug = folder.lastPathComponent
            let stories = rows.filter { $0.epicSlug == slug }.map(story)
            var epic = Epic(id: slug, title: epicTitle(slug),
                            status: Status(containerStatus(containers[slug]?.fields, stories: stories)),
                            stories: stories)
            epic.number = epicIDs[slug].map { "\($0)" }
            let retro = folder.appending(path: "\(slug)-retrospective.md")
            if exists(retro) { epic.retrospective = Status("done") }
            epic.documents = [containers[slug]?.url, breakdownURL(of: folder), retro].compactMap { $0 }.filter(exists)
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
                } else if (r.entry?.refine == true || r.type == "bug" || r.entry == nil), !r.refined {
                    groups[3].1.append(s)
                } else if !r.unknown.isEmpty {
                    groups[4].1.append(s)  // refining has settled, but the unknown still has an answer owed
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

        var project = Project(
            root: root, name: name, layout: .ticketTree, epics: epics, queue: queue,
            sources: .init(storyDirectory: storeRoot(root: root, paths: paths), planningDirectory: initiative),
            warnings: warnings
        )
        project.documents = [initiativeDoc, breakdownURL(of: initiative)].filter(exists)
        for epic in epics {
            for doc in epic.documents where doc.lastPathComponent.hasSuffix("-retrospective.md") {
                if let text = try? String(contentsOf: doc, encoding: .utf8) {
                    project.retroActions += WorkItems.retrospectiveActions(text, source: doc, epic: epic.id)
                }
            }
        }
        ProjectLoader.loadDeferredWork(into: &project, directories: [
            initiative, paths.implementation, storeRoot(root: root, paths: paths).appending(path: "implementation-artifacts"),
        ])
        FollowThroughReader.apply(&project)
        project.humanRuns = HumanRuns.read(project)
        return project
    }

    /// Rows for one epic or backlog folder: every `[[entry]]`, joined to its leaf
    /// file by `id`, then leaf files the breakdown does not list, then plans and a
    /// spike's findings file. A plan that names nothing is a problem, not a failure.
    static func loadFolder(_ folder: URL, epicNumber: String, problems: inout [String]) throws -> [Row] {
        let slug = folder.lastPathComponent
        var rows: [Row] = (try breakdown(in: folder)?.entry ?? []).map { e in
            Row(folder: folder, epicSlug: slug, id: e.id, number: "\(epicNumber).\(e.id)",
                type: e.type ?? "story", title: e.title ?? "Entry \(e.id)", entry: e, unknown: e.unknown ?? "", rawAfter: e.after ?? [])
        }
        var plans: [(URL, [String: Any])] = []
        var findings: [(URL, Any)] = []
        let files = ((try? FileManager.default.contentsOfDirectory(at: ticketsDir(of: folder), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var extra: [Row] = []
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8), let fm = FrontMatter.raw(text) else { continue }
            let type = fm["type"] as? String ?? ""
            guard leafTypes.contains(type) else {
                if fm["ticket"] != nil { plans.append((file, fm)) }
                else if let spike = fm["spike"] { findings.append((file, spike)) }
                continue
            }
            let id = fm["id"].flatMap(TicketID.init)
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
            row.blockedAt = fm["blocked_at"].map { "\($0)" } ?? ""
            row.refined = (fm["refined"] as? Bool) ?? false
            row.unknown = fileUnknown(text)  // the leaf's own `Unknown:` lines replace the entry's
            if let after = fm["after"] as? [Any] {
                row.rawAfter = after.map { ($0 as? Int).map(Ref.int) ?? .string("\($0)") }
            }
            if let index { rows[index] = row } else { extra.append(row) }
        }
        rows += extra

        // A spike's findings file joins the entry its `spike:` names, in this folder.
        for (file, ref) in findings {
            let target = TicketID(ref) ?? (ref as? String).flatMap { s in
                guard let m = s.wholeMatch(of: /([0-9A-Za-z]+)\.([0-9A-Za-z]+)/), String(m.1) == epicNumber
                else { return nil }
                return TicketID.reference(String(m.2))
            }
            guard let target, let index = rows.firstIndex(where: { $0.id == target }) else { continue }
            if rows[index].findings == nil { rows[index].findings = file }
        }

        for (plan, fm) in plans {
            let ticket = fm["ticket"]
            let target: Int? = {
                if let id = ticket.flatMap({ TicketID($0) }), let i = rows.firstIndex(where: { $0.id == id }) { return i }
                if let stem = ticket as? String { return rows.firstIndex { $0.leaf?.deletingPathExtension().lastPathComponent == stem } }
                return nil
            }()
            guard let target else {
                let shown = (ticket as? String).map { "'\($0)'" } ?? "\(ticket ?? "?")"
                problems.append("\(slug)/\(plan.lastPathComponent): ticket \(shown) names no entry or leaf file; skipped")
                continue
            }
            rows[target].plan = plan
            let planStatus = fm["status"].map { "\($0)" } ?? ""
            if !planStatus.isEmpty, !planStatuses.contains(planStatus) {
                problems.append("\(slug)/\(plan.lastPathComponent): status \(planStatus) is unknown; "
                    + "the ticket reads as blocked until the plan is fixed")
                rows[target].status = "blocked"
            } else {
                rows[target].status = planStatus
            }
            rows[target].blockedAt = fm["blocked_at"].map { "\($0)" } ?? ""
        }
        return rows
    }

    static func resolve(_ rows: inout [Row], slugByID: [TicketID: String],
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
                    let siblings = rows.filter { $0.epicSlug == r.epicSlug }
                    // A sibling's string id, then a sibling's file name.
                    key = siblings.first { row in
                        if case .string(let sid)? = row.id { return sid == s }
                        return false
                    }?.key
                    key = key ?? siblings.first {
                        $0.leaf?.lastPathComponent == s || $0.leaf?.deletingPathExtension().lastPathComponent == s
                    }?.key
                    // Another epic's entry as "<epic id>.<entry id>", or a whole epic.
                    if key == nil, let m = s.wholeMatch(of: /([0-9A-Za-z]+)\.([0-9A-Za-z]+)/),
                       let slug = slugByID[TicketID.reference(String(m.1))] {
                        key = "\(slug)/\(TicketID.reference(String(m.2)))"
                    } else if key == nil, s.hasPrefix("epic-"), containers[s] != nil {
                        key = s
                    }
                    // A tracker's id, on a ticket or a container.
                    if key == nil, !s.isEmpty {
                        key = rows.first { ($0.leafFields["tracker_id"] as? String)?.lowercased() == s.lowercased() }?.key
                    }
                    if key == nil, !s.isEmpty {
                        key = containers.first { ($0.value.fields["tracker_id"] as? String)?.lowercased() == s.lowercased() }?.key
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
        if let estimate = r.entry?.estimate { facts.append("estimate **\(estimate)**") }
        if r.entry?.hitl == true || r.leafFields["hitl"] as? Bool == true { facts.append("**human in the loop**") }
        if let sev = r.leafFields["severity"] as? String { facts.append("severity **\(sev)**") }
        md += facts.joined(separator: " · ") + "\n\n"
        guard let e = r.entry else {
            md += "_No `tickets.toml` entry: this ticket exists only as its file._\n"
            return md
        }
        if let d = e.description, !d.isEmpty { md += "### Delivers\n\n\(d)\n\n" }
        if let v = e.verify, !v.isEmpty { md += "### Verify\n\n\(v)\n\n" }
        if !r.unknown.isEmpty { md += "### Unknown\n\n\(r.unknown)\n\n" }
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

    /// The `Unknown:` lines of a leaf file's body, as `pull` writes an entry's `unknown` into Notes.
    static func fileUnknown(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            lines.removeSubrange(0...end)
        }
        // Drop `<!-- … -->` comments, which can hold a template's example, and span lines.
        var body: [String] = []
        var inComment = false
        for raw in lines {
            var l = raw
            if inComment {
                if let close = l.range(of: "-->") { l = String(l[close.upperBound...]); inComment = false } else { continue }
            }
            while let open = l.range(of: "<!--") {
                if let close = l.range(of: "-->", range: open.upperBound..<l.endIndex) {
                    l.removeSubrange(open.lowerBound..<close.upperBound)
                } else {
                    l.removeSubrange(open.lowerBound..<l.endIndex)
                    inComment = true
                    break
                }
            }
            body.append(l)
        }
        var out: [String] = []
        for line in body {
            if let m = line.wholeMatch(of: /[ \t]*(?:[-*][ \t]+)?Unknown:[ \t]*(\S.*)/) {
                out.append(String(m.1).trimmingCharacters(in: .whitespaces))
            }
        }
        return out.joined(separator: "; ")
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    static func isDirectory(_ url: URL) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &dir) && dir.boolValue
    }
}

/// A `tickets.toml` as written, for showing the file itself: an epic's `[[entry]]`
/// tables or an initiative's `[[epic]]` tables, in build order.
public struct TicketsFile: Sendable {
    public struct Entry: Sendable, Identifiable, Hashable {
        public let id: TicketTree.TicketID
        public let type: String
        public let title: String
        public let description: String?
        public let verify: String?
        public let unknown: String?
        /// As written: a bare sibling (`"3"`), `"<epic id>.<entry id>"`, `"epic-<slug>"` or a file name.
        public let after: [String]
        public let risk: String?
        public let estimate: String?
        public let hitl: Bool
        public let refine: Bool
        public let covers: [String]
    }

    public struct EpicRow: Sendable, Identifiable, Hashable {
        public struct Need: Sendable, Hashable {
            public let epic: String
            public let needs: String?
        }
        public let id: TicketTree.TicketID
        public let slug: String
        public let title: String?
        public let after: [Need]
    }

    public let entries: [Entry]
    public let epics: [EpicRow]

    public static func load(_ url: URL) throws -> TicketsFile {
        let text = try String(contentsOf: url, encoding: .utf8)
        let b: TicketTree.Breakdown
        do {
            b = try TOMLDecoder().decode(TicketTree.Breakdown.self, from: text)
        } catch {
            throw TicketTree.Failure.malformed("\(url.lastPathComponent): \(error)")
        }
        return TicketsFile(
            entries: (b.entry ?? []).map {
                Entry(id: $0.id, type: $0.type ?? "story", title: $0.title ?? "Entry \($0.id)", description: $0.description,
                      verify: $0.verify, unknown: $0.unknown, after: ($0.after ?? []).map(\.description), risk: $0.risk,
                      estimate: $0.estimate.map { "\($0)" }, hitl: $0.hitl ?? false, refine: $0.refine ?? false, covers: $0.covers ?? [])
            },
            epics: (b.epic ?? []).map {
                EpicRow(id: $0.id, slug: $0.slug, title: $0.title,
                        after: ($0.after ?? []).map { .init(epic: $0.epic.description, needs: $0.needs) })
            }
        )
    }
}
