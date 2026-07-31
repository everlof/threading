import AppKit

/// Every icon-only button in the app: the toolbar's actions, a tab's close, a sidebar row's `⋯`.
///
/// **One component, because padding is a property of the system and not of a call site.** These
/// were three separate treatments — a toolbar button, a `ThemedButton` with `isBordered = false`
/// and a hand-set `hoverFill`, and a bare button squeezed into a row's fixed slot — each stating
/// its own target size, its own glyph size and therefore its own padding. The `⋯` in a sidebar row
/// and the `×` in a tab sat at visibly different insets for no reason anyone chose.
///
/// So a caller names the **role** (`Target`) rather than a size. There is no `NSSize` parameter:
/// that is the seam a fourth, slightly-different button would come in through.
///
/// It draws from an `InkSource` rather than the chrome roles, which is what lets the same button
/// serve the toolbar — floating over the terminal's own palette — and a tab inside the chrome.
final class ThemedIconButton: BackdropThemedControl, OpticalInsetProviding {

    /// What an icon button is for, which is what decides how big it is and how much air the glyph
    /// gets. Padding is the difference between the two, so stating both here is what makes it a
    /// system rule instead of arithmetic repeated at each call site.
    enum Target {

        /// A top-level action in the window's chrome.
        case toolbar

        /// Nested inside another control — a tab's close, a row's actions.
        case inline

        var size: NSSize {
            switch self {
            case .toolbar:
                NSSize(
                    width: Design.Size.toolbarButtonWidth,
                    height: Design.Size.toolbarButtonHeight
                )
            case .inline:
                NSSize(
                    width: Design.Size.inlineButtonTarget,
                    height: Design.Size.inlineButtonTarget
                )
            }
        }

        /// The glyph inside. The remainder is the padding, equal on every side.
        var glyph: CGFloat {
            switch self {
            case .toolbar: Design.Size.tabIconSlot
            case .inline: Design.Size.inlineButtonGlyph
            }
        }

        /// What the resting hover lifts to, which depends on what the button is sitting on.
        ///
        /// A toolbar button sits on the bare backdrop, so `surface` is a lift. An inline one sits
        /// on another control's fill — which is *already* `surface` — so the same value is
        /// invisible and it has to go a step further. This was previously a `hoverFill` set by
        /// hand at the one call site that had noticed; stating it per role is what stops the next
        /// nested button from being the one that did not.
        var hoverFill: KeyPath<Design.Ink, NSColor> {
            switch self {
            case .toolbar: \.surface
            case .inline: \.surfaceHover
            }
        }
    }

    var onPress: (() -> Void)?

    /// Set when the press opens a menu rather than performing an action.
    ///
    /// **A menu opens on the press, not on the release.** That is the platform's gesture — press,
    /// drag onto an item, release — and `ChipView` and `ThemedPopUp` already present theirs that
    /// way. It is also the only *reliable* one, which is why this exists at all: a press that
    /// waits for its release depends on AppKit routing that release back to this exact view
    /// instance, and nothing guarantees it will. A sidebar row rebuilt between the two takes the
    /// click with it — `reloadData()` hands every cell back to the reuse pool, and a detached view
    /// is sent no mouse-up while the view that replaced it is sent none either. The press then
    /// disappears with nothing on screen to say so, which is the `⋯` that "needs three or four
    /// presses". Measured: a view removed between a synthesised down and up receives one
    /// `mouseDown` and no `mouseUp`, and so does its replacement.
    ///
    /// `NSMenu.popUp` is modal, so the button reads as held for exactly as long as its menu is up
    /// and the still-held mouse tracks the menu rather than this button.
    var presentsMenu = false

    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            needsDisplay = true
            setAccessibilityValue(isSelected)
        }
    }

    private let iconView = NSImageView()
    private var accessibilityName: String
    private let isEmphasized: Bool
    private let actionTarget: Target
    private var isPressed = false { didSet { needsDisplay = true } }

    /// The action this press will run, taken at the moment the press began.
    ///
    /// A press is aimed at what the button *was* when it went down. Reading `onPress` again at the
    /// release would run whatever the button has become in between — and a sidebar row is handed
    /// back to the reuse pool and re-pointed at a different session whenever the tree's shape
    /// changes. That turns a lost press into a worse bug than the one being fixed: archiving a
    /// session the user never aimed at.
    private var pressedAction: (() -> Void)?

    /// Where the press was aimed, in screen coordinates, captured for the same reason.
    ///
    /// A detached view has no window to convert through, so a release cannot be tested against
    /// `bounds` once the row is gone. Screen space is the one frame of reference that outlives the
    /// view hierarchy the press started in.
    private var pressTarget: NSRect = .zero

    /// The release, watched at the application rather than waited for at this view.
    ///
    /// AppKit routes a mouse-up to the view that took the mouse-down and to no other, and delivers
    /// nothing at all when that view has been detached in between — which is exactly what
    /// `reloadData()` does to every row it recycles. The `⋯` escaped this by opening its menu on
    /// the press (see `presentsMenu`); an action button cannot, because acting on the press is the
    /// wrong gesture for an action and gives up the drag-out-to-cancel affordance below.
    ///
    /// So the release is *read from the event stream* instead. The monitor belongs to the
    /// application, outlives this view, and completes the gesture the user actually made whether
    /// or not the row survived it. Every action button gets this by construction — a button a row
    /// grows later, ours or an extension's, is not one more call site that has to know.
    nonisolated(unsafe) private var releaseWatch: Any?

    init(
        symbolName: String,
        accessibility: String,
        target: Target = .toolbar,
        isEmphasized: Bool = false,
        inkSource: InkSource = .backdrop
    ) {
        self.accessibilityName = accessibility
        self.isEmphasized = isEmphasized
        self.actionTarget = target
        super.init(frame: .zero, inkSource: inkSource)
        setup(symbolName: symbolName)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup(symbolName: String) {
        translatesAutoresizingMaskIntoConstraints = false

        iconView.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: nil
        )
        iconView.symbolConfiguration = Design.Symbol.configuration(Design.Symbol.control)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        // The glyph is centred and the target states its own size, so the padding is whatever is
        // left over — equal on all four sides, by construction rather than by a caller's
        // arithmetic. Nothing here takes a size from outside.
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: actionTarget.size.width),
            heightAnchor.constraint(equalToConstant: actionTarget.size.height),
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: actionTarget.glyph),
            iconView.heightAnchor.constraint(equalToConstant: actionTarget.glyph)
        ])
    }

    override var intrinsicContentSize: NSSize { actionTarget.size }

    /// The padding the role holds around its glyph — `(target − glyph) / 2`, stated by the
    /// role by construction. What `PaneFooterView` subtracts to put the ink on a margin.
    var opticalHorizontalInset: CGFloat {
        (actionTarget.size.width - actionTarget.glyph) / 2
    }

    /// Re-points the button at a different action, keeping its size and padding.
    ///
    /// One slot, two roles: a project row's `⋯` and a branch heading's gear are the same control
    /// in the same place, and swapping the glyph is the whole difference between them.
    func setSymbol(_ symbolName: String, accessibility: String) {
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        accessibilityName = accessibility
        setAccessibilityTitle(accessibility)
    }

    override func applyInk(_ ink: Design.Ink) {
        iconView.contentTintColor = isEnabled ? ink.secondary : ink.quaternary
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let active = isSelected || isEmphasized
        let fill: NSColor
        if isPressed {
            fill = ink.surfaceHover
        } else if active {
            fill = isHovered ? ink.surfaceHover : ink.surface
        } else {
            fill = isHovered ? ink[keyPath: actionTarget.hoverFill] : .clear
        }

        let border = active ? ink.border : nil
        // A rounded rect, not a pill. These are square, so a pill radius is a *circle*, and a row
        // of circles beside the rounded tabs and chips they sit with reads as a second silhouette
        // in one strip of chrome. `Design.Radius.control` is the one a theme states for exactly
        // this: small things nested in the window's own furniture.
        let shape = ThemedSurface.draw(
            bounds,
            fill: fill,
            border: border,
            radius: Design.Radius.control(fitting: bounds.size)
        )

        drawKeyboardFocus(around: shape, color: ink.label)

        iconView.contentTintColor = isEnabled
            ? (isSelected || isHovered ? ink.label : ink.secondary)
            : ink.quaternary
    }

    /// **A press does not take the keyboard focus.** Tab still reaches this button — that is what
    /// `acceptsFirstResponder` and the ring in `draw(_:)` are for — but a *click* leaves the focus
    /// where it was, which is what every AppKit button does.
    ///
    /// It used to call `makeFirstResponder(self)` here, and in a sidebar row that is visible: the
    /// outline view resigns, its selected row drops from emphasized to unemphasized, and under the
    /// System theme that is the difference between the accent blue and a flat grey. Pressing a
    /// row's `⋯` recoloured the selection of a row it had nothing to do with — reported as the
    /// selection being "sometimes gray sometimes blue".
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true

        // The menu is the whole gesture: it takes the still-held mouse from here and returns only
        // once it has closed, so there is no release left for this button to wait for.
        if presentsMenu {
            performPress()
            isPressed = false
            return
        }

        pressedAction = onPress
        beginWatchingForRelease()
    }

    private func beginWatchingForRelease() {
        endWatchingForRelease()
        guard let window else { return }
        pressTarget = window.convertToScreen(convert(bounds, to: nil))

        releaseWatch = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseUp, .leftMouseDragged, .leftMouseDown]
        ) { [weak self] event in
            self?.track(event)
            return event
        }
    }

    private func endWatchingForRelease() {
        guard let releaseWatch else { return }
        NSEvent.removeMonitor(releaseWatch)
        self.releaseWatch = nil
    }

    /// Where an event happened, in screen space — the one frame of reference that outlives the
    /// view hierarchy the press started in. An event carrying no window already reports its
    /// location there.
    private func screenLocation(of event: NSEvent) -> NSPoint {
        guard let window = event.window else { return event.locationInWindow }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    private func track(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDragged:
            isPressed = pressTarget.contains(screenLocation(of: event))
        case .leftMouseUp:
            completePress(firing: isPressed && pressTarget.contains(screenLocation(of: event)))
        default:
            // A fresh press supersedes this one. Without this the gesture would outlive itself:
            // a release the app never saw — the pointer left it — would leave the watch armed
            // for an unrelated click somewhere else entirely.
            completePress(firing: false)
        }
    }

    /// Ends the gesture exactly once, whichever half of the app got there first.
    private func completePress(firing shouldFire: Bool) {
        let action = pressedAction
        pressedAction = nil
        isPressed = false
        endWatchingForRelease()
        guard shouldFire, isEnabled else { return }
        action?()
    }

    /// A drag out of the button releases the press without firing — the change-your-mind
    /// affordance `ThemedButton` already has, and the reason the fill follows the pointer.
    ///
    /// Without it the press was decided at the release and shown nowhere: a slip of a few points
    /// off a 20-point target cancelled silently, leaving the button drawn as though it had been
    /// pressed all along.
    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, !presentsMenu else { return }
        isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    /// The same decision for a view still in its window, and the only one when a press is
    /// delivered straight to the view. Whichever arrives first ends the gesture, so a press
    /// completed by the watch above is already spent by the time this runs.
    override func mouseUp(with event: NSEvent) {
        guard !presentsMenu else { return }

        completePress(
            firing: isPressed && bounds.contains(convert(event.locationInWindow, from: nil))
        )
    }

    deinit {
        if let releaseWatch { NSEvent.removeMonitor(releaseWatch) }
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityTitle() -> String? { accessibilityName }
    override func accessibilityPerformPress() -> Bool {
        performPress()
    }

    override func performPrimaryAction() -> Bool {
        performPress()
    }

    @discardableResult
    private func performPress() -> Bool {
        guard isEnabled else { return false }
        onPress?()
        return true
    }
}
