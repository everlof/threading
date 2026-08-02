import AppKit

// MARK: - Defaults

enum ExtensionDisclosureDefaults {
    /// The sidebar's dwell before the second level opens — a reveal that behaves differently
    /// in each corner of the app is two gestures to learn — then a grace for the pointer to
    /// cross the gap into what it opened, held while the pointer rests there. The detail is
    /// the one level allowed to carry actions, and a surface that closes as you reach for it
    /// is worse than no surface.
    static let popoverPolicy = HoverPopoverScheduler.Policy(
        openDelay: SessionPopoverDefaults.hoverDelay,
        closeGrace: 0.25,
        holdsWhilePointerOnPopover: true
    )

    static let contentWidth: CGFloat = 260

    /// Past this the detail scrolls. A second level is a reading, not a page: a popover that
    /// grows to the height of the screen has stopped being one.
    static let maximumContentHeight: CGFloat = 320

    /// The mark that says a reading has more behind it. `Design.Symbol.chevron` is the size the
    /// design system reserves for a hint rather than a control, which is what this is.
    static let markSymbol = "chevron.right"
}

// MARK: - View

/// One summary with a second level behind it, and the whole gesture that opens it.
///
/// An extension states that a reading has more behind it and what that more says. Everything
/// about the reveal is Threading's: the dwell before it opens, the surface it opens on, where
/// that surface is placed, how far it grows before it scrolls, and what closes it. This is the
/// same split every other extension surface makes, applied to a gesture instead of to paint.
///
/// Both levels are rendered by the *same* renderer pass, which is what keeps a button in the
/// detail working: `ExtensionNodeHostView` owns the target/action bridge for every button in
/// its tree, and AppKit's `target` is weak, so a detail built later by something else would
/// hand back buttons whose action goes nowhere.
@MainActor
final class ExtensionDisclosureNodeView: NSView {

    // MARK: - Properties

    /// Exposed so a test can assert what the reveal put on screen without driving a real
    /// pointer across a real popover.
    private(set) var detailContent: NSView?
    private(set) var isRevealed = false

    /// The revealed level's views, built with the summary and held until it is asked for.
    ///
    /// Reachable from a test because "the detail's buttons are wired to the host's action
    /// bridge" is the property that keeps an action working, and it is true from construction
    /// rather than from presentation — which is the whole reason they are built together.
    var detailViewsForTesting: [NSView] { detailViews }

    private let disclosureID: String
    private let detailViews: [NSView]
    private let row = NSStackView()
    private let mark = NSImageView()
    private var popover: ThemedPopover?

    /// Decides when the dwell opens the detail and when leaving closes it; a click bypasses
    /// it either way.
    private lazy var popoverScheduler: HoverPopoverScheduler = {
        let scheduler = HoverPopoverScheduler(policy: ExtensionDisclosureDefaults.popoverPolicy)
        scheduler.onPresent = { [weak self] in self?.reveal() }
        scheduler.onDismiss = { [weak self] in self?.dismiss() }
        return scheduler
    }()
    private var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            applyBackground()
        }
    }

    // MARK: - Initialization

    init(id: String, summary: NSView, detail: [NSView]) {
        disclosureID = id
        detailViews = detail
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerCurve = .continuous
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("extension.disclosure.\(id)")
        setAccessibilityHelp(L10n.string("Show details"))
        setAccessibilityExpanded(false)

        mark.image = NSImage(
            systemSymbolName: ExtensionDisclosureDefaults.markSymbol,
            accessibilityDescription: nil
        )
        mark.symbolConfiguration = Design.Symbol.configuration(Design.Symbol.chevron)
        mark.contentTintColor = Design.Text.tertiary
        mark.setContentHuggingPriority(.required, for: .horizontal)

        summary.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Design.Spacing.small
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(summary)
        row.addArrangedSubview(mark)
        addSubview(row)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.tight),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Spacing.tight)
        ])
        applyBackground()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Reveal

    /// Opens the second level, or does nothing if it is already open.
    ///
    /// Public to the host rather than private to the pointer: a click and a dwell are two ways
    /// into one presentation, and a test is a third.
    func reveal() {
        guard window != nil, popover?.isShown != true else { return }
        popoverScheduler.cancelPendingWork()

        let content = makeDetailSurface()
        detailContent = content.view

        let presented = HostPopoverFactory.make(.extensionNodeDetail)
        presented.contentViewController = content
        // Transient, so a click anywhere outside dismisses it — the reveal is a reading the
        // reader is holding open, not a mode they have entered.
        presented.behavior = .transient
        presented.animates = false
        presented.onClose = { [weak self, weak presented] in
            guard let self, self.popover === presented else { return }
            self.popover = nil
            self.detailContent = nil
            self.isRevealed = false
            self.setAccessibilityExpanded(false)
        }
        // Toward the pane, not off the edge of it: the card this usually rides is pinned to the
        // window's trailing edge, and `minX` is the only side with room. AppKit still flips it
        // when there is not.
        presented.show(relativeTo: bounds, of: self, preferredEdge: .minX)

        popover = presented
        isRevealed = true
        setAccessibilityExpanded(true)
    }

    func dismiss() {
        popoverScheduler.cancelPendingWork()
        popover?.close()
        popover = nil
        detailContent = nil
        isRevealed = false
        setAccessibilityExpanded(false)
    }

    /// The detail on its own surface: the rows the extension supplied, stacked, scrolling once
    /// they outgrow the height a popover should have.
    ///
    /// Built independently from the gesture that presents it, the same separation
    /// `SessionRowView.makeSessionHoverCard` makes — the surface is what an extension can be
    /// wrong about, and asserting it should not require a window on screen with a live popover
    /// in it.
    func makeDetailSurface() -> NSViewController {
        let stack = NSStackView(views: detailViews)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.small
        stack.translatesAutoresizingMaskIntoConstraints = false

        // The pointer bridge: the policy holds the detail open while the pointer rests on it,
        // so crossing the gap from the row does not lose it.
        let container = HoverTrackingView()
        container.onHoverChange = { [weak self] hovering in
            self?.popoverScheduler.popoverHoverChanged(hovering)
        }
        container.translatesAutoresizingMaskIntoConstraints = false

        let scroll = ThemedScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = stack

        container.addSubview(scroll)
        let height = scroll.heightAnchor.constraint(
            lessThanOrEqualToConstant: ExtensionDisclosureDefaults.maximumContentHeight
        )
        let fits = scroll.heightAnchor.constraint(equalTo: stack.heightAnchor)
        fits.priority = .defaultHigh
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(
                equalToConstant: ExtensionDisclosureDefaults.contentWidth
                    + 2 * Design.Spacing.inset
            ),
            scroll.topAnchor.constraint(
                equalTo: container.topAnchor,
                constant: Design.Spacing.inset
            ),
            scroll.bottomAnchor.constraint(
                equalTo: container.bottomAnchor,
                constant: -Design.Spacing.inset
            ),
            scroll.leadingAnchor.constraint(
                equalTo: container.leadingAnchor,
                constant: Design.Spacing.inset
            ),
            scroll.trailingAnchor.constraint(
                equalTo: container.trailingAnchor,
                constant: -Design.Spacing.inset
            ),
            stack.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            height,
            fits
        ])

        let controller = NSViewController()
        controller.view = container
        return controller
    }

    // MARK: - Interaction

    override func mouseDown(with event: NSEvent) {
        // A click is the deliberate way in, and the way out of one opened by dwelling.
        popoverScheduler.cancelPendingWork()
        if popover?.isShown == true {
            dismiss()
        } else {
            reveal()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        popoverScheduler.pointerEntered()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        popoverScheduler.pointerExited()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))

        // The row can slide out from under a pointer that never moved — the card it rides is
        // pinned to a pane that opens and closes. See `NSView.hoverIsStale`.
        if hoverIsStale(isHovered) {
            isHovered = false
            popoverScheduler.pointerExited()
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { dismiss() }
    }

    // MARK: - Appearance

    private func applyBackground() {
        layer?.cornerRadius = Design.Radius.control
        applyLayerBackground(isHovered ? Design.Surface.controlHover : .clear)
    }
}
