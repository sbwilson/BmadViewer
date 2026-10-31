import Foundation
import Testing
@testable import BmadKit

@Suite struct ReleaseNotesTests {
    /// v0.10 must sort above v0.9 by number, the draft must drop out, and the
    /// pre-release keeps its place below both.
    static let apiJSON = """
    [
      {"id": 3, "tag_name": "v0.9", "name": "Charts", "body": "Burn-up added.",
       "html_url": "https://github.com/sbwilson/BmadViewer/releases/tag/v0.9",
       "published_at": "2026-10-20T09:00:00Z", "draft": false, "prerelease": false},
      {"id": 1, "tag_name": "v0.10", "name": null, "body": null,
       "html_url": "https://github.com/sbwilson/BmadViewer/releases/tag/v0.10",
       "published_at": "2026-10-21T09:00:00Z", "draft": false, "prerelease": false},
      {"id": 2, "tag_name": "v0.9.1", "name": "Still writing", "body": null,
       "html_url": "https://github.com/sbwilson/BmadViewer/releases/tag/v0.9.1",
       "published_at": "2026-10-25T09:00:00Z", "draft": true, "prerelease": false},
      {"id": 4, "tag_name": "v0.2-rc1", "name": "Second look preview", "body": "Preview.",
       "html_url": "https://github.com/sbwilson/BmadViewer/releases/tag/v0.2-rc1",
       "published_at": "2026-10-02T09:00:00Z", "draft": false, "prerelease": true}
    ]
    """

    @Test func decodesOrdersAndDropsDrafts() throws {
        let releases = try ReleaseNotes.releases(from: Data(Self.apiJSON.utf8))
        #expect(releases.map(\.tagName) == ["v0.10", "v0.9", "v0.2-rc1"])
        #expect(releases[0].title == "v0.10")  // name null, so the tag stands in
        #expect(releases[1].title == "Charts")
        #expect(releases[1].body == "Burn-up added.")
        #expect(releases[1].htmlURL.path.hasSuffix("/tag/v0.9"))
        let iso = ISO8601DateFormatter()
        #expect(releases[1].publishedAt == iso.date(from: "2026-10-20T09:00:00Z"))
        #expect(releases[2].prerelease)
    }

    @Test func versionsParseTagsAndBuildStrings() {
        #expect(ReleaseNotes.version("v0.1") == [0, 1])
        #expect(ReleaseNotes.version("0.10") == [0, 10])
        #expect(ReleaseNotes.version("v0.1-5-gabc1234") == [0, 1])  // git describe
        #expect(ReleaseNotes.version("0.2-rc1") == [0, 2])
        #expect(ReleaseNotes.version("v1") == [1])
        #expect(ReleaseNotes.version("") == nil)
        #expect(ReleaseNotes.version("nightly") == nil)
        #expect(ReleaseNotes.compare([0, 2], [0, 1, 9]) > 0)
        #expect(ReleaseNotes.compare([1], [1, 0]) == 0)
    }

    @Test func notesMarkdownMarksReleasesAgainstTheRunningBuild() throws {
        let releases = try ReleaseNotes.releases(from: Data(Self.apiJSON.utf8))
        let sections = ReleaseNotes.notesMarkdown(releases, currentVersion: "0.9")
            .components(separatedBy: "\n\n---\n\n")
        #expect(sections.count == 3)
        #expect(sections.map { $0.hasPrefix("## ") } == [true, true, true])
        // Newest first: v0.10 is newer than the running 0.9; v0.9 is this version.
        #expect(sections[0].hasPrefix("## v0.10"))
        #expect(sections[0].contains("Published 21 Oct 2026 · newer than this build"))
        #expect(sections[1].contains("## Charts"))
        #expect(sections[1].contains("this version"))
        #expect(!sections[1].contains("newer than this build"))
        #expect(sections[2].contains("pre-release"))
        // With no version to compare against, nothing is marked.
        #expect(!ReleaseNotes.notesMarkdown(releases, currentVersion: nil).contains("this version"))
        #expect(!ReleaseNotes.notesMarkdown(releases, currentVersion: nil).contains("newer than"))
    }
}
