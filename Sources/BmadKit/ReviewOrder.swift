import Foundation

/// A story document's `## Suggested Review Order`: concerns in reading order, each
/// with its stops — one line of framing and a `file:line` link.
///
/// The format is bmad-build's (`step-05-present.md`): a bold line per concern, then
/// `- framing` bullets with the link on the next, indented line. `###` concern
/// headings and links on the bullet's own line are read too.
public struct ReviewOrder: Hashable, Sendable {
    public struct Stop: Identifiable, Hashable, Sendable {
        public let id: Int
        public let framing: String
        /// The link text, e.g. `endpoint.rs:442`.
        public let label: String?
        public let url: URL?
        public let lines: LineRange?
        /// The link pointed at a path that no longer exists, and `url` is where a file of
        /// the same name was found after dropping leading folders (`RustCore/crates/…` →
        /// `crates/…`). Its line numbers may have drifted.
        public let movedFrom: String?
    }

    public struct Group: Identifiable, Hashable, Sendable {
        public let id: Int
        public let title: String
        public let stops: [Stop]
    }

    public let groups: [Group]
    /// The 1-based line of the section heading in its document.
    public let line: Int

    public var stops: [Stop] { groups.flatMap(\.stops) }

    public static let heading = "suggested review order"

    /// Nil when the document has no such section or it lists no stops.
    public static func parse(_ text: String, document: URL, projectRoot: URL) -> ReviewOrder? {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: {
            $0.hasPrefix("## ") && $0.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased() == heading
        }) else { return nil }

        var groups: [Group] = []
        var title = "Review"
        var stops: [Stop] = []
        var pending: (framing: String, links: [(String, String)])?
        var nextStop = 0

        func flushStop() {
            guard let p = pending else { return }
            pending = nil
            let link = p.links.first
            let (url, lineRange) = link.map { resolve($0.1, document: document, projectRoot: projectRoot) } ?? (nil, nil)
            let found = url.map { relocate($0, projectRoot: projectRoot) }
            stops.append(Stop(id: nextStop, framing: p.framing,
                              label: link.map { $0.0.replacingOccurrences(of: "`", with: "") },
                              url: found?.url ?? url, lines: lineRange, movedFrom: found?.movedFrom))
            nextStop += 1
        }
        func flushGroup() {
            flushStop()
            if !stops.isEmpty { groups.append(Group(id: groups.count, title: title, stops: stops)) }
            stops = []
        }

        var inFence = false
        for line in lines[(start + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inFence.toggle(); continue }
            if inFence { continue }
            if line.hasPrefix("## ") || line.hasPrefix("# ") { break }
            if let m = trimmed.wholeMatch(of: /\*\*(.+)\*\*:?/) {
                flushGroup()
                title = String(m.1)
            } else if trimmed.hasPrefix("### ") {
                flushGroup()
                title = String(trimmed.dropFirst(4)).replacingOccurrences(of: "**", with: "")
            } else if let m = line.wholeMatch(of: /\s{0,3}(?:[-*+]|\d+[.)])\s+(.*)/) {
                flushStop()
                let (framing, links) = split(String(m.1))
                pending = (framing, links)
            } else if pending != nil, !trimmed.isEmpty {
                // A continuation line: the link, or more framing.
                let (more, links) = split(trimmed)
                pending!.links += links
                if !more.isEmpty { pending!.framing += (pending!.framing.isEmpty ? "" : " ") + more }
            }
        }
        flushGroup()
        guard !groups.isEmpty else { return nil }
        return ReviewOrder(groups: groups, line: start + 1)
    }

    /// The text with its markdown links taken out, and the links as (text, destination).
    static func split(_ text: String) -> (String, [(String, String)]) {
        var links: [(String, String)] = []
        var rest = text
        for m in text.matches(of: /\[([^\]]*)\]\(([^)\s]+)\)/) {
            links.append((String(m.1), String(m.2)))
            rest = rest.replacingOccurrences(of: String(m.0), with: "")
        }
        rest = rest.trimmingCharacters(in: .whitespaces)
        if rest.hasSuffix("—") || rest.hasSuffix(":") || rest.hasSuffix("-") { rest = String(rest.dropLast()).trimmingCharacters(in: .whitespaces) }
        return (rest, links)
    }

    /// The file itself when it exists; else the same path with up to three leading
    /// folders dropped, under the project root.
    static func relocate(_ url: URL, projectRoot: URL) -> (url: URL, movedFrom: String?) {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path(percentEncoded: false)) { return (url, nil) }
        let root = projectRoot.standardizedFileURL.path(percentEncoded: false)
        let path = url.standardizedFileURL.path(percentEncoded: false)
        guard path.hasPrefix(root) else { return (url, nil) }
        let relative = path.dropFirst(root.count).split(separator: "/")
        for drop in 1...min(3, max(1, relative.count - 1)) where drop < relative.count {
            let candidate = projectRoot.appending(path: relative.dropFirst(drop).joined(separator: "/"))
            if fm.fileExists(atPath: candidate.path(percentEncoded: false)) {
                return (candidate, relative.joined(separator: "/"))
            }
        }
        return (url, nil)
    }

    static func resolve(_ destination: String, document: URL, projectRoot: URL) -> (URL?, LineRange?) {
        let (written, lines) = LineRef.split(destination.removingPercentEncoding ?? destination)
        var path = written.replacingOccurrences(of: "{project-root}", with: projectRoot.path(percentEncoded: false))
        if let hash = path.firstIndex(of: "#") { path = String(path[..<hash]) }
        guard !path.isEmpty, !path.contains("://") else { return (nil, lines) }
        let url = path.hasPrefix("/") ? URL(filePath: path) : document.deletingLastPathComponent().appending(path: path).standardizedFileURL
        return (url, lines)
    }
}
