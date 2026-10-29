import Foundation
import Testing
@testable import BmadKit

private let fixture = Bundle.module.url(forResource: "Fixtures/ticket-tree-v7", withExtension: nil)!

/// The fixture follows the current v7 layout, as `tickets.py` describes it: each container
/// keeps its own file at the top and its `tickets.toml`, epic folders, leaf files and plans
/// under a `tickets/` subfolder; the backlog holds its files directly.
@Suite struct TicketTreeV7Tests {
    let project: Project

    init() throws {
        project = try ProjectLoader.load(root: fixture)
    }

    @Test func theActiveInitiativeWithATicketsFolder() {
        #expect(project.layout == .ticketTree)
        #expect(project.name == "Money v2: our finances, again")
        #expect(project.documents.map(\.lastPathComponent) == ["initiative-v7.md", "tickets.toml"])
    }

    @Test func epicsFollowTheInitiativeBuildOrderThenTheBacklog() {
        #expect(project.epics.map(\.id) == ["epic-alpha", "epic-beta", "backlog"])
        #expect(project.epics.map(\.number) == ["2", "12", nil])
        #expect(project.epics.map(\.title) == ["Alpha core", "Beta surface", "Backlog"])
    }

    @Test func numbersAreEpicIDDotEntryIDIncludingStringIDs() throws {
        #expect(project.epics[0].stories.map(\.number) == ["2.1", "2.2", "2.3", "2.4", "2.5", "2.6"])
        #expect(project.epics[1].stories.map(\.number) == ["12.1", "12.b1", "12.3"])
        #expect(project.epics[2].stories.map(\.number) == ["B.story-loose"])
    }

    @Test func statusComesFromThePlanJoinedByTicket() throws {
        #expect(try #require(project.story(number: "2.1")).status.raw == "done")          // ticket: '1'
        #expect(try #require(project.story(number: "2.2")).status.raw == "in-progress")   // ticket: 2, over the leaf's
        #expect(try #require(project.story(number: "2.3")).status.raw == "planned")       // entry only
        #expect(try #require(project.story(number: "B.story-loose")).status.raw == "blocked") // ticket: '<stem>'
    }

    @Test func aPlanNamingNothingIsAProblemNotAFailure() throws {
        // `ticket: '9.9'` is no entry and no file stem: the plan is skipped, like tickets.py does.
        #expect(project.warnings.contains { $0.contains("story-nowhere-plan.md") && $0.contains("'9.9'") })
        #expect(project.allStories.allSatisfy { !$0.documents.contains { $0.url?.lastPathComponent == "story-nowhere-plan.md" } })
    }

    @Test func anUnknownPlanStatusBlocksTheTicket() throws {
        #expect(project.warnings.contains { $0.contains("story-half-built-plan.md") && $0.contains("half-built") })
        #expect(try #require(project.story(number: "2.4")).status.raw == "blocked")
    }

    @Test func aLeafFileJoinsItsEntryByAQuotedID() throws {
        let s = try #require(project.story(number: "2.2"))
        #expect(s.title == "The list, pulled")   // the leaf's id: '2' joins entry 2; its title wins
        #expect(s.documents.map(\.label) == ["Ticket", "Story file", "Plan"])
        #expect(s.risk == "high")
        #expect(s.waitsOn.isEmpty)               // started, so no longer waiting on 2.1
        let ticket = try #require(s.documents.first?.markdown)
        #expect(ticket.contains("### After\n\n- Story 2.1 — Foundation"))  // the leaf's after: [1]
        #expect(ticket.contains("### Unknown\n\npaging at 50k rows."))     // the leaf's Notes line
    }

    @Test func aSpikesFindingsFileJoinsBySpike() throws {
        let s = try #require(project.story(number: "2.3"))
        #expect(s.documents.map(\.label) == ["Ticket", "Findings"])
        #expect(s.documents.last?.url?.lastPathComponent == "spike-lookup-findings.md")
    }

    @Test func afterResolvesAcrossEpicsAndOverWholeEpics() throws {
        let s = try #require(project.story(number: "12.1"))
        #expect(s.waitsOn == ["2.2", "Alpha core"])         // "2.2" is epic 2's entry 2; the epic's own gate adds alpha
        let gated = try #require(project.story(number: "12.3"))
        #expect(gated.dependsOnEpics.contains("epic-alpha"))
        #expect(gated.waitsOn == ["Alpha core"])            // the `after` and the epic's own gate say it once
    }

    @Test func epicStatusAndDocumentsFollowTheLayout() {
        #expect(project.epics[0].status.raw == "in-progress")
        #expect(project.epics[1].status.raw == "planned")
        #expect(project.epics[0].retrospective?.raw == "done")
        let docs = project.epics[0].documents.map { $0.pathComponents.suffix(2).joined(separator: "/") }
        #expect(docs == ["epic-alpha/epic-alpha.md", "tickets/tickets.toml", "epic-alpha/epic-alpha-retrospective.md"])
    }

    @Test func nextGroupsLikeTicketsPyNext() {
        let groups = Dictionary(uniqueKeysWithValues: project.queue.map { ($0.heading, $0.entries.map(\.storyNumber)) })
        #expect(project.queue.map(\.heading) == ["In progress", "Ready to refine", "Blocked"])
        #expect(groups["In progress"] == ["2.2"])
        #expect(groups["Ready to refine"] == ["2.3", "2.6"]) // the flagged spike, and a bug refines by default
        #expect(groups["Blocked"] == ["2.4", "2.5", "12.1", "12.b1", "12.3"]) // unknown status, unknown owed, unmet after and gates
    }

    @Test func deferredWorkAndRetroActionsComeFromTheInitiative() throws {
        #expect(project.deferredWork.count == 2)
        #expect(project.deferredWorkFile?.pathComponents.suffix(2) == ["initiative-v7", "deferred-work.md"])
        #expect(project.retroActions.count == 2)
        #expect(Set(project.retroActions.map(\.epic)) == ["epic-alpha"])
    }

    @Test func aParentInitiativeNamesItsChildren() throws {
        let paths = ConfigResolver.resolve(root: fixture)
        let parent = fixture.appending(path: "_bmad-output/initiative-parent")
        let p = try TicketTree.load(root: fixture, initiative: parent, paths: paths)
        #expect(p.epics.isEmpty)
        #expect(p.warnings.contains { $0.contains("parent initiative") && $0.contains("initiative-v7") })
    }

    @Test func openingAFileOpensTheProjectThatContainsIt() throws {
        // A restored window or a double-clicked markdown file hands the loader a
        // file, not a folder; it must land on the containing project, not an
        // empty one.
        let initiative = fixture.appending(path: "_bmad-output/initiative-v7")
        for file in ["initiative-v7.md", "tickets/tickets.toml"] {
            let p = try ProjectLoader.load(root: initiative.appending(path: file))
            #expect(p.layout == .ticketTree, "opened \(file)")
            #expect(p.epics.map(\.id) == ["epic-alpha", "epic-beta", "backlog"], "opened \(file)")
        }
    }
}
