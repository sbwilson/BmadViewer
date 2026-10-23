import Foundation
import Testing
@testable import BmadKit

private let v6 = Bundle.module.url(forResource: "Fixtures/qubric-shaped", withExtension: nil)!
private let v7 = Bundle.module.url(forResource: "Fixtures/ticket-tree", withExtension: nil)!

@Suite struct DeferredWorkTests {
    let items: [WorkItem]

    init() throws {
        items = try ProjectLoader.load(root: v6).deferredWork
    }

    @Test func canonicalEntriesAndLegacyBulletsAreBothRead() {
        #expect(items.map(\.label) == ["DW-1", "DW-2", "L34", "L37"])
    }

    @Test func aFencedExampleStartsNoEntry() {
        #expect(!items.contains { $0.label == "DW-999" })
    }

    @Test func fieldsAreReadInOrderWithRepeatsAndNonIdentifierKeys() throws {
        let dw1 = try #require(items.first)
        #expect(dw1.title == "Issuer-qualify the SessionUserScope key")
        #expect(dw1.fields.map(\.key) == ["origin", "location", "owner", "severity", "reason", "sweep 2026-09-22", "status", "gate"])
        #expect(dw1.owner == "Epic 10")
        #expect(dw1.severity == "high")
        #expect(dw1.gates == ["9-16", "9-17"])
        #expect(dw1.line == 11)
        #expect(dw1.status.raw == "open")
    }

    @Test func statusWordIsReadWithoutItsDate() throws {
        let dw2 = try #require(items.first { $0.label == "DW-2" })
        #expect(dw2.status.raw == "done")
        #expect(dw2.value("status") == "done 2026-09-20")
        #expect(dw2.value("resolution") == "built by story 1.2")
    }

    @Test func legacyBulletsTakeTheirSummaryAndDisposition() throws {
        #expect(items[2].title == "A flat-append bullet the sweep has not migrated.")
        #expect(items[2].status.raw == "open")
        #expect(items[2].section == "Legacy appends")
        #expect(items[3].status.raw == "done")
    }

    @Test func pangolinStyleLedger() throws {
        let p = try ProjectLoader.load(root: v7)
        #expect(p.deferredWork.map(\.status.raw) == ["done", "open", "open"]) // "partly fixed" is still open
        #expect(p.deferredWork.last?.section == "1.12 sweep (2026-10-01)")
        #expect(p.deferredWork.last?.title == "System-clock reads are a lint error.")
        #expect(p.deferredWorkFile?.lastPathComponent == "deferred-work.md")
    }
}

@Suite struct RetroActionTests {
    @Test func sprintStatusActionItemsAreTheSourceInV6() throws {
        let p = try ProjectLoader.load(root: v6)
        #expect(p.retroActions.map(\.label) == ["1", "152"])
        let first = p.retroActions[0]
        #expect(first.title == "Run the pipeline on f8ef7884 and record the provenance (F2)")
        #expect(first.status.raw == "done")
        #expect(first.epic == "1")
        #expect(first.related.map(\.lastPathComponent) == ["epic-1-retro-2026-09-01.md"])
        #expect(p.retroActions[1].value("progress") == "Story 9.16 drafted")
        #expect(p.retroActions[1].related.isEmpty) // its ref names a missing file
        // The retro document is listed with its epic.
        #expect(p.epics[0].documents.map(\.lastPathComponent) == ["epic-1-retro-2026-09-01.md"])
    }

    @Test func v7ReadsTheActionItemsSectionOfEachRetrospective() throws {
        let p = try ProjectLoader.load(root: v7)
        #expect(p.retroActions.map(\.label) == ["#1", "#2", "#3"])
        #expect(p.retroActions.map(\.status.raw) == ["proposed", "proposed", "proposed"])
        let a = p.retroActions[0]
        #expect(a.title == "Extract `formatCents` to a shared utility (A3)")
        #expect(a.owner == "dev loop")
        #expect(a.section == "Remediation & Cleanups")
        #expect(a.epic == "epic-ledger-core")
        #expect(p.retroActions[1].value("detail") == "Extract hooks to stay under 500 lines. Owner: dev loop.")
        #expect(p.retroActions[2].title == "Monitor FTS5 reindex latency (L1).")
        #expect(p.retroActions[2].section == "Deferred (Tracked)")
    }

    @Test func aRetrospectiveTableWithAnActionColumnIsRead() {
        let items = WorkItems.retrospectiveActions("""
        ## Action items

        | # | Action | Owner | From |
        | --- | --- | --- | --- |
        | 1 | **CLOSE PRECONDITION.** A measurement carries a cause. | Simon | A6 |
        | 2 | Fix the comment. | dev | B8 |

        ## Acceptance verdict
        """, source: URL(filePath: "/tmp/r.md"), epic: "10")
        #expect(items.map(\.label) == ["#1", "#2"])
        #expect(items[0].title == "CLOSE PRECONDITION. A measurement carries a cause.")
        #expect(items[0].owner == "Simon")
        #expect(items[1].title == "Fix the comment.")
    }
}
