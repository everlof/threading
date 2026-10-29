import AppKit
#if os(Linux)
@testable import CoreSlice
#endif

// MARK: - When it arrived

/// How this pane says *when*, in one place because two surfaces say it: a row's caption and the
/// menu that names the same file from somewhere else.
///
/// Compact but complete on purpose. A time without its calendar date makes attachments from
/// separate days look contemporaneous, while a date without its time loses the ordering detail
/// this chronology exists to provide. The numeric date follows the user's locale and always keeps
/// its year, so the value stays unambiguous across day and year boundaries.
@MainActor
enum AttachmentMoment {

    static func description(
        of date: Date,
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let format = Date.FormatStyle(
            locale: locale,
            calendar: calendar,
            timeZone: calendar.timeZone
        )
        return date.formatted(
            format.year().month(.twoDigits).day(.twoDigits).hour().minute()
        )
    }
}

extension SessionAttachment.Origin {

    /// "You" rather than "Ours": in a window where the other party is also working on your
    /// behalf, "ours" names both of them.
    var title: String {
        switch self {
        case .agent: return L10n.string("Agent")
        case .user: return L10n.string("You")
        }
    }
}

extension SessionAttachment {
    var sourceTitle: String {
        let children = agentSources.contains { $0.threadID != nil }
        guard children else { return origin.title }
        if origin == .user { return L10n.string("You + subagents") }
        return agentSources.contains { $0.threadID == nil }
            ? L10n.string("Main + subagents") : L10n.string("Subagents")
    }

    /// Keep the compact provenance mark aligned with other rows; task names use the flexible
    /// detail line, with the full path and ownership retained in its tooltip and accessibility.
    var referenceDetail: String {
        let children = agentSources.compactMap { source -> String? in
            guard let id = source.threadID else { return nil }
            return "\(source.name ?? String(id.prefix(8))) [\(id.prefix(8))]"
        }
        guard !children.isEmpty else { return relativePath }
        return children.joined(separator: ", ") + " · " + relativePath
    }
}

// MARK: - Row Metrics

enum SessionAttachmentRowMetrics {
    static let iconSize: CGFloat = 26
    static let playMarkSize: CGFloat = 13
    static let playMarkIdentifier = "attachment.row.play"
    static let compactWidth: CGFloat = 280
    static let compactHeight: CGFloat = 72

    static func height(for width: CGFloat) -> CGFloat {
        width < compactWidth ? compactHeight : SessionAttachmentListMetrics.rowHeight
    }
}

/// **An `NSTableCellView` rather than a plain `NSView`, and that is a colour decision.**
///
/// A plain view in a list is never told that the row under it is selected: AppKit propagates
/// `interiorBackgroundStyle` to cell views and to nothing else. So every label here went on
/// inking itself from the chrome's ground after the row had painted an accent under it — which
/// is how the pane's quietest tier came to draw at 1.20:1 on a selected row, *worse* than the
/// 1.34:1 it drew at unselected. Adopting the class is how the row gets to say what it painted;
/// `ThemedTableRowView.contentInk` is what it says.
final class SessionAttachmentRowView: NSTableCellView, ThemeDerivedContent {

    /// A drag is over this row and would open a comparison against it.
    ///
    /// **The row stays the row.** What makes an unfamiliar gesture learnable is the sentence, not
    /// the highlight — a highlight only answers *here*, which the pointer already said. But the
    /// first version of this said the sentence by *replacing* the row: thumbnail and name gave
    /// their place to a saturated accent plate, so the list opened a hole exactly where the
    /// picture you were aiming at had been, and the plate shouted over the window's own selection
    /// two rows above it. Two things were wrong at once — the row stopped being legible, and a
    /// pointer affordance outranked a state the user had chosen.
    ///
    /// So only the *secondary* line changes. The thumbnail and the name stay, because which
    /// picture is under the pointer is the whole question the affordance answers; the path — the
    /// one line nobody is reading mid-drag — becomes what dropping here would do, in the accent
    /// that means "the thing you are aiming at" everywhere else in the window.
    ///
    /// The wash behind it belongs to the **row**, not here (`ThemedTableRowView.isDropTarget`):
    /// this cell is inset within its row, so a plate drawn from these bounds stood as tall as the
    /// selection above it and visibly narrower than it.
    var isDropTarget = false {
        didSet {
            guard isDropTarget != oldValue else { return }
            pathLabel?.isHidden = isDropTarget
            dropLabel.isHidden = !isDropTarget
            needsDisplay = true
        }
    }

    /// The line the drop caption takes the place of.
    private var pathLabel: NSTextField?

    /// The rest of the row's words, held so the ink can be re-asked when the ground moves.
    private var nameLabel: NSTextField?
    private var originLabel: NSTextField?
    private var momentLabel: NSTextField?
    private var playMarkView: NSImageView?
    private var wideConstraints: [NSLayoutConstraint] = []
    private var compactConstraints: [NSLayoutConstraint] = []
    private(set) var isCompact = false

    func setCompact(_ compact: Bool) {
        guard isCompact != compact else { return }
        NSLayoutConstraint.deactivate(compact ? wideConstraints : compactConstraints)
        isCompact = compact
        momentLabel?.lineBreakMode = compact ? .byWordWrapping : .byClipping
        momentLabel?.maximumNumberOfLines = compact ? 2 : 0
        momentLabel?.setContentCompressionResistancePriority(
            compact ? .defaultLow : .required, for: .horizontal
        )
        NSLayoutConstraint.activate(compact ? compactConstraints : wideConstraints)
    }

    /// Selection changes the colour under every word in the row, so every word is asked again.
    ///
    /// The ink comes from the row rather than from `Design.Text`, because only the row knows
    /// whether it painted the theme's accent, AppKit's, a held-back wash, or nothing at all —
    /// see `ThemedTableRowView.contentInk`. The tiers each label takes are unchanged: the
    /// hierarchy is the same sentence, measured against the ground it is actually on.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            guard backgroundStyle != oldValue else { return }
            applyInk()
        }
    }

    private func applyInk() {
        // Resolved in *this view's* appearance rather than the ambient one, for the reason
        // `SelectionSurface.dynamic` gives: the ground and the ink underneath are dynamic, and
        // reading them under whichever appearance happens to be drawing is how a light variant's
        // ink is measured against a dark variant's ground.
        effectiveAppearance.performAsCurrentDrawingAppearance { applyResolvedInk() }
    }

    private func applyResolvedInk() {
        let ink = (superview as? ThemedTableRowView)?.contentInk ?? .chrome
        nameLabel?.textColor = ink.label
        pathLabel?.textColor = ink.tertiary
        originLabel?.textColor = ink.quaternary
        momentLabel?.textColor = ink.quaternary
        playMarkView?.contentTintColor = ink.label
        // The drop caption says "the thing you are aiming at" in the accent — which is the one
        // colour it cannot use over a row already filled with that accent. On a selected row the
        // ground's own brightest ink says it instead, and says it just as loudly.
        dropLabel.textColor = backgroundStyle == .emphasized ? ink.label : Design.Surface.accent
    }

    /// The row joins the list already selected when the pane restores a choice, and
    /// `backgroundStyle` is set before that superview exists. Asking once more on arrival is what
    /// keeps a restored selection from drawing chrome ink over an accent.
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        applyInk()
    }

    /// **The ink on a selected row is baked, so it has to be baked again.**
    ///
    /// `Design.Ink` is a struct of resolved colours, not a set of dynamic ones: `Design.Text.on`
    /// measures black and white against the ground it is *handed*, which is a question no colour
    /// provider can be asked later. So the value assigned to `textColor` here is the answer for
    /// the appearance that was current when the row joined the list, and it stays that answer
    /// through a theme switch and a light/dark flip — the sweep re-resolves recorded surfaces,
    /// layer colours and fonts, and a baked foreground is none of those.
    ///
    /// Caught by rendering the pane in both appearances in one process: three of the four cases
    /// measured cleanly and the selected row in dark came back at 1.74:1, wearing the ink it had
    /// been given in light. Exactly the failure `ThemeDerivedContent` exists for — see the note
    /// on the protocol, and `SessionRowView`, which bakes its agent mark the same way.
    func rederiveThemedContent() {
        applyInk()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyInk()
    }

    private lazy var dropLabel: NSTextField = {
        let label = NSTextField(labelWithString: L10n.string("Drop to compare"))
        label.applyFont(.caption)
        label.textColor = Design.Surface.accent
        label.lineBreakMode = .byTruncatingTail
        label.isHidden = true
        label.setAccessibilityElement(false)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    init(attachment: SessionAttachment, iconImage: NSImage?, annotationBadge: NSView? = nil) {
        super.init(frame: .zero)

        let icon = NSImageView()
        // The picture itself where there is one to show. This list is the panel's visual
        // history now, and a history of identical file-type glyphs is what it replaced — the
        // tab strip's row of `photo` marks under titles that truncated to nothing. A PDF, and
        // anything that will not decode, keeps the file icon rather than showing a blank well.
        icon.image = iconImage
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: attachment.name)
        name.applyFont(.subheading)
        name.textColor = Design.Text.label
        name.lineBreakMode = .byTruncatingMiddle
        name.translatesAutoresizingMaskIntoConstraints = false

        let path = NSTextField(labelWithString: attachment.referenceDetail)
        path.toolTip = attachment.referenceDetail
        path.applyFont(.caption)
        path.textColor = Design.Text.tertiary
        path.lineBreakMode = .byTruncatingMiddle
        path.translatesAutoresizingMaskIntoConstraints = false

        // Marked on every row rather than only on the user's, because a mark that appears on one
        // kind makes its absence carry meaning, and absence is exactly what nobody reads.
        let origin = NSTextField(labelWithString: attachment.sourceTitle)
        origin.applyFont(.caption)
        origin.textColor = Design.Text.quaternary
        origin.setContentCompressionResistancePriority(.required, for: .horizontal)
        origin.setContentHuggingPriority(.required, for: .horizontal)
        origin.translatesAutoresizingMaskIntoConstraints = false

        // When it arrived, in the same quiet voice as the mark it sits above. A chronology whose
        // rows carry no time is a list whose order the reader has to take on trust — and the
        // order is the whole reason the images stopped being tabs.
        let moment = NSTextField(
            labelWithString: AttachmentMoment.description(of: attachment.referencedAt)
        )
        moment.toolTip = moment.stringValue
        moment.applyFont(.caption)
        moment.textColor = Design.Text.quaternary
        moment.setContentCompressionResistancePriority(.required, for: .horizontal)
        moment.setContentHuggingPriority(.required, for: .horizontal)
        moment.translatesAutoresizingMaskIntoConstraints = false

        // A movie's poster frame is a picture of a moment, which is exactly what a screenshot is
        // — and in a 26-point well nothing else tells the two apart. The mark says which of the
        // rows in this history can be played, and it is drawn over the frame rather than beside
        // the name because the well is where the reader already is.
        let playMark: NSImageView? = attachment.kind == .video ? {
            let mark = NSImageView()
            mark.image = NSImage(
                systemSymbolName: "play.circle.fill",
                accessibilityDescription: nil
            )
            mark.contentTintColor = Design.Text.label
            mark.symbolConfiguration = NSImage.SymbolConfiguration(
                pointSize: SessionAttachmentRowMetrics.playMarkSize,
                weight: .semibold
            )
            mark.setAccessibilityElement(false)
            mark.setAccessibilityIdentifier(SessionAttachmentRowMetrics.playMarkIdentifier)
            mark.translatesAutoresizingMaskIntoConstraints = false
            return mark
        }() : nil

        addSubview(icon)
        addSubview(name)
        addSubview(path)
        addSubview(origin)
        addSubview(moment)
        if let annotationBadge { addSubview(annotationBadge) }
        if let playMark { addSubview(playMark) }
        addSubview(dropLabel)
        pathLabel = path
        nameLabel = name
        originLabel = origin
        momentLabel = moment
        playMarkView = playMark

        // One element, read as one sentence: four separate labels would be announced as four
        // unrelated strings with no hint that the last two are the provenance and the moment of
        // the first.
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(
            L10n.format(
                "%@, from %@, %@, %@",
                attachment.name,
                attachment.sourceTitle,
                attachment.referenceDetail,
                moment.stringValue
            )
        )
        for child in [icon, name, path, origin, moment] {
            child.setAccessibilityElement(false)
        }

        NSLayoutConstraint.activate([
            origin.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -Design.Spacing.small
            ),
            origin.firstBaselineAnchor.constraint(equalTo: path.firstBaselineAnchor),
            origin.leadingAnchor.constraint(
                greaterThanOrEqualTo: path.trailingAnchor,
                constant: Design.Spacing.small
            ),

            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.small),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: SessionAttachmentRowMetrics.iconSize),
            icon.heightAnchor.constraint(equalToConstant: SessionAttachmentRowMetrics.iconSize),

            name.leadingAnchor.constraint(
                equalTo: icon.trailingAnchor,
                constant: Design.Spacing.small
            ),
            name.topAnchor.constraint(equalTo: topAnchor, constant: Design.Spacing.tight),

            path.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            path.topAnchor.constraint(equalTo: name.bottomAnchor, constant: Design.Spacing.hairline),

            // Exactly where the path it replaces sat, so a row crossed by the pointer reads as
            // the same row saying something else — not as the list shifting under the drag.
            dropLabel.leadingAnchor.constraint(equalTo: path.leadingAnchor),
            dropLabel.firstBaselineAnchor.constraint(equalTo: path.firstBaselineAnchor),
            dropLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: origin.leadingAnchor,
                constant: -Design.Spacing.small
            )
        ])

        wideConstraints = [
            moment.trailingAnchor.constraint(equalTo: origin.trailingAnchor),
            moment.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor)
        ]
        compactConstraints = [
            name.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -Design.Spacing.small
            ),
            moment.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            moment.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -Design.Spacing.small
            ),
            moment.topAnchor.constraint(equalTo: path.bottomAnchor, constant: Design.Spacing.hairline),
            moment.bottomAnchor.constraint(
                lessThanOrEqualTo: bottomAnchor, constant: -Design.Spacing.tight
            )
        ]

        if let playMark {
            NSLayoutConstraint.activate([
                playMark.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
                playMark.centerYAnchor.constraint(equalTo: icon.centerYAnchor)
            ])
        }

        if let annotationBadge {
            let badgeAlignment = [
                annotationBadge.trailingAnchor.constraint(
                    equalTo: moment.leadingAnchor,
                    constant: -Design.Spacing.small
                ),
                annotationBadge.centerYAnchor.constraint(equalTo: moment.centerYAnchor),
                name.trailingAnchor.constraint(
                    lessThanOrEqualTo: annotationBadge.leadingAnchor,
                    constant: -Design.Spacing.small
                )
            ]
            wideConstraints += badgeAlignment
            compactConstraints += [
                annotationBadge.trailingAnchor.constraint(
                    equalTo: trailingAnchor, constant: -Design.Spacing.small
                ),
                annotationBadge.centerYAnchor.constraint(equalTo: name.centerYAnchor),
                name.trailingAnchor.constraint(
                    lessThanOrEqualTo: annotationBadge.leadingAnchor,
                    constant: -Design.Spacing.small
                )
            ]
        } else {
            wideConstraints.append(name.trailingAnchor.constraint(
                lessThanOrEqualTo: moment.leadingAnchor,
                constant: -Design.Spacing.small
            ))
        }
        NSLayoutConstraint.activate(wideConstraints)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
