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
        /// A name is product information on this screen, so tiles use four readable columns
        /// and the grid scrolls instead of truncating thirteen choices into five cramped ones.
        static let swatchSize = NSSize(width: 124, height: 72)
        static let columns = 4
        static let contentWidth: CGFloat = 640
        static let nameHeight: CGFloat = 34
    }

    var pageTitle: String { L10n.string("Appearance") }

    private let mark = ThreadingMarkView()
    private let grid = NSGridView()
    private let gridScroll = ThemedScrollView()
    private var tiles: [(
        theme: AppTheme,
        item: NavigatorGridItemView,
        swatch: NSImageView,
        selectionMark: NSTextField
    )] = []
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
                "Threading dresses itself. Pick a look and everything follows it, including the rest of this setup. Change it anytime in Settings ▸ Themes."
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

        let document = SettingsFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(grid)

        gridScroll.hasVerticalScroller = true
        gridScroll.automaticallyAdjustsContentInsets = false
        gridScroll.documentView = document
        gridScroll.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [headingRow, caption, gridScroll])
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
            gridScroll.widthAnchor.constraint(equalToConstant: Layout.contentWidth),

            document.topAnchor.constraint(equalTo: gridScroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: gridScroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: gridScroll.contentView.trailingAnchor),
            grid.topAnchor.constraint(equalTo: document.topAnchor, constant: Design.Spacing.small),
            grid.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            grid.bottomAnchor.constraint(
                equalTo: document.bottomAnchor,
                constant: -Design.Spacing.small
            ),
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
            name.lineBreakMode = .byWordWrapping
            name.maximumNumberOfLines = 2
            name.alignment = .center
            name.setAccessibilityElement(false)
            name.widthAnchor.constraint(equalToConstant: Layout.swatchSize.width).isActive = true
            name.heightAnchor.constraint(equalToConstant: Layout.nameHeight).isActive = true

            // A decorative tile border can resemble selection in several authored themes.
            // Reserve a stable one-line mark so the current choice is stated, not inferred.
            let selectionMark = NSTextField(labelWithString: " ")
            selectionMark.applyFont(.caption)
            selectionMark.textColor = Design.Surface.accent
            selectionMark.alignment = .center
            selectionMark.setAccessibilityElement(false)

            let content = NSStackView(views: [swatch, name, selectionMark])
            content.orientation = .vertical
            content.alignment = .centerX
            content.spacing = Design.Spacing.small
            content.edgeInsets = NSEdgeInsets(
                top: Design.Spacing.small,
                left: Design.Spacing.small,
                bottom: Design.Spacing.small,
                right: Design.Spacing.small
            )
            let item = NavigatorGridItemView(content: content)
            item.setAccessibilityTitle(theme.name)
            item.onActivate = {
                AppThemeLibrary.apply(theme)
            }
            return (theme, item, swatch, selectionMark)
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
            let selected = tile.theme.id == current
            tile.item.isSelected = selected
            tile.selectionMark.stringValue = selected ? "✓" : " "
            let appearance = tile.theme.mode.appearance
                ?? view.effectiveAppearance
            tile.swatch.image = ThemeSwatchImage.appSwatch(
                for: tile.theme,
                size: Layout.swatchSize,
                appearance: appearance
            )
        }
        view.layoutSubtreeIfNeeded()
        if let selectedItem = tiles.first(where: { $0.theme.id == current })?.item {
            selectedItem.scrollToVisible(selectedItem.bounds)
        }
    }
}
