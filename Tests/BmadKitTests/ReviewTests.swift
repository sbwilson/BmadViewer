import Foundation
import Testing
@testable import BmadKit

private let fixture = Bundle.module.url(forResource: "Fixtures/qubric-shaped", withExtension: nil)!

@Suite struct ReviewOrderTests {
    let review: ReviewOrder

    init() throws {
        let project = try ProjectLoader.load(root: fixture)
        review = try #require(project.story(number: "9.15")?.review)
    }

    @Test func concernsAreBoldLinesOrSubheadings() {
        #expect(review.groups.map(\.title) == ["The domain type — a second constructor", "Peripherals"])
        #expect(review.groups.map { $0.stops.count } == [2, 2])
    }

    @Test func aStopsFramingAndItsLinkOnTheNextLine() throws {
        let first = try #require(review.stops.first)
        #expect(first.framing == "The entry point: mirrors `create`'s branch.")
        #expect(first.label == "endpoint.rs:2")
        #expect(first.url?.path(percentEncoded: false).hasSuffix("/qubric-shaped/crates/foundation/src/endpoint.rs") == true)
        #expect(first.lines == LineRange(2))
        #expect(review.stops[1].lines == LineRange(1, 3))
    }

    @Test func aLinkOnTheBulletsOwnLineAndAStopWithoutOne() {
        #expect(review.stops[2].framing == "Same-line link")
        #expect(review.stops[2].lines == LineRange(3))
        #expect(review.stops[3].url == nil)
        #expect(review.stops[3].framing == "A stop with no link at all.")
    }

    @Test func aLinkToAMovedFileFindsItUnderFewerFolders() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "bmadviewer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "crates/qb/src"), withIntermediateDirectories: true)
        try "x".write(to: root.appending(path: "crates/qb/src/lib.rs"), atomically: true, encoding: .utf8)
        let found = ReviewOrder.relocate(root.appending(path: "RustCore/crates/qb/src/lib.rs"), projectRoot: root)
        #expect(found.url.path(percentEncoded: false).hasSuffix("/crates/qb/src/lib.rs"))
        #expect(found.movedFrom == "RustCore/crates/qb/src/lib.rs")
        let gone = ReviewOrder.relocate(root.appending(path: "Packages/Gone/Package.swift"), projectRoot: root)
        #expect(gone.movedFrom == nil)
    }

    @Test func fencedExamplesAndLaterSectionsAreNotStops() {
        #expect(!review.stops.contains { $0.framing.contains("not a stop") || $0.framing.contains("Not part") })
        #expect(review.stops.map(\.id) == [0, 1, 2, 3])
    }

    @Test func aDocumentWithoutTheSectionHasNoReview() throws {
        let project = try ProjectLoader.load(root: fixture)
        #expect(project.story(number: "1.1")?.review == nil)
    }
}

@Suite struct ReviewCompletionTests {
    @Test func plansTheSprintStatusAndFrontMatterEdits() throws {
        let project = try ProjectLoader.load(root: fixture)
        let story = try #require(project.story(number: "9.15"))
        let edits = try ReviewCompletion.edits(for: story, in: project).get()
        #expect(edits.map(\.after) == [
            "  9-15-a-story-left-in-review: done   # keep this comment",
            "status: 'done' # draft | ready-for-dev | in-progress | in-review | done",
        ])
        #expect(edits.map { $0.url.lastPathComponent } == ["sprint-status.yaml", "spec-9-15-a-story-left-in-review.md"])
    }

    @Test func appliesThemAndTheStoryReadsDone() throws {
        let copy = FileManager.default.temporaryDirectory.appending(path: "bmadviewer-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: fixture, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        var project = try ProjectLoader.load(root: copy)
        try ReviewCompletion.apply(try ReviewCompletion.edits(for: try #require(project.story(number: "9.15")), in: project).get())
        project = try ProjectLoader.load(root: copy)
        let story = try #require(project.story(number: "9.15"))
        #expect(story.status.raw == "done")
        #expect(story.frontMatter["status"] == "done")
        let yaml = try String(contentsOf: copy.appending(path: "docs/bmad/implementation-artifacts/sprint-status.yaml"), encoding: .utf8)
        #expect(yaml.contains("9-15-a-story-left-in-review: done   # keep this comment"))
        #expect(yaml.contains("# Header comment, as Qubric keeps one."))
    }

    @Test func refusesAQueuedStoryADoneOneAndOneNotInReview() throws {
        var project = try ProjectLoader.load(root: fixture)
        // 9.17 is row 2 of the queue: put it in review to reach the queue check.
        if let e = project.epics.firstIndex(where: { $0.id == "9" }), let s = project.epics[e].stories.firstIndex(where: { $0.number == "9.17" }) {
            project.epics[e].stories[s].status = Status("review")
        }
        let queued = try #require(project.story(number: "9.17"))
        #expect(ReviewCompletion.edits(for: queued, in: project) == .failure(.queued(section: "Increment 11 — epic S5-9", position: "2")))
        #expect(ReviewCompletion.edits(for: try #require(project.story(number: "1.1")), in: project) == .failure(.alreadyDone))
        #expect(ReviewCompletion.edits(for: try #require(project.story(number: "9.16")), in: project) == .failure(.notAwaitingReview("ready-for-dev")))
    }

    @Test func refusesWhenTheLineChangedSinceItWasRead() throws {
        let copy = FileManager.default.temporaryDirectory.appending(path: "bmadviewer-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: fixture, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        let project = try ProjectLoader.load(root: copy)
        let edits = try ReviewCompletion.edits(for: try #require(project.story(number: "9.15")), in: project).get()
        let spec = copy.appending(path: "docs/bmad/implementation-artifacts/spec-9-15-a-story-left-in-review.md")
        let text = try String(contentsOf: spec, encoding: .utf8).replacingOccurrences(of: "'in-review'", with: "'in-progress'")
        try text.write(to: spec, atomically: true, encoding: .utf8)
        #expect(throws: ReviewCompletion.ApplyFailure.self) { try ReviewCompletion.apply(edits) }
        let yaml = try String(contentsOf: copy.appending(path: "docs/bmad/implementation-artifacts/sprint-status.yaml"), encoding: .utf8)
        #expect(yaml.contains("9-15-a-story-left-in-review: review")) // nothing written
    }
}
