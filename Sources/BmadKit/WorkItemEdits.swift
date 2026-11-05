import Foundation

/// The writes beyond review completion: a smoke test or checkpoint recorded as
/// passed, progress and resolution on a retro action, a new `DW-` entry on the
/// deferred-work ledger. Like `ReviewCompletion` these are worked out as line
/// edits against the files as they read now, so they can be shown for
/// confirmation and applied through `ReviewCompletion.apply` — which writes
/// nothing when a line has changed since it was read.
public enum WorkItemEdits {
    public enum Refusal: Error, Equatable, LocalizedError {
        case noSource
        case alreadyPassed
        case itemGone
        case cellNotFound
        case notATrackedItem
        case noLedger
        case nothingToRecord

        public var errorDescription: String? {
            switch self {
            case .noSource: "The file this item is written in is gone."
            case .alreadyPassed: "This run already reads as passed."
            case .itemGone: "The line this item belongs to is gone; reload and try again."
            case .cellNotFound: "Could not find this item's status cell."
            case .notATrackedItem: "Only action items tracked in sprint-status.yaml can be recorded here."
            case .noLedger: "There is no deferred-work.md to append to."
            case .nothingToRecord: "There is nothing written to record."
            }
        }
    }

    /// The local date as ledgers and run records write it.
    public static func today(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func read(_ url: URL) -> [String]? {
        (try? String(contentsOf: url, encoding: .utf8))?.components(separatedBy: "\n")
    }

    /// Text written as one line: a pasted newline would break a table row, a
    /// YAML value and a ledger heading alike.
    static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }

    // MARK: Smoke tests

    /// The `smoke-tests.md` row set to passed: its status cell becomes ``pass``
    /// with today's date, the rest of the row untouched.
    public static func smokeTestPass(_ item: WorkItem) -> Result<[ReviewCompletion.Edit], Refusal> {
        guard let url = item.source, let row = item.line else { return .failure(.noSource) }
        guard item.status.kind != .done else { return .failure(.alreadyPassed) }
        guard let lines = read(url) else { return .failure(.noSource) }
        guard row >= 1, row <= lines.count, lines[row - 1].hasPrefix("|") else { return .failure(.itemGone) }
        // The column to write comes from the table header above the row. Cells are
        // split on `|` here and there, so a row with a stray pipe is refused.
        var header: [String]?
        var i = row - 2
        while i >= 0, lines[i].hasPrefix("|") {
            let cells = lines[i].components(separatedBy: "|")
            if cells.contains(where: { $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("status") }) {
                header = cells
                break
            }
            i -= 1
        }
        guard let header,
              let at = header.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("status") })
        else { return .failure(.cellNotFound) }
        var cells = lines[row - 1].components(separatedBy: "|")
        guard cells.count == header.count, at < cells.count else { return .failure(.cellNotFound) }
        cells[at] = " ✅ `pass`<br>\(today()) "
        return .success([.init(url: url, line: row, before: lines[row - 1], after: cells.joined(separator: "|"))])
    }

    // MARK: Checkpoints

    /// The `"status"` of this checkpoint's entry in `checkpoints.json` set to `pass`.
    public static func checkpointPass(_ item: WorkItem) -> Result<[ReviewCompletion.Edit], Refusal> {
        guard let url = item.source, item.id.hasPrefix("checkpoint:") else { return .failure(.noSource) }
        let id = String(item.id.dropFirst("checkpoint:".count))
        guard let lines = read(url) else { return .failure(.noSource) }
        // The entry's id line, then its status: just below it, or just above when
        // the file writes the keys in the other order — but never past a brace.
        guard let at = lines.firstIndex(where: {
            $0.range(of: "\"id\"\\s*:\\s*\"\(id)\"", options: .regularExpression) != nil
        }) else { return .failure(.itemGone) }
        let statusKey = /"status"\s*:\s*(?<value>"[^"]*")/
        for (from, to, stride) in [(at, min(at + 40, lines.count - 1), 1), (max(at - 1, 0), max(at - 40, 0), -1)] as [(Int, Int, Int)] {
            var i = from
            while (stride == 1 && i <= to) || (stride == -1 && i >= to) {
                let line = lines[i]
                if i != at, line.contains(stride == 1 ? "}" : "{") { break }
                if let m = line.firstMatch(of: statusKey) {
                    let current = m.value.dropFirst().dropLast()
                    if current == "pass" || current == "passed" { return .failure(.alreadyPassed) }
                    // Only the value is rewritten: the key and its spacing are the
                    // file's own, so the entry keeps the shape it was written in.
                    let keyAndColon = m.0.dropLast(m.value.count)
                    let after = line.replacing(statusKey) { _ in "\(keyAndColon)\"pass\"" }
                    return .success([.init(url: url, line: i + 1, before: line, after: after)])
                }
                i += stride
            }
        }
        return .failure(.cellNotFound)
    }

    // MARK: Retro actions

    /// A `progress:` / `resolution:` note on a `sprint-status.yaml` action item:
    /// each replaces the line already there, or is added at the block's end.
    public static func retroActionRecord(_ item: WorkItem, in project: Project,
                                         progress: String?, resolution: String?) -> Result<[ReviewCompletion.Edit], Refusal> {
        guard let url = project.sources.statusFile, item.source == url else { return .failure(.notATrackedItem) }
        guard let lines = read(url) else { return .failure(.noSource) }
        guard let at = lines.firstIndex(where: { $0.contains("id: \"\(item.id)\"") || $0.contains("id: \(item.id)") }) else {
            return .failure(.itemGone)
        }
        // The item's block: the dash line and everything indented past its dash.
        let dashIndent = lines[at].prefix(while: { $0 == " " }).count
        var end = at + 1
        var last = at
        while end < lines.count {
            if lines[end].trimmingCharacters(in: .whitespaces).isEmpty { end += 1; continue }
            if lines[end].prefix(while: { $0 == " " }).count <= dashIndent { break }
            last = end
            end += 1
        }
        // Where the block's keys sit: the first key line under the dash.
        var keyIndent = dashIndent + 2
        for i in (at + 1)..<end {
            let indent = lines[i].prefix(while: { $0 == " " }).count
            guard indent > dashIndent, lines[i].dropFirst(indent).first?.isLetter == true, lines[i].contains(":") else { continue }
            keyIndent = indent
            break
        }
        var edits: [ReviewCompletion.Edit] = []
        var appended: [String] = []
        var replaced: Set<Int> = []
        for (name, raw) in [("progress", progress), ("resolution", resolution)] {
            let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { continue }
            let newLine = "\(String(repeating: " ", count: keyIndent))\(name): \"\(yamlText(text))\""
            if let i = ((at + 1)..<end).first(where: { lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("\(name):") }) {
                guard lines[i] != newLine else { continue }
                edits.append(.init(url: url, line: i + 1, before: lines[i], after: newLine))
                replaced.insert(i)
            } else {
                appended.append(newLine)
            }
        }
        guard !edits.isEmpty || !appended.isEmpty else { return .failure(.nothingToRecord) }
        if !appended.isEmpty {
            // New keys go at the block's end — onto the last line no other edit
            // rewrites, so no two edits claim the same line.
            var anchor = last
            while replaced.contains(anchor) { anchor -= 1 }
            let before = lines[anchor]
            edits.append(.init(url: url, line: anchor + 1, before: before,
                               after: before + "\n" + appended.joined(separator: "\n")))
        }
        return .success(edits)
    }

    /// The note as a YAML double-quoted scalar on one line.
    static func yamlText(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }

    // MARK: Deferred work

    /// The number the next `### DW-<n>:` heading takes.
    public static func nextLedgerNumber(_ project: Project) -> Int {
        (project.deferredWork.compactMap { $0.label.wholeMatch(of: /DW-(\d+)/).flatMap { Int($0.1) } }.max() ?? 0) + 1
    }

    /// A new canonical `### DW-<n>:` entry appended to the ledger's end — one edit
    /// anchored on the file's last line, so it lands only while that line is still
    /// what it was when the entry was composed.
    public static func ledgerAppend(title: String, severity: String?, owner: String?, detail: String?,
                                    to url: URL?, number: Int, date: String = today()) -> Result<[ReviewCompletion.Edit], Refusal> {
        guard let url else { return .failure(.noLedger) }
        let title = oneLine(title)
        guard !title.isEmpty else { return .failure(.nothingToRecord) }
        guard let lines = read(url), !lines.isEmpty else { return .failure(.noSource) }
        var entry = ["### DW-\(number): \(title)", "status: open"]
        for (key, raw) in [("severity", severity), ("owner", owner)] {
            let value = raw.map(oneLine) ?? ""
            if !value.isEmpty { entry.append("\(key): \(value)") }
        }
        entry.append("created: \(date)")
        let detail = detail.map(oneLine) ?? ""
        if !detail.isEmpty { entry.append("detail: \(detail)") }
        let last = lines.count - 1
        let before = lines[last]
        // The file's own trailing newline is already the blank line; without one,
        // write the blank in.
        let gap = before.trimmingCharacters(in: .whitespaces).isEmpty ? "\n" : "\n\n"
        return .success([.init(url: url, line: last + 1, before: before, after: before + gap + entry.joined(separator: "\n"))])
    }
}
