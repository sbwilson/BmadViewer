import Foundation
import Testing
@testable import BmadKit

private let v6 = Bundle.module.url(forResource: "Fixtures/qubric-shaped", withExtension: nil)!

/// The writes beyond review completion — a smoke test or checkpoint recorded as
/// passed, a note on a retro action, a new ledger entry. Each is planned as line
/// edits and applied through `ReviewCompletion.apply`, the review pane's gate.
@Suite struct WorkItemEditsTests {
    /// A smoke index in a temp folder: rows as a real one writes them.
    private func smokeIndex(_ rows: [String]) throws -> (URL, [WorkItem]) {
        let url = FileManager.default.temporaryDirectory.appending(path: "smoke-tests-\(UUID().uuidString).md")
        let text = rows.joined(separator: "\n")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return (url, HumanRuns.smokeTests(text, index: url))
    }

    private func copiedProject() throws -> (URL, Project) {
        let root = FileManager.default.temporaryDirectory.appending(path: "bmadviewer-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: v6, to: root)
        return (root, try ProjectLoader.load(root: root))
    }

    // MARK: Smoke tests

    @Test func aRowSetToPassKeepsTheRestOfItsRowAndItsNeighbours() throws {
        let (url, items) = try smokeIndex([
            "| Test | What it proves | Status | Blocking / qualification | Gates | Owner |",
            "|---|---|---|---|---|---|",
            "| [SMOKE-S4-06-1](smoke-tests/SMOKE-S4-06-1.md) | Forced launch works. | ✅ `pass`<br>2026-08-06 | — | Sprint-4 go/no-go. | Simon |",
            "| [SMOKE-S4-08-4](smoke-tests/SMOKE-S4-08-4.md) | An interrupted procedure opens. | ⬜ `not-run` | The longest steps | S4-8-4 AC9. | Dana / Simon |",
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let owed = try #require(items.first { $0.label == "SMOKE-S4-08-4" })
        let edit = try #require(WorkItemEdits.smokeTestPass(owed).get().first)
        #expect(edit.line == 4)
        #expect(edit.after.hasPrefix("| [SMOKE-S4-08-4](smoke-tests/SMOKE-S4-08-4.md) | An interrupted procedure opens. |"))
        #expect(edit.after.contains("✅ `pass`<br>\(WorkItemEdits.today())"))
        #expect(edit.after.hasSuffix("| The longest steps | S4-8-4 AC9. | Dana / Simon |"))

        try ReviewCompletion.apply([edit])
        let reread = HumanRuns.smokeTests(try String(contentsOf: url, encoding: .utf8), index: url)
        #expect(reread.first { $0.label == "SMOKE-S4-08-4" }?.status.raw == "pass")
        #expect(reread.first { $0.label == "SMOKE-S4-08-4" }?.value("blocking") == "The longest steps")
        #expect(reread.first { $0.label == "SMOKE-S4-08-4" }?.owner == "Dana / Simon")
        // The row above, already passed, is exactly itself.
        #expect(reread.first { $0.label == "SMOKE-S4-06-1" }?.value("status") == "pass (last run 2026-08-06)")
    }

    @Test func aRunAlreadyPassedIsNotWrittenAgain() throws {
        let (url, items) = try smokeIndex([
            "| Test | What it proves | Status |",
            "|---|---|---|",
            "| [SMOKE-1](smoke-tests/SMOKE-1.md) | It starts. | ✅ `pass`<br>2026-08-06 |",
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(WorkItemEdits.smokeTestPass(try #require(items.first)) == .failure(.alreadyPassed))
    }

    @Test func aRowThatIsNoLongerARowIsRefused() throws {
        let (url, items) = try smokeIndex([
            "| Test | What it proves | Status |",
            "|---|---|---|",
            "| [SMOKE-1](smoke-tests/SMOKE-1.md) | It starts. | ⬜ `not-run` |",
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        var owed = try #require(items.first)
        owed.line = 1  // the header, above which no header is to be found
        #expect(WorkItemEdits.smokeTestPass(owed) == .failure(.cellNotFound))
        owed.line = 40  // past the end of the file
        #expect(WorkItemEdits.smokeTestPass(owed) == .failure(.itemGone))
        owed.source = nil
        #expect(WorkItemEdits.smokeTestPass(owed) == .failure(.noSource))
    }

    @Test func aTableWithoutAStatusColumnIsRefused() throws {
        let (url, _) = try smokeIndex([
            "| Test | What it proves |",
            "|---|---|",
            "| [SMOKE-1](smoke-tests/SMOKE-1.md) | It starts. |",
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        // No Status column: the reader has no row for it, so the write is asked of
        // a row built by hand — and refused rather than guessed at a column.
        var owed = WorkItem(id: "SMOKE-1", kind: .humanRun, label: "SMOKE-1", title: "It starts.", status: Status("not-run"))
        owed.section = "Smoke tests"
        owed.source = url
        owed.line = 3
        #expect(WorkItemEdits.smokeTestPass(owed) == .failure(.cellNotFound))
    }

    // MARK: Checkpoints

    /// One entry with its status below the id, one with it above, and a neighbour
    /// on either side to prove the search stops at the braces.
    private func checkpointFile(_ body: String) throws -> (URL, [WorkItem]) {
        let url = FileManager.default.temporaryDirectory.appending(path: "checkpoints-\(UUID().uuidString).json")
        try body.write(to: url, atomically: true, encoding: .utf8)
        return (url, HumanRuns.checkpoints(url))
    }

    private static let checkpoints = """
    {
      "checkpoints": [
        {
          "id": "cp-done",
          "checkpoint": "Already run",
          "status": "pass"
        },
        {
          "id": "cp-open",
          "checkpoint": "The list still loads",
          "proves": "Rows after a rebuild",
          "story": "9.15",
          "status": "fail"
        },
        {
          "status": "not-run",
          "id": "cp-reversed"
        }
      ]
    }
    """

    @Test func anEntryPassesByItsOwnStatusLine() throws {
        let (url, items) = try checkpointFile(Self.checkpoints)
        defer { try? FileManager.default.removeItem(at: url) }
        let failed = try #require(items.first { $0.id == "checkpoint:cp-open" })
        let edit = try #require(WorkItemEdits.checkpointPass(failed).get().first)
        #expect(edit.before == "      \"status\": \"fail\"")
        #expect(edit.after == "      \"status\": \"pass\"")
        try ReviewCompletion.apply([edit])

        let reread = HumanRuns.checkpoints(url)
        #expect(reread.first { $0.id == "checkpoint:cp-open" }?.status.raw == "pass")
        #expect(reread.first { $0.id == "checkpoint:cp-open" }?.value("story") == "9.15")
        #expect(reread.first { $0.id == "checkpoint:cp-done" }?.status.raw == "pass")
        #expect(reread.first { $0.id == "checkpoint:cp-reversed" }?.status.raw == "not-run")
    }

    @Test func aStatusWrittenAboveItsIdIsFoundThereNotNextDoor() throws {
        let (url, items) = try checkpointFile(Self.checkpoints)
        defer { try? FileManager.default.removeItem(at: url) }
        // `cp-reversed`'s status sits on the line above its id: the one below
        // belongs to no entry, and the file's closing braces stop the search.
        let reversed = try #require(items.first { $0.id == "checkpoint:cp-reversed" })
        let edit = try #require(WorkItemEdits.checkpointPass(reversed).get().first)
        #expect(edit.before == "      \"status\": \"not-run\",")
        try ReviewCompletion.apply([edit])
        let reread = HumanRuns.checkpoints(url)
        #expect(reread.first { $0.id == "checkpoint:cp-reversed" }?.status.raw == "pass")
        #expect(reread.first { $0.id == "checkpoint:cp-open" }?.status.raw == "fail")
    }

    @Test func anAlreadyPassedOrGoneCheckpointIsRefused() throws {
        let (url, items) = try checkpointFile(Self.checkpoints)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(WorkItemEdits.checkpointPass(try #require(items.first { $0.id == "checkpoint:cp-done" })) == .failure(.alreadyPassed))
        var ghost = WorkItem(id: "checkpoint:cp-nope", kind: .humanRun, label: "CP9", title: "Nothing", status: Status("not-run"))
        ghost.section = "Checkpoints"
        ghost.source = url
        #expect(WorkItemEdits.checkpointPass(ghost) == .failure(.itemGone))
        // A smoke test asked of the JSON writer is the wrong file altogether.
        let row = WorkItem(id: "SMOKE-1", kind: .humanRun, label: "SMOKE-1", title: "It starts.", status: Status("not-run"))
        #expect(WorkItemEdits.checkpointPass(row) == .failure(.noSource))
    }

    // MARK: Retro actions

    @Test func aProgressNoteReplacesTheLineAlreadyThere() throws {
        let (root, project) = try copiedProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let owed = try #require(project.retroActions.first { $0.label == "152" })
        #expect(owed.value("progress") == "Story 9.16 drafted")
        let edits = try WorkItemEdits.retroActionRecord(owed, in: project, progress: "Story 9.16 built, review owed",
                                                        resolution: nil).get()
        #expect(edits.count == 1)
        #expect(edits[0].after == "    progress: \"Story 9.16 built, review owed\"")
        try ReviewCompletion.apply(edits)

        let item = try #require(try ProjectLoader.load(root: root).retroActions.first { $0.label == "152" })
        #expect(item.value("progress") == "Story 9.16 built, review owed")
        #expect(item.value("owner") == "Simon (planning)")
        #expect(item.status.raw == "in-progress")
        #expect(item.value("action")?.contains("Split capture.rs") == true)
    }

    @Test func aNoteWithNoLineYetLandsAtTheEndOfItsOwnBlock() throws {
        let (root, project) = try copiedProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let owed = try #require(project.retroActions.first { $0.label == "1" })
        let edits = try WorkItemEdits.retroActionRecord(owed, in: project, progress: "Rerunning it now",
                                                        resolution: "Provenance recorded").get()
        // Both are new, so both go at the block's end — but as edits on distinct
        // lines, so applying them cannot lose one.
        #expect(Set(edits.map(\.line)).count == edits.count)
        try ReviewCompletion.apply(edits)

        let reread = try ProjectLoader.load(root: root)
        let item = try #require(reread.retroActions.first { $0.label == "1" })
        #expect(item.value("progress") == "Rerunning it now")
        #expect(item.value("resolution") == "Provenance recorded")
        #expect(item.value("ref")?.hasSuffix("epic-1-retro-2026-09-01.md") == true)
        #expect(item.status.raw == "done")
        // Its neighbour, whose progress line was rewritten in the other test's
        // shape, is untouched here.
        #expect(reread.retroActions.first { $0.label == "152" }?.value("progress") == "Story 9.16 drafted")
    }

    @Test func aQuoteInsideANoteStaysInsideItsString() throws {
        let (root, project) = try copiedProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let owed = try #require(project.retroActions.first { $0.label == "152" })
        let edits = try WorkItemEdits.retroActionRecord(owed, in: project, progress: #"Said "review again" today"#,
                                                        resolution: nil).get()
        try ReviewCompletion.apply(edits)
        let item = try #require(try ProjectLoader.load(root: root).retroActions.first { $0.label == "152" })
        #expect(item.value("progress") == #"Said "review again" today"#)
    }

    @Test func nothingNewIsNotAWrite() throws {
        let (root, project) = try copiedProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let owed = try #require(project.retroActions.first { $0.label == "152" })
        #expect(WorkItemEdits.retroActionRecord(owed, in: project, progress: "  ", resolution: "\n") == .failure(.nothingToRecord))
        // The same words the line already holds are nothing to write.
        #expect(WorkItemEdits.retroActionRecord(owed, in: project, progress: "Story 9.16 drafted", resolution: nil)
            == .failure(.nothingToRecord))
        // An action written in a retrospective document is not tracked in the status file.
        let elsewhere = project.retroActions.first { $0.source != project.sources.statusFile }
        if let elsewhere {
            #expect(WorkItemEdits.retroActionRecord(elsewhere, in: project, progress: "Not here", resolution: nil)
                == .failure(.notATrackedItem))
        }
    }

    // MARK: Deferred work

    @Test func theNextEntryContinuesTheLedgersOwnNumbers() throws {
        let project = try ProjectLoader.load(root: v6)
        // DW-1 and DW-2; the quoted example's DW-999 is not an entry, and the
        // legacy bullets are entries without numbers.
        #expect(project.deferredWork.filter { $0.label.hasPrefix("DW-") }.map(\.label) == ["DW-1", "DW-2"])
        #expect(WorkItemEdits.nextLedgerNumber(project) == 3)
    }

    @Test func aNewEntryAppendsToTheLedgersEnd() throws {
        let (root, project) = try copiedProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try #require(project.deferredWorkFile)
        let lines = try #require(WorkItemEdits.read(url))
        let edits = try WorkItemEdits.ledgerAppend(title: "The sweep's second pass", severity: "medium", owner: "Dana",
                                                   detail: "Rows with no issuer key", to: url,
                                                   number: WorkItemEdits.nextLedgerNumber(project), date: "2026-11-02").get()
        let edit = try #require(edits.first)
        #expect(edit.line == lines.count)
        #expect(edit.before == lines.last)
        try ReviewCompletion.apply(edits)

        let reread = try ProjectLoader.load(root: root)
        #expect(reread.deferredWork.count == project.deferredWork.count + 1)
        let added = try #require(reread.deferredWork.last)
        #expect(added.label == "DW-3")
        #expect(added.title == "The sweep's second pass")
        #expect(added.status.raw == "open")
        #expect(added.severity == "medium")
        #expect(added.owner == "Dana")
        #expect(added.value("created") == "2026-11-02")
        #expect(added.value("detail") == "Rows with no issuer key")
        // The example at the top and the legacy bullets still read as before.
        #expect(reread.deferredWork.first?.label == "DW-1")
        #expect(reread.deferredWork.map(\.title).contains("Fixed one."))
    }

    @Test func anEmptyTitleAndAMissingLedgerAreBothRefused() throws {
        let project = try ProjectLoader.load(root: v6)
        #expect(WorkItemEdits.ledgerAppend(title: "  \n ", severity: nil, owner: nil, detail: nil,
                                           to: project.deferredWorkFile, number: 3) == .failure(.nothingToRecord))
        #expect(WorkItemEdits.ledgerAppend(title: "Somewhere else", severity: nil, owner: nil, detail: nil,
                                           to: nil, number: 1) == .failure(.noLedger))
    }

    @Test func aTitleWrittenOnSeveralLinesBecomesOneHeading() throws {
        let (root, project) = try copiedProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try #require(project.deferredWorkFile)
        let edits = try WorkItemEdits.ledgerAppend(title: "A heading\nthat was pasted", severity: "high", owner: nil,
                                                   detail: nil, to: url, number: 3).get()
        try ReviewCompletion.apply(edits)
        let added = try #require(try ProjectLoader.load(root: root).deferredWork.last)
        #expect(added.label == "DW-3")
        #expect(added.title == "A heading that was pasted")
        #expect(added.severity == "high")
    }

    // MARK: The lines have to be the ones on disk

    @Test func aLineChangedSinceItWasReadStopsTheWrite() throws {
        let (root, project) = try copiedProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let owed = try #require(project.retroActions.first { $0.label == "152" })
        let edits = try WorkItemEdits.retroActionRecord(owed, in: project, progress: "Written elsewhere first",
                                                        resolution: nil).get()
        let url = try #require(project.sources.statusFile)
        let text = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: #"progress: "Story 9.16 drafted""#, with: #"progress: "Someone else got there""#)
        try text.write(to: url, atomically: true, encoding: .utf8)

        #expect(throws: (any Error).self) { try ReviewCompletion.apply(edits) }
        #expect(try ProjectLoader.load(root: root).retroActions.first { $0.label == "152" }?.value("progress")
            == "Someone else got there")
    }
}
