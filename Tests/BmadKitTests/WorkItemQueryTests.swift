import Foundation
import Testing
@testable import BmadKit

@Suite struct WorkItemQueryTests {
    func dw(_ n: Int, _ status: String, _ severity: String? = nil) -> WorkItem {
        var item = WorkItem(id: "DW-\(n)", kind: .deferred, label: "DW-\(n)", title: "t\(n)", status: Status(status))
        item.severity = severity
        return item
    }

    func retro(_ n: Int, epic: String, _ status: String = "open") -> WorkItem {
        var item = WorkItem(id: "r\(n)", kind: .retroAction, label: "\(n)", title: "t\(n)", status: Status(status))
        item.epic = epic
        return item
    }

    var ledger: [WorkItem] {
        [dw(2, "done", "high"), dw(10, "open", "low"), dw(9, "open"), dw(1, "in-progress", "critical")]
    }

    @Test func keyIsNaturalAndNewestFirstByDefault() {
        let q = WorkItemQuery()
        #expect(q.apply(ledger).flatMap(\.items).map(\.label) == ["DW-10", "DW-9", "DW-2", "DW-1"])
        var up = q
        up.ascending = true
        #expect(up.apply(ledger).flatMap(\.items).map(\.label) == ["DW-1", "DW-2", "DW-9", "DW-10"])
    }

    @Test func canonicalEntriesSortAfterLegacyBullets() {
        var legacy = WorkItem(id: "x:5", kind: .deferred, label: "L5", title: "", status: Status("open"))
        legacy.line = 5
        var q = WorkItemQuery()
        q.ascending = true
        #expect(q.apply([dw(3, "open"), legacy]).flatMap(\.items).map(\.label) == ["L5", "DW-3"])
    }

    @Test func stateGroupsOpenWorkFirst() {
        var q = WorkItemQuery()
        q.sort = .state
        let sections = q.apply(ledger)
        #expect(sections.map(\.title) == ["In-progress", "Open", "Done"])
        #expect(sections[1].items.map(\.label) == ["DW-10", "DW-9"])
    }

    @Test func priorityGroupsCriticalFirstAndUnspecifiedLast() {
        var q = WorkItemQuery()
        q.sort = .priority
        #expect(q.apply(ledger).map(\.title) == ["Critical", "High", "Low", "Unspecified"])
    }

    @Test func filtersCombine() {
        var q = WorkItemQuery()
        q.states = ["open"]
        #expect(q.apply(ledger).flatMap(\.items).map(\.label) == ["DW-10", "DW-9"])
        q.priorities = [.low]
        #expect(q.apply(ledger).flatMap(\.items).map(\.label) == ["DW-10"])
        #expect(q.activeFilterCount == 2)
    }

    @Test func retroActionsStayWithTheirEpicInKeyOrder() {
        let items = [retro(1, epic: "1"), retro(2, epic: "1", "done"), retro(139, epic: "10"), retro(140, epic: "10")]
        let q = WorkItemQuery()
        let sections = q.apply(items)
        #expect(sections.map(\.epic) == ["10", "1"])
        #expect(sections[0].items.map(\.label) == ["140", "139"])
        var epicFilter = q
        epicFilter.epics = ["1"]
        #expect(epicFilter.apply(items).flatMap(\.items).map(\.label) == ["2", "1"])
    }

    @Test func priorityReadsSeverityThenAPriorityField() {
        var item = WorkItem(id: "a", kind: .retroAction, label: "1", title: "", status: Status("open"))
        #expect(item.priority == .unspecified)
        item.fields = [.init(key: "priority", value: "P1")]
        #expect(item.priority == .high)
        item.severity = "critical"
        #expect(item.priority == .critical)
    }

    @Test func aQueryRoundTripsThroughJSON() throws {
        var q = WorkItemQuery()
        q.sort = .priority
        q.states = ["open"]
        q.priorities = [.high]
        let back = try JSONDecoder().decode(WorkItemQuery.self, from: JSONEncoder().encode(q))
        #expect(back == q)
    }
}
