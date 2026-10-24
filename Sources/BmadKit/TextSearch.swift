import Foundation

/// Full-text search over a project's files: `git grep` (tracked and untracked,
/// ignored files skipped, binaries skipped) in a repository, a bounded walk
/// elsewhere. Every match on a line is located for highlighting.
public enum TextSearch {
    public struct Options: Hashable, Codable, Sendable {
        public var caseSensitive = false
        public var wholeWord = false
        public var regex = false
        public var scope: Scope = .artifacts

        public init(caseSensitive: Bool = false, wholeWord: Bool = false, regex: Bool = false, scope: Scope = .artifacts) {
            self.caseSensitive = caseSensitive
            self.wholeWord = wholeWord
            self.regex = regex
            self.scope = scope
        }
    }

    public enum Scope: String, Codable, CaseIterable, Sendable {
        case artifacts = "BMAD artifacts"
        case project = "Whole project"
    }

    public struct Match: Identifiable, Hashable, Sendable {
        public var id: String { "\(line)" }
        public let line: Int
        /// The line, trimmed to a window around the first match when long.
        public let preview: String
        /// Matches within `preview`, as UTF-16 ranges.
        public let ranges: [NSRange]
    }

    public struct FileMatches: Identifiable, Hashable, Sendable {
        public var id: String { path }
        /// Relative to the project root.
        public let path: String
        public let url: URL
        public let matches: [Match]
    }

    public struct Outcome: Sendable {
        public let files: [FileMatches]
        public let matchCount: Int
        /// Stopped at the match limit.
        public let truncated: Bool
    }

    public enum Failure: Error, LocalizedError {
        case badPattern(String)
        public var errorDescription: String? {
            switch self { case .badPattern(let m): "Not a valid pattern: \(m)" }
        }
    }

    /// The folders `artifacts` searches: wherever the project keeps its BMAD files.
    public static func artifactFolders(_ project: Project) -> [URL] {
        var dirs = [project.sources.planningDirectory, project.sources.storyDirectory,
                    project.sources.statusFile?.deletingLastPathComponent(), project.deferredWorkFile?.deletingLastPathComponent()]
            .compactMap { $0?.standardizedFileURL }
        // Drop folders inside another one already listed.
        dirs = Array(Set(dirs)).sorted { $0.path(percentEncoded: false).count < $1.path(percentEncoded: false).count }
        var kept: [URL] = []
        for d in dirs where !kept.contains(where: { d.path(percentEncoded: false).hasPrefix($0.path(percentEncoded: false) + "/") }) {
            kept.append(d)
        }
        return kept.sorted { $0.path(percentEncoded: false) < $1.path(percentEncoded: false) }
    }

    public static func run(_ query: String, options: Options, root: URL, folders: [URL], limit: Int = 2000) throws -> Outcome {
        guard !query.isEmpty else { return Outcome(files: [], matchCount: 0, truncated: false) }
        let matcher = try matcher(query, options)
        var rootPath = root.standardizedFileURL.path(percentEncoded: false)
        while rootPath.hasSuffix("/") { rootPath.removeLast() }
        let paths: [String] = options.scope == .project ? ["."] : folders.map {
            let p = $0.standardizedFileURL.path(percentEncoded: false)
            guard p.hasPrefix(rootPath + "/") else { return p }
            return "./" + p.dropFirst(rootPath.count + 1)
        }
        let lines: [(String, Int, String)]
        if let grep = try gitGrep(query, options: options, root: root, paths: paths, limit: limit) {
            lines = grep
        } else {
            lines = walk(matcher, root: root, folders: options.scope == .project ? [root] : folders, limit: limit)
        }
        var byFile: [String: [Match]] = [:]
        var order: [String] = []
        for (path, number, text) in lines.prefix(limit) {
            let ranges = matches(matcher, in: text)
            guard !ranges.isEmpty else { continue }
            let (preview, shifted) = window(text, ranges: ranges)
            if byFile[path] == nil { order.append(path) }
            byFile[path, default: []].append(Match(line: number, preview: preview, ranges: shifted))
        }
        let files = order.map { FileMatches(path: $0, url: root.appending(path: $0), matches: byFile[$0]!) }
        return Outcome(files: files, matchCount: files.reduce(0) { $0 + $1.matches.count }, truncated: lines.count >= limit)
    }

    // MARK: Matching

    static func matcher(_ query: String, _ options: Options) throws -> NSRegularExpression {
        var pattern = options.regex ? query : NSRegularExpression.escapedPattern(for: query)
        if options.wholeWord { pattern = "\\b(?:\(pattern))\\b" }
        do {
            return try NSRegularExpression(pattern: pattern, options: options.caseSensitive ? [] : [.caseInsensitive])
        } catch {
            throw Failure.badPattern(query)
        }
    }

    static func matches(_ re: NSRegularExpression, in text: String) -> [NSRange] {
        re.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
            .map(\.range).filter { $0.length > 0 }
    }

    /// Long lines are cut to about 70 characters before the first match.
    static func window(_ text: String, ranges: [NSRange], before: Int = 70, max: Int = 400) -> (String, [NSRange]) {
        let ns = text as NSString
        let lead = ns.length - (text.drop { $0 == " " || $0 == "\t" } as Substring).utf16.count
        var start = lead
        if let first = ranges.first, first.location - start > before { start = first.location - before }
        let length = min(ns.length - start, max)
        var preview = ns.substring(with: NSRange(location: start, length: length))
        var shift = start
        if start > lead { preview = "…" + preview; shift -= 1 }
        if start + length < ns.length { preview += "…" }
        let visible = (preview as NSString).length
        let shifted = ranges.map { NSRange(location: $0.location - shift, length: $0.length) }
            .filter { $0.location >= 0 && NSMaxRange($0) <= visible }
        return (preview, shifted)
    }

    // MARK: Engines

    /// Nil when `root` is not in a git repository.
    static func gitGrep(_ query: String, options: Options, root: URL, paths: [String], limit: Int) throws -> [(String, Int, String)]? {
        var args = ["-C", root.path(percentEncoded: false), "-c", "core.quotepath=off", "grep", "-n", "-I", "--null", "--no-color", "--untracked", "--full-name"]
        if !options.caseSensitive { args.append("-i") }
        if options.wholeWord { args.append("-w") }
        args.append(options.regex ? "-E" : "-F")
        args += ["-e", options.regex ? posix(query) : query, "--"] + paths
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        // Read until the limit, then stop git rather than reading everything.
        var lines: [(String, Int, String)] = []
        var buffer = Data()
        let handle = out.fileHandleForReading
        let prefix = try repositoryPrefix(root)
        reading: while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 10) {
                let record = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                let fields = record.split(separator: 0, maxSplits: 2, omittingEmptySubsequences: false)
                guard fields.count == 3, let number = Int(String(decoding: fields[1], as: UTF8.self)) else { continue }
                var path = String(decoding: fields[0], as: UTF8.self)
                // --full-name is relative to the repository; make it relative to the project.
                if let prefix, path.hasPrefix(prefix) { path = String(path.dropFirst(prefix.count)) }
                lines.append((path, number, String(decoding: fields[2], as: UTF8.self)))
                if lines.count >= limit {
                    process.terminate()
                    break reading
                }
            }
        }
        let errText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        if lines.count >= limit { return lines }
        switch process.terminationStatus {
        case 0, 1: return lines   // 1: nothing matched
        default:
            if errText.contains("not a git repository") { return nil }
            if errText.lowercased().contains("regex") || errText.contains("Invalid") { throw Failure.badPattern(query) }
            throw GitDiff.Failure.git(errText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// The pattern as POSIX ERE for git, which knows no `\b`, `\d`, `\w` or `\s`.
    /// Dropping `\b` only widens what git returns; every line is re-checked with the
    /// real pattern afterwards.
    static func posix(_ pattern: String) -> String {
        var out = ""
        var chars = pattern.makeIterator()
        while let c = chars.next() {
            guard c == "\\", let next = chars.next() else { out.append(c); continue }
            switch next {
            case "b", "B": break
            case "d": out += "[0-9]"
            case "D": out += "[^0-9]"
            case "w": out += "[[:alnum:]_]"
            case "W": out += "[^[:alnum:]_]"
            case "s": out += "[[:space:]]"
            case "S": out += "[^[:space:]]"
            default: out += "\\\(next)"
            }
        }
        return out
    }

    /// The project's folder inside its repository (`app/` when the project is
    /// `repo/app`), or nil when they are the same.
    static func repositoryPrefix(_ root: URL) throws -> String? {
        guard let repo = try? GitDiff.repositoryRoot(for: root) else { return nil }
        let rel = GitDiff.relativePath(root, in: repo)
        return rel.isEmpty || rel == root.path(percentEncoded: false) ? nil : rel.hasSuffix("/") ? rel : rel + "/"
    }

    /// Outside git: text files under `folders`, skipping build output.
    static func walk(_ re: NSRegularExpression, root: URL, folders: [URL], limit: Int) -> [(String, Int, String)] {
        let skip: Set<String> = [".git", ".build", "build", "target", "node_modules", "DerivedData", ".swiftpm"]
        var base = root.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        while base.hasSuffix("/") { base.removeLast() }
        var out: [(String, Int, String)] = []
        for folder in folders {
            let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles])
            while let url = e?.nextObject() as? URL {
                if skip.contains(url.lastPathComponent) { e?.skipDescendants(); continue }
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                guard values?.isDirectory != true, (values?.fileSize ?? 0) < 4_000_000,
                      let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let path = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
                guard path.hasPrefix(base + "/") else { continue }
                let rel = String(path.dropFirst(base.count + 1))
                for (i, line) in text.components(separatedBy: "\n").enumerated() where re.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil {
                    out.append((rel, i + 1, line))
                    if out.count >= limit { return out }
                }
            }
        }
        return out
    }
}
