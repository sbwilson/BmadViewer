import Foundation
import Testing
@testable import BmadKit

private let fixture = Bundle.module.url(forResource: "Fixtures/qubric-shaped", withExtension: nil)!

@Suite struct TextSearchTests {
    /// The fixture copied into a git repository, with one file ignored.
    func repo() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "bmadviewer-fts-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: fixture, to: root)
        try "ignored.md\n".write(to: root.appending(path: ".gitignore"), atomically: true, encoding: .utf8)
        try "DW-1 is mentioned here too\n".write(to: root.appending(path: "ignored.md"), atomically: true, encoding: .utf8)
        _ = try GitDiff.git(["init", "-q"], in: root)
        return root
    }

    @Test func findsEveryFileThatMentionsAKeyAndSkipsIgnoredOnes() throws {
        let root = try repo()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectLoader.load(root: root)
        let out = try TextSearch.run("DW-1", options: .init(wholeWord: true, scope: .project), root: root, folders: TextSearch.artifactFolders(project))
        #expect(out.files.map(\.path) == ["docs/bmad/implementation-artifacts/deferred-work.md"])
        let match = try #require(out.files.first?.matches.first)
        #expect(match.line == 11)
        #expect((match.preview as NSString).substring(with: match.ranges[0]) == "DW-1")
    }

    @Test func caseAndRegexOptions() throws {
        let root = try repo()
        defer { try? FileManager.default.removeItem(at: root) }
        let folders = [root.appending(path: "docs/bmad")]
        let insensitive = try TextSearch.run("issuer-qualify", options: .init(), root: root, folders: folders)
        #expect(insensitive.matchCount == 1)
        let sensitive = try TextSearch.run("issuer-qualify", options: .init(caseSensitive: true), root: root, folders: folders)
        #expect(sensitive.matchCount == 0)
        let regex = try TextSearch.run("DW-[0-9]+:", options: .init(regex: true), root: root, folders: folders)
        #expect(regex.files.first?.matches.map(\.line) == [6, 11, 24]) // the fenced example on line 6 is text too
        #expect(throws: TextSearch.Failure.self) { try TextSearch.run("x{", options: .init(regex: true), root: root, folders: folders) }
    }

    @Test func artifactsScopeStaysInTheBmadFolders() throws {
        let root = try repo()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectLoader.load(root: root)
        let folders = TextSearch.artifactFolders(project)
        #expect(folders.map { $0.lastPathComponent }.sorted() == ["implementation-artifacts", "planning-artifacts"])
        let out = try TextSearch.run("line 2", options: .init(), root: root, folders: folders)
        #expect(out.matchCount == 0) // crates/foundation/src/endpoint.rs is outside the artifacts
        let whole = try TextSearch.run("line 2", options: .init(scope: .project), root: root, folders: folders)
        #expect(whole.files.map(\.path) == ["crates/foundation/src/endpoint.rs"])
    }

    @Test func theMatchLimitTruncates() throws {
        let root = try repo()
        defer { try? FileManager.default.removeItem(at: root) }
        let out = try TextSearch.run("e", options: .init(scope: .project), root: root, folders: [], limit: 5)
        #expect(out.truncated)
        #expect(out.matchCount <= 5)
    }

    @Test func outsideGitTheWalkFindsTheSameThing() throws {
        // A copy outside any repository (the fixture itself sits inside this one, ignored).
        let root = FileManager.default.temporaryDirectory.appending(path: "bmadviewer-fts-walk-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: fixture, to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let out = try TextSearch.run("Issuer-qualify", options: .init(), root: root, folders: [root.appending(path: "docs/bmad")])
        #expect(out.files.map(\.path) == ["docs/bmad/implementation-artifacts/deferred-work.md"])
    }

    @Test func regexEscapesGitCannotReadStillWork() throws {
        let root = try repo()
        defer { try? FileManager.default.removeItem(at: root) }
        // `9.16` and the key spelling `9-16-…`, but not `19.16` or `9.161`.
        let out = try TextSearch.run(#"\b9[.-]16\b"#, options: .init(regex: true, scope: .project), root: root, folders: [])
        let hits = out.files.flatMap { f in f.matches.map { (f.path as NSString).lastPathComponent + ":\($0.line)" } }
        #expect(hits.contains { $0.hasPrefix("sprint-status.yaml") })
        #expect(hits.contains { $0.hasPrefix("build-order.md") })
        #expect(TextSearch.posix(#"\bDW-\d+\s\w"#) == "DW-[0-9]+[[:space:]][[:alnum:]_]")
    }

    @Test func longLinesAreWindowedAroundTheMatch() {
        let text = String(repeating: "x", count: 300) + "NEEDLE" + String(repeating: "y", count: 600)
        let (preview, ranges) = TextSearch.window(text, ranges: [NSRange(location: 300, length: 6)])
        #expect(preview.hasPrefix("…"))
        #expect(preview.hasSuffix("…"))
        #expect((preview as NSString).substring(with: ranges[0]) == "NEEDLE")
    }
}
