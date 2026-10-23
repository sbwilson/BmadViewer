import Foundation
import Testing
@testable import BmadKit

private let fixture = Bundle.module.url(forResource: "Fixtures/qubric-shaped", withExtension: nil)!

@Suite struct ProjectLoaderTests {
    let project: Project

    init() throws {
        project = try ProjectLoader.load(root: fixture)
    }

    @Test func readsTheLiveStatusFileNotTheArchivedCopy() {
        #expect(project.name == "Fixture")
        #expect(project.layout == .sprintStatus)
        #expect(project.sources.statusFile?.path().contains("/archive/") == false)
        #expect(project.story(id: "1-1-stale-archived") == nil)
    }

    @Test func groupsStoriesUnderEpicsInFileOrder() {
        #expect(project.epics.map(\.id) == ["1", "9", "2"])
        #expect(project.epics[1].stories.map(\.number) == ["9.15", "9.16", "9.17"])
        #expect(project.epics[0].retrospective?.raw == "done")
        #expect(project.epics[1].status.kind == .inProgress)
    }

    @Test func epicTitlesComeFromEpicsMdDespiteTheSprintPrefix() {
        #expect(project.epics[0].title == "Workspace & the evidence chain")
        #expect(project.epics[1].title == "Instrument binding & the quick-check")
        // Epic 2 appears only through a story key, and epics.md has no heading for it.
        #expect(project.epics[2].title == "Epic 2")
    }

    @Test func storyTitlePrefersEpicsMdThenFrontMatterThenSlug() throws {
        #expect(try #require(project.story(number: "1.1")).title == "The qb:: crate topology")
        #expect(try #require(project.story(number: "9.17")).title == "Something later")
    }

    @Test func truncatedKeysStillFindTheirStoryFile() throws {
        let s = try #require(project.story(number: "1.2"))
        #expect(s.documentURL?.lastPathComponent == "spec-1-2-a-key-truncated-at-sixty-characters-like-the-diagnostics-split.md")
        #expect(s.frontMatter["status"] == "review")
        #expect(try #require(project.story(number: "9.16")).documentURL == nil)
    }

    @Test func epicsExcerptRunsToTheNextHeadingOfLevelThreeOrAbove() throws {
        let excerpt = try #require(project.story(number: "9.16")?.epicsExcerpt)
        #expect(excerpt.hasPrefix("### Story 9.16"))
        #expect(excerpt.contains("Still 9.16."))
        #expect(!excerpt.contains("Final notes"))
    }

    @Test func frontMatterArraysAreFlattened() throws {
        #expect(try #require(project.story(number: "1.1")).frontMatter["context"] == "a.md, b.md")
    }

    @Test func statusKinds() {
        #expect(Status("ready-for-dev").isActive)
        #expect(Status("review").isActive)
        #expect(Status("superseded").isTerminal)
        #expect(!Status("optional").isTerminal)
        #expect(Status("whatever").kind == .other)
    }

    @Test func unrecognisedKeysAndUnknownQueuedStoriesAreWarnings() {
        #expect(project.warnings.contains { $0.contains("weird_key") })
        #expect(project.warnings.contains { $0.contains("7.7") })
    }
}

@Suite struct BuildOrderTests {
    @Test func readsQueueTablesAndKeepsDrainedSections() throws {
        let text = try String(contentsOf: fixture.appending(path: "docs/bmad/planning-artifacts/build-order.md"), encoding: .utf8)
        let sections = BuildOrder.parse(text)
        #expect(sections.map(\.heading) == ["Increment 11 — epic S5-9", "Increment 10 — drained"])
        let first = sections[0].entries
        #expect(first.map(\.storyNumber) == ["9.16", "9.17", "7.7"])
        #expect(first[0].waitsOn.isEmpty)
        #expect(first[1].waitsOn == ["9.16", "9.15"])
        #expect(first[1].reason.contains("`a|b`"))
        #expect(sections[1].entries.isEmpty)
    }
}

@Suite struct ConfigResolverTests {
    @Test func expandsProjectRoot() {
        let paths = ConfigResolver.resolve(root: fixture)
        #expect(paths.planning?.lastPathComponent == "planning-artifacts")
        #expect(paths.implementation?.lastPathComponent == "implementation-artifacts")
    }

    @Test func tomlAssignmentsIgnoreCommentsAndNonStrings() {
        let pairs = ConfigResolver.tomlAssignments("""
        # a = "no"
        a = "yes" # trailing
        b = true
        """)
        #expect(pairs.map(\.0) == ["a"])
        #expect(pairs.first?.1 == "yes")
    }
}
