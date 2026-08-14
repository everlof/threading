import AppKit
import NativeDiffCore

/// One changed file in the review pane: a collapsible section whose header names the file and
/// its `+/−` weight, and whose body is the diff itself.
///
/// The body is built on first expand, not up front — a branch diff can carry thousands of
/// lines across dozens of files, and a collapsed row costing one header is what keeps the
/// pane's view count bounded. This is `ToolCallView`'s collapse pattern (the swapped bottom
/// constraint), applied to a file instead of a tool call.
final class GitReviewFileRow: NSView {

    // MARK: - Properties

    private let file: GitFileDiff

    /// Which way this row's diff moves the index, or nil in the read-only modes. It is the
    /// mode that decides: only a diff whose baseline *is* the index can be applied to it.
    private let staging: GitStaging?

    /// Whether the diff wraps to the pane or runs off it into a horizontal scroller.
    private let wraps: Bool
    private let textSize: Design.CodeTextScale
    private let initialDiffWidth: CGFloat?
    private let defersExpandedBody: Bool
    private let contentIsPending: Bool
    private let contentLoadFailed: Bool

    /// Where this file lives, when it still does. See `init`.
    private let fileURL: URL?

    /// Fired only for a click, never for the initial state — the pane remembers what the user
    /// chose, not the row's default-expanded state.
    var onToggle: ((Bool) -> Void)?

    /// Gives the virtual table the target state before hidden-body constraints change. It can
    /// swap the collapsed height for its expanded estimate first, avoiding one compressed
    /// AppKit layout pass on a large or multi-hunk body.
    var onWillToggle: ((Bool) -> Void)?

    /// A reusable table needs an explicit invalidation when this view changes its fitted height.
    /// A stack observes the constraint change directly; the virtual table caches it by path.
    var onHeightChange: (() -> Void)?

    /// The whole file, staged or unstaged in one go.
    var onStageFile: (() -> Void)?

    /// One hunk, by its index into `file.hunks`.
    var onStageHunk: ((Int) -> Void)?

    /// Provider-neutral chat context. Assignments also reach a body built during `init` for a
    /// row restored expanded, matching the image-provider handoff below.
    var onAddContextAttachment: ((ConversationContextAttachment) -> Void)? {
        didSet { wireContextDiffs() }
    }
    var onRequestContextComment: ((ConversationContextAttachment, CodeContextPreview?) -> Void)? {
        didSet { wireContextDiffs() }
    }
    private var contextDiffs: [GitReviewDiffTextView] = []

    /// Fetches the file's bytes at the mode's two endpoints, for an image row's body. Wired by
    /// the pane, which knows the mode and the checkout; the row only knows it has a picture.
    /// Completion arrives on main.
    ///
    /// A row restored expanded builds its body during `init`, before the pane has wired this —
    /// the assignment kicks the fetch that was waiting on it.
    var imagePairProvider: (@MainActor @Sendable (
        GitFileDiff,
        @escaping @MainActor @Sendable (Result<GitEndpointFilePair, GitFailure>) -> Void
    ) -> Void)? {
        didSet {
            guard awaitsImagePairProvider, imagePairProvider != nil else { return }
            awaitsImagePairProvider = false
            fetchImagePair()
        }
    }

    private weak var imageLoadingNote: NSView?
    private var awaitsImagePairProvider = false

    /// The header's pointer-revealed actions — Copy Path and the one-press external open —
    /// which the row's right-click menu already carries invisibly. They appear on hovering the
    /// whole header *line*, the sidebar rows' reveal applied here, and are hidden rather than
    /// merely transparent at rest: `hitTest` does not read `alphaValue`, so an invisible
    /// button would still swallow the header's own click-to-toggle and copy a path nobody
    /// asked for.
    private var copyPathButton: ThemedIconButton?
    private var openExternallyButton: ThemedIconButton?

    /// Resolved on first reveal, never at construction: a virtual table materializes rows
    /// mid-scroll, where even the launcher's cached registry read is not this row's to spend.
    private var hasResolvedExternalOpen = false
    private var externalOpenIsUnavailable = false

    private var isHeaderHovered = false
    private var headerTrackingArea: NSTrackingArea?

    private lazy var chevron: NSImageView = {
        let image = NSImageView()
        image.translatesAutoresizingMaskIntoConstraints = false
        image.image = NSImage(
            systemSymbolName: "chevron.right",
            accessibilityDescription: nil
        )
        image.contentTintColor = Design.Text.quaternary
        image.symbolConfiguration = Design.Symbol.configuration(
            Design.Symbol.chevron,
            weight: .semibold
        )
        image.isHidden = !canExpand
        return image
    }()
    private var headerBottom: NSLayoutConstraint?
    private var bodyBottom: NSLayoutConstraint?

    /// Where the body lands once built. Installed from the start so the constraints exist;
    /// empty and hidden until first expand.
    private lazy var bodyContainer: NSStackView = {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.tight
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.isHidden = true
        return stack
    }()
    private var bodyBuilt = false
    private var isExpanded = false
    /// Holds the row's context menu while it is up; released from its own dismissal.
    private var contextMenuSession: AnyObject?

    private var canExpand: Bool {
        !contentIsPending && Self.isExpandable(file)
    }

    static func isExpandable(_ file: GitFileDiff) -> Bool {
        !file.hunks.isEmpty || isImageComparison(file)
    }

    /// Text is immediately readable; an image comparison still waits for an explicit open,
    /// because doing so fetches and decodes two endpoint blobs rather than revealing loaded data.
    static func expandsByDefault(_ file: GitFileDiff) -> Bool {
        !file.hunks.isEmpty
    }

    /// A cheap pre-materialization height for the table's scrollbar and first layout pass.
    /// Exact TextKit height replaces it as soon as the row enters the viewport. Keeping this
    /// model-only matters: measuring every offscreen file would undo table virtualization, but
    /// a generic 48pt estimate both compresses expanded constraints and makes the scrollbar
    /// grow under the reader as files are discovered.
    static func estimatedTableHeight(
        for file: GitFileDiff,
        expanded: Bool,
        wraps: Bool,
        width: CGFloat,
        textSize: Design.CodeTextScale = .standard
    ) -> CGFloat {
        guard expanded, isExpandable(file) else { return 48 }
        guard !isImageComparison(file) else { return 96 }

        let font = Design.Typography.code(size: textSize)
        let advance = max(font.maximumAdvancement.width, 1)
        let lineHeight = ceil(font.ascender - font.descender + font.leading) + 2
        let numberColumns = max(
            1,
            Int((GitReviewDefaults.lineNumberWidth / advance).rounded(.down))
        )
        let totalColumns = max(Int((max(width, 1) / advance).rounded(.down)), 1)
        let firstLineColumns = max(totalColumns - numberColumns - 3, 1)

        var remaining = GitReviewDefaults.fileDisplayCap
        var visualLines = 0
        var shownHunks = 0
        var skipped = 0
        for hunk in file.hunks {
            guard remaining > 0 else {
                skipped += hunk.lines.count
                continue
            }
            shownHunks += 1
            for line in hunk.lines.prefix(remaining) {
                guard wraps else {
                    visualLines += 1
                    continue
                }
                let length = min(line.text.utf16.count, GitReviewDefaults.lineCharacterCap)
                guard length > firstLineColumns else {
                    visualLines += 1
                    continue
                }
                let indent = min(
                    line.text.prefix { $0 == " " || $0 == "\t" }.count,
                    16
                )
                let continuationColumns = max(firstLineColumns - indent, 1)
                visualLines += 1 + Int(ceil(
                    Double(length - firstLineColumns) / Double(continuationColumns)
                ))
            }
            remaining -= hunk.lines.count
        }

        let hasHunkHeaders = file.hunks.count > 1 || file.change != .untracked
        let hunkHeaderHeight = hasHunkHeaders ? CGFloat(shownHunks) * 27 : 0
        let bodyItemCount = shownHunks * (hasHunkHeaders ? 2 : 1) + (skipped > 0 ? 1 : 0)
        let bodySpacing = CGFloat(max(bodyItemCount - 1, 0)) * Design.Spacing.tight
        let omittedNoteHeight: CGFloat = skipped > 0 ? lineHeight : 0

        // 54pt covers either one- or two-line file header, the header/body gap and card bottom;
        // the final small spacing belongs to `GitReviewVirtualRowHost` below the card.
        return ceil(
            54
                + CGFloat(visualLines) * lineHeight
                + hunkHeaderHeight
                + bodySpacing
                + omittedNoteHeight
                + Design.Spacing.small
        )
    }

    /// A patchless row still knows its exact numstat weight. One visual line per changed line is
    /// intentionally conservative about wrapping but establishes the right order of magnitude
    /// for the document extent; TextKit replaces the visible row with exact geometry later.
    static func estimatedPendingTableHeight(
        for file: GitFileDiff,
        expanded: Bool,
        textSize: Design.CodeTextScale = .standard
    ) -> CGFloat {
        guard expanded else { return 48 }
        let totalLines = file.added + file.removed
        guard totalLines > 0 else { return 48 }
        let font = Design.Typography.code(size: textSize)
        let lineHeight = ceil(font.ascender - font.descender + font.leading) + 2
        let shown = min(totalLines, GitReviewDefaults.fileDisplayCap)
        let omittedHeight: CGFloat = totalLines > shown ? lineHeight + Design.Spacing.tight : 0
        return ceil(
            54
                + CGFloat(shown) * lineHeight
                + 27
                + omittedHeight
                + Design.Spacing.small
        )
    }

    /// Extensions the compare surface decodes — raster formats. SVG stays out on purpose: it
    /// is text, and its diff says more than a render of it would.
    private static let rasterImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "tif", "bmp", "icns"
    ]

    /// A binary change whose path says raster image — including an untracked one, which the
    /// synthesis left hunkless whether it was sniffed binary or merely over the text cap.
    private var isImageComparison: Bool {
        Self.isImageComparison(file)
    }

    private static func isImageComparison(_ file: GitFileDiff) -> Bool {
        guard file.hunks.isEmpty else { return false }
        switch file.change {
        case .binary, .untracked: break
        default: return false
        }
        let ext = (file.path as NSString).pathExtension.lowercased()
        return Self.rasterImageExtensions.contains(ext)
    }

    // MARK: - Initialization

    /// `staging` is nil in the read-only modes, which is most of them — see
    /// `GitStaging.capability(for:)` for why only two of six offer it.
    ///
    /// `fileURL` is what the row can hand to another app. The pane resolves it, because only
    /// the pane knows the checkout the paths in a diff are relative to; nil where there is
    /// nothing on disk to open — a fixture, or a file this comparison deletes.
    init(
        file: GitFileDiff,
        expanded: Bool,
        defersExpandedBody: Bool = false,
        contentIsPending: Bool = false,
        contentLoadFailed: Bool = false,
        staging: GitStaging? = nil,
        wraps: Bool = true,
        textSize: Design.CodeTextScale = .standard,
        initialDiffWidth: CGFloat? = nil,
        fileURL: URL? = nil
    ) {
        self.file = file
        self.staging = staging
        self.wraps = wraps
        self.textSize = textSize
        self.initialDiffWidth = initialDiffWidth
        self.defersExpandedBody = defersExpandedBody
        self.contentIsPending = contentIsPending
        self.contentLoadFailed = contentLoadFailed
        self.fileURL = fileURL
        super.init(frame: .zero)
        setupViews()
        if expanded {
            if canExpand {
                defersExpandedBody ? showSkeletonExpandedState() : toggle()
            } else if contentIsPending, file.added + file.removed > 0 {
                // A pending file's numstat weight already owns its expanded height in the
                // table; the ghost is what keeps that space from reading as an empty card.
                // Without known weight the estimate is a collapsed header, which has no body
                // area for a ghost to stand in.
                showSkeletonExpandedState()
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()

        // AppKit rebuilds tracking on frame changes and scrolls, but not when only a subview
        // moved — and the hover rect ends where the body begins. Compared first so a steady
        // layout pass rebuilds nothing.
        if let headerTrackingArea, headerTrackingArea.rect != headerRegion {
            updateTrackingAreas()
        }

        guard bodyBuilt, isExpanded, bodyContainer.bounds.width > 1 else { return }

        // Make the real card width the source of truth after a pane resize. Each changed text
        // constraint schedules one row-cache update; `fit` is a no-op while width is unchanged.
        contextDiffs.forEach { $0.fit(toWidth: bodyContainer.bounds.width) }
    }

    /// Virtual table rows are constructed before AppKit attaches them to the pane. Every
    /// `applySurface` in that detached tree therefore resolves against the app's ambient
    /// appearance, which may be the opposite of the window the row is about to enter. Repair
    /// the recorded card and hunk surfaces once their actual appearance is known.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            // A table reload can discard the row without reuse and without a pointer exit;
            // a rehosted row must not arrive with its actions already showing.
            setHeaderActionsRevealed(false, animated: false)
            return
        }
        AppThemeRefresh.repaint(self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        AppThemeRefresh.repaint(self)
    }

    // MARK: - Setup

    private func setupViews() {
        if defersExpandedBody {
            setupDeferredViews()
            return
        }
        translatesAutoresizingMaskIntoConstraints = false
        applySurface(fill: Design.Surface.controlResting, radius: .control)

        let glyphLabel = NSTextField(labelWithString: glyph)
        glyphLabel.applyFont(.code(weight: .medium))
        glyphLabel.textColor = Design.Text.secondary
        glyphLabel.alignment = .center
        glyphLabel.translatesAutoresizingMaskIntoConstraints = false

        let nameLabel = NSTextField(labelWithString: fileNameText)
        nameLabel.applyFont(.control)
        nameLabel.textColor = Design.Text.label
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.usesSingleLineMode = true
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameLabel.setAccessibilityIdentifier("git-review.file.name")
        nameLabel.toolTip = pathText
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        let directoryLabel = NSTextField(labelWithString: directoryText)
        directoryLabel.applyFont(.detail())
        directoryLabel.textColor = Design.Text.tertiary
        directoryLabel.lineBreakMode = .byTruncatingMiddle
        directoryLabel.usesSingleLineMode = true
        directoryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        directoryLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        directoryLabel.toolTip = pathText
        directoryLabel.translatesAutoresizingMaskIntoConstraints = false
        directoryLabel.isHidden = directoryText.isEmpty

        let metaLabel = NSTextField.label(attributed: metaText)
        metaLabel.setAccessibilityIdentifier("git-review.file.stats")
        metaLabel.setContentHuggingPriority(.required, for: .horizontal)

        // Shown rather than hover-revealed: these appear only in the two modes whose whole
        // purpose is moving changes into or out of the index, so in those modes they are what
        // the row is for.
        let stageButton = staging.map {
            Self.makeActionButton($0.action.fileTitle, target: self, action: #selector(stageFileClicked))
        }

        makeHoverActions()

        [glyphLabel, nameLabel, directoryLabel, metaLabel, stageButton, chevron, bodyContainer]
            .compactMap { $0 }
            .forEach(addSubview)
        hoverActionButtons.forEach(addSubview)

        let inset = Design.Spacing.small
        let headerContentBottom = directoryText.isEmpty
            ? nameLabel.bottomAnchor
            : directoryLabel.bottomAnchor
        headerBottom = headerContentBottom.constraint(equalTo: bottomAnchor, constant: -inset)
        headerBottom?.isActive = true
        bodyBottom = bodyContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset)

        NSLayoutConstraint.activate([
            glyphLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            glyphLabel.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            glyphLabel.widthAnchor.constraint(equalToConstant: Design.Chat.toolIconWidth),

            nameLabel.leadingAnchor.constraint(equalTo: glyphLabel.trailingAnchor, constant: inset),
            nameLabel.firstBaselineAnchor.constraint(equalTo: glyphLabel.firstBaselineAnchor),

            // The hover actions live in the flexible run between the name and the counters —
            // beside the path, where Codex-style review headers put them — so the space they
            // reserve is space the header was not using, and nothing shifts when they appear.
            metaLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: hoverActionButtons.last?.trailingAnchor
                    ?? nameLabel.trailingAnchor,
                constant: Design.Spacing.small
            ),
            metaLabel.firstBaselineAnchor.constraint(equalTo: glyphLabel.firstBaselineAnchor),

            chevron.leadingAnchor.constraint(
                equalTo: (stageButton ?? metaLabel).trailingAnchor,
                constant: Design.Spacing.small
            ),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            chevron.centerYAnchor.constraint(equalTo: glyphLabel.centerYAnchor),

            bodyContainer.topAnchor.constraint(equalTo: headerContentBottom, constant: inset),
            // The header content owns the card inset; the diff wash itself is full-bleed so its
            // edge aligns with the mode chip and the card above and below it.
            bodyContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            bodyContainer.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])

        if !directoryText.isEmpty {
            NSLayoutConstraint.activate([
                directoryLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
                directoryLabel.trailingAnchor.constraint(
                    lessThanOrEqualTo: metaLabel.leadingAnchor,
                    constant: -Design.Spacing.small
                ),
                directoryLabel.topAnchor.constraint(
                    equalTo: nameLabel.bottomAnchor,
                    constant: Design.Spacing.hairline
                ),
            ])
        }

        if let stageButton {
            NSLayoutConstraint.activate([
                stageButton.leadingAnchor.constraint(equalTo: metaLabel.trailingAnchor, constant: Design.Spacing.small),
                stageButton.centerYAnchor.constraint(equalTo: glyphLabel.centerYAnchor)
            ])
        }

        if let copyPathButton, let openExternallyButton {
            NSLayoutConstraint.activate([
                copyPathButton.leadingAnchor.constraint(
                    equalTo: nameLabel.trailingAnchor,
                    constant: Design.Spacing.small
                ),
                copyPathButton.centerYAnchor.constraint(equalTo: glyphLabel.centerYAnchor),
                openExternallyButton.leadingAnchor.constraint(
                    equalTo: copyPathButton.trailingAnchor,
                    constant: Design.Spacing.hairline
                ),
                openExternallyButton.centerYAnchor.constraint(equalTo: glyphLabel.centerYAnchor)
            ])
        }

        let click = NSClickGestureRecognizer(target: self, action: #selector(headerClicked))
        click.delegate = self
        addGestureRecognizer(click)
    }

    /// The thumb-drag row says which file is passing under the viewport without paying for the
    /// full interactive header. It is replaced before the pointer can interact with the row.
    private func setupDeferredViews() {
        translatesAutoresizingMaskIntoConstraints = false
        applySurface(fill: Design.Surface.controlResting, radius: .control)

        let nameLabel = NSTextField(labelWithString: pathText)
        nameLabel.applyFont(.control)
        nameLabel.textColor = Design.Text.label
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.usesSingleLineMode = true
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        let metaLabel = NSTextField.label(attributed: metaText)
        metaLabel.setContentHuggingPriority(.required, for: .horizontal)

        [nameLabel, metaLabel, bodyContainer].forEach(addSubview)
        let inset = Design.Spacing.small
        headerBottom = nameLabel.bottomAnchor.constraint(
            equalTo: bottomAnchor,
            constant: -inset
        )
        headerBottom?.isActive = true
        bodyBottom = bodyContainer.bottomAnchor.constraint(
            equalTo: bottomAnchor,
            constant: -inset
        )

        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            metaLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: nameLabel.trailingAnchor,
                constant: Design.Spacing.small
            ),
            metaLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            metaLabel.firstBaselineAnchor.constraint(equalTo: nameLabel.firstBaselineAnchor),
            bodyContainer.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: inset),
            bodyContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            bodyContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    // MARK: - Context Menu

    /// A right-click on the file's row: open it where it can be edited, or find it on disk.
    ///
    /// **This is where "open in" earns its keep**, because a review is the one surface in the
    /// app that knows *which line* the user is looking at. The primary click still belongs to
    /// the row's own job — opening and closing the diff — so the way out lives on the gesture
    /// that costs the row nothing.
    ///
    /// Nothing where there is nothing to point at: a file this comparison deletes has no
    /// working copy left, and offering to open it would fail after the menu had promised.
    override func rightMouseDown(with event: NSEvent) {
        if !presentContextMenu(at: .pointer(event.locationInWindow)) {
            super.rightMouseDown(with: event)
        }
    }

    /// The pointerless route to the same menu, hanging from the row itself.
    override func accessibilityPerformShowMenu() -> Bool {
        presentContextMenu(at: .control)
    }

    private func presentContextMenu(at anchor: ThemedMenuAnchor) -> Bool {
        var entries: [ThemedMenuEntry] = []
        let context = fileContextAttachment
        if onAddContextAttachment != nil {
            entries.append(.item(ThemedMenuItem(
                title: L10n.string("Add file to chat"),
                onChoose: { [weak self] in self?.onAddContextAttachment?(context) }
            )))
        }
        if onRequestContextComment != nil {
            entries.append(.item(ThemedMenuItem(
                title: L10n.string("Comment on file…"),
                onChoose: { [weak self] in self?.onRequestContextComment?(context, nil) }
            )))
        }

        if let openInTarget,
           FileManager.default.fileExists(atPath: openInTarget.url.path) {
            if !entries.isEmpty { entries.append(.separator) }
            if let openIn = OpenInMenu.submenuEntry(for: openInTarget) {
                entries.append(openIn)
            }
            entries.append(.item(ThemedMenuItem(
                title: L10n.string("Reveal in Finder"),
                onChoose: { [weak self] in self?.revealInFinderClicked() }
            )))
            entries.append(.separator)
            entries.append(.item(ThemedMenuItem(
                title: L10n.string("Copy Path"),
                onChoose: { [weak self] in self?.copyPathClicked() }
            )))
        }
        guard entries.contains(where: {
            if case .item = $0 { return true }
            return false
        }) else { return false }

        contextMenuSession = ThemedMenuPresenter.present(
            ThemedMenuPresentation(entries: entries, minimumWidth: OpenInMenuDefaults.menuWidth),
            from: self,
            anchor: anchor,
            selectedEntryIndex: nil,
            onChoose: { _, item in item.onChoose?() },
            onDismiss: { [weak self] in self?.contextMenuSession = nil }
        )
        return contextMenuSession != nil
    }

    private var fileContextAttachment: ConversationContextAttachment {
        ConversationContextAttachment(
            kind: .reference,
            source: isImageComparison ? .attachment : .code,
            title: file.path,
            excerpt: L10n.format("Changed file · +%lld −%lld", Int64(file.added), Int64(file.removed)),
            locator: file.path,
            lineStart: firstChangedLine,
            lineEnd: firstChangedLine
        )
    }

    private var firstChangedLine: Int? { Self.firstChangedLine(in: file) }

    /// The editor destination carried by this particular row. Kept as a testable seam because
    /// a reusable table may tear down and reconstruct the view far from where its model began.
    var openInTarget: ExternalAppTarget? {
        fileURL.map { .file($0, line: firstChangedLine) }
    }

    /// The line an editor should land on: the first one this diff actually changes.
    ///
    /// The *new* numbering, because that is the file the user is about to edit — a removed
    /// line's old number points into a version that no longer exists on disk. A hunk of pure
    /// removals therefore lands on the context line beside it, which is the closest thing the
    /// working copy still has to where the change was, and a diff with no numbered line at all
    /// (a binary change, an image) lands nowhere in particular.
    static func firstChangedLine(in file: GitFileDiff) -> Int? {
        for hunk in file.hunks {
            if let changed = hunk.lines.first(where: { $0.kind != .context })?.newNumber {
                return changed
            }
            if let context = hunk.lines.compactMap(\.newNumber).first {
                return context
            }
        }
        return nil
    }

    @objc private func revealInFinderClicked() {
        guard let fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    @objc private func copyPathClicked() {
        guard let fileURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fileURL.path, forType: .string)
    }

    // MARK: - Header Hover Actions

    /// Builds the pointer-revealed pair, or nothing where there is nothing on disk to act on.
    ///
    /// The gate is the *model* — a nil URL, or a change whose whole meaning is that the working
    /// copy is gone — never `FileManager`: the context menu can afford an existence check
    /// because a right-click is a user's own moment, while this runs inside a virtual table
    /// materializing rows mid-scroll, where the scaling gate forbids filesystem work. A file
    /// deleted behind the model's back fails at the press, which beeps rather than promising.
    ///
    /// Deferred glyphs for the same reason the sidebar's are: most rows are never hovered, and
    /// a CoreUI symbol resolve per header is exactly the cost the collapse pattern avoids.
    private func makeHoverActions() {
        guard fileURL != nil, file.change != .deleted else { return }

        let copy = ThemedIconButton(
            symbolName: "doc.on.doc",
            accessibility: L10n.string("Copy Path"),
            target: .inline,
            inkSource: .chrome,
            glyphMaterialization: .deferred
        )
        copy.toolTip = L10n.string("Copy Path")
        copy.onPress = { [weak self] in self?.copyPathClicked() }
        copy.setAccessibilityIdentifier("git-review.file.copy-path")

        let open = ThemedIconButton(
            symbolName: OpenInToolbarDefaults.fallbackSymbol,
            accessibility: L10n.string("Open in external app"),
            target: .inline,
            inkSource: .chrome,
            glyphMaterialization: .deferred
        )
        open.toolTip = L10n.string("Open in external app")
        open.onPress = { [weak self] in self?.openExternallyClicked() }
        open.setAccessibilityIdentifier("git-review.file.open-external")

        for button in [copy, open] {
            button.isHidden = true
            button.alphaValue = 0
        }
        copyPathButton = copy
        openExternallyButton = open
    }

    private var hasHoverActions: Bool { copyPathButton != nil }

    private var hoverActionButtons: [ThemedIconButton] {
        [copyPathButton, openExternallyButton].compactMap { $0 }
    }

    /// What a reveal actually shows — everything, until the first reveal has asked the launcher
    /// which app a press would use and found none. The unavailable button keeps its place in
    /// the constraint chain so the counters' boundary survives; it simply never unhides.
    private var revealableHoverButtons: [ThemedIconButton] {
        hoverActionButtons.filter { !externalOpenIsUnavailable || $0 !== openExternallyButton }
    }

    /// The header line's own rect — everything above the body, gap included. The actions
    /// answer a pointer anywhere on the *line*, not only over their own two targets.
    private var headerRegion: NSRect {
        guard !bodyContainer.isHidden else { return bounds }
        return NSRect(
            x: 0,
            y: bodyContainer.frame.maxY,
            width: bounds.width,
            height: max(bounds.maxY - bodyContainer.frame.maxY, 0)
        )
    }

    /// `NSView.hoverIsStale`, measured against the header's rect rather than `bounds`: a
    /// pointer resting on the open body is not on the line these actions belong to.
    private var headerHoverIsStale: Bool {
        guard isHeaderHovered else { return false }
        guard let window, window.isKeyWindow, !isHiddenOrHasHiddenAncestor else { return true }
        let unclipped = headerRegion.intersection(visibleRect)
        return !unclipped.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let headerTrackingArea {
            removeTrackingArea(headerTrackingArea)
            self.headerTrackingArea = nil
        }
        guard hasHoverActions else { return }
        let area = NSTrackingArea(
            rect: headerRegion,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self
        )
        addTrackingArea(area)
        headerTrackingArea = area

        // The header slides out from under a stationary pointer — a watched refresh, a
        // collapse above it — and no exit is delivered for that; see `NSView.hoverIsStale`.
        if headerHoverIsStale {
            setHeaderActionsRevealed(false, animated: false)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        // Not through whatever floats over the pane — see `NSView.isPointerCovered(at:)`.
        guard hasHoverActions, !isPointerCovered(at: event.locationInWindow) else { return }
        setHeaderActionsRevealed(true, animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        setHeaderActionsRevealed(false, animated: true)
    }

    /// The sidebar rows' reveal, applied to the header line. Hiding waits for the fade out so
    /// a visible button never vanishes mid-frame; revealing unhides first so both targets are
    /// hit-testable for the whole fade in.
    private func setHeaderActionsRevealed(_ revealed: Bool, animated: Bool) {
        isHeaderHovered = revealed
        guard hasHoverActions else { return }
        if revealed { resolveExternalOpenOnFirstReveal() }

        let buttons = revealableHoverButtons
        if revealed {
            buttons.forEach {
                $0.materializeGlyphIfNeeded()
                $0.isHidden = false
            }
        }
        guard animated else {
            buttons.forEach {
                $0.alphaValue = revealed ? 1 : 0
                $0.isHidden = !revealed
            }
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Design.Motion.quick
            buttons.forEach { $0.animator().alphaValue = revealed ? 1 : 0 }
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !revealed, !self.isHeaderHovered else { return }
                self.revealableHoverButtons.forEach { $0.isHidden = true }
            }
        })
    }

    /// Points the open button at the app a press would use — the toolbar's
    /// `updateOpenInControls`, per row, paid on first reveal only. The app's own icon for the
    /// toolbar's reason: the one question the button answers at a glance is "where will this
    /// send me".
    private func resolveExternalOpenOnFirstReveal() {
        guard !hasResolvedExternalOpen else { return }
        hasResolvedExternalOpen = true
        guard let openExternallyButton, let openInTarget else { return }

        let launcher = ExternalAppLauncher.shared
        guard let app = launcher.preferred(for: openInTarget) else {
            // Nothing installed can take the file: a control offering one dead option hides —
            // `OpenInMenu.submenuEntry`'s rule, kept by the reveal instead of the menu.
            externalOpenIsUnavailable = true
            openExternallyButton.isHidden = true
            return
        }
        let title = L10n.format("Open in %@", app.name)
        if let icon = launcher.icon(for: app) {
            openExternallyButton.setImage(icon, accessibility: title)
        } else {
            openExternallyButton.setSymbol(OpenInToolbarDefaults.fallbackSymbol, accessibility: title)
        }
        openExternallyButton.toolTip = title
    }

    /// The one-press open, aimed at the first line this diff changes — the same target the
    /// right-click menu offers, without the submenu. Failure beeps inside the launcher.
    @objc private func openExternallyClicked() {
        guard let openInTarget else { return }
        ExternalAppLauncher.shared.openInPreferredApp(openInTarget)
    }

    // MARK: - Expansion

    /// A scroller-thumb drag can cross hundreds of expanded files per frame, and a pending
    /// file's diff has not arrived at all. Building TextKit for either row is work the moment
    /// cannot spend, so both keep the expanded geometry and disclosure state while the body
    /// holds a `DiffSkeletonView` ghost instead of text — the table replaces the resting
    /// viewport with ordinary rows when the drag ends, and hydration replaces a pending model.
    private func showSkeletonExpandedState() {
        guard let headerBottom, let bodyBottom else { return }
        installSkeletonBody()
        isExpanded = true
        headerBottom.isActive = false
        bodyContainer.isHidden = false
        bodyBottom.isActive = true
        if !defersExpandedBody && canExpand {
            chevron.image = NSImage(
                systemSymbolName: "chevron.down",
                accessibilityDescription: nil
            )
        }
    }

    /// A ghost body has no exact height to report: the skeleton stretches to whatever the
    /// table gave the row, so measuring it would replace the model's honest line-weight
    /// estimate with the header's own fitting height and collapse the document extent.
    var hasEstimatedGhostBody: Bool {
        defersExpandedBody || (contentIsPending && isExpanded)
    }

    /// The ghost the empty body area shows while the real document is deferred (a scroller
    /// seek) or not yet read (progressive hydration). Pinned over the body container rather
    /// than arranged in it, so it takes exactly the space the row's geometry already reserves.
    private func installSkeletonBody() {
        let skeleton = DiffSkeletonView(added: file.added, removed: file.removed)
        bodyContainer.addSubview(skeleton)
        NSLayoutConstraint.activate([
            skeleton.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
            skeleton.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
            skeleton.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
            skeleton.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor)
        ])
    }

    /// Whether this file's diff is currently open — read by "Collapse all" to decide which way
    /// the one action should move every row.
    var isOpen: Bool { isExpanded }

    /// Whether there is anything to open at all (a binary or empty file has no body).
    var canOpen: Bool { canExpand }

    /// Opens or closes to a target, reporting the change through `onToggle` exactly as a click
    /// would, so "Collapse all" is recorded the same way as collapsing each by hand.
    func setExpanded(_ expanded: Bool) {
        guard canExpand, expanded != isExpanded else { return }
        toggle()
        onToggle?(isExpanded)
    }

    @objc private func headerClicked() {
        guard canExpand else { return }
        toggle()
        onToggle?(isExpanded)
    }

    private func toggle() {
        guard let headerBottom, let bodyBottom else { return }
        if !bodyBuilt { buildBody() }

        let targetExpanded = !isExpanded
        onWillToggle?(targetExpanded)
        isExpanded = targetExpanded
        if isExpanded {
            // Remove the collapsed edge before making the body participate in stack layout.
            // Showing it first briefly made both bottom edges required; AppKit recovered by
            // breaking the diff's measured-height constraint, leaving the card malformed.
            headerBottom.isActive = false
            bodyContainer.isHidden = false
            bodyBottom.isActive = true
        } else {
            bodyBottom.isActive = false
            bodyContainer.isHidden = true
            headerBottom.isActive = true
        }

        chevron.image = NSImage(
            systemSymbolName: isExpanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: nil
        )
        onHeightChange?()

        // The header's hover rect ends where the body begins, and the body just moved.
        updateTrackingAreas()
    }

    /// One `DiffView` per hunk with its `@@` header between, spending the file's line budget
    /// in order; whatever the budget cannot cover is summed into one closing note.
    private func buildBody() {
        bodyBuilt = true

        if isImageComparison {
            buildImageBody()
            return
        }

        var remaining = GitReviewDefaults.fileDisplayCap
        var skipped = 0

        for (index, hunk) in file.hunks.enumerated() {
            guard remaining > 0 else {
                skipped += hunk.lines.count
                continue
            }

            if file.hunks.count > 1 || file.change != .untracked {
                addBodyRow(makeHunkHeader(hunk, index: index))
            }
            let diff = GitReviewDiffTextView(
                gitLines: hunk.lines,
                displayCap: remaining,
                path: file.path,
                wraps: wraps,
                initialLayoutWidth: initialDiffWidth,
                textSize: textSize
            )
            contextDiffs.append(diff)
            wireContextDiff(diff)
            diff.onPreferredHeightChange = { [weak self] in self?.onHeightChange?() }
            addBodyRow(wraps ? diff : Self.horizontallyScrolling(diff))
            remaining -= hunk.lines.count
        }

        if skipped > 0 {
            addBodyRow(makeNote("… \(skipped) more lines in later hunks"))
        }
    }

    private func wireContextDiffs() {
        contextDiffs.forEach(wireContextDiff)
    }

    private func wireContextDiff(_ diff: GitReviewDiffTextView) {
        diff.onAddContextAttachment = onAddContextAttachment
        diff.onRequestComment = { [weak self] attachment, preview in
            self?.onRequestContextComment?(attachment, preview)
        }
    }

    /// The compare surface, fed with the file's bytes at the mode's two endpoints. Fetched on
    /// first expand only — the same lazy discipline as the text bodies, and blob reads are
    /// exactly the cost the collapse pattern exists to avoid.
    private func buildImageBody() {
        let loading = makeNote("Loading images…")
        imageLoadingNote = loading
        addBodyRow(loading)

        if imagePairProvider == nil {
            awaitsImagePairProvider = true
        } else {
            fetchImagePair()
        }
    }

    private func fetchImagePair() {
        guard let imagePairProvider else { return }
        imagePairProvider(file) { [weak self] result in
            guard let self else { return }
            defer { self.onHeightChange?() }
            self.imageLoadingNote?.removeFromSuperview()

            switch result {
            case .failure(let failure):
                self.addBodyRow(self.makeNote(failure.localizedDescription))
            case .success(let pair):
                let old = pair.old.flatMap(NSImage.init(data:))
                let new = pair.new.flatMap(NSImage.init(data:))
                guard old != nil || new != nil else {
                    self.addBodyRow(self.makeNote("The image could not be read at either end."))
                    return
                }
                let compare = ImageCompareView(frame: .zero)
                compare.translatesAutoresizingMaskIntoConstraints = false
                compare.configure(
                    old: old.map { .init(image: $0, title: pair.oldTitle) },
                    new: new.map { .init(image: $0, title: pair.newTitle) }
                )
                self.addBodyRow(compare)
                // The stack gives the body width but no height; the surface states the fitted
                // height at the width the row has now, capped like any long file.
                let width = max(self.bounds.width - Design.Spacing.medium * 2, 240)
                compare.heightAnchor.constraint(
                    equalToConstant: compare.preferredHeight(forWidth: width)
                ).isActive = true
            }
        }
    }

    private func addBodyRow(_ view: NSView) {
        bodyContainer.addArrangedSubview(view)
        view.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor).isActive = true
        view.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor).isActive = true
    }

    /// A diff that runs off the pane, put in a horizontal scroller sized to its own height so
    /// the outer vertical scroll still sees the whole thing. Only the diff scrolls sideways —
    /// the header and `@@` rows stay put — which is why each hunk is wrapped, not the pane.
    private static func horizontallyScrolling(_ diff: GitReviewDiffTextView) -> NSView {
        let scroll = ThemedScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        scroll.verticalScrollElasticity = .none
        scroll.documentView = diff

        NSLayoutConstraint.activate([
            diff.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            diff.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            scroll.heightAnchor.constraint(equalTo: diff.heightAnchor)
        ])
        return scroll
    }

    /// The `@@` line, and — where a hunk is a thing the index can be given on its own — the
    /// one control that gives it.
    private func makeHunkHeader(_ hunk: GitHunk, index: Int) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.applySurface(fill: Design.Surface.background, radius: .fixed(0))

        let disclosure = NSImageView()
        disclosure.image = NSImage(
            systemSymbolName: "chevron.down",
            accessibilityDescription: nil
        )
        disclosure.contentTintColor = Design.Text.tertiary
        disclosure.symbolConfiguration = Design.Symbol.configuration(
            Design.Symbol.chevron,
            weight: .semibold
        )
        disclosure.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: DiffPresentation.rangeTitle(for: hunk))
        label.applyFont(.caption)
        label.textColor = Design.Text.secondary
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.toolTip = hunk.header
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // A one-hunk file's counts are already the file counts directly above this row. Repeat
        // them only when several hunks make the per-hunk distribution new information.
        let counts: NSTextField? = file.hunks.count > 1 ? {
            let summary = hunk.summary
            let countText = NSMutableAttributedString()
            countText.append(NSAttributedString(string: "+\(summary.added)", attributes: [
                .foregroundColor: Design.Diff.added,
                .font: Design.Typography.caption(),
            ]))
            countText.append(NSAttributedString(string: " −\(summary.removed)", attributes: [
                .foregroundColor: Design.Diff.removed,
                .font: Design.Typography.caption(),
            ]))
            let label = NSTextField.label(attributed: countText)
            label.setAccessibilityIdentifier("git-review.hunk.stats")
            label.setContentHuggingPriority(.required, for: .horizontal)
            return label
        }() : nil

        let button: ThemedButton?
        if let staging, staging.allowsHunks, GitPatch.supportsHunkStaging(file) {
            let action = Self.makeActionButton(
                staging.action.hunkTitle,
                target: self,
                action: #selector(stageHunkClicked)
            )
            action.tag = index
            button = action
        } else {
            button = nil
        }

        [disclosure, label, counts, button].compactMap { $0 }.forEach(row.addSubview)
        let trailingView: NSView? = button.map { $0 as NSView }
            ?? counts.map { $0 as NSView }

        NSLayoutConstraint.activate([
            disclosure.leadingAnchor.constraint(
                equalTo: row.leadingAnchor,
                constant: Design.Spacing.small
            ),
            disclosure.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            disclosure.widthAnchor.constraint(equalToConstant: 10),

            label.leadingAnchor.constraint(
                equalTo: disclosure.trailingAnchor,
                constant: Design.Spacing.small
            ),
            label.topAnchor.constraint(equalTo: row.topAnchor, constant: Design.Spacing.small),
            label.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -Design.Spacing.small),

            label.trailingAnchor.constraint(
                lessThanOrEqualTo: row.trailingAnchor,
                constant: -Design.Spacing.small
            )
        ])

        if let trailingView {
            trailingView.trailingAnchor.constraint(
                equalTo: row.trailingAnchor,
                constant: -Design.Spacing.small
            ).isActive = true
        }

        if let counts {
            NSLayoutConstraint.activate([
                counts.leadingAnchor.constraint(
                    greaterThanOrEqualTo: label.trailingAnchor,
                    constant: Design.Spacing.small
                ),
                counts.centerYAnchor.constraint(equalTo: label.centerYAnchor)
            ])
        }

        if let button {
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(
                    equalTo: counts?.trailingAnchor ?? label.trailingAnchor,
                    constant: Design.Spacing.small
                ),
                button.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            ])
        }
        return row
    }

    /// A borderless caption-weight control: this is a pane of content, and a bezelled button
    /// per hunk would read as a form.
    private static func makeActionButton(_ title: String, target: AnyObject, action: Selector) -> ThemedButton {
        let button = ThemedButton(title: title, target: target, action: action)
        button.isBordered = false
        button.applyFont(.caption)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    // MARK: - Staging

    @objc private func stageFileClicked() {
        onStageFile?()
    }

    @objc private func stageHunkClicked(_ sender: ThemedButton) {
        onStageHunk?(sender.tag)
    }

    private func makeNote(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.applyFont(.code())
        label.textColor = Design.Text.tertiary
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    // MARK: - Header Content

    /// The tool rows' vocabulary, applied to what happened to a file.
    private var glyph: String {
        switch file.change {
        case .modified, .binary: return "±"
        case .added, .untracked: return "+"
        case .deleted: return "−"
        case .renamed: return "→"
        }
    }

    private var pathText: String {
        if case .renamed(let from) = file.change {
            return "\(from) → \(file.path)"
        }
        return file.path
    }

    private var fileNameText: String {
        if case .renamed(let from) = file.change {
            return "\((from as NSString).lastPathComponent) → \(file.fileName)"
        }
        return file.fileName
    }

    private var directoryText: String {
        file.directory
    }

    /// `+A −R` with each count in its own colour, or what stands in for a body that cannot
    /// be shown.
    private var metaText: NSAttributedString {
        if contentIsPending {
            return NSAttributedString(string: "loading…", attributes: [
                .foregroundColor: Design.Text.quaternary,
                .font: Design.Typography.caption()
            ])
        }
        if contentLoadFailed {
            return NSAttributedString(string: "preview unavailable", attributes: [
                .foregroundColor: Design.Status.negative,
                .font: Design.Typography.caption()
            ])
        }
        if isImageComparison {
            return NSAttributedString(string: "image", attributes: [
                .foregroundColor: Design.Text.tertiary,
                .font: Design.Typography.caption()
            ])
        }
        if file.change == .binary {
            return NSAttributedString(string: "binary", attributes: [
                .foregroundColor: Design.Text.tertiary,
                .font: Design.Typography.caption()
            ])
        }
        if !canExpand {
            return NSAttributedString(string: "no preview", attributes: [
                .foregroundColor: Design.Text.tertiary,
                .font: Design.Typography.caption()
            ])
        }

        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: "+\(file.added)", attributes: [
            .foregroundColor: Design.Diff.added,
            .font: Design.Typography.caption()
        ]))
        text.append(NSAttributedString(string: " −\(file.removed)", attributes: [
            .foregroundColor: Design.Diff.removed,
            .font: Design.Typography.caption()
        ]))
        return text
    }
}

// MARK: - Gesture Delegate

extension GitReviewFileRow: NSGestureRecognizerDelegate {

    /// A click that lands on a control belongs to the control. Without this the row's own
    /// recognizer sees it too, and pressing Stage would collapse the file out from under the
    /// pointer at the same moment.
    ///
    /// The body is excluded the same way: it is a selectable text surface carrying its own
    /// line actions, and a click that placed a caret *also* collapsed the card — the table
    /// re-laid hundreds of points of rows and the pane leapt under the pointer. Only the
    /// header row is the toggle.
    func gestureRecognizer(
        _ recognizer: NSGestureRecognizer,
        shouldAttemptToRecognizeWith event: NSEvent
    ) -> Bool {
        if !bodyContainer.isHidden,
           bodyContainer.frame.contains(convert(event.locationInWindow, from: nil)) {
            return false
        }
        guard let superview else { return true }

        // Walked up from the deepest hit rather than type-checked once: an icon button answers
        // a hit with the glyph view inside it, which is a plain NSView — the control the click
        // belongs to is its ancestor.
        var hit = superview.hitTest(superview.convert(event.locationInWindow, from: nil))
        while let view = hit, view !== self, view !== superview {
            if view is ThemedControl { return false }
            hit = view.superview
        }
        return true
    }
}
