import AppKit
import NativeDiffAppKit
import NativeDiffCore

/// Threading's theme/default adapter around the package renderer.
///
/// Git loading, staging and app theming stay in the app. The actual line rendering, syntax
/// highlighting, wrapping and sizing live in NativeDiffKit and are shared with the UIKit view.
final class DiffView: DiffAppKitView {
    private let appEvents = AppEventObservations()
    private var observesTheme = false
    private var contextLines: [DiffLine] = []
    private var contextPath: String?
    private var contextMenuSession: AnyObject?

    var onAddContextAttachment: ((ConversationContextAttachment) -> Void)?
    var onRequestComment: ((ConversationContextAttachment, CodeContextPreview?) -> Void)?

    convenience init(lines: [DiffLine], path: String? = nil, wraps: Bool = true) {
        self.init(
            lines: lines,
            path: path,
            configuration: .init(
                displayCap: DiffDefaults.displayCap,
                showsNumbers: false,
                wraps: wraps,
                lineCharacterLimit: GitReviewDefaults.lineCharacterCap,
                numberWidth: GitReviewDefaults.lineNumberWidth,
                gutterWidth: DiffDefaults.gutterWidth,
                verticalInset: 1
            ),
            theme: .threading()
        )
        contextLines = Array(lines.prefix(max(DiffDefaults.displayCap, 0)))
        contextPath = path
        beginObservingTheme()
    }

    convenience init(
        gitLines: [GitDiffLine],
        displayCap: Int,
        path: String? = nil,
        wraps: Bool = true
    ) {
        self.init(
            lines: gitLines,
            path: path,
            configuration: .init(
                displayCap: displayCap,
                showsNumbers: true,
                wraps: wraps,
                lineCharacterLimit: GitReviewDefaults.lineCharacterCap,
                numberWidth: GitReviewDefaults.lineNumberWidth,
                gutterWidth: DiffDefaults.gutterWidth,
                verticalInset: 1
            ),
            theme: .threading()
        )
        contextLines = Array(gitLines.prefix(max(displayCap, 0)))
        contextPath = path
        beginObservingTheme()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard onAddContextAttachment != nil || onRequestComment != nil,
              let index = lineIndex(at: convert(event.locationInWindow, from: nil)),
              let reference = contextAttachment(atDisplayedLine: index),
              let preview = contextPreview(spanningDisplayedLines: index...index) else {
            super.rightMouseDown(with: event)
            return
        }
        presentContextMenu(for: reference, preview: preview, at: event.locationInWindow)
    }

    private func lineIndex(at point: NSPoint) -> Int? {
        arrangedSubviews.enumerated().first { _, row in
            row.frame.contains(point)
        }?.offset
    }

    private func presentContextMenu(
        for reference: ConversationContextAttachment,
        preview: CodeContextPreview,
        at windowPoint: NSPoint
    ) {
        guard contextMenuSession == nil else { return }
        var entries: [ThemedMenuEntry] = []
        if onAddContextAttachment != nil {
            entries.append(.item(ThemedMenuItem(
                title: L10n.string("Add line to chat"),
                onChoose: { [weak self] in self?.onAddContextAttachment?(reference) }
            )))
        }
        if onRequestComment != nil {
            entries.append(.item(ThemedMenuItem(
                title: L10n.string("Comment on line…"),
                onChoose: { [weak self] in self?.onRequestComment?(reference, preview) }
            )))
        }
        contextMenuSession = ThemedMenuPresenter.present(
            ThemedMenuPresentation(entries: entries, minimumWidth: 180),
            from: self,
            anchor: .pointer(windowPoint),
            selectedEntryIndex: nil,
            onChoose: { _, item in item.onChoose?() },
            onDismiss: { [weak self] in self?.contextMenuSession = nil }
        )
    }

    /// The anchor corresponding to a rendered row. Kept as a small test seam because the
    /// package view owns line layout, while Threading owns the durable source locator.
    func contextAttachment(atDisplayedLine index: Int) -> ConversationContextAttachment? {
        guard contextLines.indices.contains(index) else { return nil }
        let line = contextLines[index]
        let number = line.newNumber ?? line.oldNumber
        let path = contextPath ?? L10n.string("Code change")
        let title = number.map { "\(path):\($0)" } ?? path
        return ConversationContextAttachment(
            kind: .reference,
            source: .code,
            title: title,
            excerpt: line.text,
            locator: contextPath,
            lineStart: number,
            lineEnd: number
        )
    }

    func contextPreview(
        spanningDisplayedLines span: ClosedRange<Int>
    ) -> CodeContextPreview? {
        CodeContextPreview.make(
            totalLineCount: contextLines.count,
            target: span
        ) { [contextLines] index in
            let line = contextLines[index]
            return CodeContextPreview.SourceLine(
                number: line.newNumber ?? line.oldNumber,
                change: line.kind.contextPreviewChange,
                text: line.text
            )
        }
    }

    private func beginObservingTheme() {
        guard !observesTheme else { return }
        observesTheme = true
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in
            self?.applyCurrentTheme()
        }
        // The washes are measured against the ground, and in a conversation that ground is the
        // *terminal palette's* background — which moves when the selected session does, with the
        // app theme sitting perfectly still. Without this a diff kept the previous session's
        // tint until something else repainted it.
        appEvents.observe(WindowBackdropDidChange.self) { [weak self] _ in
            self?.applyCurrentTheme()
        }
    }

    /// Re-themes in the view's **own** effective appearance.
    ///
    /// The package freezes each row's wash onto a layer (`.cgColor`), which resolves a dynamic
    /// colour in whatever drawing appearance is ambient — from a notification handler, that is
    /// whatever AppKit last had in hand. Under an adaptive theme that painted the dark
    /// variant's washes into a light window. The text labels resolve at draw and were right
    /// all along, which is what made the slabs read as the theme being broken.
    ///
    /// The same appearance decides what the *ground* resolves to, which is why it is measured
    /// in here rather than passed in from a caller that has no drawing appearance in force.
    private func applyCurrentTheme() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            update(theme: .threading(on: resolvedGround()))
        }
    }

    /// Rows built before the view joined a window froze their washes in the ambient
    /// appearance; both hooks re-resolve them in the appearance the view actually wears.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        applyCurrentTheme()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyCurrentTheme()
    }
}

/// The large-file renderer used inside Git Review.
///
/// `DiffAppKitView` deliberately exposes one AppKit row per diff line. That is a good shape for
/// the short edit cards in a conversation, where each row owns a selectable target, but it made
/// a 400-line review file hundreds of views and thousands of constraints. Opening that file took
/// hundreds of milliseconds; asking the outer automatic-height table to collapse the retained
/// row tree took seconds.
///
/// This surface keeps the same selectable text, syntax colour, wrapping and per-line context
/// actions in one TextKit document. It draws only the visible line washes behind TextKit while a
/// fixed-width monospaced prefix carries the number and gutter. The outer file table is still the
/// virtualization boundary, so offscreen files construct no text surface at all.
final class GitReviewDiffTextView: ThemedTextView {
    private struct RenderedLine {
        let source: GitDiffLine
        let text: String
        let tokens: [DiffSyntaxToken]
    }

    private struct WashRun {
        let kind: GitDiffLine.Kind
        var minY: CGFloat
        var maxY: CGFloat
    }

    private let renderedLines: [RenderedLine]
    private let omittedLineCount: Int
    private let path: String?
    private let wraps: Bool
    private let textSize: Design.CodeTextScale
    private let appEvents = AppEventObservations()
    private var lineRanges: [NSRange] = []
    private var washRuns: [WashRun] = []
    private var addedWash = NSColor.clear
    private var removedWash = NSColor.clear
    private var diffInk = Design.Diff.on(Design.Surface.ground)
    private var fittedWidth: CGFloat = 0
    private var measuredContentWidth: CGFloat = 1
    private var measuredHeight: CGFloat = 1
    private var preferredHeightConstraint: NSLayoutConstraint?
    private var heightNotificationPending = false
    private var contextMenuSession: AnyObject?

    var onAddContextAttachment: ((ConversationContextAttachment) -> Void)?
    var onRequestComment: ((ConversationContextAttachment, CodeContextPreview?) -> Void)?
    var onPreferredHeightChange: (() -> Void)?
    private(set) var initialMeasuredSize = NSSize.zero

    init(
        gitLines: [GitDiffLine],
        displayCap: Int,
        path: String? = nil,
        wraps: Bool = true,
        initialLayoutWidth: CGFloat? = nil,
        textSize: Design.CodeTextScale = .standard
    ) {
        let shown = Array(gitLines.prefix(max(displayCap, 0)))
        let capped = shown.map { line in
            GitDiffLine(
                kind: line.kind,
                text: Self.cap(line.text, at: GitReviewDefaults.lineCharacterCap),
                oldNumber: line.oldNumber,
                newNumber: line.newNumber
            )
        }
        let tokens = DiffSyntax.tokens(for: capped, path: path)
        renderedLines = zip(zip(shown, capped), tokens).map { pair, tokens in
            RenderedLine(source: pair.0, text: pair.1.text, tokens: tokens)
        }
        omittedLineCount = max(gitLines.count - shown.count, 0)
        self.path = path
        self.wraps = wraps
        self.textSize = textSize

        super.init(frame: .zero, textContainer: nil)
        translatesAutoresizingMaskIntoConstraints = false
        isEditable = false
        isSelectable = true
        isRichText = true
        importsGraphics = false
        allowsUndo = false
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        // This view publishes one explicit measured-height constraint. Leaving NSTextView's
        // independent vertical autoresizing enabled makes an automatic-height NSTableView add
        // the text view's document growth a second time during its first fitting pass.
        isVerticallyResizable = false
        isHorizontallyResizable = !wraps
        textContainer?.widthTracksTextView = wraps
        textContainer?.heightTracksTextView = false

        applyCurrentTheme()
        let initialWidth = wraps
            ? max(initialLayoutWidth ?? Self.defaultLayoutWidth, 1)
            : Self.noWrapContainerWidth

        // `widthTracksTextView` otherwise replaces the requested container width with this
        // view's zero/bootstrap frame during the first glyph layout. Give TextKit the same
        // width Auto Layout is about to assign so the table never caches that narrow answer.
        if wraps {
            setFrameSize(NSSize(width: initialWidth, height: 0))
        }
        let initialSize = measure(atWidth: initialWidth)
        initialMeasuredSize = initialSize
        let height = heightAnchor.constraint(equalToConstant: initialSize.height)
        // A virtual table first hosts a newly materialized row at its cheap estimate, then
        // replaces that encapsulated height with this measured value on the next run-loop pass.
        // Let the required table frame win during that one provisional pass without reporting
        // a broken constraint; at the real row height there is no competing constraint.
        height.priority = NSLayoutConstraint.Priority(999)
        height.isActive = true
        preferredHeightConstraint = height
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in self?.applyCurrentTheme() }
        appEvents.observe(WindowBackdropDidChange.self) { [weak self] _ in
            self?.applyCurrentTheme()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        return NSSize(
            width: wraps ? NSView.noIntrinsicMetric : measuredContentWidth,
            height: NSView.noIntrinsicMetric
        )
    }

    /// Rebuilds the frozen TextKit attributes and diff washes in this view's own appearance.
    ///
    /// A virtual row is constructed before it joins the pane's window. Resolving the dynamic
    /// theme colours in the ambient appearance at that point can therefore freeze dark washes
    /// into a light window (or the reverse), while TextKit's dynamic foregrounds continue to
    /// follow the window. Re-enter the view's effective appearance when that appearance or the
    /// theme changes.
    private func applyCurrentTheme() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            rebuildDocument()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // Attachment makes the real recorded ground available. Both the wash and the neutral
        // body ink are measured against it, so the attributed document must follow the wash.
        applyCurrentTheme()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyCurrentTheme()
    }

    override func draw(_ dirtyRect: NSRect) {
        drawChangeBackgrounds(in: dirtyRect)
        super.draw(dirtyRect)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let lineIndex = lineIndex(at: convert(event.locationInWindow, from: nil)),
              onAddContextAttachment != nil || onRequestComment != nil else {
            super.rightMouseDown(with: event)
            return
        }
        let span = targetSpan(forClickedLine: lineIndex)
        guard let reference = contextAttachment(spanningDisplayedLines: span),
              let preview = contextPreview(spanningDisplayedLines: span) else { return }
        highlightLines(span)
        presentContextMenu(
            for: reference,
            preview: preview,
            spanning: span,
            at: event.locationInWindow
        )
    }

    private func rebuildDocument() {
        refreshDiffInk()
        let document = NSMutableAttributedString()
        lineRanges.removeAll(keepingCapacity: true)
        lineRanges.reserveCapacity(renderedLines.count)

        for line in renderedLines {
            let startsAt = document.length
            let paragraph = paragraph(for: line, includesTrailingNewline: true)
            document.append(paragraph)
            lineRanges.append(NSRange(location: startsAt, length: paragraph.length))
        }

        if omittedLineCount > 0 {
            let note = NSMutableAttributedString(
                string: "… \(omittedLineCount) more lines",
                attributes: [
                    .font: Design.Typography.code(size: textSize),
                    .foregroundColor: Design.Text.tertiary,
                ]
            )
            document.append(note)
        } else if document.length > 0 {
            // A terminal newline creates an extra caret line in TextKit's used rect. It is useful
            // between paragraphs and nowhere after the final one.
            document.deleteCharacters(in: NSRange(location: document.length - 1, length: 1))
            if let last = lineRanges.indices.last {
                lineRanges[last].length -= 1
            }
        }

        textStorage?.setAttributedString(document)
        needsDisplay = true
        fittedWidth = 0
        if preferredHeightConstraint != nil {
            fit(toWidth: wraps ? max(bounds.width, Self.defaultLayoutWidth) : Self.noWrapContainerWidth)
        }
        invalidateIntrinsicContentSize()
    }

    private func paragraph(
        for line: RenderedLine,
        includesTrailingNewline: Bool
    ) -> NSAttributedString {
        let font = Design.Typography.code(size: textSize)
        let number = line.source.displayNumber.map(String.init) ?? ""
        let numberColumns = max(1, Int((GitReviewDefaults.lineNumberWidth / max(font.maximumAdvancement.width, 1)).rounded(.down)))
        let paddedNumber = String(repeating: " ", count: max(numberColumns - number.count, 0)) + number
        let sign: String = switch line.source.kind {
        case .added: "+"
        case .removed: "−"
        case .context: " "
        }
        let prefix = "\(paddedNumber) \(sign) "
        let value = prefix + (line.text.isEmpty ? " " : line.text)
            + (includesTrailingNewline ? "\n" : "")

        let style = NSMutableParagraphStyle()
        style.lineBreakMode = wraps ? .byCharWrapping : .byClipping
        style.firstLineHeadIndent = 0
        let continuationColumns = min(
            Self.leadingIndentColumns(in: line.text),
            Self.maximumContinuationIndentColumns
        )
        style.headIndent = CGFloat(prefix.count + continuationColumns)
            * font.maximumAdvancement.width
        style.lineSpacing = 2

        let base = textForeground(for: line.source.kind)
        let result = NSMutableAttributedString(string: value, attributes: [
            .font: font,
            .foregroundColor: base,
            .paragraphStyle: style,
        ])

        let numberRange = NSRange(location: 0, length: paddedNumber.utf16.count)
        // Line numbers are navigation, not decoration. Tertiary ink fell below readable
        // contrast on the dark review wash and made unchanged context look disabled.
        result.addAttribute(.foregroundColor, value: Design.Text.secondary, range: numberRange)
        let signLocation = paddedNumber.utf16.count + 1
        result.addAttribute(
            .foregroundColor,
            value: markerForeground(for: line.source.kind),
            range: NSRange(location: signLocation, length: 1)
        )

        let textOffset = prefix.utf16.count
        for token in line.tokens {
            let range = NSRange(token.range, in: line.text)
            result.addAttribute(
                .foregroundColor,
                value: syntaxColor(for: token.role),
                range: NSRange(location: textOffset + range.location, length: range.length)
            )
        }
        return result
    }

    /// Fits the one explicit height constraint to the width Auto Layout actually gave the
    /// review card. The virtual table begins from a model estimate, then caches this exact
    /// TextKit answer for a materialized row and replaces it whenever pane width changes.
    @discardableResult
    func fit(toWidth width: CGFloat) -> Bool {
        let width = wraps ? max(width, 1) : Self.noWrapContainerWidth
        guard abs(width - fittedWidth) > 0.5 else { return false }

        let previousHeight = preferredHeightConstraint?.constant ?? measuredHeight
        let measured = measure(atWidth: width)
        preferredHeightConstraint?.constant = measured.height
        invalidateIntrinsicContentSize()

        let changed = abs(measured.height - previousHeight) > 0.5
        // The table cache is keyed by width as well as height. Even when a resize happens not
        // to add a wrapped line, publish the new measurement so the row replaces its conservative
        // width-derived estimate with the exact value at that width.
        schedulePreferredHeightChange()
        return changed
    }

    private func measure(atWidth width: CGFloat) -> NSSize {
        guard let textContainer, let layoutManager else {
            return NSSize(width: width, height: max(measuredHeight, 1))
        }
        let containerWidth = wraps ? max(width, 1) : Self.noWrapContainerWidth
        if abs(textContainer.containerSize.width - containerWidth) > 0.5 {
            textContainer.containerSize = NSSize(
                width: containerWidth,
                height: CGFloat.greatestFiniteMagnitude
            )
        }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        rebuildWashRuns(using: layoutManager)
        fittedWidth = width
        measuredContentWidth = max(ceil(used.width), 1)
        measuredHeight = max(ceil(used.height), 1)
        return NSSize(width: measuredContentWidth, height: measuredHeight)
    }

    private func schedulePreferredHeightChange() {
        guard !heightNotificationPending else { return }
        heightNotificationPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.heightNotificationPending = false
            self.onPreferredHeightChange?()
        }
    }

    /// Paragraph blocks ask TextKit to recompute a percentage-width background for every line
    /// during every scroll frame. The wash is presentation, not layout: cache its vertical runs
    /// when TextKit lays out at a new width, then paint only runs intersecting the dirty viewport.
    private func drawChangeBackgrounds(in dirtyRect: NSRect) {
        guard !washRuns.isEmpty else { return }
        let originY = textContainerOrigin.y
        let dirtyMinY = dirtyRect.minY - originY
        let dirtyMaxY = dirtyRect.maxY - originY

        var lower = 0
        var upper = washRuns.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if washRuns[middle].maxY < dirtyMinY {
                lower = middle + 1
            } else {
                upper = middle
            }
        }

        for run in washRuns[lower...] {
            if run.minY > dirtyMaxY { break }
            switch run.kind {
            case .added: addedWash.setFill()
            case .removed: removedWash.setFill()
            case .context: continue
            }
            NSGraphicsContext.current?.cgContext.fill(NSRect(
                x: bounds.minX,
                y: run.minY + originY,
                width: bounds.width,
                height: run.maxY - run.minY
            ).intersection(dirtyRect))
        }
    }

    /// Turn the TextKit fragments into a small ordered display list. Adjacent fragments of the
    /// same kind are merged, including the paragraph's line-spacing gap, so a normal added hunk
    /// costs one rectangle per contiguous run rather than one rectangle per visual line.
    private func rebuildWashRuns(using layoutManager: NSLayoutManager) {
        washRuns.removeAll(keepingCapacity: true)
        washRuns.reserveCapacity(renderedLines.count)

        for (index, line) in renderedLines.enumerated() where line.source.kind != .context {
            let characterRange = lineRanges[index]
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: characterRange,
                actualCharacterRange: nil
            )
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) {
                [weak self] lineRect, _, _, _, _ in
                guard let self else { return }
                let minY = lineRect.minY
                // The paragraph owns its 2pt line spacing too. Half on either side makes
                // wrapped and adjacent changed lines read as one continuous wash.
                let maxY = lineRect.maxY + 2
                if var last = self.washRuns.last,
                   last.kind == line.source.kind,
                   minY <= last.maxY + 0.5 {
                    last.maxY = max(last.maxY, maxY)
                    self.washRuns[self.washRuns.count - 1] = last
                } else {
                    self.washRuns.append(WashRun(
                        kind: line.source.kind,
                        minY: minY,
                        maxY: maxY
                    ))
                }
            }
        }
    }

    private func refreshDiffInk() {
        diffInk = Design.Diff.on(resolvedGround())
        addedWash = diffInk.addedWash
        removedWash = diffInk.removedWash
    }

    var washColorsForTesting: (added: NSColor, removed: NSColor) {
        (addedWash, removedWash)
    }

    var inkColorsForTesting: (
        addedText: NSColor,
        removedText: NSColor,
        addedMarker: NSColor,
        removedMarker: NSColor
    ) {
        (diffInk.addedText, diffInk.removedText, diffInk.added, diffInk.removed)
    }

    private func lineIndex(at point: NSPoint) -> Int? {
        guard let textContainer, let layoutManager, !lineRanges.isEmpty else { return nil }
        let origin = textContainerOrigin
        let containerPoint = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        guard layoutManager.usedRect(for: textContainer).contains(containerPoint) else { return nil }
        let glyph = layoutManager.glyphIndex(
            for: containerPoint,
            in: textContainer,
            fractionOfDistanceThroughGlyph: nil
        )
        let character = layoutManager.characterIndexForGlyph(at: glyph)
        return lineRanges.firstIndex { NSLocationInRange(character, $0) }
    }

    /// The durable source anchor under one rendered paragraph. Kept at the same seam as
    /// `DiffView.contextAttachment(atDisplayedLine:)` so the compact renderer cannot trade away
    /// exact line actions for speed.
    func contextAttachment(atDisplayedLine index: Int) -> ConversationContextAttachment? {
        contextAttachment(spanningDisplayedLines: index...index)
    }

    /// The same anchor over a run of rendered lines — what a text selection comments on.
    ///
    /// The numbers are the span's first and last displayed line, each preferring its new
    /// number, so a span that ends on a removed line anchors to the closest number the
    /// working copy still has — the single-line rule, applied at both ends.
    func contextAttachment(
        spanningDisplayedLines span: ClosedRange<Int>
    ) -> ConversationContextAttachment? {
        guard span.lowerBound >= 0, span.upperBound < renderedLines.count else { return nil }
        let lines = renderedLines[span].map(\.source)
        let start = lines.first.flatMap { $0.newNumber ?? $0.oldNumber }
        let end = lines.last.flatMap { $0.newNumber ?? $0.oldNumber }
        let titlePath = path ?? L10n.string("Code change")
        let title: String = if let start, let end, end > start {
            "\(titlePath):\(start)-\(end)"
        } else if let start {
            "\(titlePath):\(start)"
        } else {
            titlePath
        }
        return ConversationContextAttachment(
            kind: .reference,
            source: .code,
            title: title,
            excerpt: lines.map(\.text).joined(separator: "\n"),
            locator: path,
            lineStart: start,
            lineEnd: end
        )
    }

    func contextPreview(
        spanningDisplayedLines span: ClosedRange<Int>
    ) -> CodeContextPreview? {
        CodeContextPreview.make(
            totalLineCount: renderedLines.count,
            target: span
        ) { [renderedLines] index in
            let line = renderedLines[index].source
            return CodeContextPreview.SourceLine(
                number: line.newNumber ?? line.oldNumber,
                change: line.kind.contextPreviewChange,
                text: line.text
            )
        }
    }

    /// The lines a context action speaks about: the selection when the click lands inside it —
    /// which is how more than one line is chosen — otherwise the line under the pointer alone.
    func targetSpan(forClickedLine index: Int) -> ClosedRange<Int> {
        guard let selected = selectedLineSpan(), selected.contains(index) else {
            return index...index
        }
        return selected
    }

    private func selectedLineSpan() -> ClosedRange<Int>? {
        let selection = selectedRange()
        guard selection.length > 0 else { return nil }
        let first = lineRanges.firstIndex { NSIntersectionRange(selection, $0).length > 0 }
        let last = lineRanges.lastIndex { NSIntersectionRange(selection, $0).length > 0 }
        guard let first, let last else { return nil }
        return first...last
    }

    /// Selects the span's whole lines, so what the menu — and the comment sheet after it —
    /// will quote is the run the selection wash is sitting on, not a memory of a pointer
    /// position. A partial selection grows to its line boundaries for the same reason: the
    /// excerpt quotes complete lines.
    func highlightLines(_ span: ClosedRange<Int>) {
        guard lineRanges.indices.contains(span.lowerBound),
              lineRanges.indices.contains(span.upperBound) else { return }
        let start = lineRanges[span.lowerBound].location
        let end = NSMaxRange(lineRanges[span.upperBound])
        setSelectedRange(NSRange(location: start, length: end - start))
    }

    private func presentContextMenu(
        for reference: ConversationContextAttachment,
        preview: CodeContextPreview,
        spanning span: ClosedRange<Int>,
        at windowPoint: NSPoint
    ) {
        guard contextMenuSession == nil else { return }
        let plural = span.count > 1
        var entries: [ThemedMenuEntry] = []
        if onAddContextAttachment != nil {
            entries.append(.item(ThemedMenuItem(
                title: plural
                    ? L10n.string("Add lines to chat")
                    : L10n.string("Add line to chat"),
                onChoose: { [weak self] in self?.onAddContextAttachment?(reference) }
            )))
        }
        if onRequestComment != nil {
            entries.append(.item(ThemedMenuItem(
                title: plural
                    ? L10n.string("Comment on lines…")
                    : L10n.string("Comment on line…"),
                onChoose: { [weak self] in self?.onRequestComment?(reference, preview) }
            )))
        }
        contextMenuSession = ThemedMenuPresenter.present(
            ThemedMenuPresentation(entries: entries, minimumWidth: 180),
            from: self,
            anchor: .pointer(windowPoint),
            selectedEntryIndex: nil,
            onChoose: { _, item in item.onChoose?() },
            onDismiss: { [weak self] in self?.contextMenuSession = nil }
        )
    }

    private func textForeground(for kind: GitDiffLine.Kind) -> NSColor {
        switch kind {
        case .added: diffInk.addedText
        case .removed: diffInk.removedText
        case .context: Design.Text.secondary
        }
    }

    private func markerForeground(for kind: GitDiffLine.Kind) -> NSColor {
        switch kind {
        case .added: diffInk.added
        case .removed: diffInk.removed
        case .context: Design.Text.secondary
        }
    }

    private func syntaxColor(for role: DiffSyntaxRole) -> NSColor {
        switch role {
        case .keyword: Design.Syntax.keyword
        case .type: Design.Syntax.type
        case .string: Design.Syntax.string
        case .number: Design.Syntax.number
        // Comments are deliberately hue-free in the design grammar. Using the palette's raw
        // syntax role here let an authored near-black comment land on a dark context row;
        // semantic secondary ink keeps the annotation quiet without making it disappear.
        case .comment: Design.Text.secondary
        }
    }

    private static func cap(_ text: String, at limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }

    private static func leadingIndentColumns(in text: String) -> Int {
        var columns = 0
        for character in text {
            switch character {
            case " ": columns += 1
            case "\t": columns += 4
            default: return columns
            }
        }
        return columns
    }

    private static let defaultLayoutWidth: CGFloat = 240
    private static let maximumContinuationIndentColumns = 16
    private static let noWrapContainerWidth: CGFloat = 1_000_000
}

private extension GitDiffLine.Kind {
    var contextPreviewChange: CodeContextPreview.Change {
        switch self {
        case .context: .context
        case .added: .added
        case .removed: .removed
        }
    }
}

@MainActor
private extension DiffAppKitTheme {

    /// The renderer's theme, with every colour that depends on the ground resolved against the
    /// one this diff is actually drawn on — see `Design.Diff.on(_:)`.
    static func threading(on ground: NSColor = Design.Surface.ground) -> DiffAppKitTheme {
        let diff = Design.Diff.on(ground)

        return DiffAppKitTheme(
            font: Design.Typography.code(),
            label: Design.Text.label,
            secondaryLabel: Design.Text.secondary,
            tertiaryLabel: Design.Text.tertiary,
            // NativeDiffKit v0.1 has one changed-line colour for both the sign and the body.
            // Prefer the body — the semantic wash and the +/− shape still carry the change.
            added: diff.addedText,
            removed: diff.removedText,
            addedBackground: diff.addedWash,
            removedBackground: diff.removedWash,
            syntaxKeyword: Design.Syntax.keyword,
            syntaxType: Design.Syntax.type,
            syntaxString: Design.Syntax.string,
            syntaxNumber: Design.Syntax.number,
            syntaxComment: Design.Text.secondary
        )
    }
}
