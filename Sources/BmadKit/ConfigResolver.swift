import Foundation
import Yams

/// Finds where a BMAD install keeps its planning and implementation artifacts.
///
/// Precedence follows the installer: `_bmad/custom/config.user.toml`, then
/// `_bmad/custom/config.toml`, then the installer-managed `_bmad/config.toml`,
/// then the v6 module file `_bmad/bmm/config.yaml`, then the default
/// `_bmad-output/` layout.
public enum ConfigResolver {
    public struct Paths: Sendable, Equatable {
        public var planning: URL?
        public var implementation: URL?
        public var output: URL?
        /// `modules.bmm.active_initiative`: the v7 initiative folder's name.
        public var activeInitiative: String?
        /// `[tickets] root` from `_bmad/custom/ticketing-store-config.toml`, unexpanded.
        public var ticketsRoot: String?
    }

    public static func resolve(root: URL) -> Paths {
        let fm = FileManager.default
        var values: [String: String] = [:]

        let tomlFiles = ["_bmad/config.toml", "_bmad/custom/config.toml", "_bmad/custom/config.user.toml"]
        // Later files override earlier ones.
        for rel in tomlFiles {
            let url = root.appending(path: rel)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (k, v) in tomlAssignments(text) { values[k] = v }
        }
        if values["planning_artifacts"] == nil || values["implementation_artifacts"] == nil {
            let yamlURL = root.appending(path: "_bmad/bmm/config.yaml")
            if let text = try? String(contentsOf: yamlURL, encoding: .utf8),
               let map = (try? Yams.load(yaml: text)) as? [String: Any] {
                for key in ["planning_artifacts", "implementation_artifacts", "output_folder"] where values[key] == nil {
                    if let v = map[key] as? String { values[key] = v }
                }
            }
        }

        func url(_ key: String) -> URL? {
            guard let raw = values[key] else { return nil }
            let path = raw
                .replacingOccurrences(of: "{project-root}", with: root.path(percentEncoded: false))
                .replacingOccurrences(of: "//", with: "/")
            let u = path.hasPrefix("/") ? URL(filePath: path) : root.appending(path: path)
            return fm.fileExists(atPath: u.path(percentEncoded: false)) ? u.standardizedFileURL : nil
        }

        var paths = Paths(
            planning: url("planning_artifacts"),
            implementation: url("implementation_artifacts"),
            output: url("output_folder"),
            activeInitiative: values["active_initiative"]
        )
        if let text = try? String(contentsOf: root.appending(path: "_bmad/custom/ticketing-store-config.toml"), encoding: .utf8) {
            paths.ticketsRoot = tomlAssignments(text).first { $0.0 == "root" }?.1
        }
        let fallback = root.appending(path: "_bmad-output")
        if paths.output == nil, fm.fileExists(atPath: fallback.path(percentEncoded: false)) {
            paths.output = fallback
        }
        if let out = paths.output {
            if paths.planning == nil {
                let p = out.appending(path: "planning-artifacts")
                if fm.fileExists(atPath: p.path(percentEncoded: false)) { paths.planning = p }
            }
            if paths.implementation == nil {
                let i = out.appending(path: "implementation-artifacts")
                if fm.fileExists(atPath: i.path(percentEncoded: false)) { paths.implementation = i }
            }
        }
        return paths
    }

    /// `key = "value"` lines from a TOML file, ignoring sections. Enough for
    /// BMAD's flat path settings; not a TOML parser.
    static func tomlAssignments(_ text: String) -> [(String, String)] {
        text.components(separatedBy: .newlines).compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { return nil }
            let key = t[..<eq].trimmingCharacters(in: .whitespaces)
            var value = t[t.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix("\""), value.count >= 2 else { return nil }
            value.removeFirst()
            guard let end = value.firstIndex(of: "\"") else { return nil }
            return (key, String(value[..<end]))
        }
    }
}
