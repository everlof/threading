import AppKit

// MARK: - Defaults

enum AboutWindowDefaults {

    /// The brand plate and the mark inside it. The plate is the app icon's job on this window —
    /// a home for the mark, and the surface the theme's glow has something to sit on — so it
    /// carries the panel radius rather than an icon-shaped constant of its own.
    static let plateSide: CGFloat = 88
    static let markSide: CGFloat = 52

    /// The one large string on the window.
    static let wordmarkSize: CGFloat = 22

    /// A floor rather than a width. The grid's labels are localized, and a panel sized to fit
    /// German would look starved in English; a panel sized to English clips German. So the
    /// content states the narrowest it should ever look and grows from there.
    static let minimumContentWidth: CGFloat = 240
}

// MARK: - Window

/// What the app says about itself.
///
/// This replaces `orderFrontStandardAboutPanel`, which drew the app icon, the name and the version
/// pair in system chrome — a window in nobody's theme, and the only surface in the app still
/// answering "what build is this?" with two numbers and no way to find out more. The window is
/// ours now, so the mark stitches itself in the way it does at launch, the ground carries the
/// theme's own backdrop, and every reading `BuildDetails` can take is on it rather than being
/// reachable only by hovering three letters in the sidebar's footer.
///
/// One window, reused. Repeated visits to the menu item raise the existing one and replay the
/// mark's draw-in, because that beat is the reason to open this window twice.
@MainActor
final class AboutWindowController: ThemedWindowController {

    // MARK: - Properties

    private let about = AboutViewController()

    // MARK: - Initialization

    init() {
        let window = NSWindow(
            contentRect: .zero,
            // Not resizable and not miniaturizable: the panel states a fixed set of readings and
            // has no second size worth having. `.fullSizeContentView` with a transparent titlebar
            // is what lets our ground run to the window's own rounded corners instead of AppKit
            // drawing a material bar above it — the same combination the main window uses, and
            // for the same reason.
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        // Behind the app-owned ground, so the corners AppKit masks are the theme's colour rather
        // than the system's default window grey. A dynamic role, so it re-resolves with the rest.
        window.backgroundColor = Design.Surface.ground
        window.isReleasedWhenClosed = false
        window.title = L10n.format("About %@", AppInfo.name)

        super.init(window: window)

        // Assigning the content view controller sizes the window to its fitting size.
        contentViewController = about
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public Methods

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        about.playBrandFlourish()
    }

    /// Escape closes it, like every other transient surface in the app. The window controller is
    /// the responder that reliably sees the key: this window has no control that takes focus, so
    /// the chain runs from the window itself straight to here.
    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

// MARK: - Content

/// The About window's content: the mark, the app's name, the version pair with its channel mark,
/// and the build behind it.
@MainActor
final class AboutViewController: NSViewController {

    // MARK: - Properties

    private let mark = ThreadingMarkView()
    private let details: BuildDetails

    // MARK: - Initialization

    init(details: BuildDetails = .current) {
        self.details = details
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public Methods

    /// Stitches the mark in. One-shot, and nothing at all under Reduce Motion — the mark's own
    /// rule, not a second copy of it here.
    func playBrandFlourish() {
        mark.playDrawIn()
    }

    // MARK: - Lifecycle

    override func loadView() {
        let root = ThemedSurfaceView()
        // `.fixed(0)`: the window frame owns this surface's corners, so the ground states none of
        // its own. The backdrop pattern is the theme's, which is what keeps a period chrome from
        // arriving here as a flat rectangle in the right colours.
        root.applySurface(fill: Design.Surface.ground, radius: .fixed(0), pattern: .backdrop)

        let plate = brandPlate()
        let wordmark = self.wordmark()
        let versionRow = self.versionRow()
        let card = detailCard()

        let stack = NSStackView(views: [plate, wordmark, versionRow, card])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.spacing = Design.Spacing.large
        // The name belongs to the version under it, and both belong to the mark above them: three
        // gaps of one size would read as three unrelated lines.
        stack.setCustomSpacing(Design.Spacing.small, after: wordmark)
        stack.setCustomSpacing(Design.Spacing.large, after: versionRow)

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: Design.Spacing.pane),
            stack.leadingAnchor.constraint(
                equalTo: root.leadingAnchor,
                constant: Design.Spacing.pane
            ),
            stack.trailingAnchor.constraint(
                equalTo: root.trailingAnchor,
                constant: -Design.Spacing.pane
            ),
            stack.bottomAnchor.constraint(
                equalTo: root.bottomAnchor,
                constant: -Design.Spacing.pane
            ),
            stack.widthAnchor.constraint(
                greaterThanOrEqualToConstant: AboutWindowDefaults.minimumContentWidth
            ),
            // A centred stack does not stretch its rows, and a card as wide as the words above it
            // is a card that keeps moving. This one spans the content.
            card.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        view = root
    }

    // MARK: - Private Methods

    private func brandPlate() -> NSView {
        let plate = ThemedSurfaceView()
        plate.applySurface(
            fill: Design.Surface.elevated,
            radius: .panel,
            border: Design.Surface.border,
            glow: true
        )

        mark.translatesAutoresizingMaskIntoConstraints = false
        mark.setAccessibilityElement(false)
        plate.addSubview(mark)

        NSLayoutConstraint.activate([
            plate.widthAnchor.constraint(equalToConstant: AboutWindowDefaults.plateSide),
            plate.heightAnchor.constraint(equalToConstant: AboutWindowDefaults.plateSide),
            mark.widthAnchor.constraint(equalToConstant: AboutWindowDefaults.markSide),
            mark.heightAnchor.constraint(equalToConstant: AboutWindowDefaults.markSide),
            mark.centerXAnchor.constraint(equalTo: plate.centerXAnchor),
            mark.centerYAnchor.constraint(equalTo: plate.centerYAnchor)
        ])
        return plate
    }

    /// The app's own name, deliberately not the sidebar's brand row: a theme may rename that row
    /// to whatever chrome it is imitating, and this window is the one place that has to say which
    /// application a bug report is about.
    private func wordmark() -> NSTextField {
        let label = NSTextField(labelWithString: AppInfo.name)
        label.applyFont(.wordmark(size: AboutWindowDefaults.wordmarkSize))
        label.textColor = Design.Text.label
        return label
    }

    private func versionRow() -> NSView {
        let version = NSTextField(labelWithString: details.versionSummary)
        // Body-sized, not detail-sized. It sits on the ground rather than on the card, so it is
        // the one reading with the theme's backdrop pattern behind it — and Neo Brutalism's dots
        // land in the middle of 11pt digits. It is also the reading this window exists to state,
        // which is the better argument for the size.
        version.applyFont(.numericBody)
        version.textColor = Design.Text.secondary
        // Selectable so the pair can be copied into a report. The platform's own About panel
        // allows this, and it is the only reason anybody drags across a version number.
        version.isSelectable = true

        let row = NSStackView(views: [version])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = Design.Spacing.small

        // The same mark the sidebar's footer wears, with the same Help Tag on it. A release build
        // contributes none, and the row is then just the version.
        if let badge = BuildChannelBadge.make(details) {
            row.addArrangedSubview(badge)
        }
        return row
    }

    /// The readings on a panel of their own.
    ///
    /// Not decoration, and not originally there: the ground carries the theme's backdrop pattern,
    /// and Neo Brutalism's is a field of dots on a fixed pitch that landed *inside* the glyphs of a
    /// 11pt spec sheet. A pattern is stated for a theme's large structural grounds; a block of
    /// small readings is the opposite of one, so it gets the surface that role exists for
    /// (`Design.Surface.panel` — "a container holding content"). The card also does the separating
    /// a hairline was doing above it, so the rule is gone rather than drawn on top of a card edge.
    private func detailCard() -> NSView {
        let card = ThemedSurfaceView()
        card.applySurface(
            fill: Design.Surface.panel,
            radius: .panel,
            border: Design.Surface.border
        )

        let grid = detailGrid()
        grid.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(grid)

        // Measured from the radius rather than stated flat, so a square-cornered theme is not
        // padded for a curve it does not draw.
        let padding = Design.Spacing.inset(inside: SurfaceRadius.panel)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: card.topAnchor, constant: padding),
            grid.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -padding),
            grid.leadingAnchor.constraint(
                greaterThanOrEqualTo: card.leadingAnchor,
                constant: padding
            ),
            grid.trailingAnchor.constraint(
                lessThanOrEqualTo: card.trailingAnchor,
                constant: -padding
            ),
            grid.centerXAnchor.constraint(equalTo: card.centerXAnchor)
        ])
        return card
    }

    /// The build as a spec sheet: trailing labels against leading readings, so the values line up
    /// as one column to read down rather than as a ragged list.
    private func detailGrid() -> NSGridView {
        let rows: [[NSView]] = details.entries.map { entry in
            let label = NSTextField(labelWithString: entry.label)
            label.applyFont(.detail())
            label.textColor = Design.Text.tertiary

            let value = NSTextField(labelWithString: entry.value)
            value.applyFont(.detail())
            value.textColor = Design.Text.secondary
            value.isSelectable = true

            return [label, value]
        }

        let grid = NSGridView(views: rows)
        grid.rowSpacing = Design.Spacing.small
        grid.columnSpacing = Design.Spacing.medium
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        grid.setAccessibilityIdentifier("about.buildDetails")
        return grid
    }
}
