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

    /// Fired only for a click, never for the initial state — the pane remembers what the user
    /// chose, not what the auto-expand budget chose for them.
    var onToggle: ((Bool) -> Void)?

    /// The whole file, staged or unstaged in one go.
    var onStageFile: (() -> Void)?

    /// One hunk, by its index into `file.hunks`.
    var onStageHunk: ((Int) -> Void)?

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

    private var canExpand: Bool {
        !file.hunks.isEmpty || isImageComparison
    }

    /// Extensions the compare surface decodes — raster formats. SVG stays out on purpose: it
    /// is text, and its diff says more than a render of it would.
    private static let rasterImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "tif", "bmp", "icns"
    ]

    /// A binary change whose path says raster image — including an untracked one, which the
    /// synthesis left hunkless whether it was sniffed binary or merely over the text cap.
    private var isImageComparison: Bool {
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
    init(file: GitFileDiff, expanded: Bool, staging: GitStaging? = nil, wraps: Bool = true) {
        self.file = file
        self.staging = staging
        self.wraps = wraps
        super.init(frame: .zero)
        setupViews()
        if expanded && canExpand { toggle() }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupViews() {
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
        metaLabel.setContentHuggingPriority(.required, for: .horizontal)

        // Shown rather than hover-revealed: these appear only in the two modes whose whole
        // purpose is moving changes into or out of the index, so in those modes they are what
        // the row is for.
        let stageButton = staging.map {
            Self.makeActionButton($0.action.fileTitle, target: self, action: #selector(stageFileClicked))
        }

        [glyphLabel, nameLabel, directoryLabel, metaLabel, stageButton, chevron, bodyContainer]
            .compactMap { $0 }
            .forEach(addSubview)

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

            metaLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: nameLabel.trailingAnchor,
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
            bodyContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            bodyContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset)
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

        let click = NSClickGestureRecognizer(target: self, action: #selector(headerClicked))
        click.delegate = self
        addGestureRecognizer(click)
    }

    // MARK: - Expansion

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

        isExpanded.toggle()
        bodyContainer.isHidden = !isExpanded
        headerBottom.isActive = !isExpanded
        bodyBottom.isActive = isExpanded

        chevron.image = NSImage(
            systemSymbolName: isExpanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: nil
        )
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
            let diff = DiffView(gitLines: hunk.lines, displayCap: remaining, path: file.path, wraps: wraps)
            addBodyRow(wraps ? diff : Self.horizontallyScrolling(diff))
            remaining -= hunk.lines.count
        }

        if skipped > 0 {
            addBodyRow(makeNote("… \(skipped) more lines in later hunks"))
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
    private static func horizontallyScrolling(_ diff: DiffView) -> NSView {
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
        let counts = NSTextField.label(attributed: countText)
        counts.setContentHuggingPriority(.required, for: .horizontal)

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
        let trailingView: NSView = button ?? counts

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

            counts.leadingAnchor.constraint(
                greaterThanOrEqualTo: label.trailingAnchor,
                constant: Design.Spacing.small
            ),
            counts.centerYAnchor.constraint(equalTo: label.centerYAnchor),

            trailingView.trailingAnchor.constraint(
                equalTo: row.trailingAnchor,
                constant: -Design.Spacing.small
            ),
        ])

        if let button {
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(
                    equalTo: counts.trailingAnchor,
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
    func gestureRecognizer(
        _ recognizer: NSGestureRecognizer,
        shouldAttemptToRecognizeWith event: NSEvent
    ) -> Bool {
        guard let superview else { return true }
        return !(superview.hitTest(superview.convert(event.locationInWindow, from: nil)) is ThemedButton)
    }
}
