import AppKit

/// The walkthrough's first page: pick the app's chrome, and the rest of the walkthrough —
/// built entirely from themed components under a `ThemedWindowController` — restyles itself
/// the moment a tile is clicked. That live answer is the whole argument for asking first.
final class OnboardingAppearancePageViewController: NSViewController, OnboardingPage {

    private enum Layout {
        /// Beside the heading rather than above it: stacked, the mark was the constraint the
        /// engine broke when thirteen tiles plus the header brushed the window's height —
        /// it slid off the top of the page while everything else held.
        static let markSide: CGFloat = 26
        /// Thirteen tiles have to fit a fixed 760×560 window under the flow's footer: five
        /// columns of 104-point swatches is the largest grid that does, measured on the
        /// render — four columns of 128 clipped the first row off the top.
        static let swatchSize = NSSize(width: 104, height: 72)
        static let columns = 5
        static let contentWidth: CGFloat = 640
    }

    var pageTitle: String { L10n.string("Appearance") }

    private let mark = ThreadingMarkView()
    private let grid = NSGridView()
    private var tiles: [(theme: AppTheme, item: NavigatorGridItemView, swatch: NSImageView)] = []
    private let appEvents = AppEventObservations()

    override func loadView() {
        view = NSView()
        setupViews()

        // Selection chrome and the swatches themselves both depend on the applied theme —
        // System's tile previews the appearance the theme just pinned.
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in
            self?.refreshTiles()
        }
    }

    func pageWillAppear() {
        guard !Design.Motion.reducesMotion else { return }
        mark.playDrawIn()
    }

    private func setupViews() {
        let heading = NSTextField(labelWithString: L10n.string("Make it yours"))
        heading.applyFont(.heading)
        heading.textColor = Design.Text.label
        heading.alignment = .center

        let caption = NSTextField(
            wrappingLabelWithString: L10n.string(
                "Threading dresses itself. Pick a look and everything follows it — including the rest of this setup. Change it anytime in Settings ▸ Themes."
            )
        )
        caption.applyFont(.body)
        caption.textColor = Design.Text.secondary
        caption.alignment = .center

        mark.setAccessibilityElement(false)
        let headingRow = NSStackView(views: [mark, heading])
        headingRow.orientation = .horizontal
        headingRow.alignment = .centerY
        headingRow.spacing = Design.Spacing.small

        grid.rowSpacing = Design.Spacing.inset
        grid.columnSpacing = Design.Spacing.inset
        grid.translatesAutoresizingMaskIntoConstraints = false
        buildTiles()

        let stack = NSStackView(views: [headingRow, caption, grid])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Design.Spacing.inset
        stack.setCustomSpacing(Design.Spacing.large, after: caption)
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: Design.Spacing.pane),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.bottomAnchor.constraint(
                lessThanOrEqualTo: view.bottomAnchor,
                constant: -Design.Spacing.pane
            ),
            caption.widthAnchor.constraint(lessThanOrEqualToConstant: Layout.contentWidth),
            mark.widthAnchor.constraint(equalToConstant: Layout.markSide),
            mark.heightAnchor.constraint(equalToConstant: Layout.markSide)
        ])
    }

    private func buildTiles() {
        tiles = AppThemeLibrary.stock.map { theme in
            let swatch = NSImageView()
            swatch.imageScaling = .scaleNone
            swatch.translatesAutoresizingMaskIntoConstraints = false
            swatch.setAccessibilityElement(false)
            NSLayoutConstraint.activate([
                swatch.widthAnchor.constraint(equalToConstant: Layout.swatchSize.width),
                swatch.heightAnchor.constraint(equalToConstant: Layout.swatchSize.height)
            ])

            let name = NSTextField(labelWithString: theme.name)
            name.applyFont(.control)
            name.textColor = Design.Text.label
            name.lineBreakMode = .byTruncatingTail
            name.alignment = .center
            name.setAccessibilityElement(false)

            let content = NSStackView(views: [swatch, name])
            content.orientation = .vertical
            content.alignment = .centerX
            content.spacing = Design.Spacing.small
            content.edgeInsets = NSEdgeInsets(
                top: Design.Spacing.small,
                left: Design.Spacing.small,
                bottom: Design.Spacing.small,
                right: Design.Spacing.small
            )
            name.widthAnchor.constraint(
                lessThanOrEqualToConstant: Layout.swatchSize.width
            ).isActive = true

            let item = NavigatorGridItemView(content: content)
            item.setAccessibilityTitle(theme.name)
            item.onActivate = {
                AppThemeLibrary.apply(theme)
            }
            return (theme, item, swatch)
        }

        for row in stride(from: 0, to: tiles.count, by: Layout.columns) {
            let slice = tiles[row..<min(row + Layout.columns, tiles.count)]
            grid.addRow(with: slice.map(\.item))
        }

        refreshTiles()
    }

    /// Re-resolves every tile against the currently applied theme: selection chrome, and the
    /// swatches — each drawn for the *tile's* theme in that theme's own appearance, so a grid
    /// under a dark chrome still shows the light themes light.
    private func refreshTiles() {
        let current = AppThemeLibrary.current.id
        for tile in tiles {
            tile.item.isSelected = tile.theme.id == current
            let appearance = tile.theme.mode.appearance
                ?? view.effectiveAppearance
            tile.swatch.image = ThemeSwatchImage.appSwatch(
                for: tile.theme,
                size: Layout.swatchSize,
                appearance: appearance
            )
        }
    }
}
