import AppKit

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

    private var chevron: NSImageView!
    private var headerBottom: NSLayoutConstraint!
    private var bodyBottom: NSLayoutConstraint!

    /// Where the body lands once built. Installed from the start so the constraints exist;
    /// empty and hidden until first expand.
    private var bodyContainer: NSStackView!
    private var bodyBuilt = false
    private var isExpanded = false

    private var canExpand: Bool {
        !file.hunks.isEmpty
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
        glyphLabel.font = Design.Typography.code(weight: .medium)
        glyphLabel.textColor = Design.Text.secondary
        glyphLabel.alignment = .center
        glyphLabel.translatesAutoresizingMaskIntoConstraints = false

        let pathLabel = NSTextField(labelWithString: pathText)
        pathLabel.font = Design.Typography.code()
        pathLabel.textColor = Design.Text.secondary
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.usesSingleLineMode = true
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pathLabel.toolTip = pathText
        pathLabel.translatesAutoresizingMaskIntoConstraints = false

        let metaLabel = NSTextField.label(attributed: metaText)
        metaLabel.setContentHuggingPriority(.required, for: .horizontal)

        // Shown rather than hover-revealed: these appear only in the two modes whose whole
        // purpose is moving changes into or out of the index, so in those modes they are what
        // the row is for.
        let stageButton = staging.map {
            Self.makeActionButton($0.action.fileTitle, target: self, action: #selector(stageFileClicked))
        }

        chevron = NSImageView()
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        chevron.contentTintColor = Design.Text.quaternary
        chevron.symbolConfiguration = Design.Symbol.configuration(Design.Symbol.chevron, weight: .semibold)
        chevron.isHidden = !canExpand

        bodyContainer = NSStackView()
        bodyContainer.orientation = .vertical
        bodyContainer.alignment = .leading
        bodyContainer.spacing = Design.Spacing.tight
        bodyContainer.translatesAutoresizingMaskIntoConstraints = false
        bodyContainer.isHidden = true

        [glyphLabel, pathLabel, metaLabel, stageButton, chevron, bodyContainer].compactMap { $0 }.forEach(addSubview)

        let inset = Design.Spacing.small
        headerBottom = pathLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset)
        headerBottom.isActive = true
        bodyBottom = bodyContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset)

        NSLayoutConstraint.activate([
            glyphLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            glyphLabel.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            glyphLabel.widthAnchor.constraint(equalToConstant: Design.Chat.toolIconWidth),

            pathLabel.leadingAnchor.constraint(equalTo: glyphLabel.trailingAnchor, constant: inset),
            pathLabel.firstBaselineAnchor.constraint(equalTo: glyphLabel.firstBaselineAnchor),

            metaLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: pathLabel.trailingAnchor,
                constant: Design.Spacing.small
            ),
            metaLabel.firstBaselineAnchor.constraint(equalTo: glyphLabel.firstBaselineAnchor),

            chevron.leadingAnchor.constraint(
                equalTo: (stageButton ?? metaLabel).trailingAnchor,
                constant: Design.Spacing.small
            ),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            chevron.centerYAnchor.constraint(equalTo: pathLabel.centerYAnchor),

            bodyContainer.topAnchor.constraint(equalTo: pathLabel.bottomAnchor, constant: inset),
            bodyContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            bodyContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset)
        ])

        if let stageButton {
            NSLayoutConstraint.activate([
                stageButton.leadingAnchor.constraint(equalTo: metaLabel.trailingAnchor, constant: Design.Spacing.small),
                stageButton.firstBaselineAnchor.constraint(equalTo: glyphLabel.firstBaselineAnchor)
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

        var remaining = GitReviewDefaults.fileDisplayCap
        var skipped = 0

        for (index, hunk) in file.hunks.enumerated() {
            guard remaining > 0 else {
                skipped += hunk.lines.count
                continue
            }

            if file.hunks.count > 1 || file.change != .untracked {
                addBodyRow(makeHunkHeader(hunk.header, index: index))
            }
            let diff = DiffView(gitLines: hunk.lines, displayCap: remaining, path: file.path, wraps: wraps)
            addBodyRow(wraps ? diff : Self.horizontallyScrolling(diff))
            remaining -= hunk.lines.count
        }

        if skipped > 0 {
            addBodyRow(makeNote("… \(skipped) more lines in later hunks"))
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
    private func makeHunkHeader(_ text: String, index: Int) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = Design.Typography.code()
        label.textColor = Design.Text.tertiary
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        label.translatesAutoresizingMaskIntoConstraints = false

        guard let staging, staging.allowsHunks, GitPatch.supportsHunkStaging(file) else { return label }

        let button = Self.makeActionButton(staging.action.hunkTitle, target: self, action: #selector(stageHunkClicked))
        button.tag = index

        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)
        row.addSubview(button)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            label.topAnchor.constraint(equalTo: row.topAnchor),
            label.bottomAnchor.constraint(equalTo: row.bottomAnchor),

            button.leadingAnchor.constraint(
                greaterThanOrEqualTo: label.trailingAnchor,
                constant: Design.Spacing.small
            ),
            button.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            button.centerYAnchor.constraint(equalTo: label.centerYAnchor)
        ])
        return row
    }

    /// A borderless caption-weight control: this is a pane of content, and a bezelled button
    /// per hunk would read as a form.
    private static func makeActionButton(_ title: String, target: AnyObject, action: Selector) -> ThemedButton {
        let button = ThemedButton(title: title, target: target, action: action)
        button.isBordered = false
        button.font = Design.Typography.caption()
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
        label.font = Design.Typography.code()
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

    /// `+A −R` with each count in its own colour, or what stands in for a body that cannot
    /// be shown.
    private var metaText: NSAttributedString {
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
