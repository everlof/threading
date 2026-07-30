import AppKit

// MARK: - Defaults

enum ToastDefaults {

    /// How long a toast holds before it leaves on its own.
    ///
    /// Long enough to see a row vanish, look down, and press the way back; short enough that a
    /// band nobody wanted stops being furniture. The pointer resting on it stops the clock, so
    /// this is the floor for somebody who is *not* already reaching — see `ToastPresenter`.
    static let dwell: TimeInterval = 6

    /// How far the band travels as it arrives, and back as it leaves. A short slide, because
    /// the movement is only there to say the band was not always on screen.
    static let rise: CGFloat = 8

    /// Between the band's edge and its content.
    static let contentInset: CGFloat = Design.Spacing.inset

    /// Between the band and the pane it floats in.
    static let hostInset: CGFloat = Design.Spacing.medium

    /// Widest the band grows. It fills a narrow column and stops well short of spanning a pane:
    /// a receipt read at a glance is a couple of short lines, not one long one.
    static let maxWidth: CGFloat = 320
}

// MARK: - Request

/// What a toast says, and the one thing it offers to do about it.
///
/// The action is what this type exists for. **An action that can be taken back does not have to
/// be asked about first**: a confirmation stops the person who meant it every single time in
/// order to catch the one who did not, while a receipt with a way back charges the mistake
/// alone. `ConfirmationPrompt` is still the register for questions — this is the counterpart for
/// the actions that turned out not to be questions, and archiving a session is the first of
/// them.
///
/// `detail` carries the consequence the verb does not: where the thing went, or what stopped
/// along with it. Left out, the band is one line.
struct ToastRequest {

    /// What happened, in the fewest words that name what it happened to.
    let message: String

    /// The consequence, when there is one the message does not carry.
    var detail: String?

    /// The way back. Titled by the caller, since "Undo" is right for an archive and wrong for
    /// half the things a toast will report next.
    var actionTitle: String?
    var action: (() -> Void)?

    /// For UI scripting and tests; the band and its action each take one.
    var identifier: String?

    /// What VoiceOver is told when the band arrives. The band is transient and takes no focus,
    /// so nothing else would ever read it out.
    var announcement: String {
        [message, detail].compactMap { $0 }.joined(separator: " ")
    }

    var hasAction: Bool { actionTitle != nil && action != nil }
}

// MARK: - View

/// A floating band that reports something already done and offers to take it back.
///
/// It draws on `elevated` — the role for a card above a pane — rather than on a translucent
/// control surface: this floats over a list, and a see-through fill at 14% is how the git card
/// once let a conversation's own text run through its middle (see
/// [`design-system.md`](../../../../docs/architecture/design-system.md)). Quiet-at-rest belongs
/// on a control that is waiting to be used; a band that leaves by itself in six seconds has to
/// be legible for all six.
///
/// The band handles no clicks of its own. Its action is a `ThemedButton`, which is what gives
/// the way back a keyboard route, a focus ring and an accessible name for free — and what keeps
/// this class out of the interactive-component contract, which exists so that a *drawn control*
/// cannot be mouse-only. Hover is the exception, and it is not an interaction: the presenter
/// reads it to hold the clock while somebody is reaching for the button.
final class ToastView: NSView {

    // MARK: - Properties

    /// Pressed the way back. The presenter dismisses the band; the caller undoes the work.
    var onAction: (() -> Void)?

    /// Whether the pointer is on the band. Reported rather than acted on, because what it means
    /// — the dwell pauses — is the presenter's decision and not this view's.
    var onHoverChanged: ((Bool) -> Void)?

    private(set) var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            onHoverChanged?(isHovered)
        }
    }

    let request: ToastRequest

    private let messageLabel: NSTextField
    private let detailLabel: NSTextField?
    private let actionButton: ThemedButton?
    private var hoverTracking: NSTrackingArea?

    // MARK: - Initialization

    init(request: ToastRequest) {
        self.request = request
        messageLabel = NSTextField(wrappingLabelWithString: request.message)
        detailLabel = request.detail.map { NSTextField(wrappingLabelWithString: $0) }
        actionButton = request.hasAction
            ? ThemedButton(title: request.actionTitle ?? "", target: nil, action: nil)
            : nil

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        configureLabels()
        configureAction()
        installContent()
        applyBandSurface()

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(request.announcement)
        if let identifier = request.identifier {
            setAccessibilityIdentifier(identifier)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Layout

    /// A wrapping label measures its height against a width it has to be told, and the width
    /// here is whatever the host column left — capped, but never fixed. Guarded on the value
    /// actually changing: assigning it unconditionally in `layout()` invalidates the size that
    /// caused the layout.
    override func layout() {
        super.layout()
        let available = max(0, bounds.width - ToastDefaults.contentInset * 2)
        for label in [messageLabel, detailLabel].compactMap({ $0 })
        where abs(label.preferredMaxLayoutWidth - available) > 0.5 {
            label.preferredMaxLayoutWidth = available
            label.invalidateIntrinsicContentSize()
        }
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverTracking = area

        // A fresh tracking area assumes the pointer is outside, so a band the pointer has left
        // during a relayout would hold a hover nothing ever clears — and the clock would never
        // restart. Only ever corrected in the leaving direction — see `NSView.hoverIsStale`.
        if hoverIsStale(isHovered) { isHovered = false }
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    // MARK: - Private Methods

    private func configureLabels() {
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.applyFont(.control)
        messageLabel.textColor = Design.Text.label
        messageLabel.maximumNumberOfLines = 0

        // `.detail`, not `.caption`: the caption role is semibold, which on the line *under* a
        // medium-weight message reads as a second heading rather than as the consequence of the
        // first. Two lines of small regular type in secondary ink is what a receipt's fine print
        // looks like, and it is the only way the message stays the thing read first.
        detailLabel?.translatesAutoresizingMaskIntoConstraints = false
        detailLabel?.applyFont(.detail())
        detailLabel?.textColor = Design.Text.secondary
        detailLabel?.maximumNumberOfLines = 0
    }

    private func configureAction() {
        guard let actionButton else { return }
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        // Secondary: the band reports one thing and offers one action, so the action is the
        // only thing on it asking to be pressed — but a receipt is not the screen's primary
        // business, and an accent fill floating over a list would claim it was.
        actionButton.emphasis = .secondary
        actionButton.target = self
        actionButton.action = #selector(actionPressed)
        if let identifier = request.identifier {
            actionButton.setAccessibilityIdentifier("\(identifier).action")
        }
    }

    private func installContent() {
        addSubview(messageLabel)
        detailLabel.map { addSubview($0) }
        actionButton.map { addSubview($0) }

        let inset = ToastDefaults.contentInset
        var constraints: [NSLayoutConstraint] = [
            messageLabel.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            messageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            messageLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset)
        ]

        var lastText: NSView = messageLabel
        if let detailLabel {
            constraints += [
                detailLabel.topAnchor.constraint(
                    equalTo: messageLabel.bottomAnchor,
                    constant: Design.Spacing.hairline
                ),
                detailLabel.leadingAnchor.constraint(equalTo: messageLabel.leadingAnchor),
                detailLabel.trailingAnchor.constraint(equalTo: messageLabel.trailingAnchor)
            ]
            lastText = detailLabel
        }

        if let actionButton {
            // Under the words rather than beside them: the band lives in the sidebar's column,
            // where a title long enough to wrap and a button on the same line leave the button
            // a few points wide.
            //
            // Pinned at the inset outright, **not** by ink. A bordered button's ink *is* its
            // surface, and `opticalHorizontalInset` reports the bordered shape's title inset —
            // the right answer for a footer aligning a row of plain controls by their words, and
            // the wrong one here, where subtracting it left the pill three points from the
            // band's own border.
            constraints += [
                actionButton.topAnchor.constraint(
                    equalTo: lastText.bottomAnchor,
                    constant: Design.Spacing.small
                ),
                actionButton.trailingAnchor.constraint(
                    equalTo: trailingAnchor,
                    constant: -inset
                ),
                actionButton.leadingAnchor.constraint(
                    greaterThanOrEqualTo: leadingAnchor,
                    constant: inset
                ),
                bottomAnchor.constraint(equalTo: actionButton.bottomAnchor, constant: inset)
            ]
        } else {
            constraints.append(bottomAnchor.constraint(equalTo: lastText.bottomAnchor, constant: inset))
        }

        NSLayoutConstraint.activate(constraints)
    }

    private func applyBandSurface() {
        applySurface(
            fill: Design.Surface.elevated,
            radius: .panel,
            border: Design.Surface.border,
            glow: true
        )
    }

    @objc private func actionPressed() {
        onAction?()
    }
}

// MARK: - Presenter

/// Puts one toast at a time into a pane, holds it for its dwell, and takes it away again.
///
/// Separate from the view because everything that goes wrong with a transient band is about
/// *time*, not about drawing: two of them stacking up, one outliving the thing it reports, one
/// vanishing from under the pointer that was reaching for its button. Stated once here, a host
/// contributes only where the band sits.
///
/// The host pins nothing: this owns the band's position, because "above the pane's footer,
/// inset from its edges" is the same decision in every pane that grows one — the reason
/// `PaneFooterView` owns its own geometry rather than handing hosts a constant.
@MainActor
final class ToastPresenter {

    // MARK: - Properties

    /// The dwell this presenter uses. Settable so a test can watch the band leave without
    /// waiting six seconds for it.
    var dwell: TimeInterval = ToastDefaults.dwell

    private(set) var current: ToastView?

    /// Whether a band is up with its clock stopped — which is to say, whether the pointer is
    /// holding it open. Readable so the hold can be asserted at the moment it happens rather
    /// than by waiting to see whether something failed to leave.
    var isHeldOpen: Bool { current != nil && dismissal == nil }

    private weak var host: NSView?
    private let bottom: NSLayoutYAxisAnchor
    private var bottomConstraint: NSLayoutConstraint?
    private var dismissal: Timer?

    // MARK: - Initialization

    /// `bottom` is what the band sits above — a pane's footer band, or the pane's own bottom
    /// edge where it has none.
    init(host: NSView, above bottom: NSLayoutYAxisAnchor) {
        self.host = host
        self.bottom = bottom
    }

    // MARK: - Public Methods

    /// Shows a toast, replacing whatever is already up.
    ///
    /// Replacing rather than stacking: two bands in a column is a queue the user did not ask
    /// for, and the second report is always the one that describes the state they are in. The
    /// first one's action goes with it — an undo whose row has already been archived twice over
    /// is not an undo.
    func present(_ request: ToastRequest) {
        guard let host else { return }
        removeCurrent()

        let toast = ToastView(request: request)
        toast.onAction = { [weak self] in
            request.action?()
            self?.dismiss()
        }
        toast.onHoverChanged = { [weak self] isHovered in
            guard let self else { return }
            isHovered ? holdOpen() : scheduleDismissal()
        }

        // Topmost in the pane: the band floats over the list, the settings sidebar, and
        // anything else the pane swaps in beneath it.
        host.addSubview(toast, positioned: .above, relativeTo: nil)
        current = toast

        let bottomConstraint = toast.bottomAnchor.constraint(
            equalTo: bottom,
            constant: -ToastDefaults.hostInset - ToastDefaults.rise
        )
        self.bottomConstraint = bottomConstraint

        // Fills the column it is given, up to its cap. The trailing pin is breakable so the cap
        // wins in a pane wider than the band should ever be.
        let trailing = toast.trailingAnchor.constraint(
            equalTo: host.trailingAnchor,
            constant: -ToastDefaults.hostInset
        )
        trailing.priority = .defaultHigh

        NSLayoutConstraint.activate([
            bottomConstraint,
            trailing,
            toast.leadingAnchor.constraint(
                equalTo: host.leadingAnchor,
                constant: ToastDefaults.hostInset
            ),
            toast.trailingAnchor.constraint(
                lessThanOrEqualTo: host.trailingAnchor,
                constant: -ToastDefaults.hostInset
            ),
            toast.widthAnchor.constraint(lessThanOrEqualToConstant: ToastDefaults.maxWidth)
        ])

        toast.alphaValue = 0
        host.layoutSubtreeIfNeeded()

        bottomConstraint.constant = -ToastDefaults.hostInset
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Design.Motion.appear
            context.allowsImplicitAnimation = true
            toast.animator().alphaValue = 1
            host.layoutSubtreeIfNeeded()
        }

        announce(request)
        scheduleDismissal()
    }

    /// Takes the current band away early — the action was taken, or what it reported no longer
    /// holds.
    func dismiss() {
        guard let toast = current else { return }
        stopClock()
        current = nil

        bottomConstraint?.constant = -ToastDefaults.hostInset - ToastDefaults.rise
        let host = self.host
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Design.Motion.vanish
            context.allowsImplicitAnimation = true
            toast.animator().alphaValue = 0
            host?.layoutSubtreeIfNeeded()
        }, completionHandler: {
            toast.removeFromSuperview()
        })
    }

    // MARK: - Private Methods

    /// Removes the band outright, with no animation and without running its action. Used when a
    /// second toast arrives: fading one out while the next slides in over it reads as a glitch
    /// rather than as a replacement.
    private func removeCurrent() {
        stopClock()
        current?.removeFromSuperview()
        current = nil
        bottomConstraint = nil
    }

    private func scheduleDismissal() {
        stopClock()
        guard current != nil else { return }
        dismissal = Timer.scheduledTimer(withTimeInterval: dwell, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    /// The pointer is on the band, so the clock stops: a way back that expires while it is being
    /// reached for is worse than no way back, because the reach is the moment the person has
    /// already decided.
    private func holdOpen() {
        stopClock()
    }

    private func stopClock() {
        dismissal?.invalidate()
        dismissal = nil
    }

    /// The band takes no focus and disappears by itself, so without this it is invisible to
    /// VoiceOver — the one part of the audience that cannot glance at a corner of the window.
    private func announce(_ request: ToastRequest) {
        guard let element = host?.window else { return }
        NSAccessibility.post(
            element: element,
            notification: .announcementRequested,
            userInfo: [
                .announcement: request.announcement,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }
}
