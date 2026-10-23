import Foundation
import Yams

/// A leading `---` YAML block, as BMAD story and plan files carry.
public enum FrontMatter {
    public struct Split: Sendable {
        public let fields: [String: String]
        public let body: String
    }

    public static func split(_ text: String) -> Split {
        guard text.hasPrefix("---\n") || text.hasPrefix("---\r\n") else {
            return Split(fields: [:], body: text)
        }
        let lines = text.components(separatedBy: "\n")
        guard let close = lines.dropFirst().firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---"
        }) else {
            return Split(fields: [:], body: text)
        }
        let yaml = lines[1..<close].joined(separator: "\n")
        let body = lines[(close + 1)...].joined(separator: "\n")
        var fields: [String: String] = [:]
        if let mapping = (try? Yams.load(yaml: yaml)) as? [String: Any] {
            for (key, value) in mapping {
                fields[key] = stringify(value)
            }
        }
        return Split(fields: fields, body: body)
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
