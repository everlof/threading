import AppKit
import AuthenticationServices

struct RemoteCredentialStoragePresentation: Equatable {
    let title: String
    let detail: String

    static func resolve(isShellReachable: Bool) -> RemoteCredentialStoragePresentation {
        RemoteCredentialStoragePresentation(
            title: L10n.string("Remote credentials"),
            detail: KeychainStoragePolicy.storageDescription(
                isShellReachable: isShellReachable
            )
        )
    }
}

/// Remote Access gets a page of its own because it is a setup flow, not a behavioural toggle.
///
/// General used to hide the feature below several unrelated sections and then put the actual
/// pairing instructions in an alert. This page keeps the whole journey visible: opt in, watch
/// the listener and selected transport come up, scan the code, and understand the authority.
final class RemoteAccessPreferencesViewController: NSViewController {

    private let credentialStorageIsShellReachable: Bool
    /// Whether this build offers Hosted Direct. A build that does not — every public channel —
    /// omits the Hosted Direct row, never creates the Sign in with Apple helper, and never offers
    /// Threading Direct as a way in. See `BuildChannel.offersHostedDirect`.
    private let hostedDirectIsOffered: Bool

    // MARK: - Controls

    private let remoteAccessToggle = ThemedToggle()
    private let thisNetworkToggle = ThemedToggle()
    private let tailscaleToggle = ThemedToggle()
    private let tailscaleServeToggle = ThemedToggle()
    /// The Serve sub-option's own status line, and the admin-console page that fixes it.
    private var tailscaleServeStatusViews: WayInStatusViews?
    private let tailscaleServeRemedyButton = ThemedButton()
    /// The page `tailscaleServeRemedyButton` opens, held here because a target-action carries no
    /// payload. Cleared on every update so a stale page cannot outlive the failure that offered it.
    private var tailscaleServeRemedyURL: URL?
    private var wayInStatusViews: [RemoteAccessWayIn: WayInStatusViews] = [:]

    /// The run of ways in, and the one whose detail is on the page.
    ///
    /// A segmented run rather than a card each: three cards of four questions was the page a
    /// person had to read top to bottom to find the one switch they came for, and two of the
    /// three were always describing something they had not chosen. The run keeps every choice on
    /// screen and shows one panel, and each segment carries its own state mark so a way in you
    /// are *not* looking at can still say it came up.
    private let waysInControl = ThemedSegmentedControl()
    /// The card under the run, rebuilt when the choice moves. Not on every update: a status line
    /// changes on every interface event, and a card rebuilt to change two strings is how a page
    /// starts flickering under a network that is settling.
    private let waysInHost = WaysInHostView()
    private var waysInCard: SettingsCard?
    private var waysIn: [RemoteAccessWayIn] = [.thisNetwork, .tailscale]
    private var selectedWayIn: RemoteAccessWayIn = .thisNetwork
    /// The structure the card was last built for. The rebuild trigger, and nothing else.
    private var builtWaysIn: [RemoteAccessWayIn]?
    private var builtSelection: RemoteAccessWayIn?
    /// The last values the page was handed, so a rebuilt card can be repainted without asking
    /// the coordinator again — which a test driving `apply` must never make it do.
    private var lastDoors = RemoteAccessDoorsPresentation.idle
    private var lastDiscovery = RemoteDiscoveryPresentation.idle

    private let discoveryToggle = ThemedToggle()
    /// The announced fact's whole row, held so it can leave the card rather than leave a gap.
    /// Hiding the label alone keeps the mark column's height constraint and prints a blank line.
    private var announcedRow: NSView?
    private let announcedGlyph = NSTextField(labelWithString: DoorMark.idle)
    private let announcedLabel = NSTextField(wrappingLabelWithString: "")
    /// The announcement is on or it is not, so this slot never spins. It is here because the
    /// mark column's width is the spinner's, and a fact line indented differently from the
    /// status line above it is a misalignment a reader sees before they read either.
    private let announcedSpinner = ThemedSpinner()
    private let wakeGlyph = NSTextField(labelWithString: DoorMark.idle)
    private let wakeLabel = NSTextField(wrappingLabelWithString: "")
    /// This one does spin: reading the two wake facts costs a child process and a browse, and
    /// silence for the length of both is what "Not checked yet" would otherwise look like.
    private let wakeSpinner = ThemedSpinner()
    /// The door state the wake facts were last read against, and the read in flight.
    ///
    /// Both exist to keep this off a timer without asking for the same answer forever:
    /// `wakeOnDemand` posts the page's own status notification when it lands, so refreshing on
    /// every notification would re-probe for every answer it received.
    private var wakeFactsDoorState: RemoteAccessDoorState?
    private var wakeFactsTask: Task<Void, Never>?
    private let identityCaption = NSTextField(labelWithString: "")
    /// Wrapping, and by character: 26 characters a person compares glyph by glyph must not be
    /// truncated, and in a squeezed pane the only alternative to truncating them is a second
    /// line. It is the one incompressible thing in the hero, so without this it pushes the whole
    /// text column past the card.
    private let identityCode = NSTextField(wrappingLabelWithString: "")
    /// The one identity line that stays on the page: *why there is no code*, or that none has
    /// been minted yet. The explanation of what the code is for moved into the hero's "?" —
    /// a reason is not an explanation, and only one of the two belongs beside a control.
    private let identityDetail = NSTextField(wrappingLabelWithString: "")
    private let identitySuccessor = NSTextField(wrappingLabelWithString: "")
    private let identityResetButton = ThemedButton()
    private let identityPrepareButton = ThemedButton()
    private let identityActivateButton = ThemedButton()
    private var identityTask: Task<Void, Never>?
    /// Lazy so a build without Hosted Direct never constructs Apple's sign-in button.
    private lazy var hostedSignInButton = HostedServiceSignInButton()
    private let hostedSignOutButton = ThemedButton()
    private let hostedDeleteAccountButton = ThemedButton()
    private let hostedStatusLabel = NSTextField(labelWithString: "")
    private let hostedAccountControls = NSStackView()
    private let inputControlDefault = ThemedSegmentedControl()
    private let phoneReportWorkspacePopUp = ThemedPopUp()
    private let macActivityWindowPopUp = ThemedPopUp()
    private let openLocallyButton = ThemedButton()
    private let pairingActionButton = ThemedButton()
    private let pairedDevicesStack = NSStackView()

    private let statusGlyph = NSTextField(labelWithString: "●")
    private let statusSpinner = ThemedSpinner()
    private let statusTitle = NSTextField(labelWithString: "")
    private let statusDetail = NSTextField(wrappingLabelWithString: "")

    private let pairingTitle = NSTextField(labelWithString: "")
    private let pairingSpinner = ThemedSpinner()
    private let pairingDetail = NSTextField(wrappingLabelWithString: "")
    private let pairingCode = NSImageView()
    private let hostedSpinner = ThemedSpinner()

    private var copiedReset: DispatchWorkItem?
    private var pairedDeviceIDs: [String] = []
    private let hostedAppleSignIn: RemoteHostedAppleSignIn?
    private var hostedAccountTask: Task<Void, Never>?
    private var hostedAccountError: String?
    private let appEvents = AppEventObservations()

    // MARK: - Lifecycle

    init(
        credentialStorageIsShellReachable: Bool = KeychainStoragePolicy.isShellReachable,
        hostedDirectIsOffered: Bool = AppSettings.shared.hostedDirectIsOffered
    ) {
        self.credentialStorageIsShellReachable = credentialStorageIsShellReachable
        self.hostedDirectIsOffered = hostedDirectIsOffered
        hostedAppleSignIn = hostedDirectIsOffered ? RemoteHostedAppleSignIn() : nil
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
        configureControls()
        buildPage()
        refresh()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // One `tailscale status` while somebody is looking at the page, and only while the
        // tailnet way in is on. The door itself needs no probe — it is bound or it is not — so
        // this is what sharpens "not connected" into "not installed" and supplies the MagicDNS
        // name. Not a timer, and nothing waits for it: the page redraws when it answers.
        RemoteAccessCoordinator.shared.refreshTailscaleHostFacts()
        refresh()
        // A sleep proxy is a property of the network this Mac is attached to, so the answer is
        // read when somebody is looking at it and when the door under it moves. Never on a
        // timer: it costs a child process and a multicast browse each time.
        readWakeOnDemandFacts(force: true)
    }

    deinit {
        wakeFactsTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Construction

    private func configureControls() {
        remoteAccessToggle.target = self
        remoteAccessToggle.action = #selector(remoteAccessChanged)
        remoteAccessToggle.setAccessibilityIdentifier("settings.remote-access.enabled")

        thisNetworkToggle.target = self
        thisNetworkToggle.action = #selector(thisNetworkDoorChanged)
        thisNetworkToggle.setAccessibilityIdentifier(Identifier.doorToggle(.thisNetwork))
        thisNetworkToggle.setAccessibilityLabel(RemoteAccessWayIn.thisNetwork.title)

        tailscaleToggle.target = self
        tailscaleToggle.action = #selector(tailscaleDoorChanged)
        tailscaleToggle.setAccessibilityIdentifier(Identifier.doorToggle(.tailscale))
        tailscaleToggle.setAccessibilityLabel(RemoteAccessWayIn.tailscale.title)

        discoveryToggle.target = self
        discoveryToggle.action = #selector(discoveryChanged)
        discoveryToggle.setAccessibilityIdentifier(Identifier.discoveryToggle)
        discoveryToggle.setAccessibilityLabel(L10n.string("Announce on this network"))
        announcedGlyph.applyFont(.subheading)
        announcedGlyph.setContentHuggingPriority(.required, for: .horizontal)
        announcedLabel.applyFont(.subheading)
        announcedLabel.textColor = Design.Text.secondary
        announcedLabel.setAccessibilityIdentifier(Identifier.announcedName)
        wakeGlyph.applyFont(.subheading)
        wakeGlyph.setContentHuggingPriority(.required, for: .horizontal)
        wakeGlyph.setAccessibilityIdentifier(Identifier.wakeOnDemandMark)
        wakeLabel.applyFont(.subheading)
        wakeLabel.textColor = Design.Text.secondary
        wakeLabel.setAccessibilityIdentifier(Identifier.wakeOnDemand)

        tailscaleServeToggle.target = self
        tailscaleServeToggle.action = #selector(tailscaleServeChanged)
        tailscaleServeToggle.setAccessibilityIdentifier(Identifier.serveToggle)
        tailscaleServeToggle.setAccessibilityLabel(L10n.string("Open in a browser on your tailnet"))

        tailscaleServeRemedyButton.target = self
        tailscaleServeRemedyButton.action = #selector(openServeRemedy)
        tailscaleServeRemedyButton.isHidden = true
        tailscaleServeRemedyButton.setContentHuggingPriority(.required, for: .horizontal)
        tailscaleServeRemedyButton.setContentCompressionResistancePriority(
            .required,
            for: .horizontal
        )
        tailscaleServeRemedyButton.setAccessibilityIdentifier(Identifier.serveRemedy)

        // The caption names what the 26 characters are *for* in one line, so the code under the
        // instruction reads as part of the same setup step rather than as a serial number.
        identityCaption.stringValue = L10n.string("Your phone compares this code")
        identityCaption.applyFont(.subheading)
        identityCaption.textColor = Design.Text.tertiary
        identityCaption.setAccessibilityIdentifier(Identifier.identityCaption)
        identityCode.applyFont(.code())
        identityCode.textColor = Design.Text.label
        identityCode.isSelectable = true
        identityCode.lineBreakMode = .byCharWrapping
        identityCode.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        identityCode.setAccessibilityIdentifier("settings.remote-access.identity-code")
        identityDetail.applyFont(.subheading)
        identityDetail.textColor = Design.Text.secondary
        identityDetail.setAccessibilityIdentifier("settings.remote-access.identity-detail")
        identitySuccessor.applyFont(.subheading)
        identitySuccessor.textColor = Design.Text.secondary
        identitySuccessor.setAccessibilityIdentifier("settings.remote-access.identity-successor")

        identityResetButton.title = L10n.string("Reset Identity…")
        identityResetButton.target = self
        identityResetButton.action = #selector(resetIdentity)
        identityResetButton.setAccessibilityIdentifier("settings.remote-access.identity-reset")
        identityPrepareButton.title = L10n.string("Prepare Rotation")
        identityPrepareButton.target = self
        identityPrepareButton.action = #selector(prepareIdentityRotation)
        identityPrepareButton.setAccessibilityIdentifier("settings.remote-access.identity-prepare")
        identityActivateButton.title = L10n.string("Activate Rotation")
        identityActivateButton.target = self
        identityActivateButton.action = #selector(activateIdentityRotation)
        identityActivateButton.setAccessibilityIdentifier(
            "settings.remote-access.identity-activate"
        )

        if hostedDirectIsOffered { configureHostedAccountControls() }

        inputControlDefault.configure(
            titles: RemoteInputControlDefault.allCases.map(\.title),
            selectedIndex: RemoteInputControlDefault.allCases.firstIndex(
                of: AppSettings.shared.remoteInputControlDefault
            ) ?? 0
        )
        inputControlDefault.onSelect = { index in
            guard RemoteInputControlDefault.allCases.indices.contains(index) else { return }
            AppSettings.shared.remoteInputControlDefault =
                RemoteInputControlDefault.allCases[index]
        }
        inputControlDefault.setAccessibilityIdentifier(
            "settings.remote-access.input-control-default"
        )
        // The measure the run *wants*, not a contract. Required, it was 380 points of a 300-point
        // row, and the sentence beside it was pinned to what was left: a subtitle one character
        // wide, wrapping down the card for eleven lines. The content pane stops at 320 points, so
        // that is a pane somebody can actually drag to. A truncated run of two choices is
        // legible; a column of single letters is not. This is where a squeeze is answered — a
        // floor on the words instead would only push this control out of the card.
        SettingsUI.preferControlWidth(
            inputControlDefault,
            width: SettingsUIDefaults.wideSegmentedControlWidth
        )

        for policy in PhoneReportWorkspacePolicy.allCases {
            phoneReportWorkspacePopUp.addItem(
                ThemedMenuItem(title: policy.settingsTitle, representedValue: policy)
            )
        }
        phoneReportWorkspacePopUp.selectItem(
            at: PhoneReportWorkspacePolicy.allCases
                .firstIndex(of: AppSettings.shared.phoneReportWorkspace) ?? 0
        )
        phoneReportWorkspacePopUp.target = self
        phoneReportWorkspacePopUp.action = #selector(phoneReportWorkspaceChanged)
        phoneReportWorkspacePopUp.setAccessibilityIdentifier(
            "settings.remote-access.phone-report-workspace"
        )

        for window in MacNotificationActivityWindow.allCases {
            macActivityWindowPopUp.addItem(
                ThemedMenuItem(title: window.settingsTitle, representedValue: window)
            )
        }
        macActivityWindowPopUp.target = self
        macActivityWindowPopUp.action = #selector(macActivityWindowChanged)
        macActivityWindowPopUp.setAccessibilityIdentifier(
            "settings.remote-access.mac-activity-window"
        )

        openLocallyButton.title = L10n.string("Open in Browser")
        openLocallyButton.target = self
        openLocallyButton.action = #selector(openLocally)
        openLocallyButton.setAccessibilityIdentifier("settings.remote-access.open-local")

        pairingActionButton.target = self
        pairingActionButton.action = #selector(pairingAction)
        pairingActionButton.setAccessibilityIdentifier("settings.remote-access.pair")

        statusGlyph.applyFont(.body)
        statusGlyph.setContentHuggingPriority(.required, for: .horizontal)

        statusTitle.applyFont(.body)
        statusTitle.textColor = Design.Text.label
        statusTitle.setAccessibilityIdentifier("settings.remote-access.status")

        statusDetail.applyFont(.subheading)
        statusDetail.textColor = Design.Text.secondary

        // A card's title, at body scale: the page already has one heading, and a second one
        // inside a card is what made this read as a poster rather than as a settings card.
        pairingTitle.applyFont(.emphasizedBody)
        pairingTitle.textColor = Design.Text.label
        pairingTitle.setAccessibilityIdentifier("settings.remote-access.pairing-title")
        // Both single-line labels beside a code that cannot shrink. A squeezed pane truncates
        // them rather than clipping them mid-glyph with nothing to say it did.
        for label in [pairingTitle, identityCaption] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        pairingDetail.applyFont(.subheading)
        pairingDetail.textColor = Design.Text.secondary
        pairingDetail.setAccessibilityIdentifier("settings.remote-access.pairing-detail")

        pairingCode.imageScaling = .scaleProportionallyUpOrDown
        pairingCode.translatesAutoresizingMaskIntoConstraints = false
        pairingCode.setAccessibilityIdentifier("settings.remote-access.qr-code")

        pairedDevicesStack.orientation = .vertical
        pairedDevicesStack.alignment = .leading
        pairedDevicesStack.spacing = 0

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(remoteAccessStatusDidChange),
            name: RemoteAccessCoordinator.statusDidChange,
            object: nil
        )

        // The pairing code is drawn from the palette, and an `NSImage` handed to an image view
        // is not repainted by a repaint of the view — so it is rebuilt rather than refreshed.
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in self?.refresh() }
    }

    /// The page, in the order somebody sets this up in: pair the phone, see whether anything can
    /// reach this Mac, choose a way in, then decide what is shared.
    ///
    /// It used to run the other way — a connection card, three way-in cards each carrying four
    /// questions, a readiness card duplicating one of them, and the pairing code below all of it.
    /// The thing the page exists for was the last thing on it, and everything above it was prose.
    private func buildPage() {
        let page = SettingsUI.page(
            title: "Remote Access",
            summary: "Continue chats from Threading on iPhone or a private browser.",
            sections: [
                SettingsUI.section("Set Up Your iPhone", heroCard()),
                SettingsUI.section("Connection", connectionCard()),
                SettingsUI.section("Ways In", waysInSection()),
                SettingsUI.section("Notification Delivery", notificationDeliveryCard()),
                SettingsUI.section("Sharing & Security", securityCard()),
                SettingsUI.note(
                    "Remote Access publishes only Threading’s authenticated remote surface. "
                        + "MCP, extension services and other local ports stay on this Mac."
                )
            ]
        )
        page.setAccessibilityIdentifier("settings.remote-access.page")
        page.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: view.topAnchor),
            page.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    // MARK: - Hero

    /// The code, and the identity the code is a fingerprint of, as one thing.
    ///
    /// They were two cards a page apart, which is exactly backwards: the 26 characters under the
    /// QR are what the phone compares against the certificate the QR carries, so a person reading
    /// one is reading the other. The prose that used to sit between them — what pinning is, what
    /// an owner code costs — is behind the "?" beside the title, one press away and complete.
    private func heroCard() -> SettingsCard {
        let heading = NSStackView(views: [
            pairingTitle,
            pairingSpinner,
            HelpPopoverButton(topic: Self.pairingHelp)
        ])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = Design.Spacing.small

        let identity = NSStackView(views: [identityCaption, identityCode])
        identity.orientation = .vertical
        identity.alignment = .leading
        identity.spacing = Design.Spacing.hairline

        let actions = NSStackView(views: [pairingActionButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = Design.Spacing.small

        let text = NSStackView(views: [
            heading,
            pairingDetail,
            identity,
            identityDetail,
            identitySuccessor,
            actions
        ])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = Design.Spacing.medium
        // A vertical stack aligned `.leading` gives each arranged view its *fitting* width, and
        // a wrapping label has none to give — so every paragraph is pinned to the column it sits
        // in, or it wraps at whatever width it happens to prefer.
        text.setHuggingPriority(.defaultLow, for: .horizontal)
        // A stack has no intrinsic height of its own, so beside a 168pt code it was handed the
        // code's height and spread its rows through it: the title floated a quarter of the way
        // down the card and the gaps came out uneven where all of them are meant to be `medium`.
        // Hugging vertically is what makes the column its content's height and the spacing the
        // token that states it.
        for stack in [heading, identity, actions, text] {
            stack.setHuggingPriority(.required, for: .vertical)
        }

        let content = NSStackView(views: [pairingCode, text])
        content.orientation = .horizontal
        // The code is a block; the text beside it starts at its first line.
        content.alignment = .top
        content.distribution = .fill
        content.spacing = Design.Spacing.large

        NSLayoutConstraint.activate([
            pairingCode.widthAnchor.constraint(equalToConstant: PairingCardLayout.codeSide),
            pairingCode.heightAnchor.constraint(equalTo: pairingCode.widthAnchor),
            pairingDetail.widthAnchor.constraint(equalTo: text.widthAnchor),
            identityDetail.widthAnchor.constraint(equalTo: text.widthAnchor),
            identitySuccessor.widthAnchor.constraint(equalTo: text.widthAnchor),
            // The code is a wrapping label too, so it is stated like the others rather than left
            // to hug. Left to itself it took the column in a tree laid out once and its own 177
            // points in a window, which is the same coin toss `fillingColumn(_:spacing:)`
            // describes — and the one the fixture and the app disagreed about. The line is
            // leading-aligned either way, so stating it changes no pixel and settles the layout.
            identityCode.widthAnchor.constraint(equalTo: text.widthAnchor)
        ])
        pairingCode.setContentHuggingPriority(.required, for: .horizontal)
        pairingCode.setContentCompressionResistancePriority(.required, for: .horizontal)

        let identityActions = SettingsUI.controlGroup(
            [identityPrepareButton, identityActivateButton, identityResetButton],
            spacing: Design.Spacing.small
        )
        // Three sibling buttons on one row share their width. Equal at a priority every real
        // constraint outranks, so nothing about the wide layout is forced — and in a squeezed
        // pane the pressure is spread across all three, each truncating its own title, instead
        // of the solver picking one to crush into a sliver while its neighbours stay whole.
        for button in [identityActivateButton, identityResetButton] {
            let equal = button.widthAnchor.constraint(
                equalTo: identityPrepareButton.widthAnchor
            )
            equal.priority = .defaultLow
            equal.isActive = true
        }

        return SettingsCard(rows: [
            SettingsUI.fullRow(content),
            SettingsUI.row(
                title: "Rotate or reset this Mac’s identity",
                help: Self.identityHelp,
                control: identityActions
            )
        ])
    }

    enum PairingCardLayout {
        /// The side the card gives the pairing code, which is also the side the image is drawn
        /// at — the plate `PairingCodeImage` draws *is* the quiet zone, so the plate is never
        /// wider than the code needs, and drawing at the displayed size keeps the modules from
        /// being resampled on the way down.
        ///
        /// 49 modules (41 plus the four-module quiet zone on each side) at 3.4 points each, so
        /// nearly 7 pixels per module on a 2x display against the 3.02 that
        /// `PairingCodeImageTests` measured as the floor for a tilted, softened decode.
        static let codeSide: CGFloat = 168
    }

    /// What the hero's "?" carries: the two things a person is entitled to read before they scan
    /// a code that grants owner access, and neither of which is a control's caption.
    private static var pairingHelp: HelpTopic {
        HelpTopic(
            title: L10n.string("Pairing this Mac"),
            paragraphs: [
                L10n.string(
                    "Only scan this owner code on a device you control. It can access every chat "
                        + "on this Mac. The code expires after one successful pairing; that "
                        + "device stays paired until you revoke it here."
                ),
                RemoteIdentityCardPresentation.explanation
            ]
        )
    }

    /// The two operations that change the certificate, and what each of them costs.
    private static var identityHelp: HelpTopic {
        HelpTopic(
            title: L10n.string("Rotate or reset this Mac’s identity"),
            paragraphs: [
                L10n.string(
                    "Prepare mints the next certificate and announces it over the connection "
                        + "your devices already trust. Activate switches to it, and a device "
                        + "that has connected since the announcement keeps working."
                ),
                L10n.string(
                    "Resetting throws the certificate away and mints a new one. Every paired "
                        + "device has to scan the new pairing code before it can connect again."
                )
            ]
        )
    }

    /// The Hosted Direct account row's controls. Configured only in a build that offers Hosted
    /// Direct, because the row that holds them exists only there.
    private func configureHostedAccountControls() {
        hostedSignInButton.configure(target: self, action: #selector(signInHostedService))
        hostedSignInButton.setAccessibilityIdentifier("settings.remote-access.hosted-sign-in")
        hostedSignOutButton.title = L10n.string("Sign Out")
        hostedSignOutButton.target = self
        hostedSignOutButton.action = #selector(signOutHostedService)
        hostedSignOutButton.setAccessibilityIdentifier("settings.remote-access.hosted-sign-out")
        hostedDeleteAccountButton.title = L10n.string("Delete Account")
        hostedDeleteAccountButton.target = self
        hostedDeleteAccountButton.action = #selector(deleteHostedServiceAccount)
        hostedDeleteAccountButton.setAccessibilityIdentifier(
            "settings.remote-access.hosted-delete-account"
        )
        hostedStatusLabel.applyFont(.subheading)
        hostedStatusLabel.textColor = Design.Text.secondary
        hostedSpinner.setAccessibilityLabel(L10n.string("Connecting…"))
        hostedAccountControls.orientation = .horizontal
        hostedAccountControls.alignment = .centerY
        hostedAccountControls.spacing = Design.Spacing.small
        hostedAccountControls.addArrangedSubview(hostedSpinner)
        hostedAccountControls.addArrangedSubview(hostedStatusLabel)
        hostedAccountControls.addArrangedSubview(hostedSignInButton)
        hostedAccountControls.addArrangedSubview(hostedSignOutButton)
        hostedAccountControls.addArrangedSubview(hostedDeleteAccountButton)
    }

    // MARK: - Connection

    private func connectionCard() -> SettingsCard {
        var rows: [NSView] = [
            SettingsUI.row(
                title: "Remote Access",
                subtitle: "Turning it off closes every connection and shared-chat link.",
                help: HelpTopic(
                    title: L10n.string("Remote Access"),
                    paragraphs: [
                        L10n.string(
                            "Your explicitly paired devices remain paired for the next time."
                        )
                    ]
                ),
                control: remoteAccessToggle
            )
        ]
        // A public build cannot carry the Sign in with Apple entitlement, so it offers no sign-in
        // row rather than a button that could never enroll this Mac.
        if hostedDirectIsOffered {
            rows.append(SettingsUI.row(
                title: "Hosted Direct",
                subtitle: "Uses Threading’s service only to introduce this Mac and iPhone.",
                help: HelpTopic(
                    title: L10n.string("Hosted Direct"),
                    paragraphs: [
                        L10n.string(
                            "It then prefers a direct encrypted connection. TURN is used only "
                                + "when direct network traversal cannot connect."
                        )
                    ]
                ),
                control: hostedAccountControls
            ))
        }
        rows.append(SettingsUI.fullRow(connectionStatusRow()))
        return SettingsCard(rows: rows)
    }

    private func connectionStatusRow() -> NSView {
        let labels = fillingColumn([statusTitle, statusDetail], spacing: Design.Spacing.hairline)

        let row = NSStackView(views: [
            markSlot(glyph: statusGlyph, spinner: statusSpinner),
            labels,
            openLocallyButton
        ])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Design.Spacing.medium
        return row
    }

    // MARK: - Ways in

    /// The run of ways in, over the one panel it selects.
    private func waysInSection() -> NSView {
        waysInHost.translatesAutoresizingMaskIntoConstraints = false
        // A search result naming a row on a way in nobody is looking at still has to arrive at
        // it. See `SettingsRowRevealing`.
        waysInHost.onReveal = { [weak self] title in self?.showWayIn(carrying: title) ?? false }
        rebuildWaysInCard()
        return waysInHost
    }

    /// Selects the way in whose panel carries `title`, for a reveal that could not find it.
    ///
    /// It answers by trying each segment and asking the page, rather than by holding a list of
    /// which row belongs to which way in. A list would be a second statement of what
    /// `waysInRows()` already builds, and a row moved from one panel to another would leave the
    /// search pointing at the panel it came from with nothing to say it had.
    private func showWayIn(carrying title: String) -> Bool {
        let original = selectedWayIn
        for wayIn in waysIn where wayIn != original {
            select(wayIn)
            view.layoutSubtreeIfNeeded()
            if SettingsRowAnchor.find(title: title, in: view) != nil { return true }
        }
        select(original)
        return false
    }

    /// Builds the card for whichever way in is selected.
    ///
    /// Everything the panel shows is created here, including the status views the page writes
    /// into, so the last thing this does is hand the current values back to the new views. A page
    /// driven entirely by `apply(_:)` — which is what makes every state photographable — must
    /// never reach for the coordinator to repaint itself.
    private func rebuildWaysInCard() {
        waysInCard?.removeFromSuperview()
        wayInStatusViews.removeAll()
        tailscaleServeStatusViews = nil
        announcedRow = nil

        waysInControl.configure(
            titles: waysIn.map(\.title),
            marks: waysIn.map { segmentMark(for: $0) },
            selectedIndex: waysIn.firstIndex(of: selectedWayIn) ?? 0
        )
        waysInControl.onSelect = { [weak self] index in
            guard let self, waysIn.indices.contains(index) else { return }
            selectedWayIn = waysIn[index]
            rebuildWaysInCard()
        }
        waysInControl.setAccessibilityIdentifier(Identifier.waysInControl)
        waysInControl.setAccessibilityLabel(L10n.string("Ways In"))

        let card = SettingsCard(rows: [SettingsUI.fullRow(waysInControl)] + waysInRows())
        card.translatesAutoresizingMaskIntoConstraints = false
        waysInHost.addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: waysInHost.topAnchor),
            card.bottomAnchor.constraint(equalTo: waysInHost.bottomAnchor),
            card.leadingAnchor.constraint(equalTo: waysInHost.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: waysInHost.trailingAnchor)
        ])
        waysInCard = card
        builtWaysIn = waysIn
        builtSelection = selectedWayIn

        applyWayIns()
    }

    /// One way in's panel: what it is, its switch, what it is doing, and its own sub-rows.
    private func waysInRows() -> [NSView] {
        let wayIn = selectedWayIn
        // The copy arrives already localized from `RemoteAccessWayIn`, so the row must not look
        // it up a second time: under a translated build that lookup takes the Swedish sentence
        // as a key and finds nothing.
        var rows: [NSView] = [
            SettingsUI.row(
                title: wayIn.title,
                subtitle: wayIn.promise,
                help: Self.help(for: wayIn),
                control: toggle(for: wayIn),
                localizes: false
            ),
            SettingsUI.fullRow(statusRow(for: wayIn))
        ]
        switch wayIn {
        case .thisNetwork:
            // The announcement and what it buys belong to this way in and to no other: only the
            // LAN listeners carry it, and only a Mac on the same network can be woken by one.
            rows.append(contentsOf: discoveryRows())
            // "Through a VPN" is the same way in reached from a tunnel, so it belongs to the
            // network panel rather than to a segment of its own. It keeps its own four lines,
            // because a way in never appears without them.
            rows.append(throughAVPNRow())
        case .tailscale:
            rows.append(contentsOf: tailscaleServeRows())
        case .throughAVPN, .threadingDirect:
            break
        }
        return rows
    }

    private func toggle(for wayIn: RemoteAccessWayIn) -> NSView? {
        switch wayIn {
        case .thisNetwork: return thisNetworkToggle
        case .tailscale: return tailscaleToggle
        case .throughAVPN, .threadingDirect: return nil
        }
    }

    /// The four questions a way in answers, plus whatever else it has to say, behind its "?".
    ///
    /// The four lines are still never optional and still in the same order and the same words.
    /// What changed is where they are: on the page they were three quarters of its height and
    /// were being scrolled past, and behind a press they are one press from the name they belong
    /// to and in the button's accessibility help for a reader who presses nothing.
    static func help(for wayIn: RemoteAccessWayIn) -> HelpTopic {
        HelpTopic(
            title: wayIn.title,
            lines: wayIn.disclosure.lines.map {
                HelpTopic.Line(term: $0.question, detail: $0.answer)
            },
            paragraphs: wayIn.note.map { [$0] } ?? []
        )
    }

    /// The VPN, as a note inside the network panel.
    private func throughAVPNRow() -> NSView {
        SettingsUI.row(
            title: RemoteAccessWayIn.throughAVPN.title,
            subtitle: RemoteAccessWayIn.throughAVPN.promise,
            help: Self.help(for: .throughAVPN),
            localizes: false
        )
    }

    /// The announcement's switch and the two facts that follow from it.
    ///
    /// It is not a way in: the door works without it and closing it changes nothing about who can
    /// reach this Mac. What it changes is whether a paired phone can still find the Mac after the
    /// router hands it a new address, and whether a connection can wake it.
    ///
    /// The exact payload is behind the "?" rather than in the subtitle. A broadcast is visible to
    /// everyone on the network, so the person switching it on is entitled to read exactly what
    /// leaves this Mac — which is why it is one press away and complete, and not why it should be
    /// four lines of the page for everybody who has already decided.
    private func discoveryRows() -> [NSView] {
        let row = SettingsUI.row(
            title: "Announce on this network",
            subtitle: "Lets a paired iPhone find this Mac after its address changes.",
            help: HelpTopic(
                title: L10n.string("Announce on this network"),
                paragraphs: [
                    L10n.string(
                        "Broadcasts an opaque name, this Mac’s id, its protocol version and its "
                            + "certificate fingerprint, so a paired iPhone can find this Mac "
                            + "after its address changes. Never the computer name and never your "
                            + "name, and pairing still needs the code."
                    )
                ]
            ),
            control: discoveryToggle
        )

        let announced = factRow(glyph: announcedGlyph, spinner: announcedSpinner, label: announcedLabel)
        announcedRow = announced
        let wake = factRow(glyph: wakeGlyph, spinner: wakeSpinner, label: wakeLabel)

        let facts = NSStackView(views: [announced, wake])
        facts.orientation = .vertical
        facts.alignment = .leading
        facts.spacing = Design.Spacing.small
        // Both fact rows take the card's width, for the reason `fillingColumn(_:spacing:)` gives:
        // a vertical stack aligned `.leading` hands each row its fitting width, and a row whose
        // only wide thing is a wrapping label has none worth having.
        //
        // **A preference, and the priority is the whole point.** Required, this crushed the page.
        // The announcement leaves the card by hiding its label *and* its row, and a hidden view
        // leaves an `NSStackView`'s layout while its constraints stay active — so the row became
        // its 14-point mark slot, `row.width == facts.width` handed that 14 to the column, and
        // the column handed it up a chain of required edges to the card, the section and the
        // page. Every state without an announcement laid out against a broken required
        // constraint, which is a width nobody chose: 532 points inside a 1,124-point canvas.
        for fact in [announced, wake] {
            let pin = fact.widthAnchor.constraint(equalTo: facts.widthAnchor)
            pin.priority = NSLayoutConstraint.Priority(
                NSLayoutConstraint.Priority.defaultLow.rawValue + 1
            )
            pin.isActive = true
        }
        return [row, SettingsUI.fullRow(facts)]
    }

    /// One announced fact: the mark, then the line, on the status column above it.
    private func factRow(
        glyph: NSTextField,
        spinner: ThemedSpinner,
        label: NSTextField
    ) -> NSStackView {
        label.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [markSlot(glyph: glyph, spinner: spinner), label])
        row.orientation = .horizontal
        row.alignment = .top
        row.distribution = .fill
        row.spacing = Design.Spacing.medium
        return row
    }

    /// The Serve sub-option, under the tailnet way in.
    ///
    /// It is a sub-option and not a way in: the phone reaches this Mac at the tailnet address the
    /// listener binds, with the certificate it pinned, so nothing here is a route. What Serve buys
    /// is the one thing a pinned self-signed identity cannot give a *browser* — a publicly trusted
    /// certificate for the `*.ts.net` name — and what it costs is a public certificate-transparency
    /// entry naming this Mac and the tailnet, which is why the cost is one press from the switch
    /// rather than in a document.
    private func tailscaleServeRows() -> [NSView] {
        let row = SettingsUI.row(
            title: "Open in a browser on your tailnet",
            subtitle: "Lets a browser on your tailnet open Threading without a certificate "
                + "warning. The Threading app does not need this.",
            help: HelpTopic(
                title: L10n.string("Open in a browser on your tailnet"),
                paragraphs: [
                    L10n.string(
                        "Turning it on publishes this Mac’s name and your tailnet name in public "
                            + "certificate logs."
                    )
                ]
            ),
            control: tailscaleServeToggle
        )
        return [row, SettingsUI.fullRow(serveStatusRow())]
    }

    /// Serve's own status line, with the admin-console page that fixes it beside the sentence.
    private func serveStatusRow() -> NSView {
        let views = statusViews(
            statusIdentifier: Identifier.serveStatus,
            markIdentifier: Identifier.serveStatusMark,
            hintIdentifier: Identifier.serveStatusHint
        )
        tailscaleServeStatusViews = views
        return statusRow(views, action: tailscaleServeRemedyButton)
    }

    /// One way in's live status: a mark, the fact, and the remedy when the fact alone does not
    /// say what to do about it.
    private func statusRow(for wayIn: RemoteAccessWayIn) -> NSView {
        let views = statusViews(
            statusIdentifier: Identifier.status(wayIn),
            markIdentifier: Identifier.statusMark(wayIn),
            hintIdentifier: Identifier.statusHint(wayIn)
        )
        wayInStatusViews[wayIn] = views
        return statusRow(views, action: nil)
    }

    private func statusViews(
        statusIdentifier: String,
        markIdentifier: String,
        hintIdentifier: String
    ) -> WayInStatusViews {
        let glyph = NSTextField(labelWithString: DoorMark.idle)
        glyph.applyFont(.body)
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        glyph.setAccessibilityIdentifier(markIdentifier)

        let text = NSTextField(wrappingLabelWithString: "")
        text.applyFont(.body)
        text.textColor = Design.Text.label
        text.setAccessibilityIdentifier(statusIdentifier)

        let hint = NSTextField(wrappingLabelWithString: "")
        hint.applyFont(.subheading)
        hint.textColor = Design.Text.secondary
        hint.setAccessibilityIdentifier(hintIdentifier)

        // Neither line argues for a width of its own: see `fillingColumn(_:)`.
        for label in [text, hint] {
            label.setContentHuggingPriority(.init(1), for: .horizontal)
        }
        return WayInStatusViews(glyph: glyph, spinner: ThemedSpinner(), text: text, hint: hint)
    }

    private func statusRow(_ views: WayInStatusViews, action: NSView?) -> NSView {
        let labels = fillingColumn([views.text, views.hint], spacing: Design.Spacing.hairline)

        var members: [NSView] = [
            markSlot(glyph: views.glyph, spinner: views.spinner),
            labels
        ]
        if let action { members.append(action) }

        let row = NSStackView(views: members)
        row.orientation = .horizontal
        row.alignment = .top
        row.distribution = .fill
        row.spacing = Design.Spacing.medium
        return row
    }

    /// A column of wrapping lines that takes the width it is given, rather than the width it
    /// happens to prefer.
    ///
    /// **A wrapping `NSTextField` hugs horizontally at `.defaultLow`, which is the same priority
    /// a low-hugging label column uses to claim its row's slack.** Two constraints at 250 wanting
    /// opposite things is not a layout, and the engine settled it differently depending on how
    /// many passes the tree had been through: laid out once in a detached fixture every status
    /// line spanned its card, and the same page in a window gave each line its own fitting width.
    /// The render tests photographed the first and the app drew the second, which is most of what
    /// "it doesn't look like your image" was. Stating both halves — no opinion from the label, an
    /// equal-width pin from the column — leaves nothing for a later pass to decide.
    private func fillingColumn(_ labels: [NSTextField], spacing: CGFloat) -> NSStackView {
        let column = NSStackView(views: labels)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = spacing
        column.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for label in labels {
            label.setContentHuggingPriority(.init(1), for: .horizontal)
            // The pin the comment above is about. A preference rather than a requirement: in a
            // squeezed pane the row's own edges win, and a status line that ran a few points
            // past its column is better than one the solver had to break a card to satisfy.
            let pin = label.widthAnchor.constraint(equalTo: column.widthAnchor)
            pin.priority = NSLayoutConstraint.Priority(
                NSLayoutConstraint.Priority.defaultLow.rawValue + 1
            )
            pin.isActive = true
        }
        return column
    }

    /// One fixed-width slot holding a step's glyph and its in-flight spinner, so swapping the
    /// mark never shifts the text beside it — `SessionStatusIndicator`'s reserved-slot rule.
    /// The spinner hides itself while it is not animating; the glyph is hidden by the state
    /// that animates the spinner.
    private func markSlot(glyph: NSTextField, spinner: ThemedSpinner) -> NSView {
        let slot = NSView()
        slot.translatesAutoresizingMaskIntoConstraints = false
        glyph.translatesAutoresizingMaskIntoConstraints = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        slot.addSubview(glyph)
        slot.addSubview(spinner)
        NSLayoutConstraint.activate([
            slot.widthAnchor.constraint(
                equalToConstant: spinner.intrinsicContentSize.width
            ),
            glyph.topAnchor.constraint(equalTo: slot.topAnchor),
            glyph.bottomAnchor.constraint(equalTo: slot.bottomAnchor),
            glyph.centerXAnchor.constraint(equalTo: slot.centerXAnchor),
            spinner.centerXAnchor.constraint(equalTo: slot.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: slot.centerYAnchor)
        ])
        return slot
    }

    // MARK: - Sharing

    private func notificationDeliveryCard() -> SettingsCard {
        SettingsCard(rows: [
            SettingsUI.row(
                title: "Mac activity window",
                subtitle: "While this Mac is in use, in any app, routine turn-completion alerts "
                    + "stay off your paired devices for this long after its last input. Locking "
                    + "the screen ends that at once. Off never uses Mac activity to suppress "
                    + "them.",
                control: macActivityWindowPopUp
            )
        ])
    }

    private func securityCard() -> SettingsCard {
        let credentialStorage = RemoteCredentialStoragePresentation.resolve(
            isShellReachable: credentialStorageIsShellReachable
        )
        return SettingsCard(rows: [
            SettingsUI.row(
                title: "New shared chats",
                subtitle: "Collaborative lets everyone with reply access send. Focused starts "
                    + "with the Mac owner in control.",
                help: HelpTopic(
                    title: L10n.string("New shared chats"),
                    paragraphs: [L10n.string("You can switch a live chat at any time.")]
                ),
                control: inputControlDefault
            ),
            SettingsUI.row(
                title: "Reports from your phone",
                subtitle: "Shake to report, then Send to Mac, starts a chat here while you are "
                    + "away from it.",
                help: HelpTopic(
                    title: L10n.string("Reports from your phone"),
                    paragraphs: [
                        L10n.string(
                            "Its own workspace keeps that chat out of the checkout you left "
                                + "open. Available for a Git project whose agent has session "
                                + "tools."
                        )
                    ]
                ),
                control: phoneReportWorkspacePopUp
            ),
            SettingsUI.detailRow(
                symbol: "lock.shield",
                title: "Your own devices",
                detail: "The QR code is owner access.",
                help: HelpTopic(
                    title: L10n.string("Your own devices"),
                    paragraphs: [
                        L10n.string(
                            "A paired device can see and manage your chats, send prompts, and "
                                + "review permission requests."
                        )
                    ]
                )
            ),
            SettingsUI.detailRow(
                symbol: "person.2",
                title: "Other people",
                detail: "Use Share Chat… from that chat’s ⋯ menu.",
                help: HelpTopic(
                    title: L10n.string("Other people"),
                    paragraphs: [
                        L10n.string(
                            "It grants only the selected chat, with view, collaboration and "
                                + "approval rights chosen separately. The invitation points at a "
                                + "way in above, so the person needs the Threading app and a way "
                                + "onto that network."
                        )
                    ]
                )
            ),
            SettingsUI.detailRow(
                symbol: "key.fill",
                title: credentialStorage.title,
                detail: credentialStorage.detail,
                localizes: false
            ),
            pairedDevicesStack
        ])
    }

    // MARK: - State

    @objc private func remoteAccessStatusDidChange(_ notification: Notification) {
        refresh()
        readWakeOnDemandFacts()
    }

    private func refresh() {
        copiedReset?.cancel()
        copiedReset = nil

        let coordinator = RemoteAccessCoordinator.shared
        let doors = doorsPresentation(coordinator)
        inputControlDefault.selectedIndex = RemoteInputControlDefault.allCases.firstIndex(
            of: AppSettings.shared.remoteInputControlDefault
        ) ?? 0
        phoneReportWorkspacePopUp.selectItem(
            at: PhoneReportWorkspacePolicy.allCases
                .firstIndex(of: AppSettings.shared.phoneReportWorkspace) ?? 0
        )
        macActivityWindowPopUp.selectItem(
            at: MacNotificationActivityWindow.allCases.firstIndex(
                of: AppSettings.shared.remoteNotificationMacActivityWindow
            ) ?? 0
        )
        openLocallyButton.isHidden = coordinator.localURL == nil
        openLocallyButton.isEnabled = coordinator.localURL != nil
        rebuildPairedDevices(coordinator.pairedOwnerDevices, error: coordinator.ownerDevicePersistenceError)
        if hostedDirectIsOffered { updateHostedAccount(coordinator) }
        apply(doors)
        apply(discoveryPresentation(coordinator))

        switch coordinator.status {
        case .disabled:
            updateConnection(
                title: L10n.string("Off"),
                detail: L10n.string("This Mac is not reachable from another device."),
                color: Design.Text.tertiary
            )
            updatePairing(
                title: L10n.string("Connect your iPhone"),
                detail: L10n.string(
                    "Turn on Remote Access. Threading starts a local mirror and answers on the "
                    + "ways in you have switched on below."
                ),
                action: L10n.string("Turn On Remote Access"),
                actionEnabled: true,
                prominent: true
            )

        case .starting:
            updateConnection(
                title: L10n.string("Starting"),
                detail: L10n.string("Preparing the private listener on this Mac…"),
                color: Design.Status.warning,
                busy: true
            )
            updatePairing(
                title: L10n.string("Preparing your connection"),
                detail: L10n.string("This usually takes only a few seconds."),
                action: L10n.string("Starting…"),
                actionEnabled: false,
                prominent: false,
                busy: true
            )

        case .listening(let port):
            applyListeningState(
                connection: RemoteConnectionStatusPresentation.resolve(
                    statuses: doors.offeredStatuses,
                    localPort: port
                ),
                card: RemotePairingCardState.resolve(
                    ownerDevicePersistenceError: coordinator.ownerDevicePersistenceError,
                    pairingCodePayload: coordinator.pairingCodePayload,
                    wayIn: RemotePairingCardState.mostAdvanced(of: doors.offeredStatuses),
                    hasWayIn: coordinator.hasEnabledWayIn
                )
            )

        case .failed(let reason):
            // The reason is already a sentence with a remedy in it; a page that wrapped it in
            // "The private listener failed (portRangeInUse)" was printing a diagnostic token.
            updateConnection(
                title: L10n.string("Couldn’t start"),
                detail: reason,
                color: Design.Status.negative
            )
            updatePairing(
                title: L10n.string("Remote Access needs attention"),
                detail: L10n.string(
                    "Retry without leaving Settings. Existing launch links remain revoked."
                ),
                action: L10n.string("Try Again"),
                actionEnabled: true,
                prominent: true
            )
        }
    }

    /// What the ways in are doing, read from the coordinator once.
    ///
    /// Every value the page prints comes through here, which is what lets the render tests
    /// photograph a bound LAN address, a Mac with no interface and a firewall that may be
    /// swallowing connections without any of them existing on the machine running the test.
    private func doorsPresentation(
        _ coordinator: RemoteAccessCoordinator
    ) -> RemoteAccessDoorsPresentation {
        let isOn = AppSettings.shared.remoteAccessEnabled
        let doorState = coordinator.tailscaleDoorState
        let facts = coordinator.tailscaleHostFacts
        var statuses: [RemoteAccessWayIn: RemoteDoorStatus] = [:]
        var serve: RemoteDoorStatus?
        if isOn {
            statuses[.thisNetwork] = .thisNetwork(
                isEnabled: coordinator.isThisNetworkDoorEnabled,
                state: coordinator.thisNetworkDoorState,
                firewall: coordinator.listenerStatus.firewall
            )
            statuses[.tailscale] = .tailscale(
                isEnabled: coordinator.isTailscaleDoorEnabled,
                state: doorState,
                facts: facts
            )
            if hostedDirectIsOffered {
                statuses[.threadingDirect] = .threadingDirect(coordinator.hostedServiceState)
            }
            serve = .tailscaleServe(
                isEnabled: coordinator.isTailscaleServeEnabled,
                transport: coordinator.tailscaleServeStatus,
                readiness: coordinator.tailscaleServeReadiness
            )
        } else {
            for wayIn in RemoteAccessWayIn.allCases where wayIn != .throughAVPN
                && (wayIn != .threadingDirect || hostedDirectIsOffered) {
                statuses[wayIn] = .remoteAccessOff()
            }
            serve = .remoteAccessOff()
        }
        return RemoteAccessDoorsPresentation(
            isRemoteAccessOn: isOn,
            thisNetworkIsOn: coordinator.isThisNetworkDoorEnabled,
            tailscaleIsOn: coordinator.isTailscaleDoorEnabled,
            tailscaleServeIsOn: coordinator.isTailscaleServeEnabled,
            showsThreadingDirect: hostedDirectIsOffered
                && coordinator.canIssueHostedDeviceCredentials,
            statuses: statuses,
            serveStatus: serve,
            serveRemedy: RemoteDoorStatus.serveRemedy(coordinator.tailscaleServeReadiness),
            tailnetReadiness: .resolve(
                isEnabled: isOn && coordinator.isTailscaleDoorEnabled,
                facts: facts,
                doorState: doorState,
                doorStatus: statuses[.tailscale] ?? .remoteAccessOff()
            ),
            identity: .resolve(coordinator.identitySnapshot)
        )
    }

    /// What is being announced, and whether a connection could wake this Mac.
    ///
    /// Read from the coordinator in one place for the same reason `doorsPresentation` is: a
    /// hosted test must not register a Bonjour service and cannot put a sleep proxy on the
    /// developer's network, so the page renders a value the tests can hand it instead.
    private func discoveryPresentation(
        _ coordinator: RemoteAccessCoordinator
    ) -> RemoteDiscoveryPresentation {
        RemoteDiscoveryPresentation(
            isEnabled: coordinator.isDiscoveryEnabled,
            announcedName: coordinator.advertisedService?.name,
            wakeFacts: coordinator.wakeOnDemand
        )
    }

    /// Reads the two wake facts, when there is a reason to.
    ///
    /// Never on a timer, and not on every status change either: `wakeOnDemand` posts the same
    /// notification when it lands, so an unconditional refresh from the observer would ask again
    /// for every answer it received. The `lan` door's own state is the trigger, because a sleep
    /// proxy is a property of the network this Mac is attached to. `force` is the page becoming
    /// visible, which is a person looking at the answer rather than the network moving.
    private func readWakeOnDemandFacts(force: Bool = false) {
        let state = RemoteAccessCoordinator.shared.thisNetworkDoorState
        guard force || state != wakeFactsDoorState else { return }
        guard wakeFactsTask == nil else { return }
        wakeFactsDoorState = state
        wakeSpinner.isAnimating = true
        wakeGlyph.isHidden = true
        wakeFactsTask = Task { [weak self] in
            await RemoteAccessCoordinator.shared.refreshWakeOnDemandFacts()
            guard let self else { return }
            self.wakeFactsTask = nil
            self.refresh()
        }
    }

    /// Renders the ways in. The one entry point a test drives, for the same reason
    /// `applyListeningState` is: none of these states can be reached on a developer's machine
    /// on purpose.
    func apply(_ doors: RemoteAccessDoorsPresentation) {
        lastDoors = doors
        remoteAccessToggle.state = doors.isRemoteAccessOn ? .on : .off
        thisNetworkToggle.state = doors.thisNetworkIsOn ? .on : .off
        tailscaleToggle.state = doors.tailscaleIsOn ? .on : .off
        tailscaleServeToggle.state = doors.tailscaleServeIsOn ? .on : .off

        // Threading Direct joins the run when this Mac signs in, and takes the selection with it
        // only if the segment somebody was on has gone. A build without Hosted Direct never
        // offers it, whatever presentation it is handed.
        var offered: [RemoteAccessWayIn] = [.thisNetwork, .tailscale]
        if hostedDirectIsOffered && doors.showsThreadingDirect { offered.append(.threadingDirect) }
        waysIn = offered
        if !offered.contains(selectedWayIn) { selectedWayIn = offered[0] }

        if builtWaysIn != waysIn || builtSelection != selectedWayIn {
            // Rebuilding calls back into here with the same value once the new views exist, so
            // everything below runs against the panel that is actually on screen.
            rebuildWaysInCard()
            return
        }

        waysInControl.setMarks(waysIn.map { segmentMark(for: $0) })
        applyWayIns()
    }

    /// Chooses which way in's panel is on the page.
    ///
    /// Internal because it is the run's counterpart to `apply(_:)`: a test photographing the
    /// tailnet panel has to be able to select it without a pointer, and the coordinator has
    /// nothing to say about which segment somebody is looking at.
    func select(_ wayIn: RemoteAccessWayIn) {
        guard waysIn.contains(wayIn), wayIn != selectedWayIn else { return }
        selectedWayIn = wayIn
        rebuildWaysInCard()
    }

    /// Which way in's panel is on the page.
    var shownWayIn: RemoteAccessWayIn { selectedWayIn }

    /// Paints the selected panel from the values the page was last handed.
    private func applyWayIns() {
        for (wayIn, views) in wayInStatusViews {
            apply(lastDoors.status(of: wayIn), to: views)
        }
        if let views = tailscaleServeStatusViews {
            apply(lastDoors.serveStatus, to: views)
        }
        tailscaleServeRemedyURL = lastDoors.serveRemedy?.url
        tailscaleServeRemedyButton.isHidden = lastDoors.serveRemedy == nil
        if let remedy = lastDoors.serveRemedy {
            tailscaleServeRemedyButton.title = remedy.title
            tailscaleServeRemedyButton.setAccessibilityLabel(remedy.title)
        }
        apply(lastDoors.identity)
        apply(lastDiscovery)
    }

    /// What a segment says about a way in you are not looking at.
    ///
    /// Read from the same status line the panel prints, so the mark and the sentence can never
    /// disagree: a run that derived "on" from the *switch* would show a tick beside a way in
    /// that is switched on and bound to nothing.
    private func segmentMark(
        for wayIn: RemoteAccessWayIn
    ) -> ThemedSegmentedControl.SegmentMark? {
        guard let status = lastDoors.status(of: wayIn) else { return nil }
        switch status.tone {
        case .ready: return .ready
        case .attention: return .attention
        case .off, .working: return .idle
        }
    }

    /// Renders the announcement and the wake fact. The other entry point a test drives.
    ///
    /// The positive wake line is drawn from `RemoteDiscoveryPresentation.Wake` and from nothing
    /// else, so "can wake this Mac" cannot be printed without both facts holding, which is the
    /// promise §15 of the transport plan says settings must not make on a network that cannot
    /// keep it.
    func apply(_ discovery: RemoteDiscoveryPresentation) {
        lastDiscovery = discovery
        discoveryToggle.state = discovery.isEnabled ? .on : .off

        announcedLabel.stringValue = discovery.announcement ?? ""
        // Nothing registered is not a state with a line in it: the switch above already says
        // whether the announcement is meant to be running, and a door with no address under it
        // has its own status line three rows up.
        let isAnnounced = discovery.announcement != nil
        announcedRow?.isHidden = !isAnnounced
        announcedLabel.isHidden = !isAnnounced
        announcedGlyph.isHidden = !isAnnounced
        announcedGlyph.stringValue = DoorMark.ready
        announcedGlyph.textColor = Self.ink(for: .ready)
        announcedSpinner.isAnimating = false

        let wake = discovery.wake
        wakeLabel.stringValue = wake.text
        wakeGlyph.stringValue = Self.mark(for: wake.tone)
        wakeGlyph.textColor = Self.ink(for: wake.tone)
        wakeSpinner.isAnimating = wakeFactsTask != nil
        wakeGlyph.isHidden = wakeFactsTask != nil
        wakeSpinner.setAccessibilityLabel(wake.text)
    }

    private func apply(_ status: RemoteDoorStatus?, to views: WayInStatusViews) {
        guard let status else {
            views.text.stringValue = ""
            views.hint.stringValue = ""
            views.hint.isHidden = true
            views.glyph.isHidden = true
            views.spinner.isAnimating = false
            return
        }
        views.text.stringValue = status.text
        views.hint.stringValue = status.hint ?? ""
        views.hint.isHidden = status.hint == nil
        views.spinner.setAccessibilityLabel(status.text)
        views.spinner.isAnimating = status.isBusy
        views.glyph.isHidden = status.isBusy
        // A mark as well as a colour: status has to be identifiable without colour alone, and
        // this is also the page's only signal under Differentiate Without Colour.
        views.glyph.stringValue = Self.mark(for: status.tone)
        views.glyph.textColor = Self.ink(for: status.tone)
    }

    private static func mark(for tone: RemoteDoorStatus.Tone) -> String {
        switch tone {
        case .ready: return DoorMark.ready
        case .attention: return DoorMark.attention
        case .off, .working: return DoorMark.idle
        }
    }

    private static func ink(for tone: RemoteDoorStatus.Tone) -> NSColor {
        switch tone {
        case .ready: return Design.Status.positive
        case .attention: return Design.Status.warning
        case .off, .working: return Design.Text.tertiary
        }
    }

    private func apply(_ identity: RemoteIdentityCardPresentation) {
        identityCode.stringValue = identity.pairingCode ?? ""
        identityCode.isHidden = identity.pairingCode == nil
        identityCaption.isHidden = identity.pairingCode == nil
        // Only a *reason* stays on the page. What the code is for is one press away behind the
        // hero's "?", where it is read once rather than every time somebody opens this page.
        let reason = identity.failure
            ?? (identity.pairingCode == nil ? RemoteIdentityCardPresentation.notMintedYet : nil)
        identityDetail.stringValue = reason ?? ""
        identityDetail.isHidden = reason == nil
        identitySuccessor.isHidden = identity.nextPairingCode == nil
        identitySuccessor.stringValue = identity.nextPairingCode.map {
            L10n.format(
                "A successor is announced and not in use yet: %@. Every device that has "
                    + "connected since then already trusts it.",
                $0
            )
        } ?? ""
        identityPrepareButton.isEnabled = identity.canPrepareRotation && identityTask == nil
        identityActivateButton.isEnabled = identity.canActivateRotation && identityTask == nil
        identityResetButton.isEnabled = identityTask == nil
    }

    private func updateHostedAccount(_ coordinator: RemoteAccessCoordinator) {
        // A running account task is the sign-in/out exchange; `.connecting` is the service
        // itself coming up. Both are work in progress the row would otherwise state as text
        // beside controls that merely went quiet.
        hostedSpinner.isAnimating = hostedAccountTask != nil
            || coordinator.hostedServiceState == .connecting
        hostedSignInButton.isHidden = true
        hostedSignOutButton.isHidden = true
        hostedDeleteAccountButton.isHidden = true
        hostedSignInButton.isEnabled = hostedAccountTask == nil
        hostedSignOutButton.isEnabled = hostedAccountTask == nil
        hostedDeleteAccountButton.isEnabled = hostedAccountTask == nil

        if let hostedAccountError {
            hostedStatusLabel.stringValue = hostedAccountError
            if coordinator.canIssueHostedDeviceCredentials {
                hostedSignOutButton.isHidden = false
                hostedDeleteAccountButton.isHidden = false
            } else {
                hostedSignInButton.isHidden = false
            }
            return
        }
        switch coordinator.hostedServiceState {
        case .stopped:
            if coordinator.canIssueHostedDeviceCredentials {
                hostedStatusLabel.stringValue = L10n.string("Signed in")
                hostedSignOutButton.isHidden = false
                hostedDeleteAccountButton.isHidden = false
            } else {
                hostedStatusLabel.stringValue = L10n.string("Not signed in")
                hostedSignInButton.isHidden = false
            }
        case .notConfigured:
            hostedStatusLabel.stringValue = L10n.string("Not configured in this build")
        case .signInRequired:
            hostedStatusLabel.stringValue = L10n.string("Sign in to enable zero-setup access")
            hostedSignInButton.isHidden = false
        case .connecting:
            hostedStatusLabel.stringValue = L10n.string("Connecting…")
        case .ready:
            hostedStatusLabel.stringValue = L10n.string("Ready")
            hostedSignOutButton.isHidden = false
            hostedDeleteAccountButton.isHidden = false
        case .unavailable:
            hostedStatusLabel.stringValue = L10n.string("Temporarily unavailable")
            if coordinator.canIssueHostedDeviceCredentials {
                hostedSignOutButton.isHidden = false
                hostedDeleteAccountButton.isHidden = false
            } else {
                hostedSignInButton.isHidden = false
            }
        }
    }

    @objc private func signInHostedService() {
        guard hostedDirectIsOffered, hostedAccountTask == nil, let window = view.window,
              let hostedAppleSignIn else { return }
        hostedAccountError = nil
        refresh()
        hostedAccountTask = Task { [weak self] in
            guard let self else { return }
            do {
                let authorization = try await hostedAppleSignIn.authorize(from: window)
                try await RemoteAccessCoordinator.shared.signInHostedService(
                    identityToken: authorization.identityToken,
                    authorizationCode: authorization.authorizationCode,
                    rawNonce: authorization.rawNonce
                )
            } catch let error as ASAuthorizationError where error.code == .canceled {
                // Closing Apple's sheet is an ordinary cancellation, not a service failure.
            } catch {
                hostedAccountError = L10n.string("Sign in failed. Try again.")
            }
            hostedAccountTask = nil
            refresh()
        }
    }

    @objc private func signOutHostedService() {
        guard hostedDirectIsOffered, hostedAccountTask == nil else { return }
        hostedAccountError = nil
        refresh()
        hostedAccountTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await RemoteAccessCoordinator.shared.signOutHostedService()
            } catch {
                hostedAccountError = L10n.string("Sign out failed. Try again.")
            }
            hostedAccountTask = nil
            refresh()
        }
    }

    @objc private func deleteHostedServiceAccount() {
        guard hostedDirectIsOffered, hostedAccountTask == nil else { return }
        let request = ConfirmationRequest(
            prompt: .deleteHostedServiceAccount,
            title: L10n.string("Delete hosted account?"),
            message: L10n.string(
                "This permanently removes your Threading service account, revokes direct "
                    + "access for every paired iPhone, and signs this Mac out. Local chats and "
                    + "settings stay on this Mac."
            ),
            confirmTitle: L10n.string("Delete Account")
        )
        guard ConfirmationAlert.ask(request) else { return }
        hostedAccountError = nil
        refresh()
        hostedAccountTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await RemoteAccessCoordinator.shared.deleteHostedServiceAccount()
            } catch {
                hostedAccountError = L10n.string("Account deletion failed. Try again.")
            }
            hostedAccountTask = nil
            refresh()
        }
    }

    /// Applies one coherent listening-state page: the status row and the pairing card together.
    ///
    /// Both come from values a test can build, because both states this page needed fixing in —
    /// a door that failed and a door that is still coming up — take a live tailnet to reach, and
    /// what shipped was reviewed in neither.
    func applyListeningState(
        connection: RemoteConnectionStatusPresentation,
        card: RemotePairingCardState
    ) {
        apply(connection)
        applyPairingCard(card)
    }

    private func apply(_ connection: RemoteConnectionStatusPresentation) {
        updateConnection(
            title: connection.title,
            detail: connection.detail,
            color: color(for: connection.tone),
            busy: connection.isBusy
        )
    }

    private func color(for tone: RemoteConnectionStatusPresentation.Tone) -> NSColor {
        switch tone {
        case .ready: return Design.Status.positive
        case .attention, .working: return Design.Status.warning
        }
    }

    private func applyPairingCard(_ state: RemotePairingCardState) {
        switch state {
        case .keychainUnavailable:
            updatePairing(
                title: L10n.string("Pairing unavailable"),
                detail: L10n.string(
                    "Threading could not read its paired-device Keychain item. It will not "
                        + "overwrite that item or issue a credential it cannot preserve."
                ),
                action: L10n.string("Pairing Unavailable"),
                actionEnabled: false,
                prominent: false
            )

        case .ready(let payload):
            updatePairing(
                title: L10n.string("Scan with your iPhone"),
                detail: L10n.string(
                    "Open Threading on iPhone, choose Pair a Mac, then scan this one-time code."
                ),
                action: L10n.string("Copy Pairing Link"),
                actionEnabled: true,
                prominent: false,
                pairingPayload: payload
            )

        case .noWayIn:
            updatePairing(
                title: L10n.string("No way in is switched on"),
                detail: L10n.string(
                    "Remote Access is on and nothing outside this Mac can reach it. Turn on "
                        + "This network, or Tailscale, to get a pairing code."
                ),
                action: L10n.string("Pairing Unavailable"),
                actionEnabled: false,
                prominent: false
            )

        case .connectionUnavailable(let reason):
            // The reason is the panel's own, not a pointer at a row above it: the way in's
            // status line states the fact and its remedy, and this is that sentence.
            updatePairing(
                title: L10n.string("Private connection unavailable"),
                detail: reason,
                action: L10n.string("Retry Connection"),
                actionEnabled: true,
                prominent: true
            )

        case .preparing(let detail):
            updatePairing(
                title: L10n.string("Preparing your pairing code"),
                detail: detail ?? L10n.string(
                    "The QR code appears here as soon as the selected connection is ready."
                ),
                action: L10n.string("Connecting…"),
                actionEnabled: false,
                prominent: false,
                busy: true
            )

        case .codeUnavailable:
            updatePairing(
                title: L10n.string("Pairing code unavailable"),
                detail: L10n.string(
                    "The connection is ready, but Threading could not build a pairing code for "
                        + "it. Retrying starts the connection again."
                ),
                action: L10n.string("Retry Connection"),
                actionEnabled: true,
                prominent: true
            )
        }
    }

    private func updateConnection(
        title: String,
        detail: String,
        color: NSColor,
        busy: Bool = false
    ) {
        statusTitle.stringValue = title
        statusDetail.stringValue = detail
        statusGlyph.textColor = color
        statusGlyph.isHidden = busy
        statusSpinner.setAccessibilityLabel(title)
        statusSpinner.isAnimating = busy
    }

    /// The tailnet readiness rows are gone from the page, and the value behind them stays.
    ///
    /// They named three steps — installed, signed in, an address — and the tailnet way in's own
    /// status line already states whichever of the three failed *with its remedy in the same
    /// sentence*: "Tailscale is not installed on this Mac. Install Tailscale and sign in on this
    /// Mac. The door comes back on its own." A card repeating that under it was a second place
    /// for the same fact to be, which is the arrangement §9's copy rules were written against.
    /// `RemoteTailnetReadinessPresentation` and its tests are untouched; nothing draws it.

    private func rebuildPairedDevices(
        _ devices: [RemoteAccessCoordinator.PairedOwnerDevice],
        error: String?
    ) {
        pairedDevicesStack.arrangedSubviews.forEach {
            pairedDevicesStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        pairedDeviceIDs = devices.map(\.id)

        if let error {
            addPairedDeviceRow(SettingsUI.row(
                title: L10n.string("Paired devices unavailable"),
                subtitle: error,
                localizes: false
            ))
            return
        }
        guard !devices.isEmpty else {
            addPairedDeviceRow(SettingsUI.row(
                title: L10n.string("Paired devices"),
                subtitle: L10n.string("No durable owner devices are paired yet."),
                localizes: false
            ))
            return
        }

        for (index, device) in devices.enumerated() {
            if index > 0 {
                let divider = SeparatorView()
                pairedDevicesStack.addArrangedSubview(divider)
                divider.leadingAnchor.constraint(
                    equalTo: pairedDevicesStack.leadingAnchor,
                    constant: Design.Spacing.inset
                ).isActive = true
                divider.trailingAnchor.constraint(
                    equalTo: pairedDevicesStack.trailingAnchor
                ).isActive = true
            }
            let button = ThemedButton(
                title: L10n.string("Revoke"),
                target: self,
                action: #selector(revokePairedDevice(_:))
            )
            button.tag = index
            button.setAccessibilityLabel(
                L10n.format("Revoke %@", device.displayName)
            )
            let date = device.lastSeenAt ?? device.pairedAt
            let detail = device.lastSeenAt == nil
                ? L10n.format("Paired %@", Self.relative.localizedString(
                    for: date,
                    relativeTo: Date()
                ))
                : L10n.format("Last seen %@", Self.relative.localizedString(
                    for: date,
                    relativeTo: Date()
                ))
            addPairedDeviceRow(SettingsUI.row(
                title: device.displayName,
                subtitle: detail,
                control: button,
                localizes: false
            ))
        }
    }

    private func addPairedDeviceRow(_ row: NSView) {
        pairedDevicesStack.addArrangedSubview(row)
        row.leadingAnchor.constraint(equalTo: pairedDevicesStack.leadingAnchor).isActive = true
        row.trailingAnchor.constraint(equalTo: pairedDevicesStack.trailingAnchor).isActive = true
    }

    private func updatePairing(
        title: String,
        detail: String,
        action: String,
        actionEnabled: Bool,
        prominent: Bool,
        busy: Bool = false,
        pairingPayload: String? = nil
    ) {
        pairingTitle.stringValue = title
        pairingSpinner.setAccessibilityLabel(title)
        pairingSpinner.isAnimating = busy
        pairingDetail.stringValue = detail
        pairingActionButton.title = action
        pairingActionButton.isEnabled = actionEnabled
        pairingActionButton.isProminent = prominent

        // Drawn at the side the card gives it: an `NSImage` scaled into an image view is
        // resampled, and a resampled module edge is the one thing this artwork cannot spare.
        let code = pairingPayload.flatMap {
            PairingCodeImage.make(for: $0, side: PairingCardLayout.codeSide)
        }
        pairingCode.image = code
        pairingCode.isHidden = code == nil
    }

    // MARK: - Actions

    @objc private func remoteAccessChanged() {
        RemoteAccessCoordinator.shared.setEnabled(remoteAccessToggle.state == .on)
        refresh()
    }

    /// The `lan` door. `vpn` is deliberately not selected with it: a tunnel into this network
    /// hands the phone an address inside it, so the LAN listener is what answers, and the `vpn`
    /// door is for the day a listener binds the tunnel's own address.
    @objc private func thisNetworkDoorChanged() {
        var doors = AppSettings.shared.remoteAccessDoors
        if thisNetworkToggle.state == .on {
            doors.insert(.lan)
        } else {
            doors.remove(.lan)
        }
        RemoteAccessCoordinator.shared.setDoors(doors)
        refresh()
    }

    /// Starts or stops the broadcast. Nothing else moves: the door stays open, the listener is
    /// not disturbed, and a phone already connected over it stays connected.
    @objc private func discoveryChanged() {
        RemoteAccessCoordinator.shared.setDiscoveryEnabled(discoveryToggle.state == .on)
        refresh()
    }

    @objc private func tailscaleDoorChanged() {
        RemoteAccessCoordinator.shared.setTailscaleDoorEnabled(tailscaleToggle.state == .on)
        refresh()
    }

    @objc private func tailscaleServeChanged() {
        RemoteAccessCoordinator.shared.setTailscaleServeEnabled(
            tailscaleServeToggle.state == .on
        )
        refresh()
    }

    /// Throws this Mac's certificate away and mints a new one. The one operation on this page
    /// that unpairs devices, so it says so in the words it will actually cost.
    @objc private func resetIdentity() {
        guard identityTask == nil else { return }
        let request = ConfirmationRequest(
            prompt: .resetRemoteAccessIdentity,
            title: L10n.string("Reset this Mac’s identity?"),
            message: L10n.string(
                "Threading mints a new certificate and a new pairing code. Every paired device "
                    + "stops trusting this Mac and has to scan the new code before it can "
                    + "connect again. Use Prepare Rotation instead if this Mac’s certificate is "
                    + "still working."
            ),
            confirmTitle: L10n.string("Reset Identity")
        )
        guard ConfirmationAlert.ask(request) else { return }
        runIdentityOperation { await RemoteAccessCoordinator.shared.resetIdentity() }
    }

    /// Mints the successor and announces it over the pinned channel, without presenting it. A
    /// phone connected since the announcement has already pinned it.
    @objc private func prepareIdentityRotation() {
        guard identityTask == nil else { return }
        runIdentityOperation { await RemoteAccessCoordinator.shared.prepareIdentityRotation() }
    }

    @objc private func activateIdentityRotation() {
        guard identityTask == nil else { return }
        let request = ConfirmationRequest(
            prompt: .activateRemoteAccessIdentityRotation,
            title: L10n.string("Switch to the new identity?"),
            message: L10n.string(
                "Every device that has connected to this Mac since the successor was announced "
                    + "keeps working without doing anything. A device that has not connected "
                    + "since then has to scan the new pairing code."
            ),
            confirmTitle: L10n.string("Switch")
        )
        guard ConfirmationAlert.ask(request) else { return }
        runIdentityOperation { await RemoteAccessCoordinator.shared.activateIdentityRotation() }
    }

    /// One task at a time, and the buttons state that while it runs. The operations themselves
    /// read and write files and import a container, which the coordinator already does off the
    /// main actor.
    private func runIdentityOperation(
        _ operation: @escaping @MainActor () async -> Result<
            RemoteHostFingerprint, RemoteIdentityFailure
        >
    ) {
        identityTask = Task { [weak self] in
            _ = await operation()
            guard let self else { return }
            identityTask = nil
            refresh()
        }
        refresh()
    }

    /// Recorded on the Mac and read again the next time a phone asks what is available, so a
    /// report already on its way keeps the answer it was given.
    @objc private func phoneReportWorkspaceChanged() {
        guard let value = phoneReportWorkspacePopUp.selectedItem?.representedValue
            as? PhoneReportWorkspacePolicy else { return }
        AppSettings.shared.phoneReportWorkspace = value
    }

    @objc private func macActivityWindowChanged() {
        guard let value = macActivityWindowPopUp.selectedItem?.representedValue
            as? MacNotificationActivityWindow else { return }
        AppSettings.shared.remoteNotificationMacActivityWindow = value
    }

    @objc private func openLocally() {
        guard let url = RemoteAccessCoordinator.shared.localURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// Opens the admin-console page a Serve failure named. Only that page is ever offered, so
    /// arbitrary text in command output cannot steer the browser anywhere else.
    @objc private func openServeRemedy() {
        guard let tailscaleServeRemedyURL else { return }
        NSWorkspace.shared.open(tailscaleServeRemedyURL)
    }

    @objc private func pairingAction() {
        let coordinator = RemoteAccessCoordinator.shared

        if let payload = coordinator.pairingCodePayload {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(payload, forType: .string)
            pairingActionButton.title = L10n.string("Copied")
            pairingActionButton.isEnabled = false

            let reset = DispatchWorkItem { [weak self] in self?.refresh() }
            copiedReset = reset
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: reset)
            return
        }

        switch coordinator.status {
        case .disabled:
            coordinator.setEnabled(true)
        case .failed:
            restart()
        case .listening:
            coordinator.retryTransports()
        case .starting:
            break
        }
        refresh()
    }

    private func restart() {
        let coordinator = RemoteAccessCoordinator.shared
        coordinator.setEnabled(false)
        coordinator.setEnabled(true)
    }

    @objc private func revokePairedDevice(_ sender: ThemedButton) {
        guard pairedDeviceIDs.indices.contains(sender.tag),
              let device = RemoteAccessCoordinator.shared.pairedOwnerDevices.first(where: {
                  $0.id == pairedDeviceIDs[sender.tag]
              }) else { return }
        let request = ConfirmationRequest(
            prompt: .revokePairedDevice,
            title: L10n.format("Revoke %@?", device.displayName),
            message: L10n.string(
                "This device loses owner access immediately. Pair it again with a new code if "
                    + "you want to restore access."
            ),
            confirmTitle: L10n.string("Revoke")
        )
        guard ConfirmationAlert.ask(request) else { return }
        _ = RemoteAccessCoordinator.shared.revokeOwnerDevice(device.id)
        refresh()
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    /// The views one way in's status line writes into. Held rather than rebuilt: a status line
    /// changes on every interface event, and rebuilding a card to change two strings is how a
    /// page starts flickering under a network that is settling.
    private struct WayInStatusViews {
        let glyph: NSTextField
        let spinner: ThemedSpinner
        let text: NSTextField
        let hint: NSTextField
    }

    /// The mark beside a status line, so the state survives Differentiate Without Colour.
    private enum DoorMark {
        static let ready = "✓"
        static let attention = "!"
        static let idle = "–"
    }

    /// Accessibility identifiers, built once so a test and the page cannot spell them apart.
    enum Identifier {
        static let discoveryToggle = "settings.remote-access.discovery"
        static let announcedName = "settings.remote-access.announced-as"
        static let wakeOnDemand = "settings.remote-access.wake-on-demand"
        static let wakeOnDemandMark = "settings.remote-access.wake-on-demand-mark"

        static func doorToggle(_ wayIn: RemoteAccessWayIn) -> String {
            "settings.remote-access.door.\(wayIn.identifierComponent)"
        }

        static func status(_ wayIn: RemoteAccessWayIn) -> String {
            "settings.remote-access.status.\(wayIn.identifierComponent)"
        }

        static func statusMark(_ wayIn: RemoteAccessWayIn) -> String {
            "settings.remote-access.status-mark.\(wayIn.identifierComponent)"
        }

        static func statusHint(_ wayIn: RemoteAccessWayIn) -> String {
            "settings.remote-access.status-hint.\(wayIn.identifierComponent)"
        }

        /// The run of ways in, and the caption above the hero's identity code.
        static let waysInControl = "settings.remote-access.ways-in"
        static let identityCaption = "settings.remote-access.identity-caption"

        /// The Serve sub-option. Not a way in, so it is named rather than derived from one.
        static let serveToggle = "settings.remote-access.tailscale-serve"
        static let serveStatus = "settings.remote-access.status.tailscale-serve"
        static let serveStatusMark = "settings.remote-access.status-mark.tailscale-serve"
        static let serveStatusHint = "settings.remote-access.status-hint.tailscale-serve"
        static let serveRemedy = "settings.remote-access.tailscale-serve-remedy"
    }

}

// MARK: - Ways In Host

/// The view the ways-in card stands in, and the page's answer to a search result naming a row
/// behind a segment nobody is on.
///
/// A bare `NSView` with one closure: it chooses no styling of its own, and the knowledge of what
/// is on which segment stays with the controller that built them.
private final class WaysInHostView: NSView, SettingsRowRevealing {

    var onReveal: ((String) -> Bool)?

    func prepareToReveal(title: String) -> Bool {
        onReveal?(title) ?? false
    }
}
