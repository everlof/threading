import AppKit

// MARK: - Position

/// A place in a transcript's text: which item of the presentation, which run of text inside it,
/// and how many UTF-16 units into that run.
///
/// An item with no text of its own — a divider, a tool row, a fold — is still a place, at
/// segment and offset zero, so a drag across it orders correctly and simply selects nothing there.
struct TranscriptTextPosition: Comparable, Hashable {
    let item: Int
    let segment: Int
    let offset: Int

    /// The start and the end of a whole item, for a selection that covers it entirely.
    static func start(ofItem item: Int) -> Self { Self(item: item, segment: 0, offset: 0) }
    static func end(ofItem item: Int) -> Self { Self(item: item, segment: .max, offset: .max) }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.item, lhs.segment, lhs.offset) < (rhs.item, rhs.segment, rhs.offset)
    }
}

/// What the reader has chosen: where the drag began and where it is now, in either order.
struct TranscriptTextRange: Equatable {
    var anchor: TranscriptTextPosition
    var focus: TranscriptTextPosition

    var start: TranscriptTextPosition { min(anchor, focus) }
    var end: TranscriptTextPosition { max(anchor, focus) }
    var isEmpty: Bool { anchor == focus }

    /// The part of one segment the range covers, or nil when it covers none of it.
    func range(inItem item: Int, segment: Int, length: Int) -> NSRange? {
        let here = (item, segment)
        let start = self.start
        let end = self.end
        guard (start.item, start.segment) <= here, here <= (end.item, end.segment) else { return nil }
        let lower = (start.item, start.segment) == here ? min(start.offset, length) : 0
        let upper = (end.item, end.segment) == here ? min(end.offset, length) : length
        guard upper > lower else { return nil }
        return NSRange(location: lower, length: upper - lower)
    }

    /// Whether the range takes in every character of `item`, whatever its segments turn out to
    /// be — which is when the item's text can come from the model rather than from its views.
    func coversWhole(item: Int) -> Bool {
        let start = self.start
        let end = self.end
        let fromStart = start.item < item || (start.item == item && start.segment == 0 && start.offset == 0)
        let toEnd = end.item > item || (end.item == item && end.segment == .max)
        return fromStart && toEnd
    }
}

// MARK: - Segments

/// The runs of selectable text inside one row: the conversation's prose labels — Markdown
/// blocks, a bubble's `ProseLabel`, a code block — and the cells of a Markdown table.
///
/// Opt-in by identifier rather than by class, because a transcript row also holds labels that
/// are *controls'* titles — a tool row's header, a card's caption — and a press on one of those
/// belongs to the control.
@MainActor
enum TranscriptTextSegments {
    struct Segment {
        let field: NSTextField
        /// In the coordinates of the view the segments were collected against.
        let frame: NSRect
        /// The Markdown table the run is a cell of, if it is one.
        let table: ObjectIdentifier?
    }

    /// Whether a view a press landed on is transcript text rather than part of a control.
    static func isText(_ view: NSView, within host: NSView) -> Bool {
        guard let field = view as? NSTextField, participates(field) else { return false }
        var ancestor = field.superview
        while let current = ancestor, current !== host {
            if current is NSControl { return false }
            ancestor = current.superview
        }
        return true
    }

    /// Every segment in `host`, in reading order: top to bottom, then leading to trailing for
    /// runs that share a line — the cells of a table row.
    static func collect(in host: NSView, relativeTo reference: NSView) -> [Segment] {
        var found: [Segment] = []
        gather(in: host, host: host, reference: reference, into: &found)
        return found.sorted { lhs, rhs in
            if abs(lhs.frame.minY - rhs.frame.minY) > TranscriptTextSelectionDefaults.sameLineTolerance {
                return lhs.frame.minY < rhs.frame.minY
            }
            return lhs.frame.minX < rhs.frame.minX
        }
    }

    /// What goes between two neighbouring segments when they are copied: a tab between the
    /// cells of one table row and a line break between its rows, a blank line between
    /// paragraphs, a line break between the items of a list. Told apart by where they sit,
    /// because that is all a row's views say about the document they were built from.
    static func separator(between previous: Segment, and next: Segment) -> String {
        let sameLine = abs(next.frame.minY - previous.frame.minY)
            <= TranscriptTextSelectionDefaults.sameLineTolerance
        if let table = next.table, table == previous.table {
            return sameLine ? "\t" : "\n"
        }
        if sameLine { return "\t" }
        return next.frame.minY - previous.frame.maxY > Design.Chat.blockSpacing / 2 ? "\n\n" : "\n"
    }

    private static func participates(_ field: NSTextField) -> Bool {
        guard !field.isEditable, !field.isHiddenOrHasHiddenAncestor else { return false }
        return field.identifier == .transcriptText || documentTable(containing: field) != nil
    }

    private static func documentTable(containing field: NSTextField) -> ThemedDocumentTableView? {
        var ancestor = field.superview
        while let current = ancestor {
            if let table = current as? ThemedDocumentTableView { return table }
            ancestor = current.superview
        }
        return nil
    }

    private static func gather(
        in view: NSView,
        host: NSView,
        reference: NSView,
        into found: inout [Segment]
    ) {
        for child in view.subviews where !child.isHidden {
            if let field = child as? NSTextField, isText(field, within: host) {
                found.append(Segment(
                    field: field,
                    frame: reference.convert(field.bounds, from: field),
                    table: documentTable(containing: field).map(ObjectIdentifier.init)
                ))
                continue
            }
            gather(in: child, host: host, reference: reference, into: &found)
        }
    }
}

// MARK: - Source

/// What the selection needs from the transcript it selects in.
@MainActor
protocol TranscriptTextSource: AnyObject {
    var selectableItemCount: Int { get }
    /// The whole text of an item, read from the model, for an item the selection covers
    /// entirely while it has no views — scrolled away, or never shown. Nil for an item that
    /// holds no prose.
    func selectableText(ofItem item: Int) -> String?
    /// The host currently showing an item, if AppKit has one.
    func materializedHost(ofItem item: Int) -> NSView?
}

// MARK: - Controller

/// Text selection that runs across a transcript's rows the way it runs across a page.
///
/// A transcript is a virtualized table of separately built rows, and every paragraph, list
/// item, code block and table cell in a row is its own label. AppKit lets one label hold a
/// selection at a time — the field editor is one per window — so a drag that began in one
/// paragraph stopped at its last character, and nothing spanning two blocks, let alone two
/// messages, could be copied. That was reported as "I can't select between sections".
///
/// So the transcript owns the selection. A press on transcript text is handed here by the row
/// host (`ConversationVirtualRowHost`) instead of to the label, the drag is tracked across rows
/// with autoscroll, positions are stated as item/segment/offset, and the highlight is painted
/// into each label's own text with the theme's text-selection colours — the label draws it, so
/// it lies exactly under the glyphs. A row that scrolls into view inside the selection is
/// decorated as it materializes; a row that scrolled away is copied from the model.
@MainActor
final class TranscriptTextSelection {

    // MARK: - Properties

    private(set) var range: TranscriptTextRange?

    private weak var tableView: ThemedTableView?
    private weak var source: TranscriptTextSource?

    /// The text of the rows the range ends in, read while they were on screen, so a partial row
    /// that has since scrolled away still copies the part of it that was chosen.
    private var snapshots: [Int: [SnapshotSegment]] = [:]

    private struct SnapshotSegment {
        let text: String
        let separator: String
    }

    /// Labels currently wearing the highlight, with the text to give back.
    private var highlights: [ObjectIdentifier: Highlight] = [:]

    private struct Highlight {
        weak var field: NSTextField?
        let range: NSRange
        let original: NSAttributedString
        let applied: NSAttributedString
    }

    private let appEvents = AppEventObservations()
    private let layout = TranscriptTextLayout()

    // MARK: - Initialization

    init(tableView: ThemedTableView, source: TranscriptTextSource) {
        self.tableView = tableView
        self.source = source

        tableView.canCopy = { [weak self] in self?.range.map { !$0.isEmpty } ?? false }
        tableView.onCopy = { [weak self] in self?.copyToPasteboard() }
        tableView.onSelectAll = { [weak self] in self?.selectAll() ?? false }

        // A theme or text-size change rebuilds the labels the highlight was painted into; paint
        // it into their replacements once those exist.
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshHighlights() }
        }
    }

    // MARK: - Public Methods

    /// Takes over a press that landed on transcript text and tracks it to its release.
    func track(mouseDown event: NSEvent) {
        guard let tableView, let window = tableView.window else { return }
        let point = tableView.convert(event.locationInWindow, from: nil)
        guard let hit = position(at: point) else {
            clear()
            return
        }

        let extends = event.modifierFlags.contains(.shift) && range != nil
        switch event.clickCount {
        case 2:
            setRange(word(around: hit) ?? TranscriptTextRange(anchor: hit.position, focus: hit.position))
        case 3...:
            setRange(segmentRange(around: hit) ?? TranscriptTextRange(anchor: hit.position, focus: hit.position))
        default:
            if extends, let range {
                setRange(TranscriptTextRange(anchor: range.anchor, focus: hit.position))
            } else {
                setRange(TranscriptTextRange(anchor: hit.position, focus: hit.position))
            }
        }

        var dragged = false
        var lastDrag = event
        NSEvent.startPeriodicEvents(
            afterDelay: TranscriptTextSelectionDefaults.autoscrollDelay,
            withPeriod: TranscriptTextSelectionDefaults.autoscrollPeriod
        )
        defer { NSEvent.stopPeriodicEvents() }

        while let next = window.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp, .periodic],
            until: .distantFuture,
            inMode: .eventTracking,
            dequeue: true
        ) {
            switch next.type {
            case .leftMouseDragged:
                dragged = true
                lastDrag = next
                extend(toWindowPoint: next.locationInWindow)
            case .periodic:
                // Held past the viewport's edge: keep scrolling, and keep the end of the range
                // under the pointer as rows move beneath it.
                guard dragged, tableView.autoscroll(with: lastDrag) else { continue }
                extend(toWindowPoint: lastDrag.locationInWindow)
            case .leftMouseUp:
                if !dragged, !extends, event.clickCount == 1 {
                    // A click, not a drag: follow a link under it, and either way let go of the
                    // selection the way a page does.
                    let link = self.link(at: hit)
                    clear()
                    if let link { NSWorkspace.shared.open(link) }
                } else if let range, !range.isEmpty {
                    // Something is chosen, so ⌘C and ⌘A have to reach the transcript. A bare
                    // click takes no focus: the reply box keeps the keyboard it had.
                    window.makeFirstResponder(tableView)
                }
                return
            default:
                continue
            }
        }
    }

    /// Selects what a drag from one point of the table to another would — the gesture's two
    /// ends without its event loop, for callers that already know where they are.
    func select(fromTablePoint start: NSPoint, to end: NSPoint) {
        guard let anchor = position(at: start), let focus = position(at: end) else {
            clear()
            return
        }
        setRange(TranscriptTextRange(anchor: anchor.position, focus: focus.position))
    }

    /// Paints the highlight into a row that has just materialized inside the range.
    func decorate(_ host: NSView, item: Int) {
        guard let range, !range.isEmpty, let tableView,
              range.start.item <= item, item <= range.end.item else { return }
        let segments = TranscriptTextSegments.collect(in: host, relativeTo: tableView)
        for (index, segment) in segments.enumerated() {
            let length = segment.field.attributedStringValue.length
            guard let covered = range.range(inItem: item, segment: index, length: length) else {
                continue
            }
            paint(segment.field, range: covered)
        }
    }

    /// The selected text as it reads, ready for the pasteboard.
    func selectedText() -> String? {
        guard let range, !range.isEmpty, let source else { return nil }
        var parts: [String] = []
        let lastItem = min(range.end.item, source.selectableItemCount - 1)
        guard range.start.item <= lastItem else { return nil }
        for item in range.start.item...lastItem {
            if let text = text(ofItem: item, in: range, source: source), !text.isEmpty {
                parts.append(text)
            }
        }
        let joined = parts.joined(separator: "\n\n")
        return joined.isEmpty ? nil : joined
    }

    @discardableResult
    func copyToPasteboard() -> Bool {
        guard let text = selectedText() else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return true
    }

    /// Every item, start to end.
    @discardableResult
    func selectAll() -> Bool {
        guard let source, source.selectableItemCount > 0 else { return false }
        snapshots.removeAll()
        setRange(TranscriptTextRange(
            anchor: .start(ofItem: 0),
            focus: .end(ofItem: source.selectableItemCount - 1)
        ))
        return true
    }

    func clear() {
        guard range != nil else { return }
        range = nil
        snapshots.removeAll()
        removeHighlights()
    }

    /// The presentation changed from `item` on. A range reaching that far was stated in item
    /// numbers that may no longer mean the same rows, so it is let go rather than left pointing
    /// at whatever moved into its place. Appending past the end never reaches it.
    func itemsChanged(from item: Int) {
        guard let range, range.end.item >= item else { return }
        clear()
    }

    // MARK: - Private Methods

    private struct Hit {
        let position: TranscriptTextPosition
        let field: NSTextField?
        let index: Int?
    }

    private func setRange(_ newRange: TranscriptTextRange) {
        range = newRange
        // Only the rows the range ends in can be copied in part, so only theirs are kept.
        let ends: Set<Int> = [newRange.anchor.item, newRange.focus.item]
        snapshots = snapshots.filter { ends.contains($0.key) }
        refreshHighlights()
    }

    private func extend(toWindowPoint windowPoint: NSPoint) {
        guard let tableView, let range else { return }
        let point = tableView.convert(windowPoint, from: nil)
        guard let hit = position(at: point) else { return }
        let extended = TranscriptTextRange(anchor: range.anchor, focus: hit.position)
        guard extended != range else { return }
        setRange(extended)
    }

    /// Where a point in the table falls in the text, snapshotting the row it lands in.
    private func position(at point: NSPoint) -> Hit? {
        guard let tableView, let source, source.selectableItemCount > 0 else { return nil }
        let count = source.selectableItemCount
        if point.y < 0 { return Hit(position: .start(ofItem: 0), field: nil, index: nil) }
        var item = tableView.row(at: point)
        if item < 0 {
            guard point.y > tableView.bounds.minY else {
                return Hit(position: .start(ofItem: 0), field: nil, index: nil)
            }
            item = count - 1
            return Hit(position: .end(ofItem: item), field: nil, index: nil)
        }
        guard let host = source.materializedHost(ofItem: item) else {
            return Hit(position: .start(ofItem: item), field: nil, index: nil)
        }
        let segments = TranscriptTextSegments.collect(in: host, relativeTo: tableView)
        snapshot(segments, item: item)
        guard !segments.isEmpty else {
            return Hit(position: .start(ofItem: item), field: nil, index: nil)
        }

        for (index, segment) in segments.enumerated() {
            if point.y < segment.frame.minY {
                return Hit(
                    position: TranscriptTextPosition(item: item, segment: index, offset: 0),
                    field: nil,
                    index: nil
                )
            }
            guard point.y <= segment.frame.maxY else { continue }
            // A cell that shares its line with the next one hands the point on when it lies
            // beyond its trailing edge.
            if segments.indices.contains(index + 1) {
                let next = segments[index + 1]
                let sharesLine = abs(next.frame.minY - segment.frame.minY)
                    <= TranscriptTextSelectionDefaults.sameLineTolerance
                if sharesLine, point.x >= next.frame.minX { continue }
            }
            let located = layout.location(in: segment.field, at: point, from: tableView)
            return Hit(
                position: TranscriptTextPosition(item: item, segment: index, offset: located.insertion),
                field: segment.field,
                index: located.character
            )
        }
        let last = segments.count - 1
        return Hit(
            position: TranscriptTextPosition(
                item: item,
                segment: last,
                offset: segments[last].field.attributedStringValue.length
            ),
            field: nil,
            index: nil
        )
    }

    private func word(around hit: Hit) -> TranscriptTextRange? {
        guard let field = hit.field, let index = hit.index else { return nil }
        let text = field.attributedStringValue
        guard text.length > 0 else { return nil }
        let word = text.doubleClick(at: min(index, text.length - 1))
        let position = hit.position
        return TranscriptTextRange(
            anchor: TranscriptTextPosition(item: position.item, segment: position.segment, offset: word.location),
            focus: TranscriptTextPosition(item: position.item, segment: position.segment, offset: NSMaxRange(word))
        )
    }

    private func segmentRange(around hit: Hit) -> TranscriptTextRange? {
        guard let field = hit.field else { return nil }
        let position = hit.position
        return TranscriptTextRange(
            anchor: TranscriptTextPosition(item: position.item, segment: position.segment, offset: 0),
            focus: TranscriptTextPosition(
                item: position.item,
                segment: position.segment,
                offset: field.attributedStringValue.length
            )
        )
    }

    private func link(at hit: Hit) -> URL? {
        guard let field = hit.field, let index = hit.index else { return nil }
        let text = field.attributedStringValue
        guard index < text.length else { return nil }
        let value = text.attribute(.link, at: index, effectiveRange: nil)
        let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
        return url.flatMap(MarkdownExternalURLPolicy.externalWebURL)
    }

    /// Remembers the text of the row a position was just found in. `setRange` keeps only the
    /// rows the range now ends in.
    private func snapshot(_ segments: [TranscriptTextSegments.Segment], item: Int) {
        var captured: [SnapshotSegment] = []
        for (index, segment) in segments.enumerated() {
            let separator = index == 0
                ? ""
                : TranscriptTextSegments.separator(between: segments[index - 1], and: segment)
            captured.append(SnapshotSegment(
                text: unhighlightedText(of: segment.field),
                separator: separator
            ))
        }
        snapshots[item] = captured
    }

    private func text(ofItem item: Int, in range: TranscriptTextRange, source: TranscriptTextSource) -> String? {
        if let host = source.materializedHost(ofItem: item), let tableView {
            let segments = TranscriptTextSegments.collect(in: host, relativeTo: tableView)
            let captured = segments.enumerated().map { index, segment in
                SnapshotSegment(
                    text: unhighlightedText(of: segment.field),
                    separator: index == 0
                        ? ""
                        : TranscriptTextSegments.separator(between: segments[index - 1], and: segment)
                )
            }
            return text(of: captured, item: item, in: range)
        }
        if range.coversWhole(item: item) {
            return source.selectableText(ofItem: item)
        }
        if let captured = snapshots[item] {
            return text(of: captured, item: item, in: range)
        }
        return source.selectableText(ofItem: item)
    }

    private func text(of segments: [SnapshotSegment], item: Int, in range: TranscriptTextRange) -> String {
        var result = ""
        var wroteAny = false
        for (index, segment) in segments.enumerated() {
            let utf16 = segment.text as NSString
            guard let covered = range.range(inItem: item, segment: index, length: utf16.length) else {
                continue
            }
            if wroteAny { result += segment.separator }
            result += utf16.substring(with: covered)
            wroteAny = true
        }
        return result
    }

    /// The label's text without the highlight's colours, for copying and snapshotting.
    private func unhighlightedText(of field: NSTextField) -> String {
        field.attributedStringValue.string
    }

    /// Brings the visible labels' highlight to the range. Only a label whose covered part
    /// changed is repainted — a drag moves the end of the range through one or two labels per
    /// event, and setting every visible label's text again on each would make the drag pay for
    /// the whole viewport.
    private func refreshHighlights() {
        guard let range, !range.isEmpty, let tableView, let source else {
            removeHighlights()
            return
        }
        var wanted: [ObjectIdentifier: (field: NSTextField, range: NSRange)] = [:]
        let visible = tableView.rows(in: tableView.visibleRect)
        let lower = max(range.start.item, visible.location)
        let upper = min(range.end.item, NSMaxRange(visible) - 1)
        if lower <= upper {
            for item in lower...upper {
                guard let host = source.materializedHost(ofItem: item) else { continue }
                let segments = TranscriptTextSegments.collect(in: host, relativeTo: tableView)
                for (index, segment) in segments.enumerated() {
                    let length = segment.field.attributedStringValue.length
                    guard let covered = range.range(inItem: item, segment: index, length: length) else {
                        continue
                    }
                    wanted[ObjectIdentifier(segment.field)] = (segment.field, covered)
                }
            }
        }
        // Kept only when it is the same label covering the same part: an identifier can outlive
        // the label it was taken from and be handed to the next one AppKit builds.
        for (key, highlight) in highlights {
            if let target = wanted[key], target.field === highlight.field, target.range == highlight.range {
                continue
            }
            restore(highlight)
            highlights[key] = nil
        }
        for (key, target) in wanted where highlights[key] == nil {
            paint(target.field, range: target.range)
        }
    }

    private func paint(_ field: NSTextField, range covered: NSRange) {
        let key = ObjectIdentifier(field)
        if let existing = highlights[key] { restore(existing) }
        let original = field.attributedStringValue
        let marked = NSMutableAttributedString(attributedString: original)
        marked.addAttributes(ThemedTextSelection.attributes(over: field), range: covered)
        field.attributedStringValue = marked
        highlights[key] = Highlight(field: field, range: covered, original: original, applied: marked)
    }

    private func removeHighlights() {
        for highlight in highlights.values { restore(highlight) }
        highlights.removeAll()
    }

    /// Gives a label back its text — unless something has set new text since the highlight was
    /// painted, which is then the text to keep.
    private func restore(_ highlight: Highlight) {
        guard let field = highlight.field,
              field.attributedStringValue.isEqual(to: highlight.applied) else { return }
        field.attributedStringValue = highlight.original
    }
}

// MARK: - Layout

/// Where a point falls in a label's text, by laying the text out the way the label does.
///
/// The highlight never depends on this — the label paints it into its own runs — only the
/// mapping from the pointer to a character does. Measured against `NSTextFieldCell` over a
/// thousand random paragraphs and widths, a TextKit container as wide as the cell's title rect
/// with AppKit's two-point line-fragment padding broke lines identically in all but one.
///
/// One laid-out label is kept: a drag asks about the same paragraph on every event until it
/// crosses into the next, and a long code block is not worth laying out again per event.
@MainActor
final class TranscriptTextLayout {
    struct Location {
        /// The caret position nearest the point — where a drag puts the end of the range.
        let insertion: Int
        /// The character under the point, if the point is on one — what a link click asks.
        let character: Int?
    }

    private struct Laid {
        weak var field: NSTextField?
        let width: CGFloat
        let length: Int
        let manager: NSLayoutManager
        let container: NSTextContainer
        let storage: NSTextStorage
    }

    private var laid: Laid?

    func location(in field: NSTextField, at point: NSPoint, from view: NSView) -> Location {
        let text = field.attributedStringValue
        guard text.length > 0, let cell = field.cell else { return Location(insertion: 0, character: nil) }

        let local = field.convert(point, from: view)
        let flippedY = field.isFlipped ? local.y : field.bounds.height - local.y
        let title = cell.titleRect(forBounds: field.bounds)
        let (manager, container) = layout(of: field, text: text, cell: cell, width: title.width)

        let inText = NSPoint(x: local.x - title.minX, y: flippedY - title.minY)
        var fraction: CGFloat = 0
        let index = manager.characterIndex(
            for: inText,
            in: container,
            fractionOfDistanceBetweenInsertionPoints: &fraction
        )
        let insertion = min(text.length, index + (fraction > 0.5 ? 1 : 0))

        let glyph = manager.glyphIndexForCharacter(at: index)
        let glyphRect = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        let character = glyphRect.contains(inText) ? index : nil
        return Location(insertion: insertion, character: character)
    }

    /// The highlight changes only colours, so a label of the same width and length lays out the
    /// same; a streamed update or a resize does not, and is laid out again.
    private func layout(
        of field: NSTextField,
        text: NSAttributedString,
        cell: NSCell,
        width: CGFloat
    ) -> (NSLayoutManager, NSTextContainer) {
        if let laid, laid.field === field, laid.width == width, laid.length == text.length {
            return (laid.manager, laid.container)
        }
        let wraps = cell.wraps && field.lineBreakMode != .byClipping
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        let container = NSTextContainer(size: NSSize(
            width: wraps ? width : .greatestFiniteMagnitude,
            height: .greatestFiniteMagnitude
        ))
        container.lineFragmentPadding = TranscriptTextSelectionDefaults.lineFragmentPadding
        container.maximumNumberOfLines = field.maximumNumberOfLines
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        laid = Laid(
            field: field,
            width: width,
            length: text.length,
            manager: manager,
            container: container,
            storage: storage
        )
        return (manager, container)
    }
}

// MARK: - Defaults

enum TranscriptTextSelectionDefaults {
    /// `NSTextFieldCell`'s own inset of text from its title rect — see `TranscriptTextLayout`.
    static let lineFragmentPadding: CGFloat = 2
    /// Two runs whose tops are this close stand on one line: the cells of a table row.
    static let sameLineTolerance: CGFloat = 1
    /// How soon, and how often, a drag held past the viewport's edge scrolls it.
    static let autoscrollDelay: TimeInterval = 0.1
    static let autoscrollPeriod: TimeInterval = 0.05
}
