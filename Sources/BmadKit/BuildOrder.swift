import Foundation

/// Reads queue tables from a `build-order.md`: any markdown table whose header
/// has a `Story` column, grouped under the `##` heading it sits in. A section
/// whose table has no rows is kept, so a drained increment still shows.
public enum BuildOrder {
    public static func parse(_ text: String) -> [QueueSection] {
        var sections: [QueueSection] = []
        var heading: String?
        var entries: [QueueEntry] = []
        var hasTable = false
        var columns: Columns?
        var expectSeparator = false

        func close() {
            if let heading, hasTable {
                sections.append(QueueSection(heading: heading, entries: entries))
            }
            entries = []
            hasTable = false
            columns = nil
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") {
                close()
                heading = String(trimmed.dropFirst(3))
                continue
            }
            guard trimmed.hasPrefix("|") else {
                columns = nil
                continue
            }
            let cells = splitRow(trimmed)
            if expectSeparator {
                expectSeparator = false
                if cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { continue }
                columns = nil
            }
            if columns == nil {
                if let c = Columns(header: cells) {
                    columns = c
                    hasTable = true
                    expectSeparator = true
                }
                continue
            }
            guard let c = columns, let heading else { continue }
            let storyCell = c.story < cells.count ? cells[c.story] : ""
            guard let number = storyNumbers(in: storyCell).first else { continue }
            entries.append(QueueEntry(
                section: heading,
                position: c.position.flatMap { $0 < cells.count ? cells[$0] : nil } ?? "\(entries.count + 1)",
                storyNumber: number,
                waitsOn: c.waitsOn.flatMap { $0 < cells.count ? storyNumbers(in: cells[$0]) : nil } ?? [],
                reason: c.reason.flatMap { $0 < cells.count ? cells[$0] : nil } ?? ""
            ))
        }
        close()
        return sections
    }

    struct Columns {
        var position: Int?
        var story: Int
        var waitsOn: Int?
        var reason: Int?

        init?(header: [String]) {
            let lower = header.map { $0.lowercased() }
            guard let story = lower.firstIndex(where: { $0 == "story" || $0 == "ticket" }) else { return nil }
            self.story = story
            position = lower.firstIndex(of: "#")
            waitsOn = lower.firstIndex { $0.contains("wait") || $0.contains("after") || $0.contains("depends") }
            reason = lower.firstIndex { $0.contains("why") || $0.contains("reason") }
        }
    }

    /// Splits `| a | b |` on pipes outside backtick spans.
    static func splitRow(_ row: String) -> [String] {
        var cells: [String] = []
        var cell = ""
        var inCode = false
        var chars = Substring(row)
        if chars.first == "|" { chars = chars.dropFirst() }
        if chars.last == "|" { chars = chars.dropLast() }
        for ch in chars {
            if ch == "`" { inCode.toggle() }
            if ch == "|", !inCode {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
            } else {
                cell.append(ch)
            }
        }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        return cells
    }

    public static func storyNumbers(in text: String) -> [String] {
        text.matches(of: /(\d+)\.(\d+[a-z]?)/).map { "\($0.1).\($0.2)" }
    }
}
