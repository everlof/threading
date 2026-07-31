import AppKit
import ThreadingRemoteKit

/// Who can reach one chat from outside this Mac, and who is looking at it right now.
///
/// The app could say that a chat was shared and nothing else: not who accepted a link, not
/// whether anyone was on it, not how many links were still lying around unused. That gap was
/// not only a privacy hole — two clients quietly holding the same terminal is what made the
/// shared PTY flip between two grid sizes several times a second, and the only way to see it was
/// to screenshot the corner card.
///
/// **Three sections, because there are three different things here**, and they are a lifecycle:
/// a *link* is created and waits, accepting one turns it into a *person*, and a person opening
/// the chat makes a *connection*. They have different lifetimes and different verbs — you copy a
/// link, you revoke a person, and a connection simply ends — so mixing them into one list would
/// make every row's controls a guess.
///
/// The owner's own paired devices sit in the live section with the guests, because in the moment
/// that matters — something is watching this chat — they are the same fact. They carry no Revoke:
/// a paired device holds the pairing token rather than a share of this chat, so dropping it is
/// unpairing the Mac, which belongs in Settings and says so.
final class SessionSharingViewController: NSViewController {

    // MARK: - Properties

    let sessionID: SessionID

    /// Asks the window for a fresh invitation, so the sheet, its grant choice and its copy
    /// behaviour stay in the one place that already owns them.
    var onShare: (() -> Void)?

    private let appEvents = AppEventObservations()
    nonisolated(unsafe) private var tickTimer: Timer?

    /// What is on screen, so an event that changed nothing does not throw away the scroll
    /// position or the pointer's hover. Ages are written into the rows already there.
    private var renderedShape: String?
    private var ageRows: [String: SessionSharingRowView] = [:]

    private lazy var titleLabel: NSTextField = {
        let label = NSTextField(labelWithString: L10n.string("Sharing"))
        label.applyFont(.subheading)
        label.textColor = Design.Text.label
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    private lazy var subtitleLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.applyFont(.caption)
        label.textColor = Design.Text.tertiary
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    private lazy var shareButton: ThemedButton = {
        let button = ThemedButton(
            title: L10n.string("Share Chat…"),
            target: self,
            action: #selector(shareClicked)
        )
        button.toolTip = L10n.string("Create a single-use invitation to this chat")
        return button
    }()

    private lazy var stack: NSStackView = {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.hairline
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(
            top: Design.Spacing.small,
            left: Design.Spacing.small,
            bottom: Design.Spacing.inset,
            right: Design.Spacing.small
        )
        return stack
    }()

    private lazy var scrollView: ThemedScrollView = {
        let clipView = FlippedClipView()
        clipView.drawsBackground = false
        let scroll = ThemedScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.contentView = clipView
        scroll.documentView = stack
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        return scroll
    }()

    // MARK: - Initialization

    init(sessionID: SessionID) {
        self.sessionID = sessionID
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        tickTimer?.invalidate()
    }

    // MARK: - Lifecycle

    override func loadView() {
        let root = WindowAwareView()
        root.onWindowChange = { [weak self] window in
            window == nil ? self?.stopTicking() : self?.startTicking()
        }
        root.wantsLayer = true
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        [titleLabel, subtitleLabel, shareButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        view.addSubview(scrollView)
        setupConstraints()

        // Both halves move on their own clocks: who *may* watch changes when the owner acts,
        // who *is* watching changes whenever a phone is picked up.
        appEvents.observe(SessionFollowersDidChange.self) { [weak self] event in
            guard event.sessionID == self?.sessionID else { return }
            self?.refresh()
        }
        appEvents.observe(SessionSharingDidChange.self) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    // MARK: - Public Methods

    /// Re-reads both sides now. Cheap: everything it asks for is in memory on this actor.
    func refresh() {
        guard isViewLoaded else { return }
        subtitleLabel.stringValue = ProjectStore.shared
            .session(withID: sessionID)?.displayTitle ?? ""

        let sections = Self.sections(
            followers: RemoteSessionMirrorRegistry.shared.followers(of: sessionID),
            access: RemoteAccessCoordinator.shared.access(for: sessionID)
        )

        let shape = self.shape(
            followers: sections.watching,
            away: sections.away,
            links: sections.links
        )
        guard shape != renderedShape else {
            updateAges(
                followers: sections.watching,
                away: sections.away,
                links: sections.links
            )
            return
        }
        renderedShape = shape
        rebuild(followers: sections.watching, away: sections.away, links: sections.links)
    }

    /// The three groups, from the live sockets and the stored shares.
    ///
    /// The one judgement here: **a member who has the chat open shows once**, in the live group,
    /// where there is more to say about them. Both sources know about that person — the socket
    /// because they are on it, the share store because they accepted an invitation — and listing
    /// them from each would put the same name in two sections and read as two people.
    static func sections(
        followers: [RemoteSessionMirrorRegistry.Follower],
        access: RemoteAccessCoordinator.SessionAccess
    ) -> (
        watching: [RemoteSessionMirrorRegistry.Follower],
        away: [RemoteAccessCoordinator.SessionAccess.Member],
        links: [RemoteAccessCoordinator.SessionAccess.Link]
    ) {
        let watchingMemberIDs = Set(followers.compactMap(\.memberID))
        return (
            watching: followers,
            away: access.members.filter { !watchingMemberIDs.contains($0.id) },
            links: access.links
        )
    }

    // MARK: - Rendering

    /// Everything about the pane except the ages, which move on their own. Two readings with the
    /// same shape describe the same rows.
    private func shape(
        followers: [RemoteSessionMirrorRegistry.Follower],
        away: [RemoteAccessCoordinator.SessionAccess.Member],
        links: [RemoteAccessCoordinator.SessionAccess.Link]
    ) -> String {
        let live = followers.map {
            "\($0.id)/\($0.memberName ?? "")/\($0.deviceName ?? "")/\($0.surface)"
                + "/\($0.viewport.map { "\($0.cols)×\($0.rows)" } ?? "")/\($0.isTyping)"
        }
        return (live + away.map(\.id) + links.map(\.id)).joined(separator: "|")
    }

    private func updateAges(
        followers: [RemoteSessionMirrorRegistry.Follower],
        away: [RemoteAccessCoordinator.SessionAccess.Member],
        links: [RemoteAccessCoordinator.SessionAccess.Link]
    ) {
        for follower in followers {
            ageRows["\(follower.id)"]?.detail = detail(for: follower)
        }
        for member in away {
            ageRows[member.id]?.detail = detail(for: member)
        }
        for link in links {
            ageRows[link.id]?.detail = detail(for: link)
        }
    }

    private func rebuild(
        followers: [RemoteSessionMirrorRegistry.Follower],
        away: [RemoteAccessCoordinator.SessionAccess.Member],
        links: [RemoteAccessCoordinator.SessionAccess.Link]
    ) {
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        ageRows.removeAll()

        guard AppSettings.shared.remoteAccessEnabled else {
            add(note: L10n.string(
                "Remote Access is off, so nothing outside this Mac can reach this chat."
            ))
            shareButton.isHidden = true
            return
        }
        shareButton.isHidden = false

        if followers.isEmpty, away.isEmpty, links.isEmpty {
            add(note: L10n.string(
                "Nobody else can reach this chat. Sharing it creates a single-use invitation "
                    + "to this one chat — never to your other sessions."
            ))
            return
        }

        if !followers.isEmpty {
            add(sectionTitle: L10n.string("Watching now"), count: followers.count)
            followers.forEach(add(follower:))
            if followers.contains(where: \.isOwnerDevice) {
                addSettingsFootnote(
                    L10n.string(
                        "Your own devices are paired to this Mac, not to this chat. "
                            + "Unpair them in Settings."
                    ),
                    buttonTitle: L10n.string("Remote Access…")
                )
            }
        }

        if !away.isEmpty {
            add(sectionTitle: L10n.string("With access"), count: away.count)
            away.forEach(add(member:))
        }

        if !links.isEmpty {
            add(sectionTitle: L10n.string("Invited"), count: links.count)
            links.forEach(add(link:))
        }
    }

    // MARK: - Rows

    private func add(follower: RemoteSessionMirrorRegistry.Follower) {
        let row = SessionSharingRowView(
            symbolName: SessionSharingSymbols.watching,
            // The positive status role: somebody is here. Not the accent, which already means
            // "this session wants you" everywhere else in the window.
            symbolColor: Design.Status.positive,
            title: name(for: follower),
            detail: detail(for: follower)
        )
        row.toolTip = follower.isOwnerDevice
            ? L10n.string("One of your own paired devices")
            : L10n.format("%@ has this chat open", name(for: follower))
        ageRows["\(follower.id)"] = row
        addFullWidth(row)
    }

    private func add(member: RemoteAccessCoordinator.SessionAccess.Member) {
        let row = SessionSharingRowView(
            symbolName: SessionSharingSymbols.away,
            symbolColor: Design.Text.tertiary,
            title: member.displayName,
            detail: detail(for: member),
            actions: [
                .init(
                    title: L10n.string("Revoke"),
                    accessibility: L10n.format("Revoke %@’s access", member.displayName),
                    action: { [weak self] in self?.revoke(member) }
                )
            ]
        )
        ageRows[member.id] = row
        addFullWidth(row)
    }

    private func add(link: RemoteAccessCoordinator.SessionAccess.Link) {
        var actions: [SessionSharingRowView.Action] = []
        if let url = link.url {
            actions.append(.init(
                title: L10n.string("Copy"),
                accessibility: L10n.string("Copy this invitation link"),
                action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
            ))
        }
        actions.append(.init(
            title: L10n.string("Revoke"),
            accessibility: L10n.string("Withdraw this invitation"),
            action: { [weak self] in self?.revoke(link) }
        ))

        let row = SessionSharingRowView(
            symbolName: SessionSharingSymbols.link,
            symbolColor: Design.Text.tertiary,
            title: grantName(capability: link.capability, canApprove: link.canApprovePermissions),
            detail: detail(for: link),
            actions: actions
        )
        row.toolTip = L10n.string("Nobody has used this link yet")
        ageRows[link.id] = row
        addFullWidth(row)
    }

    // MARK: - Row text

    /// What to call a live viewer: their own name if they accepted an invitation, otherwise what
    /// their device said it was, otherwise the short pseudonym the diagnostics log uses.
    private func name(for follower: RemoteSessionMirrorRegistry.Follower) -> String {
        follower.memberName ?? follower.deviceName ?? follower.deviceLabel
    }

    private func detail(for follower: RemoteSessionMirrorRegistry.Follower) -> String {
        var parts: [String] = []
        if follower.isOwnerDevice {
            parts.append(L10n.string("Your device"))
            if let deviceName = follower.deviceName { parts.append(deviceName) }
        } else if follower.memberName != nil, let deviceName = follower.deviceName {
            parts.append(deviceName)
        }
        parts.append(grantName(
            capability: follower.capability,
            canApprove: follower.canApprovePermissions
        ))
        // The grid, because two viewers disagreeing about it is a thing that happens and used to
        // be invisible: the chat is held at the smallest one, which this is how you notice.
        if let viewport = follower.viewport {
            parts.append("\(viewport.cols)×\(viewport.rows)")
        }
        if follower.isTyping {
            parts.append(L10n.string("typing…"))
        } else if let since = follower.watchingSince {
            parts.append(L10n.format("watching %@", Self.age(of: since)))
        }
        return parts.joined(separator: " · ")
    }

    private func detail(for member: RemoteAccessCoordinator.SessionAccess.Member) -> String {
        var parts = [grantName(
            capability: member.capability,
            canApprove: member.canApprovePermissions
        )]
        if let lastSeen = member.lastSeenAt {
            parts.append(L10n.format("last seen %@", Self.relative.localizedString(
                for: lastSeen,
                relativeTo: Date()
            )))
        } else {
            parts.append(L10n.format("joined %@", Self.relative.localizedString(
                for: member.joinedAt,
                relativeTo: Date()
            )))
        }
        return parts.joined(separator: " · ")
    }

    private func detail(for link: RemoteAccessCoordinator.SessionAccess.Link) -> String {
        let created = L10n.format("created %@", Self.relative.localizedString(
            for: link.createdAt,
            relativeTo: Date()
        ))
        let expires = L10n.format("expires %@", Self.relative.localizedString(
            for: link.expiresAt,
            relativeTo: Date()
        ))
        return "\(created) · \(expires)"
    }

    /// The grant, in the words the share sheet offers it in — one vocabulary for the thing you
    /// choose and the thing you later see you chose.
    private func grantName(capability: RemoteCapability, canApprove: Bool) -> String {
        switch (capability, canApprove) {
        case (.interact, true): return L10n.string("Can reply · can approve")
        case (.interact, false): return L10n.string("Can reply")
        default: return L10n.string("View only")
        }
    }

    /// How long a live view has been open, kept short because it sits in a row of facts:
    /// `4 min`, not `4 minutes ago` — the row already says "watching".
    private static func age(of date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        if seconds < 60 { return L10n.string("just now") }
        return Self.duration.string(from: seconds) ?? L10n.string("just now")
    }

    private static let duration: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 1
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    // MARK: - Actions

    @objc private func shareClicked() {
        onShare?()
    }

    /// Asked every time. The invitation they came through was single-use, so the way back is a
    /// *different* action the owner has to know to take — share the chat again — which is the
    /// line `ConfirmationPrompt` draws between a question worth asking and an undo worth
    /// offering. Withdrawing an unused link asks nothing: nobody has become anybody yet.
    private func revoke(_ member: RemoteAccessCoordinator.SessionAccess.Member) {
        let request = ConfirmationRequest(
            prompt: .revokeChatAccess,
            title: L10n.format("Revoke %@’s access?", member.displayName),
            message: L10n.string(
                "They lose this chat immediately and anything they have open closes. Their "
                    + "invitation was single-use, so letting them back in means sharing the "
                    + "chat again."
            ),
            confirmTitle: L10n.string("Revoke")
        )
        guard ConfirmationAlert.ask(request) else { return }
        RemoteAccessCoordinator.shared.revokeMember(member.id, in: sessionID)
    }

    private func revoke(_ link: RemoteAccessCoordinator.SessionAccess.Link) {
        RemoteAccessCoordinator.shared.revokeLink(link.id, in: sessionID)
    }

    @objc private func openRemoteAccessSettings() {
        (view.window?.windowController as? MainWindowController)?
            .showSettingsPage(id: SettingsPages.remoteAccessID)
    }

    // MARK: - Ticking

    /// Ages are the one thing here that changes with no event behind it. A slow tick while the
    /// tab is on screen keeps "watching 4 min" honest without rebuilding anything: the rows are
    /// written in place, so the pointer keeps its hover and the pane its scroll position.
    private func startTicking() {
        guard tickTimer == nil else { return }
        refresh()
        let timer = Timer.scheduledTimer(
            withTimeInterval: SessionSharingDefaults.tickInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        timer.tolerance = SessionSharingDefaults.tickTolerance
        tickTimer = timer
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    // MARK: - Stack helpers

    private func add(sectionTitle: String, count: Int) {
        let label = NSTextField(
            labelWithString: L10n.format("%@  %lld", sectionTitle.uppercased(), Int64(count))
        )
        label.applyFont(.caption)
        label.textColor = Design.Text.quaternary
        label.translatesAutoresizingMaskIntoConstraints = false

        if !stack.arrangedSubviews.isEmpty {
            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.heightAnchor.constraint(
                equalToConstant: Design.Spacing.small
            ).isActive = true
            addFullWidth(spacer)
        }
        addFullWidth(label)
    }

    private func add(note: String) {
        let label = NSTextField(labelWithString: note)
        label.applyFont(.body)
        label.textColor = Design.Text.tertiary
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        addFullWidth(label)
    }

    /// A quiet line under a section, with the button that acts on what it says. Only one thing
    /// says this so far — that a paired device is the Mac's business and not this chat's — and
    /// the button goes to the one page that can undo it.
    private func addSettingsFootnote(_ footnote: String, buttonTitle: String) {
        let label = NSTextField(labelWithString: footnote)
        label.applyFont(.caption)
        label.textColor = Design.Text.quaternary
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        addFullWidth(label)

        let button = ThemedButton(
            title: buttonTitle,
            target: self,
            action: #selector(openRemoteAccessSettings)
        )
        button.emphasis = .tertiary
        button.translatesAutoresizingMaskIntoConstraints = false
        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(button)
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: holder.topAnchor),
            button.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            button.leadingAnchor.constraint(
                equalTo: holder.leadingAnchor,
                constant: -button.opticalHorizontalInset
            ),
            button.trailingAnchor.constraint(lessThanOrEqualTo: holder.trailingAnchor)
        ])
        addFullWidth(holder)
    }

    private func addFullWidth(_ subview: NSView) {
        stack.addArrangedSubview(subview)
        subview.widthAnchor.constraint(
            equalTo: stack.widthAnchor,
            constant: -(stack.edgeInsets.left + stack.edgeInsets.right)
        ).isActive = true
    }

    private func setupConstraints() {
        let inset = Design.Spacing.inset
        NSLayoutConstraint.activate([
            // The toolbar insets the safe area; pinning to the view's own top slides the header
            // underneath it.
            titleLabel.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor,
                constant: Design.Spacing.small
            ),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: inset),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: shareButton.leadingAnchor,
                constant: -Design.Spacing.tight
            ),

            shareButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            shareButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -inset),

            subtitleLabel.topAnchor.constraint(
                equalTo: titleLabel.bottomAnchor,
                constant: Design.Spacing.hairline
            ),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(
                equalTo: view.trailingAnchor,
                constant: -inset
            ),

            scrollView.topAnchor.constraint(
                equalTo: subtitleLabel.bottomAnchor,
                constant: Design.Spacing.small
            ),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            stack.widthAnchor.constraint(equalTo: scrollView.widthAnchor)
        ])
    }
}

// MARK: - Defaults

enum SessionSharingSymbols {
    /// The same filled dot the process list uses for "alive". A live viewer is a live thing.
    static let watching = "circle.fill"
    /// Hollow for somebody who could be here and is not — the difference between the two states
    /// is the fill, which reads at a glance down a column.
    static let away = "circle"
    /// A link that has not become a person yet is still just a link.
    static let link = "link"
}

enum SessionSharingDefaults {
    /// Slow, because the only thing it moves is an age. Anything that actually happens arrives
    /// as an event.
    static let tickInterval: TimeInterval = 30
    static let tickTolerance: TimeInterval = 5
    static let glyphPointSize: CGFloat = 9
    static let glyphSlot: CGFloat = 14
}

// MARK: - Row

/// One participant, link, or live view: a mark, a name, a line of facts under it, and whatever
/// can be done about it on the trailing edge.
///
/// Two lines rather than the info pane's one because the facts here do not fit a value column —
/// "Chrome on Mac · can reply · 46×35 · watching 12 min" is a sentence, and squeezing it into a
/// right-aligned slot beside a name is how it would end up truncated to "Chrome on…".
final class SessionSharingRowView: NSView {

    struct Action {
        let title: String
        let accessibility: String
        let action: () -> Void
    }

    private let glyphView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    /// Held so the buttons can dispatch by tag: `ThemedButton` is a target/action control, and a
    /// row builds its buttons from values rather than from selectors it could name up front.
    private var actions: [Action] = []

    /// Written in place between ticks, so a moving age costs neither the hover under the pointer
    /// nor the pane's scroll position.
    var detail: String {
        get { detailLabel.stringValue }
        set { detailLabel.stringValue = newValue }
    }

    init(
        symbolName: String,
        symbolColor: NSColor,
        title: String,
        detail: String,
        actions: [Action] = []
    ) {
        super.init(frame: .zero)
        self.actions = actions
        translatesAutoresizingMaskIntoConstraints = false
        applySurface(fill: Design.Chat.toolRowResting, radius: .control)

        glyphView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(
                pointSize: SessionSharingDefaults.glyphPointSize,
                weight: .regular
            ))
        glyphView.contentTintColor = symbolColor
        glyphView.imageScaling = .scaleNone
        glyphView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.applyFont(.body)
        titleLabel.textColor = Design.Text.label
        titleLabel.stringValue = title
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.applyFont(.caption)
        detailLabel.textColor = Design.Text.tertiary
        detailLabel.stringValue = detail
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        [glyphView, titleLabel, detailLabel].forEach(addSubview)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = Design.Spacing.hairline
        buttons.translatesAutoresizingMaskIntoConstraints = false
        for (index, action) in actions.enumerated() {
            let button = ThemedButton(
                title: action.title,
                target: self,
                action: #selector(runAction(_:))
            )
            button.tag = index
            button.emphasis = .tertiary
            button.setAccessibilityHelp(action.accessibility)
            buttons.addArrangedSubview(button)
        }
        addSubview(buttons)

        let inset = Design.Spacing.small
        NSLayoutConstraint.activate([
            glyphView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            glyphView.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            glyphView.widthAnchor.constraint(
                equalToConstant: SessionSharingDefaults.glyphSlot
            ),

            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            titleLabel.leadingAnchor.constraint(
                equalTo: glyphView.trailingAnchor,
                constant: Design.Spacing.tight
            ),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: buttons.leadingAnchor,
                constant: -Design.Spacing.tight
            ),

            detailLabel.topAnchor.constraint(
                equalTo: titleLabel.bottomAnchor,
                constant: Design.Spacing.hairline
            ),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: buttons.leadingAnchor,
                constant: -Design.Spacing.tight
            ),
            detailLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),

            buttons.centerYAnchor.constraint(equalTo: centerYAnchor),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset)
        ])

        setAccessibilityRole(.group)
        setAccessibilityLabel("\(title). \(detail)")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func runAction(_ sender: NSControl) {
        guard actions.indices.contains(sender.tag) else { return }
        actions[sender.tag].action()
    }
}
