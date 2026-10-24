import Foundation
import Testing
@testable import BmadKit

private let v6 = Bundle.module.url(forResource: "Fixtures/qubric-shaped", withExtension: nil)!
private let v7 = Bundle.module.url(forResource: "Fixtures/ticket-tree", withExtension: nil)!

@Suite struct DependencyTests {
    @Test func proseTakesEveryStoryNumberInADependsOnSentence() {
        let text = "Added on Simon's ruling. Depends on 4.8's `InterruptionCauses` and `open_successor`, and on 4.14's arbiter. Queued after 4.7. Not 0.2.3 or 12.5.1."
        #expect(Dependencies.prose(text, excluding: "4.15") == ["4.8", "4.14", "4.7"])
        #expect(Dependencies.prose("Mentions 4.8 without depending on it.", excluding: "1.1").isEmpty)
    }

    @Test func ticketTreeAfterBecomesDependsOn() throws {
        let p = try ProjectLoader.load(root: v7)
        let list = try #require(p.story(number: "12.2"))
        #expect(list.dependsOn == ["epic-workspace/1"])         // the leaf file's own after: [1]
        let sweep = try #require(p.story(number: "12.4"))
        #expect(Set(sweep.dependsOn) == ["epic-workspace/2", "epic-workspace/3"])
        #expect(try #require(p.story(number: "12.1")).dependsOn == ["epic-ledger-core/2"])
    }

    @Test func sprintStatusDependenciesComeFromTheQueue() throws {
        let p = try ProjectLoader.load(root: v6)
        // build-order: 9.17 waits on 9.16 and 9.15.
        #expect(Set(try #require(p.story(number: "9.17")).dependsOn) == [
            "9-16-capture-rs-core-rs-and-root-rs-are-split-by-concern-before-e", "9-15-a-story-left-in-review",
        ])
    }

    @Test func graphLayersAndTheLongestRemainingChain() throws {
        let p = try ProjectLoader.load(root: v7)
        let g = DependencyGraph.build(p, epic: nil, hideFinished: false)
        let layer = Dictionary(g.nodes.map { ($0.number, $0.layer) }, uniquingKeysWith: { a, _ in a })
        #expect(layer["2.1"] == 0)
        #expect(layer["2.2"] == 1)
        #expect(layer["12.1"] == 2)   // after 2.2
        #expect(layer["12.4"] == 4)   // after 12.2, which is after 12.1
        // 2.1 is done, so the chain starts at the built 2.2.
        #expect(g.longestChain.compactMap { p.story(id: $0)?.number } == ["2.2", "12.1", "12.2", "12.4"])
    }

    @Test func scopingToAnEpicPullsInItsOutsidePrerequisites() throws {
        let p = try ProjectLoader.load(root: v7)
        let g = DependencyGraph.build(p, epic: "epic-workspace", hideFinished: false)
        #expect(g.nodes.filter(\.external).map(\.number) == ["2.2"])
        let hidden = DependencyGraph.build(p, epic: nil, hideFinished: true)
        #expect(!hidden.nodes.contains { $0.number == "2.1" })
    }
}

@Suite struct FollowThroughTests {
    @Test func keysAreNumbersOrActionIds() {
        #expect(FollowThroughReader.cleanKey("**#9** — *\"Fix `sprint_status.py`\"*") == "9")
        #expect(FollowThroughReader.cleanKey("6 — shared transaction helper + DW-522") == "6")
        #expect(FollowThroughReader.cleanKey("`epic-18-retro-item-134-…` (`done`)") == "epic-18-retro-item-134-")
        #expect(FollowThroughReader.cleanKey("**A11** — track every change") == "A11")
    }

    @Test func verdicts() {
        #expect(FollowThroughReader.verdict("✅ **yes**") == .landed)
        #expect(FollowThroughReader.verdict("Landed") == .landed)
        #expect(FollowThroughReader.verdict("Partly. The register row exists") == .partly)
        #expect(FollowThroughReader.verdict("**No evidence it landed.**") == .notLanded)
        #expect(FollowThroughReader.verdict("**regressed**") == .notLanded)
        #expect(FollowThroughReader.verdict("open (untracked)") == .unclear)
    }

    @Test func numberedRowsCheckThePreviousRetrosItems() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "bmadviewer-ft-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: v7, to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        // A later retrospective on the workspace epic checks the ledger-core retro's items.
        let later = root.appending(path: "_bmad-output/initiative-money/epic-workspace/epic-workspace-retrospective.md")
        try """
        ---
        date: 2026-10-20
        ---

        ## Previous-retro follow-through

        | Item | Action Text | Owner | Landed? | Evidence |
        |---|---|---|---|---|
        | **1** | Extract formatCents | dev loop | Landed | Commit `d5a8200` |
        | **3** | Monitor FTS5 | dev loop | Deferred | not yet |

        ## Action items

        1. **A later action with a long enough title:** nothing.
        """.write(to: later, atomically: true, encoding: .utf8)
        let earlier = root.appending(path: "_bmad-output/initiative-money/epic-ledger-core/epic-ledger-core-retrospective.md")
        let text = try String(contentsOf: earlier, encoding: .utf8).replacingOccurrences(of: "verdict: accepted-with-open-items", with: "date: 2026-10-10")
        try text.write(to: earlier, atomically: true, encoding: .utf8)

        let p = try ProjectLoader.load(root: root)
        let core = p.retroActions.filter { $0.source?.lastPathComponent == "epic-ledger-core-retrospective.md" }
        #expect(core.map { $0.followThrough?.verdict } == [.landed, nil, .notLanded])
        #expect(core[0].followThrough?.evidence == "Commit `d5a8200`")
        #expect(core[0].followThrough?.line == 9)
    }

    @Test func storiesThatCiteARetroItemAreLinked() throws {
        var p = try ProjectLoader.load(root: v6)
        // The fixture's epic-9 action is item 152, and story 9.16's epics.md text cites nothing yet.
        if let e = p.epics.firstIndex(where: { $0.id == "9" }), let s = p.epics[e].stories.firstIndex(where: { $0.number == "9.16" }) {
            p.epics[e].stories[s].documents.append(StoryDocument(label: "Epic definition", markdown: "Ruled at epic-10 retro items 152, 156."))
        }
        FollowThroughReader.linkStories(&p)
        #expect(p.retroActions.first { $0.label == "152" }?.linkedStories == ["9.16"])
    }
}

@Suite struct HumanRunTests {
    @Test func smokeIndexRows() {
        let index = URL(filePath: "/tmp/x/smoke-tests.md")
        let items = HumanRuns.smokeTests("""
        | Test | What it proves | Status | Blocking / qualification | Gates | Owner |
        |---|---|---|---|---|---|
        | [SMOKE-S4-06-1](smoke-tests/SMOKE-S4-06-1.md) | Forced launch works. | ✅ `pass`<br>2026-08-06 | — | Sprint-4 go/no-go. | Simon |
        | [SMOKE-S4-08-4](smoke-tests/SMOKE-S4-08-4.md) | An interrupted procedure opens. | ⬜ `not-run` | The longest steps | S4-8-4 AC9. | Dana / Simon |
        | [SMOKE-S5-02-10](smoke-tests/SMOKE-S5-02-10.md) | Never performed. | `n/a` | — | — | Simon |
        """, index: index)
        #expect(items.map(\.label) == ["SMOKE-S4-06-1", "SMOKE-S4-08-4", "SMOKE-S5-02-10"])
        #expect(items.map(\.status.isTerminal) == [true, false, true])
        #expect(items[1].owner == "Dana / Simon")
        #expect(items[1].value("blocking") == "The longest steps")
        #expect(items[0].value("status") == "pass (last run 2026-08-06)")
        #expect(items[0].line == 3)
    }

    @Test func hitlTicketsThatAreNotFinished() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "bmadviewer-hitl-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: v7, to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let toml = root.appending(path: "_bmad-output/initiative-money/epic-workspace/tickets.toml")
        let text = try String(contentsOf: toml, encoding: .utf8).replacingOccurrences(of: "title = \"Sweep\"", with: "title = \"Sweep\"\nhitl = true")
        try text.write(to: toml, atomically: true, encoding: .utf8)
        let p = try ProjectLoader.load(root: root)
        #expect(p.humanRuns.map(\.label) == ["12.4"])
        #expect(p.humanRuns.first?.linkedStories == ["12.4"])
    }
}

@Suite struct BurnupTests {
    @Test func replaysStatusLinesIncludingWrappedValues() {
        let log = """
        >>> aaa 1000
        diff --git a/s.yaml b/s.yaml
        @@ -1,0 +1,4 @@
        +development_status:
        +  epic-1: in-progress
        +  1-1-first: backlog
        +  1-2-a-very-long-key:
        +    backlog
        >>> bbb 2000
        diff --git a/s.yaml b/s.yaml
        @@ -2,3 +2,3 @@
           epic-1: in-progress
        -  1-1-first: backlog
        +  1-1-first: done
        @@ -4,2 +4,2 @@
           1-2-a-very-long-key:
        -    backlog
        -  2-1-other: backlog
        +    done
        +  2-1-other: superseded
        """
        let snaps = Burnup.replaySprintStatus(log)
        #expect(snaps.count == 2)
        #expect(snaps[0].counts(epic: "1") == Burnup.Counts(total: 2, done: 0))
        #expect(snaps[1].counts(epic: "1") == Burnup.Counts(total: 2, done: 2))
        #expect(snaps[1].counts(epic: "2").total == 0)   // superseded is out of scope
        #expect(snaps[1].date == Date(timeIntervalSince1970: 2000))
    }

    @Test func eventsAndMilestonesFromASprintStatusLog() {
        let log = """
        >>> aaa 1000
        diff --git a/s.yaml b/s.yaml
        @@ -1,0 +1,3 @@
        +development_status:
        +  1-1-first: backlog
        +  1-2-second: backlog
        >>> bbb 700000
        diff --git a/s.yaml b/s.yaml
        @@ -2,1 +2,1 @@
        -  1-1-first: backlog
        +  1-1-first: done
        @@ -4,0 +4,1 @@
        +  1-3-third: backlog
        """
        let snaps = Burnup.replaySprintStatus(log)
        #expect(snaps[0].events == [.init(storyID: "1-1-first", kind: .created("backlog")), .init(storyID: "1-2-second", kind: .created("backlog"))])
        #expect(snaps[1].events == [.init(storyID: "1-1-first", kind: .status("done")), .init(storyID: "1-3-third", kind: .created("backlog"))])
        let m = Burnup.milestones(snaps)
        #expect(m.created["1-3-third"] == Date(timeIntervalSince1970: 700000))
        #expect(m.done["1-1-first"] == Date(timeIntervalSince1970: 700000))
        #expect(m.finishedPerWeek.values.reduce(0, +) == 1)
    }

    @Test func replaysTicketTreeEntriesAndPlanStatuses() {
        let log = """
        >>> aaa 1000
        diff --git a/i/epic-x/tickets.toml b/i/epic-x/tickets.toml
        --- /dev/null
        +++ b/i/epic-x/tickets.toml
        @@ -0,0 +1,4 @@
        +[[entry]]
        +id = 1
        +[[entry]]
        +id = 2
        >>> bbb 2000
        diff --git a/i/epic-x/story-a-plan.md b/i/epic-x/story-a-plan.md
        --- /dev/null
        +++ b/i/epic-x/story-a-plan.md
        @@ -0,0 +1,3 @@
        +---
        +status: 'built'
        +---
        >>> ccc 3000
        diff --git a/i/epic-x/story-a-plan.md b/i/epic-x/story-a-plan.md
        --- a/i/epic-x/story-a-plan.md
        +++ b/i/epic-x/story-a-plan.md
        @@ -2 +2 @@
        -status: 'built'
        +status: done
        """
        let snaps = Burnup.replayTicketTree(log, epicIDs: ["epic-x"], planIDs: ["i/epic-x/story-a-plan.md": "epic-x/1"])
        #expect(snaps[0].events.map(\.storyID) == ["epic-x/1", "epic-x/2"])
        #expect(snaps[1].events == [.init(storyID: "epic-x/1", kind: .status("built"))])
        #expect(snaps[2].events == [.init(storyID: "epic-x/1", kind: .status("done"))])
        let m = Burnup.milestones(snaps)
        #expect(m.built["epic-x/1"] == Date(timeIntervalSince1970: 2000))
        #expect(m.done["epic-x/1"] == Date(timeIntervalSince1970: 3000))
        #expect(m.finishedPerWeek.values.reduce(0, +) == 1) // built then done counts once
        #expect(snaps.map { $0.counts(epic: "epic-x") } == [
            Burnup.Counts(total: 2, done: 0, built: 0),
            Burnup.Counts(total: 2, done: 0, built: 1),
            Burnup.Counts(total: 2, done: 1, built: 0),
        ])
    }
}
