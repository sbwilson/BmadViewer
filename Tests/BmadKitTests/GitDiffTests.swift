import Foundation
import Testing
@testable import BmadKit

/// A throwaway repository: a baseline commit, the story's commit (which also
/// touches its spec), then an unrelated later commit.
private final class Repo {
    let root: URL
    var baseline = ""
    var storyCommit = ""

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "bmadviewer-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "src"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "docs"), withIntermediateDirectories: true)
        try git("init", "-q", "-b", "main")
        try git("config", "user.email", "t@example.com")
        try git("config", "user.name", "Test")
        try git("config", "commit.gpgsign", "false")
        try write("src/a.rs", (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n")
        try write("src/old.rs", "fn moved() {}\nfn kept() {}\n")
        try write("docs/spec.md", "---\nstatus: 'in-review'\n---\n")
        try git("add", "-A"); try git("commit", "-qm", "baseline")
        baseline = try git("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)

        var lines = (1...20).map { "line \($0)" }
        lines[9] = "line 10 changed"
        lines.insert("inserted after 15", at: 15)
        try write("src/a.rs", lines.joined(separator: "\n") + "\n")
        try git("mv", "src/old.rs", "src/new.rs")
        try write("src/added.rs", "fn added() {}\n")
        try write("docs/spec.md", "---\nstatus: 'done'\n---\n")
        try git("add", "-A"); try git("commit", "-qm", "story")
        storyCommit = try git("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)

        try write("src/later.rs", "fn later() {}\n")
        try git("add", "-A"); try git("commit", "-qm", "later")
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult func git(_ args: String...) throws -> String { try GitDiff.git(args, in: root) }

    func write(_ path: String, _ text: String) throws {
        try text.write(to: root.appending(path: path), atomically: true, encoding: .utf8)
    }
}

@Suite struct GitDiffTests {
    @Test func theStoryRangeEndsAtTheLastCommitToTouchTheDocument() throws {
        let repo = try Repo()
        let range = try GitDiff.range(baseline: String(repo.baseline.prefix(8)), end: .story,
                                      document: repo.root.appending(path: "docs/spec.md"), projectRoot: repo.root)
        #expect(range.base == repo.baseline)
        #expect(range.end == repo.storyCommit)
        let files = try GitDiff.changedFiles(in: range)
        #expect(files.map(\.path).sorted() == ["docs/spec.md", "src/a.rs", "src/added.rs", "src/new.rs"])
        let renamed = try #require(files.first { $0.path == "src/new.rs" })
        #expect(renamed.status == "R")
        #expect(renamed.oldPath == "src/old.rs")
        let a = try #require(files.first { $0.path == "src/a.rs" })
        #expect(a.additions == 2)
        #expect(a.deletions == 1)
    }

    @Test func headIncludesLaterWorkAndAnUncommittedDocumentMeansTheWorkingTree() throws {
        let repo = try Repo()
        let head = try GitDiff.range(baseline: repo.baseline, end: .head, document: nil, projectRoot: repo.root)
        #expect(try GitDiff.changedFiles(in: head).contains { $0.path == "src/later.rs" })
        try repo.write("docs/spec.md", "---\nstatus: 'edited'\n---\n")
        let story = try GitDiff.range(baseline: repo.baseline, end: .story, document: repo.root.appending(path: "docs/spec.md"), projectRoot: repo.root)
        #expect(story.end == nil)
        #expect(story.label.hasSuffix("working tree"))
    }

    @Test func aFilesDiffNumbersBothSides() throws {
        let repo = try Repo()
        let range = try GitDiff.range(baseline: repo.baseline, end: .story, document: repo.root.appending(path: "docs/spec.md"), projectRoot: repo.root)
        let diff = try GitDiff.diff(range, path: "src/a.rs", context: 1)
        #expect(diff.hunks.count == 2)
        let changed = diff.hunks.flatMap(\.lines).filter { $0.kind != .context }
        #expect(changed.map(\.kind) == [.removed, .added, .added])
        #expect(changed[0].old == 10)
        #expect(changed[1].new == 10)
        #expect(changed[2].new == 16)
        #expect(diff.shows(LineRange(16)))
        #expect(!diff.shows(LineRange(3)))
        let whole = try GitDiff.diff(range, path: "src/a.rs", context: nil)
        #expect(whole.shows(LineRange(1, 21)))
    }

    @Test func aRenameDiffsAgainstTheOldPath() throws {
        let repo = try Repo()
        let range = try GitDiff.range(baseline: repo.baseline, end: .story, document: repo.root.appending(path: "docs/spec.md"), projectRoot: repo.root)
        let diff = try GitDiff.diff(range, path: "src/new.rs", oldPath: "src/old.rs")
        #expect(diff.isEmpty) // a pure rename changes no lines
        let added = try GitDiff.diff(range, path: "src/added.rs")
        #expect(added.hunks.first?.lines.map(\.kind) == [.added])
    }

    @Test func anUnknownBaselineIsNamed() throws {
        let repo = try Repo()
        #expect(throws: GitDiff.Failure.unknownCommit("deadbeefdeadbeef")) {
            try GitDiff.range(baseline: "deadbeefdeadbeef", end: .head, document: nil, projectRoot: repo.root)
        }
    }

    @Test func parsesNoNewlineMarkersAndBinaryFiles() {
        let text = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@ fn\n-a\n\\ No newline at end of file\n+b\n"
        let diff = GitDiff.parse(text)
        #expect(diff.hunks.first?.header == "fn")
        #expect(diff.hunks.first?.lines.map(\.kind) == [.removed, .note, .added])
        #expect(GitDiff.parse("diff --git a/i.png b/i.png\nBinary files a/i.png and b/i.png differ\n").isBinary)
    }
}
