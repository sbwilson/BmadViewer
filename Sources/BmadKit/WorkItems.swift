import Foundation
import Yams

/// A retrospective action item or a deferred-work entry: something owed that is
/// not a story.
public struct WorkItem: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case retroAction = "Retro action"
        case deferred = "Deferred work"
        case humanRun = "Human runs"
    }

    /// What the next retrospective found when it checked this action.
    public struct FollowThrough: Hashable, Sendable {
        public enum Verdict: String, Sendable { case landed, partly, notLanded, unclear }
        public let verdict: Verdict
        /// The cell as written ("Landed", "Partly. The register row…").
        public let text: String
        public let evidence: String?
        /// The retrospective that checked it, and the table row.
        public let source: URL
        public let line: Int
    }

    public struct Field: Hashable, Sendable {
        public let key: String
        public let value: String
    }

    /// Unique within its kind: `epic-10-retro-item-139`, `DW-12`, `deferred-work.md:32`.
    public let id: String
    public let kind: Kind
    /// What to show in a list: `DW-12`, `#3`, `139`.
    public var label: String
    public var title: String
    public var status: Status
    public var owner: String?
    /// The epic it came from, as the project names epics (`10`, `epic-ledger-workspace`).
    public var epic: String?
    public var severity: String?
    /// The grouping it was written under: a retro's `### Remediation`, a ledger's `## 1.12 sweep`.
    public var section: String?
    /// The file it is written in.
    public var source: URL?
    /// The 1-based line where it starts in `source`.
    public var line: Int?
    /// Other files it points at (a retro doc from `ref:`).
    public var related: [URL] = []
    /// Every field in file order, repeats kept (`sweep …:`, `seen-again:`).
    public var fields: [Field] = []
    /// Story keys a `gate:` line blocks.
    public var gates: [String] = []
    /// Stories this item became or names (`9.16` from "retro item 152" in its text).
    public var linkedStories: [String] = []
    public var followThrough: FollowThrough?

    public init(id: String, kind: Kind, label: String, title: String, status: Status) {
        self.id = id
        self.kind = kind
        self.label = label
        self.title = title
        self.status = status
    }

    public func value(_ key: String) -> String? { fields.first { $0.key == key }?.value }

    /// The item as readable markdown for the detail view.
    public var markdown: String {
        // The header already shows the title, status, owner, severity, gates and the
        // linked ref; the body is everything else, minus a field that only repeats the title.
        var md = ""
        let shown: Set<String> = ["status", "owner", "severity", "epic", "id", "gate", "ref"]
        for f in fields where !shown.contains(f.key) && f.value.replacingOccurrences(of: "**", with: "") != title {
            let key = f.key.replacingOccurrences(of: "_", with: " ")
            md += "**\(key.prefix(1).uppercased() + key.dropFirst()).** \(f.value)\n\n"
        }
        return md.isEmpty ? "_No further detail._" : md
    }
}

/// Reads deferred-work ledgers and retrospective action items.
public enum WorkItems {
    // MARK: Deferred work

    /// A `deferred-work.md` in the canonical format (`### DW-<n>: title` then one
    /// `key: value` line per field), plus legacy flat-append bullets (`- source_spec:`,
    /// `- source_plan:`, `- disposition:` with indented continuation fields).
    public static func deferredWork(_ text: String, source: URL?) -> [WorkItem] {
        var items: [WorkItem] = []
        var current: WorkItem?
        var legacy = false
        var section: String?
        var inFence = false

        func close() {
            if var item = current {
                finish(&item, legacy: legacy)
                items.append(item)
            }
            current = nil
            legacy = false
        }

        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            let lineNumber = index + 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inFence.toggle() }
            if inFence { continue }

            let first = line.first
            if first == "#" || first == " ", let m = line.wholeMatch(of: /###\s+(DW-\d+):\s*(.*)/) {
                close()
                var item = WorkItem(id: String(m.1), kind: .deferred, label: String(m.1),
                                    title: String(m.2).trimmingCharacters(in: .whitespaces), status: Status("open"))
                item.source = source
                item.line = lineNumber
                item.section = section
                current = item
                continue
            }
            // Any other heading ends an entry, and a `##` names the group that follows.
            if trimmed.hasPrefix("#"), let m = line.wholeMatch(of: /\s{0,3}(#{1,6})(?:\s+(.*))?/) {
                close()
                if m.1.count == 2 { section = m.2.map(String.init) }
                continue
            }
            // A flat-append bullet: `- key: value` at the left margin starts a legacy item.
            if first == "-", let m = line.wholeMatch(of: /-\s+([a-z_][a-z0-9_-]*):\s?(.*)/) {
                close()
                var item = WorkItem(id: "\(source?.lastPathComponent ?? "deferred"):\(lineNumber)", kind: .deferred,
                                    label: "L\(lineNumber)", title: "", status: Status("open"))
                item.source = source
                item.line = lineNumber
                item.section = section
                item.fields.append(.init(key: String(m.1), value: String(m.2)))
                current = item
                legacy = true
                continue
            }
            guard current != nil else { continue }
            if legacy {
                if let m = line.wholeMatch(of: /\s{2,}([a-z_][a-z0-9_-]*):\s?(.*)/) {
                    current!.fields.append(.init(key: String(m.1), value: String(m.2)))
                } else if trimmed.isEmpty {
                    close()
                } else if line.hasPrefix("  "), let last = current!.fields.indices.last {
                    // A wrapped continuation of the previous field.
                    let f = current!.fields[last]
                    current!.fields[last] = .init(key: f.key, value: f.value + " " + trimmed)
                }
            } else if let field = field(line) {
                current!.fields.append(field)
            }
        }
        close()
        return items
    }

    /// `key: value` at the left margin, the key lowercase words (`sweep 2026-09-22` is a key).
    /// Hand-rolled: a ledger runs to ten thousand lines and a Regex per line costs seconds.
    static func field(_ line: String) -> WorkItem.Field? {
        guard let first = line.unicodeScalars.first, ("a"..."z").contains(first) || first == "_",
              let colon = line.firstIndex(of: ":") else { return nil }
        let key = line[..<colon]
        guard key.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || "_- ".unicodeScalars.contains($0) })
        else { return nil }
        var value = line[line.index(after: colon)...]
        if value.first == " " { value = value.dropFirst() }
        return .init(key: String(key), value: String(value))
    }

    static let closedWords = ["done", "fixed", "closed", "resolved", "obsolete", "dropped", "wontfix", "won't fix", "duplicate", "superseded"]

    static func finish(_ item: inout WorkItem, legacy: Bool) {
        item.owner = item.value("owner")
        item.severity = item.value("severity")
        item.gates = item.fields.filter { $0.key == "gate" }
            .flatMap { $0.value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
            .filter { !$0.isEmpty }
        if let status = item.value("status") {
            // `done 2026-06-20`: the word is the status, the date stays in the field.
            item.status = Status(String(status.split(separator: " ").first ?? "open"))
        } else if let disposition = item.value("disposition") {
            let d = disposition.lowercased()
            item.status = Status(closedWords.contains { d.hasPrefix($0) } ? "done" : "open")
        }
        if legacy {
            let summary = item.value("summary") ?? item.value("reason") ?? item.value("title") ?? item.fields.first?.value ?? ""
            item.title = summary
            item.label = item.value("disposition").map { _ in "L\(item.line ?? 0)" } ?? "L\(item.line ?? 0)"
        }
    }

    // MARK: Retro actions from sprint-status.yaml

    /// `action_items:` in a v6 `sprint-status.yaml`: `id`, `epic`, `action`, `owner`, `status`, `ref`.
    public static func sprintActionItems(_ text: String, statusFile: URL, root: URL) -> [WorkItem] {
        guard let map = (try? Yams.load(yaml: text)) as? [String: Any],
              let list = map["action_items"] as? [[String: Any]] else { return [] }
        let lines = text.components(separatedBy: "\n")
        return list.enumerated().map { index, raw in
            let id = raw["id"].map { "\($0)" } ?? "action-\(index + 1)"
            let action = (raw["action"].map { "\($0)" } ?? id)
                .replacingOccurrences(of: "\n", with: " ")
            var item = WorkItem(
                id: id, kind: .retroAction,
                label: id.wholeMatch(of: /.*-retro-item-(\d+).*/).map { String($0.1) } ?? "\(index + 1)",
                title: action, status: Status(raw["status"].map { "\($0)" } ?? "open")
            )
            item.owner = raw["owner"].map { "\($0)" }
            item.epic = raw["epic"].map { "\($0)" }
            item.source = statusFile
            item.line = lines.firstIndex { $0.contains("id: \"\(id)\"") || $0.contains("id: \(id)") }.map { $0 + 1 }
            if let ref = raw["ref"] as? String {
                let url = ref.hasPrefix("/") ? URL(filePath: ref) : root.appending(path: ref)
                if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) { item.related = [url] }
            }
            let order = ["action", "owner", "status", "progress", "resolution", "ref"]
            let keys = order.filter { raw[$0] != nil } + raw.keys.filter { !order.contains($0) && $0 != "id" && $0 != "epic" }.sorted()
            item.fields = keys.map { .init(key: $0, value: "\(raw[$0]!)".replacingOccurrences(of: "\n", with: " ")) }
            return item
        }
    }

    // MARK: Retro actions from a retrospective document

    /// The `## Action items` section of a retrospective: numbered or bulleted items, or
    /// a table with an `Action` column, grouped by the `###` heading above them.
    /// A retrospective file carries no status for its items, so they read as `proposed`.
    public static func retrospectiveActions(_ text: String, source: URL, epic: String?) -> [WorkItem] {
        var items: [WorkItem] = []
        var inSection = false
        var section: String?
        var columns: [String]?
        let lines = text.components(separatedBy: "\n")
        var i = 0
        func add(_ number: String, _ text: String, owner: String?, line: Int) {
            var title = text
            var fields: [WorkItem.Field] = []
            // `**Short title (A3):** detail` → a title and a detail field.
            // A short lead-in (`**Fix F1** (blocking): …`) says too little alone, so the
            // whole sentence is the title.
            if let m = text.wholeMatch(of: /\*\*(.+?)\*\*:?\s*(.*)/), m.1.count >= 30 || m.2.isEmpty {
                title = String(m.1).trimmingCharacters(in: CharacterSet(charactersIn: ": "))
                if !m.2.isEmpty { fields.append(.init(key: "detail", value: String(m.2))) }
            } else if text.hasPrefix("**") {
                title = text.replacingOccurrences(of: "**", with: "")
                fields.append(.init(key: "action", value: text))
            } else {
                fields.append(.init(key: "action", value: text))
            }
            var item = WorkItem(id: "\(source.lastPathComponent)#\(number)", kind: .retroAction,
                                label: "#\(number)", title: title, status: Status("proposed"))
            item.owner = owner ?? text.firstMatch(of: /Owner:\s*([^.(]+)/).map { String($0.1).trimmingCharacters(in: .whitespaces) }
            item.epic = epic
            item.section = section
            item.source = source
            item.line = line
            item.fields = fields
            items.append(item)
        }
        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix("## ") {
                inSection = line.lowercased().hasPrefix("## action items")
                section = nil
                columns = nil
                i += 1
                continue
            }
            guard inSection else { i += 1; continue }
            if line.hasPrefix("### ") {
                section = String(line.dropFirst(4))
                columns = nil
            } else if let m = line.wholeMatch(of: /\s{0,3}(?:(\d+)[.)]|[-*])\s+(.+)/) {
                var text = String(m.2)
                // Fold wrapped continuation lines into the item.
                while i + 1 < lines.count, lines[i + 1].hasPrefix("   "), !lines[i + 1].trimmingCharacters(in: .whitespaces).isEmpty {
                    i += 1
                    text += " " + lines[i].trimmingCharacters(in: .whitespaces)
                }
                add(m.1.map(String.init) ?? "\(items.count + 1)", text, owner: nil, line: i + 1)
            } else if line.hasPrefix("|") {
                let cells = BuildOrder.splitRow(line)
                if columns == nil {
                    if cells.contains(where: { $0.lowercased() == "action" }) { columns = cells.map { $0.lowercased() } }
                } else if !cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }), let cols = columns {
                    func cell(_ name: String) -> String? {
                        cols.firstIndex(of: name).flatMap { $0 < cells.count ? cells[$0] : nil }
                    }
                    if let action = cell("action"), !action.isEmpty {
                        add(cell("#") ?? "\(items.count + 1)", action, owner: cell("owner"), line: i + 1)
                    }
                }
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                // Blank lines separate groups; a table ends at one.
                columns = nil
            }
            i += 1
        }
        return items
    }
}
