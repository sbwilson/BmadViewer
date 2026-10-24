import AppKit
import BmadKit
import SwiftUI

/// A read-only, selectable, findable rich-text view. Clicking a file link opens
/// it in its default app; right-clicking offers Open With, Reveal and Copy Path.
struct DocumentView: NSViewRepresentable {
    /// Identity of the content: re-rendering happens only when this changes.
    let key: String
    let render: @MainActor () -> NSAttributedString
    var onStoryLink: (String) -> Void
    /// Opens a file link in a tab; nil outside a tabbed view, where links open in their app.
    var onOpenFile: OpenDocumentAction?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> DocumentContainer {
        // TextKit 1: NSTextTable and text blocks are TextKit 1 features.
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 22, height: 18)
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .cursor: NSCursor.pointingHand,
        ]
        textView.delegate = context.coordinator
        return DocumentContainer(textView: textView)
    }

    /// Take whatever space is offered: the document scrolls, it never asks to grow
    /// to its own height (which would push the whole split view out of the window).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DocumentContainer, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 480, height: proposal.height ?? 480)
    }

    func updateNSView(_ container: DocumentContainer, context: Context) {
        context.coordinator.onStoryLink = onStoryLink
        context.coordinator.onOpenFile = onOpenFile
        guard context.coordinator.key != key else { return }
        context.coordinator.key = key
        container.textView.textStorage?.setAttributedString(render())
        container.scroll(toY: 0)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var key: String?
        var onStoryLink: (String) -> Void = { _ in }
        var onOpenFile: OpenDocumentAction?

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else { return false }
            if url.scheme == MarkdownRenderer.storyScheme {
                onStoryLink(url.lastPathComponent)
            } else if url.isFileURL, let onOpenFile {
                onOpenFile(url.withoutFragment, url.lineRange)
            } else {
                FileActions.open(url.isFileURL ? url.withoutFragment : url)
            }
            return true
        }

        func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            guard charIndex >= 0, charIndex < view.textStorage?.length ?? 0,
                  let link = view.textStorage?.attribute(.link, at: charIndex, effectiveRange: nil),
                  let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)),
                  url.scheme != MarkdownRenderer.storyScheme
            else { return menu }
            let file = url.isFileURL ? url.withoutFragment : url
            let open = onOpenFile.map { f in { f(file, url.lineRange) } }
            let items = FileActions.linkMenuItems(for: file, openInTab: open)
            for (i, item) in items.enumerated() { menu.insertItem(item, at: i) }
            menu.insertItem(.separator(), at: items.count)
            return menu
        }
    }
}

/// Holds the scroll view by autoresizing, so Auto Layout never sees the text
/// view's height. Returned directly, the NSScrollView was sized by SwiftUI to its
/// document (2600pt for a story file) and shifted the whole window's content.
final class DocumentContainer: NSView {
    let scrollView = NSScrollView()
    let textView: NSTextView

    init(textView: NSTextView) {
        self.textView = textView
        super.init(frame: NSRect(x: 0, y: 0, width: 480, height: 480))
        clipsToBounds = true
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.documentView = textView
        textView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Scrolls this clip view only (NSView.scroll walks up into SwiftUI's scroll
    /// views) to `y` in the document. A vertical ruler is an inset on the clip view,
    /// whose bounds start at minus that inset; scrolling to x 0 slid the text under it.
    func scroll(toY y: CGFloat) {
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: -clip.contentInsets.left, y: y - clip.contentInsets.top))
        scrollView.reflectScrolledClipView(clip)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}
