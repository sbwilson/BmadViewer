import AppKit
import BmadKit
import SwiftUI

/// A unified diff: old and new line numbers, full-width added/removed bands,
/// syntax colours, and the stop's lines (new-side numbering) highlighted and
/// scrolled to.
struct DiffView: NSViewRepresentable {
    let diff: GitDiff.FileDiff
    let url: URL
    let highlight: LineRange?
    let key: String

    final class Coordinator { var key: String? }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> DocumentContainer {
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.textContainer?.replaceLayoutManager(DiffLayoutManager())
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 0, height: 8)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = []
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textContainer?.lineFragmentPadding = 0
        textView.layoutManager?.allowsNonContiguousLayout = true
        let container = DocumentContainer(textView: textView)
        container.scrollView.hasHorizontalScroller = true
        return container
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DocumentContainer, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 480, height: proposal.height ?? 480)
    }

    func updateNSView(_ container: DocumentContainer, context: Context) {
        guard context.coordinator.key != key, let storage = container.textView.textStorage else { return }
        context.coordinator.key = key
        let (text, target) = Self.render(diff, url: url, highlight: highlight)
        storage.setAttributedString(text)
        let textView = container.textView
        DispatchQueue.main.async {
            guard let target, let lm = textView.layoutManager, let tc = textView.textContainer else {
                container.scroll(toY: 0)
                return
            }
            lm.ensureLayout(forCharacterRange: target)
            let rect = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: target, actualCharacterRange: nil), in: tc)
            container.scroll(toY: max(0, rect.minY + textView.textContainerOrigin.y - container.scrollView.contentView.bounds.height * 0.3))
        }
    }

    /// The attributed diff, and the range to scroll to: the highlight, else the first change.
    static func render(_ diff: GitDiff.FileDiff, url: URL, highlight: LineRange?) -> (NSAttributedString, NSRange?) {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let gutterFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        let out = NSMutableAttributedString()
        var codeRanges: [(NSRange, Int)] = []   // where each code line landed, and its offset in `code`
        var code = ""
        var target: NSRange?
        var firstChange: NSRange?
        let width = max(4, String(diff.hunks.flatMap(\.lines).compactMap { max($0.old ?? 0, $0.new ?? 0) }.max() ?? 0).count)

        func pad(_ n: Int?) -> String {
            let s = n.map(String.init) ?? ""
            return String(repeating: " ", count: max(0, width - s.count)) + s
        }

        for (h, hunk) in diff.hunks.enumerated() {
            let title = hunk.lines.first.map { line -> String in
                let start = line.new ?? line.old ?? 0
                return "  ⋯ line \(start)" + (hunk.header.isEmpty ? "" : " · \(hunk.header)")
            } ?? ""
            let headerStart = out.length
            out.append(NSAttributedString(string: (h == 0 ? "" : "\n") + title, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
            out.addAttribute(.diffBand, value: DiffBand.hunk.rawValue, range: NSRange(location: headerStart, length: out.length - headerStart))
            for line in hunk.lines {
                out.append(NSAttributedString(string: "\n"))
                let start = out.length
                let marker: String = switch line.kind {
                case .added: "+"
                case .removed: "−"
                case .context: " "
                case .note: "\\"
                }
                let gutter = " \(pad(line.old)) \(pad(line.new)) \(marker) "
                out.append(NSAttributedString(string: gutter, attributes: [
                    .font: gutterFont,
                    .foregroundColor: line.kind == .context ? NSColor.tertiaryLabelColor : NSColor.secondaryLabelColor,
                ]))
                let codeStart = out.length
                out.append(NSAttributedString(string: line.text, attributes: [
                    .font: line.kind == .note ? NSFont.systemFont(ofSize: 11).withTraits(.italic) : font,
                    .foregroundColor: line.kind == .note ? NSColor.secondaryLabelColor : NSColor.labelColor,
                ]))
                if line.kind != .note {
                    codeRanges.append((NSRange(location: codeStart, length: (line.text as NSString).length), (code as NSString).length))
                    code += line.text + "\n"
                }
                let full = NSRange(location: start, length: out.length - start)
                let lit = highlight.map { h in line.new.map { $0 >= h.lower && $0 <= h.upper } ?? false } ?? false
                let band: DiffBand? = lit ? (line.kind == .added ? .highlightAdded : .highlight)
                    : line.kind == .added ? .added : line.kind == .removed ? .removed : nil
                if let band { out.addAttribute(.diffBand, value: band.rawValue, range: full) }
                if lit, target == nil { target = full }
                if line.kind == .added || line.kind == .removed, firstChange == nil { firstChange = full }
            }
        }

        // Syntax colours over the code, mapped back line by line.
        let starts = codeRanges.map(\.1)
        for (range, token) in Syntax.tokens(code, Syntax.language(for: url)) {
            var i = (starts.lastIndex { $0 <= range.location }) ?? 0
            var remaining = range
            while remaining.length > 0, i < codeRanges.count {
                let (dest, offset) = codeRanges[i]
                let lineEnd = offset + dest.length
                let from = remaining.location - offset
                let take = min(remaining.length, lineEnd - remaining.location)
                if take > 0, from >= 0 {
                    out.addAttribute(.foregroundColor, value: SourceCodeView.color(token), range: NSRange(location: dest.location + from, length: take))
                }
                // Skip the newline that joined this line to the next.
                let consumed = max(take, 0) + 1
                remaining = NSRange(location: remaining.location + consumed, length: max(0, remaining.length - consumed))
                i += 1
            }
        }
        return (out, target ?? firstChange)
    }
}

enum DiffBand: Int {
    case added, removed, hunk, highlight, highlightAdded

    var color: NSColor {
        switch self {
        case .added: NSColor.systemGreen.withAlphaComponent(0.14)
        case .removed: NSColor.systemRed.withAlphaComponent(0.14)
        case .hunk: NSColor.quaternarySystemFill
        case .highlight: NSColor.systemYellow.withAlphaComponent(0.30)
        case .highlightAdded: NSColor.systemYellow.withAlphaComponent(0.38)
        }
    }
}

extension NSAttributedString.Key {
    static let diffBand = NSAttributedString.Key("BmadViewer.diffBand")
}

/// Paints each line's band across the whole width of the view, not just behind its glyphs.
final class DiffLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if let storage = textStorage, let view = firstTextView {
            // Drawing happens on the main thread.
            let width = MainActor.assumeIsolated { max(view.bounds.width, view.enclosingScrollView?.contentView.bounds.width ?? 0) }
            enumerateLineFragments(forGlyphRange: glyphsToShow) { rect, _, _, glyphs, _ in
                let char = self.characterIndexForGlyph(at: glyphs.location)
                guard char < storage.length,
                      let raw = storage.attribute(.diffBand, at: char, effectiveRange: nil) as? Int,
                      let band = DiffBand(rawValue: raw) else { return }
                band.color.setFill()
                NSRect(x: 0, y: rect.minY + origin.y, width: width, height: rect.height).fill(using: .sourceOver)
            }
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
}

private extension NSFont {
    func withTraits(_ traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
        NSFont(descriptor: fontDescriptor.withSymbolicTraits(traits), size: pointSize) ?? self
    }
}
