import Foundation

// MARK: Dependencies

public enum Dependencies {
    /// Sprint-status projects record dependencies only in prose: build-order's
    /// "Waits on" column and sentences in a story's epics.md section such as
    /// "Depends on 4.8's `InterruptionCauses` …, and on 4.14's arbiter" or "Queued
    /// after 4.7". Every story number in such a sentence is taken.
    public static func infer(_ project: inout Project) {
        let byNumber = Dictionary(project.allStories.map { ($0.number, $0.id) }, uniquingKeysWith: { a, _ in a })
        let waits = Dictionary(project.queue.flatMap(\.entries).map { ($0.storyNumber, $0.waitsOn) }, uniquingKeysWith: { a, _ in a })
        for e in project.epics.indices {
            for s in project.epics[e].stories.indices {
                let story = project.epics[e].stories[s]
                var numbers = waits[story.number] ?? []
                let text = story.documents.first { $0.label == "Epic definition" }?.markdown ?? ""
                numbers += prose(text, excluding: story.number)
                var seen = Set<String>()
                project.epics[e].stories[s].dependsOn = numbers.compactMap { byNumber[$0] }.filter { $0 != story.id && seen.insert($0).inserted }
            }
        }
    }

    /// `4.14` but not part of `0.2.3` or `12.5.1`. (ICU: Swift Regex has no lookbehind.)
    static let storyNumber = try! NSRegularExpression(pattern: #"(?<![\d.])\d+\.\d+[a-z]?(?![\d.])"#)

    static func prose(_ text: String, excluding own: String) -> [String] {
        var out: [String] = []
        let sentences = text.replacingOccurrences(of: "\n", with: " ").components(separatedBy: ". ")
        for sentence in sentences {
            let lower = sentence.lowercased()
            guard ["depends on", "queued after", "waits on", "blocked by", "needs story", "builds on story"].contains(where: lower.contains) else { continue }
            let ns = sentence as NSString
            out += storyNumber.matches(in: sentence, range: NSRange(location: 0, length: ns.length))
                .map { ns.substring(with: $0.range) }.filter { $0 != own }
        }
        return out
    }
}

/// Stories laid out in layers by what they come after, with the longest chain of
/// work still to do.
public struct DependencyGraph: Sendable {
    public struct Node: Identifiable, Hashable, Sendable {
        public let id: Story.ID
        public let number: String
        public let title: String
        public let epicID: String
        public let status: Status
        /// Pulled in from outside the chosen epic because something inside depends on it.
        public let external: Bool
        public var layer = 0
        public var row = 0
    }

    public struct Edge: Hashable, Sendable {
        /// The prerequisite.
        public let from: Story.ID
        public let to: Story.ID
    }

    public let nodes: [Node]
    public let edges: [Edge]
    /// Prerequisite first: the longest run of not-yet-finished stories, each waiting
    /// on the one before.
    public let longestChain: [Story.ID]

    public var layers: Int { (nodes.map(\.layer).max() ?? -1) + 1 }
    public var rows: Int { (nodes.map(\.row).max() ?? -1) + 1 }

    /// `epic` nil for the whole project; `hideFinished` drops done and superseded stories.
    public static func build(_ project: Project, epic: String?, hideFinished: Bool) -> DependencyGraph {
        let all = project.allStories
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var included = Set(all.filter { epic == nil || $0.epicID == epic }.map(\.id))
        var external = Set<Story.ID>()
        if epic != nil {
            for id in included { for dep in byID[id]?.dependsOn ?? [] where !included.contains(dep) { external.insert(dep) } }
            included.formUnion(external)
        }
        if hideFinished { included = included.filter { !(byID[$0]?.status.isTerminal ?? true) } }

        let edges = included.flatMap { id in (byID[id]?.dependsOn ?? []).filter(included.contains).map { Edge(from: $0, to: id) } }
        let deps = Dictionary(grouping: edges, by: \.to).mapValues { $0.map(\.from) }

        // Layer: one past the deepest prerequisite (cycles are cut where they close).
        var layer: [Story.ID: Int] = [:]
        func depth(_ id: Story.ID, _ visiting: Set<Story.ID>) -> Int {
            if let l = layer[id] { return l }
            let l = (deps[id] ?? []).filter { !visiting.contains($0) }.map { depth($0, visiting.union([id])) + 1 }.max() ?? 0
            layer[id] = l
            return l
        }
        for id in included { _ = depth(id, []) }

        // Rows within a layer: epic order, then the story's own order.
        let order = Dictionary(all.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        var nodes: [Node] = []
        for (l, ids) in Dictionary(grouping: included, by: { layer[$0] ?? 0 }) {
            for (r, id) in ids.sorted(by: { (order[$0] ?? 0) < (order[$1] ?? 0) }).enumerated() {
                guard let s = byID[id] else { continue }
                nodes.append(Node(id: id, number: s.number, title: s.title, epicID: s.epicID, status: s.status,
                                  external: external.contains(id), layer: l, row: r))
            }
        }
        nodes.sort { ($0.layer, $0.row) < ($1.layer, $1.row) }
        return DependencyGraph(nodes: nodes, edges: edges, longestChain: longestChain(included, deps: deps, byID: byID))
    }

    /// Mirrors `tickets.py`'s longest remaining chain: over unfinished stories only.
    static func longestChain(_ ids: Set<Story.ID>, deps: [Story.ID: [Story.ID]], byID: [Story.ID: Story]) -> [Story.ID] {
        let remaining = ids.filter { !(byID[$0]?.status.isTerminal ?? true) }
        var memo: [Story.ID: [Story.ID]] = [:]
        func chain(_ id: Story.ID, _ visiting: Set<Story.ID>) -> [Story.ID] {
            if let c = memo[id] { return c }
            let best = (deps[id] ?? []).filter { remaining.contains($0) && !visiting.contains($0) }
                .map { chain($0, visiting.union([id])) }.max { $0.count < $1.count } ?? []
            let c = best + [id]
            memo[id] = c
            return c
        }
        return remaining.sorted().map { chain($0, []) }.max { $0.count < $1.count } ?? []
    }
}

// MARK: Retro follow-through

public enum FollowThroughReader {
    /// Reads each retrospective's "Previous-retro follow-through" table (a table with a
    /// `Landed?` column) and joins its rows to the actions they check: by action id
    /// (`epic-4-retro-item-111-…`, which may be cut short with …), or by item number
    /// against the retrospective before it, by date.
    public static func apply(_ project: inout Project) {
        let retros = retrospectives(project).sorted { $0.date < $1.date }
        for (i, retro) in retros.enumerated() {
            // The retrospective this one checks: an earlier one of the same epic, else
            // the one just before it.
            let earlier = retros[..<i]
            let previous = (earlier.last { $0.epic != nil && $0.epic == retro.epic } ?? earlier.last).map { path($0.url) }
            let checked = project.retroActions.indices.filter { j in
                let a = project.retroActions[j]
                return previous != nil && ([a.source].compactMap { $0 } + a.related).contains { path($0) == previous }
            }
            for row in rows(retro.text, source: retro.url) {
                let index: Int?
                if let n = row.number, !checked.isEmpty {
                    index = checked.first { project.retroActions[$0].label == "#\(n)" }
                        ?? (n >= 1 && n <= checked.count ? checked[n - 1] : nil)
                } else if row.number != nil {
                    // Nothing to number against: use an action id the row itself names
                    // ("epic-17-retro-item-46 `done`" in its evidence).
                    let actions = project.retroActions
                    index = row.mentions.compactMap { id in
                        actions.firstIndex { $0.id == id || $0.id.hasPrefix(id + "-") }
                    }.first
                } else {
                    let key = row.key
                    index = project.retroActions.firstIndex { $0.id == key || (key.count > 12 && $0.id.hasPrefix(key)) }
                }
                if let index { project.retroActions[index].followThrough = row.followThrough }
            }
        }
        linkStories(&project)
    }

    struct Retro { let url: URL; let text: String; let date: String; let epic: String? }

    static func path(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false) }

    static func retrospectives(_ project: Project) -> [Retro] {
        project.epics.flatMap { epic in epic.documents.map { (epic.id, $0) } }
            .filter { $0.1.lastPathComponent.hasSuffix("-retrospective.md") || $0.1.lastPathComponent.contains("-retro-") }
            .compactMap { epicID, url in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                let date = FrontMatter.split(text).fields["date"]
                    ?? url.lastPathComponent.firstMatch(of: /\d{4}-\d{2}-\d{2}/).map { String($0.0) } ?? ""
                // A retro without a date is a draft or a split-out note, not a run.
                guard !date.isEmpty else { return nil }
                return Retro(url: url, text: text, date: date, epic: epicID)
            }
    }

    struct Row {
        let key: String
        let followThrough: WorkItem.FollowThrough
        /// Action ids named anywhere in the row.
        var mentions: [String] = []
        /// `**#9** — …` or `6 — shared helper`: the previous retro's item number.
        var number: Int? { key.firstMatch(of: /^(\d+)\b/).flatMap { Int($0.1) } }
    }

    static func rows(_ text: String, source: URL) -> [Row] {
        var out: [Row] = []
        var inSection = false
        var columns: [String]?
        for (i, line) in text.components(separatedBy: "\n").enumerated() {
            if line.hasPrefix("#") {
                inSection = line.lowercased().contains("follow-through") || line.lowercased().contains("follow through")
                columns = nil
                continue
            }
            guard inSection, line.hasPrefix("|") else { columns = line.trimmingCharacters(in: .whitespaces).isEmpty ? nil : columns; continue }
            let cells = BuildOrder.splitRow(line)
            if columns == nil {
                let lower = cells.map { $0.lowercased() }
                if lower.contains(where: { $0.contains("landed") }) { columns = lower }
                continue
            }
            guard let cols = columns, !cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }),
                  let landedAt = cols.firstIndex(where: { $0.contains("landed") }), landedAt < cells.count else { continue }
            let evidenceAt = cols.firstIndex { $0.contains("evidence") || $0 == "source" }
            let key = cleanKey(cells[0])
            guard !key.isEmpty else { continue }
            let text = cells[landedAt]
            out.append(Row(key: key, followThrough: .init(
                verdict: verdict(text), text: text,
                evidence: evidenceAt.flatMap { $0 < cells.count ? cells[$0] : nil },
                source: source, line: i + 1
            ), mentions: line.matches(of: /epic-[A-Za-z0-9]+-retro-item-\d+/).map { String($0.0) }))
        }
        return out
    }

    /// `**#9** — *"Fix …"*` → `9`; `` `epic-18-retro-item-134-…` (`done`) `` → `epic-18-retro-item-134-`;
    /// `**A11** — …` → `A11`. A leading item number wins over code later in the cell.
    static func cleanKey(_ cell: String) -> String {
        let plain = cell.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
        if let m = plain.firstMatch(of: /^#?(\d+)\b/) { return String(m.1) }
        var key = plain
        if let id = key.firstMatch(of: /`([^`]*retro-item-[^`]*)`/) { key = String(id.1) }
        else if plain.hasPrefix("`"), let tick = key.firstMatch(of: /`([^`]+)`/) { key = String(tick.1) }
        else if let word = key.firstMatch(of: /^[A-Za-z0-9#-]+/) { key = String(word.0) }
        key = key.replacingOccurrences(of: "#", with: "")
        if let cut = key.firstIndex(of: "…") { key = String(key[..<cut]) }
        return key.trimmingCharacters(in: .whitespaces)
    }

    static func verdict(_ text: String) -> WorkItem.FollowThrough.Verdict {
        let t = text.lowercased().replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("partly") || t.hasPrefix("partial") || t.hasPrefix("half") { return .partly }
        if t.hasPrefix("no") || t.contains("not landed") || t.hasPrefix("deferred") || t.contains("regressed") || t.hasPrefix("✗") { return .notLanded }
        if t.hasPrefix("landed") || t.hasPrefix("yes") || t.hasPrefix("done") || t.hasPrefix("✅") || t.hasPrefix("✓") { return .landed }
        return .unclear
    }

    /// Stories an action became: those whose text cites its retro item number
    /// ("epic-10 retro items 152, 156"), and stories the action names ("Story 5.22").
    static func linkStories(_ project: inout Project) {
        var citations: [Int: Set<String>] = [:]
        let known = Set(project.allStories.map(\.number))
        for story in project.allStories {
            let text = ([story.title] + story.documents.compactMap(\.markdown)).joined(separator: "\n")
                + (project.queue.flatMap(\.entries).first { $0.storyNumber == story.number }?.reason ?? "")
            for m in text.matches(of: /(?i)retro[- ]items?\s+([0-9][0-9,\s–-]*(?:and\s+[0-9]+)?)/) {
                for n in String(m.1).matches(of: /\d+/) { if let v = Int(n.0) { citations[v, default: []].insert(story.number) } }
            }
        }
        for i in project.retroActions.indices {
            let item = project.retroActions[i]
            var linked = Set<String>()
            if let n = item.id.firstMatch(of: /retro-item-(\d+)/).flatMap({ Int($0.1) }) { linked.formUnion(citations[n] ?? []) }
            let own = item.fields.map(\.value).joined(separator: " ") + " " + item.title
            for m in own.matches(of: /(?i)\b(?:story|stories|ticket)\s+(\d+\.\d+[a-z]?)/) where known.contains(String(m.1)) {
                linked.insert(String(m.1))
            }
            project.retroActions[i].linkedStories = linked.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
    }
}

// MARK: Human runs

public enum HumanRuns {
    /// Smoke tests from a `smoke-tests.md` index, checkpoints from a `checkpoints.json`,
    /// and ticket-tree entries marked `hitl = true` that are not finished.
    public static func read(_ project: Project) -> [WorkItem] {
        var out: [WorkItem] = []
        let dirs = [project.sources.storyDirectory, project.sources.statusFile?.deletingLastPathComponent()].compactMap { $0 }
        if let index = dirs.map({ $0.appending(path: "smoke-tests.md") }).first(where: exists),
           let text = try? String(contentsOf: index, encoding: .utf8) {
            out += smokeTests(text, index: index)
        }
        if let planning = project.sources.planningDirectory, let file = find("checkpoints.json", under: planning) {
            out += checkpoints(file)
        }
        for story in project.allStories where story.hitl && !story.status.isTerminal {
            var item = WorkItem(id: "hitl:\(story.id)", kind: .humanRun, label: story.number, title: story.title,
                                status: story.status)
            item.section = "Human-in-the-loop tickets"
            item.epic = story.epicID
            item.linkedStories = [story.number]
            item.source = story.documents.first { $0.label == "Ticket" }?.url
            item.fields = [.init(key: "kind", value: "Human-in-the-loop ticket"), .init(key: "status", value: story.status.raw)]
            out.append(item)
        }
        return out
    }

    /// `| [SMOKE-…](smoke-tests/SMOKE-….md) | What it proves | ✅ `pass`<br>date | Blocking | Gates | Owner |`
    static func smokeTests(_ text: String, index: URL) -> [WorkItem] {
        var out: [WorkItem] = []
        var columns: [String]?
        for (i, line) in text.components(separatedBy: "\n").enumerated() {
            guard line.hasPrefix("|") else { columns = nil; continue }
            let cells = BuildOrder.splitRow(line)
            if columns == nil {
                let lower = cells.map { $0.lowercased() }
                if lower.first == "test", lower.contains("status") { columns = lower }
                continue
            }
            guard let cols = columns, !cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) else { continue }
            func cell(_ name: String) -> String? {
                cols.firstIndex { $0.hasPrefix(name) }.flatMap { $0 < cells.count ? cells[$0] : nil }
            }
            guard let link = cells.first?.firstMatch(of: /\[([^\]]+)\]\(([^)]+)\)/) else { continue }
            let id = String(link.1)
            let statusCell = cell("status") ?? ""
            let status = statusCell.firstMatch(of: #/`([a-z/-]+)`/#).map { String($0.1) } ?? "unknown"
            let date = statusCell.firstMatch(of: /\d{4}-\d{2}-\d{2}/).map { String($0.0) }
            var item = WorkItem(id: id, kind: .humanRun, label: id, title: cell("what") ?? id, status: Status(status))
            item.owner = cell("owner")
            item.section = "Smoke tests"
            item.source = index
            item.line = i + 1
            let spec = index.deletingLastPathComponent().appending(path: String(link.2))
            if exists(spec) { item.related = [spec] }
            item.fields = [
                .init(key: "proves", value: cell("what") ?? ""),
                .init(key: "status", value: status + (date.map { " (last run \($0))" } ?? "")),
                .init(key: "blocking", value: cell("blocking") ?? ""),
                .init(key: "gates", value: cell("gates") ?? ""),
            ].filter { !$0.value.isEmpty && $0.value != "—" }
            out.append(item)
        }
        return out
    }

    static func checkpoints(_ file: URL) -> [WorkItem] {
        guard let data = try? Data(contentsOf: file),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = root["checkpoints"] as? [[String: Any]] else { return [] }
        return list.enumerated().compactMap { i, cp in
            guard let id = cp["id"] as? String else { return nil }
            let title = [cp["checkpoint"] as? String, cp["proves"] as? String].compactMap { $0 }.joined(separator: ": ")
            var item = WorkItem(id: "checkpoint:\(id)", kind: .humanRun, label: "CP\(i + 1)",
                                title: title.isEmpty ? id : title, status: Status(cp["status"] as? String ?? "unknown"))
            item.section = "Checkpoints"
            item.source = file
            if let story = cp["story"] as? String { item.linkedStories = [story] }
            item.fields = ["status", "epic", "story", "verdict", "re_set"].compactMap { key in
                (cp[key] as? String).map { WorkItem.Field(key: key == "re_set" ? "re-set" : key, value: $0) }
            }
            return item
        }
    }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

    static func find(_ name: String, under dir: URL) -> URL? {
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        while let url = e?.nextObject() as? URL {
            if url.lastPathComponent == name { return url }
        }
        return nil
    }
}
