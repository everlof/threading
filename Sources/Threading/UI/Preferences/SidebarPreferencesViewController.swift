import AppKit

/// Sidebar preferences: how the project list orders, groups and names its chats.
///
/// These rows were the first card of General, where they sat above thirty unrelated settings
/// and made General read as "the sidebar page, and everything else". Every one of them changes
/// what the sidebar shows and nothing else, which is what earns them a destination of their own.
final class SidebarPreferencesViewController: NSViewController {

    // MARK: - Controls

    private let sessionOrderPopUp = ThemedPopUp()
    private let sessionOrderDirectionPopUp = ThemedPopUp()
    private let chatPreviewToggle = ThemedToggle()
    private let branchGroupingToggle = ThemedToggle()
    private let branchFollowToggle = ThemedToggle()
    private let compactTreeToggle = ThemedToggle()
    private let unhideProjectsToggle = ThemedToggle()
    private let terminalTitleToggle = ThemedToggle()
    private let projectIconToggle = ThemedToggle()
    private let accountAvatarToggle = ThemedToggle()
    /// Holds the unhide switch's subscription for the page's lifetime: the same Boolean is
    /// written from the sidebar's own menu.
    private let appEvents = AppEventObservations()

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        setupControls()
        setupLayout()
    }

    // MARK: - Setup

    private func setupControls() {
        let options = NativeSidebarPipelineOptions.current
        configureSessionOrderPopUps(options)
        configure(chatPreviewToggle, isOn: options.chatPreview, action: #selector(chatPreviewChanged))
        chatPreviewToggle.setAccessibilityIdentifier("settings.sidebar.chat-preview")
        configure(branchGroupingToggle,
                  isOn: options.branchGrouping,
                  action: #selector(branchGroupingChanged))
        configure(branchFollowToggle,
                  isOn: AppSettings.shared.followsCheckoutBranch,
                  action: #selector(branchFollowChanged))
        configure(compactTreeToggle, isOn: options.compactTree, action: #selector(compactTreeChanged))
        configure(unhideProjectsToggle,
                  isOn: AppSettings.shared.unhidesProjectsOnWriting,
                  action: #selector(unhideProjectsChanged))
        unhideProjectsToggle.setAccessibilityIdentifier("settings.sidebar.unhide-projects-on-writing")
        appEvents.observe(AppSettingsDidChange.self) { [weak self] change in
            guard change.affects(AppSettingIdentity.unhidesProjectsOnWriting.rawValue) else { return }
            self?.unhideProjectsToggle.state = AppSettings.shared.unhidesProjectsOnWriting ? .on : .off
        }
        configure(terminalTitleToggle,
                  isOn: AppSettings.shared.usesAgentTitleInSidebar,
                  action: #selector(terminalTitleChanged))
        configure(projectIconToggle,
                  isOn: AppSettings.shared.discoversProjectIcons,
                  action: #selector(projectIconChanged))
        configure(accountAvatarToggle,
                  isOn: AppSettings.shared.discoversAccountAvatars,
                  action: #selector(accountAvatarChanged))
    }

    private func configure(_ toggle: ThemedToggle, isOn: Bool, action: Selector) {
        toggle.state = isOn ? .on : .off
        toggle.target = self
        toggle.action = action
    }

    /// The sidebar's order and its direction, the same two choices its Sort menu offers.
    ///
    /// The direction's two items are worded for the order in force — "Most Recent First" says
    /// something about a list of chats that "Descending" does not — so they are rebuilt whenever
    /// the order changes.
    private func configureSessionOrderPopUps(_ values: NativeSidebarPipelineOptionValues) {
        for order in SidebarSessionOrder.allCases {
            sessionOrderPopUp.addItem(
                ThemedMenuItem(title: order.settingsTitle, representedValue: order)
            )
        }
        sessionOrderPopUp.selectItem(
            at: SidebarSessionOrder.allCases.firstIndex(of: values.sessionOrder) ?? 0
        )
        sessionOrderPopUp.target = self
        sessionOrderPopUp.action = #selector(sessionOrderChanged)
        sessionOrderPopUp.setAccessibilityIdentifier("settings.sidebar.session-order")
        SettingsUI.preferControlWidth(sessionOrderPopUp)

        sessionOrderDirectionPopUp.target = self
        sessionOrderDirectionPopUp.action = #selector(sessionOrderDirectionChanged)
        sessionOrderDirectionPopUp.setAccessibilityIdentifier(
            "settings.sidebar.session-order-direction"
        )
        SettingsUI.preferControlWidth(sessionOrderDirectionPopUp)
        reloadSessionOrderDirections(values)
    }

    private func reloadSessionOrderDirections(_ values: NativeSidebarPipelineOptionValues) {
        sessionOrderDirectionPopUp.removeAllItems()
        sessionOrderDirectionPopUp.addItem(ThemedMenuItem(
            title: values.sessionOrder.naturalDirectionTitle,
            representedValue: false
        ))
        sessionOrderDirectionPopUp.addItem(ThemedMenuItem(
            title: values.sessionOrder.reversedDirectionTitle,
            representedValue: true
        ))
        sessionOrderDirectionPopUp.selectItem(at: values.sessionOrderReversed ? 1 : 0)
    }

    private func setupLayout() {
        let order = SettingsCard(rows: [
            SettingsUI.row(
                title: "Sort sessions by",
                subtitle: "Pinned chats stay on top.",
                control: sessionOrderPopUp
            ),
            SettingsUI.row(
                title: "Sort direction",
                subtitle: "Most Recent First is how the iPhone app lists them.",
                control: sessionOrderDirectionPopUp
            )
        ])

        let layout = SettingsCard(rows: [
            SettingsUI.row(
                title: "Show five chats per project",
                subtitle: "Longer projects end in Show 5 more.",
                help: SettingsUI.help(
                    "Show five chats per project",
                    "The chat you have open always stays in view, even when it is not among "
                        + "the five."
                ),
                control: chatPreviewToggle
            ),
            SettingsUI.row(
                title: "Group sessions by branch",
                subtitle: "When a branch has more than one session.",
                control: branchGroupingToggle
            ),
            SettingsUI.row(
                title: "Follow the checkout's branch",
                subtitle: "A stopped session takes the branch its checkout switches to.",
                help: SettingsUI.help(
                    "Follow the checkout's branch",
                    "A session that isn't running updates its branch whenever its checkout "
                        + "switches — from another session or outside Threading alike. Off, it "
                        + "keeps the branch it last ran on."
                ),
                control: branchFollowToggle
            ),
            SettingsUI.row(
                title: "Compact tree",
                subtitle: "Every row starts at the same edge.",
                help: SettingsUI.help(
                    "Compact tree",
                    "Projects separate with spacing and a rule instead of indentation."
                ),
                control: compactTreeToggle
            ),
            SettingsUI.row(
                title: "Unhide projects when writing in their chats",
                subtitle: "Typing in a hidden project's chat shows the project again.",
                control: unhideProjectsToggle
            )
        ])

        let names = SettingsCard(rows: [
            SettingsUI.row(
                title: "Name sessions after the agent's own title",
                subtitle: "A name you give a session is always kept.",
                control: terminalTitleToggle
            ),
            SettingsUI.row(
                title: "Discover project icons",
                subtitle: "From the checkout, or the GitHub organization's avatar.",
                help: SettingsUI.help(
                    "Discover project icons",
                    "Projects without an icon use an image in the checkout or request the "
                        + "GitHub organization avatar implied by the origin remote. Other "
                        + "websites are contacted only when you choose Use Website Favicon."
                ),
                control: projectIconToggle
            ),
            SettingsUI.row(
                title: "Discover account avatars",
                subtitle: "Looks up Gravatar, then GitHub. A chosen emoji still wins.",
                help: SettingsUI.help(
                    "Discover account avatars",
                    "Finding an account avatar sends a hash of its login email to Gravatar, "
                        + "then the email to GitHub's public-user search."
                ),
                control: accountAvatarToggle
            )
        ])

        let page = SettingsUI.page(title: "Sidebar", sections: [
            SettingsUI.section("Order", order),
            SettingsUI.section("Layout", layout),
            SettingsUI.section("Names & Icons", names)
        ])

        page.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: view.topAnchor),
            page.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    // MARK: - Actions

    @objc private func sessionOrderChanged(_ sender: ThemedPopUp) {
        guard let order = sender.selectedItem?.representedValue as? SidebarSessionOrder else {
            return
        }
        // The sidebar's Sort menu goes through the same call, so a registered fact sort gives way
        // here exactly as it does there.
        NativeSidebarPipelineOptions.chooseSessionOrder(order)
        reloadSessionOrderDirections(NativeSidebarPipelineOptions.current)
    }

    @objc private func sessionOrderDirectionChanged(_ sender: ThemedPopUp) {
        guard let isReversed = sender.selectedItem?.representedValue as? Bool else { return }
        NativeSidebarPipelineOptions.chooseSessionOrderReversed(isReversed)
    }

    @objc private func chatPreviewChanged() {
        NativeSidebarPipelineOptions.setChatPreview(chatPreviewToggle.state == .on)
        // The preview decides which rows exist, so the tree is rebuilt rather than re-laid out.
        NotificationCenter.default.post(ProjectsDidChange())
    }

    @objc private func branchGroupingChanged() {
        NativeSidebarPipelineOptions.setBranchGrouping(branchGroupingToggle.state == .on)
        // The sidebar rebuilds its tree on this, which is what adds or removes the level.
        NotificationCenter.default.post(ProjectsDidChange())
    }

    @objc private func branchFollowChanged() {
        // No extra post needed either way: the setter's own settings notification makes
        // `CheckoutBranchFollower` reconcile, and switching on catches every checkout up,
        // which regroups the sidebar through the store where anything actually moved.
        AppSettings.shared.followsCheckoutBranch = branchFollowToggle.state == .on
    }

    @objc private func compactTreeChanged() {
        // No extra post: density changes no node, and the setter's own settings event is what
        // the sidebar re-lays out on. See `ProjectSidebarViewController.applyTreeDensity`.
        NativeSidebarPipelineOptions.setCompactTree(compactTreeToggle.state == .on)
    }

    @objc private func unhideProjectsChanged() {
        AppSettings.shared.unhidesProjectsOnWriting = unhideProjectsToggle.state == .on
    }

    @objc private func terminalTitleChanged() {
        AppSettings.shared.usesAgentTitleInSidebar = terminalTitleToggle.state == .on
        NotificationCenter.default.post(ProjectsDidChange())
    }

    @objc private func projectIconChanged() {
        AppSettings.shared.discoversProjectIcons = projectIconToggle.state == .on
        // Sweeps immediately, so switching this on does not wait for a relaunch.
        ProjectIconDiscovery.shared.retryAll()
    }

    @objc private func accountAvatarChanged() {
        AppSettings.shared.discoversAccountAvatars = accountAvatarToggle.state == .on
        // Forgotten attempts plus a sidebar rebuild, so re-enabling acts immediately —
        // rows re-prime lookups as they reconfigure.
        AccountAvatarStore.retryAll()
        NotificationCenter.default.post(ProjectsDidChange())
    }
}
