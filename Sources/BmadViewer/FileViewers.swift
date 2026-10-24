import AppKit
import BmadKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: Kinds

enum FileKind {
    case markdown, ticketsToml, image, pdf, text, folder, other

    static func of(_ url: URL) -> FileKind {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDir), isDir.boolValue {
            return .folder
        }
        let ext = url.pathExtension.lowercased()
        if url.lastPathComponent == "tickets.toml" { return .ticketsToml }
        if ["md", "markdown"].contains(ext) { return .markdown }
        if ext == "pdf" { return .pdf }
        let type = UTType(filenameExtension: ext)
        if let type, type.conforms(to: .image) { return .image }
        if let type, type.conforms(to: .text) || type.conforms(to: .sourceCode) || type.conforms(to: .json) || type.conforms(to: .propertyList) {
            return .text
        }
        if knownText.contains(ext) || ext.isEmpty && looksLikeText(url) { return .text }
        return looksLikeText(url) ? .text : .other
    }

    static let knownText: Set<String> = ["rs", "toml", "yaml", "yml", "ts", "tsx", "mts", "cts", "jsx", "sql", "ftl", "lock", "gitignore", "env", "conf", "cfg", "ini", "log", "csv", "tsv", "gyb", "proto", "graphql"]

    /// No NUL in the first 8 KB and valid UTF-8.
    static func looksLikeText(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        guard let data = try? h.read(upToCount: 8192) else { return false }
        if data.isEmpty { return true }
        if data.contains(0) { return false }
        return String(data: data, encoding: .utf8) != nil
    }

    var icon: String {
        switch self {
        case .markdown: "doc.richtext"
        case .ticketsToml: "list.number"
        case .image: "photo"
        case .pdf: "doc.text.image"
        case .text: "chevron.left.forwardslash.chevron.right"
        case .folder: "folder"
        case .other: "doc"
        }
    }
}

// MARK: Viewer

/// The viewer that suits a file, under a toolbar with its path and its actions.
struct FileViewer: View {
    @Environment(ProjectStore.self) private var store
    let url: URL
    let lines: LineRange?
    let project: Project

    enum Mode: String, CaseIterable, Identifiable {
        case rendered = "Rendered", source = "Source", tickets = "Tickets"
        var id: Self { self }
    }

    @State private var mode: Mode?
    @State private var zoom = ZoomController()

    var body: some View {
        let kind = FileKind.of(url)
        let modes: [Mode] = switch kind {
        case .markdown: [.rendered, .source]
        case .ticketsToml: [.tickets, .source]
        default: []
        }
        let current = mode ?? (lines != nil ? .source : modes.first)
        let version = store.lastLoaded?.timeIntervalSince1970 ?? 0
        VStack(spacing: 0) {
            FileToolbar(url: url, lines: lines, project: project) {
                if !modes.isEmpty {
                    Picker("View", selection: Binding(get: { current ?? .source }, set: { mode = $0 })) {
                        ForEach(modes) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                }
                if kind == .image || kind == .pdf { ZoomControls(zoom: zoom) }
            }
            Divider()
            switch (kind, current) {
            case (.markdown, .rendered?):
                MarkdownFileView(url: url, project: project, version: store.lastLoaded)
            case (.ticketsToml, .tickets?):
                TicketsTomlView(url: url, project: project)
            case (.image, _):
                ImageViewer(url: url, zoom: zoom).id("\(url)#\(version)")
            case (.pdf, _):
                PDFViewer(url: url, zoom: zoom).id("\(url)#\(version)")
            case (.folder, _):
                FolderView(url: url)
            case (.other, _):
                FallbackFileView(url: url)
            default:
                SourceFileView(url: url, lines: lines, version: version)
            }
        }
    }
}

/// Path, line range, and the ways out: the default app, Open With, Finder.
struct FileToolbar<Controls: View>: View {
    let url: URL
    let lines: LineRange?
    let project: Project
    @ViewBuilder let controls: () -> Controls

    var body: some View {
        HStack(spacing: 10) {
            Text(relativePath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(url.path(percentEncoded: false))
            if let lines {
                Text(lines.label)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.yellow.opacity(0.25), in: Capsule())
            }
            Spacer(minLength: 8)
            controls()
            if let app = FileActions.defaultApplication(for: url) {
                Button { FileActions.open(url) } label: {
                    Image(nsImage: FileActions.icon(app, size: 16))
                }
                .buttonStyle(.borderless)
                .help("Open in \(FileActions.displayName(app))")
            }
            Menu {
                FileContextMenu(url: url)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Open With, Reveal in Finder, Copy Path")
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
    }

    private var relativePath: String {
        let root = project.root.path(percentEncoded: false)
        let path = url.path(percentEncoded: false)
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) : path
    }
}

// MARK: Source

struct SourceFileView: View {
    let url: URL
    let lines: LineRange?
    let version: TimeInterval

    var body: some View {
        if let text = Self.read(url) {
            SourceCodeView(url: url, text: text, lines: lines, key: "\(url.path(percentEncoded: false))#\(version)#\(lines?.fragment ?? "")")
        } else {
            FallbackFileView(url: url)
        }
    }

    /// Text up to 8 MB; anything larger or undecodable falls back.
    static func read(_ url: URL) -> String? {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= 8_000_000 else { return nil }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1))
    }
}

/// Monospaced, unwrapped, line-numbered text with syntax colours, scrolled to
/// and highlighting `lines`.
struct SourceCodeView: NSViewRepresentable {
    let url: URL
    let text: String
    let lines: LineRange?
    let key: String

    final class Coordinator {
        var key: String?
        var observer: NSObjectProtocol?
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> DocumentContainer {
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 6, height: 10)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = []
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.layoutManager?.allowsNonContiguousLayout = true
        let container = DocumentContainer(textView: textView)
        container.scrollView.hasHorizontalScroller = true
        let ruler = LineNumberRuler(textView: textView, scrollView: container.scrollView)
        container.scrollView.verticalRulerView = ruler
        container.scrollView.hasVerticalRuler = true
        container.scrollView.rulersVisible = true
        container.scrollView.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: container.scrollView.contentView, queue: .main
        ) { [weak ruler] _ in
            MainActor.assumeIsolated { ruler?.needsDisplay = true }
        }
        return container
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DocumentContainer, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 480, height: proposal.height ?? 480)
    }

    func updateNSView(_ container: DocumentContainer, context: Context) {
        guard context.coordinator.key != key, let storage = container.textView.textStorage else { return }
        context.coordinator.key = key
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let attributed = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        // Colour only the first 2 MB: past that the cost outweighs the help.
        let lang = Syntax.language(for: url)
        let sample = text.utf16.count > 2_000_000 ? String(text.prefix(2_000_000)) : text
        for (range, token) in Syntax.tokens(sample, lang) {
            attributed.addAttribute(.foregroundColor, value: Self.color(token), range: range)
            if token == .heading { attributed.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold), range: range) }
        }
        let starts = Self.lineStarts(text)
        let highlight = lines.flatMap { Self.characterRange(of: $0, starts: starts, length: attributed.length) }
        if let highlight {
            attributed.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.28), range: highlight)
        }
        storage.setAttributedString(attributed)
        if let ruler = container.scrollView.verticalRulerView as? LineNumberRuler {
            ruler.lineStarts = starts
            ruler.highlighted = lines
            ruler.updateThickness()
            ruler.needsDisplay = true
        }
        let textView = container.textView
        DispatchQueue.main.async {
            guard let highlight, let lm = textView.layoutManager, let tc = textView.textContainer else {
                container.scroll(toY: 0)
                return
            }
            lm.ensureLayout(forCharacterRange: highlight)
            let glyphs = lm.glyphRange(forCharacterRange: highlight, actualCharacterRange: nil)
            let rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
            let visible = container.scrollView.contentView.bounds.height
            container.scroll(toY: max(0, rect.minY + textView.textContainerOrigin.y - visible * 0.3))
        }
    }

    static func lineStarts(_ text: String) -> [Int] {
        var starts = [0]
        var i = 0
        for unit in text.utf16 {
            i += 1
            if unit == 10 { starts.append(i) }
        }
        return starts
    }

    static func characterRange(of lines: LineRange, starts: [Int], length: Int) -> NSRange? {
        guard lines.lower <= starts.count else { return nil }
        let start = starts[lines.lower - 1]
        let end = lines.upper < starts.count ? starts[lines.upper] : length
        return NSRange(location: start, length: max(0, end - start))
    }

    static func color(_ token: Syntax.Token) -> NSColor {
        switch token {
        case .comment: .systemGray
        case .string: .systemRed
        case .number: .systemPurple
        case .keyword: .systemPink
        case .type: .systemTeal
        case .key: .systemBlue
        case .heading: .systemOrange
        case .tag: .systemBlue
        }
    }
}

/// Line numbers for a TextKit 1 text view; the highlighted range in the accent colour.
final class LineNumberRuler: NSRulerView {
    var lineStarts: [Int] = [0]
    var highlighted: LineRange?

    init(textView: NSTextView, scrollView: NSScrollView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        clipsToBounds = true
        ruleThickness = 40
    }

    required init(coder: NSCoder) { fatalError("not used") }

    func updateThickness() {
        let digits = max(3, String(lineStarts.count).count)
        ruleThickness = CGFloat(digits) * 7.5 + 18
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        // Only the dirty rect: views do not clip to their bounds since macOS 14, so
        // filling `bounds` painted the gutter's edge up through the header above.
        let area = rect.intersection(visibleRect)
        NSColor.textBackgroundColor.setFill()
        area.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: area.minY, width: 1, height: area.height).fill()
        guard let tv = clientView as? NSTextView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        let visible = tv.visibleRect
        let glyphs = lm.glyphRange(forBoundingRect: visible, in: tc)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        var line = lineIndex(containing: chars.location)
        let length = tv.textStorage?.length ?? 0
        while line < lineStarts.count, lineStarts[line] <= NSMaxRange(chars) {
            let start = lineStarts[line]
            let fragment: NSRect
            if start >= length {
                fragment = lm.extraLineFragmentRect
                if fragment.isEmpty { break }
            } else {
                fragment = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: start), effectiveRange: nil)
            }
            let y = convert(NSPoint(x: 0, y: fragment.minY + tv.textContainerOrigin.y), from: tv).y
            let number = line + 1
            let lit = highlighted.map { number >= $0.lower && number <= $0.upper } ?? false
            let label = NSAttributedString(string: "\(number)", attributes: [
                .font: lit ? NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold) : font,
                .foregroundColor: lit ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor,
            ])
            let size = label.size()
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y + (fragment.height - size.height) / 2))
            line += 1
        }
    }

    /// The 0-based line holding `char`, by binary search.
    private func lineIndex(containing char: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= char { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }
}

// MARK: Zoom

@MainActor
@Observable
final class ZoomController {
    var percent = 100
    @ObservationIgnored var zoomIn: () -> Void = {}
    @ObservationIgnored var zoomOut: () -> Void = {}
    @ObservationIgnored var fit: () -> Void = {}
    @ObservationIgnored var actualSize: () -> Void = {}
}

struct ZoomControls: View {
    let zoom: ZoomController

    var body: some View {
        HStack(spacing: 2) {
            Button { zoom.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom out")
            Text("\(zoom.percent)%")
                .font(.caption.monospacedDigit())
                .frame(minWidth: 40)
            Button { zoom.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom in")
            Button { zoom.fit() } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
                .help("Zoom to fit")
            Button { zoom.actualSize() } label: { Image(systemName: "1.magnifyingglass") }
                .help("Actual size")
        }
        .buttonStyle(.borderless)
    }
}

// MARK: Image

struct ImageViewer: NSViewRepresentable {
    let url: URL
    let zoom: ZoomController

    final class Coordinator {
        var observers: [NSObjectProtocol] = []
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.contentView = CenteringClipView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.02
        scroll.maxMagnification = 32
        scroll.backgroundColor = .underPageBackgroundColor
        guard let image = NSImage(contentsOf: url) else { return scroll }
        let view = PanningImageView(frame: NSRect(origin: .zero, size: image.size))
        view.image = image
        view.imageScaling = .scaleAxesIndependently
        scroll.documentView = view

        // Main-thread only: the observers below run on .main and hop back via assumeIsolated.
        nonisolated(unsafe) let update = { [weak scroll, zoom] in
            guard let scroll else { return }
            zoom.percent = Int((scroll.magnification * 100).rounded())
        }
        func set(_ m: CGFloat) {
            let center = NSPoint(x: scroll.contentView.bounds.midX, y: scroll.contentView.bounds.midY)
            scroll.setMagnification(min(max(m, scroll.minMagnification), scroll.maxMagnification), centeredAt: center)
            update()
        }
        zoom.zoomIn = { [weak scroll] in if let scroll { set(scroll.magnification * 1.25) } }
        zoom.zoomOut = { [weak scroll] in if let scroll { set(scroll.magnification / 1.25) } }
        zoom.actualSize = { set(1) }
        zoom.fit = { [weak scroll, weak view] in
            guard let scroll, let view else { return }
            scroll.magnify(toFit: view.frame)
            update()
        }
        view.onDoubleClick = { [zoom] in
            if zoom.percent == 100 { zoom.fit() } else { zoom.actualSize() }
        }
        context.coordinator.observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveMagnifyNotification, object: scroll, queue: .main
        ) { _ in MainActor.assumeIsolated { update() } })
        // Fit a large image; show a small one at its own size.
        DispatchQueue.main.async { [weak scroll] in
            guard let scroll else { return }
            if image.size.width > scroll.contentSize.width || image.size.height > scroll.contentSize.height {
                zoom.fit()
            } else {
                update()
            }
        }
        return scroll
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 480, height: proposal.height ?? 480)
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}

/// Keeps a document smaller than the viewport in its middle.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        if rect.width > doc.frame.width { rect.origin.x = (doc.frame.width - rect.width) / 2 }
        if rect.height > doc.frame.height { rect.origin.y = (doc.frame.height - rect.height) / 2 }
        return rect
    }
}

/// Drag to pan; double-click to toggle fit and actual size.
final class PanningImageView: NSImageView {
    var onDoubleClick: () -> Void = {}
    private var last: NSPoint?

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick(); return }
        last = event.locationInWindow
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let last, let clip = enclosingScrollView?.contentView else { return }
        let now = event.locationInWindow
        let scale = enclosingScrollView?.magnification ?? 1
        var origin = clip.bounds.origin
        origin.x -= (now.x - last.x) / scale
        origin.y += (now.y - last.y) / scale * (clip.isFlipped ? 1 : -1)
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        enclosingScrollView?.reflectScrolledClipView(clip)
        self.last = now
    }

    override func mouseUp(with event: NSEvent) {
        last = nil
        NSCursor.pop()
    }
}

// MARK: PDF

struct PDFViewer: NSViewRepresentable {
    let url: URL
    let zoom: ZoomController

    final class Coordinator {
        var observer: NSObjectProtocol?
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = PDFDocument(url: url)
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .underPageBackgroundColor
        nonisolated(unsafe) let update = { [weak view, zoom] in
            if let view { zoom.percent = Int((view.scaleFactor * 100).rounded()) }
        }
        zoom.zoomIn = { [weak view] in view?.zoomIn(nil); update() }
        zoom.zoomOut = { [weak view] in view?.zoomOut(nil); update() }
        zoom.fit = { [weak view] in view?.autoScales = true; update() }
        zoom.actualSize = { [weak view] in view?.scaleFactor = 1; update() }
        context.coordinator.observer = NotificationCenter.default.addObserver(
            forName: .PDFViewScaleChanged, object: view, queue: .main
        ) { _ in MainActor.assumeIsolated { update() } }
        DispatchQueue.main.async { update() }
        return view
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PDFView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 480, height: proposal.height ?? 480)
    }

    func updateNSView(_ nsView: PDFView, context: Context) {}
}

// MARK: Folder and fallback

struct FolderView: View {
    @Environment(\.openDocument) private var openDocument
    let url: URL

    var body: some View {
        let children = ((try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []).sorted { a, b in
            let da = FileKind.of(a) == .folder, db = FileKind.of(b) == .folder
            return da != db ? da : a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
        }
        List(children, id: \.self) { child in
            Button {
                if let openDocument { openDocument(child) } else { FileActions.open(child) }
            } label: {
                Label {
                    Text(child.lastPathComponent)
                } icon: {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: child.path(percentEncoded: false)))
                        .resizable().frame(width: 16, height: 16)
                }
            }
            .buttonStyle(.plain)
            .contextMenu { FileContextMenu(url: child) }
        }
        .overlay { if children.isEmpty { ContentUnavailableView("Empty folder", systemImage: "folder") } }
    }
}

struct FallbackFileView: View {
    let url: URL

    var body: some View {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .localizedTypeDescriptionKey])
        VStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false)))
                .resizable().frame(width: 64, height: 64)
            Text(url.lastPathComponent).font(.headline)
            Text([values?.localizedTypeDescription, values?.fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Open") { FileActions.open(url) }.keyboardShortcut(.defaultAction)
                Menu("Open With") { FileContextMenu(url: url) }.fixedSize()
                Button("Reveal in Finder") { FileActions.reveal(url) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
