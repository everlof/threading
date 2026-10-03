import AppKit

enum MarkdownEditorDefaults {
    static let windowSize = NSSize(width: 1_100, height: 740)
    static let minimumSize = NSSize(width: 640, height: 360)
    static let paneMinimum: CGFloat = 240
    static let previewDelay: Duration = .milliseconds(180)
    /// A single long line/block must not bypass the native renderer's page budgets.
    static let maximumPreviewBlockBytes = 32_768
    /// Both panes set their first line the same distance below the band: a page margin, not a
    /// field's inset.
    static let documentInset = Design.Spacing.large
    /// Monospaced source is read line by line; this keeps adjacent lines from merging.
    static let sourceLineSpacing = Design.Spacing.tight
    /// Rendered prose stops growing at a readable measure and the spare width becomes margin.
    static let previewMeasure = Design.Size.readableWidth
    /// The platform's document keys, which a Markdown window claims while it is key. One table
    /// drives both the editor's dispatch and what the File menu shows; the main window's own
    /// commands on these chords get them back when the editor stops being key.
    static let documentShortcuts: [String: KeyboardShortcut] = [
        AppCommands.ID.newMarkdown: KeyboardShortcut(key: "n", modifiers: .command),
        AppCommands.ID.openMarkdown: KeyboardShortcut(key: "o", modifiers: .command),
        AppCommands.ID.closeMarkdown: KeyboardShortcut(key: "w", modifiers: .command),
        AppCommands.ID.saveMarkdown: KeyboardShortcut(key: "s", modifiers: .command),
        AppCommands.ID.saveMarkdownAs: KeyboardShortcut(key: "s", modifiers: [.command, .shift])
    ]
}

/// Complete source remains editable; preview preparation is serialized off-main and stale
/// results are discarded. Native MarkdownView owns the bounded page and its live theme response.
final class MarkdownEditorViewController: NSViewController, NSTextViewDelegate, NSSplitViewDelegate {
    let splitView = ThemedSplitView(frame: NSRect(origin: .zero, size: MarkdownEditorDefaults.windowSize))
    let sourceScroll = ThemedTextView.scrolling()
    let previewScroll = ThemedScrollView()
    private(set) lazy var saveButton: ThemedButton = {
        let button = ThemedButton(title: L10n.string("Save"), target: self, action: #selector(saveClicked))
        // Quiet until relevant: the title is the band's trailing ink, and a plate appears under
        // the pointer rather than standing against the divider at rest.
        button.emphasis = .tertiary
        return button
    }()
    let highlighter = MarkdownSourceHighlighter()
    private let previewDocument = MarkdownEditorPreviewDocument()
    /// A standing condition about the document — it changed or vanished on disk — pushed into
    /// the source pane between its band and the text rather than drawn over either.
    private let noticeSlot = NSStackView()
    private let previewStatus = NSTextField(labelWithString: "")
    let wordCount = NSTextField(labelWithString: "")
    private var previewTask: Task<Void, Never>?
    private var revision = 0
    private(set) var displayedPage: Int?
    private(set) var previewPreparationDuration = Duration.zero
    private(set) var previewMountDuration = Duration.zero
    var onChange: ((String) -> Void)?
    var onSave: (() -> Void)?

    var source: String { sourceScroll.textView.string }
    var renderedPreview: MarkdownView? { previewDocument.subviews.first as? MarkdownView }

    init() {
        super.init(nibName: nil, bundle: nil)
        view = splitView
        splitView.delegate = self
        setupEditor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, MarkdownEditorDefaults.paneMinimum)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, splitView.bounds.width - splitView.dividerThickness - MarkdownEditorDefaults.paneMinimum)
    }

    private func setupEditor() {
        sourceScroll.fillsViewport = true
        let editor = sourceScroll.textView
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.applyFont(.code())
        let inset = MarkdownEditorDefaults.documentInset
        editor.textContainerInset = NSSize(width: inset - (editor.textContainer?.lineFragmentPadding ?? 0), height: inset)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = MarkdownEditorDefaults.sourceLineSpacing
        editor.defaultParagraphStyle = paragraph
        editor.typingAttributes[.paragraphStyle] = paragraph
        editor.textStorage?.delegate = highlighter
        editor.delegate = self
        editor.setAccessibilityLabel(L10n.string("Markdown Source"))
        editor.setAccessibilityIdentifier("markdown-editor.source")
        previewScroll.hasVerticalScroller = true
        previewScroll.autohidesScrollers = true
        previewScroll.documentView = previewDocument
        previewDocument.translatesAutoresizingMaskIntoConstraints = false
        previewDocument.widthAnchor.constraint(equalTo: previewScroll.contentView.widthAnchor).isActive = true
        previewScroll.setAccessibilityLabel(L10n.string("Markdown Preview"))
        previewScroll.setAccessibilityIdentifier("markdown-editor.preview")
        for label in [previewStatus, wordCount] {
            label.applyFont(.numericDetail())
            label.textColor = Design.Text.tertiary
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        wordCount.setAccessibilityIdentifier("markdown-editor.word-count")
        saveButton.setAccessibilityIdentifier("markdown-editor.save")
        noticeSlot.orientation = .vertical
        noticeSlot.spacing = 0
        splitView.addArrangedSubview(pane(title: "Source", content: sourceScroll, trailing: [wordCount, saveButton], notices: noticeSlot))
        splitView.addArrangedSubview(pane(title: "Preview", content: previewScroll, trailing: [previewStatus]))
        splitView.adjustSubviews()
    }

    func setSource(_ text: String) {
        _ = view
        let editor = sourceScroll.textView
        editor.string = text
        if let storage = editor.textStorage, let paragraph = editor.defaultParagraphStyle {
            storage.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: storage.length))
        }
        // Assigning `string` leaves the caret after the last character. An opened document
        // starts where it is read from, and the preview's page follows the caret.
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.scrollRangeToVisible(NSRange(location: 0, length: 0))
        editor.undoManager?.removeAllActions()
        updatePreview(text, immediately: true)
    }

    /// Replaces the source with `text` as one undoable edit of only the span that differs, so
    /// the caret, selection and scroll position stay with the text around them and Undo brings
    /// back what was replaced.
    func replaceSource(with text: String, actionName: String) {
        let editor = sourceScroll.textView
        guard let storage = editor.textStorage else { return }
        let old = storage.mutableString
        let new = text as NSString
        let limit = min(old.length, new.length)
        var prefix = 0
        while prefix < limit, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < limit - prefix,
              old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) {
            suffix += 1
        }
        let range = NSRange(location: prefix, length: old.length - prefix - suffix)
        let replacement = new.substring(with: NSRange(location: prefix, length: new.length - prefix - suffix))
        guard range.length > 0 || !replacement.isEmpty else { return }
        // Its own group, so Undo takes back the replacement and not the typing before it.
        editor.breakUndoCoalescing()
        let undo = editor.undoManager
        undo?.beginUndoGrouping()
        defer {
            undo?.setActionName(actionName)
            undo?.endUndoGrouping()
        }
        guard editor.shouldChangeText(in: range, replacementString: replacement) else { return }
        storage.replaceCharacters(in: range, with: replacement)
        editor.didChangeText()
    }

    func showNotice(_ notice: PaneNoticeView?) {
        for view in noticeSlot.arrangedSubviews {
            noticeSlot.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        guard let notice else { return }
        noticeSlot.addArrangedSubview(notice)
        notice.leadingAnchor.constraint(equalTo: noticeSlot.leadingAnchor).isActive = true
        notice.trailingAnchor.constraint(equalTo: noticeSlot.trailingAnchor).isActive = true
    }

    var notice: PaneNoticeView? { noticeSlot.arrangedSubviews.first as? PaneNoticeView }

    func textDidChange(_ notification: Notification) {
        let text = source
        onChange?(text)
        updatePreview(text)
    }

    @objc private func saveClicked() { onSave?() }

    private func pane(title: String, content: NSView, trailing: [NSView] = [], notices: NSStackView? = nil) -> NSView {
        let ground = ThemedSurfaceView()
        // NSSplitView owns its direct pane frames; constraints only lay out their contents.
        ground.translatesAutoresizingMaskIntoConstraints = true
        ground.applySurface(fill: Design.Surface.ground, radius: .fixed(0), pattern: .backdrop)
        ground.frame = NSRect(origin: .zero, size: NSSize(
            width: (MarkdownEditorDefaults.windowSize.width - splitView.dividerThickness) / 2,
            height: MarkdownEditorDefaults.windowSize.height
        ))
        let label = NSTextField(labelWithString: L10n.string(title))
        label.applyFont(.caption)
        label.textColor = Design.Text.secondary
        let header = PaneHeaderView(leading: [label], trailing: trailing, margin: .paneEdge)
        content.translatesAutoresizingMaskIntoConstraints = false
        ground.addSubview(header)
        ground.addSubview(content)
        var top = header.bottomAnchor
        if let notices {
            notices.translatesAutoresizingMaskIntoConstraints = false
            ground.addSubview(notices)
            // Nothing to say is no band at all.
            let collapsed = notices.heightAnchor.constraint(equalToConstant: 0)
            collapsed.priority = .defaultLow
            NSLayoutConstraint.activate([
                notices.topAnchor.constraint(equalTo: header.bottomAnchor),
                notices.leadingAnchor.constraint(equalTo: ground.leadingAnchor),
                notices.trailingAnchor.constraint(equalTo: ground.trailingAnchor),
                collapsed
            ])
            top = notices.bottomAnchor
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: ground.topAnchor),
            header.leadingAnchor.constraint(equalTo: ground.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: ground.trailingAnchor),
            content.topAnchor.constraint(equalTo: top),
            content.leadingAnchor.constraint(equalTo: ground.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: ground.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: ground.bottomAnchor)
        ])
        return ground
    }

    private func updatePreview(_ text: String, immediately: Bool = false) {
        revision += 1
        let requestedRevision = revision
        let caret = sourceScroll.textView.selectedRange().location
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            if !immediately {
                do { try await Task.sleep(for: MarkdownEditorDefaults.previewDelay) }
                catch { return }
            }
            let prepared = await MarkdownEditorPreviewWorker.shared.prepare(text, caret: caret)
            guard !Task.isCancelled, let self, revision == requestedRevision else { return }
            previewPreparationDuration = prepared.duration
            let mountStarted = ContinuousClock.now
            wordCount.stringValue = prepared.words == 1
                ? L10n.string("1 word")
                : L10n.format("%lld words", Int64(prepared.words))
            if let pages = prepared.pages, pages.contains(where: { !$0.isEmpty }) {
                // The page holding the caret follows the edit; the reader's own scroll position
                // within it survives each keystroke.
                previewDocument.install(
                    MarkdownView(preparedPages: pages, initialPage: prepared.page, presentation: .document),
                    keepingScrollPosition: prepared.page == displayedPage
                )
                displayedPage = prepared.page
                previewStatus.stringValue = ""
            } else if prepared.pages != nil {
                previewDocument.install(note(L10n.string("Start writing to see the preview.")), keepingScrollPosition: false)
                displayedPage = nil
                previewStatus.stringValue = ""
            } else {
                let explanation = prepared.documentTooLarge
                    ? L10n.string("Preview is paused because the document exceeds 1 MB. Your source is kept in full.")
                    : L10n.string("Preview is paused because a Markdown block exceeds 32 KB. Your source is kept in full.")
                previewDocument.install(note(explanation), keepingScrollPosition: false)
                displayedPage = nil
                previewStatus.stringValue = L10n.string("Preview paused")
            }
            previewMountDuration = mountStarted.duration(to: .now)
        }
    }

    private func note(_ text: String) -> NSTextField {
        let message = NSTextField(wrappingLabelWithString: text)
        message.applyFont(.body)
        message.textColor = Design.Text.tertiary
        return message
    }

    /// Deterministic evidence waits for the production preparation rather than adding a renderer.
    func waitForPreview() async { await previewTask?.value }
}

private actor MarkdownEditorPreviewWorker {
    static let shared = MarkdownEditorPreviewWorker()

    struct Prepared: Sendable {
        let pages: [[String]]?
        let page: Int
        let words: Int
        let documentTooLarge: Bool
        let duration: Duration
    }

    func prepare(_ text: String, caret: Int) -> Prepared {
        let started = ContinuousClock.now
        let words = Self.wordCount(text)
        let documentTooLarge = text.utf8.count > MarkdownEditorFileStore.maximumBytes
        guard !documentTooLarge, !Task.isCancelled else {
            return Prepared(pages: nil, page: 0, words: words, documentTooLarge: documentTooLarge, duration: started.duration(to: .now))
        }
        let planned = MarkdownView.preparePages(text, showingLine: Self.line(of: caret, in: text))
        let fits = planned.pages.allSatisfy { $0.allSatisfy { $0.utf8.count <= MarkdownEditorDefaults.maximumPreviewBlockBytes } }
        return Prepared(
            pages: !Task.isCancelled && fits ? planned.pages : nil,
            page: planned.page, words: words, documentTooLarge: false,
            duration: started.duration(to: .now)
        )
    }

    /// The zero-based source line holding a UTF-16 caret offset, which is what AppKit reports.
    static func line(of caret: Int, in text: String) -> Int {
        var line = 0
        for unit in text.utf16.prefix(caret) where unit == 0x0A { line += 1 }
        return line
    }

    /// Runs of non-space text holding at least one letter or digit, so Markdown's own marks —
    /// `#`, `-`, `|`, fences, rules — are not counted as words.
    static func wordCount(_ text: String) -> Int {
        var count = 0
        var inRun = false
        var runHasWord = false
        for byte in text.utf8 {
            let isSpace = byte == 0x20 || byte == 0x0A || byte == 0x09 || byte == 0x0D
            if isSpace {
                if inRun, runHasWord { count += 1 }
                inRun = false
                runHasWord = false
                continue
            }
            inRun = true
            // A byte at or above 0x80 belongs to a non-ASCII scalar, which in prose is a letter.
            if byte >= 0x80 || (byte >= 0x30 && byte <= 0x39) || ((byte | 0x20) >= 0x61 && (byte | 0x20) <= 0x7A) {
                runHasWord = true
            }
        }
        if inRun, runHasWord { count += 1 }
        return count
    }
}

private final class MarkdownEditorPreviewDocument: NSView {
    override var isFlipped: Bool { true }

    func install(_ content: NSView, keepingScrollPosition: Bool) {
        let scrollOrigin = enclosingScrollView?.contentView.bounds.origin ?? .zero
        subviews.forEach { $0.removeFromSuperview() }
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        let inset = MarkdownEditorDefaults.documentInset
        // Centred at a readable measure; a narrower pane gives up margin before the text does.
        let fill = content.widthAnchor.constraint(equalTo: widthAnchor, constant: -2 * inset)
        fill.priority = .defaultHigh
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: centerXAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: inset),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: MarkdownEditorDefaults.previewMeasure),
            fill,
            content.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset)
        ])
        layoutSubtreeIfNeeded()
        guard let scroll = enclosingScrollView else { return }
        scroll.contentView.scroll(to: keepingScrollPosition ? scrollOrigin : .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}
