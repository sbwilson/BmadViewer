import Foundation

/// Scope and progress over time, per epic, replayed from git history: every
/// change to `sprint-status.yaml`'s statuses (sprint-status projects), or to the
/// ticket tree's `tickets.toml` entries and plan statuses (ticket trees).
public enum Burnup {
    public struct Counts: Hashable, Sendable {
        /// Stories in scope: superseded and dropped ones are out.
        public var total = 0
        public var done = 0
        /// Built and awaiting done (ticket trees).
        public var built = 0
    }

    public struct Snapshot: Hashable, Sendable {
        public let date: Date
        public let commit: String
        public let epics: [String: Counts]

        public func counts(epic: String?) -> Counts {
            if let epic { return epics[epic] ?? Counts() }
            return epics.values.reduce(into: Counts()) { $0.total += $1.total; $0.done += $1.done; $0.built += $1.built }
        }
    }

    public static func history(_ project: Project) throws -> [Snapshot] {
        switch project.layout {
        case .sprintStatus:
            guard let file = project.sources.statusFile else { return [] }
            let repo = try GitDiff.repositoryRoot(for: project.root)
            // One line of context, so a wrapped value's key line shows when only the value changed.
            let text = try GitDiff.git(["log", "--reverse", "--no-color", "--first-parent", "-m", "--format=>>> %H %ct", "-p", "-U1", "--",
                                        GitDiff.relativePath(file, in: repo)], in: repo)
            return replaySprintStatus(text)
        case .ticketTree:
            guard let initiative = project.sources.planningDirectory else { return [] }
            let repo = try GitDiff.repositoryRoot(for: project.root)
            let text = try GitDiff.git(["log", "--reverse", "--no-color", "--first-parent", "-m", "--format=>>> %H %ct", "-p", "-U0", "--",
                                        GitDiff.relativePath(initiative, in: repo)], in: repo)
            return replayTicketTree(text, epicIDs: Set(project.epics.map(\.id)))
        }
    }

    // MARK: sprint-status.yaml

    /// Replays the log hunk by hunk: each hunk's old side (context and removed lines)
    /// and new side (context and added lines) are read as `development_status` pairs,
    /// so a value wrapped under a long key (`18-5-…:` then `    done`) and git's
    /// removed-then-added ordering both come out right.
    static func replaySprintStatus(_ log: String) -> [Snapshot] {
        var statuses: [String: String] = [:]
        var out: [Snapshot] = []
        var commit: (String, Date)?
        var added: [String: String] = [:]
        var removed = Set<String>()
        var epicOf: [String: String?] = [:]   // key → epic, parsed once
        var oldSide: [Substring] = []
        var newSide: [Substring] = []
        var inHunk = false

        func flushHunk() {
            let before = pairs(oldSide), after = pairs(newSide)
            let kept = Set(after.map(\.0))
            for (k, _) in before where !kept.contains(k) { removed.insert(k) }
            for (k, v) in after { added[k] = v }
            oldSide = []
            newSide = []
        }

        func close() {
            flushHunk()
            guard let (hash, date) = commit else { return }
            for key in removed where added[key] == nil { statuses[key] = nil }
            for (k, v) in added { statuses[k] = v }
            var epics: [String: Counts] = [:]
            for (key, status) in statuses {
                let epic: String?
                if let cached = epicOf[key] { epic = cached } else {
                    if case .story(let e, _, _) = SprintStatus.Key(key) { epic = e } else { epic = nil }
                    epicOf[key] = epic
                }
                guard let e = epic else { continue }
                let s = Status(status)
                if s.kind == .superseded { continue }
                epics[e, default: Counts()].total += 1
                if s.kind == .done { epics[e, default: Counts()].done += 1 }
            }
            out.append(Snapshot(date: date, commit: hash, epics: epics))
            added = [:]
            removed = []
        }

        for line in log.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(">>> ") {
                close()
                inHunk = false
                let parts = line.dropFirst(4).split(separator: " ")
                commit = parts.count == 2 ? (String(parts[0]), Date(timeIntervalSince1970: TimeInterval(parts[1]) ?? 0)) : nil
                continue
            }
            if line.hasPrefix("@@") { flushHunk(); inHunk = true; continue }
            if line.hasPrefix("diff --git") { flushHunk(); inHunk = false; continue }
            guard inHunk, let first = line.first else { continue }
            let body = line.dropFirst()
            switch first {
            case " ": oldSide.append(body); newSide.append(body)
            case "-": oldSide.append(body)
            case "+": newSide.append(body)
            default: break
            }
        }
        close()
        return out
    }

    /// `development_status` entries in a run of file lines: `  key: value`, or
    /// `  key:` with the value on the next, deeper line.
    static func pairs(_ lines: [Substring]) -> [(String, String)] {
        var out: [(String, String)] = []
        var pending: String?
        for line in lines {
            // Cheap checks first: the log carries long prose lines a Regex would crawl.
            guard line.utf8.count < 300, line.hasPrefix("  ") else { pending = nil; continue }
            if line.hasPrefix("    ") {
                if let key = pending, let v = line.wholeMatch(of: /\s+([\w-]+)\s*(?:#.*)?/) { out.append((key, String(v.1))) }
                pending = nil
                continue
            }
            if let m = line.wholeMatch(of: /\ \ ([\w.-]+):\s*([\w-]+)?\s*(?:#.*)?/) {
                if let v = m.2 { out.append((String(m.1), String(v))); pending = nil } else { pending = String(m.1) }
            } else {
                pending = nil
            }
        }
        return out
    }

    // MARK: Ticket tree

    /// Scope from `id = N` lines in each epic's `tickets.toml` (`[[entry]]` tables);
    /// progress from `status:` lines in the plans beside them.
    static func replayTicketTree(_ log: String, epicIDs: Set<String>) -> [Snapshot] {
        var entries: [String: Set<Int>] = [:]       // epic folder → entry ids
        var plans: [String: (epic: String, status: String)] = [:]
        var out: [Snapshot] = []
        var commit: (String, Date)?
        var file: String?

        func epic(of path: String) -> String? {
            path.split(separator: "/").map(String.init).last { epicIDs.contains($0) }
        }

        func close() {
            guard let (hash, date) = commit else { return }
            var epics: [String: Counts] = [:]
            for (e, ids) in entries { epics[e, default: Counts()].total = ids.count }
            for (_, p) in plans {
                switch Status(p.status).kind {
                case .done: epics[p.epic, default: Counts()].done += 1
                case .built, .review: epics[p.epic, default: Counts()].built += 1
                case .superseded: epics[p.epic, default: Counts()].total -= 1
                default: break
                }
            }
            out.append(Snapshot(date: date, commit: hash, epics: epics))
        }

        var pendingAdds: [String: Set<Int>] = [:]
        var pendingRemoves: [String: Set<Int>] = [:]
        func flushFile() {
            for (e, ids) in pendingRemoves { entries[e, default: []].subtract(ids.subtracting(pendingAdds[e] ?? [])) }
            for (e, ids) in pendingAdds { entries[e, default: []].formUnion(ids) }
            pendingAdds = [:]
            pendingRemoves = [:]
        }

        for line in log.components(separatedBy: "\n") {
            if line.hasPrefix(">>> ") {
                flushFile()
                close()
                let parts = line.dropFirst(4).split(separator: " ")
                commit = parts.count == 2 ? (String(parts[0]), Date(timeIntervalSince1970: TimeInterval(parts[1]) ?? 0)) : nil
                file = nil
                continue
            }
            if line.hasPrefix("+++ ") {
                flushFile()
                let path = String(line.dropFirst(4))
                file = path == "/dev/null" ? nil : String(path.dropFirst(2))   // "b/…"
                continue
            }
            if line.hasPrefix("--- ") {
                // A deleted file has `+++ /dev/null`; remember the old path for its removals.
                let path = String(line.dropFirst(4))
                if path != "/dev/null" { file = String(path.dropFirst(2)) }
                continue
            }
            guard line.utf8.count < 200, line.first == "+" || line.first == "-",
                  let path = file, let e = epic(of: path) else { continue }
            if path.hasSuffix("/tickets.toml") {
                guard let m = line.wholeMatch(of: /([+-])id\s*=\s*(\d+)\s*/), let id = Int(m.2) else { continue }
                if m.1 == "+" { pendingAdds[e, default: []].insert(id) } else { pendingRemoves[e, default: []].insert(id) }
            } else if path.hasSuffix("-plan.md") {
                if let m = line.wholeMatch(of: /\+status:\s*['"]?([\w-]+)['"]?.*/) {
                    plans[path] = (e, String(m.1))
                }
            }
        }
        flushFile()
        close()
        return out
    }
}
