import AppKit

enum MarkdownEditorDefaults {
    static let windowSize = NSSize(width: 1_100, height: 740)
    static let minimumSize = NSSize(width: 640, height: 360)
    static let paneMinimum: CGFloat = 240
    static let previewDelay: Duration = .milliseconds(180)
    /// A single long line/block must not bypass the native renderer's page budgets.
    static let maximumPreviewBlockBytes = 32_768
}

/// Complete source remains editable; preview preparation is serialized off-main and stale
/// results are discarded. Native MarkdownView owns the bounded page and its live theme response.
final class MarkdownEditorViewController: NSViewController, NSTextViewDelegate, NSSplitViewDelegate {
    let splitView = ThemedSplitView(frame: NSRect(origin: .zero, size: MarkdownEditorDefaults.windowSize))
    let sourceScroll = ThemedTextView.scrolling()
    let previewScroll = ThemedScrollView()
    private(set) lazy var saveButton = ThemedButton(title: L10n.string("Save"), target: self, action: #selector(saveClicked))
    private let previewDocument = MarkdownEditorPreviewDocument()
    private let previewStatus = NSTextField(labelWithString: "")
    private var previewTask: Task<Void, Never>?
    private var revision = 0
    private(set) var previewPreparationDuration = Duration.zero
    private(set) var previewMountDuration = Duration.zero
    var onChange: ((String) -> Void)?
    var onSave: (() -> Void)?

    var source: String { sourceScroll.textView.string }

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
        editor.textContainerInset = NSSize(width: Design.Spacing.inset, height: Design.Spacing.inset)
        editor.delegate = self
        editor.setAccessibilityLabel(L10n.string("Markdown Source"))
        editor.setAccessibilityIdentifier("markdown-editor.source")
        previewScroll.hasVerticalScroller = true
        previewScroll.documentView = previewDocument
        previewDocument.translatesAutoresizingMaskIntoConstraints = false
        previewDocument.widthAnchor.constraint(equalTo: previewScroll.contentView.widthAnchor).isActive = true
        previewScroll.setAccessibilityLabel(L10n.string("Markdown Preview"))
        previewScroll.setAccessibilityIdentifier("markdown-editor.preview")
        previewStatus.applyFont(.detail())
        previewStatus.textColor = Design.Text.secondary
        previewStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        saveButton.setAccessibilityIdentifier("markdown-editor.save")
        splitView.addArrangedSubview(pane(title: "Source", content: sourceScroll, trailing: [saveButton]))
        splitView.addArrangedSubview(pane(title: "Preview", content: previewScroll, trailing: [previewStatus]))
        splitView.adjustSubviews()
    }

    func setSource(_ text: String) {
        _ = view
        sourceScroll.textView.string = text
        sourceScroll.textView.undoManager?.removeAllActions()
        updatePreview(text, immediately: true)
    }

    func textDidChange(_ notification: Notification) {
        let text = source
        onChange?(text)
        updatePreview(text)
    }

    @objc private func saveClicked() { onSave?() }

    private func pane(title: String, content: NSView, trailing: [NSView] = []) -> NSView {
        let ground = ThemedSurfaceView()
        // NSSplitView owns its direct pane frames; constraints only lay out their contents.
        ground.translatesAutoresizingMaskIntoConstraints = true
        ground.applySurface(fill: Design.Surface.ground, radius: .fixed(0), pattern: .backdrop)
        ground.frame = NSRect(origin: .zero, size: NSSize(
            width: (MarkdownEditorDefaults.windowSize.width - splitView.dividerThickness) / 2,
            height: MarkdownEditorDefaults.windowSize.height
        ))
        let label = NSTextField(labelWithString: L10n.string(title))
        label.applyFont(.body)
        label.textColor = Design.Text.label
        let header = PaneHeaderView(leading: [label], trailing: trailing, margin: .paneEdge)
        content.translatesAutoresizingMaskIntoConstraints = false
        ground.addSubview(header)
        ground.addSubview(content)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: ground.topAnchor),
            header.leadingAnchor.constraint(equalTo: ground.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: ground.trailingAnchor),
            content.topAnchor.constraint(equalTo: header.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: ground.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: ground.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: ground.bottomAnchor)
        ])
        return ground
    }

    private func updatePreview(_ text: String, immediately: Bool = false) {
        revision += 1
        let requestedRevision = revision
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            if !immediately {
                do { try await Task.sleep(for: MarkdownEditorDefaults.previewDelay) }
                catch { return }
            }
            let prepared = await MarkdownEditorPreviewWorker.shared.prepare(text)
            guard !Task.isCancelled, let self, revision == requestedRevision else { return }
            previewPreparationDuration = prepared.duration
            let mountStarted = ContinuousClock.now
            if let pages = prepared.pages {
                previewDocument.install(MarkdownView(preparedPages: pages))
                previewStatus.stringValue = ""
            } else {
                let explanation = prepared.documentTooLarge
                    ? L10n.string("Preview is paused because the document exceeds 1 MB. Your source is kept in full.")
                    : L10n.string("Preview is paused because a Markdown block exceeds 32 KB. Your source is kept in full.")
                let message = NSTextField(wrappingLabelWithString: explanation)
                message.applyFont(.body)
                message.textColor = Design.Text.secondary
                previewDocument.install(message)
                previewStatus.stringValue = L10n.string("Preview paused")
            }
            previewMountDuration = mountStarted.duration(to: .now)
        }
    }

    /// Deterministic evidence waits for the production preparation rather than adding a renderer.
    func waitForPreview() async { await previewTask?.value }
}

private actor MarkdownEditorPreviewWorker {
    static let shared = MarkdownEditorPreviewWorker()

    func prepare(_ text: String) -> (pages: [[String]]?, documentTooLarge: Bool, duration: Duration) {
        let started = ContinuousClock.now
        let documentTooLarge = text.utf8.count > MarkdownEditorFileStore.maximumBytes
        guard !documentTooLarge else { return (nil, true, started.duration(to: .now)) }
        let pages = sourcePages(text)
        return (pages, false, started.duration(to: .now))
    }

    private func sourcePages(_ text: String) -> [[String]]? {
        guard !Task.isCancelled else { return nil }
        let pages = MarkdownView.preparePages(text)
        guard !Task.isCancelled,
              pages.allSatisfy({ $0.allSatisfy { $0.utf8.count <= MarkdownEditorDefaults.maximumPreviewBlockBytes } }) else {
            return nil
        }
        return pages
    }
}

private final class MarkdownEditorPreviewDocument: NSView {
    override var isFlipped: Bool { true }

    func install(_ content: NSView) {
        let scrollOrigin = enclosingScrollView?.contentView.bounds.origin ?? .zero
        subviews.forEach { $0.removeFromSuperview() }
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.inset),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Spacing.inset),
            content.topAnchor.constraint(equalTo: topAnchor, constant: Design.Spacing.inset),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Design.Spacing.inset)
        ])
        layoutSubtreeIfNeeded()
        enclosingScrollView?.contentView.scroll(to: scrollOrigin)
    }
}
