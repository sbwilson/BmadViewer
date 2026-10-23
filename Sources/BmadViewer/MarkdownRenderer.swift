import AppKit
import Markdown

/// Markdown → `NSAttributedString` for a TextKit 1 `NSTextView`, so links are
/// real text links (click, right-click menus, Find) and tables are `NSTextTable`s.
///
/// Links resolve against the document's folder, then the project root; inline
/// code that names an existing file (`scripts/samd/check.py`) becomes a link too,
/// and "Story 9.16" becomes a link to that story.
@MainActor
struct MarkdownRenderer {
    static let storyScheme = "bmadviewer"

    let baseURL: URL
    let projectRoot: URL
    let storyNumbers: Set<String>
    var bodySize: CGFloat = 13

    func render(_ markdown: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let document = Document(parsing: markdown)
        for child in document.children {
            block(child, into: out, context: BlockContext())
        }
        // Drop the trailing paragraph break.
        while out.string.hasSuffix("\n") { out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1)) }
        return out
    }

    // MARK: Blocks

    struct BlockContext {
        var indent: CGFloat = 0
        var quote = false
        var textBlocks: [NSTextBlock] = []
        /// Prefix for the first paragraph of a list item (bullet or number + tab).
        var listPrefix: String?
        var tight = false
    }

    private func paragraphStyle(_ ctx: BlockContext, spacingBefore: CGFloat = 0, spacingAfter: CGFloat = 8) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.15
        p.paragraphSpacingBefore = spacingBefore
        p.paragraphSpacing = ctx.tight ? 2 : spacingAfter
        p.textBlocks = ctx.textBlocks
        if ctx.listPrefix != nil {
            p.firstLineHeadIndent = ctx.indent - 18
            p.headIndent = ctx.indent
            p.tabStops = [NSTextTab(textAlignment: .left, location: ctx.indent)]
        } else {
            p.firstLineHeadIndent = ctx.indent
            p.headIndent = ctx.indent
        }
        return p
    }

    private func baseAttributes(_ ctx: BlockContext) -> InlineStyle {
        var s = InlineStyle(size: bodySize)
        if ctx.quote { s.color = .secondaryLabelColor }
        return s
    }

    private func block(_ markup: Markup, into out: NSMutableAttributedString, context ctx: BlockContext) {
        switch markup {
        case let h as Heading:
            let sizes: [CGFloat] = [22, 18, 15, 13.5, 13, 12]
            var style = baseAttributes(ctx)
            style.size = sizes[min(h.level, 6) - 1]
            style.bold = true
            let para = paragraphStyle(ctx, spacingBefore: out.length == 0 ? 0 : (h.level <= 2 ? 14 : 10), spacingAfter: 6)
            appendParagraph(inlines(h.children, style), para: para, into: out)

        case let p as Paragraph:
            var text = NSMutableAttributedString()
            if let prefix = ctx.listPrefix {
                text = NSMutableAttributedString(string: prefix, attributes: baseAttributes(ctx).attributes)
            }
            text.append(inlines(p.children, baseAttributes(ctx)))
            appendParagraph(text, para: paragraphStyle(ctx), into: out)

        case let list as UnorderedList:
            listItems(Array(list.listItems), ordered: false, start: 1, into: out, context: ctx)

        case let list as OrderedList:
            listItems(Array(list.listItems), ordered: true, start: Int(list.startIndex), into: out, context: ctx)

        case let q as BlockQuote:
            var inner = ctx
            inner.indent += 16
            inner.quote = true
            inner.listPrefix = nil
            for child in q.children { block(child, into: out, context: inner) }

        case let code as CodeBlock:
            let box = NSTextBlock()
            box.backgroundColor = .quaternarySystemFill
            box.setWidth(8, type: .absoluteValueType, for: .padding)
            box.setWidth(ctx.indent, type: .absoluteValueType, for: .margin, edge: .minX)
            box.setWidth(4, type: .absoluteValueType, for: .margin, edge: .maxY)
            var inner = ctx
            inner.textBlocks = ctx.textBlocks + [box]
            inner.indent = 0
            inner.listPrefix = nil
            let para = paragraphStyle(inner, spacingAfter: 0)
            para.lineHeightMultiple = 1.0
            var style = InlineStyle(size: bodySize - 1.5)
            style.code = true
            let text = code.code.hasSuffix("\n") ? String(code.code.dropLast()) : code.code
            appendParagraph(NSAttributedString(string: text, attributes: style.attributes), para: para, into: out)

        case let table as Markdown.Table:
            renderTable(table, into: out, context: ctx)

        case is ThematicBreak:
            let rule = NSTextBlock()
            rule.setBorderColor(.separatorColor, for: .maxY)
            rule.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
            rule.setWidth(6, type: .absoluteValueType, for: .margin, edge: .maxY)
            var inner = ctx
            inner.textBlocks = ctx.textBlocks + [rule]
            appendParagraph(NSAttributedString(string: " ", attributes: InlineStyle(size: 4).attributes),
                            para: paragraphStyle(inner, spacingAfter: 10), into: out)

        case let html as HTMLBlock:
            var style = InlineStyle(size: bodySize - 2)
            style.code = true
            style.color = .tertiaryLabelColor
            let text = html.rawHTML.trimmingCharacters(in: .whitespacesAndNewlines)
            appendParagraph(NSAttributedString(string: text, attributes: style.attributes), para: paragraphStyle(ctx, spacingAfter: 6), into: out)

        default:
            for child in markup.children { block(child, into: out, context: ctx) }
        }
    }

    private func listItems(_ items: [ListItem], ordered: Bool, start: Int, into out: NSMutableAttributedString, context ctx: BlockContext) {
        let depth = Int(ctx.indent / 22)
        let bullets = ["•", "◦", "▪︎"]
        for (i, item) in items.enumerated() {
            var inner = ctx
            inner.indent = ctx.indent + 22
            inner.tight = true
            let marker: String
            if let box = item.checkbox {
                marker = box == .checked ? "☑" : "☐"
            } else {
                marker = ordered ? "\(start + i)." : bullets[depth % bullets.count]
            }
            for (j, child) in item.children.enumerated() {
                inner.listPrefix = j == 0 ? "\(marker)\t" : nil
                if j > 0, child is Paragraph { inner.listPrefix = nil }
                block(child, into: out, context: inner)
            }
        }
        // Space after the outermost list.
        if ctx.listPrefix == nil, ctx.indent == 0, out.length > 0 {
            let range = (out.string as NSString).paragraphRange(for: NSRange(location: out.length - 1, length: 0))
            if let p = out.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle,
               let m = p.mutableCopy() as? NSMutableParagraphStyle {
                m.paragraphSpacing = 8
                out.addAttribute(.paragraphStyle, value: m, range: range)
            }
        }
    }

    private func renderTable(_ table: Markdown.Table, into out: NSMutableAttributedString, context ctx: BlockContext) {
        let columns = max(table.maxColumnCount, 1)
        let textTable = NSTextTable()
        textTable.numberOfColumns = columns
        textTable.collapsesBorders = true
        textTable.hidesEmptyCells = false
        textTable.setContentWidth(100, type: .percentageValueType)

        var rows: [(cells: [Markdown.Table.Cell], header: Bool)] = [(Array(table.head.cells), true)]
        rows += table.body.rows.map { (Array($0.cells), false) }

        for (r, row) in rows.enumerated() {
            for c in 0..<columns {
                let cell = NSTextTableBlock(table: textTable, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                cell.setWidth(0.5, type: .absoluteValueType, for: .border)
                cell.setBorderColor(.separatorColor)
                cell.setWidth(5, type: .absoluteValueType, for: .padding)
                if row.header { cell.backgroundColor = .quaternarySystemFill }
                var inner = ctx
                inner.textBlocks = ctx.textBlocks + [cell]
                inner.indent = 0
                inner.listPrefix = nil
                var style = InlineStyle(size: bodySize - 1)
                style.bold = row.header
                let content = c < row.cells.count ? inlines(row.cells[c].children, style) : NSAttributedString(string: " ")
                let para = paragraphStyle(inner, spacingAfter: 0)
                para.lineHeightMultiple = 1.05
                appendParagraph(content.length == 0 ? NSAttributedString(string: " ", attributes: style.attributes) : content,
                                para: para, into: out)
            }
        }
        // A gap after the table that does not belong to it.
        appendParagraph(NSAttributedString(string: " ", attributes: InlineStyle(size: 4).attributes),
                        para: paragraphStyle(ctx, spacingAfter: 4), into: out)
    }

    private func appendParagraph(_ text: NSAttributedString, para: NSParagraphStyle, into out: NSMutableAttributedString) {
        let m = NSMutableAttributedString(attributedString: text)
        m.append(NSAttributedString(string: "\n"))
        m.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: m.length))
        out.append(m)
    }

    // MARK: Inlines

    struct InlineStyle {
        var size: CGFloat
        var bold = false
        var italic = false
        var code = false
        var strike = false
        var color: NSColor = .labelColor
        var link: URL?

        var attributes: [NSAttributedString.Key: Any] {
            var font: NSFont = code
                ? .monospacedSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
                : .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
            if italic {
                font = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(.italic), size: size) ?? font
            }
            var a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            if code { a[.backgroundColor] = NSColor.quaternarySystemFill }
            if strike { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link { a[.link] = link; a[.toolTip] = link.isFileURL ? link.path(percentEncoded: false) : link.absoluteString }
            return a
        }
    }

    private func inlines(_ children: some Sequence<Markup>, _ style: InlineStyle) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for child in children { out.append(inline(child, style)) }
        return out
    }

    private func inline(_ markup: Markup, _ style: InlineStyle) -> NSAttributedString {
        switch markup {
        case let t as Markdown.Text:
            return storyLinked(t.string, style)
        case let e as Emphasis:
            var s = style; s.italic = true
            return inlines(e.children, s)
        case let b as Strong:
            var s = style; s.bold = true
            return inlines(b.children, s)
        case let x as Strikethrough:
            var s = style; s.strike = true
            return inlines(x.children, s)
        case let c as InlineCode:
            var s = style
            s.code = true
            s.size = style.size - 1
            if s.link == nil, let url = resolveCodePath(c.code) { s.link = url }
            return NSAttributedString(string: c.code, attributes: s.attributes)
        case let l as Markdown.Link:
            var s = style
            s.link = l.destination.flatMap(resolve) ?? style.link
            return inlines(l.children, s)
        case let img as Markdown.Image:
            var s = style
            s.link = img.source.flatMap(resolve)
            s.italic = true
            return NSAttributedString(string: "[image: \(img.plainText.isEmpty ? (img.source ?? "") : img.plainText)]", attributes: s.attributes)
        case is SoftBreak:
            return NSAttributedString(string: " ", attributes: style.attributes)
        case is LineBreak:
            return NSAttributedString(string: "\u{2028}", attributes: style.attributes)
        case let h as InlineHTML:
            var s = style
            s.color = .tertiaryLabelColor
            return NSAttributedString(string: h.rawHTML, attributes: s.attributes)
        default:
            return inlines(markup.children, style)
        }
    }

    /// Links "Story 9.16" / "story 9.16" in plain text to the story, when it exists.
    private func storyLinked(_ text: String, _ style: InlineStyle) -> NSAttributedString {
        let out = NSMutableAttributedString(string: text, attributes: style.attributes)
        guard style.link == nil, !storyNumbers.isEmpty else { return out }
        let ns = text as NSString
        for m in text.matches(of: /[Ss]tor(?:y|ies)\s+(\d+\.\d+[a-z]?)/) {
            let number = String(m.1)
            guard storyNumbers.contains(number),
                  let url = URL(string: "\(Self.storyScheme)://story/\(number)") else { continue }
            let range = NSRange(m.range, in: text)
            guard range.location != NSNotFound, NSMaxRange(range) <= ns.length else { continue }
            out.addAttribute(.link, value: url, range: range)
        }
        return out
    }

    // MARK: Link resolution

    func resolve(_ destination: String) -> URL? {
        let d = destination.trimmingCharacters(in: .whitespaces)
        guard !d.isEmpty, !d.hasPrefix("#") else { return nil }
        if let url = URL(string: d), let scheme = url.scheme, scheme.count > 1 {
            return scheme == "file" ? (exists(url) ? url : nil) : url
        }
        return resolvePath(d)
    }

    /// Inline code is a link only if it plainly names a file that exists.
    private func resolveCodePath(_ code: String) -> URL? {
        guard code.count < 300, !code.contains(" "), !code.contains("\n") else { return nil }
        let looksLikePath = code.contains("/") || code.wholeMatch(of: /[\w.-]+\.(md|ya?ml|toml|rs|swift|py|sh|json|txt|csv)(:\d+(-\d+)?)?/) != nil
        guard looksLikePath else { return nil }
        return resolvePath(code)
    }

    private func resolvePath(_ raw: String) -> URL? {
        var path = raw.removingPercentEncoding ?? raw
        if let hash = path.firstIndex(of: "#") { path = String(path[..<hash]) }
        path = path.replacing(/:\d+(?::\d+)?(?:-\d+)?$/, with: "")
        path = path.replacingOccurrences(of: "{project-root}", with: projectRoot.path(percentEncoded: false))
        if path.hasPrefix("~/") { path = NSString(string: path).expandingTildeInPath }
        guard !path.isEmpty else { return nil }
        if path.hasPrefix("/") {
            let u = URL(filePath: path)
            return exists(u) ? u : nil
        }
        for base in [baseURL, projectRoot] {
            let u = base.appending(path: path).standardizedFileURL
            if exists(u) { return u }
        }
        return nil
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }
}
