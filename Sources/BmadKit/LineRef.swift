import Foundation

/// A 1-based, inclusive range of lines in a file.
public struct LineRange: Hashable, Sendable, Codable {
    public let lower: Int
    public let upper: Int

    public init(_ lower: Int, _ upper: Int? = nil) {
        self.lower = max(1, lower)
        self.upper = max(self.lower, upper ?? lower)
    }

    /// `L42` or `L42-L50`, the form carried in a link's fragment.
    public var fragment: String { lower == upper ? "L\(lower)" : "L\(lower)-L\(upper)" }

    /// Reads `L42`, `L42-L50` and `L42-50`.
    public init?(fragment: String) {
        guard let m = fragment.wholeMatch(of: /L(\d+)(?:-L?(\d+))?/), let a = Int(m.1) else { return nil }
        self.init(a, m.2.flatMap { Int($0) })
    }

    public var label: String { lower == upper ? "line \(lower)" : "lines \(lower)–\(upper)" }
}

public enum LineRef {
    /// Splits a written reference into its path and lines: `a.rs:42`, `a.rs:42:7`,
    /// `a.rs:42-50`, `a.rs#L42`, `a.rs#L42-L50`. A path with no line part comes back whole.
    public static func split(_ raw: String) -> (path: String, lines: LineRange?) {
        if let hash = raw.range(of: "#L") {
            let path = String(raw[..<hash.lowerBound])
            return (path, LineRange(fragment: String(raw[raw.index(after: hash.lowerBound)...])))
        }
        if let m = raw.wholeMatch(of: /(.+?):(\d+)(?::\d+)?(?:[-–](\d+)(?::\d+)?)?/), let a = Int(m.2) {
            return (String(m.1), LineRange(a, m.3.flatMap { Int($0) }))
        }
        return (raw, nil)
    }
}

public extension URL {
    /// This URL with `lines` as its fragment (`#L42-L50`), or without a fragment.
    func withLines(_ lines: LineRange?) -> URL {
        var c = URLComponents(url: self, resolvingAgainstBaseURL: false)
        c?.fragment = lines?.fragment
        return c?.url ?? self
    }

    var lineRange: LineRange? { fragment.flatMap(LineRange.init(fragment:)) }

    var withoutFragment: URL { withLines(nil) }
}
