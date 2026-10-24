import Foundation

/// What a story changed, read from git: the range from the story's recorded
/// baseline (`baseline_commit` / `baseline_revision`) to where it ended, the files
/// that range touched, and a file's unified diff.
public enum GitDiff {
    public enum Failure: Error, LocalizedError, Equatable {
        case notARepository
        case unknownCommit(String)
        case git(String)

        public var errorDescription: String? {
            switch self {
            case .notARepository: "The project is not in a git repository."
            case .unknownCommit(let c): "Commit \(c.prefix(10)) is not in this repository."
            case .git(let message): message
            }
        }
    }

    /// Where a range ends.
    public enum End: String, Codable, CaseIterable, Sendable {
        /// The last commit that touched the story's document: the story's own commit,
        /// or the working tree when that document has uncommitted changes.
        case story = "Story's last commit"
        case head = "HEAD"
        case workingTree = "Working tree"
    }

    public struct Range: Hashable, Sendable {
        public let repository: URL
        public let base: String
        /// Nil for the working tree.
        public let end: String?
        public let endKind: End
        /// How `story` was settled, for the label.
        public let note: String?

        public var label: String {
            "\(base.prefix(8)) → \(end.map { String($0.prefix(8)) } ?? "working tree")"
        }

        /// `base end` or just `base` (diff against the working tree).
        var revisions: [String] { [base] + (end.map { [$0] } ?? []) }
    }

    public struct FileChange: Identifiable, Hashable, Sendable {
        public var id: String { path }
        /// A, M, D, R, C or T.
        public let status: Character
        /// Relative to the repository root; the new path for a rename.
        public let path: String
        public let oldPath: String?
        /// Nil for a binary file.
        public let additions: Int?
        public let deletions: Int?
    }

    public struct Line: Hashable, Sendable {
        public enum Kind: Sendable { case context, added, removed, note }
        public let kind: Kind
        public let text: String
        public let old: Int?
        public let new: Int?
    }

    public struct Hunk: Hashable, Sendable {
        public let header: String
        public let lines: [Line]
    }

    public struct FileDiff: Hashable, Sendable {
        public let hunks: [Hunk]
        public let isBinary: Bool

        public var isEmpty: Bool { hunks.isEmpty && !isBinary }

        /// Whether every line of `range` (new-side numbering) is shown.
        public func shows(_ range: LineRange) -> Bool {
            let shown = Set(hunks.flatMap(\.lines).compactMap(\.new))
            return (range.lower...range.upper).allSatisfy(shown.contains)
        }
    }

    // MARK: Git

    static func git(_ args: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-C", directory.path(percentEncoded: false), "-c", "core.quotepath=off"] + args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        // Read before waiting: a large diff fills the pipe and would block git.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure.git(String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(decoding: data, as: UTF8.self)
    }

    public static func repositoryRoot(for url: URL) throws -> URL {
        do {
            let path = try git(["rev-parse", "--show-toplevel"], in: url).trimmingCharacters(in: .whitespacesAndNewlines)
            return URL(filePath: path)
        } catch {
            throw Failure.notARepository
        }
    }

    /// `path` relative to the repository root.
    public static func relativePath(_ url: URL, in repository: URL) -> String {
        let root = repository.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    // MARK: Range

    public static func range(baseline: String, end: End, document: URL?, projectRoot: URL) throws -> Range {
        let repo = try repositoryRoot(for: projectRoot)
        guard (try? git(["cat-file", "-e", "\(baseline)^{commit}"], in: repo)) != nil else {
            throw Failure.unknownCommit(baseline)
        }
        let base = try git(["rev-parse", "\(baseline)^{commit}"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
        switch end {
        case .workingTree:
            return Range(repository: repo, base: base, end: nil, endKind: end, note: nil)
        case .head:
            let head = try git(["rev-parse", "HEAD"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
            return Range(repository: repo, base: base, end: head, endKind: end, note: nil)
        case .story:
            if let document {
                let rel = relativePath(document, in: repo)
                let dirty = try git(["status", "--porcelain", "--", rel], in: repo)
                if !dirty.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return Range(repository: repo, base: base, end: nil, endKind: end, note: "the story document has uncommitted changes")
                }
                let last = try git(["log", "-1", "--format=%H", "--", rel], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
                if !last.isEmpty, last != base, (try? git(["merge-base", "--is-ancestor", base, last], in: repo)) != nil {
                    return Range(repository: repo, base: base, end: last, endKind: end, note: "the last commit to touch the story document")
                }
            }
            let head = try git(["rev-parse", "HEAD"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
            return Range(repository: repo, base: base, end: head, endKind: end, note: "no later commit touched the story document")
        }
    }

    // MARK: Files

    public static func changedFiles(in range: Range) throws -> [FileChange] {
        let status = try git(["diff", "--name-status", "-M", "-z"] + range.revisions, in: range.repository)
        let numstat = try git(["diff", "--numstat", "-M", "-z"] + range.revisions, in: range.repository)
        return parseChanges(nameStatus: status, numstat: numstat)
    }

    /// `--name-status -z` and `--numstat -z` output, joined by path.
    static func parseChanges(nameStatus: String, numstat: String) -> [FileChange] {
        var counts: [String: (Int?, Int?)] = [:]
        var n = numstat.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)[...]
        while let head = n.popFirst(), !head.isEmpty {
            let parts = head.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3 else { continue }
            let path: String
            if parts[2].isEmpty {
                // A rename: old and new paths follow as their own fields.
                _ = n.popFirst()
                path = n.popFirst() ?? ""
            } else {
                path = parts[2]
            }
            counts[path] = (Int(parts[0]), Int(parts[1]))
        }
        var out: [FileChange] = []
        var s = nameStatus.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)[...]
        while let code = s.popFirst(), !code.isEmpty {
            guard let letter = code.first else { continue }
            if letter == "R" || letter == "C" {
                let old = s.popFirst() ?? ""
                let new = s.popFirst() ?? ""
                out.append(FileChange(status: letter, path: new, oldPath: old, additions: counts[new]?.0, deletions: counts[new]?.1))
            } else {
                let path = s.popFirst() ?? ""
                out.append(FileChange(status: letter, path: path, oldPath: nil, additions: counts[path]?.0, deletions: counts[path]?.1))
            }
        }
        return out
    }

    // MARK: Diff

    /// One file's diff in `range`; `context` lines around each change, or the whole file.
    public static func diff(_ range: Range, path: String, oldPath: String? = nil, context: Int? = 6) throws -> FileDiff {
        let unified = context.map { "-U\($0)" } ?? "-U1000000"
        let paths = [oldPath, path].compactMap { $0 }
        let text = try git(["diff", "--no-color", "--no-ext-diff", "-M", unified] + range.revisions + ["--"] + paths, in: range.repository)
        return parse(text)
    }

    public static func parse(_ text: String) -> FileDiff {
        var hunks: [Hunk] = []
        var lines: [Line] = []
        var header: String?
        var old = 0, new = 0
        var binary = false

        func close() {
            if let header { hunks.append(Hunk(header: header, lines: lines)) }
            lines = []
        }

        for raw in text.components(separatedBy: "\n") {
            if raw.hasPrefix("@@"), let m = raw.firstMatch(of: /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@(.*)$/) {
                close()
                old = Int(m.1) ?? 0
                new = Int(m.2) ?? 0
                header = String(m.3).trimmingCharacters(in: .whitespaces)
                continue
            }
            if header == nil {
                if raw.hasPrefix("Binary files ") || raw == "GIT binary patch" { binary = true }
                continue
            }
            guard let first = raw.first else { continue }
            let body = String(raw.dropFirst())
            switch first {
            case " ":
                lines.append(Line(kind: .context, text: body, old: old, new: new)); old += 1; new += 1
            case "+":
                lines.append(Line(kind: .added, text: body, old: nil, new: new)); new += 1
            case "-":
                lines.append(Line(kind: .removed, text: body, old: old, new: nil)); old += 1
            case "\\":
                lines.append(Line(kind: .note, text: body.trimmingCharacters(in: .whitespaces), old: nil, new: nil))
            default:
                // The next file's header (`diff --git …`) ends this file's hunks.
                close()
                header = nil
            }
        }
        close()
        return FileDiff(hunks: hunks, isBinary: binary)
    }
}
