import Foundation

/// How a list of retro actions or deferred work is filtered, ordered and grouped.
public struct WorkItemQuery: Codable, Hashable, Sendable {
    public enum Sort: String, Codable, CaseIterable, Sendable {
        case key = "Key"
        case state = "State"
        case priority = "Priority"
    }

    public var sort: Sort = .key
    /// Descending by default: the newest entry (highest key) first.
    public var ascending = false
    /// Raw states to keep; empty keeps all.
    public var states: Set<String> = []
    public var priorities: Set<Priority> = []
    /// Epic ids to keep (retro actions); empty keeps all.
    public var epics: Set<String> = []

    public init() {}

    public var activeFilterCount: Int { states.count + priorities.count + epics.count }

    public struct Section: Hashable, Sendable {
        public let title: String
        /// The epic a section is for, when grouped by epic.
        public let epic: String?
        public let items: [WorkItem]
    }

    public func apply(_ items: [WorkItem]) -> [Section] {
        let kept = items.filter { item in
            (states.isEmpty || states.contains(item.status.raw))
                && (priorities.isEmpty || priorities.contains(item.priority))
                && (epics.isEmpty || epics.contains(item.epic ?? ""))
        }
        // Each epic's rank is where it first appears: the file's own order.
        var epicRank: [String: Int] = [:]
        for item in items where epicRank[item.epic ?? ""] == nil { epicRank[item.epic ?? ""] = epicRank.count }

        let byKey: (WorkItem, WorkItem) -> Bool = { a, b in
            let ka = Self.key(a), kb = Self.key(b)
            return ascending ? ka.lexicographicallyPrecedes(kb) : kb.lexicographicallyPrecedes(ka)
        }

        switch sort {
        case .key:
            if kept.contains(where: { $0.kind == .humanRun }) {
                // Human runs keep their source's grouping: smoke tests, checkpoints, tickets.
                var order: [String] = []
                for item in items where !order.contains(item.section ?? "") { order.append(item.section ?? "") }
                let grouped = Dictionary(grouping: kept) { $0.section ?? "" }
                return order.compactMap { k in grouped[k].map { Section(title: k.isEmpty ? "Other" : k, epic: nil, items: $0.sorted(by: byKey)) } }
            }
            guard kept.contains(where: { $0.kind == .retroAction }) else {
                return kept.isEmpty ? [] : [Section(title: "All", epic: nil, items: kept.sorted(by: byKey))]
            }
            // Retro actions stay with their epic; the epics follow the same direction.
            let grouped = Dictionary(grouping: kept) { $0.epic ?? "" }
            let order = grouped.keys.sorted {
                let a = epicRank[$0] ?? 0, b = epicRank[$1] ?? 0
                return ascending ? a < b : a > b
            }
            return order.map { Section(title: $0, epic: $0, items: grouped[$0]!.sorted(by: byKey)) }
        case .state:
            let grouped = Dictionary(grouping: kept) { $0.status.raw }
            let order = grouped.keys.sorted { (Self.stateRank($0), $0) < (Self.stateRank($1), $1) }
            return order.map { Section(title: $0.prefix(1).uppercased() + $0.dropFirst(), epic: nil, items: grouped[$0]!.sorted(by: byKey)) }
        case .priority:
            let grouped = Dictionary(grouping: kept, by: \.priority)
            return grouped.keys.sorted().map { Section(title: $0.label, epic: nil, items: grouped[$0]!.sorted(by: byKey)) }
        }
    }

    /// Open work first, finished work last.
    public static func stateRank(_ raw: String) -> Int {
        switch Status(raw).kind {
        case .blocked: 0
        case .inProgress: 1
        case .review: 2
        case .backlog, .ready: raw == "open" ? 3 : 4
        case .other, .optional, .built: 5
        case .done: 6
        case .superseded: 7
        }
    }

    /// A natural key: `DW-12` after `DW-9`; canonical entries after legacy bullets;
    /// retro items by their number.
    static func key(_ item: WorkItem) -> [Int] {
        let digits = item.label.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        let family = item.label.hasPrefix("DW-") ? 1 : 0
        return [family] + (digits.isEmpty ? [item.line ?? 0] : digits)
    }
}

public enum Priority: Int, Codable, CaseIterable, Comparable, Sendable {
    case critical, high, medium, low, unspecified

    public static func < (a: Priority, b: Priority) -> Bool { a.rawValue < b.rawValue }

    public init(_ text: String?) {
        switch text?.lowercased().trimmingCharacters(in: .whitespaces) {
        case "critical", "p0", "blocker": self = .critical
        case "high", "p1": self = .high
        case "medium", "p2", "normal": self = .medium
        case "low", "p3", "minor": self = .low
        default: self = .unspecified
        }
    }

    public var label: String {
        switch self {
        case .critical: "Critical"
        case .high: "High"
        case .medium: "Medium"
        case .low: "Low"
        case .unspecified: "Unspecified"
        }
    }
}

public extension WorkItem {
    /// `severity:` (the deferred-work format's field), else a `priority:` field.
    var priority: Priority { Priority(severity ?? value("priority")) }
}
