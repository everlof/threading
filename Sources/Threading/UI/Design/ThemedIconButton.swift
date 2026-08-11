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

    /// When the symbol backing the control becomes an `NSImage`.
    ///
    /// A hidden sidebar action still needs its real control shell from first paint: keyboard
    /// traversal and VoiceOver can reach it without a pointer. Its SF Symbol is presentation,
    /// though, and resolving every hidden row glyph made CoreUI part of cold launch. Deferred
    /// controls keep their geometry, action and accessibility contract, then resolve the latest
    /// symbol or custom image when first drawn or explicitly revealed.
    enum GlyphMaterialization {
        case immediate
        case deferred
    }

    /// What an icon button is for, which is what decides how big it is and how much air the glyph
    /// gets. Padding is the difference between the two, so stating both here is what makes it a
    /// system rule instead of arithmetic repeated at each call site.
    enum Target {

        /// A top-level action in the window's chrome.
        case toolbar

        /// Nested inside another control — a tab's close, a row's `⋯`.
        ///
        /// *Nested*, literally. A button standing **beside** a chip rather than inside anything
        /// is that chip's peer and takes its size from the `ControlRowView` they share: put it
        /// in the row and it is sized for you. This case answering both questions is what made
        /// the Compare tab's actions six points shorter than the chip they sat with.
        case inline

        /// The chevron half of a split control, welded to the press it belongs to — see
        /// `SplitIconButtonView`. A toolbar button's height on a narrower base, because the two
        /// halves of a split control are not equals: the press is the point and the chevron is
        /// the exception, and equal halves would offer them as the same choice twice.
        case splitMenu

        /// The chevron half of a **titled** split control — `SplitButtonView`, which welds the
        /// other ways to take a press onto a `ThemedButton`. The same ranking as `.splitMenu` —
        /// the press is the point, the chevron the exception — on the button's own base height
        /// rather than the toolbar's, because two halves of one plate must agree about how tall
        /// the plate is, and a chip-height press cannot share one with a toolbar-height chevron.
        case titledSplitMenu

        /// The narrow chevron beside a prompt's compact send glyph. Like `splitMenu`, it is the
        /// exceptional half of one decision; unlike the toolbar version it belongs inside the
        /// prompt's 18-point footer control group. Naming the role here keeps its 12×18 geometry
        /// out of the call site and prevents it from fighting `.inline`'s owned 20×20 constraints.
        case compactSplitMenu

        /// Standing beside a `ThemedButton`, offering the other way to take the same decision —
        /// the composer's clock next to Start Session: send it now, send it later.
        ///
        /// A peer of a *button*, not something nested in one, so `.inline`'s 20 was the wrong
        /// answer for the same reason it was wrong beside a chip (see `adopt`): the clock's
        /// hover raised a plate six points shorter than the primary it sits opposite, which
        /// reads as two rows pretending to be one — invisible under the System theme's soft
        /// corners, and unmissable under a square-cornered material like Bauhaus, where it drew
        /// as a hard plate that had missed its size. The measure is the button's own base
        /// height, and the glyph grows with it exactly as a `ControlRowView` promotion grows a
        /// member's — the same mark in a larger box would be more padding, not more button.
        case besidePrimary

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
            case .splitMenu:
                NSSize(
                    width: Design.Size.splitMenuWidth,
                    height: Design.Size.toolbarButtonHeight
                )
            case .titledSplitMenu:
                NSSize(
                    width: Design.Size.splitMenuWidth,
                    height: Design.Size.chipHeight
                )
            case .compactSplitMenu:
                NSSize(
                    width: Design.Size.compactSplitMenuWidth,
                    height: Design.Size.compactSubmitHeight
                )
            case .besidePrimary:
                NSSize(width: Design.Size.chipHeight, height: Design.Size.chipHeight)
            }
        }

        /// The glyph's slot. The remainder is the padding, equal on every side.
        var glyph: CGFloat {
            switch self {
            case .toolbar, .splitMenu: Design.Size.tabIconSlot
            case .compactSplitMenu: 8
            case .inline: Design.Size.inlineButtonGlyph
            case .besidePrimary, .titledSplitMenu:
                Design.Symbol.slot(inControlOfHeight: Design.Size.chipHeight)
            }
        }

        /// The size the symbol is *configured* at, as against the slot it must fit.
        ///
        /// Two numbers because they answer different questions: the slot is layout — what the
        /// padding is measured from — while the point size is optics. One hard-set 11pt
        /// configuration served both roles, which missed in both directions at once: toolbar
        /// glyphs floated small in a 16pt slot, and inline symbols wider than 12pt
        /// (`gearshape` renders 14×14 at 11pt) were shrunk *after* rendering, thinning the
        /// stroke the configuration had chosen. `Design.Symbol.image(_:slot:pointSize:)` is
        /// the fit.
        var glyphPointSize: CGFloat {
            switch self {
            case .toolbar, .splitMenu: Design.Symbol.toolbar
            case .compactSplitMenu: Design.Symbol.control
            case .inline: Design.Symbol.control
            case .besidePrimary, .titledSplitMenu: Design.Symbol.pointSize(forSlot: glyph)
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
            // The rest sit on a surface something else already drew — another control's fill,
            // the plate a split control shares, or the pane a primary already lifted from —
            // so the resting lift is invisible there.
            case .inline, .splitMenu, .titledSplitMenu, .compactSplitMenu, .besidePrimary:
                \.surfaceHover
            }
        }
    }

    var onPress: (() -> Void)?

    /// Whether this button draws its own fill and border, or leaves them to whoever hosts it.
    ///
    /// False for the halves of a split plate — `SplitIconButtonView`'s pair, `SplitButtonView`'s
    /// chevron — and *only* for a host that draws the surface itself: two halves each raising
    /// their own rounded rect is the seam those components exist to remove. Everything else about
    /// the button — the glyph, the focus ring, the press gesture, the accessibility — is
    /// unchanged, because none of it is the surface.
    var drawsSurface = true {
        didSet {
            guard drawsSurface != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Told to the host that draws this button's surface, whenever what it would draw changed.
    ///
    /// A host cannot observe a hover it does not track, and it must not track one of its own: two
    /// tracking areas over the same points answer in whichever order AppKit delivers them, which
    /// is how a raised half survives the pointer leaving it.
    var surfaceStateDidChange: (() -> Void)?

    /// Whether a host drawing for this button should raise its half — the pointer is on it, or
    /// holding it down.
    var isRaised: Bool { isHovered || isPressed }

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
    /// The presenter's dropdown owns the pointer while it is up — the held press's drag and
    /// release are forwarded to the open menu — so the button reads as held for exactly as
    /// long as its menu is, the way a menu-bar title does.
    var presentsMenu = false

    /// The menu a *secondary* click asks for, on a button whose press already does something.
    ///
    /// The alternative to `presentsMenu`, not a companion to it. A button that offers a choice on
    /// every press makes the common case cost two gestures — the sidebar's `+` asked "chat or
    /// terminal?" every time, and it is a chat nearly every time. So the press does the ordinary
    /// thing and the rest hangs off right-click, the way a row's own actions already do.
    ///
    /// Returning `false` lets the click fall through to whatever would have handled it, which is
    /// how a row keeps its own context menu when a button on it offers none.
    var onContextMenu: ((ThemedMenuAnchor) -> Bool)?

    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            needsDisplay = true
            surfaceStateDidChange?()
            setAccessibilityValue(isSelected)
        }
    }

    private let iconView = GlyphView()
    private var accessibilityName: String
    private let isEmphasized: Bool
    private let actionTarget: Target

    /// What the button is currently drawn at: the role's own measurements, until a control row
    /// it stands in states the row's.
    ///
    /// The role stays the button's identity — it still decides the hover fill and what the
    /// button is *for* — but the size is no longer a constant of it, because a peer of a
    /// theme-sized chip cannot be a constant. Nothing outside `ControlRowView` can write these:
    /// `adopt` takes a `ControlRowMetrics`, which only a row can make.
    private var drawnSize: NSSize
    private var drawnGlyph: CGFloat
    private var drawnGlyphPointSize: CGFloat

    /// What the slot holds, kept so it can be re-rendered when the slot changes size. A symbol
    /// has to be *configured* at the new size rather than scaled to it (see `Design.Symbol`),
    /// and that needs its name back.
    private var symbolName: String?
    private var customImage: NSImage?
    private(set) var hasMaterializedGlyph = false

    private var widthConstraint: NSLayoutConstraint?
    private var heightConstraint: NSLayoutConstraint?
    private(set) var isPressed = false {
        didSet {
            guard isPressed != oldValue else { return }
            needsDisplay = true
            surfaceStateDidChange?()
        }
    }

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
    private let releaseWatch = LocalEventMonitor()

    init(
        symbolName: String,
        accessibility: String,
        target: Target = .toolbar,
        isEmphasized: Bool = false,
        inkSource: InkSource = .backdrop,
        glyphMaterialization: GlyphMaterialization = .immediate
    ) {
        self.accessibilityName = accessibility
        self.isEmphasized = isEmphasized
        self.actionTarget = target
        drawnSize = target.size
        drawnGlyph = target.glyph
        drawnGlyphPointSize = target.glyphPointSize
        super.init(frame: .zero, inkSource: inkSource)
        setup(symbolName: symbolName, glyphMaterialization: glyphMaterialization)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup(
        symbolName: String,
        glyphMaterialization: GlyphMaterialization
    ) {
        translatesAutoresizingMaskIntoConstraints = false

        self.symbolName = symbolName
        addSubview(iconView)

        // The glyph is centred and the size states itself, so the padding is whatever is left
        // over — equal on all four sides, by construction rather than by a caller's arithmetic.
        // Nothing here takes a size from a call site: it is the role's, or the row's. The glyph
        // carries no size constraints of its own: it is configured to fit the slot (see
        // `glyphPointSize`), and pinning it to the slot was exactly the shrink-after-render this
        // replaced.
        let width = widthAnchor.constraint(equalToConstant: drawnSize.width)
        let height = heightAnchor.constraint(equalToConstant: drawnSize.height)
        widthConstraint = width
        heightConstraint = height
        NSLayoutConstraint.activate([
            width,
            height,
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        if glyphMaterialization == .immediate {
            materializeGlyphIfNeeded()
        }
    }

    override var intrinsicContentSize: NSSize { drawnSize }

    /// The padding held around the glyph — `(target − glyph) / 2`, by construction. What
    /// `PaneFooterView` and `ControlRowView` subtract to put the *ink* on a stated margin.
    var opticalHorizontalInset: CGFloat {
        (drawnSize.width - drawnGlyph) / 2
    }

    /// Draws whatever the slot holds at the size the slot currently is.
    private func renderSlot() {
        hasMaterializedGlyph = true
        if let customImage {
            // The slot cap is what keeps foreign artwork honest: an installed app's icon
            // arrives at whatever size LaunchServices holds, and a symbol's fitted
            // configuration cannot speak for it. Capped to the slot it draws exactly where a
            // symbol would.
            iconView.slot = NSSize(width: drawnGlyph, height: drawnGlyph)
            iconView.image = customImage
            return
        }
        iconView.slot = nil
        iconView.image = symbolName.flatMap {
            Design.Symbol.image($0, slot: drawnGlyph, pointSize: drawnGlyphPointSize)
        }
    }

    /// Crosses the presentation-only lazy boundary for a control that is about to be shown.
    /// Idempotent so both an explicit reveal and AppKit's first draw can safely ask.
    func materializeGlyphIfNeeded() {
        guard !hasMaterializedGlyph else { return }
        renderSlot()
    }

    /// Re-points the button at a different action, keeping its size and padding.
    ///
    /// One slot, two roles: a project row's `⋯` and a branch heading's gear are the same control
    /// in the same place, and swapping the glyph is the whole difference between them.
    func setSymbol(_ symbolName: String, accessibility: String) {
        // The custom image is cleared along with it, because `renderSlot` prefers one: a slot
        // that has held an app's icon must draw the next symbol at the size every other glyph
        // in the app has — configured to fit, never squeezed to.
        self.symbolName = symbolName
        customImage = nil
        if hasMaterializedGlyph { renderSlot() }
        accessibilityName = accessibility
        setAccessibilityTitle(accessibility)
    }

    /// The same slot, holding artwork whose silhouette is not the app's to draw — an installed
    /// application's own icon, read from LaunchServices.
    ///
    /// A symbol is what this button is for, and this is the documented exception: no glyph we
    /// could draw says "Xcode" as fast as Xcode's own icon does, which is the whole reason the
    /// file tree shows Finder's icons rather than ours. A non-template image ignores
    /// `contentTintColor`, so it keeps its own colours while everything the theme owns — the
    /// surface, the hover lift, the focus ring — stays ours. Passing nil empties the slot rather
    /// than leaving the previous app's mark behind.
    func setImage(_ image: NSImage?, accessibility: String) {
        customImage = image
        symbolName = nil
        if hasMaterializedGlyph { renderSlot() }
        accessibilityName = accessibility
        setAccessibilityTitle(accessibility)
    }

    override func applyInk(_ ink: Design.Ink) {
        iconView.tint = isEnabled ? ink.secondary : ink.quaternary
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        materializeGlyphIfNeeded()

        // Half of a split control draws no surface of its own: the plate underneath is one
        // shape, and a second one raised inside it is the seam `SplitIconButtonView` removes.
        // The ring still needs a silhouette to follow, so it takes the one that was not drawn.
        guard drawsSurface else {
            drawKeyboardFocus(
                around: ThemedSurface.Shape(
                    rect: bounds,
                    radius: Design.Radius.control(fitting: bounds.size)
                ),
                color: ink.label
            )
            applyGlyphTint()
            return
        }

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
        //
        // Under a bevel material a pressed or toggled-on button reads *sunken* — pressed-in
        // is what "active" has meant on a bevelled desktop since there were bevelled
        // desktops — and everything else raises only when it draws a surface at all.
        let shape = ThemedSurface.draw(
            bounds,
            fill: fill,
            border: border,
            radius: Design.Radius.control(fitting: bounds.size),
            bevel: (isPressed || isSelected) ? .sunken : .automatic
        )

        drawKeyboardFocus(around: shape, color: ink.label)

        applyGlyphTint()
    }

    /// The glyph reads against whatever is under it *now*: brighter while the button is selected
    /// or under the pointer, dimmed when it cannot be pressed. Stated once because both drawing
    /// paths — this button's own surface, and a host's — end here.
    private func applyGlyphTint() {
        iconView.tint = isEnabled
            ? (isSelected || isHovered ? ink.label : ink.secondary)
            : ink.quaternary
    }

    /// A raised half is drawn by the plate, not by this button, so the plate has to be told.
    override func hoverDidChange() {
        super.hoverDidChange()
        surfaceStateDidChange?()
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

    /// The secondary click, anchored where it landed — the idiom `ThemedMenuAnchor.pointer`
    /// states. A button offering no such menu passes the click on rather than eating it.
    override func rightMouseDown(with event: NSEvent) {
        guard isEnabled, let onContextMenu else {
            super.rightMouseDown(with: event)
            return
        }
        if !onContextMenu(.pointer(event.locationInWindow)) {
            super.rightMouseDown(with: event)
        }
    }

    private func beginWatchingForRelease() {
        endWatchingForRelease()
        guard let window else { return }
        pressTarget = window.convertToScreen(convert(bounds, to: nil))

        releaseWatch.install(matching: [.leftMouseUp, .leftMouseDragged, .leftMouseDown]) {
            [weak self] event in
            self?.track(event)
            return event
        }
    }

    private func endWatchingForRelease() {
        releaseWatch.remove()
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

    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityTitle() -> String? { accessibilityName }
    override func accessibilityPerformPress() -> Bool {
        performPress()
    }

    /// The pointerless route to the secondary click's menu, anchored to the button itself —
    /// and, for a button whose press *is* its menu, to that same menu.
    override func accessibilityPerformShowMenu() -> Bool {
        if let onContextMenu, isEnabled {
            return onContextMenu(.control)
        }
        guard presentsMenu else { return super.accessibilityPerformShowMenu() }
        return performPress()
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

// MARK: - ControlRowMember

extension ThemedIconButton: ControlRowMember {

    /// Stands at the row's height rather than the role's.
    ///
    /// **Square, at the row's height** — an action beside a chip is a peer of it, and the role's
    /// own size answers a different question: `.inline` means *nested inside another control*,
    /// which is what a tab's × is and what an action sharing a margin with a chip never was.
    /// The Compare tab's export and expand buttons were `.inline` for want of anywhere else to
    /// be, and so stood six points shorter than the chip they were meant to sit level with.
    ///
    /// The glyph grows with the button. A promoted 26pt button keeping its 12pt slot would be
    /// the same mark in a larger box — more padding, not more button — which reads as a target
    /// that missed rather than one that was sized.
    func adopt(_ metrics: ControlRowMetrics) {
        let size = NSSize(width: metrics.height, height: metrics.height)
        guard size != drawnSize || metrics.glyphSlot != drawnGlyph else { return }

        drawnSize = size
        drawnGlyph = metrics.glyphSlot
        drawnGlyphPointSize = metrics.glyphPointSize
        widthConstraint?.constant = size.width
        heightConstraint?.constant = size.height
        if hasMaterializedGlyph { renderSlot() }
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }
}
