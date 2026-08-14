import AppKit

// MARK: - Defaults

enum PrivacyPageDefaults {
    /// How often an open page re-reads the grants it can read without prompting.
    ///
    /// A grant is changed in another application, and macOS posts nothing when it happens — so
    /// the only way for the page to stay true while it is on screen is to look again. Three
    /// seconds is chosen against the two calls it costs: `AXIsProcessTrusted` and
    /// `CGPreflightScreenCaptureAccess` are local, and `getNotificationSettings` is one XPC
    /// round trip. It only ticks while the page is the one on screen.
    static let refreshInterval: TimeInterval = 3
}

/// What the operating system lets Threading do, and who ends up using each grant.
///
/// This page exists because the honest answer was previously spread across three places that
/// each covered one slice: a paragraph about notifications in the user guide, an extension
/// load failure that named the Accessibility pane, and nothing at all for the folder prompt a
/// user actually meets first. None of them said the thing that matters most — that a grant
/// given to Threading is exercised by the agents running inside it.
///
/// It is an inventory, not a checklist. Two of these four are expected to read "Not allowed"
/// on almost every machine, so nothing here is coloured as a fault; green marks a grant that is
/// live, and everything else stays quiet.
final class PrivacyPreferencesViewController: NSViewController {

    // MARK: - Row Views

    private struct PermissionRow {
        let statusGlyph: NSTextField
        let statusLabel: NSTextField
        let container: NSView
    }

    // MARK: - Properties

    private let reader: SystemPrivacyStatusReader
    private let refreshInterval: TimeInterval
    private let settings: AppSettings
    /// Injected keychain probes, so a test asserts on stated answers rather than on whatever
    /// the developer's own keychain holds — the same rule as `reader`.
    private let claudeAccounts: () -> [AgentAccount]
    private let keychainAvailability:
        @Sendable (String) -> ClaudeKeychainCredentials.Availability
    private let keychainGrant: @Sendable (String) -> Bool
    private let prefetchUsage: () -> Void
    private var rows: [SystemPrivacyPermission: PermissionRow] = [:]
    private var shown: [SystemPrivacyPermission: SystemPrivacyStatus] = [:]
    private var keychainToggle: ThemedToggle?
    private var keychainSubtitleField: NSTextField?
    private var shownKeychainSubtitle: String?
    private let activationEvents = AppEventObservations()

    /// Live while the page is on screen. Nil is the whole of "not watching" — the notification
    /// observer is added and removed alongside it, so there is one state rather than two that
    /// can disagree.
    private let refreshTimer = MainRunLoopTimer()

    // MARK: - Initialization

    init(
        reader: SystemPrivacyStatusReader = SystemPrivacyStatusReader(),
        refreshInterval: TimeInterval = PrivacyPageDefaults.refreshInterval,
        settings: AppSettings = .shared,
        claudeAccounts: @escaping () -> [AgentAccount] = {
            AgentAccountDiscovery.accounts(for: .claude)
        },
        keychainAvailability:
            @escaping @Sendable (String) -> ClaudeKeychainCredentials.Availability = {
            ClaudeKeychainCredentials.availability(forConfigPath: $0)
        },
        keychainGrant: @escaping @Sendable (String) -> Bool = {
            ClaudeKeychainCredentials.requestAccess(forConfigPath: $0)
        },
        prefetchUsage: @escaping () -> Void = { AccountUsageMenu.prefetch() }
    ) {
        self.reader = reader
        self.refreshInterval = refreshInterval
        self.settings = settings
        self.claudeAccounts = claudeAccounts
        self.keychainAvailability = keychainAvailability
        self.keychainGrant = keychainGrant
        self.prefetchUsage = prefetchUsage
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        buildPage()
        refresh()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // A grant can be changed in System Settings while this page is open, and returning to
        // it is exactly when the user expects the new answer.
        refresh()
    }

    /// The page's whole job is to report a live fact, and it used to stop reporting the moment
    /// it was on screen: `refresh` ran when the page was built and when it was navigated back
    /// to, and neither of those is when the answer changes. The page *invites* the change — the
    /// row says "You allow Threading in System Settings", the button opens the pane — and the
    /// user then comes back to a word that still reads "Not allowed". So the page watches while
    /// it is visible.
    override func viewDidAppear() {
        super.viewDidAppear()
        startWatching()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        stopWatching()
    }

    // MARK: - Watching

    private func startWatching() {
        guard !refreshTimer.isInstalled else { return }

        // Coming back from System Settings is the common path and the one worth answering
        // immediately: a poll would leave the old word up for up to an interval, right at the
        // moment the user is looking for the new one.
        activationEvents.observe(NSApplication.didBecomeActiveNotification) { [weak self] in
            self?.refreshIfOnScreen()
        }

        // …and the poll covers what activation does not. A TCC prompt is presented by another
        // process, so an approval given to one raised by an agent can land without Threading
        // ever having resigned active.
        refreshTimer.install(Timer.scheduledTimer(
            withTimeInterval: refreshInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshIfOnScreen() }
        })
    }

    private func stopWatching() {
        refreshTimer.invalidate()
        activationEvents.removeAll()
    }

    /// A cached page is kept alive after being navigated away from, so "in a window" is what
    /// says this one is the page on screen. Deliberately not `isVisible`: an unshown window
    /// answers no to that, and every test here builds one rather than ordering a real window
    /// in front of the developer.
    private func refreshIfOnScreen() {
        guard view.window != nil else { return }
        refresh()
    }

    // MARK: - Construction

    private func buildPage() {
        let page = SettingsUI.page(title: "Privacy", sections: [
            SettingsUI.note(
                "Threading runs without the App Sandbox — a terminal that cannot open a pseudo-"
                    + "terminal or launch your shell is not a terminal. These are the grants it "
                    + "asks macOS for, and none of them is taken silently."
            ),
            SettingsUI.section("System Permissions", permissionsCard()),
            SettingsUI.section("Who Uses These Grants", attributionCard()),
            SettingsUI.section("Stored Credentials", credentialsCard()),
            SettingsUI.section("Leaving This Mac", egressCard()),
            SettingsUI.note(
                "Agents reach the network on their own account, under their own logins. "
                    + "Threading does not watch what they do there."
            )
        ])
        page.setAccessibilityIdentifier("settings.privacy.page")
        page.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: view.topAnchor),
            page.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    private func permissionsCard() -> SettingsCard {
        SettingsCard(
            rows: SystemPrivacyPermission.allCases.map { permissionRow(for: $0) }
        )
    }

    private func permissionRow(for permission: SystemPrivacyPermission) -> NSView {
        let icon = NSImageView(image: symbol(permission.symbol))
        icon.imageScaling = .scaleProportionallyDown
        icon.contentTintColor = Design.Text.secondary
        icon.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: permission.title)
        title.applyFont(.body)
        title.textColor = Design.Text.label

        let statusGlyph = NSTextField(labelWithString: "●")
        statusGlyph.applyFont(.caption)
        statusGlyph.setContentHuggingPriority(.required, for: .horizontal)

        let statusLabel = NSTextField(labelWithString: "")
        statusLabel.applyFont(.caption)
        statusLabel.textColor = Design.Text.secondary
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)

        let titleLine = NSStackView(views: [title, statusGlyph, statusLabel])
        titleLine.orientation = .horizontal
        titleLine.alignment = .firstBaseline
        titleLine.spacing = Design.Spacing.small
        titleLine.setHuggingPriority(.defaultLow, for: .horizontal)

        let purpose = NSTextField(wrappingLabelWithString: permission.purpose)
        purpose.applyFont(.subheading)
        purpose.textColor = Design.Text.secondary

        let granting = NSTextField(wrappingLabelWithString: permission.howItIsGranted)
        granting.applyFont(.subheading)
        granting.textColor = Design.Text.tertiary

        let labels = NSStackView(views: [titleLine, purpose, granting])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = Design.Spacing.hairline
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [icon, labels, settingsButton(for: permission)])
        row.orientation = .horizontal
        row.alignment = .top
        row.distribution = .fill
        row.spacing = Design.Spacing.medium

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: Design.Symbol.control + 2),
            icon.heightAnchor.constraint(equalTo: icon.widthAnchor),
            // The wrapping labels have no intrinsic width to argue with, so the column is told
            // to take the row's slack rather than letting the trailing button take it — the
            // same trap `SettingsUI.row` documents.
            titleLine.widthAnchor.constraint(equalTo: labels.widthAnchor)
        ])

        let container = SettingsUI.fullRow(row)
        container.setAccessibilityIdentifier("settings.privacy.\(permission.rawValue)")
        // Hand-built rather than `SettingsUI.row`, so the search anchor is stated here.
        SettingsRowAnchor.tag(container, title: permission.title)

        rows[permission] = PermissionRow(
            statusGlyph: statusGlyph,
            statusLabel: statusLabel,
            container: container
        )
        return container
    }

    private func settingsButton(for permission: SystemPrivacyPermission) -> NSView {
        let button = SettingsUI.button(
            "Open Settings",
            target: self,
            action: #selector(openSystemSettings)
        )
        button.tag = SystemPrivacyPermission.allCases.firstIndex(of: permission) ?? 0
        button.isEnabled = permission.settingsURL != nil
        button.setAccessibilityIdentifier("settings.privacy.\(permission.rawValue).open")

        // Four buttons reading "Open Settings" are indistinguishable in a rotor. The context
        // goes in AXHelp rather than AXDescription: `ThemedButton` deliberately publishes a
        // button's words as its *title* and returns nil for the label, so setting a label here
        // would be silently dropped. The tooltip carries the same sentence for the pointer.
        let context = L10n.format("Open %@ in System Settings", permission.title)
        button.setAccessibilityHelp(context)
        button.toolTip = context

        // Under `.fill` the row's leftover width goes to whichever view is willing to take it.
        // Without this the button grew to half the card and squeezed the text into a column,
        // which is the same bug as an unassigned-slack row wearing the opposite face.
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    private func attributionCard() -> SettingsCard {
        SettingsCard(rows: [
            SettingsUI.detailRow(
                symbol: "arrow.turn.down.right",
                title: "Agents inherit what you grant Threading",
                detail: "macOS attributes a directly launched child process to the app that "
                    + "launched it. Claude and Codex run inside Threading, so the files they "
                    + "read are approved against Threading's grant — and the prompt names "
                    + "Threading, whichever agent asked."
            ),
            SettingsUI.detailRow(
                symbol: "shippingbox",
                title: "Extensions are separate",
                detail: "A safe extension is sandboxed and Foundation-only. A companion "
                    + "executable must declare each capability it wants, and Threading requests "
                    + "only the grants that its reviewed capabilities cover."
            ),
            SettingsUI.detailRow(
                symbol: "network",
                title: "Remote Access starts at a loopback listener",
                detail: "The listener binds to 127.0.0.1 and the selected HTTPS relay or "
                    + "Tailscale Serve publishes only that listener. Threading opens no LAN "
                    + "listener, so macOS never asks for Local Network access."
            )
        ])
    }

    private func credentialsCard() -> SettingsCard {
        let toggle = SettingsUI.toggle(
            isOn: settings.readsClaudeLoginFromKeychain,
            target: self,
            action: #selector(keychainToggleChanged(_:))
        )
        toggle.setAccessibilityLabel(L10n.string("Live usage from your Claude login"))
        keychainToggle = toggle

        var subtitleField: NSTextField?
        let liveUsageRow = SettingsUI.row(
            title: "Live usage from your Claude login",
            subtitle: keychainSubtitle(status: nil),
            control: toggle,
            subtitleField: &subtitleField
        )
        keychainSubtitleField = subtitleField

        return SettingsCard(rows: [
            SettingsUI.detailRow(
                symbol: "key",
                title: "Kept in your login keychain",
                detail: "Your GitHub connection, any model API keys you enter, and secrets an "
                    + "extension stores. They never enter Threading's own database."
            ),
            SettingsUI.detailRow(
                symbol: "person.crop.circle",
                title: "Agent logins stay with the agent",
                detail: "Threading reads which accounts exist under ~/.claude and ~/.codex so "
                    + "it can route a session to one. It reads a credential only for the "
                    + "live-usage switch below, and only after you allow it in the keychain "
                    + "prompt."
            ),
            liveUsageRow
        ])
    }

    // MARK: - Claude Keychain Row

    /// The row's whole story in one place: what is read, where it goes, what saying no costs.
    /// The dynamic status is appended rather than shown in its own label so the paragraph and
    /// the fact never sit in different type styles arguing about which is the truth.
    private func keychainSubtitle(status: String?) -> String {
        let explanation = L10n.string(
            "Reads the sign-in the Claude CLI keeps in your macOS keychain and asks Anthropic "
                + "for the account's rate limits — the numbers in the toolbar's usage pill. The "
                + "token goes to Anthropic and nowhere else; Threading never stores, refreshes, "
                + "or logs it. macOS asks once per login — choose Always Allow to not be asked "
                + "again. When this is off, usage comes from caches the CLI leaves on disk, "
                + "which can be hours old or missing."
        )
        guard let status else { return explanation }
        return explanation + "\n" + status
    }

    /// On is a grant flow, not just a bit: each Claude login that has a keychain item Threading
    /// cannot yet read gets its one macOS prompt now, while the user is looking at the sentence
    /// that explains it. Off is only the bit — the reads stop, and any standing "Always Allow"
    /// stays until revoked in Keychain Access, which the status line says while it matters.
    @objc private func keychainToggleChanged(_ sender: ThemedToggle) {
        settings.readsClaudeLoginFromKeychain = sender.state == .on
        guard sender.state == .on else {
            refreshKeychainStatus()
            return
        }

        let accounts = claudeAccounts()
        let availability = keychainAvailability
        let grant = keychainGrant
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for account in accounts
            where availability(account.configPath) == .needsGrant {
                _ = grant(account.configPath)
            }
            Task { @MainActor [weak self] in
                self?.refreshKeychainStatus()
                // The pill should light up with the new source now, not a timer-tick later.
                self?.prefetchUsage()
            }
        }
    }

    /// Reads availability off the main thread — a granted probe is a round trip to
    /// `securityd` — and rewrites the row only when the answer changed, the same
    /// VoiceOver-quiet rule the permission rows follow.
    private func refreshKeychainStatus() {
        let enabled = settings.readsClaudeLoginFromKeychain
        keychainToggle?.state = enabled ? .on : .off

        guard enabled else {
            showKeychainSubtitle(keychainSubtitle(status: L10n.string("Off.")))
            return
        }

        let accounts = claudeAccounts()
        let availability = keychainAvailability
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let states = accounts.map { availability($0.configPath) }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.showKeychainSubtitle(
                    self.keychainSubtitle(status: Self.keychainStatus(for: states))
                )
            }
        }
    }

    private func showKeychainSubtitle(_ subtitle: String) {
        guard subtitle != shownKeychainSubtitle else { return }
        shownKeychainSubtitle = subtitle
        keychainSubtitleField?.stringValue = subtitle
    }

    /// One sentence of truth about where the grant stands, testable as a pure function.
    static func keychainStatus(
        for states: [ClaudeKeychainCredentials.Availability]
    ) -> String {
        let withItems = states.filter { $0 != .missing }
        guard !withItems.isEmpty else {
            return L10n.string("On — no Claude sign-in found in the keychain.")
        }

        let granted = withItems.filter { $0 == .granted }.count
        if granted == withItems.count {
            return L10n.format(
                "On — reading %lld of %lld logins.", Int64(granted), Int64(withItems.count)
            )
        }
        return L10n.format(
            "On — reading %lld of %lld logins. Toggle off and on to be asked again "
                + "for the rest.",
            Int64(granted),
            Int64(withItems.count)
        )
    }

    /// The old copy here claimed Threading "sends nothing about your projects anywhere". That
    /// was wrong, and wrong in the way that costs trust rather than accuracy: a lock-screen
    /// notification carries the chat's own name, and the chat is usually named by the agent.
    /// Naming the exceptions is worth more than a clean sentence, because someone watching the
    /// traffic will find them either way.
    private func egressCard() -> SettingsCard {
        SettingsCard(rows: [
            SettingsUI.detailRow(
                symbol: "chart.bar.xaxis",
                title: "No analytics",
                detail: "Threading has no usage tracking and no identifier for this install. "
                    + "The network requests its product features make are described below; "
                    + "none of them is analytics."
            ),
            SettingsUI.detailRow(
                symbol: "arrow.triangle.pull",
                title: "Status card checks reach your code host",
                detail: "While the session status card is on, Threading asks GitHub or GitLab "
                    + "for the branch's open change request and checks. GitHub uses your "
                    + "available connection, or anonymous access for a public repository; "
                    + "GitLab uses glab. Turning off the card stops these lookups."
            ),
            SettingsUI.detailRow(
                symbol: "bell.badge",
                title: "Notification titles reach Apple",
                detail: "To arrive on your iPhone, a notification travels through Apple's push "
                    + "service, and its title is the chat's name — usually the one the agent "
                    + "chose. Tool arguments, paths and diffs are deliberately left out. This "
                    + "happens only while Remote Access is on."
            ),
            SettingsUI.detailRow(
                symbol: "arrow.down.circle",
                title: "Update checks reach GitHub",
                detail: "Threading uses Sparkle to check a release feed on GitHub once a day. "
                    + "The request carries the version you are on and your macOS version, the "
                    + "way any download does — no identifier, and nothing about your projects. "
                    + "Turn it off in General settings and nothing is asked."
            ),
            SettingsUI.detailRow(
                symbol: "lifepreserver",
                title: "Support reports are yours to send",
                detail: "Help ▸ Create Remote Support Report… writes a file of versions, "
                    + "counts and grant states — no names, paths or prompts — and reveals it in "
                    + "the Finder. Threading never uploads it; sending it is your decision."
            )
        ])
    }

    private func symbol(_ name: String) -> NSImage {
        SettingsUI.symbolImage(name)
    }

    // MARK: - State

    private func refresh() {
        reader.load { [weak self] statuses in
            guard let self else { return }
            for (permission, status) in statuses {
                self.apply(status, to: permission)
            }
        }
        refreshKeychainStatus()
    }

    /// Rewriting a label that has not changed is what a poll would otherwise do twenty times a
    /// minute: it re-announces the row to VoiceOver and marks the text field dirty for nothing.
    /// The page only touches a row when its answer is new.
    private func apply(_ status: SystemPrivacyStatus, to permission: SystemPrivacyPermission) {
        guard let row = rows[permission], shown[permission] != status else { return }
        shown[permission] = status

        row.statusLabel.stringValue = status.label
        row.statusGlyph.textColor = Self.color(for: status)

        // Colour is decoration here. The word carries the state, and the row states both to
        // VoiceOver so the grant can be audited without seeing the dot.
        row.container.setAccessibilityLabel(
            L10n.format("%@ permission: %@", permission.title, status.label)
        )
    }

    /// Green marks a live grant. Nothing marks the absence of one, because two of these are
    /// meant to be absent — a red dot beside Screen Recording on a machine that has never
    /// installed a capturing companion would be reporting a problem that does not exist.
    private static func color(for status: SystemPrivacyStatus) -> NSColor {
        switch status {
        case .allowed: return Design.Status.positive
        case .notAllowed, .askedWhenNeeded: return Design.Text.tertiary
        }
    }

    // MARK: - Actions

    @objc private func openSystemSettings(_ sender: NSControl) {
        let permissions = SystemPrivacyPermission.allCases
        guard permissions.indices.contains(sender.tag),
              let url = permissions[sender.tag].settingsURL else { return }
        NSWorkspace.shared.open(url)
    }
}
