import Foundation
import Testing
@testable import BmadKit

private let v6 = Bundle.module.url(forResource: "Fixtures/v6app-shaped", withExtension: nil)!
private let v7 = Bundle.module.url(forResource: "Fixtures/ticket-tree", withExtension: nil)!
private let v7current = Bundle.module.url(forResource: "Fixtures/ticket-tree-v7", withExtension: nil)!

/// The line that hands a ready story to `bmad-build`, in the shape upstream's
/// dispatcher takes: a tree ticket by ref, a sprint-status story by its spec file.
@Suite struct RunCommandTests {
    let v6project: Project
    let v7project: Project
    let current: Project

    init() throws {
        v6project = try ProjectLoader.load(root: v6)
        v7project = try ProjectLoader.load(root: v7)
        current = try ProjectLoader.load(root: v7current)
    }

    // MARK: Sprint-status projects

    @Test func aSprintStatusStoryIsNamedByItsSpecFile() throws {
        let story = try #require(v6project.story(number: "9.15"))
        #expect(RunCommand.command(for: story, in: v6project) ==
            "/bmad-build docs/bmad/implementation-artifacts/spec-9-15-a-story-left-in-review.md")
    }

    @Test func theAutoVariantsSaysSoAndKeepsTheSameArgument() throws {
        let story = try #require(v6project.story(number: "9.15"))
        #expect(RunCommand.command(for: story, in: v6project, auto: true) ==
            "/bmad-build-auto docs/bmad/implementation-artifacts/spec-9-15-a-story-left-in-review.md")
    }

    @Test func aStoryWithoutAFileHasNothingForBuildToOpen() throws {
        // 9.16 is ready-for-dev in sprint-status.yaml with no spec file written yet.
        let story = try #require(v6project.story(number: "9.16"))
        #expect(story.status.raw == "ready-for-dev")
        #expect(RunCommand.command(for: story, in: v6project) == nil)
    }

    @Test func finishedAndDroppedStoriesAreNotBuildsToStart() throws {
        for number in ["1.1", "2.10"] {
            let story = try #require(v6project.story(number: number))
            #expect(RunCommand.command(for: story, in: v6project) == nil, "story \(number) is \(story.status.raw)")
        }
    }

    // MARK: Ticket trees

    @Test func aTreeTicketIsNamedByItsRef() throws {
        let started = try #require(v7project.story(number: "12.1"))
        #expect(started.waitsOn.isEmpty)
        #expect(RunCommand.command(for: started, in: v7project) == "/bmad-build ticket 12.1")
        // Built still counts as Build's to finish.
        #expect(RunCommand.command(for: try #require(v7project.story(number: "2.2")), in: v7project) == "/bmad-build ticket 2.2")
    }

    @Test func waitingAndBlockedTicketsAreNotOffered() throws {
        for number in ["12.2", "12.4", "2.1"] {
            let story = try #require(v7project.story(number: number))
            #expect(RunCommand.command(for: story, in: v7project) == nil, "story \(number) is \(story.status.raw)")
        }
    }

    @Test func aBacklogTicketHasNoRefSoItsFileIsNamed() throws {
        let spike = try #require(v7project.story(number: "B.spike-drill-stall"))
        #expect(RunCommand.command(for: spike, in: v7project) == "/bmad-build ticket _bmad-output/backlog/spike-drill-stall.md")
        #expect(RunCommand.command(for: spike, in: v7project, auto: true) ==
            "/bmad-build-auto ticket _bmad-output/backlog/spike-drill-stall.md")
    }

    @Test func theCurrentLayoutNumbersTheSameWay() throws {
        // The newer tree keeps tickets under `tickets/`; the ref is still `<epic>.<entry>`.
        #expect(RunCommand.command(for: try #require(current.story(number: "2.2")), in: current) == "/bmad-build ticket 2.2")
        #expect(RunCommand.command(for: try #require(current.story(number: "12.1")), in: current) == nil)  // waits on 2.2
        #expect(RunCommand.command(for: try #require(current.story(number: "12.b1")), in: current) == nil)
    }

    @Test func aPathWithSpacesIsQuoted() {
        let root = v6project.root
        let spaced = root.appending(path: "docs/bmad/implementation-artifacts/spec-1-1 some story.md")
        #expect(RunCommand.relative(spaced, in: v6project) == "\"docs/bmad/implementation-artifacts/spec-1-1 some story.md\"")
        let plain = root.appending(path: "docs/bmad/implementation-artifacts/spec-1-1-the-first-story.md")
        #expect(RunCommand.relative(plain, in: v6project) == "docs/bmad/implementation-artifacts/spec-1-1-the-first-story.md")
    }
}
