import Foundation
import Testing
@testable import BmadKit

@Suite struct LineRefTests {
    @Test(arguments: [
        ("a.rs:42", "a.rs", LineRange(42)),
        ("a.rs:42:7", "a.rs", LineRange(42)),
        ("a.rs:42-50", "a.rs", LineRange(42, 50)),
        ("crates/x/src/lib.rs:1670-1673", "crates/x/src/lib.rs", LineRange(1670, 1673)),
        ("a.md#L3", "a.md", LineRange(3)),
        ("a.md#L3-L9", "a.md", LineRange(3, 9)),
    ])
    func splitsAPathFromItsLines(raw: String, path: String, lines: LineRange) {
        let (p, l) = LineRef.split(raw)
        #expect(p == path)
        #expect(l == lines)
    }

    @Test func aPathWithoutLinesComesBackWhole() {
        #expect(LineRef.split("docs/a.md").lines == nil)
        #expect(LineRef.split("docs/a.md").path == "docs/a.md")
    }

    @Test func linesRoundTripThroughAURLFragment() {
        let url = URL(filePath: "/tmp/some file.rs").withLines(LineRange(10, 12))
        #expect(url.fragment == "L10-L12")
        #expect(url.lineRange == LineRange(10, 12))
        #expect(url.withoutFragment.path(percentEncoded: false) == "/tmp/some file.rs")
        #expect(url.withoutFragment.fragment == nil)
    }

    @Test func aRangeIsNeverBackwards() {
        #expect(LineRange(9, 3) == LineRange(9, 9))
        #expect(LineRange(0).lower == 1)
    }
}

@Suite struct SyntaxTests {
    func kinds(_ text: String, _ file: String) -> [String: Syntax.Token] {
        let ns = text as NSString
        var out: [String: Syntax.Token] = [:]
        for t in Syntax.tokens(text, Syntax.language(for: URL(filePath: file))) { out[ns.substring(with: t.range)] = t.token }
        return out
    }

    @Test func aQuoteInsideACommentIsNotAString() {
        let k = kinds("let a = \"x\" // it's \"fine\"\nfn", "a.rs")
        #expect(k["let"] == .keyword)
        #expect(k["\"x\""] == .string)
        #expect(k["// it's \"fine\""] == .comment)
        #expect(k["fn"] == .keyword)
    }

    @Test func tomlKeysAndTableHeaders() {
        let k = kinds("[[entry]]\nid = 1\ntitle = \"Web\"\nhitl = false", "tickets.toml")
        #expect(k["[[entry]]"] == .heading)
        #expect(k["id"] == .key)
        #expect(k["\"Web\""] == .string)
        #expect(k["false"] == .keyword)
        #expect(k["1"] == .number)
    }

    @Test func markdownHeadingsAndCode() {
        let k = kinds("# Title\n\nSome `code` here.", "a.md")
        #expect(k["# Title"] == .heading)
        #expect(k["`code`"] == .string)
    }

    @Test func plainTextHasNoTokens() {
        #expect(Syntax.tokens("hello 42 \"x\"", Syntax.language(for: URL(filePath: "notes.txt"))).count == 1) // the number
    }
}

@Suite struct TicketsFileTests {
    @Test func readsAnEpicsEntriesAndAnInitiativesEpics() throws {
        let root = Bundle.module.url(forResource: "Fixtures/ticket-tree", withExtension: nil)!
        let epic = try TicketsFile.load(root.appending(path: "_bmad-output/initiative-money/epic-workspace/tickets.toml"))
        #expect(epic.entries.map(\.id) == [1, 2, 3, 4])
        #expect(epic.entries[1].after == ["1", "2.1"])
        #expect(epic.entries[2].type == "spike")
        #expect(epic.entries[2].refine)
        let initiative = try TicketsFile.load(root.appending(path: "_bmad-output/initiative-money/tickets.toml"))
        #expect(initiative.epics.map(\.slug) == ["epic-ledger-core", "epic-workspace", "epic-budgets"])
        #expect(initiative.epics[2].after.map(\.epic) == ["12", "epic-ledger-core"])
        #expect(initiative.epics[1].after.first?.needs == "the ledger modules")
    }
}
