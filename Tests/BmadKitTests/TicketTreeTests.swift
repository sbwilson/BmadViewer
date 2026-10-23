import Foundation
import Testing
@testable import BmadKit

private let fixture = Bundle.module.url(forResource: "Fixtures/ticket-tree", withExtension: nil)!

/// The fixture follows pangolin's layout: `tickets.toml` directly in the initiative
/// and epic folders, status in `*-plan.md` beside the entry, a sibling `backlog/`.
@Suite struct TicketTreeTests {
    let project: Project

    init() throws {
        project = try ProjectLoader.load(root: fixture)
    }

    @Test func theActiveInitiativeWinsOverOlderV6Artifacts() {
        #expect(project.layout == .ticketTree)
        #expect(project.name == "Money v1: our finances")
        #expect(project.documents.map(\.lastPathComponent) == ["initiative-money.md", "tickets.toml"])
    }

    @Test func epicsFollowTheInitiativeBuildOrderThenTheBacklog() {
        #expect(project.epics.map(\.id) == ["epic-ledger-core", "epic-workspace", "epic-budgets", "backlog"])
        #expect(project.epics.map(\.number) == ["2", "12", "6", nil])
        #expect(project.epics.map(\.title) == ["Ledger core and privacy", "Ledger workspace", "Budgets and recurring bills", "Backlog"])
    }

    @Test func numbersAreEpicIDDotEntryID() {
        #expect(project.epics[1].stories.map(\.number) == ["12.1", "12.2", "12.3", "12.4"])
        #expect(project.epics[3].stories.map(\.number) == ["B.1", "B.spike-drill-stall", "B.story-status-lists-jobs"])
    }

    @Test func statusComesFromThePlanJoinedByTicket() throws {
        #expect(try #require(project.story(number: "2.1")).status.raw == "done")      // ticket: '1'
        #expect(try #require(project.story(number: "2.2")).status.raw == "built")     // ticket: 2
        #expect(try #require(project.story(number: "12.1")).status.raw == "in-progress")
        #expect(try #require(project.story(number: "12.2")).status.raw == "not started") // leaf file, no plan
        #expect(try #require(project.story(number: "12.3")).status.raw == "planned")     // entry only
        #expect(try #require(project.story(number: "B.story-status-lists-jobs")).status.raw == "blocked") // ticket: '<stem>'
    }

    @Test func aLeafFileJoinsItsEntryByIDAndOverridesTitleAndAfter() throws {
        let s = try #require(project.story(number: "12.2"))
        #expect(s.title == "Transaction list, pulled")
        #expect(s.documents.map(\.label) == ["Ticket", "Story file"])
        #expect(s.waitsOn == ["12.1"]) // the file's after: [1], not the entry's [1, "2.1"]
    }

    @Test func crossEpicAfterIsMetByAStoryInReview() throws {
        // 12.1 waits on "2.2", which is built: built counts as review, and review meets an `after`.
        #expect(try #require(project.story(number: "12.1")).waitsOn.isEmpty)
        #expect(try #require(project.story(number: "12.4")).waitsOn == ["12.2", "12.3"])
    }

    @Test func documentsAreTicketThenStoryFileThenPlan() throws {
        let s = try #require(project.story(number: "2.1"))
        #expect(s.documents.map(\.label) == ["Ticket", "Plan"])
        let ticket = try #require(s.documents.first?.markdown)
        #expect(ticket.contains("### Delivers\n\nTables for accounts and transactions."))
        #expect(ticket.contains("### Verify\n\nMigrations run."))
        #expect(s.frontMatter["baseline_revision"] == "abc12345def")
        let multi = try #require(project.story(number: "2.2")?.documents.first?.markdown)
        #expect(multi.contains("A multi-line\ndescription."))
        #expect(multi.contains("- Story 2.1 — Ledger schema"))
    }

    @Test func epicStatusIsDerivedWhenTheContainerHasNone() {
        #expect(project.epics[0].status.raw == "in-progress") // one done, one built
        #expect(project.epics[0].retrospective?.raw == "done")
        #expect(project.epics[0].builtCount == 1)
        #expect(project.epics[2].status.raw == "not refined")
        #expect(project.epics[0].documents.map(\.lastPathComponent) == ["epic-ledger-core.md", "tickets.toml", "epic-ledger-core-retrospective.md"])
    }

    @Test func nextGroupsLikeTicketsPyNext() {
        let groups = Dictionary(uniqueKeysWithValues: project.queue.map { ($0.heading, $0.entries.map(\.storyNumber)) })
        #expect(project.queue.map(\.heading) == ["In progress", "Built — awaiting done", "Ready to refine", "Blocked"])
        #expect(groups["In progress"] == ["12.1"])
        #expect(groups["Built — awaiting done"] == ["2.2"])
        #expect(groups["Ready to refine"] == ["12.3"])
        #expect(groups["Blocked"] == ["12.2", "12.4"])
    }

    @Test func typesAndRiskAreCarried() throws {
        #expect(try #require(project.story(number: "12.3")).type == "spike")
        #expect(try #require(project.story(number: "B.1")).type == "bug")
        #expect(try #require(project.story(number: "B.1")).risk == "high")
        #expect(project.warnings.isEmpty)
    }
}
