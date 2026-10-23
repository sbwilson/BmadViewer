import Foundation

/// Titles and per-story sections from a v6 `epics.md`.
///
/// Headings are `## Epic <n>: Title` and `### Story <n>.<m>: Title`; a sprint
/// prefix such as `S5-` before the number is tolerated, because the tracking
/// file's `epic-9` is the document's `Epic S5-9`.
public struct EpicsDocument: Sendable {
    public var epicTitles: [String: String] = [:]
    public var storyTitles: [String: String] = [:]
    /// Markdown from a story's heading up to the next heading of level 1–3.
    public var storySections: [String: String] = [:]

    public init(_ text: String) {
        let lines = text.components(separatedBy: "\n")
        var current: String?
        var buffer: [String] = []

        func flush() {
            if let current { storySections[current] = buffer.joined(separator: "\n") }
            current = nil
            buffer = []
        }

        for line in lines {
            if let m = line.wholeMatch(of: /##\s+Epic\s+(?:[A-Za-z]+\d*-)?(\d+)\s*[:—–-]\s*(.+)/) {
                flush()
                epicTitles[String(m.1)] = String(m.2).trimmingCharacters(in: .whitespaces)
                continue
            }
            if let m = line.wholeMatch(of: /###\s+Story\s+(?:[A-Za-z]+\d*-)?(\d+)\.(\d+[a-z]?)\s*[:—–-]\s*(.+)/) {
                flush()
                let number = "\(m.1).\(m.2)"
                storyTitles[number] = Self.plain(String(m.3))
                current = number
                buffer = [line]
                continue
            }
            if current != nil {
                if line.hasPrefix("# ") || line.hasPrefix("## ") || line.hasPrefix("### ") {
                    flush()
                } else {
                    buffer.append(line)
                }
            }
        }
        flush()
    }

    /// Strip inline code backticks from a heading so it reads as a title.
    static func plain(_ s: String) -> String {
        s.replacingOccurrences(of: "`", with: "").trimmingCharacters(in: .whitespaces)
    }
}
