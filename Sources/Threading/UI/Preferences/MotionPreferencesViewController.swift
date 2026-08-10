import AppKit

/// Motion preferences with the real components as previews. Effects expose
/// only their meaningful choice; timing and intensity remain app-owned.
///
/// **Every choice is shown in the list it is chosen from**, which is what these two settings
/// need and what a menu of names cannot give: the thing being picked is movement, so a row
/// reading "Bounce" describes it exactly as well as a row reading "Searching" describes an orb —
/// which is to say not at all. Deciding used to mean selecting one, watching it, and selecting
/// the next, with the previous one gone by the time the next arrived; the previews on the page
/// remain for the choice already made, but the comparison happens in the dropdown.
///
/// The two dropdowns differ in *when* they move, and the reason is legibility rather than cost.
/// Ten orb rows run at once because comparing animations means seeing them together. Eleven names
/// morphing at once would be unreadable, so a name transition plays on the highlighted row only.
final class MotionPreferencesViewController: NSViewController {

    /// Named so a test can find the two controls whose dropdowns carry the previews. A
    /// dropdown's rows are only reachable through the control that opens them.
    enum Identifier {
        static let orbStyle = "motion.orbStyle"
        static let nameStyle = "motion.nameStyle"
    }

    private enum Preview {
        /// The second name a transition demonstration morphs to and from.
        ///
        /// A transition acts on a *change*, so a demonstration needs two names — and the app's
        /// own is the one string every install has. Read from the bundle so the product's name
        /// lives in one place; see `AppInfo`.
        static var alternateName: String { AppInfo.name }
    }

    private let orbStylePopUp = ThemedPopUp()
    private let orbPreview = WorkingOrbView()
    private let nameStylePopUp = ThemedPopUp()
    private let namePreview = MorphingTitleLabel()
    private var previewNameIndex = 0

    /// One live preview per choice, made up front and handed to the menu item.
    ///
    /// The row shows the component itself rather than a picture of it, and the same instance is
    /// reused each time the dropdown reopens — the menu rebuilds its rows per open, so a view
    /// made in the row's initializer would restart every animation on every open.
    private var orbRowPreviews: [WorkingOrbStyle: WorkingOrbView] = [:]
    private var nameRowPreviews: [ChatNameMorphStyle: MorphingTitleLabel] = [:]

    /// The row currently demonstrating a transition, and the timer stepping it. One of each,
    /// because one row is highlighted at a time.
    private var demonstrating: ChatNameMorphStyle?
    private let demonstrationTimer = MainRunLoopTimer()

    private let previewNames = [
        "Rename this conversation",
        "Polish the release notes",
        "Trace the session lifecycle"
    ]

    override func loadView() {
        view = NSView()
        setupControls()
        setupLayout()
    }

    private func setupControls() {
        for style in WorkingOrbStyle.allCases {
            orbStylePopUp.addItem(
                ThemedMenuItem(
                    title: style.displayName,
                    preview: orbRowPreview(for: style),
                    representedValue: style
                )
            )
        }
        let orbStyle = AppSettings.shared.workingOrbStyle
        orbStylePopUp.selectItem(
            at: WorkingOrbStyle.allCases.firstIndex(of: orbStyle) ?? 0
        )
        orbStylePopUp.target = self
        orbStylePopUp.action = #selector(orbStyleChanged)
        orbStylePopUp.setAccessibilityIdentifier(Identifier.orbStyle)
        orbStylePopUp.translatesAutoresizingMaskIntoConstraints = false
        orbStylePopUp.widthAnchor.constraint(
            equalToConstant: SettingsUIDefaults.controlWidth
        ).isActive = true
        orbPreview.prepareForWorking(style: orbStyle)

        for style in ChatNameMorphStyle.allCases {
            nameStylePopUp.addItem(
                ThemedMenuItem(
                    title: style.displayName,
                    preview: nameRowPreview(for: style),
                    representedValue: style
                )
            )
        }
        let nameStyle = AppSettings.shared.chatNameMorphStyle
        nameStylePopUp.selectItem(
            at: ChatNameMorphStyle.allCases.firstIndex(of: nameStyle) ?? 0
        )
        nameStylePopUp.target = self
        nameStylePopUp.action = #selector(nameStyleChanged)
        nameStylePopUp.setAccessibilityIdentifier(Identifier.nameStyle)
        nameStylePopUp.translatesAutoresizingMaskIntoConstraints = false
        nameStylePopUp.widthAnchor.constraint(
            equalToConstant: SettingsUIDefaults.controlWidth
        ).isActive = true

        namePreview.applyFont(.emphasizedBody)
        namePreview.morphStyleOverride = nameStyle
        namePreview.setStringValue(previewNames[0], animated: false)
    }

    // MARK: - Row Previews

    private func orbRowPreview(for style: WorkingOrbStyle) -> ThemedMenuPreview {
        let orb = WorkingOrbView()
        orb.prepareForWorking(style: style)
        orbRowPreviews[style] = orb

        // A named orb runs continuously, so its row needs nothing from the highlight. Random has
        // no fixed orb to show at all: what it stands for is the choosing, so its row re-rolls
        // each time the highlight arrives — pointing at it twice shows two different orbs, which
        // is exactly what the setting does per turn.
        guard style == .random else {
            return ThemedMenuPreview(placement: .leading, view: orb)
        }
        return ThemedMenuPreview(
            placement: .leading,
            view: orb,
            highlightChanged: { [weak orb] isHighlighted in
                guard isHighlighted else { return }
                orb?.prepareForWorking(style: .random)
            }
        )
    }

    private func nameRowPreview(for style: ChatNameMorphStyle) -> ThemedMenuPreview {
        let label = MorphingTitleLabel()
        // The row's own title role, so a demonstrating row and a plain one set type alike.
        label.applyFont(.control)
        label.morphStyleOverride = style
        label.setStringValue(style.displayName, animated: false)
        nameRowPreviews[style] = label

        return ThemedMenuPreview(
            placement: .title,
            view: label,
            highlightChanged: { [weak self] isHighlighted in
                self?.setDemonstrating(style, isHighlighted: isHighlighted)
            }
        )
    }

    /// Starts or ends the repeating demonstration on one row.
    ///
    /// A row reporting that its highlight *left* may only end the demonstration it owns. The menu
    /// keeps its rows in a dictionary, so when the pointer moves from one row to the next the two
    /// reports arrive in no defined order, and an unguarded stop would cancel the row that just
    /// started.
    private func setDemonstrating(_ style: ChatNameMorphStyle, isHighlighted: Bool) {
        guard isHighlighted else {
            if demonstrating == style { stopDemonstration() }
            return
        }
        guard demonstrating != style else { return }
        stopDemonstration()
        demonstrating = style

        // Under Reduce Motion the row keeps its name and stays still. `setStringValue` would not
        // animate, so a demonstration here would be the two names swapping outright — a flicker
        // where the setting asked for less movement, not more.
        guard !Design.Motion.reducesMotion else { return }

        // A demonstration holds the row's own name before it starts, which is a dwell rather
        // than a delay: the highlight is also where it lands when the menu *opens*, and a list
        // whose selected row reads "Threading" the moment it appears has answered a question
        // nobody asked with the one name it needed to show. It is what keeps a pointer crossing
        // the list from leaving a trail of morphing rows behind it, too.
        scheduleNextLeg(after: Design.Motion.demonstrationHold)
    }

    private func stopDemonstration() {
        demonstrationTimer.invalidate()
        // Put the row back to its own name without animating. A row abandoned mid-morph would be
        // left showing the app's name where a transition's name belongs.
        if let style = demonstrating {
            nameRowPreviews[style]?.setStringValue(style.displayName, animated: false)
        }
        demonstrating = nil
    }

    /// One leg of the demonstration: morph to whichever of the two names is not showing, then
    /// come back for the other once this one has settled and been read.
    private func stepDemonstration() {
        guard let style = demonstrating, let label = nameRowPreviews[style] else { return }

        let next = label.stringValue == style.displayName
            ? Preview.alternateName
            : style.displayName
        let period = label.morphSettleDuration(to: next) + Design.Motion.demonstrationHold
        label.setStringValue(next, animated: true)

        scheduleNextLeg(after: period)
    }

    private func scheduleNextLeg(after delay: TimeInterval) {
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stepDemonstration()
            }
        }
        demonstrationTimer.install(timer)
        // `.common`, because a press held on the control that opened the menu runs the
        // event-tracking run-loop mode — and browsing a dropdown with the button still down is
        // one of the two ways every menu is used. A default-mode timer would stop there.
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: - Layout

    private func setupLayout() {
        let orbControl = NSStackView(views: [orbPreview, orbStylePopUp])
        orbControl.orientation = .horizontal
        orbControl.alignment = .centerY
        orbControl.spacing = Design.Spacing.medium

        let indicatorCard = SettingsCard(rows: [
            SettingsUI.row(
                title: "Working indicator",
                subtitle: "Random chooses a new visual for each turn without repeating "
                    + "the previous one. Choose a named orb to keep it fixed; the list "
                    + "shows each one running.",
                control: orbControl
            )
        ])

        let transitionCard = SettingsCard(rows: [
            SettingsUI.row(
                title: "Chat name transition",
                subtitle: "Used when the active chat is renamed. Point at a transition in "
                    + "the list to watch it. Animation timing is tuned by "
                    + "\(AppInfo.name) and follows Reduce Motion.",
                control: nameStylePopUp
            ),
            SettingsUI.fullRow(namePreviewRow())
        ])

        let page = SettingsUI.page(title: "Motion", sections: [
            SettingsUI.section("Working", indicatorCard),
            SettingsUI.section("Chat names", transitionCard)
        ], hostPage: .motion)

        page.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: view.topAnchor),
            page.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    private func namePreviewRow() -> NSView {
        let replay = SettingsUI.button(
            "Preview",
            target: self,
            action: #selector(previewNameMorph)
        )
        namePreview.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [namePreview, replay])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Design.Spacing.medium
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true
        return row
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        // The row itself reports a closing menu, so this covers only the page going away with a
        // dropdown still open.
        stopDemonstration()
    }

    // MARK: - Actions

    @objc private func orbStyleChanged() {
        guard let style = orbStylePopUp.selectedItem?.representedValue
                as? WorkingOrbStyle else { return }
        AppSettings.shared.workingOrbStyle = style
        orbPreview.prepareForWorking(style: style)
    }

    @objc private func nameStyleChanged() {
        guard let style = nameStylePopUp.selectedItem?.representedValue
                as? ChatNameMorphStyle else { return }
        AppSettings.shared.chatNameMorphStyle = style
        namePreview.morphStyleOverride = style
        previewNameMorph()
    }

    @objc private func previewNameMorph() {
        previewNameIndex = (previewNameIndex + 1) % previewNames.count
        namePreview.setStringValue(previewNames[previewNameIndex], animated: true)
    }
}
