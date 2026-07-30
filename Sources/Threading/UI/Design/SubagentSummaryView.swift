import AppKit

/// The display-only facts the shared subagent component needs from a provider timeline.
struct SubagentSummaryItem: Equatable {
    enum State: Equatable {
        case pending
        case working
        case completed
        case interrupted
        case failed
        case stopped
    }

    let id: String
    let title: String
    let subtitle: String?
    let state: State
    let statusDetail: String?
    let detailLines: [String]
    let transcriptURL: URL?

    init(
        id: String,
        title: String,
        subtitle: String?,
        state: State,
        statusDetail: String?,
        detailLines: [String],
        transcriptURL: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.state = state
        self.statusDetail = statusDetail
        self.detailLines = detailLines
        self.transcriptURL = transcriptURL
    }
}

/// A compact child-agent navigator for the Subagents side pane.
///
/// The component owns every interactive and painted surface. Feature code supplies semantic
/// rows and receives selections; it never constructs an AppKit button or invents status colour,
/// spacing, type, or panel geometry outside the design boundary.
final class SubagentSummaryView: NSView {

    // MARK: - Properties

    enum SelectionStyle: Equatable {
        /// The selected child's recent activity opens beneath its row.
        case inline

        /// A row is a navigation action. Selection is handed to the feature, while this
        /// component remains the compact overview it was before the click.
        case navigation

        /// The selected child is already open beneath this component. Draw only a compact
        /// identity/status header instead of repeating the navigator title, prompt, and recent
        /// activity above the transcript.
        case detail
    }

    var onSelect: ((String?) -> Void)?
    var onRevealTranscript: ((URL) -> Void)? = {
        NSWorkspace.shared.activateFileViewerSelecting([$0])
    }
    var selectionStyle: SelectionStyle = .inline {
        didSet {
            guard selectionStyle != oldValue else { return }
            rebuildRows()
        }
    }

    private let surface = ThemedSurfaceView()
    private let headerLabel = NSTextField(labelWithString: L10n.string("Subagents"))
    private let countLabel = NSTextField(labelWithString: "")
    private let header = NSStackView()
    private let rows = NSStackView()

    private var items: [SubagentSummaryItem] = []
    private var selectedID: String?
    private var identifiersByButton: [ObjectIdentifier: String] = [:]

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityRole(.group)
        setAccessibilityLabel(L10n.string("Subagents"))

        surface.applySurface(
            fill: Design.Surface.panel,
            radius: .panel,
            border: Design.Surface.border,
            glow: true
        )

        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        headerLabel.applyFont(.subheading)
        headerLabel.textColor = Design.Text.label

        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.applyFont(.detail())
        countLabel.textColor = Design.Text.tertiary
        countLabel.setContentHuggingPriority(.required, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        header.setViews([headerLabel, spacer, countLabel], in: .leading)
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = Design.Spacing.small
        header.translatesAutoresizingMaskIntoConstraints = false

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = Design.Spacing.tight
        rows.translatesAutoresizingMaskIntoConstraints = false

        let content = NSStackView(views: [header, rows])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = Design.Spacing.small
        content.translatesAutoresizingMaskIntoConstraints = false

        addSubview(surface)
        addSubview(content)
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),

            content.topAnchor.constraint(equalTo: topAnchor, constant: Design.Spacing.inset),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.inset),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Spacing.inset),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Design.Spacing.inset),

            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            rows.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: content.trailingAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Content

    func update(
        items: [SubagentSummaryItem],
        workingCount: Int,
        doneCount: Int
    ) {
        self.items = items
        if selectedID.map({ id in !items.contains { $0.id == id } }) == true {
            selectedID = nil
        }

        let working = L10n.format("%lld working", Int64(workingCount))
        let done = L10n.format("%lld done", Int64(doneCount))
        countLabel.stringValue = workingCount > 0 ? "\(working) · \(done)" : done
        rebuildRows()
    }

    /// Selects one child for drill-in, or collapses the current detail.
    ///
    /// Kept as a semantic operation rather than exposing row controls: the component owns how
    /// selection is drawn and feature code only owns which thread id is selected.
    func setSelection(_ id: String?) {
        selectedID = id.flatMap { candidate in
            items.contains { $0.id == candidate } ? candidate : nil
        }
        rebuildRows()
        onSelect?(selectedID)
    }

    private func rebuildRows() {
        header.isHidden = selectionStyle == .detail
        for view in rows.arrangedSubviews {
            rows.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        identifiersByButton.removeAll()

        for item in items {
            let row = makeRow(item)
            rows.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: rows.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: rows.trailingAnchor)
            ])
        }
    }

    private func makeRow(_ item: SubagentSummaryItem) -> NSView {
        let showsInlineDetail = selectionStyle == .inline && selectedID == item.id
        let showsSelection = selectionStyle == .navigation && selectedID == item.id
        let title: NSView
        if selectionStyle == .detail {
            let label = NSTextField(labelWithString: item.title)
            label.translatesAutoresizingMaskIntoConstraints = false
            label.applyFont(.subheading)
            label.textColor = Design.Text.label
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            title = label
        } else {
            let button = ThemedButton(
                symbol: showsInlineDetail || showsSelection ? "chevron.down" : "chevron.right",
                accessibility: item.title,
                target: self,
                action: #selector(selectAgent(_:))
            )
            button.title = item.title
            button.isBordered = false
            button.hoverFill = Design.Surface.controlHover
            button.setAccessibilityTitle(item.title)
            if selectionStyle == .navigation {
                // The chevron is only a visual cue. Expose the same selected state as a Boolean
                // value so VoiceOver can distinguish the transcript currently on screen.
                button.setAccessibilityValue(showsSelection)
            }
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            identifiersByButton[ObjectIdentifier(button)] = item.id
            title = button
        }

        let status = NSTextField(labelWithString: stateText(item.state))
        status.translatesAutoresizingMaskIntoConstraints = false
        status.applyFont(.detail())
        status.textColor = stateColor(item.state)
        status.setContentHuggingPriority(.required, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var headingViews: [NSView] = [title, spacer]
        if let transcriptURL = item.transcriptURL {
            let reveal = ThemedIconButton(
                symbolName: "folder",
                accessibility: L10n.string("Reveal in Finder"),
                target: .inline
            )
            reveal.toolTip = L10n.string("Reveal in Finder")
            reveal.onPress = { [weak self] in
                self?.onRevealTranscript?(transcriptURL)
            }
            headingViews.append(reveal)
        }
        headingViews.append(status)

        let heading = NSStackView(views: headingViews)
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = Design.Spacing.small
        heading.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView()
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = Design.Spacing.hairline
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(heading)
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            heading.trailingAnchor.constraint(equalTo: row.trailingAnchor)
        ])

        if let statusDetail = item.statusDetail, !statusDetail.isEmpty {
            addDetail(statusDetail, to: row, color: Design.Text.tertiary)
        }

        if showsInlineDetail {
            if let subtitle = item.subtitle, !subtitle.isEmpty {
                addDetail(subtitle, to: row, color: Design.Text.secondary)
            }

            if item.detailLines.isEmpty {
                addDetail(
                    L10n.string("No child activity received yet."),
                    to: row,
                    color: Design.Text.tertiary
                )
            } else {
                for line in item.detailLines {
                    addDetail(line, to: row, color: Design.Text.tertiary)
                }
            }
        }

        return row
    }

    private func addDetail(_ text: String, to row: NSStackView, color: NSColor) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.applyFont(.detail(), in: .conversation)
        label.textColor = color
        label.maximumNumberOfLines = 3
        label.lineBreakMode = .byWordWrapping
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(
                equalTo: row.leadingAnchor,
                constant: Design.Spacing.large
            ),
            label.trailingAnchor.constraint(equalTo: row.trailingAnchor)
        ])
    }

    @objc private func selectAgent(_ sender: ThemedButton) {
        guard let id = identifiersByButton[ObjectIdentifier(sender)] else { return }
        switch selectionStyle {
        case .inline:
            setSelection(selectedID == id ? nil : id)
        case .navigation:
            // Selecting the same child again is useful after the detail tab was closed: it
            // reopens the current snapshot instead of requiring a meaningless deselect click.
            setSelection(id)
        case .detail:
            break
        }
    }

    private func stateText(_ state: SubagentSummaryItem.State) -> String {
        switch state {
        case .pending: return L10n.string("Pending")
        case .working: return L10n.string("Working")
        case .completed: return L10n.string("Done")
        case .interrupted: return L10n.string("Interrupted")
        case .failed: return L10n.string("Failed")
        case .stopped: return L10n.string("Stopped")
        }
    }

    private func stateColor(_ state: SubagentSummaryItem.State) -> NSColor {
        switch state {
        case .pending: return Design.Status.warning
        case .working: return Design.Surface.accent
        case .completed: return Design.Status.positive
        case .interrupted, .stopped: return Design.Text.tertiary
        case .failed: return Design.Status.negative
        }
    }
}
