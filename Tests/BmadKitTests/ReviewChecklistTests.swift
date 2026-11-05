import Foundation
import Testing
@testable import BmadKit

private let v6 = Bundle.module.url(forResource: "Fixtures/v6app-shaped", withExtension: nil)!
private let v7 = Bundle.module.url(forResource: "Fixtures/ticket-tree", withExtension: nil)!

/// What to tick before calling a review complete: the ticket's own `verify`
/// text, or the review order's stops when the entry says nothing.
@Suite struct ReviewChecklistTests {
    @Test func aTicketsVerifyTextIsTheChecklist() throws {
        let project = try ProjectLoader.load(root: v7)
        #expect(ReviewChecklist.items(for: try #require(project.story(number: "2.1"))) == ["Migrations run."])
        #expect(ReviewChecklist.items(for: try #require(project.story(number: "12.1"))) == ["Routes round-trip."])
    }

    @Test func aStoryWithNoVerifyWalksItsStops() throws {
        let project = try ProjectLoader.load(root: v6)
        let story = try #require(project.story(number: "9.15"))
        #expect(story.verify == nil)
        #expect(ReviewChecklist.items(for: story) == [
            "The entry point: mirrors `create`'s branch.",
            "The struct it edits: private fields, no setter.",
            "Same-line link",
            "A stop with no link at all.",
        ])
    }

    @Test func aStoryWithNeitherHasNothingToTick() throws {
        let project = try ProjectLoader.load(root: v6)
        #expect(ReviewChecklist.items(for: try #require(project.story(number: "1.1"))).isEmpty)
    }

    @Test func bulletsOpenItemsAndPlainLinesFoldIntoThem() {
        #expect(ReviewChecklist.split("- Migrations run\n  without a warning") == ["Migrations run without a warning"])
        #expect(ReviewChecklist.split("""
        * The list pages
        1. The total matches
        2) The export runs
        and keeps the header
        """) == ["The list pages", "The total matches", "The export runs and keeps the header"])
    }

    @Test func withNoBulletsEachLineIsItsOwnItem() {
        #expect(ReviewChecklist.split("Migrations run.") == ["Migrations run."])
        #expect(ReviewChecklist.split("Migrations run.\nNo orphan rows") == ["Migrations run.", "No orphan rows"])
        #expect(ReviewChecklist.split("   \n\n").isEmpty)
    }
}
