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
    init(file: GitFileDiff, expanded: Bool, staging: GitStaging? = nil) {
        self.file = file
        self.staging = staging
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
        applySurface(fill: Design.Surface.controlResting, radius: Design.Radius.control)

        let glyphLabel = NSTextField(labelWithString: glyph)
        glyphLabel.font = .monospacedSystemFont(ofSize: ToolCallDefaults.fontSize, weight: .medium)
        glyphLabel.textColor = .secondaryLabelColor
        glyphLabel.alignment = .center
        glyphLabel.translatesAutoresizingMaskIntoConstraints = false

        let pathLabel = NSTextField(labelWithString: pathText)
        pathLabel.font = .monospacedSystemFont(ofSize: ToolCallDefaults.fontSize, weight: .regular)
        pathLabel.textColor = .secondaryLabelColor
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
        chevron.contentTintColor = .quaternaryLabelColor
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
            addBodyRow(DiffView(gitLines: hunk.lines, displayCap: remaining, path: file.path))
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

    /// The `@@` line, and — where a hunk is a thing the index can be given on its own — the
    /// one control that gives it.
    private func makeHunkHeader(_ text: String, index: Int) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedSystemFont(ofSize: ToolCallDefaults.fontSize, weight: .regular)
        label.textColor = .tertiaryLabelColor
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
    private static func makeActionButton(_ title: String, target: AnyObject, action: Selector) -> NSButton {
        let button = HoverTintButton(title: title, target: target, action: action)
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.font = Design.Typography.caption()
        button.tintsTitle = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    // MARK: - Staging

    @objc private func stageFileClicked() {
        onStageFile?()
    }

    @objc private func stageHunkClicked(_ sender: NSButton) {
        onStageHunk?(sender.tag)
    }

    private func makeNote(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedSystemFont(ofSize: ToolCallDefaults.fontSize, weight: .regular)
        label.textColor = .tertiaryLabelColor
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
                .foregroundColor: NSColor.tertiaryLabelColor,
                .font: Design.Typography.caption()
            ])
        }
        if !canExpand {
            return NSAttributedString(string: "no preview", attributes: [
                .foregroundColor: NSColor.tertiaryLabelColor,
                .font: Design.Typography.caption()
            ])
        }

        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: "+\(file.added)", attributes: [
            .foregroundColor: NSColor.systemGreen,
            .font: Design.Typography.caption()
        ]))
        text.append(NSAttributedString(string: " −\(file.removed)", attributes: [
            .foregroundColor: NSColor.systemRed,
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
        return !(superview.hitTest(superview.convert(event.locationInWindow, from: nil)) is NSButton)
    }
}
