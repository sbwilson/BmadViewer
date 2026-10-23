import Foundation
import Yams

/// A leading `---` YAML block, as BMAD story and plan files carry.
public enum FrontMatter {
    public struct Split: Sendable {
        public let fields: [String: String]
        public let body: String
    }

    public static func split(_ text: String) -> Split {
        guard let (yaml, body) = sections(text) else { return Split(fields: [:], body: text) }
        var fields: [String: String] = [:]
        if let mapping = (try? Yams.load(yaml: yaml)) as? [String: Any] {
            for (key, value) in mapping {
                fields[key] = stringify(value)
            }
        }
        return Split(fields: fields, body: body)
    }

    /// The front matter with YAML types kept (`id: 3` is an Int, `after: [1, "2.8"]` an array);
    /// nil when there is none or it does not parse.
    public static func raw(_ text: String) -> [String: Any]? {
        guard let (yaml, _) = sections(text) else { return nil }
        return (try? Yams.load(yaml: yaml)) as? [String: Any]
    }

    private static func sections(_ text: String) -> (yaml: String, body: String)? {
        guard text.hasPrefix("---\n") || text.hasPrefix("---\r\n") else { return nil }
        let lines = text.components(separatedBy: "\n")
        guard let close = lines.dropFirst().firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---"
        }) else { return nil }
        return (lines[1..<close].joined(separator: "\n"), lines[(close + 1)...].joined(separator: "\n"))
    }

    private static func stringify(_ value: Any) -> String {
        switch value {
        case let s as String: s
        case let a as [Any]: a.map(stringify).joined(separator: ", ")
        case let d as Date: ISO8601DateFormatter().string(from: d).prefix(10).description
        default: "\(value)"
        }
    }
}
