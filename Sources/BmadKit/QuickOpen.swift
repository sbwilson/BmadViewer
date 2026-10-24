import Foundation

/// Something ⌘K can jump to.
public struct QuickOpenItem: Identifiable, Hashable, Sendable {
    public enum Kind: Int, Sendable, Comparable {
        case story, epic, retro, deferred, document, file

        public static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }

        public var label: String {
            switch self {
            case .story: "Story"
            case .epic: "Epic"
            case .retro: "Retro action"
            case .deferred: "Deferred"
            case .document: "Document"
            case .file: "File"
            }
        }
    }

    public enum Target: Hashable, Sendable {
        case story(String)
        case epic(String)
        case workItem(WorkItem.Kind, String)
        case document(URL)
        case file(URL)
    }

    public let id: String
    public let kind: Kind
    public let title: String
    public let subtitle: String
    /// What an exact query names it by: `9.16`, `DW-12`, `139`.
    public let key: String?
    /// What the fuzzy match runs over, besides the title.
    public let searchText: String
    public let target: Target
    public var status: Status?
}

public enum QuickOpen {
    public struct Result: Identifiable, Hashable, Sendable {
        public var id: String { item.id }
        public let item: QuickOpenItem
        public let score: Int
        /// `core.rs:940` asks for those lines.
        public let lines: LineRange?

        public init(item: QuickOpenItem, score: Int, lines: LineRange?) {
            self.item = item
            self.score = score
            self.lines = lines
        }
    }

    // MARK: Index

    public static func items(for project: Project, files: [String]) -> [QuickOpenItem] {
        var out: [QuickOpenItem] = []
        for epic in project.epics {
            out.append(QuickOpenItem(
                id: "epic:\(epic.id)", kind: .epic, title: epic.title,
                subtitle: [epic.number.map { "Epic \($0)" }, epic.status.raw].compactMap { $0 }.joined(separator: " · "),
                key: epic.number.map { "epic \($0)" }, searchText: "epic \(epic.number ?? "") \(epic.id)",
                target: .epic(epic.id), status: epic.status
            ))
            for story in epic.stories {
                out.append(QuickOpenItem(
                    id: "story:\(story.id)", kind: .story, title: story.title,
                    subtitle: "\(story.type?.capitalized ?? "Story") \(story.number) · \(epic.title)",
                    key: story.number, searchText: "\(story.number) \(story.id)",
                    target: .story(story.id), status: story.status
                ))
            }
        }
        for item in project.retroActions {
            out.append(QuickOpenItem(
                id: "retro:\(item.id)", kind: .retro, title: item.title,
                subtitle: ["Retro action \(item.label)", item.owner].compactMap { $0 }.joined(separator: " · "),
                key: item.label, searchText: "\(item.label) \(item.id)",
                target: .workItem(.retroAction, item.id), status: item.status
            ))
        }
        for item in project.deferredWork {
            out.append(QuickOpenItem(
                id: "deferred:\(item.id)", kind: .deferred, title: item.title,
                subtitle: [item.label, item.severity, item.owner].compactMap { $0 }.joined(separator: " · "),
                key: item.label, searchText: item.label,
                target: .workItem(.deferred, item.id), status: item.status
            ))
        }
        for url in project.documents {
            out.append(QuickOpenItem(
                id: "document:\(url.path(percentEncoded: false))", kind: .document, title: url.lastPathComponent,
                subtitle: relative(url, to: project.root), key: nil, searchText: relative(url, to: project.root),
                target: .document(url)
            ))
        }
        for path in files {
            let url = project.root.appending(path: path)
            out.append(QuickOpenItem(
                id: "file:\(path)", kind: .file, title: (path as NSString).lastPathComponent,
                subtitle: (path as NSString).deletingLastPathComponent, key: nil, searchText: path,
                target: .file(url)
            ))
        }
        return out
    }

    /// Tracked and untracked-but-not-ignored files, relative to `root`, from git;
    /// a bounded walk that skips build output when `root` is not a repository.
    public static func listFiles(root: URL, limit: Int = 50_000) -> [String] {
        if let text = try? GitDiff.git(["ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", "."], in: root) {
            return Array(text.split(separator: "\0").map(String.init).prefix(limit))
        }
        let skip: Set<String> = [".git", ".build", "build", "target", "node_modules", "DerivedData", ".swiftpm"]
        var out: [String] = []
        // Resolve symlinks on both sides: /var vs /private/var would misalign the prefix.
        var base = root.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        while base.hasSuffix("/") { base.removeLast() }
        let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        while let url = e?.nextObject() as? URL, out.count < limit {
            if skip.contains(url.lastPathComponent) { e?.skipDescendants(); continue }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
            if path.hasPrefix(base + "/") { out.append(String(path.dropFirst(base.count + 1))) }
        }
        return out
    }

    static func relative(_ url: URL, to root: URL) -> String {
        let r = root.standardizedFileURL.path(percentEncoded: false)
        let p = url.standardizedFileURL.path(percentEncoded: false)
        return p.hasPrefix(r) ? String(p.dropFirst(r.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) : p
    }

    // MARK: Search

    public static func search(_ query: String, in items: [QuickOpenItem], limit: Int = 60) -> [Result] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        // `core.rs:940` / `core.rs#L940`: match the path, carry the lines.
        let (pathPart, lines) = LineRef.split(q)
        let lowered = q.lowercased()
        var results: [Result] = []
        for item in items {
            var best: Int?
            if let key = item.key?.lowercased(), key == lowered || key == "dw-\(lowered)" {
                best = 10_000
            }
            if item.kind == .file || item.kind == .document {
                let needle = (lines != nil ? pathPart : q).lowercased()
                let s = max(score(needle, item.title.lowercased()).map { $0 + 25 } ?? Int.min,
                            score(needle, item.searchText.lowercased()) ?? Int.min)
                // Archived copies rank below the live file of the same name.
                let archived = item.searchText.contains("archive/") ? 15 : 0
                if s > Int.min { best = max(best ?? Int.min, s - archived) }
            } else {
                let s = max(score(lowered, item.title.lowercased()) ?? Int.min,
                            score(lowered, item.searchText.lowercased()).map { $0 + 10 } ?? Int.min)
                if s > Int.min { best = max(best ?? Int.min, s + 15) }
            }
            if let best {
                let carry = item.kind == .file || item.kind == .document ? lines : nil
                results.append(Result(item: item, score: best, lines: carry))
            }
        }
        results.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.item.kind != $1.item.kind { return $0.item.kind < $1.item.kind }
            return $0.item.title.count < $1.item.title.count
        }
        return Array(results.prefix(limit))
    }

    /// A subsequence match of `query` in `candidate` (both lowercased), scored for
    /// word starts, runs and a contiguous substring; nil when the query's letters
    /// do not all appear in order.
    public static func score(_ query: String, _ candidate: String) -> Int? {
        let q = Array(query.filter { $0 != " " })
        let c = Array(candidate)
        guard !q.isEmpty, q.count <= c.count else { return nil }
        var score = 0
        var qi = 0
        var previous = -2
        var firstMatch: Int?
        for (ci, ch) in c.enumerated() where qi < q.count {
            guard ch == q[qi] else { continue }
            if firstMatch == nil { firstMatch = ci }
            var s = 1
            let boundary = ci == 0 || "/_-. :#".contains(c[ci - 1])
            if boundary { s += 8 }
            if previous == ci - 1 { s += 6 }
            else if previous >= 0 { s -= min(4, ci - previous - 1) }
            score += s
            previous = ci
            qi += 1
        }
        guard qi == q.count else { return nil }
        if let range = candidate.range(of: String(q)) {
            score += 30
            if range.lowerBound == candidate.startIndex { score += 20 }
        }
        // Shorter candidates and earlier matches read as closer.
        score -= min(15, (firstMatch ?? 0) / 4) + min(10, c.count / 20)
        return score
    }
}
