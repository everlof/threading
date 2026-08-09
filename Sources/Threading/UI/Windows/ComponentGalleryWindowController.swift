import AppKit
import ThreadingExtensionKit
import ThinkingOrbs

/// A live catalogue of the application's design-system components.
///
/// Theme selection is intentionally app-wide, matching the real setting. Appearance is scoped
/// to this window, so a light theme under dark AppKit chrome (and the reverse) can be inspected
/// without disturbing the main window.
final class ComponentGalleryWindowController: ThemedWindowController {

    private enum Defaults {
        static let frameName = "ThreadingComponentGalleryWindowFrame"
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
        window.title = L10n.string("Component Gallery")
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

        var localizedName: String {
            switch self {
            case .light: L10n.string("Light")
            case .dark: L10n.string("Dark")
            }
        }
    }

    /// The concrete visual vocabulary represented by the gallery.
    ///
    /// Keeping this explicit makes additions reviewable and gives the tests one place to detect
    /// a story silently disappearing during a refactor.
    static let componentNames: Set<String> = [
        "AgentActivityBeamView",
        "AgentWorkSummaryView",
        "BackdropOverlay",
        "BackdropThemedControl",
        "BrowserAnnotationOverlay",
        "BrowserBaselineOverlay",
        "BrowserBaselineOverlayHandle",
        "BrowserDeviceToolbar",
        "BrowserFindBar",
        "ChipView",
        "ConversationContextRailView",
        "ConversationHandoffView",
        "ConversationOutboxRailView",
        "ConversationOutboxRowView",
        "ScheduledMessageStripView",
        "ScheduledMessageRowView",
        "CompareInspectorView",
        "CodeContextPreviewView",
        "ControlRowView",
        "ExecutionAuditEventView",
        "FileActivityMapView",
        "GlyphView",
        "HoverPopoverScheduler",
        "ImageCompareCanvas",
        "ImageCompareView",
        "MediaInspectorCanvas",
        "MediaInspectorDocumentView",
        "MediaInspectorView",
        "MorphingTitleLabel",
        "NavigatorGridItemView",
        "PaneFooterView",
        "PaneHeaderView",
        "PaneNoticeView",
        "PromptCompletionPresenter",
        "PromptView",
        "SearchMatchLabel",
        "SemanticSceneView",
        "SeparatorView",
        "ShortcutRecorderView",
        "SidebarBackdropView",
        "SidebarBrandView",
        "SplitIconButtonView",
        "SubagentSummaryView",
        "SubmissionStatusView",
        "ThreadingMarkView",
        "ThemeSwatchImage",
        "ThemeSwatchView",
        "ThemedButton",
        "ThemedAlert",
        "ThemedCheckbox",
        "ThemedRadioButton",
        "ThemedClipView",
        "ThemedControl",
        "ThemedDisclosureRow",
        "ThemedFileIconView",
        "ThemedFloatingGlyphView",
        "ThemedGroupedTableView",
        "ThemedOutlineView",
        "ThemedPopUp",
        "ThemedPopover",
        "ThemedPopoverChromeView",
        "ThemedProgressBar",
        "ThemedScroller",
        "ThemedScrollView",
        "ThemedSegmentedControl",
        "ThemedSpinner",
        "ThemedSplitView",
        "ThemedStackedBandChartView",
        "ThemedTimeSeriesChartView",
        "ListSelectionStrength",
        "ThemedTableHeaderView",
        "ThemedTableRowView",
        "ThemedTableView",
        "ThemedTabItemView",
        "ThemedTabStripView",
        "ThemedTextField",
        "ThemedSearchField",
        "ThemedSecureField",
        "ThemedTextView",
        "ThemedToggle",
        "ThemedVirtualTableCell",
        "ThemedWarningMark",
        "ThemedSurface",
        "ThemedSurfaceView",
        "ThemeRedraw",
        "ThemedIconButton",
        "ThemedImagePreview",
        "ToastPresenter",
        "ToastView",
        "ToolbarButtonGroupView",
        "UsageDashboardView",
        "WorkingOrbView",
        "WindowBackdrop",
        "WindowChromeButton",
        "WindowCommandBandView",
        "WindowChromeFrameView",
        "WindowTitleBandView"
    ]

    /// The toast story's presenter, retained so the button beside the pane can send a band into
    /// it more than once.
    private var toastPresenter: ToastPresenter?

    /// The notice story's pane, kept so the band can be put up and taken down after the pass
    /// that built it — the push it performs is the component, and a still one shows none of it.
    private var paneNoticeHost: NSView?
    private var paneNoticeHeaderBottom: NSLayoutYAxisAnchor?
    private var paneNoticeContent: NSView?
    private var paneNoticeContentTop: NSLayoutConstraint?
    private weak var galleryNotice: PaneNoticeView?

    private var galleryPopover: ThemedPopover?
    private let galleryCompletionPresenter = PromptCompletionPresenter()

    /// The hover-policy story's demos, retained so their schedulers and popovers outlive the
    /// pass that built the section.
    private var hoverPolicyDemos: [GalleryHoverPolicyDemo] = []

    private let themePopUp = ThemedPopUp()
    /// The mark stories' views, retained so the replay control can reach them.
    private var markSamples: [ThreadingMarkView] = []
    private var particleMarkSamples: [ThreadingMarkView] = []
    private let appearanceToggle = ThemedToggle()
    private let receiptLabel = NSTextField(
        labelWithString: L10n.string("Ready — interact with any story.")
    )
    private let spinner = ThemedSpinner()
    /// The submission story's line, retained so the three buttons beside it can re-state it.
    private let submissionStatus = SubmissionStatusView()
    private let workingOrbs = OrbState.allCases.map { WorkingOrbView(state: $0) }
    private let morphingTitle = MorphingTitleLabel()

    /// The highlight story's field and the lines it marks, retained so typing re-marks them.
    /// A search's answer is the one thing here that cannot be shown at rest: the component's
    /// whole job is what a *query* does to a line, so the story hands the reader the query.
    private let matchQueryField = ThemedSearchField()
    private let matchSamples: [SearchMatchLabel] = [
        SearchMatchLabel(role: .body),
        SearchMatchLabel(role: .subheading, ink: { Design.Text.secondary }),
        SearchMatchLabel(role: .code(), ink: { Design.Text.quaternary })
    ]

    /// The tab strip's live model, so its story can be driven rather than looked at: closing
    /// and dragging mutate this and the strip re-renders from it, exactly as a host would.
    private let tabStrip = ThemedTabStripView(inkSource: .chrome)
    private var stripTabs: [(id: UUID, title: String, symbolName: String)] = [
        (UUID(), L10n.string("Terminal"), "terminal"),
        (UUID(), L10n.string("Browser"), "globe"),
        (UUID(), L10n.string("Review"), "plus.forwardslash.minus"),
        (UUID(), L10n.string("Activity"), "folder")
    ]
    private var stripActiveTabID: UUID?
    private let activityMapView = FileActivityMapView()
    private let galleryActivityBeam = AgentActivityBeamView()
    private let galleryUsageChart = ThemedTimeSeriesChartView()
    private let galleryStackedUsageChart = ThemedStackedBandChartView(frame: .zero)
    private var galleryUsageChartShowsAlternateData = false
    private var activityDemoFiles: [String] = []
    private var activityDemoCursor = 0
    private var activityBeamDemoCursor = 2
    private let progressBar = ThemedProgressBar()
    private let progressLabel = NSTextField(labelWithString: "42%")
    private let themeImageView = NSImageView()
    private let galleryScrollView = ThemedScrollView()
    private let tableModel = ComponentGalleryTableModel()
    private let extensionLoadButton = ThemedButton()
    private let extensionProcessStatus = NSTextField(
        wrappingLabelWithString: L10n.string(
            "Choose an extension directory to start its interactive process."
        )
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
        extensionProcessStatus.stringValue = L10n.string(
            "Choose an extension directory to start its interactive process."
        )
        replaceExtensionProcessPreview(with: nil)
    }

    override func loadView() {
        let root = NSView()
        root.applySurface(
            fill: Design.Surface.ground,
            radius: .fixed(0),
            pattern: .backdrop
        )
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
        let title = NSTextField(labelWithString: L10n.string("Component Gallery"))
        title.applyFont(.heading)
        title.textColor = Design.Text.label

        let subtitle = NSTextField(
            labelWithString: L10n.string(
                "Theme is app-wide · Light/Dark is scoped to this window"
            )
        )
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
        themePopUp.setAccessibilityLabel(L10n.string("Gallery theme"))
    }

    private func configureAppearanceToggle() {
        appearanceToggle.state = appearanceMode == .dark ? .on : .off
        appearanceToggle.target = self
        appearanceToggle.action = #selector(appearanceChanged)
        appearanceToggle.setAccessibilityLabel(L10n.string("Dark appearance"))
    }

    // MARK: Stories

    private func makeGallery() -> NSView {
        let sections = NSStackView(views: [
            makeButtonsAndChoicesSection(),
            makeTextSection(),
            makeFeedbackSection(),
            makeUsageAnalyticsSection(),
            makePresentationSection(),
            makeContainersSection(),
            makeBrowserChromeSection(),
            makeWindowChromeSection(),
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
        scroll.applySurface(
            fill: Design.Surface.ground,
            radius: .fixed(0),
            pattern: .backdrop
        )

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
            accessibility: L10n.string("Icon button"),
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
        toggle.setAccessibilityLabel(L10n.string("Interactive toggle"))

        let onToggle = ThemedToggle()
        onToggle.state = .on
        onToggle.target = self
        onToggle.action = #selector(sampleToggleChanged)
        onToggle.setAccessibilityLabel(L10n.string("On toggle"))

        let disabledToggle = ThemedToggle()
        disabledToggle.state = .on
        disabledToggle.isEnabled = false
        disabledToggle.setAccessibilityLabel(L10n.string("Disabled toggle"))

        let toggleRow = row([
            labelledInline("Off", toggle),
            labelledInline("On", onToggle),
            labelledInline("Disabled", disabledToggle)
        ])

        let checkbox = ThemedCheckbox(title: L10n.string("Include this one")) { [weak self] state in
            self?.showReceipt(L10n.format(
                "ThemedCheckbox is now %@.",
                state == .on ? L10n.string("on") : L10n.string("off")
            ))
        }
        let mixedCheckbox = ThemedCheckbox(
            title: L10n.string("Some of these"),
            state: .mixed
        ) { _ in }
        let disabledCheckbox = ThemedCheckbox(
            title: L10n.string("Unavailable"),
            state: .on
        ) { _ in }
        disabledCheckbox.isEnabled = false
        let checkboxRow = row([checkbox, mixedCheckbox, disabledCheckbox])

        let selectedRadio = ThemedRadioButton(
            title: L10n.string("On"),
            state: .on
        ) { [weak self] _ in
            self?.showReceipt(L10n.string("On"))
        }
        let emptyRadio = ThemedRadioButton(title: L10n.string("Off")) { _ in }
        let disabledRadio = ThemedRadioButton(
            title: L10n.string("Unavailable"),
            state: .on
        ) { _ in }
        disabledRadio.isEnabled = false
        let radioRow = row([selectedRadio, emptyRadio, disabledRadio])

        let disclosureTitle = NSTextField(labelWithString: L10n.string("Advanced details"))
        disclosureTitle.applyFont(.control)
        disclosureTitle.textColor = Design.Text.label
        let disclosureSummary = NSTextField(
            labelWithString: L10n.string("A full-width keyboard and VoiceOver control")
        )
        disclosureSummary.applyFont(.subheading)
        disclosureSummary.textColor = Design.Text.secondary
        let disclosureContent = NSStackView(views: [disclosureTitle, disclosureSummary])
        disclosureContent.orientation = .vertical
        disclosureContent.alignment = .leading
        disclosureContent.spacing = Design.Spacing.hairline
        let disclosure = ThemedDisclosureRow(content: disclosureContent)
        disclosure.setAccessibilityLabel(L10n.string("Advanced details"))
        let disclosureDetail = smallLabel(
            L10n.string("Expanded content remains owned by the surrounding settings card.")
        )
        disclosureDetail.isHidden = true
        disclosure.onToggle = { [weak self, weak disclosureDetail] isExpanded in
            disclosureDetail?.isHidden = !isExpanded
            self?.showReceipt(L10n.string(
                isExpanded ? "Expanded advanced details." : "Collapsed advanced details."
            ))
        }
        let disclosureStory = NSStackView(views: [disclosure, disclosureDetail])
        disclosureStory.orientation = .vertical
        disclosureStory.alignment = .leading
        disclosureStory.spacing = Design.Spacing.small
        disclosure.widthAnchor.constraint(equalTo: disclosureStory.widthAnchor).isActive = true
        disclosureStory.widthAnchor.constraint(equalToConstant: 420).isActive = true

        let segmented = ThemedSegmentedControl()
        let segmentTitles = [
            L10n.string("List"),
            L10n.string("Outline"),
            L10n.string("Grid")
        ]
        segmented.configure(titles: segmentTitles, selectedIndex: 1)
        segmented.onSelect = { [weak self] index in
            self?.showReceipt(L10n.format(
                "ThemedSegmentedControl selected %@.",
                segmentTitles[index]
            ))
        }

        let navigatorCellLabel = NSTextField(
            labelWithString: L10n.string("Navigator cell")
        )
        navigatorCellLabel.applyFont(.control)
        navigatorCellLabel.textColor = Design.Text.label
        let navigatorCell = NavigatorGridItemView(content: navigatorCellLabel)
        navigatorCell.isSelected = true
        navigatorCell.setAccessibilityLabel(
            L10n.string("Selected navigator grid item.")
        )
        navigatorCell.onActivate = { [weak self, weak navigatorCell] in
            navigatorCell?.isSelected.toggle()
            self?.showReceipt(L10n.string("Activated the navigator grid item."))
        }
        navigatorCell.widthAnchor.constraint(equalToConstant: 160).isActive = true
        navigatorCell.heightAnchor.constraint(equalToConstant: 72).isActive = true

        let popUp = ThemedPopUp()
        [
            L10n.string("First choice"),
            L10n.string("Second choice"),
            L10n.string("Third choice")
        ].forEach(popUp.addItem)
        popUp.target = self
        popUp.action = #selector(samplePopUpChanged)

        let disabledPopUp = ThemedPopUp()
        disabledPopUp.addItem(withTitle: L10n.string("Disabled"))
        disabledPopUp.isEnabled = false

        let chip = ChipView()
        chip.configure(symbolName: "paintpalette", title: L10n.string("Open chip menu"))
        chip.setAccessibilityIdentifier("gallery.menu.chip")
        chip.itemsProvider = {
            [
                .item(ThemedMenuItem(
                    title: L10n.string("Alpha"),
                    subtitle: L10n.string("Selected item with supporting text"),
                    representedValue: "Alpha",
                    isSelected: chip.selectedItem?.title == "Alpha"
                )),
                .item(ThemedMenuItem(
                    title: L10n.string("Beta"),
                    representedValue: "Beta",
                    isSelected: chip.selectedItem?.title == "Beta"
                )),
                .separator,
                .item(ThemedMenuItem(
                    title: L10n.string("Unavailable"),
                    subtitle: L10n.string("Disabled state"),
                    isEnabled: false
                ))
            ]
        }
        chip.onSelect = { [weak self] item in
            chip.configure(symbolName: "paintpalette", title: item.title)
            self?.showReceipt(L10n.format("ChipView selected “%@”.", item.title))
        }

        let activeTab = ThemedTabItemView(
            title: L10n.string("Terminal"),
            symbolName: "terminal",
            placement: .horizontal,
            showsClose: true,
            inkSource: .chrome
        )
        activeTab.isSelected = true
        activeTab.onSelect = { [weak self] in
            self?.showReceipt(L10n.string("Selected the Terminal tab."))
        }
        activeTab.onClose = { [weak self] in
            self?.showReceipt(L10n.string("Closed the Terminal tab."))
        }

        let inactiveTab = ThemedTabItemView(
            title: L10n.string("Browser"),
            symbolName: "globe",
            placement: .horizontal,
            showsClose: true,
            inkSource: .chrome
        )
        inactiveTab.onSelect = { [weak self] in
            self?.showReceipt(L10n.string("Selected the Browser tab."))
        }

        let sidebarTab = ThemedTabItemView(
            title: L10n.string("Themes"),
            symbolName: "paintpalette",
            placement: .sidebar,
            inkSource: .chrome
        )
        sidebarTab.isSelected = true
        sidebarTab.widthAnchor.constraint(equalToConstant: 180).isActive = true

        let newSessionButton = ThemedIconButton(
            symbolName: "plus",
            accessibility: L10n.string("New session")
        )
        newSessionButton.onPress = { [weak self] in
            self?.showReceipt(L10n.string("Opened the new-session page."))
        }

        let selectedToolbarButton = ThemedIconButton(
            symbolName: "sidebar.trailing",
            accessibility: L10n.string("Selected toolbar action")
        )
        selectedToolbarButton.isSelected = true
        selectedToolbarButton.onPress = { [weak self] in
            self?.showReceipt(L10n.string("Pressed the selected toolbar action."))
        }

        // The toolbar's page tab: the *same* class as the two above it, differing only in the
        // ground it inks from. Shown beside them on purpose — this pair used to be two
        // implementations, and the gallery is where that would show.
        let activeSession = ThemedTabItemView(
            title: L10n.string("Active session"),
            symbolName: "chevron.left.forwardslash.chevron.right",
            placement: .horizontal,
            showsClose: true,
            inkSource: .backdrop
        )
        activeSession.isSelected = true
        activeSession.onSelect = { [weak self] in
            self?.showReceipt(L10n.string("Revealed the active page in the sidebar."))
        }
        activeSession.onClose = { [weak self] in
            self?.showReceipt(
                L10n.string("Closed the active page without stopping its session.")
            )
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
                    "ThemedCheckbox",
                    "Off, on, mixed for a group that disagrees, and disabled.",
                    checkboxRow
                ),
                story(
                    "ThemedRadioButton",
                    "Selected, empty, disabled, and radio-group accessibility.",
                    radioRow
                ),
                story(
                    "ThemedDisclosureRow",
                    "A full-width collapsible header with hover, focus, keyboard, and accessibility states.",
                    disclosureStory
                ),
                story(
                    "ThemedSegmentedControl",
                    "Two or three fixed choices with selection, arrows, and radio-group accessibility.",
                    segmented
                ),
                story(
                    "NavigatorGridItemView",
                    "A selectable navigator cell with hover, focus, press, and host-owned chrome.",
                    navigatorCell
                ),
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
                    "ThemedTabStripView",
                    "The strip those tabs live in: select, close, drag a chip along it, or reorder from its secondary-click menu.",
                    makeTabStripStory()
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
                ),
                story(
                    "ControlRowView",
                    "One height across every control in the row, the two runs held at opposite "
                        + "edges, and the outer two aligned by ink. The height is the theme's: "
                        + "switch the style above and every member follows the chooser.",
                    makeControlRowStory()
                ),
                story(
                    "SplitIconButtonView",
                    "One plate, two halves: hover each in turn — the raise stays inside the shared silhouette.",
                    makeSplitButtonStory()
                ),
                story(
                    "ExecutionAuditEventView",
                    "One audit row per source, resting and selected: the ledger's fixed grid of category, phase, operation and fidelity.",
                    makeExecutionAuditStory()
                ),
                story(
                    "ConversationHandoffView",
                    "A continuation path across runtimes: the direct source is offered as an action, the older stops stay as provenance.",
                    makeConversationHandoffStory()
                )
            ]
        )
    }

    /// The control row story's own width, for the reason the audit row states below: both of the
    /// row's edges are what it demonstrates, and a row sized to its contents has no gap to hold.
    private enum ControlRowStory {
        static let width: CGFloat = 460
    }

    /// The notice story's pane. Wider than the sidebar's stories because the band it holds is a
    /// *content* pane's, and at the sidebar's width the sentence would truncate on every theme —
    /// which is the one state this story is not about.
    private enum GalleryNotice {
        static let paneWidth: CGFloat = 560
        @MainActor static var paneHeight: CGFloat { PaneHeaderView.bandHeight * 3 }
    }

    /// The audit story's own measurements. The row is given a width because the ledger's grid is
    /// the thing being shown: at the story stack's natural width the four columns would be spaced
    /// by whatever this fixture's longest summary happens to be.
    private enum AuditStory {
        static let rowWidth: CGFloat = 460
        static let durationMilliseconds = 128
    }

    /// The two states a reader has to tell apart at a glance — resting and selected — across the
    /// sources the ledger carries. The records are stated here rather than read from a live
    /// ledger: a story is a fixture, and a row that needed a running audit store to draw would
    /// make this window depend on a session.
    private func makeExecutionAuditStory() -> NSView {
        let rows: [NSView] = [
            (ExecutionAuditRecord.Source.providerStream, false),
            (ExecutionAuditRecord.Source.threadingMCP, false),
            (ExecutionAuditRecord.Source.permissionBroker, true)
        ].map { source, isSelected in
            let view = ExecutionAuditEventView()
            view.configure(
                record: Self.auditStoryRecord(source: source),
                isSelected: isSelected
            )
            view.widthAnchor.constraint(
                equalToConstant: AuditStory.rowWidth
            ).isActive = true
            return view
        }

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.hairline
        return stack
    }

    private static func auditStoryRecord(
        source: ExecutionAuditRecord.Source
    ) -> ExecutionAuditRecord {
        let shape: (
            category: ExecutionAuditRecord.Category,
            phase: ExecutionAuditRecord.Phase,
            operation: String,
            summary: String,
            fidelity: ExecutionAuditRecord.Fidelity
        )
        switch source {
        case .providerStream:
            shape = (.tool, .completed, "Edit", "Design.swift, 2 hunks", .exact)
        case .threadingMCP:
            shape = (.browser, .progressed, "browser_click", "Sign in, #submit", .canonicalized)
        case .permissionBroker:
            shape = (.permission, .allowed, "Bash", "git status", .exactWithRedactions)
        }

        return ExecutionAuditRecord(
            id: UUID(),
            sessionID: SessionID(),
            sequence: 1,
            timestamp: Date(timeIntervalSince1970: 0),
            source: source,
            provider: nil,
            category: shape.category,
            phase: shape.phase,
            operation: shape.operation,
            callID: nil,
            summary: shape.summary,
            input: nil,
            output: nil,
            durationMilliseconds: AuditStory.durationMilliseconds,
            fidelity: shape.fidelity,
            redactions: [],
            previousDigest: nil,
            digest: ""
        )
    }

    /// A three-stop path, the shortest one that shows everything the view says at once: where the
    /// conversation started, the direct source it offers to open, and that the middle of a longer
    /// path can have been compacted away.
    private func makeConversationHandoffStory() -> NSView {
        let endpoints = [
            ConversationHandoffEndpoint(
                sessionID: SessionID(),
                kind: .claude,
                model: "claude-opus-4-1",
                title: nil
            ),
            ConversationHandoffEndpoint(
                sessionID: SessionID(),
                kind: .codex,
                model: "gpt-5",
                title: nil
            ),
            ConversationHandoffEndpoint(
                sessionID: SessionID(),
                kind: .claude,
                model: "claude-opus-4-1",
                title: nil
            )
        ]
        guard let handoff = ConversationHandoff(endpoints: endpoints, omittedEndpointCount: 1)
        else { return NSView() }

        return ConversationHandoffView(
            handoff: handoff,
            canOpenSource: true,
            onOpenSource: nil
        )
    }

    /// The strip wired to its live model: every gesture mutates `stripTabs` and re-renders,
    /// which is also what proves chip reuse — the dragged chip survives its own re-render.
    private func makeTabStripStory() -> NSView {
        stripActiveTabID = stripTabs.first?.id

        tabStrip.onSelect = { [weak self] id in
            guard let self else { return }
            stripActiveTabID = id
            renderTabStripStory()
            let title = stripTabs.first { $0.id == id }?.title ?? ""
            showReceipt(L10n.format("Selected the %@ tab.", title))
        }
        tabStrip.onClose = { [weak self] id in
            guard let self, let index = stripTabs.firstIndex(where: { $0.id == id }) else {
                return
            }
            let removed = stripTabs.remove(at: index)
            if stripActiveTabID == id {
                let neighbour = stripTabs.indices.contains(index)
                    ? stripTabs[index] : stripTabs.last
                stripActiveTabID = neighbour?.id
            }
            renderTabStripStory()
            showReceipt(L10n.format("Closed the %@ tab.", removed.title))
        }
        tabStrip.onReorder = { [weak self] id, index in
            guard let self else { return }
            moveStripTab(id: id, toIndex: index)
        }
        tabStrip.contextEntries = { [weak self] id in
            guard let self, let index = stripTabs.firstIndex(where: { $0.id == id }) else {
                return []
            }
            return [
                .item(ThemedMenuItem(
                    title: L10n.string("Move Left"),
                    isEnabled: index > 0,
                    onChoose: { [weak self] in self?.moveStripTab(id: id, toIndex: index - 1) }
                )),
                .item(ThemedMenuItem(
                    title: L10n.string("Move Right"),
                    isEnabled: index < stripTabs.count - 1,
                    onChoose: { [weak self] in self?.moveStripTab(id: id, toIndex: index + 1) }
                ))
            ]
        }

        renderTabStripStory()
        NSLayoutConstraint.activate([
            tabStrip.widthAnchor.constraint(equalToConstant: 420)
        ])
        return tabStrip
    }

    private func moveStripTab(id: UUID, toIndex index: Int) {
        guard let from = stripTabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = stripTabs.remove(at: from)
        let target = min(max(index, 0), stripTabs.count)
        stripTabs.insert(tab, at: target)
        renderTabStripStory()
        showReceipt(L10n.format("Moved the %@ tab to slot %d.", tab.title, target + 1))
    }

    private func renderTabStripStory() {
        tabStrip.update(items: stripTabs.map {
            TabStripItem(
                id: $0.id,
                title: $0.title,
                symbolName: $0.symbolName,
                isActive: $0.id == stripActiveTabID
            )
        })
    }

    /// A toolbar button whose only job is to report that it was pressed.
    /// The Open In control as the pane header carries it: the app's own icon on the press, and a
    /// narrower chevron welded to it for the day the answer is different.
    ///
    /// Here because the thing worth looking at is what happens *between* the halves — each raises
    /// inside the plate's own silhouette rather than drawing a rounded rect of its own, so
    /// pointing at one does not cut the control in two. Finder stands in because every Mac has
    /// it; in the header this is whichever editor was reached for last.
    private func makeSplitButtonStory() -> NSView {
        let open = ThemedIconButton(
            symbolName: OpenInToolbarDefaults.fallbackSymbol,
            accessibility: L10n.string("Open in external app")
        )
        if let finder = ExternalApps.app(id: ExternalApps.finderID),
           let icon = ExternalAppLauncher.shared.icon(for: finder) {
            open.setImage(icon, accessibility: L10n.format("Open in %@", finder.name))
        }
        open.onPress = { [weak self] in
            self?.showReceipt(L10n.format("Pressed %@.", L10n.string("Open in external app")))
        }

        let choose = ThemedIconButton(
            symbolName: DesignSymbols.chevron,
            accessibility: L10n.string("Choose an app to open in"),
            target: .splitMenu
        )
        choose.onPress = { [weak self] in
            self?.showReceipt(
                L10n.format("Pressed %@.", L10n.string("Choose an app to open in"))
            )
        }

        return row([SplitIconButtonView(action: open, chevron: choose)])
    }

    /// The compare header's own shape, since that is the row this component was written for: a
    /// mode chooser, a caption that doubles as the run's compressible member, and the actions at
    /// the far edge. Given a width because both edges are the point — at the story stack's
    /// natural width there would be no gap for the runs to hold apart.
    private func makeControlRowStory() -> NSView {
        let mode = ChipView()
        mode.configure(symbolName: "rectangle.split.2x1", title: L10n.string("Wipe ↔"))
        mode.itemsProvider = {
            ImageCompareMode.allCases.map { candidate in
                .item(ThemedMenuItem(
                    title: ImageCompareView.name(for: candidate),
                    representedValue: candidate,
                    isSelected: candidate == .wipeHorizontal
                ))
            }
        }
        mode.onSelect = { [weak self] item in
            self?.showReceipt(L10n.format("Pressed %@.", item.title))
        }

        // localization-ignore: A fixture's two file names, which are data rather than copy.
        let caption = NSTextField(labelWithString: "one.png → two.png")
        caption.applyFont(.caption)
        caption.textColor = Design.Text.secondary
        caption.lineBreakMode = .byTruncatingMiddle
        caption.setContentHuggingPriority(.defaultLow, for: .horizontal)
        caption.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let accept = ThemedButton(
            title: L10n.string("Accept"),
            target: self,
            action: #selector(buttonPressed)
        )
        let export = ThemedIconButton(
            symbolName: "square.and.arrow.up",
            accessibility: L10n.string("Export comparison"),
            target: .inline,
            inkSource: .chrome
        )
        export.onPress = { [weak self] in
            self?.showReceipt(L10n.format("Pressed %@.", L10n.string("Export comparison")))
        }
        let expand = ThemedIconButton(
            symbolName: "arrow.up.left.and.arrow.down.right",
            accessibility: L10n.string("Open comparison"),
            target: .inline,
            inkSource: .chrome
        )
        expand.onPress = { [weak self] in
            self?.showReceipt(L10n.format("Pressed %@.", L10n.string("Open comparison")))
        }

        let controlRow = ControlRowView(
            leading: [mode, caption],
            trailing: [accept, export, expand]
        )
        controlRow.widthAnchor.constraint(
            equalToConstant: ControlRowStory.width
        ).isActive = true
        return row([controlRow])
    }

    private func galleryToolbarButton(symbol: String, label: String) -> ThemedIconButton {
        let button = ThemedIconButton(symbolName: symbol, accessibility: L10n.string(label))
        button.onPress = { [weak self] in
            self?.showReceipt(L10n.format("Pressed %@.", L10n.string(label)))
        }
        return button
    }

    private func makeTextSection() -> NSView {
        let field = ThemedTextField(string: L10n.string("Editable text"))
        field.placeholderString = L10n.string("Type here")
        field.target = self
        field.action = #selector(textCommitted)

        let search = ThemedSearchField()
        search.placeholderString = L10n.string("Filter components")
        search.target = self
        search.action = #selector(searchCommitted)

        let disabled = ThemedTextField(string: L10n.string("Disabled"))
        disabled.isEnabled = false

        let secure = ThemedSecureField()
        secure.placeholderString = L10n.string("Test account password")
        secure.target = self
        secure.action = #selector(textCommitted)

        matchQueryField.placeholderString = L10n.string("Type a word, or paste the whole ID")
        matchQueryField.delegate = self
        matchQueryField.setAccessibilityIdentifier("gallery.search-match.query")

        for field in [field, search, disabled, secure, matchQueryField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true
        }

        markSampleLines()
        let matchLines = NSStackView(views: matchSamples)
        matchLines.orientation = .vertical
        matchLines.alignment = .leading
        matchLines.spacing = Design.Spacing.hairline
        let matchStory = NSStackView(views: [matchQueryField, matchLines])
        matchStory.orientation = .vertical
        matchStory.alignment = .leading
        matchStory.spacing = Design.Spacing.small

        let scrollingText = ThemedTextView.scrolling()
        scrollingText.translatesAutoresizingMaskIntoConstraints = false
        scrollingText.heightAnchor.constraint(equalToConstant: 100).isActive = true
        scrollingText.applySurface(
            fill: Design.Surface.controlResting,
            radius: .control,
            border: Design.Surface.border
        )
        if let text = scrollingText.documentView as? ThemedTextView {
            text.string = L10n.string(
                "ThemedTextView preserves AppKit editing while the text, insertion point, and "
                    + "scroll surface follow the selected theme.\n\n"
                    + "Try selecting, editing, and scrolling this text."
            )
            text.applyFont(.body)
            text.textContainerInset = NSSize(width: Design.Spacing.medium, height: Design.Spacing.medium)
        }

        let prompt = PromptView()
        prompt.showsImageAttachments = true
        prompt.placeholder = L10n.string("Write a multi-line prompt; Return submits")
        prompt.minimumHeight = 72
        let previewPaths = [
            AgentIconDefaults.claudeResource,
            AgentIconDefaults.codexResource
        ].compactMap { name -> String? in
            guard let url = Bundle.main.url(
                forResource: name,
                withExtension: AgentIconDefaults.resourceExtension,
                subdirectory: AgentIconDefaults.resourceSubdirectory
            ) else { return nil }
            return url.path
        }
        prompt.attachFiles(at: previewPaths)
        prompt.onChange = { [weak self] text in
            let message = text.count == 1
                ? L10n.string("PromptView contains 1 character.")
                : L10n.format("PromptView contains %lld characters.", Int64(text.count))
            self?.showReceipt(message)
        }
        prompt.onSubmit = { [weak self] text in
            self?.showReceipt(
                L10n.format("PromptView submitted “%@”.", String(text.prefix(80)))
            )
        }

        // The chat surface's shape, which the growing-composer story above cannot show: what a
        // message is sent *with* lives on a row inside the box, and the send closes that row.
        let replyPrompt = PromptView()
        replyPrompt.fontSurface = .conversation
        replyPrompt.showsImageAttachments = true
        replyPrompt.submitPlacement = .footer
        replyPrompt.placeholder = L10n.string("Reply to the agent")

        let galleryModelChip = ChipView()
        galleryModelChip.configure(symbolName: "cpu", title: L10n.string("Opus · 1M"))
        galleryModelChip.itemsProvider = { [] }
        let gallerySpeedChip = ChipView()
        gallerySpeedChip.configure(symbolName: "bolt.fill", title: L10n.string("Standard"))
        gallerySpeedChip.itemsProvider = { [] }
        let galleryContextMeter = NSTextField(labelWithString: L10n.string("37% context"))
        galleryContextMeter.applyFont(.subheading)
        galleryContextMeter.textColor = Design.Text.tertiary

        replyPrompt.setFooterControls(
            leading: [galleryModelChip, gallerySpeedChip],
            trailing: [galleryContextMeter]
        )
        replyPrompt.onSubmit = { [weak self] text in
            self?.showReceipt(
                L10n.format("PromptView submitted “%@”.", String(text.prefix(80)))
            )
        }

        let contextRail = ConversationContextRailView(mode: .composer)
        contextRail.setAttachments([
            ConversationContextAttachment(
                kind: .reference,
                source: .code,
                title: "PromptView.swift:42",
                excerpt: "guard canSend else { return }",
                locator: "Sources/Threading/UI/Design/PromptView.swift",
                lineStart: 42,
                lineEnd: 42
            ),
            ConversationContextAttachment(
                kind: .comment,
                source: .attachment,
                title: "layout.png",
                comment: "Reduce the space above the toolbar.",
                locator: "attachments/layout.png"
            )
        ])
        contextRail.onComment = { [weak self] attachment in
            self?.showReceipt(L10n.format("Comment on %@.", attachment.title))
        }
        contextRail.onRemove = { [weak self] attachment in
            self?.showReceipt(L10n.format("Removed %@ from the prompt.", attachment.title))
        }

        // Three states at once, because the difference between them is the whole component: two
        // waiting rows the user can still reorder and edit, and one already handed to the agent
        // that they cannot.
        // Three states at once again, and the third is the point: a row simply waiting for
        // its moment, one whose session stayed busy, and one the clock passed while the app was
        // closed. Only the last two offer Send now — a schedule doing what it was asked to needs
        // no rescue.
        let scheduledStrip = ScheduledMessageStripView()
        var scheduledRows: [ScheduledMessageStripView.Row] = [
            ScheduledMessageStripView.Row(
                id: ScheduledMessageID(),
                summary: "Pick the importer back up where we left it.",
                timing: "tomorrow 09:00 · in 16h",
                problem: nil
            ),
            ScheduledMessageStripView.Row(
                id: ScheduledMessageID(),
                summary: "Run the full suite before you write the note.",
                timing: "13:20 · in 2h",
                problem: "Waiting for the session to be free"
            ),
            ScheduledMessageStripView.Row(
                id: ScheduledMessageID(),
                summary: "Draft the release note for the scheduling work.",
                timing: "09:00 · in 1d",
                problem: "Missed while Threading was closed"
            )
        ]
        scheduledStrip.setRows(scheduledRows)
        scheduledStrip.onRemove = { id in
            scheduledRows.removeAll { $0.id == id }
            scheduledStrip.setRows(scheduledRows)
        }

        let outboxRail = ConversationOutboxRailView()
        var outboxRows: [ConversationOutboxRailView.Row] = [
            ConversationOutboxRailView.Row(
                id: ConversationMessageID(),
                summary: "Then run the tests and fix whatever fails.",
                state: .started
            ),
            ConversationOutboxRailView.Row(
                id: ConversationMessageID(),
                summary: "Add a rendered-state test for the new rail.",
                state: .queued
            ),
            ConversationOutboxRailView.Row(
                id: ConversationMessageID(),
                summary: "Update the architecture note when it settles.",
                state: .queued
            )
        ]
        outboxRail.setRows(outboxRows)
        outboxRail.onMove = { [weak self] from, to in
            let pending = outboxRows.indices.filter { outboxRows[$0].state.isPending }
            guard pending.indices.contains(from), pending.indices.contains(to) else { return }
            outboxRows.swapAt(pending[from], pending[to])
            outboxRail.setRows(outboxRows)
            self?.showReceipt(L10n.string("Reordered the queue."))
        }
        outboxRail.onRemove = { [weak self] id in
            outboxRows.removeAll { $0.id == id }
            outboxRail.setRows(outboxRows)
            self?.showReceipt(L10n.string("Removed a queued message."))
        }
        outboxRail.onEdit = { [weak self] _ in
            self?.showReceipt(L10n.string("Opened a queued message for editing."))
        }

        // Armed, it swallows key equivalents, so a chord that is already a menu shortcut can be
        // pressed here and captured rather than firing its command — which is the behaviour worth
        // being able to try by hand.
        let recorder = ShortcutRecorderView(
            shortcut: KeyboardShortcut(key: "r", modifiers: [.command, .shift])
        )
        recorder.onRecord = { [weak self] shortcut in
            self?.showReceipt(
                L10n.format(
                    "ShortcutRecorderView captured %@.",
                    shortcut?.displayString ?? L10n.string("no shortcut")
                )
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
                    "ThemedSecureField",
                    "The same well with AppKit's secure cell inside it, so masking, the "
                        + "pasteboard rules and the input-method log stay where the system puts "
                        + "them. Deliberately no reveal control: a field that can be un-masked "
                        + "puts a password on screen while an agent may be driving the app "
                        + "beside it.",
                    row([secure])
                ),
                story(
                    "SearchMatchLabel",
                    "The run a query accounts for takes weight and a ground — both, so a match "
                        + "survives Differentiate Without Colour. Paste the whole ID to see a "
                        + "line shorter than the query still answer for itself.",
                    matchStory
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
                ),
                story(
                    "PromptView · control row",
                    "The chat reply's shape: what the message is sent with sits inside the box, "
                        + "and the send finishes the row.",
                    replyPrompt
                ),
                story(
                    "ConversationContextRailView",
                    "Reference and comment receipts. Open either chip to comment or remove it.",
                    contextRail
                ),
                story(
                    "ConversationOutboxRailView",
                    "Messages waiting to be sent. Drag a waiting row to reorder it, click one to "
                        + "edit it, ⌘↑/⌘↓ from the keyboard. The row already handed to the agent "
                        + "offers neither, because it is no longer ours to withdraw.",
                    outboxRail
                ),
                story(
                    "ScheduledMessageStripView",
                    "Messages waiting for a later moment, above the queue waiting only for this "
                        + "turn. Ordered by the clock rather than by hand, so no row drags — "
                        + "click one to open it, ✕ to unschedule it, and Send now where the "
                        + "clock has stopped being the thing to say.",
                    scheduledStrip
                )
            ]
        )
    }

    private func makeFeedbackSection() -> NSView {
        spinner.isAnimating = true
        spinner.setAccessibilityLabel(L10n.string("Working"))

        let spinnerButton = button("Stop spinner", action: #selector(toggleSpinner))
        spinnerButton.setAccessibilityIdentifier("gallery.spinner.toggle")

        for orb in workingOrbs {
            orb.setAccessibilityLabel(
                L10n.format("%@ orb", orb.state.localizedLabel)
            )
        }
        let orbButton = button("Hide orbs", action: #selector(toggleWorkingOrb))
        orbButton.setAccessibilityIdentifier("gallery.working-orb.toggle")
        let orbVariantRows = stride(from: 0, to: workingOrbs.count, by: 3).map { start in
            row(workingOrbs[start..<min(start + 3, workingOrbs.count)].map { orb in
                labelledControl(orb.state.localizedLabel, control: orb)
            })
        }
        let orbVariants = NSStackView(views: orbVariantRows)
        orbVariants.orientation = .vertical
        orbVariants.alignment = .leading
        orbVariants.spacing = Design.Spacing.medium

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
                    "All nine theme-accented variants. A conversation chooses one per turn; "
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
                    "AgentWorkSummaryView",
                    "The bounded Activity overview above the filesystem tree: the "
                        + "repository atlas, action ribbon, counts, and recent agents share one "
                        + "stable file axis even when the checkout has thousands of files.",
                    makeAgentWorkSummarySample()
                ),
                story(
                    "AgentActivityBeamView",
                    "The System-theme activity ring around a live surface. Cycle idle, one agent, "
                        + "and three agents at top effort; styled themes intentionally decline it.",
                    makeAgentActivityBeamSample()
                ),
                story(
                    "SeparatorView",
                    "Horizontal and vertical orientations use the theme’s divider and border weight.",
                    row([horizontal, vertical])
                ),
                story(
                    "ThemedWarningMark",
                    "A stop nobody typed — the mark a session wears when its account’s usage "
                        + "limit is spent. Negative and warning roles, and corners taken from "
                        + "the theme: square a style’s panels and this squares with them.",
                    row(warningMarkSamples())
                ),
                story(
                    "GlyphView",
                    "Tinted template glyphs drawn on the device pixel grid; a slot caps foreign artwork.",
                    row(glyphSamples())
                ),
                story(
                    "ThemedFloatingGlyphView",
                    "The marks app-owned floating content names semantically. Switch to a period "
                        + "theme: every one of them drops its SF Symbol for the one-bit mark that "
                        + "material draws instead.",
                    row(floatingGlyphSamples())
                ),
                story(
                    "SubmissionStatusView",
                    "How a submitted thing ended. Press each: the wording and the glyph carry "
                        + "the outcome, so it survives Differentiate Without Colour — and every "
                        + "change announces itself to VoiceOver.",
                    row([submissionStatus, submissionButtons()])
                )
            ]
        )
    }

    private func makeUsageAnalyticsSection() -> NSView {
        galleryUsageChart.setModel(
            galleryChartModel(alternate: galleryUsageChartShowsAlternateData),
            animated: false
        )
        galleryStackedUsageChart.setModel(
            galleryStackedChartModel(alternate: galleryUsageChartShowsAlternateData),
            animated: false
        )
        galleryUsageChart.translatesAutoresizingMaskIntoConstraints = false
        galleryUsageChart.widthAnchor.constraint(equalToConstant: 820).isActive = true
        galleryStackedUsageChart.translatesAutoresizingMaskIntoConstraints = false
        galleryStackedUsageChart.widthAnchor.constraint(equalToConstant: 820).isActive = true

        let switchData = button("Switch data", action: #selector(toggleGalleryUsageChart))
        let chartSample = NSStackView(views: [galleryUsageChart, switchData])
        chartSample.orientation = .vertical
        chartSample.alignment = .leading
        chartSample.spacing = Design.Spacing.small

        let switchStackedData = button("Switch data", action: #selector(toggleGalleryUsageChart))
        let stackedChartSample = NSStackView(views: [galleryStackedUsageChart, switchStackedData])
        stackedChartSample.orientation = .vertical
        stackedChartSample.alignment = .leading
        stackedChartSample.spacing = Design.Spacing.small

        let dashboard = galleryUsageDashboardFixture()
        dashboard.translatesAutoresizingMaskIntoConstraints = false
        dashboard.widthAnchor.constraint(equalToConstant: 820).isActive = true

        return section(
            "Usage analytics",
            note: "Provider-neutral charts and the retained dashboard they compose.",
            rows: [
                story(
                    "ThemedTimeSeriesChartView",
                    "Hover or arrow through points, then switch data to inspect the interrupted morph animation.",
                    chartSample
                ),
                story(
                    "ThemedStackedBandChartView",
                    "Hover or arrow through points, then switch data to inspect the interrupted morph animation.",
                    stackedChartSample
                ),
                story(
                    "UsageDashboardView",
                    "Overview and Limit History are separate tabs; switch ranges or metrics to inspect the retained chart morph.",
                    dashboard
                )
            ]
        )
    }

    @objc private func toggleGalleryUsageChart() {
        galleryUsageChartShowsAlternateData.toggle()
        galleryUsageChart.setModel(
            galleryChartModel(alternate: galleryUsageChartShowsAlternateData),
            animated: true
        )
        galleryStackedUsageChart.setModel(
            galleryStackedChartModel(alternate: galleryUsageChartShowsAlternateData),
            animated: true
        )
        showReceipt(L10n.string("Switched the chart data."))
    }

    private func galleryChartModel(alternate: Bool) -> ThemedChartModel {
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: -20, to: today) ?? today
        let primary = (0...20).map { index in
            ThemedChartPoint(
                at: calendar.date(byAdding: .day, value: index, to: start) ?? start,
                value: alternate
                    ? 12 + Double((index * 11 + 7) % 25)
                    : 8 + Double((index * 7 + 3) % 19),
                label: L10n.format("%lld requests", Int64(index + 12)),
                detail: L10n.string("Observed")
            )
        }
        let comparison = stride(from: 0, through: 20, by: 2).map { index in
            ThemedChartPoint(
                at: calendar.date(byAdding: .day, value: index, to: start) ?? start,
                value: alternate
                    ? 6 + Double((index * 5 + 9) % 14)
                    : 10 + Double((index * 3 + 1) % 16),
                label: L10n.format("%lld requests", Int64(index + 6)),
                detail: L10n.string("Comparison")
            )
        }
        let resetAt = calendar.date(byAdding: .day, value: 7, to: start) ?? start
        return ThemedChartModel(
            title: L10n.string("Usage over time"),
            accessibilitySummary: L10n.string("Two provider series with one recorded reset."),
            series: [
                ThemedChartSeries(
                    id: "gallery-primary",
                    title: L10n.string("Claude Code"),
                    points: primary,
                    style: .categorical(0),
                    fillsArea: true
                ),
                ThemedChartSeries(
                    id: "gallery-comparison",
                    title: L10n.string("Codex"),
                    points: comparison,
                    style: .categorical(1),
                    fillsArea: true
                )
            ],
            markers: [ThemedChartMarker(
                id: "gallery-reset",
                at: resetAt,
                title: L10n.string("Reset"),
                detail: L10n.string("Recorded reset boundary"),
                kind: .reset
            )],
            xRange: start...today,
            valueFormat: .number
        )
    }

    private func galleryStackedChartModel(alternate: Bool) -> ThemedChartModel {
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: -20, to: today) ?? today
        let titles = [
            L10n.string("Claude Code"),
            L10n.string("Codex"),
            L10n.string("Grok")
        ]
        let series = titles.enumerated().map { seriesIndex, title in
            ThemedChartSeries(
                id: "gallery-stacked-\(seriesIndex)",
                title: title,
                points: (0...20).map { pointIndex in
                    let shiftedIndex = pointIndex + seriesIndex * 3 + (alternate ? 5 : 0)
                    let value = 3 + Double((shiftedIndex * (seriesIndex + 4)) % 13)
                    return ThemedChartPoint(
                        at: calendar.date(byAdding: .day, value: pointIndex, to: start) ?? start,
                        value: value,
                        label: L10n.format("%lld requests", Int64(value)),
                        detail: L10n.string("Observed")
                    )
                },
                style: .categorical(seriesIndex),
                fillsArea: true
            )
        }
        return ThemedChartModel(
            title: L10n.string("Usage over time"),
            accessibilitySummary: L10n.string("Usage over time"),
            series: series,
            xRange: start...today,
            valueFormat: .number
        )
    }

    private func galleryUsageDashboardFixture() -> UsageDashboardView {
        let dashboard = UsageDashboardView()
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: Date())
        let origins: [UsageOrigin] = [
            .direct(.claude),
            .direct(.codex),
            .direct(.grok),
            .direct(.openCode),
            .openCode(providerID: "openrouter")
        ]
        var cells: [TranscriptUsageReport.Cell] = []
        for dayIndex in 0..<35 {
            let day = calendar.date(byAdding: .day, value: -dayIndex, to: today) ?? today
            for (routeIndex, origin) in origins.enumerated() {
                let wave = 0.45 + Double((dayIndex * (routeIndex + 2)) % 9) / 10
                let cost = wave * Double(routeIndex + 1) * 0.72
                cells.append(TranscriptUsageReport.Cell(
                    day: day,
                    origin: origin,
                    accountID: "\(origin.runtimeID):gallery",
                    accountName: L10n.string("Personal"),
                    model: galleryModelName(for: origin),
                    checkoutPath: "/component-gallery/project-\(dayIndex % 12)",
                    checkoutLabel: L10n.format("Project %lld", Int64(dayIndex % 12 + 1)),
                    tokens: UsageTokenCounts(
                        uncachedInput: Int64(cost * 110_000),
                        cachedInput: Int64(cost * 360_000),
                        cacheWrite: Int64(cost * 24_000),
                        output: Int64(cost * 58_000),
                        reasoning: Int64(cost * 8_000)
                    ),
                    providerReportedCostUSD: origin.billingProviderID == "openrouter" ? cost : 0,
                    catalogCostUSD: origin.billingProviderID == "openrouter" ? 0 : cost,
                    unpricedTokens: origin.runtimeID == AgentKind.grok.rawValue
                        ? Int64(cost * 18_000) : 0,
                    cacheSavingsUSD: cost * 2.1,
                    records: 5 + (dayIndex + routeIndex) % 16
                ))
            }
        }
        var scan = TranscriptUsageReport.ScanStatistics()
        scan.sourceFiles = 96
        scan.cacheHits = 91
        scan.cacheMisses = 5
        scan.rawRecords = 8_240
        scan.distinctRecords = 8_019
        let report = TranscriptUsageReport(
            cells: cells,
            coverage: galleryUsageCoverage,
            scan: scan,
            builtAt: Date()
        )
        dashboard.update(
            report: report,
            limits: [galleryUsageLimitFixture(now: Date())],
            isBuilding: false,
            animated: false
        )
        return dashboard
    }

    private var galleryUsageCoverage: [UsageSourceCoverage] {
        [
            UsageSourceCoverage(runtimeID: "claude", runtimeName: "Claude Code", state: .complete, sourceCount: 31, recordCount: 3_182, detail: "Local transcripts"),
            UsageSourceCoverage(runtimeID: "codex", runtimeName: "Codex", state: .complete, sourceCount: 24, recordCount: 2_954, detail: "Local rollout files"),
            UsageSourceCoverage(runtimeID: "grok", runtimeName: "Grok", state: .partial, sourceCount: 0, recordCount: 0, detail: "Context occupancy only"),
            UsageSourceCoverage(runtimeID: "opencode", runtimeName: "OpenCode", state: .complete, sourceCount: 41, recordCount: 1_883, detail: "Supported local exports"),
            UsageSourceCoverage(runtimeID: "openrouter", runtimeName: "OpenRouter via OpenCode", state: .complete, sourceCount: 12, recordCount: 734, detail: "Billing route from OpenCode")
        ]
    }

    private func galleryModelName(for origin: UsageOrigin) -> String {
        switch origin.billingProviderID {
        case "anthropic": return "claude-opus-4"
        case "openai": return "gpt-5.6-sol"
        case "xai": return "grok-4"
        case "openrouter": return "openrouter/auto"
        default: return "opencode/zen"
        }
    }

    private func galleryUsageLimitFixture(now: Date) -> UsageLimitDashboardSeries {
        let day: TimeInterval = 86_400
        let start = now.addingTimeInterval(-25 * day)
        let samples = (0...25).map { index -> UsageSample in
            let cycle = index / 7
            let step = index % 7
            let at = start.addingTimeInterval(Double(index) * day)
            let reset = start.addingTimeInterval(Double((cycle + 1) * 7) * day)
            return UsageSample(
                at: at,
                fraction: min(0.97, 0.10 + Double(step) * 0.145),
                resetsAt: reset,
                runtimeID: AgentKind.codex.rawValue,
                accountID: "codex:gallery",
                accountName: L10n.string("Personal"),
                windowID: "weekly",
                windowLabel: L10n.string("Weekly"),
                windowDuration: 7 * day,
                source: .codexAPI,
                nextResetCreditExpiresAt: now.addingTimeInterval(1.4 * day),
                resetCreditCount: 3
            )
        }
        let resets = [7, 14, 21].map { index in
            let detected = start.addingTimeInterval(Double(index) * day)
            return UsageLimitResetEvent(
                id: "gallery-reset-\(index)",
                runtimeID: AgentKind.codex.rawValue,
                accountID: "codex:gallery",
                accountName: L10n.string("Personal"),
                windowID: "weekly",
                windowLabel: L10n.string("Weekly"),
                previousObservedAt: detected.addingTimeInterval(-day),
                detectedAt: detected,
                oldScheduledResetAt: detected,
                newScheduledResetAt: detected.addingTimeInterval(7 * day),
                restoredFraction: 0.97,
                elapsedFraction: 1,
                secondsEarly: 0,
                cause: .scheduled
            )
        }
        let projection = UsageLimitProjection(
            observedAt: now,
            observedFraction: 0.68,
            resetsAt: now.addingTimeInterval(3 * day),
            projectedFractionAtReset: 1,
            projectedExhaustionAt: now.addingTimeInterval(2.2 * day),
            resetCreditExpiresAt: now.addingTimeInterval(1.4 * day)
        )
        return UsageLimitDashboardSeries(
            id: "codex|gallery|weekly",
            runtimeName: L10n.string("Codex"),
            accountName: L10n.string("Personal"),
            windowLabel: L10n.string("Weekly"),
            samples: samples,
            resets: resets,
            projection: projection,
            currentFraction: 0.68,
            resetsAt: projection.resetsAt,
            resetCreditCount: 3,
            nextResetCreditExpiresAt: projection.resetCreditExpiresAt
        )
    }

    /// The three states in the order a submission moves through them.
    private func submissionButtons() -> NSView {
        let working = button("Working", action: #selector(showWorkingStatus))
        working.setAccessibilityIdentifier("gallery.submission-status.working")
        let done = button("Done", action: #selector(showDoneStatus))
        done.setAccessibilityIdentifier("gallery.submission-status.done")
        let failed = button("Failed", action: #selector(showFailedStatus))
        failed.setAccessibilityIdentifier("gallery.submission-status.failed")

        let stack = NSStackView(views: [working, done, failed])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.small
        return stack
    }

    @objc private func showWorkingStatus() {
        submissionStatus.show(L10n.string("Filing the issue on GitHub…"), tone: .working)
    }

    @objc private func showDoneStatus() {
        submissionStatus.show(L10n.format("Filed as issue #%lld.", 42), tone: .done)
    }

    @objc private func showFailedStatus() {
        submissionStatus.show(L10n.format("GitHub refused the report (%lld).", 403), tone: .failed)
    }

    /// One glyph per role, plus foreign artwork under the slot cap — the three ways the view
    /// is used in the app's own chrome.
    /// Both roles, each beside the session mark it is ranked against, since the whole argument
    /// for a triangle is that it does not read as a third dot.
    private func warningMarkSamples() -> [NSView] {
        let negative = ThemedWarningMark()
        negative.setAccessibilityLabel(L10n.string("Session stopped at its usage limit"))

        let warning = ThemedWarningMark()
        warning.severity = .warning
        warning.setAccessibilityLabel(L10n.string("Session needs attention"))

        let blocked = SessionStatusIndicator()
        blocked.update(for: .awaitingUser)

        let unread = SessionStatusIndicator()
        unread.update(for: .needsAttention)

        return [negative, warning, blocked, unread]
    }

    private func glyphSamples() -> [NSView] {
        let inline = GlyphView()
        inline.image = Design.Symbol.image(
            "gearshape",
            slot: Design.Size.inlineButtonGlyph,
            pointSize: Design.Symbol.control
        )
        inline.tint = Design.Text.secondary

        let toolbar = GlyphView()
        toolbar.image = Design.Symbol.image(
            "gearshape",
            slot: Design.Size.tabIconSlot,
            pointSize: Design.Symbol.toolbar
        )
        toolbar.tint = Design.Text.secondary

        let capped = GlyphView()
        capped.slot = NSSize(width: Design.Size.tabIconSlot, height: Design.Size.tabIconSlot)
        capped.image = NSApp.applicationIconImage
        return [inline, toolbar, capped]
    }

    /// The whole semantic set, in the pairings the popover and the corner card already use, so a
    /// theme's period marks can be read against each other rather than one at a time in the app.
    /// `.plan` is drawn here before a feature names it: the gallery is where a mark that does not
    /// hold up is meant to be found.
    private func floatingGlyphSamples() -> [NSView] {
        let marks: [(String, ThemedFloatingGlyphView.ClassicGlyph)] = [
            ("folder", .folder),
            ("arrow.triangle.branch", .branch),
            ("arrow.left.arrow.right", .handoff),
            ("circle.fill", .status),
            ("plusminus", .changes),
            ("cpu", .model),
            ("list.bullet.rectangle", .plan),
            ("bolt.fill", .speed)
        ]
        return marks.map { symbolName, classicGlyph in
            let mark = ThemedFloatingGlyphView(
                systemSymbolName: symbolName,
                classicGlyph: classicGlyph,
                pointSize: Design.Symbol.toolbar
            )
            mark.tintColor = Design.Text.secondary
            return mark
        }
    }

    private func makePresentationSection() -> NSView {
        let alert = button("Open alert", action: #selector(showGalleryAlert(_:)))
        alert.setAccessibilityIdentifier("gallery.presentation.alert")
        let popover = button("Open popover", action: #selector(showGalleryPopover(_:)))
        popover.setAccessibilityIdentifier("gallery.presentation.popover")
        let completions = button(
            "Open completions",
            action: #selector(showGalleryCompletions(_:))
        )
        completions.setAccessibilityIdentifier("gallery.presentation.completions")
        let hoverPolicies = makeHoverPolicySample()

        return section(
            "Presentation",
            note: "Open each surface, switch the theme while it is visible, and dismiss it with Escape.",
            rows: [
                story(
                    "ThemedAlert",
                    "App-owned transient surfaces with themed chrome, Escape, focus return, and accessibility.",
                    alert
                ),
                story(
                    "ThemedPopover & ThemedPopoverChromeView",
                    "App-owned transient surfaces with themed chrome, Escape, focus return, and accessibility.",
                    popover
                ),
                story(
                    "PromptCompletionPresenter",
                    "Non-key command and skill suggestions that keep the composer focused while keyboard selection moves.",
                    completions
                ),
                story(
                    "HoverPopoverScheduler",
                    "Hover timing as configured policy: instant, dwell, and dwell with a grace that holds.",
                    hoverPolicies
                )
            ]
        )
    }

    /// The three shipped hover policies, each on its own live anchor.
    private func makeHoverPolicySample() -> NSView {
        let demos = [
            GalleryHoverPolicyDemo(
                title: L10n.string("Instant (usage pill)"),
                message: L10n.string("Visible exactly while the pointer is on the anchor."),
                policy: AccountUsageItemDefaults.readingPopoverPolicy
            ),
            GalleryHoverPolicyDemo(
                title: L10n.string("Dwell (sidebar cards)"),
                message: L10n.string("Waits out a dwell, then closes the instant the pointer leaves."),
                policy: SessionPopoverDefaults.hoverPolicy
            ),
            GalleryHoverPolicyDemo(
                title: L10n.string("Held (extension detail)"),
                message: L10n.string("Grants a grace to cross the gap, and holds while the pointer rests here."),
                policy: ExtensionDisclosureDefaults.popoverPolicy
            )
        ]
        hoverPolicyDemos = demos

        let stack = NSStackView(views: demos.map(\.anchor))
        stack.orientation = .horizontal
        stack.spacing = Design.Spacing.medium
        return stack
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

        let groupedTable = ThemedGroupedTableView()
        let groupedColumn = column("virtual", title: "Virtual rows", width: 420)
        groupedColumn.resizingMask = .autoresizingMask
        groupedTable.addTableColumn(groupedColumn)
        groupedTable.headerView = nil
        groupedTable.style = .plain
        groupedTable.selectionHighlightStyle = .none
        groupedTable.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        groupedTable.intercellSpacing = .zero
        groupedTable.rowHeight = 48
        groupedTable.usesAutomaticRowHeights = true
        groupedTable.delegate = tableModel
        groupedTable.dataSource = tableModel
        groupedTable.cardDecorations = [ThemedTableCardDecoration(rows: 0...3)]

        let groupedScroll = ThemedScrollView()
        groupedScroll.documentView = groupedTable
        groupedScroll.hasVerticalScroller = true
        groupedScroll.translatesAutoresizingMaskIntoConstraints = false
        groupedScroll.heightAnchor.constraint(equalToConstant: 156).isActive = true
        groupedTable.reloadData()

        return section(
            "Data containers",
            note: "The table, outline, header, scroll, and clip boundaries are real AppKit views.",
            rows: [
                story(
                    "SubagentSummaryView",
                    "Working and completed child agents; select a row to inspect its bounded activity.",
                    makeSubagentSummarySample()
                ),
                story(
                    "ImageCompareView & CompareInspectorView",
                    "Two renderings of one asset. Drag the seam or arrow-key it, and pick a "
                        + "mode from the chip: Fade held at the middle is the onion skin, "
                        + "Difference answers whether anything changed at all. The button "
                        + "beside the chip opens the same comparison at the window's size, "
                        + "where Escape closes it and hands back the mode and the scrub it "
                        + "was left at.",
                    makeImageCompareSample()
                ),
                story(
                    "ThemedImagePreview",
                    "A picture that takes the size it is given rather than lending its own: "
                        + "scaled down to fit, never up, hung from the top. Tab to it for the "
                        + "focus ring, then Space — or double-click — to open the file in "
                        + "the media inspector. The one below has no file behind it, so it refuses and "
                        + "stays out of the key loop; that refusal is the state to check.",
                    makeImagePreviewSample()
                ),
                story(
                    "ThemedFileIconView",
                    "Native Finder artwork under System; semantic, theme-owned file kinds under authored themes.",
                    makeFileIconSample()
                ),
                story(
                    "ThemedTableView, ThemedTableRowView & ThemedTableHeaderView",
                    "Select rows and resize the themed header columns. The selected row is the "
                        + "theme's, not AppKit's: switch the theme above and the fill follows it, "
                        + "except under System, where the row hands the highlight back.",
                    tableScroll
                ),
                story(
                    "ThemedGroupedTableView & ThemedVirtualTableCell",
                    "One continuous themed card whose repeating rows are recycled at the "
                        + "viewport boundary. Scroll it to exercise real cell reuse rather than "
                        + "a retained stack disguised as a list.",
                    groupedScroll
                ),
                story(
                    "CodeContextPreviewView",
                    "A bounded diff-shaped slice for a code comment: target rows keep their "
                        + "marker, additions and removals keep theirs, and a large source never "
                        + "turns into a large sheet.",
                    makeCodeContextPreviewSample()
                ),
                story(
                    "ThemedOutlineView",
                    "Expand, collapse, select, and scroll a hierarchy — selected rows themed by "
                        + "the same row view the table above uses.",
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
                        + "own opaque surface under a style — plus whatever gradient or image "
                        + "the style's sidebar block states. Switch the theme above to watch it "
                        + "trade one for the other.",
                    makeSidebarBackdropSample()
                ),
                story(
                    "ThreadingMarkView",
                    "The Threading mark drawn live: brand threads under System, the theme's "
                        + "accent under a style. Rest, then Weave, Breathe and Orbit from left "
                        + "to right; Preview holds Weave through its box turn, while Replay "
                        + "shows the launch stitch.",
                    makeThreadingMarkSample()
                ),
                story(
                    "SidebarBrandView",
                    "The sidebar's brand row: the mark beside the app's name — or the logo, "
                        + "wordmark and face the current chrome's sidebar brand states instead.",
                    makeSidebarBrandSample()
                ),
                story(
                    "PaneFooterView",
                    "The bottom band of a pane: hairline, band height, and controls whose ink "
                        + "sits on the stated margin — corner-adapted when the band meets a "
                        + "rounded window corner.",
                    makePaneFooterSample()
                ),
                story(
                    "PaneHeaderView",
                    "The footer's mirror at the top of a pane: the same band height, the same "
                        + "align-by-ink margin, hairline below instead of above. Shown over a "
                        + "footer so the two bands can be checked against each other — the "
                        + "height is one measure, and a pane wearing both should read as a "
                        + "matched pair.",
                    makePaneHeaderSample()
                ),
                story(
                    "PaneNoticeView",
                    "The pane's third band: a standing condition it found on its own, with the "
                        + "ways to answer it and the way out on the same line. Press Show to put "
                        + "one up — the content below moves down by the band's height rather "
                        + "than disappearing under it. Restore and ✕ both take it away; a notice "
                        + "waits as long as it takes to be read, since nobody clicked for it.",
                    makePaneNoticeSample()
                ),
                story(
                    "ToastView",
                    "A receipt for something already done, with the way back on it. Press Show "
                        + "to send one into the pane below: it slides in above the footer, holds "
                        + "while the pointer is on it, and leaves by itself otherwise. Press it "
                        + "again before that one leaves and the second waits its turn behind the "
                        + "first, as a card edge above it. Agent sends the same receipt for an "
                        + "archive nobody clicked — it names who did it, carries their reason, "
                        + "and holds more than twice as long.",
                    makeToastSample()
                )
            ]
        )
    }

    private func makeAgentWorkSummarySample() -> NSView {
        let now = Date()
        let files = (0..<2_400).map { index in
            "Sources/Feature\(index / 120)/Area\(index / 24)/file-\(index).swift"
        }
        let atlas = RepositoryFileAtlas(files: files)
        let firstID = SessionID()
        let secondID = SessionID()
        var first = AgentSessionWorkTrace()
        first.sessionTitle = L10n.string("Refactor sidebar")
        first.agentLabel = "Codex"
        var second = AgentSessionWorkTrace()
        second.sessionTitle = L10n.string("Harden tests")
        second.agentLabel = "Claude"

        for index in stride(from: 90, through: 1_080, by: 19) {
            _ = first.recordFile(
                .read,
                path: files[index],
                root: nil,
                at: now.addingTimeInterval(-TimeInterval(index % 70))
            )
            if index.isMultiple(of: 3) {
                _ = first.recordFile(
                    .edit,
                    path: files[index],
                    root: nil,
                    at: now.addingTimeInterval(-TimeInterval(index % 35))
                )
            }
        }
        for index in stride(from: 720, through: 1_900, by: 29) {
            _ = second.recordFile(
                .edit,
                path: files[index],
                root: nil,
                at: now.addingTimeInterval(-TimeInterval(index % 60))
            )
        }
        for index in 0..<12 {
            first.recordAction(
                category: index.isMultiple(of: 3) ? .shell : .filesystem,
                operation: index.isMultiple(of: 3) ? "exec" : "Read",
                at: now.addingTimeInterval(-TimeInterval(index * 3)),
                sessionID: firstID
            )
            second.recordAction(
                category: index.isMultiple(of: 4) ? .subagent : .network,
                operation: index.isMultiple(of: 4) ? "Agent" : "WebSearch",
                at: now.addingTimeInterval(-TimeInterval(index * 4 + 1)),
                sessionID: secondID
            )
        }

        let traces = [firstID: first, secondID: second]
        let presentation = AgentWorkPresentation.project(
            AgentProjectWorkAggregate(traces: traces),
            traces: traces,
            projectID: ProjectID(),
            atlas: atlas,
            detailed: true
        )
        let summary = AgentWorkSummaryView()
        summary.setClock { now }
        summary.setPresentation(presentation)
        return summary
    }

    private func makeAgentActivityBeamSample() -> NSView {
        let surface = ThemedSurfaceView()
        surface.translatesAutoresizingMaskIntoConstraints = false
        surface.applySurface(
            fill: Design.Surface.panel,
            radius: .panel,
            border: Design.Surface.border
        )
        surface.widthAnchor.constraint(equalToConstant: 320).isActive = true
        surface.heightAnchor.constraint(equalToConstant: 72).isActive = true

        let label = NSTextField(labelWithString: L10n.string("Three agents are working"))
        label.applyFont(.emphasizedBody)
        label.textColor = Design.Text.label
        label.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(label)
        surface.addSubview(galleryActivityBeam)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: surface.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: surface.centerYAnchor),
            galleryActivityBeam.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            galleryActivityBeam.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            galleryActivityBeam.topAnchor.constraint(equalTo: surface.topAnchor),
            galleryActivityBeam.bottomAnchor.constraint(equalTo: surface.bottomAnchor)
        ])
        galleryActivityBeam.update(
            workload: AgentWorkload(workingCount: 3, anyAtTopEffort: true)
        )
        let cycle = button("Cycle workload", action: #selector(cycleActivityBeam))
        return row([surface, cycle])
    }

    private func makeCodeContextPreviewSample() -> NSView {
        let lines = [
            "func render(_ project: Project) {",
            "    let agents = project.activeAgents",
            "    sidebar.show(work: agents)",
            "    sidebar.refreshSelection()",
            "    metrics.record(agents.count)",
            "}"
        ]
        let preview = CodeContextPreview.make(
            totalLineCount: lines.count,
            target: 2...3
        ) { index in
            let change: CodeContextPreview.Change = index == 2
                ? .added
                : (index == 4 ? .removed : .context)
            return CodeContextPreview.SourceLine(
                number: index + 1,
                change: change,
                text: lines[index]
            )
        }!
        let view = CodeContextPreviewView(preview: preview)
        view.widthAnchor.constraint(equalToConstant: 560).isActive = true
        return view
    }

    /// The toast in the pane it is used in rather than on its own, because both things this
    /// component has to get right are relationships: whether a card floating over a column still
    /// reads as floating, and whether it clears the footer band under it. Driven rather than
    /// looked at — the dwell and the pointer hold are the component, and a still picture of a
    /// band says nothing about either.
    private func makeToastSample() -> NSView {
        let pane = ThemedSurfaceView()
        pane.applySurface(fill: Design.Surface.background, radius: .control)
        pane.translatesAutoresizingMaskIntoConstraints = false

        let footer = PaneFooterView()
        pane.addSubview(footer)

        NSLayoutConstraint.activate([
            pane.widthAnchor.constraint(equalToConstant: SidebarDefaults.defaultWidth),
            pane.heightAnchor.constraint(equalToConstant: 170),
            footer.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: pane.bottomAnchor)
        ])

        toastPresenter = ToastPresenter(host: pane, above: footer.topAnchor)

        let show = ThemedButton()
        show.title = L10n.string("Show")
        show.applyFont(.controlRegular)
        show.target = self
        show.action = #selector(showGalleryToast(_:))

        // The second receipt is here because it is the one the eye has to find unprompted: it
        // arrives with no click behind it, so its attribution and its longer clock are the whole
        // difference, and both are only visible beside the band they differ from.
        let showAgent = ThemedButton()
        showAgent.title = L10n.string("Agent")
        showAgent.applyFont(.controlRegular)
        showAgent.target = self
        showAgent.action = #selector(showGalleryAgentToast(_:))

        let buttons = NSStackView(views: [show, showAgent])
        buttons.orientation = .vertical
        buttons.alignment = .leading
        buttons.spacing = Design.Spacing.small

        let row = NSStackView(views: [pane, buttons])
        row.orientation = .horizontal
        row.alignment = .bottom
        row.spacing = Design.Spacing.inset
        return row
    }

    /// The archive receipt as the app actually builds it, rather than a second copy of its
    /// wording that could drift from the one that ships.
    @objc private func showGalleryToast(_ sender: NSButton) {
        toastPresenter?.present(
            SessionCoordinator.archiveToast(
                for: Self.gallerySession,
                wasRunning: true
            ) { [weak self] in
                self?.showReceipt(L10n.string("Undo"))
            }
        )
    }

    /// The same archive, performed by the agent whose session it is.
    @objc private func showGalleryAgentToast(_ sender: NSButton) {
        toastPresenter?.present(
            SessionCoordinator.agentArchiveToast(
                for: Self.gallerySession,
                reason: "committed and pushed the parser fix",
                wasRunning: true
            ) { [weak self] in
                self?.showReceipt(L10n.string("Undo"))
            }
        )
    }

    private static var gallerySession: AgentSession {
        AgentSession(kind: .claude, title: "Refactor the parser")
    }

    /// A before and an after of the same little scene, drawn here so the story needs no asset
    /// files: the circle moves and changes colour, which gives every mode something to show.
    private func makeImageCompareSample() -> NSView {
        func scene(circle: NSColor, at x: CGFloat) -> NSImage {
            let size = NSSize(width: 260, height: 150)
            let image = NSImage(size: size)
            image.lockFocus()
            Design.Surface.background.setFill()
            NSRect(origin: .zero, size: size).fill()
            Design.Text.tertiary.setFill()
            NSRect(x: 16, y: 118, width: 160, height: 10).fill()
            NSRect(x: 16, y: 98, width: 120, height: 8).fill()
            circle.setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: 20, width: 60, height: 60)).fill()
            image.unlockFocus()
            return image
        }

        let compare = ImageCompareView(frame: .zero)
        compare.translatesAutoresizingMaskIntoConstraints = false
        compare.configure(
            old: .init(image: scene(circle: Design.Status.negative, at: 40), title: "before.png"),
            new: .init(image: scene(circle: Design.Surface.accent, at: 120), title: "after.png")
        )
        compare.onModeChange = { [weak self] mode in
            self?.showReceipt(
                L10n.format("Compare mode: %@.", ImageCompareView.name(for: mode))
            )
        }
        NSLayoutConstraint.activate([
            compare.widthAnchor.constraint(equalToConstant: 520),
            compare.heightAnchor.constraint(
                equalToConstant: compare.preferredHeight(forWidth: 520)
            )
        ])
        return compare
    }

    /// Two of them side by side at one height: a picture wider than its box and one far
    /// smaller. The pair is the story — the wide one fills the width, the small one keeps its
    /// own size and centres, and neither makes the row any wider than it was given.
    private func makeImagePreviewSample() -> NSView {
        func plate(_ size: NSSize, tint: NSColor) -> NSImage {
            let image = NSImage(size: size)
            image.lockFocus()
            tint.setFill()
            NSRect(origin: .zero, size: size).fill()
            Design.Surface.background.setFill()
            NSRect(x: size.width / 4, y: size.height / 4,
                   width: size.width / 2, height: size.height / 2).fill()
            image.unlockFocus()
            return image
        }

        let wide = ThemedImagePreview()
        wide.image = plate(NSSize(width: 900, height: 400), tint: Design.Surface.accent)
        // The inspector begins from the exact in-memory pixels above; this stable, existing URL
        // supplies only the file identity/actions that a production image gets from its asset.
        wide.fileURL = Bundle.main.bundleURL

        let small = ThemedImagePreview()
        small.image = plate(NSSize(width: 48, height: 48), tint: Design.Status.positive)

        let row = NSStackView(views: [wide, small])
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = Design.Spacing.medium
        row.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalToConstant: 520),
            row.heightAnchor.constraint(equalToConstant: 160)
        ])
        return row
    }

    /// A path-only corpus covering every semantic class. The names are fixture data rather than
    /// prose: switching between System and an authored theme above is the interaction under test.
    private func makeFileIconSample() -> NSView {
        let fixtures: [(name: String, isDirectory: Bool)] = [
            ("Sources", true),
            ("Parser.swift", false),
            ("README.md", false),
            ("theme.json", false),
            ("preview.png", false),
            ("voice.mp3", false),
            ("demo.mov", false),
            ("release.zip", false),
            ("Threading.xcodeproj", false),
            ("build.sh", false),
            ("NOTICE", false)
        ]

        let samples = fixtures.map { fixture -> NSView in
            let url = URL(fileURLWithPath: "/component-gallery/\(fixture.name)")
            let icon = ThemedFileIconView(url: url, isDirectory: fixture.isDirectory)
            let label = smallLabel(fixture.name)
            let sample = NSStackView(views: [icon, label])
            sample.orientation = .vertical
            sample.alignment = .centerX
            sample.spacing = Design.Spacing.hairline
            return sample
        }
        return row(samples)
    }

    private func makeSubagentSummarySample() -> NSView {
        let summary = SubagentSummaryView()
        summary.update(
            items: [
                SubagentSummaryItem(
                    id: "cargo-ffi",
                    title: "Cargo enrollment ffi",
                    subtitle: "Audit the retained-parent capacity regressions.",
                    state: .working,
                    statusDetail: "Read · 1m 42s · 14 tools · 24.2K tokens",
                    detailLines: [
                        "Started",
                        "Edited rust_target_pipeline.rs",
                        "Running the remaining native Cargo fixtures"
                    ]
                ),
                SubagentSummaryItem(
                    id: "unicode",
                    title: "Unicode audit",
                    subtitle: "Check format controls and display-byte behavior.",
                    state: .completed,
                    statusDetail: "28s · 6 tools · 8.1K tokens",
                    detailLines: ["Found and corrected two format-control comparisons."]
                )
            ],
            workingCount: 1,
            doneCount: 1
        )
        summary.setSelection("cargo-ffi")
        summary.onSelect = { [weak self] threadID in
            self?.showReceipt(
                threadID.map { "Selected subagent \($0)." } ?? "Collapsed subagent activity."
            )
        }
        summary.widthAnchor.constraint(equalToConstant: 520).isActive = true
        return summary
    }

    /// The header at sidebar width, above the footer it mirrors: a titled action at the leading
    /// margin, an icon-only twin at the trailing one. Paired deliberately — the bug the shared
    /// component exists to prevent is the two bands disagreeing about height or margin, and that
    /// is only visible when they are seen together.
    private func makePaneHeaderSample() -> NSView {
        let title = ThemedButton()
        title.title = L10n.string("Projects")
        title.isBordered = false
        title.applyFont(.controlRegular)
        title.target = self
        title.action = #selector(buttonPressed(_:))

        let arrange = ThemedButton()
        arrange.image = NSImage(
            systemSymbolName: "line.3.horizontal.decrease",
            accessibilityDescription: L10n.string("Arrange")
        )?.withSymbolConfiguration(Design.Symbol.configuration(Design.Symbol.control))
        arrange.isBordered = false
        arrange.toolTip = L10n.string("Arrange")
        arrange.target = self
        arrange.action = #selector(buttonPressed(_:))

        let header = PaneHeaderView(leading: [title], trailing: [arrange])

        let pane = ThemedSurfaceView()
        pane.applySurface(fill: Design.Surface.background, radius: .control)
        pane.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(header)

        NSLayoutConstraint.activate([
            pane.widthAnchor.constraint(equalToConstant: SidebarDefaults.defaultWidth),
            pane.heightAnchor.constraint(equalToConstant: PaneHeaderView.bandHeight * 2),
            header.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            header.topAnchor.constraint(equalTo: pane.topAnchor)
        ])

        return pane
    }

    /// The notice in the position it ships in rather than on its own, because the thing it has to
    /// get right is a relationship: it is stacked between a pane's header and the pane's content,
    /// and it **pushes** that content down instead of covering it. Driven rather than looked at —
    /// a still picture of a band cannot say whether what was underneath moved.
    private func makePaneNoticeSample() -> NSView {
        let title = NSTextField(labelWithString: L10n.string("Session"))
        title.applyFont(.control)
        let header = PaneHeaderView(leading: [title])

        let content = NSTextField(labelWithString: L10n.string("The pane's content."))
        content.applyFont(.control)
        content.translatesAutoresizingMaskIntoConstraints = false

        let pane = ThemedSurfaceView()
        pane.applySurface(fill: Design.Surface.background, radius: .control)
        pane.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(header)
        pane.addSubview(content)

        NSLayoutConstraint.activate([
            pane.widthAnchor.constraint(equalToConstant: GalleryNotice.paneWidth),
            pane.heightAnchor.constraint(equalToConstant: GalleryNotice.paneHeight),
            header.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            header.topAnchor.constraint(equalTo: pane.topAnchor),
            content.leadingAnchor.constraint(
                equalTo: pane.leadingAnchor,
                constant: Design.Spacing.medium
            )
        ])

        paneNoticeHost = pane
        paneNoticeHeaderBottom = header.bottomAnchor
        paneNoticeContent = content
        pinPaneNoticeContent(to: header.bottomAnchor)

        let show = ThemedButton()
        show.title = L10n.string("Show")
        show.applyFont(.controlRegular)
        show.target = self
        show.action = #selector(showGalleryNotice(_:))

        let row = NSStackView(views: [pane, show])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = Design.Spacing.inset
        return row
    }

    /// The band the launch after a crash puts up, built with the copy that ships rather than a
    /// second version of it that could drift.
    @objc private func showGalleryNotice(_ sender: NSControl) {
        guard let host = paneNoticeHost, let anchor = paneNoticeHeaderBottom else { return }
        dismissGalleryNotice()

        let notice = PaneNoticeView(
            tone: .attention,
            message: L10n.string(
                "Threading quit unexpectedly last time. Its open session and browser windows were not reopened."
            ),
            actions: [
                PaneNoticeAction(title: L10n.string("Restore")) { [weak self] in
                    self?.dismissGalleryNotice()
                },
                PaneNoticeAction(title: L10n.string("Show Crash Report"), emphasis: .tertiary) {
                    [weak self] in self?.showReceipt(L10n.string("Show Crash Report"))
                }
            ],
            onDismiss: { [weak self] in self?.dismissGalleryNotice() }
        )

        host.addSubview(notice)
        NSLayoutConstraint.activate([
            notice.topAnchor.constraint(equalTo: anchor),
            notice.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            notice.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
        galleryNotice = notice
        pinPaneNoticeContent(to: notice.bottomAnchor)
    }

    private func dismissGalleryNotice() {
        guard let galleryNotice, let anchor = paneNoticeHeaderBottom else { return }
        galleryNotice.removeFromSuperview()
        self.galleryNotice = nil
        pinPaneNoticeContent(to: anchor)
    }

    /// The pane's content hangs off whichever band is currently its top edge, which is the whole
    /// of "pushes rather than covers" — the same single re-pinned constraint the real pane uses.
    private func pinPaneNoticeContent(to anchor: NSLayoutYAxisAnchor) {
        guard let paneNoticeContent else { return }
        paneNoticeContentTop?.isActive = false
        let constraint = paneNoticeContent.topAnchor.constraint(
            equalTo: anchor,
            constant: Design.Spacing.medium
        )
        constraint.isActive = true
        paneNoticeContentTop = constraint
    }

    /// The sidebar's own ground, at gallery scale — and beside it the plain view it replaced, so
    /// the appearance toggle above shows the difference rather than describing it.
    /// The sidebar footer's shape at the sidebar's width: the titled Settings button alone at
    /// the leading margin, its ink landing on the stated inset.
    private func makePaneFooterSample() -> NSView {
        let gear = ThemedButton()
        gear.title = L10n.string("Settings")
        gear.image = NSImage(
            systemSymbolName: "gearshape",
            accessibilityDescription: L10n.string("Settings")
        )?
            .withSymbolConfiguration(Design.Symbol.configuration(Design.Symbol.control))
        gear.isBordered = false
        gear.applyFont(.controlRegular)
        gear.target = self
        gear.action = #selector(buttonPressed(_:))

        let footer = PaneFooterView(leading: [gear])

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

    /// The mark at rest and in all three particle treatments. They are deliberately shown at
    /// inspection size here; the real sidebar exercises Weave at 24pt.
    private func makeThreadingMarkSample() -> NSView {
        let small = ThreadingMarkView()
        let particleMarks = ThreadingMarkParticleMotion.allCases.map {
            ThreadingMarkView(particleMotion: $0)
        }

        var constraints = [
            small.widthAnchor.constraint(equalToConstant: 20),
            small.heightAnchor.constraint(equalToConstant: 20)
        ]
        for mark in particleMarks {
            constraints += [
                mark.widthAnchor.constraint(equalToConstant: 44),
                mark.heightAnchor.constraint(equalToConstant: 44)
            ]
            mark.setParticlePresentation(phase: 0.34)
        }
        NSLayoutConstraint.activate(constraints)

        let replay = ThemedButton()
        replay.title = L10n.string("Replay")
        replay.isBordered = false
        replay.applyFont(.controlRegular)
        replay.target = self
        replay.action = #selector(replayMarkDrawIn(_:))

        let preview = ThemedButton()
        preview.title = L10n.string("Preview")
        preview.isBordered = false
        preview.applyFont(.controlRegular)
        preview.target = self
        preview.action = #selector(previewMarkParticles(_:))

        markSamples = [small] + particleMarks
        particleMarkSamples = particleMarks

        let row = NSStackView(views: [small] + particleMarks + [preview, replay])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Design.Spacing.medium
        return row
    }

    @objc private func replayMarkDrawIn(_ sender: Any?) {
        particleMarkSamples.forEach { $0.setParticlePresentation(phase: nil) }
        markSamples.forEach { $0.playDrawIn() }
        showReceipt(L10n.string("Mark draw-in replayed."))
    }

    @objc private func previewMarkParticles(_ sender: Any?) {
        particleMarkSamples.forEach {
            $0.setParticlePresentation(phase: nil)
            $0.setHovered(true)
        }
        DispatchQueue.main.asyncAfter(
            deadline: .now()
                + Design.Motion.brandParticleHoverHold
                + Design.Motion.brandParticleBoxTurnCycle
        ) { [weak self] in
            self?.particleMarkSamples.forEach { $0.setHovered(false) }
        }
        showReceipt(L10n.string("Particle marks previewed."))
    }

    private func makeSidebarBrandSample() -> NSView {
        let brand = SidebarBrandView()

        let pane = ThemedSurfaceView()
        pane.applySurface(fill: Design.Surface.background, radius: .control)
        pane.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(brand)

        NSLayoutConstraint.activate([
            pane.widthAnchor.constraint(equalToConstant: SidebarDefaults.defaultWidth),
            pane.heightAnchor.constraint(equalToConstant: PaneHeaderView.bandHeight),
            brand.leadingAnchor.constraint(
                equalTo: pane.leadingAnchor,
                constant: Design.Spacing.inset
            ),
            brand.centerYAnchor.constraint(equalTo: pane.centerYAnchor)
        ])

        return pane
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
        // localization-ignore: This is the literal design-token API being demonstrated.
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

    /// The three components that dress a live web view.
    ///
    /// They are the hardest ones in the vocabulary to review in place: each appears only over a
    /// real page, two of them fold their own controls away below a width threshold, and the
    /// third declines hit testing entirely unless it has been switched on. A story is the only
    /// place all of that can be driven without a browser — which is the argument the catalogue
    /// test makes for every component, and why it went red the moment these landed.
    private func makeBrowserChromeSection() -> NSView {
        let findBar = BrowserFindBar()
        // The app's own name, which is a plausible query, the same word in every language, and
        // read from the bundle rather than written down — see `AppInfo`.
        findBar.queryField.stringValue = AppInfo.name
        findBar.setMatchFound(true)
        findBar.onFind = { [weak self] query, backwards in
            self?.showReceipt(L10n.format(
                backwards ? "BrowserFindBar searched back for “%@”."
                    : "BrowserFindBar searched for “%@”.",
                query
            ))
        }
        findBar.onDismiss = { [weak self] in
            self?.showReceipt(L10n.string("BrowserFindBar asked to close."))
        }

        let deviceToolbar = BrowserDeviceToolbar()
        deviceToolbar.setViewport(
            CGSize(width: 390, height: 844),
            preset: BrowserViewportPreset.catalog.last
        )
        deviceToolbar.onChoosePreset = { [weak self] preset in
            self?.showReceipt(L10n.format(
                "BrowserDeviceToolbar chose %@.",
                preset?.title ?? L10n.string("Responsive")
            ))
        }
        deviceToolbar.onApplyCustomSize = { [weak self] width, height in
            self?.showReceipt(L10n.format(
                "BrowserDeviceToolbar applied %lld×%lld.",
                Int64(width),
                Int64(height)
            ))
            return true
        }
        deviceToolbar.onRotate = { [weak self] in
            self?.showReceipt(L10n.string("BrowserDeviceToolbar rotated the viewport."))
        }
        deviceToolbar.onDismiss = { [weak self] in
            self?.showReceipt(L10n.string("BrowserDeviceToolbar asked to hide."))
        }

        // Switched on, because an overlay in its resting state is a component that deliberately
        // draws and answers nothing — a blank card would be an accurate and useless story.
        let overlay = BrowserAnnotationOverlay()
        overlay.isAnnotating = true
        overlay.markers = [
            BrowserAnnotationMarker(id: 1, point: CGPoint(x: 54, y: 34)),
            BrowserAnnotationMarker(id: 2, point: CGPoint(x: 168, y: 66))
        ]
        // A stand-in for what the live browser reports under the pointer. Deliberately not
        // localized: at runtime this text is the *page's* own, and no page is translated by us.
        overlay.hoveredTarget = BrowserAnnotationTarget(
            rect: CGRect(x: 232, y: 24, width: 190, height: 56),
            label: "button \u{201C}Sign in\u{201D}"
        )
        overlay.onAdd = { [weak self] point in
            guard let self else { return }
            let next = (overlay.markers.map(\.id).max() ?? 0) + 1
            overlay.markers.append(BrowserAnnotationMarker(id: next, point: point))
            self.showReceipt(L10n.format("BrowserAnnotationOverlay placed pin %lld.", Int64(next)))
        }
        overlay.onSelect = { [weak self] id in
            self?.showReceipt(L10n.format("BrowserAnnotationOverlay selected pin %lld.", Int64(id)))
        }
        overlay.onDismiss = { [weak self] in
            self?.showReceipt(L10n.string("BrowserAnnotationOverlay left annotation mode."))
        }
        overlay.applySurface(
            fill: Design.Surface.ground,
            radius: .control,
            border: Design.Surface.border
        )

        // The baseline overlay's story needs something under it to be a story at all: the whole
        // point of the component is that the surface beneath stays reachable, so the card puts a
        // real button behind it and the receipt says which of the two took the click.
        let underlying = ThemedButton(
            title: L10n.string("A control on the page beneath"),
            target: self,
            action: #selector(baselineOverlayPassThroughClicked)
        )
        underlying.translatesAutoresizingMaskIntoConstraints = false

        let baselineOverlay = BrowserBaselineOverlay()
        baselineOverlay.translatesAutoresizingMaskIntoConstraints = false
        baselineOverlay.content = BrowserBaselineOverlayContent(
            image: Self.baselineOverlaySample(),
            name: "Signed-in dashboard",
            captureKind: .viewport,
            capturedScroll: .zero,
            captureSize: CGSize(width: 460, height: 120)
        )
        baselineOverlay.onDismiss = { [weak self] in
            self?.showReceipt(L10n.string("BrowserBaselineOverlay stopped holding its baseline."))
        }

        let baselineCard = NSView()
        baselineCard.translatesAutoresizingMaskIntoConstraints = false
        baselineCard.addSubview(underlying)
        baselineCard.addSubview(baselineOverlay)

        for bar in [findBar, deviceToolbar] as [NSView] {
            bar.widthAnchor.constraint(equalToConstant: 460).isActive = true
        }
        NSLayoutConstraint.activate([
            overlay.widthAnchor.constraint(equalToConstant: 460),
            overlay.heightAnchor.constraint(equalToConstant: 120),
            baselineCard.widthAnchor.constraint(equalToConstant: 460),
            baselineCard.heightAnchor.constraint(equalToConstant: 120),
            underlying.centerXAnchor.constraint(equalTo: baselineCard.centerXAnchor),
            underlying.centerYAnchor.constraint(equalTo: baselineCard.centerYAnchor),
            baselineOverlay.topAnchor.constraint(equalTo: baselineCard.topAnchor),
            baselineOverlay.bottomAnchor.constraint(equalTo: baselineCard.bottomAnchor),
            baselineOverlay.leadingAnchor.constraint(equalTo: baselineCard.leadingAnchor),
            baselineOverlay.trailingAnchor.constraint(equalTo: baselineCard.trailingAnchor)
        ])

        return section(
            "Browser chrome",
            note: "The bars fold their labels below their own width thresholds; drag the gallery narrower to see it.",
            rows: [
                story(
                    "BrowserFindBar",
                    "Find in page, with the match count folded away when the bar is narrow.",
                    findBar
                ),
                story(
                    "BrowserDeviceToolbar",
                    "CSS viewport presets and a custom size; no touch or device emulation.",
                    deviceToolbar
                ),
                story(
                    "BrowserAnnotationOverlay",
                    "The agent-visible pin layer, shown in annotation mode — click the panel to place one.",
                    overlay
                ),
                story(
                    "BrowserBaselineOverlay",
                    "An approved picture held over a live page. Drag the handle; click anywhere else and the button underneath answers.",
                    baselineCard
                )
            ]
        )
    }

    @objc private func baselineOverlayPassThroughClicked() {
        showReceipt(L10n.string("The control under BrowserBaselineOverlay took the click."))
    }

    /// A stand-in capture: two bands, so a seam dragged across it is visibly a seam.
    private static func baselineOverlaySample() -> NSImage {
        NSImage(size: NSSize(width: 460, height: 120), flipped: false) { bounds in
            Design.Surface.panel.setFill()
            bounds.fill()
            Design.Surface.accent.withAlphaComponent(0.35).setFill()
            bounds.insetBy(dx: 24, dy: 24).fill()
            return true
        }
    }

    private func makeColourSection() -> NSView {
        let editable = ThemeSwatchView(size: 34)
        editable.isEditable = true
        editable.setColor(Design.Surface.accent, name: "Accent")
        editable.onChange = { [weak self] colour in
            self?.showReceipt(L10n.format("ThemeSwatchView chose %@.", colour.hexString))
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

        // localization-ignore: These are the literal API type and method being demonstrated.
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
                self?.showReceipt(
                    L10n.format("Extension action “%@” was invoked.", action)
                )
            }
            rendered.setAccessibilityIdentifier("gallery.extension.panel")
        } catch {
            let failure = NSTextField(wrappingLabelWithString: error.localizedDescription)
            failure.applyFont(.body)
            failure.textColor = Design.Status.negative
            rendered = failure
        }

        extensionLoadButton.title = L10n.string("Load Extension Directory…")
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

        let semanticScene = makeSemanticSceneStory()
        var rows = [
            story(
                "SemanticSceneView",
                "Normalized, interactive marks for treemaps, heatmaps, timelines, scatter plots, and bubbles.",
                semanticScene
            ),
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

    private func makeSemanticSceneStory() -> NSView {
        let activate: (String) -> Void = { [weak self] itemID in
            self?.showReceipt(
                L10n.format("Extension action “%@” was invoked.", itemID)
            )
        }
        let scene = SemanticSceneView(
            accessibilityLabel: L10n.string("Installed-size map for iOS 26.5"),
            items: [
                .init(
                    id: "system-library",
                    normalizedFrame: NSRect(x: 0, y: 0, width: 0.62, height: 1),
                    shape: .roundedRectangle,
                    color: .category(0),
                    label: L10n.string("System Library"),
                    detail: L10n.string("4.82 GB · +114 MB"),
                    accessibilityLabel: L10n.string("System Library"),
                    accessibilityValue: L10n.string("4.82 GB · +114 MB"),
                    isEnabled: true,
                    isSelected: true,
                    onActivate: { activate("system-library") }
                ),
                .init(
                    id: "dyld-cache",
                    normalizedFrame: NSRect(x: 0.62, y: 0, width: 0.38, height: 0.58),
                    shape: .roundedRectangle,
                    color: .category(1),
                    label: L10n.string("dyld cache"),
                    detail: L10n.string("2.31 GB · +92 MB"),
                    accessibilityLabel: L10n.string("dyld cache"),
                    accessibilityValue: L10n.string("2.31 GB · +92 MB"),
                    isEnabled: true,
                    isSelected: false,
                    onActivate: { activate("dyld-cache") }
                ),
                .init(
                    id: "frameworks",
                    normalizedFrame: NSRect(x: 0.62, y: 0.58, width: 0.38, height: 0.42),
                    shape: .roundedRectangle,
                    color: .category(2),
                    label: L10n.string("Frameworks"),
                    detail: L10n.string("1.18 GB"),
                    accessibilityLabel: L10n.string("Frameworks"),
                    accessibilityValue: L10n.string("1.18 GB"),
                    isEnabled: true,
                    isSelected: false,
                    onActivate: { activate("frameworks") }
                )
            ]
        )
        NSLayoutConstraint.activate([
            scene.widthAnchor.constraint(equalToConstant: 420),
            scene.heightAnchor.constraint(equalToConstant: 210)
        ])
        return scene
    }

    // MARK: Actions

    @objc private func themeChanged() {
        let index = themePopUp.indexOfSelectedItem
        guard let theme = AppThemeLibrary.stock[safe: index] else { return }
        setTheme(theme)
        showReceipt(L10n.format("Applied the %@ theme app-wide.", theme.name))
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
        showReceipt(
            L10n.format("Gallery appearance is %@.", appearanceMode.localizedName)
        )
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
        let name = button?.accessibilityTitle() ?? L10n.string("Button")
        showReceipt(L10n.format("%@ pressed · %lld total.", name, Int64(clickCount)))
    }

    @objc private func cycleActivityBeam() {
        activityBeamDemoCursor = (activityBeamDemoCursor + 1) % 3
        let workload: AgentWorkload
        let sentence: String
        switch activityBeamDemoCursor {
        case 0:
            workload = .none
            sentence = L10n.string("Activity beam is idle.")
        case 1:
            workload = AgentWorkload(workingCount: 1, anyAtTopEffort: false)
            sentence = L10n.string("Activity beam shows one working agent.")
        default:
            workload = AgentWorkload(workingCount: 3, anyAtTopEffort: true)
            sentence = L10n.string("Activity beam shows three agents, including top effort.")
        }
        galleryActivityBeam.update(workload: workload)
        showReceipt(sentence)
    }

    @objc private func showGalleryAlert(_ sender: ThemedButton) {
        let alert = ThemedAlert()
        alert.messageText = L10n.string("Presentation chrome")
        alert.informativeText = L10n.string(
            "This alert follows the app theme and always gives Escape back to its source."
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.string("Continue"))
        alert.addButton(withTitle: L10n.string("Cancel"))
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    @objc private func showGalleryPopover(_ sender: ThemedButton) {
        if galleryPopover?.isShown == true {
            galleryPopover?.close()
            return
        }

        let title = NSTextField(labelWithString: L10n.string("Popover"))
        title.applyFont(.heading)
        title.textColor = Design.Text.label
        let message = NSTextField(
            wrappingLabelWithString: L10n.string(
                "This anchored surface flips at screen edges and follows live theme changes."
            )
        )
        message.applyFont(.body)
        message.textColor = Design.Text.secondary
        message.preferredMaxLayoutWidth = 260
        let close = button("Close", action: #selector(closeGalleryPopover(_:)))

        let stack = NSStackView(views: [title, message, close])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.medium
        stack.edgeInsets = NSEdgeInsets(
            top: Design.Spacing.inset,
            left: Design.Spacing.inset,
            bottom: Design.Spacing.inset,
            right: Design.Spacing.inset
        )
        stack.frame = NSRect(x: 0, y: 0, width: 292, height: 126)

        let controller = NSViewController()
        controller.view = stack
        controller.preferredContentSize = stack.frame.size

        let popover = ThemedPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.onClose = { [weak self, weak popover] in
            guard self?.galleryPopover === popover else { return }
            self?.galleryPopover = nil
        }
        galleryPopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    @objc private func closeGalleryPopover(_ sender: ThemedButton) {
        galleryPopover?.close()
    }

    @objc private func showGalleryCompletions(_ sender: ThemedButton) {
        if galleryCompletionPresenter.isVisible {
            galleryCompletionPresenter.dismiss()
            return
        }
        let items = [
            ComposerCapability(
                id: "gallery.command:compact",
                name: "compact",
                description: L10n.string("Compact the conversation context"),
                kind: .command,
                trigger: .slash,
                presentation: .command
            ),
            ComposerCapability(
                id: "gallery.skill:release",
                name: "release",
                displayName: L10n.string("Release"),
                description: L10n.string("Browse skills available in this conversation"),
                argumentHint: "[version]",
                kind: .skill,
                trigger: .dollar,
                presentation: .turn
            )
        ]
        galleryCompletionPresenter.present(
            items: items,
            selectedIndex: 0,
            from: sender,
            onChoose: { [weak self] _ in self?.galleryCompletionPresenter.dismiss() },
            onDismiss: {}
        )
    }

    @objc private func chooseExtensionDirectory() {
        let panel = NSOpenPanel()
        panel.title = L10n.string("Load Threading Extension")
        panel.message = L10n.string(
            "Choose a directory containing threading-extension.json."
        )
        panel.prompt = L10n.string("Load Extension")
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
        extensionProcessStatus.stringValue = L10n.format(
            "Inspecting and starting %@…",
            directory.lastPathComponent
        )
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
            showReceipt(L10n.string("Extension failed to start."))

        case .success(let (manifest, started)):
            extensionProcessSession = started.session
            extensionProcessStatus.textColor = Design.Status.positive
            extensionProcessStatus.stringValue = L10n.format(
                "%@ is running · %lld commands, %lld panels.",
                manifest.name,
                Int64(started.registration.commands.count),
                Int64(started.registration.panels.count)
            )

            guard let panel = started.registration.panels.first else {
                let empty = NSTextField(
                    labelWithString: L10n.string(
                        "The extension registered no panels."
                    )
                )
                empty.applyFont(.detail())
                empty.textColor = Design.Text.tertiary
                replaceExtensionProcessPreview(with: empty)
                showReceipt(L10n.format("Loaded extension “%@”.", manifest.name))
                return
            }

            if renderExtensionPanel(
                panel,
                manifest: manifest,
                session: started.session
            ) {
                showReceipt(
                    L10n.format(
                        "Loaded extension “%@” and rendered “%@”.",
                        manifest.name,
                        panel.title
                    )
                )
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
                self.extensionProcessStatus.stringValue = L10n.format(
                    "Running “%@”…",
                    action
                )
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
            showReceipt(L10n.string("Extension panel rendering failed."))
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
            showReceipt(L10n.string("Extension action failed."))

        case .success(let response):
            if let error = response.error {
                extensionProcessStatus.textColor = Design.Status.negative
                extensionProcessStatus.stringValue = error
                showReceipt(L10n.string("Extension declined the action."))
                return
            }

            if let panel = response.panel {
                guard renderExtensionPanel(panel, manifest: manifest, session: session) else {
                    return
                }
            }

            let message = response.message ?? L10n.string("Extension action completed.")
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
        let state = sender.state == .on ? L10n.string("on") : L10n.string("off")
        showReceipt(L10n.format("ThemedToggle is %@.", state))
    }

    @objc private func samplePopUpChanged(_ sender: ThemedPopUp) {
        showReceipt(
            L10n.format(
                "ThemedPopUp selected “%@”.",
                sender.selectedItem?.title ?? L10n.string("Nothing")
            )
        )
    }

    @objc private func textCommitted(_ sender: ThemedTextField) {
        showReceipt(L10n.format("ThemedTextField committed “%@”.", sender.stringValue))
    }

    @objc private func searchCommitted(_ sender: ThemedSearchField) {
        showReceipt(L10n.format("ThemedSearchField searched for “%@”.", sender.stringValue))
    }

    /// Re-marks the highlight story's three lines against whatever is in its field.
    ///
    /// Three roles rather than three copies of one: prose, its quieter second line, and an
    /// identifier in code — the three the app actually highlights, each of which resolves its
    /// own emphasis. The third is deliberately a real session id, because the interesting case
    /// is a query *longer* than the line it is being matched against.
    private func markSampleLines() {
        let query = matchQueryField.stringValue
        for (label, line) in zip(matchSamples, Self.matchSampleLines) {
            label.show(line, matching: query)
        }
    }

    private static var matchSampleLines: [String] {
        [
            L10n.string("Notifications · Mute · Sound"),
            L10n.string("Play a sound when a session needs attention"),
            "9f3c1a20-77b4-4e6d-9c02-5a1e8b3d40ff"
        ]
    }

    private func configureActivityMap() {
        activityMapView.setFiles(Self.activityDemoUniverse())
        // The map sorts its universe; cycling in *its* order keeps each press touching a
        // contiguous directory run, which is the pattern the strip exists to show.
        activityDemoFiles = activityMapView.map.entries.map(\.path)
        activityMapView.setAccessibilityLabel(
            L10n.string("File activity map sample")
        )
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
        showReceipt(
            L10n.format("FileActivityMapView read %@.", touchDemoFiles(count: 12, tool: .read))
        )
    }

    @objc private func demoAgentEdits() {
        showReceipt(
            L10n.format("FileActivityMapView edited %@.", touchDemoFiles(count: 5, tool: .edit))
        )
    }

    /// Touches a contiguous run from the demo cursor through the real classifier, and
    /// answers with the neighbourhood it landed in for the receipt.
    private func touchDemoFiles(count: Int, tool: ToolIdentity) -> String {
        guard !activityDemoFiles.isEmpty else { return L10n.string("nothing") }

        var lastPath = ""
        for _ in 0..<count {
            lastPath = activityDemoFiles[activityDemoCursor % activityDemoFiles.count]
            activityDemoCursor += 1
            activityMapView.recordTouches(tool: tool, input: ["file_path": lastPath])
        }
        let directory = lastPath.split(separator: "/").dropLast().joined(separator: "/")
        return L10n.format(
            "%lld files around %@",
            Int64(count),
            directory.isEmpty ? L10n.string("the repo root") : directory
        )
    }

    @objc private func toggleSpinner(_ sender: ThemedButton) {
        spinner.isAnimating.toggle()
        sender.title = spinner.isAnimating
            ? L10n.string("Stop spinner")
            : L10n.string("Start spinner")
        let state = spinner.isAnimating ? L10n.string("started") : L10n.string("stopped")
        showReceipt(L10n.format("ThemedSpinner %@.", state))
    }

    @objc private func toggleWorkingOrb(_ sender: ThemedButton) {
        let shouldHide = !(workingOrbs.first?.isHidden ?? false)
        workingOrbs.forEach { $0.isHidden = shouldHide }
        sender.title = shouldHide ? L10n.string("Show orbs") : L10n.string("Hide orbs")
        let state = shouldHide
            ? L10n.string("hidden and idling")
            : L10n.string("visible and animating")
        showReceipt(L10n.format("WorkingOrbView variants %@.", state))
    }

    @objc private func previewTitleMorph() {
        let samples = [
            L10n.string("Rename this conversation"),
            L10n.string("Polish the release notes"),
            L10n.string("Trace the session lifecycle")
        ]
        morphDemoCursor = (morphDemoCursor + 1) % samples.count
        morphingTitle.setStringValue(samples[morphDemoCursor], animated: true)
        showReceipt(
            L10n.format(
                "MorphingTitleLabel previewed %@.",
                AppSettings.shared.chatNameMorphStyle.displayName
            )
        )
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
        // localization-ignore: A locale-neutral integer percentage with no language.
        progressLabel.stringValue = "\(Int((progress * 100).rounded()))%"
        showReceipt(L10n.format("ThemedProgressBar is %@.", progressLabel.stringValue))
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

    /// The chrome a takeover theme draws in place of the window frame, previewed through the
    /// components' fixture seam — the styles here are stated, never taken from the active
    /// theme, so the story reads the same whatever the gallery is wearing.
    private func makeWindowChromeSection() -> NSView {
        func style(
            _ glyphs: WindowChromeStyle.TitleBar.ButtonGlyphStyle
        ) -> WindowChromeAppearance.Resolved {
            WindowChromeAppearance.resolved(from: WindowChromeStyle(
                titleBar: .init(
                    activeGradient: .init(stops: [
                        .init(color: NSColor(hex: "#000080")!, position: 0),
                        .init(color: NSColor(hex: "#1084D0")!, position: 1)
                    ], angleDegrees: 90),
                    ink: .white,
                    buttonGlyphStyle: glyphs
                ),
                frame: .init(width: 4)
            ))
        }

        let squares = style(.squares)
        let band = WindowTitleBandView()
        band.fixtureStyle = squares
        band.setTitle(AppInfo.name)
        NSLayoutConstraint.activate([
            band.widthAnchor.constraint(equalToConstant: 420),
            band.heightAnchor.constraint(equalToConstant: squares.bandHeight)
        ])

        // Every stock takeover theme's real band, driven by the model's own list rather
        // than restated by hand — this section had already drifted once (Aqua and Tiger
        // were absent) while it named each theme itself. A new takeover theme appears
        // here by existing.
        let takeoverBands: [NSView] = AppThemeStyles.takeovers.map { theme in
            let chrome = theme.variant(.light)?.chrome
                ?? theme.variants.values.compactMap(\.chrome).first
            precondition(chrome != nil, "a takeover theme must state window chrome")
            let resolved = WindowChromeAppearance.resolved(from: chrome!)
            let themeBand = WindowTitleBandView()
            themeBand.fixtureStyle = resolved
            themeBand.setTitle(Self.chromeStoryTitle(for: theme))
            NSLayoutConstraint.activate([
                themeBand.widthAnchor.constraint(equalToConstant: 420),
                themeBand.heightAnchor.constraint(equalToConstant: resolved.bandHeight)
            ])
            return themeBand
        }

        let plain = style(.plain)
        let plainButtons = NSStackView(views: [
            WindowChromeButton.Role.minimize, .zoom, .close
        ].map { role in
            let button = WindowChromeButton(role: role)
            button.fixtureStyle = plain
            return button
        })
        plainButtons.orientation = .horizontal
        plainButtons.spacing = Design.Spacing.hairline
        let backplate = NSView()
        backplate.translatesAutoresizingMaskIntoConstraints = false
        backplate.applyLayerBackground(NSColor(hex: "#000080")!)
        backplate.addSubview(plainButtons)
        plainButtons.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            plainButtons.centerXAnchor.constraint(equalTo: backplate.centerXAnchor),
            plainButtons.centerYAnchor.constraint(equalTo: backplate.centerYAnchor),
            backplate.widthAnchor.constraint(
                equalTo: plainButtons.widthAnchor,
                constant: Design.Spacing.large
            ),
            backplate.heightAnchor.constraint(equalToConstant: squares.bandHeight)
        ])

        let frame = WindowChromeFrameView()
        frame.fixtureStyle = squares
        frame.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            frame.widthAnchor.constraint(equalToConstant: 220),
            frame.heightAnchor.constraint(equalToConstant: 96)
        ])

        let bandRow = NSStackView(
            views: [band] + takeoverBands + [backplate]
        )
        bandRow.orientation = .vertical
        bandRow.alignment = .leading
        bandRow.spacing = Design.Spacing.small

        let commandBand = WindowCommandBandView()
        commandBand.setLeadingControls([
            ThemedIconButton(
                symbolName: "sidebar.leading",
                accessibility: L10n.string("Show or hide sidebar"),
                inkSource: .chrome
            ),
            ThemedIconButton(
                symbolName: "chevron.left",
                accessibility: L10n.string("Go back"),
                inkSource: .chrome
            )
        ])
        NSLayoutConstraint.activate([
            commandBand.widthAnchor.constraint(equalToConstant: 420),
            commandBand.heightAnchor.constraint(equalToConstant: WindowCommandBandView.bandHeight)
        ])

        return section(
            "Window chrome",
            note: "A takeover theme's frame, drawn by the app. The band drags this very window, and its buttons really close, minimize, and zoom it.",
            rows: [
                story(
                    "WindowTitleBandView & WindowChromeButton",
                    "The title band with square-plate buttons, and the bare-glyph style on its own ground.",
                    bandRow
                ),
                story(
                    "WindowCommandBandView",
                    "Application navigation stays on its own chrome row below the title band.",
                    commandBand
                ),
                story(
                    "WindowChromeFrameView",
                    "The border drawn around a takeover window's edges, seated by the theme's border role.",
                    frame
                )
            ]
        )
    }

    /// Demo titles are presentation, not vocabulary. Workbench titled its windows with disk
    /// gauges, and generalising the band list must not flatten that into the app's name —
    /// the gallery should stay as characterful as the systems it reproduces.
    private static func chromeStoryTitle(for theme: AppTheme) -> String {
        theme.id == AppThemeStyles.amiga.id
            ? "hd02  50% full, 2,047M free, 2,048M in use"
            : AppInfo.name
    }

    private func section(_ title: String, note: String, rows: [NSView]) -> NSView {
        let heading = NSTextField(labelWithString: L10n.string(title))
        heading.applyFont(.heading)
        heading.textColor = Design.Text.label

        let explanation = NSTextField(
            wrappingLabelWithString: L10n.string(note)
        )
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
        let nameLabel = NSTextField(labelWithString: L10n.string(name))
        nameLabel.applyFont(.control)
        nameLabel.textColor = Design.Text.label

        let summaryLabel = NSTextField(
            wrappingLabelWithString: L10n.string(summary)
        )
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
        let label = smallLabel(L10n.string(title).uppercased())
        let stack = NSStackView(views: [label, control])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.hairline
        return stack
    }

    private func labelledInline(_ title: String, _ control: NSView) -> NSView {
        let label = smallLabel(L10n.string(title))
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
        ThemedButton(title: L10n.string(title), target: self, action: action)
    }

    private func column(_ identifier: String, title: String, width: CGFloat) -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.title = L10n.string(title)
        column.width = width
        column.minWidth = 80
        return column
    }
}

// MARK: - NSTextFieldDelegate

extension ComponentGalleryViewController: NSTextFieldDelegate {

    /// The highlight story is the one that has to answer *while* the reader types — its
    /// component draws a query's effect, and a query committed with Return is a query nobody
    /// watched land.
    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSTextField === matchQueryField else { return }
        markSampleLines()
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
        if tableView is ThemedGroupedTableView {
            let identifier = NSUserInterfaceItemIdentifier("GalleryVirtualRow")
            let host = tableView.makeView(
                withIdentifier: identifier,
                owner: self
            ) as? ThemedVirtualTableCell ?? ThemedVirtualTableCell()
            host.identifier = identifier
            host.install(
                groupedContent(for: rows[row]),
                columnWidth: tableColumn.width,
                horizontalInset: Design.Size.glowGutter,
                topInset: row == 0 ? Design.Spacing.small : 0,
                bottomInset: row == rows.count - 1 ? Design.Spacing.small : 0
            )
            return host
        }
        let value = tableColumn.identifier.rawValue == "component"
            ? rows[row].component
            : rows[row].state
        return cell(value)
    }

    private func groupedContent(for row: TableRow) -> NSView {
        let title = NSTextField(labelWithString: row.component)
        title.applyFont(.emphasizedBody)
        title.textColor = Design.Text.label
        let detail = NSTextField(labelWithString: row.state)
        detail.applyFont(.subheading)
        detail.textColor = Design.Text.secondary
        let stack = NSStackView(views: [title, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.tight
        stack.edgeInsets = NSEdgeInsets(
            top: Design.Spacing.small,
            left: Design.Spacing.inset,
            bottom: Design.Spacing.small,
            right: Design.Spacing.inset
        )
        return stack
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

// MARK: - Hover Policy Demo

/// One `HoverPopoverScheduler` policy made hoverable: a labelled anchor that presents a small
/// themed popover under the policy's timing, including the popover-side hold when the policy
/// grants one. The gallery shows the shipped policies rather than invented ones, so what is
/// felt here is what the product does.
@MainActor
private final class GalleryHoverPolicyDemo {

    let anchor: HoverTrackingView

    private let scheduler: HoverPopoverScheduler
    private let message: String
    private var popover: ThemedPopover?

    init(title: String, message: String, policy: HoverPopoverScheduler.Policy) {
        self.message = message
        scheduler = HoverPopoverScheduler(policy: policy)

        let label = NSTextField(labelWithString: title)
        label.applyFont(.subheading)
        label.textColor = Design.Text.secondary
        label.translatesAutoresizingMaskIntoConstraints = false

        anchor = HoverTrackingView()
        anchor.translatesAutoresizingMaskIntoConstraints = false
        anchor.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: anchor.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: anchor.trailingAnchor),
            label.topAnchor.constraint(equalTo: anchor.topAnchor),
            label.bottomAnchor.constraint(equalTo: anchor.bottomAnchor)
        ])

        anchor.onHoverChange = { [weak self] hovering in
            if hovering {
                self?.scheduler.pointerEntered()
            } else {
                self?.scheduler.pointerExited()
            }
        }
        scheduler.onPresent = { [weak self] in self?.present() }
        scheduler.onDismiss = { [weak self] in self?.dismiss() }
    }

    private func present() {
        guard anchor.window != nil, popover?.isShown != true else { return }

        let text = NSTextField(wrappingLabelWithString: message)
        text.applyFont(.subheading)
        text.textColor = Design.Text.secondary
        text.preferredMaxLayoutWidth = 220
        text.translatesAutoresizingMaskIntoConstraints = false

        // The popover's own hover feeds the scheduler, so a policy that holds can be felt.
        let content = HoverTrackingView()
        content.onHoverChange = { [weak self] hovering in
            self?.scheduler.popoverHoverChanged(hovering)
        }
        content.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(
                equalTo: content.leadingAnchor, constant: Design.Spacing.inset
            ),
            text.trailingAnchor.constraint(
                equalTo: content.trailingAnchor, constant: -Design.Spacing.inset
            ),
            text.topAnchor.constraint(equalTo: content.topAnchor, constant: Design.Spacing.inset),
            text.bottomAnchor.constraint(
                equalTo: content.bottomAnchor, constant: -Design.Spacing.inset
            )
        ])

        let controller = NSViewController()
        controller.view = content

        let presented = ThemedPopover()
        presented.behavior = .applicationDefined
        presented.animates = false
        presented.contentViewController = controller
        presented.onClose = { [weak self, weak presented] in
            guard let self, self.popover === presented else { return }
            self.popover = nil
        }
        presented.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        popover = presented
    }

    private func dismiss() {
        scheduler.cancelPendingWork()
        popover?.close()
        popover = nil
    }
}
