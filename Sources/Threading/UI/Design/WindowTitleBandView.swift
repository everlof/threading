import AppKit

/// The title band a chrome-takeover theme draws across the window's top: gradient, title, the
/// window identity, and the window's own buttons. Application commands live in the command
/// band below it; title-bar geometry should never depend on toolbar-sized controls.
///
/// This is the app-drawn half of what `.titled` provided. The behaviours a titlebar owes its
/// window are re-stated here one for one — a press drags the window, a double-click performs
/// the user's own System Settings choice (`TitlebarDoubleClick`, the same reading
/// `TitlebarActionWindow` does in native dress), and the band dims when the window is not key,
/// which is how a window has said "not me" since windows could overlap.
///
/// The gradient is drawn in `draw(_:)` rather than laid into a layer, the `ThemedControl`
/// lesson: a live theme switch repaints it with nothing to re-freeze. The title follows
/// `window.title` by observation, so whatever names the window names the band.
final class WindowTitleBandView: NSView, ThemedComponent {

    /// What a double-click performs — a closure for the same reason `TitlebarActionWindow`
    /// holds one: the gesture is only worth asserting against a known answer.
    var doubleClickAction: () -> TitlebarDoubleClick.Action = { TitlebarDoubleClick.preferredAction }

    /// A style stated by a fixture instead of resolved from the active theme; handed on to
    /// the band's own buttons so the cluster previews as one piece.
    var fixtureStyle: WindowChromeAppearance.Resolved? {
        didSet {
            [minimizeButton, zoomButton, closeButton].forEach { $0.fixtureStyle = fixtureStyle }
            apply()
        }
    }

    /// Key-state stated by a fixture, for the same reason: an unshown render window is never
    /// key, so without this the band's hero form — the active gradient — is unrenderable.
    var fixtureIsKey: Bool? {
        didSet {
            [minimizeButton, zoomButton, closeButton].forEach { $0.fixtureIsKey = fixtureIsKey }
            apply()
        }
    }

    private var resolvedStyle: WindowChromeAppearance.Resolved? {
        fixtureStyle ?? WindowChromeAppearance.resolve()
    }

    private var drawsAsKey: Bool {
        fixtureIsKey ?? (window == nil || window?.isKeyWindow == true)
    }

    private let titleLabel = NSTextField(labelWithString: "")
    private let appIcon = NSImageView()
    private let leadingStack = NSStackView()
    private let buttonStack = NSStackView()
    private(set) lazy var minimizeButton = WindowChromeButton(role: .minimize)
    private(set) lazy var zoomButton = WindowChromeButton(role: .zoom)
    private(set) lazy var closeButton = WindowChromeButton(role: .close)

    private let appEvents = AppEventObservations()
    nonisolated(unsafe) private var windowStateObservations: [NSObjectProtocol] = []
    private var centeredTitleConstraint: NSLayoutConstraint?
    private var leadingTitleConstraint: NSLayoutConstraint?

    // MARK: - Initialization

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setup()
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in self?.apply() }
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        windowStateObservations.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: - Contents

    /// What the band is currently titling the window, for a test to hold against what was
    /// set without reaching into the label.
    var displayedTitle: String { titleLabel.stringValue }

    /// The window controller pushes the title — it owns `updateWindowTitle` and is the one
    /// place the name is decided. Deliberately not KVO on `window.title`: the band lives in
    /// the window's own view tree, so on window dealloc an observation would unregister
    /// against an object mid-teardown, which is the deferred-detonation shape this feature
    /// already met once in `_NSWindowTransformAnimation`.
    func setTitle(_ title: String) {
        titleLabel.stringValue = title
    }

    /// An optional title-bar leading slot retained for authored previews and future identity
    /// furniture. Its guests keep their own semantic size; forcing toolbar controls down to the
    /// caption-button height created two conflicting required constraints.
    func setLeadingControls(_ views: [NSView]) {
        leadingStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for view in views {
            leadingStack.addArrangedSubview(view)
        }
    }

    // MARK: - Setup

    private func setup() {
        appIcon.image = NSApplication.shared.applicationIconImage
        appIcon.imageScaling = .scaleProportionallyUpOrDown
        appIcon.translatesAutoresizingMaskIntoConstraints = false
        appIcon.setAccessibilityElement(false)
        addSubview(appIcon)

        leadingStack.orientation = .horizontal
        leadingStack.alignment = .centerY
        leadingStack.spacing = Design.Spacing.tight
        leadingStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(leadingStack)

        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = Design.Spacing.hairline
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        [minimizeButton, zoomButton, closeButton].forEach(buttonStack.addArrangedSubview)
        addSubview(buttonStack)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.applyFont(.detail(weight: .bold))
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(titleLabel)

        let leadingTitle = titleLabel.leadingAnchor.constraint(
            equalTo: leadingStack.trailingAnchor,
            constant: Design.Spacing.medium
        )
        leadingTitleConstraint = leadingTitle
        centeredTitleConstraint = titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor)

        NSLayoutConstraint.activate([
            appIcon.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: Design.Spacing.tight
            ),
            appIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            appIcon.widthAnchor.constraint(equalToConstant: 14),
            appIcon.heightAnchor.constraint(equalToConstant: 14),

            leadingStack.leadingAnchor.constraint(
                equalTo: appIcon.trailingAnchor,
                constant: Design.Spacing.hairline
            ),
            leadingStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            buttonStack.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -Design.Spacing.tight
            ),
            buttonStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            leadingTitle,
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: buttonStack.leadingAnchor,
                constant: -Design.Spacing.medium
            )
        ])
    }

    // MARK: - Resolution

    /// Re-reads the resolved chrome: title ink for the current key state, alignment, and the
    /// gradient the next draw uses.
    private func apply() {
        let resolved = resolvedStyle
        let isKey = drawsAsKey
        titleLabel.textColor = isKey
            ? resolved?.ink ?? .white
            : resolved?.inactiveInk ?? .white

        let centered = resolved?.titleAlignment == .center
        centeredTitleConstraint?.isActive = centered
        leadingTitleConstraint?.isActive = !centered
        if !centered {
            leadingTitleConstraint?.isActive = true
        }

        needsDisplay = true
    }

    // MARK: - Window Following

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        windowStateObservations.forEach(NotificationCenter.default.removeObserver)
        windowStateObservations = []

        guard let newWindow else { return }

        for name in [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification
        ] {
            windowStateObservations.append(NotificationCenter.default.addObserver(
                forName: name,
                object: newWindow,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply() }
            })
        }
    }

    // MARK: - Titlebar Behaviours

    /// A press on the band's own ground moves the window; a double-click performs the user's
    /// System Settings choice. Clicks the controls claim never arrive — the responder chain
    /// asks them first, the same reasoning `TitlebarActionWindow.mouseDown` records.
    override func mouseDown(with event: NSEvent) {
        guard event.clickCount < TitlebarDoubleClick.clickCount else {
            perform(doubleClickAction())
            return
        }
        window?.performDrag(with: event)
    }

    /// The direct operations rather than `perform*`, the `WindowChromeButton` rule: the
    /// perform forms animate a standard button a frameless window does not have, and refuse.
    private func perform(_ action: TitlebarDoubleClick.Action) {
        switch action {
        case .zoom: window?.zoom(nil)
        case .minimize: window?.miniaturize(nil)
        case .doNothing: break
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let resolved = resolvedStyle else { return }
        let gradient = drawsAsKey ? resolved.activeGradient : resolved.inactiveGradient

        guard gradient.colors.count >= 2,
              let drawn = NSGradient(
                  colors: gradient.colors,
                  atLocations: gradient.locations,
                  colorSpace: .sRGB
              ) else {
            (gradient.colors.first ?? Design.Surface.ground).setFill()
            bounds.fill()
            return
        }

        // The document's angle is CSS's — degrees clockwise from "toward the top" —
        // and `NSGradient` wants degrees counterclockwise from "toward the trailing edge".
        drawn.draw(in: bounds, angle: 90 - gradient.angleDegrees)
    }

    // MARK: - Accessibility

    /// The band itself is furniture; its controls speak for themselves. Announced as a group
    /// so VoiceOver users hear the window's controls as one cluster, the way the titlebar was.
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
}
