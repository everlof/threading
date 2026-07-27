import AppKit
import SkalmanExtensionKit
import ThinkingOrbs

/// A live catalogue of the application's design-system components.
///
/// Theme selection is intentionally app-wide, matching the real setting. Appearance is scoped
/// to this window, so a light theme under dark AppKit chrome (and the reverse) can be inspected
/// without disturbing the main window.
final class ComponentGalleryWindowController: ThemedWindowController {

    private enum Defaults {
        static let frameName = "SkalmanComponentGalleryWindowFrame"
        static let size = NSSize(width: 1_020, height: 780)
        static let minimumSize = NSSize(width: 780, height: 580)
    }

    convenience init() {
        let content = ComponentGalleryViewController()
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Defaults.size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Component Gallery"
        window.minSize = Defaults.minimumSize
        window.isReleasedWhenClosed = false
        window.contentViewController = content

        self.init(window: window)

        if !window.setFrameUsingName(Defaults.frameName) {
            // Installing a content controller replaces the content rect with its fitting size.
            // Restore the intended first-open size afterwards, as the main window does.
            window.setContentSize(Defaults.size)
            window.center()
        }
        window.setFrameAutosaveName(Defaults.frameName)
        window.delegate = self
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }
}

extension ComponentGalleryWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        (contentViewController as? ComponentGalleryViewController)?
            .stopExtensionProcess()
    }
}

// MARK: - Gallery

@MainActor
final class ComponentGalleryViewController: NSViewController {

    enum AppearanceMode: String, CaseIterable {
        case light = "Light"
        case dark = "Dark"

        var appearance: NSAppearance? {
            NSAppearance(named: self == .dark ? .darkAqua : .aqua)
        }
    }

    /// The concrete visual vocabulary represented by the gallery.
    ///
    /// Keeping this explicit makes additions reviewable and gives the tests one place to detect
    /// a story silently disappearing during a refactor.
    static let componentNames: Set<String> = [
        "BackdropOverlay",
        "BackdropThemedControl",
        "ChipView",
        "FileActivityMapView",
        "MorphingTitleLabel",
        "PaneFooterView",
        "PromptView",
        "SeparatorView",
        "ShortcutRecorderView",
        "SidebarBackdropView",
        "ThemeSwatchImage",
        "ThemeSwatchView",
        "ThemedButton",
        "ThemedClipView",
        "ThemedControl",
        "ThemedOutlineView",
        "ThemedPopUp",
        "ThemedProgressBar",
        "ThemedScrollView",
        "ThemedSpinner",
        "ThemedSplitView",
        "ThemedTableHeaderView",
        "ThemedTableView",
        "ThemedTabItemView",
        "ThemedTextField",
        "ThemedSearchField",
        "ThemedTextView",
        "ThemedToggle",
        "ThemedSurface",
        "ThemedSurfaceView",
        "ThemeRedraw",
        "ThemedIconButton",
        "ToolbarButtonGroupView",
        "WorkingOrbView",
        "WindowBackdrop"
    ]

    private let themePopUp = ThemedPopUp()
    private let appearanceToggle = ThemedToggle()
    private let receiptLabel = NSTextField(labelWithString: "Ready — interact with any story.")
    private let spinner = ThemedSpinner()
    private let workingOrbs = OrbState.allCases.map(WorkingOrbView.init(state:))
    private let morphingTitle = MorphingTitleLabel()
    private let activityMapView = FileActivityMapView()
    private var activityDemoFiles: [String] = []
    private var activityDemoCursor = 0
    private let progressBar = ThemedProgressBar()
    private let progressLabel = NSTextField(labelWithString: "42%")
    private let themeImageView = NSImageView()
    private let galleryScrollView = ThemedScrollView()
    private let tableModel = ComponentGalleryTableModel()
    private let extensionLoadButton = ThemedButton()
    private let extensionProcessStatus = NSTextField(
        wrappingLabelWithString: "Choose an extension directory to start its interactive process."
    )
    private let extensionProcessPreview = NSStackView()
    private var extensionProcessSession: ExtensionProcessSession?
    private var extensionLoadGeneration = 0

    private var progress = 0.42
    private var clickCount = 0
    private var morphDemoCursor = 0
    private var didSetInitialScrollPosition = false
    private(set) var appearanceMode: AppearanceMode

    init() {
        let currentAppearance = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        appearanceMode = currentAppearance == .darkAqua ? .dark : .light
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        extensionProcessSession?.terminate()
    }

    func stopExtensionProcess() {
        extensionLoadGeneration += 1
        extensionProcessSession?.terminate()
        extensionProcessSession = nil
        guard isViewLoaded else { return }
        extensionProcessStatus.textColor = Design.Text.secondary
        extensionProcessStatus.stringValue =
            "Choose an extension directory to start its interactive process."
        replaceExtensionProcessPreview(with: nil)
    }

    override func loadView() {
        let root = NSView()
        root.applySurface(fill: Design.Surface.ground, radius: .fixed(0))
        root.appearance = appearanceMode.appearance
        view = root

        let header = makeHeader()
        let separator = SeparatorView()
        let gallery = makeGallery()

        for child in [header, separator, gallery] {
            child.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child)
        }

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            separator.topAnchor.constraint(equalTo: header.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            gallery.topAnchor.constraint(equalTo: separator.bottomAnchor),
            gallery.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            gallery.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            gallery.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !didSetInitialScrollPosition else { return }
        didSetInitialScrollPosition = true
        galleryScrollView.contentView.scroll(to: .zero)
        galleryScrollView.reflectScrolledClipView(galleryScrollView.contentView)
    }

    // MARK: Header

    private func makeHeader() -> NSView {
        let title = NSTextField(labelWithString: "Component Gallery")
        title.applyFont(.heading)
        title.textColor = Design.Text.label

        let subtitle = NSTextField(labelWithString: "Theme is app-wide · Light/Dark is scoped to this window")
        subtitle.applyFont(.subheading)
        subtitle.textColor = Design.Text.secondary

        let heading = NSStackView(views: [title, subtitle])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = Design.Spacing.hairline

        configureThemePopUp()
        configureAppearanceToggle()

        let themeControl = labelledControl("Theme", control: themePopUp)

        let light = smallLabel("Light")
        let dark = smallLabel("Dark")
        let appearanceControls = NSStackView(views: [light, appearanceToggle, dark])
        appearanceControls.orientation = .horizontal
        appearanceControls.alignment = .centerY
        appearanceControls.spacing = Design.Spacing.small
        let appearanceControl = labelledControl("Appearance", control: appearanceControls)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [heading, spacer, themeControl, appearanceControl])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Design.Spacing.large
        row.edgeInsets = NSEdgeInsets(
            top: Design.Spacing.medium,
            left: Design.Spacing.pane,
            bottom: Design.Spacing.medium,
            right: Design.Spacing.pane
        )
        return row
    }

    private func configureThemePopUp() {
        for theme in AppThemeLibrary.stock {
            themePopUp.addItem(
                ThemedMenuItem(
                    title: theme.name,
                    image: ThemeSwatchImage.menuSwatch(for: theme.terminalPalette),
                    representedValue: theme.id.rawValue
                )
            )
        }
        let selected = AppThemeLibrary.stock.firstIndex { $0.id == AppThemePalette.current.id } ?? 0
        themePopUp.selectItem(at: selected)
        themePopUp.target = self
        themePopUp.action = #selector(themeChanged)
        themePopUp.setAccessibilityLabel("Gallery theme")
    }

    private func configureAppearanceToggle() {
        appearanceToggle.state = appearanceMode == .dark ? .on : .off
        appearanceToggle.target = self
        appearanceToggle.action = #selector(appearanceChanged)
        appearanceToggle.setAccessibilityLabel("Dark appearance")
    }

    // MARK: Stories

    private func makeGallery() -> NSView {
        let sections = NSStackView(views: [
            makeButtonsAndChoicesSection(),
            makeTextSection(),
            makeFeedbackSection(),
            makeContainersSection(),
            makeColourSection(),
            makeExtensionSection(),
            makeInfrastructureSection()
        ])
        sections.orientation = .vertical
        sections.alignment = .leading
        sections.spacing = Design.Spacing.large
        sections.translatesAutoresizingMaskIntoConstraints = false

        let document = ComponentGalleryFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(sections)

        let scroll = galleryScrollView
        scroll.setAccessibilityIdentifier("gallery.catalogue")
        scroll.hasVerticalScroller = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = document
        scroll.applySurface(fill: Design.Surface.ground, radius: .fixed(0))

        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),

            sections.topAnchor.constraint(equalTo: document.topAnchor, constant: Design.Spacing.large),
            sections.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: Design.Spacing.pane),
            sections.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -Design.Spacing.pane),
            sections.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -Design.Spacing.large)
        ])

        for section in sections.arrangedSubviews {
            section.widthAnchor.constraint(equalTo: sections.widthAnchor).isActive = true
        }
        return scroll
    }

    private func makeButtonsAndChoicesSection() -> NSView {
        let ordinary = button("Ordinary", action: #selector(buttonPressed))
        ordinary.setAccessibilityIdentifier("gallery.button.ordinary")

        let prominent = button("Prominent", action: #selector(buttonPressed))
        prominent.isProminent = true
        prominent.setAccessibilityIdentifier("gallery.button.prominent")

        let icon = ThemedButton(
            symbol: "sparkles",
            accessibility: "Icon button",
            target: self,
            action: #selector(buttonPressed)
        )
        icon.setAccessibilityIdentifier("gallery.button.icon")

        let disabled = button("Disabled", action: #selector(buttonPressed))
        disabled.isEnabled = false

        let buttonRow = row([ordinary, prominent, icon, disabled])

        let toggle = ThemedToggle()
        toggle.target = self
        toggle.action = #selector(sampleToggleChanged)
        toggle.setAccessibilityLabel("Interactive toggle")

        let onToggle = ThemedToggle()
        onToggle.state = .on
        onToggle.target = self
        onToggle.action = #selector(sampleToggleChanged)
        onToggle.setAccessibilityLabel("On toggle")

        let disabledToggle = ThemedToggle()
        disabledToggle.state = .on
        disabledToggle.isEnabled = false
        disabledToggle.setAccessibilityLabel("Disabled toggle")

        let toggleRow = row([
            labelledInline("Off", toggle),
            labelledInline("On", onToggle),
            labelledInline("Disabled", disabledToggle)
        ])

        let popUp = ThemedPopUp()
        ["First choice", "Second choice", "Third choice"].forEach(popUp.addItem)
        popUp.target = self
        popUp.action = #selector(samplePopUpChanged)

        let disabledPopUp = ThemedPopUp()
        disabledPopUp.addItem(withTitle: "Disabled")
        disabledPopUp.isEnabled = false

        let chip = ChipView()
        chip.configure(symbolName: "paintpalette", title: "Open chip menu")
        chip.setAccessibilityIdentifier("gallery.menu.chip")
        chip.itemsProvider = {
            [
                .item(ThemedMenuItem(
                    title: "Alpha",
                    subtitle: "Selected item with supporting text",
                    representedValue: "Alpha",
                    isSelected: chip.selectedItem?.title == "Alpha"
                )),
                .item(ThemedMenuItem(
                    title: "Beta",
                    representedValue: "Beta",
                    isSelected: chip.selectedItem?.title == "Beta"
                )),
                .separator,
                .item(ThemedMenuItem(
                    title: "Unavailable",
                    subtitle: "Disabled state",
                    isEnabled: false
                ))
            ]
        }
        chip.onSelect = { [weak self] item in
            chip.configure(symbolName: "paintpalette", title: item.title)
            self?.showReceipt("ChipView selected “\(item.title)”.")
        }

        let activeTab = ThemedTabItemView(
            title: "Terminal",
            symbolName: "terminal",
            placement: .horizontal,
            showsClose: true,
            inkSource: .chrome
        )
        activeTab.isSelected = true
        activeTab.onSelect = { [weak self] in self?.showReceipt("Selected the Terminal tab.") }
        activeTab.onClose = { [weak self] in self?.showReceipt("Closed the Terminal tab.") }

        let inactiveTab = ThemedTabItemView(
            title: "Browser",
            symbolName: "globe",
            placement: .horizontal,
            showsClose: true,
            inkSource: .chrome
        )
        inactiveTab.onSelect = { [weak self] in self?.showReceipt("Selected the Browser tab.") }

        let sidebarTab = ThemedTabItemView(
            title: "Themes",
            symbolName: "paintpalette",
            placement: .sidebar,
            inkSource: .chrome
        )
        sidebarTab.isSelected = true
        sidebarTab.widthAnchor.constraint(equalToConstant: 180).isActive = true

        let newSessionButton = ThemedIconButton(
            symbolName: "plus",
            accessibility: "New session"
        )
        newSessionButton.onPress = { [weak self] in
            self?.showReceipt("Opened the new-session page.")
        }

        let selectedToolbarButton = ThemedIconButton(
            symbolName: "sidebar.trailing",
            accessibility: "Selected toolbar action"
        )
        selectedToolbarButton.isSelected = true
        selectedToolbarButton.onPress = { [weak self] in
            self?.showReceipt("Pressed the selected toolbar action.")
        }

        // The toolbar's page tab: the *same* class as the two above it, differing only in the
        // ground it inks from. Shown beside them on purpose — this pair used to be two
        // implementations, and the gallery is where that would show.
        let activeSession = ThemedTabItemView(
            title: "Active session",
            symbolName: "chevron.left.forwardslash.chevron.right",
            placement: .horizontal,
            showsClose: true,
            inkSource: .backdrop
        )
        activeSession.isSelected = true
        activeSession.onSelect = { [weak self] in
            self?.showReceipt("Revealed the active page in the sidebar.")
        }
        activeSession.onClose = { [weak self] in
            self?.showReceipt("Closed the active page without stopping its session.")
        }
        activeSession.widthAnchor.constraint(equalToConstant: 190).isActive = true

        let groupedActions = ToolbarButtonGroupView(buttons: [
            galleryToolbarButton(symbol: "ellipsis", label: "Session options"),
            galleryToolbarButton(
                symbol: "rectangle.bottomthird.inset.filled",
                label: "Shell drawer"
            ),
            galleryToolbarButton(symbol: "sidebar.trailing", label: "Display panel")
        ])

        return section(
            "Buttons & choices",
            note: "Hover, press, disable, toggle, and open both menu-based controls.",
            rows: [
                story("ThemedButton", "Bordered, prominent, icon-only, and disabled.", buttonRow),
                story("ThemedToggle", "Off, on, disabled, target/action, and accessibility.", toggleRow),
                story(
                    "ThemedPopUp & ChipView",
                    "Fully app-owned dropdowns: selection, subtitle, separator, disabled state, and keyboard navigation.",
                    row([popUp, disabledPopUp, chip])
                ),
                story(
                    "ThemedTabItemView",
                    "The same selected destination language in horizontal strips and sidebars.",
                    row([activeTab, inactiveTab, sidebarTab])
                ),
                story(
                    "ThemedIconButton",
                    "Active page tab with its own close control, then New Session and selected pane actions.",
                    row([activeSession, newSessionButton, selectedToolbarButton])
                ),
                story(
                    "ToolbarButtonGroupView",
                    "Related toolbar actions spaced as a set, the way the window's own trailing controls are.",
                    groupedActions
                )
            ]
        )
    }

    /// A toolbar button whose only job is to report that it was pressed.
    private func galleryToolbarButton(symbol: String, label: String) -> ThemedIconButton {
        let button = ThemedIconButton(symbolName: symbol, accessibility: label)
        button.onPress = { [weak self] in self?.showReceipt("Pressed \(label).") }
        return button
    }

    private func makeTextSection() -> NSView {
        let field = ThemedTextField(string: "Editable text")
        field.placeholderString = "Type here"
        field.target = self
        field.action = #selector(textCommitted)

        let search = ThemedSearchField()
        search.placeholderString = "Filter components"
        search.target = self
        search.action = #selector(searchCommitted)

        let disabled = ThemedTextField(string: "Disabled")
        disabled.isEnabled = false

        for field in [field, search, disabled] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true
        }

        let scrollingText = ThemedTextView.scrolling()
        scrollingText.translatesAutoresizingMaskIntoConstraints = false
        scrollingText.heightAnchor.constraint(equalToConstant: 100).isActive = true
        scrollingText.applySurface(
            fill: Design.Surface.controlResting,
            radius: .control,
            border: Design.Surface.border
        )
        if let text = scrollingText.documentView as? ThemedTextView {
            text.string = """
                ThemedTextView preserves AppKit editing while the text, insertion point, and \
                scroll surface follow the selected theme.

                Try selecting, editing, and scrolling this text.
                """
            text.applyFont(.body)
            text.textContainerInset = NSSize(width: Design.Spacing.medium, height: Design.Spacing.medium)
        }

        let prompt = PromptView()
        prompt.placeholder = "Write a multi-line prompt; Return submits"
        prompt.minimumHeight = 72
        prompt.onChange = { [weak self] text in
            self?.showReceipt("PromptView contains \(text.count) character\(text.count == 1 ? "" : "s").")
        }
        prompt.onSubmit = { [weak self] text in
            self?.showReceipt("PromptView submitted “\(text.prefix(80))”.")
        }

        // Armed, it swallows key equivalents, so a chord that is already a menu shortcut can be
        // pressed here and captured rather than firing its command — which is the behaviour worth
        // being able to try by hand.
        let recorder = ShortcutRecorderView(
            shortcut: KeyboardShortcut(key: "r", modifiers: [.command, .shift])
        )
        recorder.onRecord = { [weak self] shortcut in
            self?.showReceipt(
                "ShortcutRecorderView captured \(shortcut?.displayString ?? "no shortcut")."
            )
        }

        let unboundRecorder = ShortcutRecorderView(shortcut: nil)
        let disabledRecorder = ShortcutRecorderView(
            shortcut: KeyboardShortcut(key: "q", modifiers: .command)
        )
        disabledRecorder.isEnabled = false

        return section(
            "Text input",
            note: "Focus rings, placeholders, selection, multiline growth, Return, and scrolling are live.",
            rows: [
                story(
                    "ThemedTextField & ThemedSearchField",
                    "Editable, search-shaped, and disabled states.",
                    row([field, search, disabled])
                ),
                story(
                    "ShortcutRecorderView",
                    "Click one and press a chord. Escape cancels, Delete clears; the third is fixed.",
                    row([recorder, unboundRecorder, disabledRecorder])
                ),
                story(
                    "ThemedTextView, ThemedScrollView & ThemedClipView",
                    "The scroll factory composes all three boundaries.",
                    scrollingText
                ),
                story(
                    "PromptView",
                    "Growing composer, submission, paste, and file-drop behavior.",
                    prompt
                )
            ]
        )
    }

    private func makeFeedbackSection() -> NSView {
        spinner.isAnimating = true
        spinner.setAccessibilityLabel("Working")

        let spinnerButton = button("Stop spinner", action: #selector(toggleSpinner))
        spinnerButton.setAccessibilityIdentifier("gallery.spinner.toggle")

        for orb in workingOrbs {
            orb.setAccessibilityLabel("\(orb.state.label) orb")
        }
        let orbButton = button("Hide orbs", action: #selector(toggleWorkingOrb))
        orbButton.setAccessibilityIdentifier("gallery.working-orb.toggle")
        let orbVariants = row(workingOrbs.map { orb in
            labelledControl(orb.state.rawValue, control: orb)
        })

        morphingTitle.applyFont(.emphasizedBody)
        morphingTitle.setStringValue("Rename this conversation", animated: false)
        morphingTitle.translatesAutoresizingMaskIntoConstraints = false
        morphingTitle.widthAnchor.constraint(equalToConstant: 260).isActive = true
        let morphButton = button("Preview rename", action: #selector(previewTitleMorph))

        progressBar.progress = progress
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true

        let less = button("−10%", action: #selector(decreaseProgress))
        let more = button("+10%", action: #selector(increaseProgress))

        configureActivityMap()
        let reads = button("Agent reads", action: #selector(demoAgentReads))
        reads.setAccessibilityIdentifier("gallery.activity-map.reads")
        let edits = button("Agent edits", action: #selector(demoAgentEdits))
        edits.setAccessibilityIdentifier("gallery.activity-map.edits")
        let activityButtons = NSStackView(views: [reads, edits])
        activityButtons.orientation = .vertical
        activityButtons.alignment = .leading
        activityButtons.spacing = Design.Spacing.small

        let horizontal = SeparatorView()
        horizontal.translatesAutoresizingMaskIntoConstraints = false
        horizontal.widthAnchor.constraint(equalToConstant: 180).isActive = true

        let vertical = SeparatorView(.vertical)
        vertical.translatesAutoresizingMaskIntoConstraints = false
        vertical.heightAnchor.constraint(equalToConstant: 34).isActive = true

        return section(
            "Feedback & separation",
            note: "Animation, determinate progress, and theme-weighted rules.",
            rows: [
                story(
                    "ThemedSpinner",
                    "Indeterminate activity with a real start/stop state.",
                    row([spinner, spinnerButton])
                ),
                story(
                    "WorkingOrbView",
                    "All six theme-accented variants. A conversation chooses one per turn; "
                        + "visibility starts and idles its animation.",
                    row([orbVariants, orbButton])
                ),
                story(
                    "MorphingTitleLabel",
                    "The selected chat-name effect with fixed, app-owned timing.",
                    row([morphingTitle, morphButton])
                ),
                story(
                    "ThemedProgressBar",
                    "Clamped determinate progress without a stock slider.",
                    row([less, progressBar, progressLabel, more])
                ),
                story(
                    "FileActivityMapView",
                    "Every tracked file as a mark: reads glow in the secondary tier, edits in "
                        + "the accent, both fading to a residual. Hover names the file.",
                    row([activityMapView, activityButtons])
                ),
                story(
                    "SeparatorView",
                    "Horizontal and vertical orientations use the theme’s divider and border weight.",
                    row([horizontal, vertical])
                )
            ]
        )
    }

    private func makeContainersSection() -> NSView {
        let table = ThemedTableView()
        table.addTableColumn(column("component", title: "Component", width: 180))
        table.addTableColumn(column("state", title: "State", width: 120))
        table.headerView = ThemedTableHeaderView()
        table.rowHeight = 26
        table.delegate = tableModel
        table.dataSource = tableModel

        let tableScroll = ThemedScrollView()
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.translatesAutoresizingMaskIntoConstraints = false
        tableScroll.heightAnchor.constraint(equalToConstant: 132).isActive = true
        tableScroll.applySurface(
            fill: Design.Surface.panel,
            radius: .control,
            border: Design.Surface.border
        )

        let outline = ThemedOutlineView()
        let outlineColumn = column("outline", title: "Hierarchy", width: 300)
        outline.addTableColumn(outlineColumn)
        outline.outlineTableColumn = outlineColumn
        outline.headerView = nil
        outline.rowHeight = 25
        outline.delegate = tableModel
        outline.dataSource = tableModel

        let outlineScroll = ThemedScrollView()
        outlineScroll.documentView = outline
        outlineScroll.hasVerticalScroller = true
        outlineScroll.translatesAutoresizingMaskIntoConstraints = false
        outlineScroll.heightAnchor.constraint(equalToConstant: 132).isActive = true
        outlineScroll.applySurface(
            fill: Design.Surface.panel,
            radius: .control,
            border: Design.Surface.border
        )

        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)

        return section(
            "Data containers",
            note: "The table, outline, header, scroll, and clip boundaries are real AppKit views.",
            rows: [
                story(
                    "ThemedTableView & ThemedTableHeaderView",
                    "Select rows and resize the themed header columns.",
                    tableScroll
                ),
                story(
                    "ThemedOutlineView",
                    "Expand, collapse, select, and scroll a hierarchy.",
                    outlineScroll
                ),
                story(
                    "ThemedSplitView",
                    "Drag the divider: the seam is inked against the window's backdrop, not the chrome's ground.",
                    makeSplitViewSample()
                ),
                story(
                    "ThemedSurfaceView",
                    "A pane's ground. Switch the gallery between Light and Dark: this keeps its "
                        + "role, where a plain view would keep the colour it was first handed.",
                    makeSurfaceViewSample()
                ),
                story(
                    "SidebarBackdropView",
                    "The sidebar's ground: the platform's material under System, the theme's "
                        + "own opaque surface under a style. Switch the theme above to watch it "
                        + "trade one for the other.",
                    makeSidebarBackdropSample()
                ),
                story(
                    "PaneFooterView",
                    "The bottom band of a pane: hairline, band height, and controls whose ink "
                        + "sits on the stated margin — corner-adapted when the band meets a "
                        + "rounded window corner.",
                    makePaneFooterSample()
                )
            ]
        )
    }

    /// The sidebar's own ground, at gallery scale — and beside it the plain view it replaced, so
    /// the appearance toggle above shows the difference rather than describing it.
    /// The sidebar footer's shape at the sidebar's width: a titled plain button at the leading
    /// margin, an icon-only twin at the trailing one, both landing their ink on the same inset.
    private func makePaneFooterSample() -> NSView {
        let add = ThemedButton()
        add.title = "Add Project"
        add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Project")?
            .withSymbolConfiguration(Design.Symbol.configuration(Design.Symbol.control))
        add.isBordered = false
        add.applyFont(.controlRegular)
        add.target = self
        add.action = #selector(buttonPressed(_:))

        let gear = ThemedButton()
        gear.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")?
            .withSymbolConfiguration(Design.Symbol.configuration(Design.Symbol.control))
        gear.isBordered = false
        gear.toolTip = "Settings"
        gear.target = self
        gear.action = #selector(buttonPressed(_:))

        let footer = PaneFooterView(leading: [add], trailing: [gear])

        let pane = ThemedSurfaceView()
        pane.applySurface(fill: Design.Surface.background, radius: .control)
        pane.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(footer)

        NSLayoutConstraint.activate([
            pane.widthAnchor.constraint(equalToConstant: SidebarDefaults.defaultWidth),
            pane.heightAnchor.constraint(equalToConstant: Design.Size.footerHeight * 2),
            footer.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: pane.bottomAnchor)
        ])

        return pane
    }

    private func makeSidebarBackdropSample() -> NSView {
        let backdrop = SidebarBackdropView()

        NSLayoutConstraint.activate([
            backdrop.widthAnchor.constraint(equalToConstant: 120),
            backdrop.heightAnchor.constraint(equalToConstant: 72)
        ])

        return backdrop
    }

    private func makeSurfaceViewSample() -> NSView {
        let themed = ThemedSurfaceView()
        themed.applySurface(fill: Design.Surface.background, radius: .panel)

        let row = NSStackView(views: [themed, makeSurfaceLabel()])
        row.orientation = .horizontal
        row.spacing = Design.Spacing.medium

        NSLayoutConstraint.activate([
            themed.widthAnchor.constraint(equalToConstant: 120),
            themed.heightAnchor.constraint(equalToConstant: 72)
        ])

        return row
    }

    private func makeSurfaceLabel() -> NSView {
        let label = NSTextField(labelWithString: "Surface.background")
        label.applyFont(.code())
        label.textColor = Design.Text.secondary
        return label
    }

    /// Two panes and the seam between them, which is the whole of what this component draws.
    private func makeSplitViewSample() -> NSView {
        let split = ThemedSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false

        for fill in [Design.Surface.panel, Design.Surface.elevated] {
            let pane = NSView()
            pane.applySurface(fill: fill, radius: .fixed(0))
            split.addArrangedSubview(pane)
        }

        NSLayoutConstraint.activate([
            split.widthAnchor.constraint(equalToConstant: 260),
            split.heightAnchor.constraint(equalToConstant: 72)
        ])

        return split
    }

    private func makeColourSection() -> NSView {
        let editable = ThemeSwatchView(size: 34)
        editable.isEditable = true
        editable.setColor(Design.Surface.accent, name: "Accent")
        editable.onChange = { [weak self] colour in
            self?.showReceipt("ThemeSwatchView chose \(colour.hexString).")
        }

        let fixed = ThemeSwatchView(size: 34)
        fixed.setColor(Design.Status.positive, name: "Positive")

        themeImageView.imageScaling = .scaleProportionallyUpOrDown
        themeImageView.translatesAutoresizingMaskIntoConstraints = false
        themeImageView.widthAnchor.constraint(equalToConstant: 88).isActive = true
        themeImageView.heightAnchor.constraint(equalToConstant: 56).isActive = true
        updateThemeImage()

        let tokenSwatches = [
            ("Ground", Design.Surface.ground),
            ("Panel", Design.Surface.panel),
            ("Accent", Design.Surface.accent),
            ("Positive", Design.Status.positive),
            ("Warning", Design.Status.warning),
            ("Negative", Design.Status.negative)
        ].map { name, colour -> NSView in
            let swatch = ThemeSwatchView(size: 28)
            swatch.setColor(colour, name: name)
            return labelledInline(name, swatch)
        }

        return section(
            "Colour & theme",
            note: "The first swatch opens the system colour panel; the rest are read-only truth samples.",
            rows: [
                story(
                    "ThemeSwatchView",
                    "Editable and read-only containment of the system colour picker.",
                    row([labelledInline("Editable", editable), labelledInline("Read-only", fixed)])
                ),
                story(
                    "ThemeSwatchImage",
                    "The compact terminal-palette preview used in menus and theme lists.",
                    themeImageView
                ),
                story(
                    "Semantic roles",
                    "A quick visual checksum of the active palette.",
                    row(tokenSwatches)
                )
            ]
        )
    }

    private func makeInfrastructureSection() -> NSView {
        let backdrop = ComponentGalleryBackdropSample()
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.widthAnchor.constraint(equalToConstant: 260).isActive = true
        backdrop.heightAnchor.constraint(equalToConstant: 42).isActive = true

        let surface = NSView()
        surface.translatesAutoresizingMaskIntoConstraints = false
        surface.widthAnchor.constraint(equalToConstant: 260).isActive = true
        surface.heightAnchor.constraint(equalToConstant: 42).isActive = true
        surface.applySurface(
            fill: Design.Surface.elevated,
            radius: .panel,
            border: Design.Surface.border,
            glow: true
        )

        let surfaceLabel = NSTextField(labelWithString: "ThemedSurface / applySurface")
        surfaceLabel.applyFont(.control)
        surfaceLabel.textColor = Design.Text.label
        surfaceLabel.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(surfaceLabel)
        NSLayoutConstraint.activate([
            surfaceLabel.centerXAnchor.constraint(equalTo: surface.centerXAnchor),
            surfaceLabel.centerYAnchor.constraint(equalTo: surface.centerYAnchor)
        ])

        return section(
            "Infrastructure",
            note: "Abstract contracts are represented by a concrete live example rather than fake controls.",
            rows: [
                story(
                    "BackdropOverlay & WindowBackdrop",
                    "Ink is measured against the window backdrop, including appearance changes.",
                    backdrop
                ),
                story(
                    "ThemedSurface, ThemeRedraw & recorded layers",
                    "Surface geometry and live colour refresh shared by the components above.",
                    surface
                ),
                story(
                    "Interaction receipt",
                    "The last action taken anywhere in the gallery.",
                    receiptLabel
                )
            ]
        )
    }

    private func makeExtensionSection() -> NSView {
        let panel = ExtensionExperimentFixture.registration.panels[0]
        let rendered: NSView

        do {
            rendered = try ExtensionNodeRenderer.render(panel.root) { [weak self] action in
                self?.showReceipt("Extension action “\(action)” was invoked.")
            }
            rendered.setAccessibilityIdentifier("gallery.extension.panel")
        } catch {
            let failure = NSTextField(wrappingLabelWithString: error.localizedDescription)
            failure.applyFont(.body)
            failure.textColor = Design.Status.negative
            rendered = failure
        }

        extensionLoadButton.title = "Load Extension Directory…"
        extensionLoadButton.target = self
        extensionLoadButton.action = #selector(chooseExtensionDirectory)
        extensionLoadButton.setAccessibilityIdentifier("gallery.extension.load")

        extensionProcessStatus.applyFont(.detail())
        extensionProcessStatus.textColor = Design.Text.secondary
        extensionProcessStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        extensionProcessPreview.orientation = .vertical
        extensionProcessPreview.alignment = .leading
        extensionProcessPreview.spacing = Design.Spacing.small
        extensionProcessPreview.setAccessibilityIdentifier("gallery.extension.process-preview")

        let processExperiment = NSStackView(
            views: [extensionLoadButton, extensionProcessStatus, extensionProcessPreview]
        )
        processExperiment.orientation = .vertical
        processExperiment.alignment = .leading
        processExperiment.spacing = Design.Spacing.small
        extensionProcessStatus.widthAnchor.constraint(
            lessThanOrEqualTo: processExperiment.widthAnchor
        ).isActive = true
        extensionProcessPreview.widthAnchor.constraint(
            lessThanOrEqualTo: processExperiment.widthAnchor
        ).isActive = true

        var rows = [
            story(
                "ExtensionNode renderer",
                "Text, status, separation, layout, actions, disabled state, and semantic roles.",
                rendered
            ),
            story(
                "Live out-of-process extension",
                "Inspect a manifest, supervise its process, validate every JSONL value, route actions, and render returned panel state.",
                processExperiment
            )
        ]
        rows.append(contentsOf: ComponentCustomizationGalleryFixture.stories().map {
            story($0.title, $0.detail, $0.view)
        })

        return section(
            "Extension rendering",
            note: "Semantic values cross the extension boundary; the same themed controls render them.",
            rows: rows
        )
    }

    // MARK: Actions

    @objc private func themeChanged() {
        let index = themePopUp.indexOfSelectedItem
        guard let theme = AppThemeLibrary.stock[safe: index] else { return }
        setTheme(theme)
        showReceipt("Applied the \(theme.name) theme app-wide.")
    }

    /// Applies a gallery theme and keeps the selector honest.
    ///
    /// The public interaction reaches this through `themeChanged`; the render harness uses the
    /// same path so every captured fixture names and displays the theme it actually renders.
    func setTheme(_ theme: AppTheme) {
        if let index = AppThemeLibrary.stock.firstIndex(where: { $0.id == theme.id }) {
            themePopUp.selectItem(at: index)
        }
        AppThemeLibrary.apply(theme)
        updateThemeImage()
    }

    @objc private func appearanceChanged() {
        setAppearance(appearanceToggle.state == .on ? .dark : .light)
        showReceipt("Gallery appearance is \(appearanceMode.rawValue).")
    }

    func setAppearance(_ mode: AppearanceMode) {
        appearanceMode = mode
        appearanceToggle.state = mode == .dark ? .on : .off
        view.appearance = mode.appearance
        AppThemeRefresh.repaint(view)
    }

    @objc private func buttonPressed(_ sender: Any?) {
        clickCount += 1
        let button = sender as? ThemedButton
        let name = button?.accessibilityTitle() ?? "Button"
        showReceipt("\(name) pressed · \(clickCount) total.")
    }

    @objc private func chooseExtensionDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Load Skalman Extension"
        panel.message = "Choose a directory containing skalman-extension.json."
        panel.prompt = "Load Extension"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let directory = panel.url else { return }

        extensionLoadGeneration += 1
        let loadGeneration = extensionLoadGeneration
        extensionProcessSession?.terminate()
        extensionProcessSession = nil
        extensionLoadButton.isEnabled = false
        extensionProcessStatus.textColor = Design.Text.secondary
        extensionProcessStatus.stringValue = "Inspecting and starting \(directory.lastPathComponent)…"
        replaceExtensionProcessPreview(with: nil)

        DispatchQueue.global(qos: .userInitiated).async { [directory] in
            let result: Result<
                (ExtensionManifest, ExtensionProcessSession.Started),
                Error
            >
            do {
                let bundle = try ExtensionBundleInspector.inspect(at: directory)
                let started = try ExtensionProcessSession.start(bundle: bundle)
                result = .success((bundle.manifest, started))
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async { [weak self] in
                self?.presentStartedExtension(result, generation: loadGeneration)
            }
        }
    }

    private func presentStartedExtension(
        _ result: Result<
            (ExtensionManifest, ExtensionProcessSession.Started),
            Error
        >,
        generation: Int
    ) {
        guard generation == extensionLoadGeneration else {
            if case .success((_, let started)) = result {
                started.session.terminate()
            }
            return
        }

        extensionLoadButton.isEnabled = true

        switch result {
        case .failure(let error):
            extensionProcessStatus.stringValue = error.localizedDescription
            extensionProcessStatus.textColor = Design.Status.negative
            showReceipt("Extension failed to start.")

        case .success(let (manifest, started)):
            extensionProcessSession = started.session
            extensionProcessStatus.textColor = Design.Status.positive
            extensionProcessStatus.stringValue =
                "\(manifest.name) is running · \(started.registration.commands.count) command(s), \(started.registration.panels.count) panel(s)."

            guard let panel = started.registration.panels.first else {
                let empty = NSTextField(labelWithString: "The extension registered no panels.")
                empty.applyFont(.detail())
                empty.textColor = Design.Text.tertiary
                replaceExtensionProcessPreview(with: empty)
                showReceipt("Loaded extension “\(manifest.name)”.")
                return
            }

            if renderExtensionPanel(
                panel,
                manifest: manifest,
                session: started.session
            ) {
                showReceipt("Loaded extension “\(manifest.name)” and rendered “\(panel.title)”.")
            }
        }
    }

    @discardableResult
    private func renderExtensionPanel(
        _ panel: ExtensionPanel,
        manifest: ExtensionManifest,
        session: ExtensionProcessSession
    ) -> Bool {
        do {
            let rendered = try ExtensionNodeRenderer.render(panel.root) { [weak self, weak session] action in
                guard let self, let session,
                      self.extensionProcessSession === session else { return }
                self.extensionProcessStatus.textColor = Design.Text.secondary
                self.extensionProcessStatus.stringValue = "Running “\(action)”…"
                session.invoke(panelID: panel.id, actionID: action) { [weak self, weak session] result in
                    guard let self, let session,
                          self.extensionProcessSession === session else { return }
                    self.presentExtensionAction(
                        result,
                        manifest: manifest,
                        session: session
                    )
                }
            }
            rendered.setAccessibilityIdentifier("gallery.extension.live-panel")
            replaceExtensionProcessPreview(with: rendered)
            return true
        } catch {
            extensionProcessStatus.textColor = Design.Status.negative
            extensionProcessStatus.stringValue = error.localizedDescription
            replaceExtensionProcessPreview(with: nil)
            showReceipt("Extension panel rendering failed.")
            return false
        }
    }

    private func presentExtensionAction(
        _ result: Result<ExtensionActionResponse, Error>,
        manifest: ExtensionManifest,
        session: ExtensionProcessSession
    ) {
        switch result {
        case .failure(let error):
            extensionProcessStatus.textColor = Design.Status.negative
            extensionProcessStatus.stringValue = error.localizedDescription
            showReceipt("Extension action failed.")

        case .success(let response):
            if let error = response.error {
                extensionProcessStatus.textColor = Design.Status.negative
                extensionProcessStatus.stringValue = error
                showReceipt("Extension declined the action.")
                return
            }

            if let panel = response.panel {
                guard renderExtensionPanel(panel, manifest: manifest, session: session) else {
                    return
                }
            }

            let message = response.message ?? "Extension action completed."
            extensionProcessStatus.textColor = Design.Status.positive
            extensionProcessStatus.stringValue = message
            showReceipt(message)
        }
    }

    private func replaceExtensionProcessPreview(with view: NSView?) {
        for arranged in extensionProcessPreview.arrangedSubviews {
            extensionProcessPreview.removeArrangedSubview(arranged)
            arranged.removeFromSuperview()
        }
        if let view {
            extensionProcessPreview.addArrangedSubview(view)
        }
    }

    @objc private func sampleToggleChanged(_ sender: ThemedToggle) {
        showReceipt("ThemedToggle is \(sender.state == .on ? "on" : "off").")
    }

    @objc private func samplePopUpChanged(_ sender: ThemedPopUp) {
        showReceipt("ThemedPopUp selected “\(sender.selectedItem?.title ?? "Nothing")”.")
    }

    @objc private func textCommitted(_ sender: ThemedTextField) {
        showReceipt("ThemedTextField committed “\(sender.stringValue)”.")
    }

    @objc private func searchCommitted(_ sender: ThemedSearchField) {
        showReceipt("ThemedSearchField searched for “\(sender.stringValue)”.")
    }

    private func configureActivityMap() {
        activityMapView.setFiles(Self.activityDemoUniverse())
        // The map sorts its universe; cycling in *its* order keeps each press touching a
        // contiguous directory run, which is the pattern the strip exists to show.
        activityDemoFiles = activityMapView.map.entries.map(\.path)
        activityMapView.setAccessibilityLabel("File activity map sample")
        activityMapView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            activityMapView.widthAnchor.constraint(equalToConstant: 300),
            activityMapView.heightAnchor.constraint(equalToConstant: 160)
        ])
    }

    /// A compact repo-shaped universe, so the story shows directory runs without reading
    /// anything off disk.
    private static func activityDemoUniverse() -> [String] {
        var files = ["CLAUDE.md", "README.md", "USER_GUIDE.md"]
        let directories = [
            ("App", 4), ("Core/Agent", 24), ("Core/Session", 16), ("Core/MCP", 12),
            ("Models", 10), ("UI/Design", 28), ("UI/Views", 22), ("UI/Windows", 8),
            ("Tests", 30)
        ]
        for (directory, count) in directories {
            for index in 1...count {
                files.append("\(directory)/File\(String(format: "%02d", index)).swift")
            }
        }
        return files
    }

    @objc private func demoAgentReads() {
        showReceipt("FileActivityMapView read \(touchDemoFiles(count: 12, tool: .read)).")
    }

    @objc private func demoAgentEdits() {
        showReceipt("FileActivityMapView edited \(touchDemoFiles(count: 5, tool: .edit)).")
    }

    /// Touches a contiguous run from the demo cursor through the real classifier, and
    /// answers with the neighbourhood it landed in for the receipt.
    private func touchDemoFiles(count: Int, tool: ToolIdentity) -> String {
        guard !activityDemoFiles.isEmpty else { return "nothing" }

        var lastPath = ""
        for _ in 0..<count {
            lastPath = activityDemoFiles[activityDemoCursor % activityDemoFiles.count]
            activityDemoCursor += 1
            activityMapView.recordTouches(tool: tool, input: ["file_path": lastPath])
        }
        let directory = lastPath.split(separator: "/").dropLast().joined(separator: "/")
        return "\(count) files around \(directory.isEmpty ? "the repo root" : directory)"
    }

    @objc private func toggleSpinner(_ sender: ThemedButton) {
        spinner.isAnimating.toggle()
        sender.title = spinner.isAnimating ? "Stop spinner" : "Start spinner"
        showReceipt("ThemedSpinner \(spinner.isAnimating ? "started" : "stopped").")
    }

    @objc private func toggleWorkingOrb(_ sender: ThemedButton) {
        let shouldHide = !(workingOrbs.first?.isHidden ?? false)
        workingOrbs.forEach { $0.isHidden = shouldHide }
        sender.title = shouldHide ? "Show orbs" : "Hide orbs"
        showReceipt("WorkingOrbView variants \(shouldHide ? "hidden and idling" : "visible and animating").")
    }

    @objc private func previewTitleMorph() {
        let samples = [
            "Rename this conversation",
            "Polish the release notes",
            "Trace the session lifecycle"
        ]
        morphDemoCursor = (morphDemoCursor + 1) % samples.count
        morphingTitle.setStringValue(samples[morphDemoCursor], animated: true)
        showReceipt("MorphingTitleLabel previewed \(AppSettings.shared.chatNameMorphStyle.displayName).")
    }

    @objc private func decreaseProgress() {
        setProgress(progress - 0.1)
    }

    @objc private func increaseProgress() {
        setProgress(progress + 0.1)
    }

    private func setProgress(_ value: Double) {
        progress = min(max(value, 0), 1)
        progressBar.progress = progress
        progressLabel.stringValue = "\(Int((progress * 100).rounded()))%"
        showReceipt("ThemedProgressBar is \(progressLabel.stringValue).")
    }

    private func showReceipt(_ text: String) {
        receiptLabel.stringValue = text
        receiptLabel.toolTip = text
    }

    private func updateThemeImage() {
        themeImageView.image = ThemeSwatchImage.listSwatch(
            for: AppThemePalette.current.terminalPalette
        )
    }

    // MARK: Building blocks

    private func section(_ title: String, note: String, rows: [NSView]) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.applyFont(.heading)
        heading.textColor = Design.Text.label

        let explanation = NSTextField(wrappingLabelWithString: note)
        explanation.applyFont(.subheading)
        explanation.textColor = Design.Text.secondary

        let cards = NSStackView(views: rows)
        cards.orientation = .vertical
        cards.alignment = .leading
        cards.spacing = Design.Spacing.medium

        let result = NSStackView(views: [heading, explanation, cards])
        result.orientation = .vertical
        result.alignment = .leading
        result.spacing = Design.Spacing.small
        cards.widthAnchor.constraint(equalTo: result.widthAnchor).isActive = true
        for row in rows {
            row.widthAnchor.constraint(equalTo: cards.widthAnchor).isActive = true
        }
        return result
    }

    private func story(_ name: String, _ summary: String, _ sample: NSView) -> NSView {
        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.applyFont(.control)
        nameLabel.textColor = Design.Text.label

        let summaryLabel = NSTextField(wrappingLabelWithString: summary)
        summaryLabel.applyFont(.subheading)
        summaryLabel.textColor = Design.Text.secondary

        let heading = NSStackView(views: [nameLabel, summaryLabel])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = Design.Spacing.hairline

        sample.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [heading, sample])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.small
        stack.translatesAutoresizingMaskIntoConstraints = false

        let card = NSView()
        card.setAccessibilityIdentifier("gallery.story.\(name)")
        card.applySurface(
            fill: Design.Surface.panel,
            radius: .panel,
            border: Design.Surface.border,
            glow: true
        )
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: Design.Spacing.inset),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Design.Spacing.inset),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Design.Spacing.inset),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Design.Spacing.inset),
            sample.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor)
        ])
        return card
    }

    private func row(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Design.Spacing.medium
        return stack
    }

    private func labelledControl(_ title: String, control: NSView) -> NSView {
        let label = smallLabel(title.uppercased())
        let stack = NSStackView(views: [label, control])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.hairline
        return stack
    }

    private func labelledInline(_ title: String, _ control: NSView) -> NSView {
        let label = smallLabel(title)
        let stack = NSStackView(views: [label, control])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Design.Spacing.small
        return stack
    }

    private func smallLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.applyFont(.caption)
        label.textColor = Design.Text.tertiary
        return label
    }

    private func button(_ title: String, action: Selector) -> ThemedButton {
        ThemedButton(title: title, target: self, action: action)
    }

    private func column(_ identifier: String, title: String, width: CGFloat) -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.title = title
        column.width = width
        column.minWidth = 80
        return column
    }
}

// MARK: - Table and outline fixtures

@MainActor
private final class ComponentGalleryTableModel: NSObject,
    NSTableViewDataSource,
    NSTableViewDelegate,
    NSOutlineViewDataSource,
    NSOutlineViewDelegate {

    private struct TableRow {
        let component: String
        let state: String
    }

    private final class Node {
        let title: String
        let children: [Node]

        init(_ title: String, children: [Node] = []) {
            self.title = title
            self.children = children
        }
    }

    private let rows = [
        TableRow(component: "ThemedButton", state: "Ready"),
        TableRow(component: "ThemedTextField", state: "Focused"),
        TableRow(component: "ThemedSpinner", state: "Working"),
        TableRow(component: "ThemedProgressBar", state: "42%")
    ]

    private let roots = [
        Node("Controls", children: [
            Node("Buttons"),
            Node("Choices"),
            Node("Text input")
        ]),
        Node("Containers", children: [
            Node("Scroll views"),
            Node("Tables")
        ])
    ]

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard let tableColumn, rows.indices.contains(row) else { return nil }
        let value = tableColumn.identifier.rawValue == "component"
            ? rows[row].component
            : rows[row].state
        return cell(value)
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Node)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Node)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? Node else { return false }
        return !node.children.isEmpty
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let node = item as? Node else { return nil }
        return cell(node.title)
    }

    private func cell(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.applyFont(.body)
        label.textColor = Design.Text.label
        label.translatesAutoresizingMaskIntoConstraints = false

        let cell = NSTableCellView()
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: Design.Spacing.small),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
}

// MARK: - Infrastructure fixtures

private final class ComponentGalleryFlippedView: NSView {
    override var isFlipped: Bool { true }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
