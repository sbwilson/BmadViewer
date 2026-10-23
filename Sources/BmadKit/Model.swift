import Foundation

/// A status as written in the tracking file. The raw string is kept verbatim so
/// nothing the project invents (`superseded`, `optional`, `built`) is lost;
/// `kind` is only for grouping and colour.
public struct Status: Hashable, Sendable {
    public enum Kind: Int, Sendable, CaseIterable, Comparable {
        case inProgress, review, ready, backlog, built, done, superseded, optional, other

        public static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }

        public var label: String {
            switch self {
            case .inProgress: "In progress"
            case .review: "Review"
            case .ready: "Ready for dev"
            case .backlog: "Backlog"
            case .built: "Built"
            case .done: "Done"
            case .superseded: "Superseded"
            case .optional: "Optional"
            case .other: "Other"
            }
        }
    }

    public let raw: String

    public init(_ raw: String) { self.raw = raw.trimmingCharacters(in: .whitespaces) }

    public var kind: Kind {
        switch raw.lowercased() {
        case "in-progress", "in_progress", "in progress", "doing": .inProgress
        case "review", "in-review": .review
        case "ready-for-dev", "ready", "ready_for_dev", "drafted", "contexted": .ready
        case "backlog", "todo", "planned": .backlog
        case "built": .built
        case "done", "completed", "closed": .done
        case "superseded", "dropped", "cancelled", "canceled": .superseded
        case "optional": .optional
        default: .other
        }
    }

    /// Terminal statuses count as finished for progress.
    public var isTerminal: Bool { kind == .done || kind == .superseded }
    /// Active statuses are what someone is working on now.
    public var isActive: Bool { kind == .inProgress || kind == .review || kind == .ready }
}

public struct Story: Identifiable, Hashable, Sendable {
    /// The tracking key, e.g. `9-16-capture-rs-core-rs-and-root-rs-are-split`.
    public let id: String
    /// Display number, e.g. `9.16`.
    public let number: String
    public let epicID: String
    public var title: String
    public var status: Status
    /// The story's own document (spec/story file), if one exists.
    public var documentURL: URL?
    /// Where the story is defined in `epics.md`, if found: used when no story file exists.
    public var epicsExcerpt: String?
    /// Front matter of the story document.
    public var frontMatter: [String: String] = [:]
}

public struct Epic: Identifiable, Hashable, Sendable {
    /// The epic number as the tracking file spells it (`9` for `epic-9`).
    public let id: String
    public var title: String
    public var status: Status
    public var retrospective: Status?
    public var stories: [Story]

    public var progress: (finished: Int, total: Int) {
        (stories.filter(\.status.isTerminal).count, stories.count)
    }
}

/// One row of a build-order queue table.
public struct QueueEntry: Identifiable, Hashable, Sendable {
    public var id: String { "\(section)#\(position)" }
    public let section: String
    public let position: String
    /// Story number as written, e.g. `9.16`.
    public let storyNumber: String
    public let waitsOn: [String]
    /// Markdown text from the "why" column.
    public let reason: String
}

public struct QueueSection: Identifiable, Hashable, Sendable {
    public var id: String { heading }
    public let heading: String
    public let entries: [QueueEntry]
}

public struct Project: Sendable {
    public let root: URL
    public var name: String
    public var layout: Layout
    public var epics: [Epic]
    public var queue: [QueueSection]
    public var sources: Sources
    /// Things the loader could not make sense of, shown rather than hidden.
    public var warnings: [String]

    public enum Layout: String, Sendable {
        case sprintStatus = "BMAD v6 (sprint-status.yaml)"
        case ticketTree = "BMAD v7 (ticket tree)"
    }

    public struct Sources: Sendable {
        public var statusFile: URL?
        public var epicsFile: URL?
        public var buildOrderFile: URL?
        public var storyDirectory: URL?
        public var planningDirectory: URL?
    }

    public var allStories: [Story] { epics.flatMap(\.stories) }

    public func story(number: String) -> Story? {
        allStories.first { $0.number == number }
    }

    public func story(id: String) -> Story? {
        allStories.first { $0.id == id }
    }
}
