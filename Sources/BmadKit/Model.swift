import Foundation

/// A status as written in the tracking file or plan. The raw string is kept
/// verbatim so nothing the project invents (`superseded`, `optional`, `built`) is
/// lost; `kind` is only for grouping and colour.
public struct Status: Hashable, Sendable {
    public enum Kind: Int, Sendable, CaseIterable, Comparable {
        case blocked, inProgress, review, ready, backlog, built, done, superseded, optional, other

        public static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }

        public var label: String {
            switch self {
            case .blocked: "Blocked"
            case .inProgress: "In progress"
            case .review: "Review"
            case .ready: "Ready for dev"
            case .backlog: "Backlog"
            case .built: "Built"
            case .done: "Done"
            case .superseded: "Superseded / dropped"
            case .optional: "Optional"
            case .other: "Other"
            }
        }
    }

    public let raw: String

    public init(_ raw: String) { self.raw = raw.trimmingCharacters(in: .whitespaces) }

    public var kind: Kind {
        switch raw.lowercased() {
        case "blocked": .blocked
        case "in-progress", "in_progress", "in progress", "doing": .inProgress
        case "review", "in-review": .review
        case "ready-for-dev", "ready", "ready_for_dev", "drafted", "contexted": .ready
        // v7: no status yet, a planned entry with no file, or a build's draft are all backlog.
        case "backlog", "todo", "planned", "not started", "draft", "open", "proposed": .backlog
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
    public var isActive: Bool { [.blocked, .inProgress, .review, .ready].contains(kind) }
}

/// One readable view of a story: a file on disk, or markdown assembled from
/// the planning documents (an `epics.md` section, a `tickets.toml` entry).
public struct StoryDocument: Hashable, Sendable {
    public let label: String
    public let url: URL?
    public let markdown: String?

    public init(label: String, url: URL) {
        self.label = label
        self.url = url
        markdown = nil
    }

    public init(label: String, markdown: String, url: URL? = nil) {
        self.label = label
        self.url = url
        self.markdown = markdown
    }
}

public struct Story: Identifiable, Hashable, Sendable {
    /// Unique within the project: the tracking key (`9-16-capture-rs-…`) or `<epic folder>/<entry id>`.
    public let id: String
    /// Display number, e.g. `9.16`; what "Story 9.16" and `after = ["2.1"]` refer to.
    public let number: String
    public let epicID: String
    public var title: String
    public var status: Status
    /// `story`, `spike` or `bug` in a v7 ticket tree.
    public var type: String?
    /// Views of the story, in the order the detail shows them; the first is the default.
    public var documents: [StoryDocument] = []
    /// Front matter of the story's own file.
    public var frontMatter: [String: String] = [:]
    /// Prerequisites not yet met, as display numbers or epic names.
    public var waitsOn: [String] = []
    public var risk: String?
    /// The story document's Suggested Review Order, when it has one.
    public var review: ReviewOrder?

    public init(id: String, number: String, epicID: String, title: String, status: Status) {
        self.id = id
        self.number = number
        self.epicID = epicID
        self.title = title
        self.status = status
    }

    /// The first document that is a file.
    public var primaryFile: URL? { documents.lazy.compactMap(\.url).first }
    public var files: [URL] { documents.compactMap(\.url) }
}

public struct Epic: Identifiable, Hashable, Sendable {
    /// The epic number as the tracking file spells it (`9` for `epic-9`), or the
    /// initiative's epic id in a ticket tree.
    public let id: String
    /// The number stories are numbered under (`9` → `9.16`); nil for the backlog.
    public var number: String?
    public var title: String
    public var status: Status
    public var retrospective: Status?
    public var stories: [Story]
    /// The epic's own files (epic document, tickets.toml, retrospective).
    public var documents: [URL] = []

    public init(id: String, title: String, status: Status, retrospective: Status? = nil, stories: [Story] = []) {
        self.id = id
        number = Int(id) != nil ? id : nil
        self.title = title
        self.status = status
        self.retrospective = retrospective
        self.stories = stories
    }

    public var progress: (finished: Int, total: Int) {
        (stories.filter(\.status.isTerminal).count, stories.count)
    }

    public var builtCount: Int { stories.filter { $0.status.kind == .built }.count }
}

/// One row of the queue: a build-order table row, or a v7 ticket that is next.
public struct QueueEntry: Identifiable, Hashable, Sendable {
    public var id: String { "\(section)#\(position)#\(storyNumber)" }
    public let section: String
    public let position: String
    /// Story number as written, e.g. `9.16`.
    public let storyNumber: String
    public let waitsOn: [String]
    /// Markdown text from the "why" column.
    public let reason: String

    public init(section: String, position: String, storyNumber: String, waitsOn: [String], reason: String) {
        self.section = section
        self.position = position
        self.storyNumber = storyNumber
        self.waitsOn = waitsOn
        self.reason = reason
    }
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
    /// Project-level files for the sidebar's Documents section.
    public var documents: [URL] = []
    /// Retrospective action items, oldest epic first.
    public var retroActions: [WorkItem] = []
    /// Deferred-work ledger entries in file order.
    public var deferredWork: [WorkItem] = []
    /// The ledger file, when there is one.
    public var deferredWorkFile: URL?
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

        public init(statusFile: URL? = nil, epicsFile: URL? = nil, buildOrderFile: URL? = nil,
                    storyDirectory: URL? = nil, planningDirectory: URL? = nil) {
            self.statusFile = statusFile
            self.epicsFile = epicsFile
            self.buildOrderFile = buildOrderFile
            self.storyDirectory = storyDirectory
            self.planningDirectory = planningDirectory
        }

        /// Folders whose changes should trigger a reload.
        public var watched: [URL] {
            [statusFile?.deletingLastPathComponent(), planningDirectory, storyDirectory].compactMap { $0 }
        }
    }

    public var allStories: [Story] { epics.flatMap(\.stories) }

    public func story(number: String) -> Story? {
        allStories.first { $0.number == number }
    }

    public func story(id: String) -> Story? {
        allStories.first { $0.id == id }
    }
}
