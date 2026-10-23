import Foundation
import Yams

/// Reads a v6 `sprint-status.yaml`, keeping `development_status` in file order.
public enum SprintStatus {
    public struct File: Sendable {
        public var project: String?
        public var storyLocation: String?
        public var entries: [(key: String, value: String)]
    }

    public enum Failure: Error, LocalizedError {
        case notAMapping
        case noDevelopmentStatus

        public var errorDescription: String? {
            switch self {
            case .notAMapping: "sprint-status.yaml is not a YAML mapping"
            case .noDevelopmentStatus: "sprint-status.yaml has no development_status mapping"
            }
        }
    }

    public static func parse(_ text: String) throws -> File {
        guard let node = try Yams.compose(yaml: text), let root = node.mapping else {
            throw Failure.notAMapping
        }
        guard let dev = root["development_status"]?.mapping else {
            throw Failure.noDevelopmentStatus
        }
        let entries = dev.compactMap { pair -> (key: String, value: String)? in
            guard let k = pair.key.string, let v = pair.value.string else { return nil }
            return (k, v)
        }
        return File(
            project: root["project"]?.string,
            storyLocation: root["story_location"]?.string,
            entries: entries
        )
    }

    public enum Key: Equatable, Sendable {
        case epic(String)
        case retrospective(String)
        case story(epic: String, story: String, slug: String)
        case unrecognised

        public init(_ key: String) {
            if let m = key.wholeMatch(of: /epic-(\w+)-retrospective/) {
                self = .retrospective(String(m.1))
            } else if let m = key.wholeMatch(of: /epic-(\w+)/) {
                self = .epic(String(m.1))
            } else if let m = key.wholeMatch(of: /(\d+)-(\d+[a-z]?)-(.+)/) {
                self = .story(epic: String(m.1), story: String(m.2), slug: String(m.3))
            } else {
                self = .unrecognised
            }
        }
    }
}
