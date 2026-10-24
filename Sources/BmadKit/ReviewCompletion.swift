import Foundation

/// The edits that mark a reviewed story done, worked out before anything is
/// written so they can be shown for confirmation, then applied only if every
/// line is still what it was.
public enum ReviewCompletion {
    /// One line of one file, before and after.
    public struct Edit: Hashable, Sendable {
        public let url: URL
        /// 1-based.
        public let line: Int
        public let before: String
        public let after: String
    }

    public enum Refusal: Error, Equatable, LocalizedError {
        case alreadyDone
        case notAwaitingReview(String)
        /// Rule R2 of build-order.md: a queued story goes done in one commit with its
        /// row dropped and the floor lowered, so the app leaves it alone.
        case queued(section: String, position: String)
        case unsupportedLayout
        case statusLineNotFound(String)

        public var errorDescription: String? {
            switch self {
            case .alreadyDone: "The story is already done."
            case .notAwaitingReview(let s): "The story is \(s), not awaiting review."
            case .queued(let section, let position):
                "The story is #\(position) in build-order.md (\(section)). Going done there also drops its queue row and lowers the check's floor in the same commit (build-order R2), so mark it done by hand."
            case .unsupportedLayout: "Marking a review complete is only supported for sprint-status.yaml projects."
            case .statusLineNotFound(let file): "Could not find the story's status line in \(file)."
            }
        }
    }

    public enum ApplyFailure: Error, LocalizedError {
        case changed(URL, Int)
        public var errorDescription: String? {
            switch self {
            case .changed(let url, let line): "\(url.lastPathComponent):\(line) changed since it was read; nothing was written."
            }
        }
    }

    /// `review` → `done` on the story's `development_status` line, and the story
    /// file's front-matter `status:` to `done` when it says otherwise.
    public static func edits(for story: Story, in project: Project) -> Result<[Edit], Refusal> {
        guard project.layout == .sprintStatus, let statusFile = project.sources.statusFile else {
            return .failure(.unsupportedLayout)
        }
        if story.status.kind == .done { return .failure(.alreadyDone) }
        guard story.status.kind == .review else { return .failure(.notAwaitingReview(story.status.raw)) }
        if let entry = project.queue.lazy.flatMap(\.entries).first(where: { $0.storyNumber == story.number }) {
            return .failure(.queued(section: entry.section, position: entry.position))
        }

        var edits: [Edit] = []
        guard let text = try? String(contentsOf: statusFile, encoding: .utf8),
              let edit = statusLineEdit(in: text, key: story.id, url: statusFile) else {
            return .failure(.statusLineNotFound(statusFile.lastPathComponent))
        }
        edits.append(edit)

        if let file = story.documents.first(where: { $0.label == "Story file" })?.url,
           let text = try? String(contentsOf: file, encoding: .utf8),
           let edit = frontMatterStatusEdit(in: text, url: file) {
            edits.append(edit)
        }
        return .success(edits)
    }

    /// `  <key>: review   # comment` → `  <key>: done   # comment`.
    static func statusLineEdit(in text: String, key: String, url: URL) -> Edit? {
        let lines = text.components(separatedBy: "\n")
        var inDevelopment = false
        for (i, line) in lines.enumerated() {
            if line.hasPrefix("development_status:") { inDevelopment = true; continue }
            if inDevelopment, let first = line.first, first != " ", first != "#" { inDevelopment = false }
            guard inDevelopment else { continue }
            let trimmed = line.drop { $0 == " " }
            guard trimmed.hasPrefix("\(key):") else { continue }
            let indent = line.prefix(line.count - trimmed.count)
            let value = trimmed.dropFirst(key.count + 1)
            let word = value.drop { $0 == " " }.prefix { !$0.isWhitespace && $0 != "#" }
            guard !word.isEmpty else { return nil }
            let tail = value.drop { $0 == " " }.dropFirst(word.count)
            return Edit(url: url, line: i + 1, before: line, after: "\(indent)\(key): done\(tail)")
        }
        return nil
    }

    /// The front matter's `status:` line set to `done`, keeping its quoting and any
    /// trailing comment; nil when there is none or it already says done.
    static func frontMatterStatusEdit(in text: String, url: URL) -> Edit? {
        let lines = text.components(separatedBy: "\n")
        guard lines.first == "---" else { return nil }
        for (i, line) in lines.enumerated().dropFirst() {
            if line == "---" { return nil }
            guard let m = line.wholeMatch(of: /status:(\s*)(['"]?)([A-Za-z_-]+)(['"]?)(.*)/) else { continue }
            if m.3 == "done" { return nil }
            return Edit(url: url, line: i + 1, before: line, after: "status:\(m.1)\(m.2)done\(m.4)\(m.5)")
        }
        return nil
    }

    /// Writes every edit, or none: each file is re-read and each line checked first.
    public static func apply(_ edits: [Edit]) throws {
        let byFile = Dictionary(grouping: edits, by: \.url)
        var rewritten: [(URL, String)] = []
        for (url, fileEdits) in byFile {
            var lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for e in fileEdits {
                guard e.line - 1 < lines.count, lines[e.line - 1] == e.before else { throw ApplyFailure.changed(url, e.line) }
                lines[e.line - 1] = e.after
            }
            rewritten.append((url, lines.joined(separator: "\n")))
        }
        for (url, text) in rewritten {
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
