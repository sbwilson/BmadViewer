import Foundation

/// The items to walk before calling a review complete: a v7 ticket's `verify`
/// text split into items, or, when the entry says nothing, its review order's
/// stops. The ticks themselves are the app's — local checkboxes, saved per
/// project, never written into the tree.
public enum ReviewChecklist {
    public static func items(for story: Story) -> [String] {
        if let verify = story.verify, !verify.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return split(verify)
        }
        var seen = Set<String>()
        return (story.review?.stops ?? []).compactMap { stop in
            let text = stop.framing.isEmpty ? (stop.label ?? "") : stop.framing
            return text.isEmpty || !seen.insert(text).inserted ? nil : text
        }
    }

    /// Bullets (`-`, `*`, `1.` or `1)`) open an item and a plain line folds into
    /// the one above it; with no bullets at all, each non-empty line is its own
    /// item — a one-line `verify` is the one-item case.
    static func split(_ text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.contains(where: { bullet($0) != nil }) else { return lines }
        var items: [String] = []
        for line in lines {
            if let item = bullet(line) { items.append(item) }
            else if items.isEmpty { items.append(line) }
            else { items[items.count - 1] += " " + line }
        }
        return items
    }

    static func bullet(_ line: String) -> String? {
        line.wholeMatch(of: /(?:[-*]|\d+[.)])\s+(.+)/).map { String($0.1) }
    }
}
