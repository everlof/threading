import AppKit

/// One line of the review pane's history list: the graph rail, the hash, any refs pointing
/// here, the subject, who and when, and the commit's weight. Clicking it opens the commit's
/// diff.
///
/// Flat at rest, lit on hover — the tool rows' rule, and here it also earns the graph: a
/// hundred filled slabs with gaps between them cannot carry a continuous rail, and a rail
/// broken once per row reads as a history that stops and restarts.
final class GitReviewCommitRow: NSView {

    // MARK: - Properties

    var onOpen: (() -> Void)?

    private var isHovered = false

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        // "now" and "yesterday" rather than "0 sec. ago" for a commit that just landed.
        formatter.dateTimeStyle = .named
        return formatter
    }()

    /// The byline's age. A commit cannot be in the future from the list's point of view; clock
    /// skew or a commit made this second produced "in 0 sec", so the future is clamped to now.
    static func relativeDescription(for date: Date, relativeTo now: Date = Date()) -> String {
        relativeFormatter.localizedString(for: min(date, now), relativeTo: now)
    }

    // MARK: - Initialization

    /// `graph` is nil when the history is drawn without a rail; `laneCount` is the whole
    /// page's width, so every row's nodes sit in the same columns.
    init(commit: GitCommitSummary, graph: GitGraphRow? = nil, laneCount: Int = 1) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        applySurface(fill: .clear, radius: .control)

        let hashLabel = NSTextField(labelWithString: commit.shortHash)
        hashLabel.applyFont(.code())
        hashLabel.textColor = Design.Text.tertiary
        hashLabel.setContentHuggingPriority(.required, for: .horizontal)

        // The hash and the refs are one group: both name the commit, and neither compresses.
        let identity = NSStackView(views: [hashLabel] + commit.refs
            .prefix(GitReviewCommitRowDefaults.maximumRefs)
            .map(Self.makeRefBadge))
        identity.orientation = .horizontal
        identity.spacing = Design.Spacing.tight
        identity.setContentHuggingPriority(.required, for: .horizontal)
        identity.setContentCompressionResistancePriority(.required, for: .horizontal)

        let subjectLabel = NSTextField(labelWithString: commit.subject)
        subjectLabel.applyFont(.control)
        subjectLabel.textColor = Design.Text.label
        subjectLabel.lineBreakMode = .byTruncatingTail
        subjectLabel.usesSingleLineMode = true
        subjectLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subjectLabel.toolTip = commit.subject

        let counts = NSMutableAttributedString()
        if commit.hasStats {
            counts.append(NSAttributedString(string: "+\(commit.added)", attributes: [
                .foregroundColor: Design.Diff.added,
                .font: Design.Typography.caption()
            ]))
            counts.append(NSAttributedString(string: " −\(commit.removed)", attributes: [
                .foregroundColor: Design.Diff.removed,
                .font: Design.Typography.caption()
            ]))
        } else {
            // Preserve the trailing column while the background stat read runs, without lying
            // that an unknown count is zero or making the fixed-height row move when it arrives.
            counts.append(NSAttributedString(string: "…", attributes: [
                .foregroundColor: Design.Text.quaternary,
                .font: Design.Typography.caption()
            ]))
        }
        let countsLabel = NSTextField.label(attributed: counts)
        countsLabel.setContentHuggingPriority(.required, for: .horizontal)

        let when = Self.relativeDescription(for: commit.date)
        let byline = NSTextField(labelWithString: "\(commit.author) · \(when)")
        byline.applyFont(.detail())
        byline.textColor = Design.Text.tertiary
        byline.lineBreakMode = .byTruncatingTail
        byline.usesSingleLineMode = true

        let rail = graph.map { GitGraphRailView(row: $0, laneCount: laneCount) }

        [rail, identity, subjectLabel, countsLabel, byline].compactMap { $0 }.forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }

        let inset = Design.Spacing.small
        var constraints: [NSLayoutConstraint] = [
            identity.topAnchor.constraint(equalTo: topAnchor, constant: inset),

            subjectLabel.leadingAnchor.constraint(equalTo: identity.trailingAnchor, constant: inset),
            subjectLabel.firstBaselineAnchor.constraint(equalTo: hashLabel.firstBaselineAnchor),

            countsLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: subjectLabel.trailingAnchor,
                constant: Design.Spacing.small
            ),
            countsLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            countsLabel.firstBaselineAnchor.constraint(equalTo: hashLabel.firstBaselineAnchor),

            byline.leadingAnchor.constraint(equalTo: subjectLabel.leadingAnchor),
            byline.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -inset),
            byline.topAnchor.constraint(equalTo: subjectLabel.bottomAnchor, constant: Design.Spacing.hairline),
            byline.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset)
        ]

        if let rail {
            // Edge to edge, so consecutive rows draw one unbroken line.
            constraints += [
                rail.leadingAnchor.constraint(equalTo: leadingAnchor),
                rail.topAnchor.constraint(equalTo: topAnchor),
                rail.bottomAnchor.constraint(equalTo: bottomAnchor),
                identity.leadingAnchor.constraint(equalTo: rail.trailingAnchor, constant: inset)
            ]
        } else {
            constraints.append(identity.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset))
        }

        NSLayoutConstraint.activate(constraints)
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Refs

    /// A branch, tag or HEAD pointing at this commit, as a quiet pill. Two at most per row:
    /// a freshly cloned repository puts four refs on its tip, and the subject is what the row
    /// is for.
    private static func makeRefBadge(_ ref: String) -> NSView {
        let isTag = ref.hasPrefix(GitReviewCommitRowDefaults.tagPrefix)
        let name = isTag ? String(ref.dropFirst(GitReviewCommitRowDefaults.tagPrefix.count)) : ref

        let label = NSTextField(labelWithString: name)
        label.applyFont(.caption)
        label.textColor = ref == GitReviewCommitRowDefaults.headRef ? Design.Text.label : Design.Text.secondary
        label.translatesAutoresizingMaskIntoConstraints = false

        let badge = NSView()
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.applySurface(
            fill: Design.Surface.controlResting,
            radius: .pill(height: GitReviewCommitRowDefaults.refBadgeHeight)
        )
        badge.addSubview(label)
        badge.setContentHuggingPriority(.required, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)

        let inset = GitReviewCommitRowDefaults.refBadgeInset
        NSLayoutConstraint.activate([
            badge.heightAnchor.constraint(equalToConstant: GitReviewCommitRowDefaults.refBadgeHeight),
            label.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: inset),
            label.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: -inset),
            label.centerYAnchor.constraint(equalTo: badge.centerYAnchor)
        ])
        return badge
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))

        // A row that scrolled out from under the pointer was never told it was left — see
        // `NSView.hoverIsStale`.
        if hoverIsStale(isHovered) {
            isHovered = false
            applyHover()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        applyHover()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        applyHover()
    }

    private func applyHover() {
        applyLayerBackground(isHovered ? Design.Chat.toolRowActive : NSColor.clear)
    }

    // MARK: - Actions

    @objc private func clicked() {
        onOpen?()
    }
}

// MARK: - Defaults

enum GitReviewCommitRowDefaults {
    /// The byline sits under a `control`-weight subject; caption's semibold reads too loud
    /// for a second line, so it is the same size at regular weight.
    static let bylineFontSize: CGFloat = 11

    /// Two text lines, the hairline between them, and the row's vertical insets. Fixed height is
    /// what lets `NSTableView` seek without first asking every offscreen commit to lay itself out.
    static let tableRowHeight: CGFloat = 42

    static let maximumRefs = 2
    static let refBadgeHeight: CGFloat = 15
    static let refBadgeInset: CGFloat = 5
    static let tagPrefix = "tag: "
    static let headRef = "HEAD"
}
