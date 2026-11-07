import AppKit
import ThreadingController

// MARK: - Workrooms Preferences

/// Settings ▸ Workrooms: whether agents may ask people outside this Mac at all, who those people
/// are and whether they have the app, which rooms are open, and — folded away — how a person
/// without the app answers in a browser.
///
/// The page was one long list of everything the feature has: the tunnel and its domain first,
/// then every person with four buttons, then every room with its questions. The pilot owner
/// called it hard to grasp, and it was answering the wrong question for most visits — "who can
/// answer, and how do I get them in" — after the infrastructure. So the order is the decision
/// order: the switch, people with the app invitation, rooms; the web path, which needs a tunnel
/// and its provider, is one disclosure at the end. Each chat's own questions are in its Workroom
/// panel, not here.
///
/// The people and rooms are externally sized, so the page reads bounded slices of them
/// (`WorkroomsPageDefaults`) off the main actor and rebuilds only its own small stack.
final class WorkroomsPreferencesViewController: NSViewController {

    private struct PersonEntry {
        let person: WorkroomPerson
        let devices: [WorkroomDevice]
        let invitation: WorkroomInvitation?
        /// Phones answering in the Threading app, and whether an app invitation is unused.
        let app: RemoteAccessCoordinator.SessionAccess
    }

    private struct RoomEntry {
        let summary: WorkroomSummary
    }

    private struct Snapshot {
        var people: [PersonEntry] = []
        var morePeople = false
        var rooms: [RoomEntry] = []
        var moreRooms = false
        var failure: String?
    }

    // MARK: - State

    private let appEvents = AppEventObservations()
    private var snapshot = Snapshot()
    private var loading: Task<Void, Never>?
    private let peopleCards = NSStackView()
    private let roomCards = NSStackView()
    private let browserCards = NSStackView()
    private var statusField: NSTextField?
    /// The browser section's fold: a view state, not a preference.
    private var showsBrowserAnswering = false
    private var personButtons: [ObjectIdentifier: WorkroomPersonID] = [:]
    private var invitationButtons: [ObjectIdentifier: WorkroomLinkExtension.Target] = [:]
    private var roomButtons: [ObjectIdentifier: WorkroomID] = [:]
    private var copiedPerson: WorkroomPersonID?
    private var addMessage: String?

    private lazy var enabledToggle = SettingsUI.toggle(isOn: AppSettings.shared.workroomsEnabled,
                                                       target: self, action: #selector(enabledChanged))
    private lazy var providerPopUp: ThemedPopUp = {
        let popUp = SettingsUI.popUp(target: self, action: #selector(providerChanged))
        for provider in WorkroomTunnelProvider.allCases {
            popUp.addItem(ThemedMenuItem(title: provider.displayName, representedValue: provider.rawValue))
        }
        return popUp
    }()
    private lazy var domainField: ThemedTextField = {
        let field = SettingsUI.textField(target: self, action: #selector(domainChanged))
        field.placeholderString = L10n.string("example.ngrok.app")
        return field
    }()
    private lazy var ownerPopUp = SettingsUI.popUp(target: self, action: #selector(ownerChanged))
    private lazy var nameField = SettingsUI.textField(target: self, action: #selector(addPerson), width: 150)
    private lazy var handleField = SettingsUI.textField(target: self, action: #selector(addPerson), width: 110)
    private lazy var languageField = SettingsUI.textField(target: self, action: #selector(addPerson), width: 60)
    private lazy var addButton = SettingsUI.button("Add", target: self, action: #selector(addPerson))

    // MARK: - Lifecycle

    override func loadView() {
        let root = SettingsPageRootView()
        // A search naming the tunnel, its domain or a web link finds it behind the browser fold.
        root.onPrepareToReveal = { [weak self] _ in self?.unfoldBrowserAnswering() ?? false }
        view = root
        nameField.placeholderString = L10n.string("Name")
        handleField.placeholderString = L10n.string("handle")
        languageField.placeholderString = "sv" // localization-ignore: a BCP-47 example, not copy
        appEvents.observe(WorkroomStatusDidChange.self) { [weak self] _ in
            self?.refreshStatus()
            self?.load()
        }
        appEvents.observe(AppSettingsDidChange.self) { [weak self] change in
            guard change.affects(AppSettingIdentity.workroomsEnabled.rawValue,
                                 AppSettingIdentity.workroomTunnelProvider.rawValue,
                                 AppSettingIdentity.workroomNgrokDomain.rawValue) else { return }
            self?.refreshSettings()
        }
        buildPage()
        refreshSettings()
        refreshData()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        load()
    }

    // MARK: - Loading

    private func load() {
        loading?.cancel()
        loading = Task { [weak self] in
            let snapshot = await Self.read()
            guard !Task.isCancelled, let self else { return }
            self.snapshot = snapshot
            self.refreshData()
        }
    }

    private static func read() async -> Snapshot {
        var snapshot = Snapshot()
        do {
            let store = try await MacMailbox.shared.controllerStore()
            let people = try await store.workroomPeople(limit: WorkroomsPageDefaults.people + 1)
            snapshot.morePeople = people.items.count > WorkroomsPageDefaults.people
            for person in people.items.prefix(WorkroomsPageDefaults.people) {
                snapshot.people.append(PersonEntry(person: person,
                                                   devices: try await store.workroomDevices(person: person.id),
                                                   invitation: try await store.latestWorkroomInvitation(person: person.id),
                                                   app: await RemoteAccessCoordinator.shared.access(forWorkroomPerson: person.id)))
            }
            // Newest rooms last in storage order; the page shows the newest few.
            var rooms: [LinkedWorkroom] = []
            var after: Int64 = 0
            for _ in 0..<WorkroomsPageDefaults.roomPages {
                let page = try await store.allWorkrooms(after: after, limit: 50)
                rooms += page.items
                guard page.items.count == 50 else { break }
                after = page.next
            }
            snapshot.moreRooms = rooms.count > WorkroomsPageDefaults.rooms
            for room in rooms.suffix(WorkroomsPageDefaults.rooms).reversed() {
                snapshot.rooms.append(RoomEntry(summary: try await store.workroomSummary(room.id)))
            }
        } catch {
            snapshot.failure = MacMailbox.describe(error)
        }
        return snapshot
    }

    // MARK: - Building

    private func buildPage() {
        for cards in [peopleCards, roomCards, browserCards] {
            cards.orientation = .vertical
            cards.alignment = .leading
            cards.spacing = 0
        }
        let sections: [NSView] = [
            SettingsUI.section(nil, SettingsCard(rows: [
                SettingsUI.row(
                    title: "Ask people outside this Mac",
                    subtitle: "Structured questions to domain experts; answers return as mail.",
                    help: SettingsUI.help(
                        "Linked Workrooms",
                        "An agent can create a private room in its project when you ask, and put questions in it to people you add here. Nothing is reachable from outside this Mac until you approve opening a room to a person.",
                        "The person answers in the Threading app or, through a link you send them, in a browser. Their answers are information for the agent, never approvals or permissions."
                    ),
                    control: enabledToggle
                ),
                SettingsUI.row(
                    title: "Questions for you go to",
                    subtitle: "A chat tied to a workroom asks you here instead of waiting in its terminal.",
                    help: SettingsUI.help(
                        "Questions for you",
                        "A chat that created or asked in an open workroom must not stop on a question in its terminal. Questions for you go to this person through the workroom, like any other person's, and the answer comes back to the chat as mail.",
                        "Add yourself as a person first. You are added to every room you approve opening, so you can answer from your own phone."
                    ),
                    control: ownerPopUp
                )
            ])),
            SettingsUI.section("People", peopleCards, help: SettingsUI.help(
                "People",
                "Invite to App… shows a code the person scans with their phone's camera. The Threading app then shows them only their own questions, with notifications, and never anything else on this Mac.",
                "Sign Out ends a person's app access and their browsers. A chat's own Workroom panel lists the people of its rooms with the same invitation."
            )),
            SettingsUI.section("Rooms", roomCards),
            SettingsUI.section(nil, browserCards)
        ]
        let closeAll = SettingsUI.button("Close All Workrooms", target: self, action: #selector(closeAll))
        let page = SettingsUI.page(title: "Workrooms",
                                   summary: "Questions for people outside this Mac.",
                                   actions: [closeAll], sections: sections)
        page.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(page)
        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            page.topAnchor.constraint(equalTo: view.topAnchor),
            page.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func refreshSettings() {
        enabledToggle.state = AppSettings.shared.workroomsEnabled ? .on : .off
        let provider = AppSettings.shared.workroomTunnelProvider
        providerPopUp.selectItem(at: WorkroomTunnelProvider.allCases.firstIndex(of: provider) ?? 0)
        if domainField.currentEditor() == nil { domainField.stringValue = AppSettings.shared.workroomNgrokDomain ?? "" }
        domainField.isEnabled = provider == .ngrok
        refreshStatus()
    }

    private func refreshStatus() {
        statusField?.stringValue = statusLine()
    }

    private func refreshData() {
        let focusedControl = keyControls(in: view).first { control in
            guard let responder = view.window?.firstResponder else { return false }
            return responder === control || (control as? NSTextField)?.currentEditor() === responder
        }
        personButtons.removeAll()
        invitationButtons.removeAll()
        roomButtons.removeAll()
        replaceCard(in: peopleCards, rows: peopleRows())
        replaceCard(in: roomCards, rows: roomRows())
        replaceBrowserCard()
        updateKeyViewLoop()
        if let focusedControl, focusedControl.window === view.window {
            view.window?.makeFirstResponder(focusedControl)
        }
    }

    private func replaceCard(in stack: NSStackView, rows: [NSView]) {
        install(SettingsCard(rows: rows), in: stack)
    }

    private func install(_ card: NSView, in stack: NSStackView) {
        for old in stack.arrangedSubviews { stack.removeArrangedSubview(old); old.removeFromSuperview() }
        stack.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    /// The web path, folded: the tunnel, its domain, and each person's single-use web link. Only
    /// someone without the app needs any of it.
    private func replaceBrowserCard() {
        statusField = nil
        var rows: [NSView] = []
        if showsBrowserAnswering {
            var tunnelStatus: NSTextField?
            rows.append(SettingsUI.row(title: "Tunnel", subtitle: statusLine(), help: SettingsUI.help(
                "Public Address",
                "An open room is published through a tunnel to a port on this Mac that serves only the people's pages. The tunnel provider terminates the connection and can read what passes through it.",
                "ngrok uses your own ngrok configuration and account. A Cloudflare Quick Tunnel needs no account, but its address changes whenever Threading restarts, so links you sent stop working."
            ), control: providerPopUp, subtitleField: &tunnelStatus))
            statusField = tunnelStatus
            rows.append(SettingsUI.row(title: "Reserved domain", subtitle: "Optional. Keeps links working after a restart.",
                                       control: domainField))
            rows += snapshot.people.map(browserRow)
        }
        install(SettingsUI.disclosureCard(
            title: "Answer in a browser",
            subtitle: "For someone without the app: a single-use link to their questions, published through a tunnel while a room is open.",
            isExpanded: showsBrowserAnswering,
            accessibilityIdentifier: WorkroomsPageIdentifiers.browserAnswering,
            onToggle: { [weak self] expanded in
                self?.showsBrowserAnswering = expanded
                self?.refreshData()
            },
            detailRows: rows
        ), in: browserCards)
    }

    /// Opens the browser fold for a settings search; false when it was open already.
    private func unfoldBrowserAnswering() -> Bool {
        guard !showsBrowserAnswering else { return false }
        showsBrowserAnswering = true
        refreshData()
        return true
    }

    private func browserRow(_ entry: PersonEntry) -> NSView {
        let person = entry.person
        let copy = SettingsUI.button(copiedPerson == person.id ? "Copied" : "Copy Link", target: self,
                                     action: #selector(copyLink(_:)))
        copy.isEnabled = WorkroomHost.shared.publishedOrigin != nil
        personButtons[ObjectIdentifier(copy)] = person.id
        var controls = [copy]
        if let invitation = entry.invitation, invitation.state == .pending {
            let extend = SettingsUI.button("Extend Link…", target: self, action: #selector(extendLink(_:)))
            invitationButtons[ObjectIdentifier(extend)] = .init(person: person, invitation: invitation)
            controls.append(extend)
        }
        return SettingsUI.row(title: person.name, subtitle: browserLine(entry),
                              control: SettingsUI.controlGroup(controls, spacing: Design.Spacing.small),
                              localizes: false)
    }

    private func updateKeyViewLoop() {
        let controls = keyControls(in: view)
        guard let first = controls.first else { return }
        for (current, next) in zip(controls, Array(controls.dropFirst()) + [first]) {
            current.nextKeyView = next
        }
    }

    /// Settings rows add their help buttons inside the label column. Following the view tree
    /// keeps those buttons in the Tab loop beside the form controls and any loaded room actions.
    private func keyControls(in root: NSView) -> [NSView] {
        let current: [NSView] = (root is ThemedControl || root is ThemedTextField) ? [root] : []
        return current + root.subviews.flatMap(keyControls(in:))
    }

    private func statusLine() -> String {
        guard AppSettings.shared.workroomsEnabled else { return L10n.string("Workrooms is off.") }
        switch WorkroomHost.shared.status {
        case .off: return L10n.string("Nothing is published until you open a room.")
        case .idle: return L10n.string("Nothing is published until you open a room.")
        case .starting: return L10n.string("Starting the tunnel…")
        case .published(let url): return L10n.format("Published at %@", url.host ?? url.absoluteString)
        case .unavailable(let message): return message
        }
    }

    private func peopleRows() -> [NSView] {
        ownerPopUp.removeAllItems()
        ownerPopUp.addItem(ThemedMenuItem(title: L10n.string("Nobody"), representedValue: ""))
        for entry in snapshot.people {
            ownerPopUp.addItem(ThemedMenuItem(title: entry.person.name, representedValue: entry.person.handle))
        }
        let owner = AppSettings.shared.workroomOwnerHandle
        ownerPopUp.selectItem(at: snapshot.people.firstIndex { $0.person.handle == owner }.map { $0 + 1 } ?? 0)
        var rows: [NSView] = snapshot.people.map { entry in
            let person = entry.person
            var controls: [NSView] = []
            if person.handle != owner {
                let invite = SettingsUI.button("Invite to App…", target: self, action: #selector(inviteToApp(_:)))
                personButtons[ObjectIdentifier(invite)] = person.id
                controls.append(invite)
            }
            let signOut = SettingsUI.button("Sign Out", target: self, action: #selector(signOut(_:)))
            signOut.isEnabled = !entry.devices.isEmpty || !entry.app.members.isEmpty || !entry.app.links.isEmpty
            personButtons[ObjectIdentifier(signOut)] = person.id
            controls.append(signOut)
            return SettingsUI.row(title: person.name, subtitle: personLine(entry),
                                  control: SettingsUI.controlGroup(controls, spacing: Design.Spacing.small),
                                  localizes: false)
        }
        if snapshot.morePeople {
            rows.append(SettingsUI.row(title: L10n.format("and more than %d others", WorkroomsPageDefaults.people),
                                       localizes: false))
        }
        rows.append(SettingsUI.row(
            title: "Add a person",
            subtitle: addMessage ?? "Their name, a short handle agents use, and their language.",
            control: SettingsUI.controlGroup([nameField, handleField, languageField, addButton], spacing: Design.Spacing.small),
            localizes: addMessage == nil
        ))
        return rows
    }

    /// Who they are to agents, and where they will see a question — the app first, because that
    /// is where they are told about it.
    private func personLine(_ entry: PersonEntry) -> String {
        [entry.person.handle, entry.person.language,
         WorkroomPaneFeed.personStatus(app: entry.app, browsers: entry.devices,
                                       isOwner: entry.person.handle == AppSettings.shared.workroomOwnerHandle)]
            .joined(separator: WorkroomPaneFeedDefaults.separator)
    }

    /// The person's browsers and their web link, for the folded browser section.
    private func browserLine(_ entry: PersonEntry) -> String {
        var parts: [String] = []
        if let device = entry.devices.first {
            parts.append(L10n.format("%d browsers, last %@", entry.devices.count, Self.short(device.lastSeenAt)))
            parts.append(device.label)
        }
        if let invitation = entry.invitation, invitation.state == .pending {
            let expired = ISO8601DateFormatter().date(from: invitation.expiresAt).map { $0 <= Date() } ?? true
            parts.append(expired
                ? L10n.format("unused link expired %@", Self.short(invitation.expiresAt))
                : L10n.format("link sent, unused until %@", Self.short(invitation.expiresAt)))
        } else if entry.devices.isEmpty {
            parts.append(L10n.string("no link yet"))
        }
        return parts.joined(separator: WorkroomPaneFeedDefaults.separator)
    }

    private func roomRows() -> [NSView] {
        if let failure = snapshot.failure {
            return [SettingsUI.row(title: L10n.string("Workrooms cannot be read"), subtitle: failure, localizes: false)]
        }
        guard !snapshot.rooms.isEmpty else {
            return [SettingsUI.row(title: "No rooms yet", subtitle: "An agent creates one when you ask it to.")]
        }
        var rows: [NSView] = snapshot.rooms.map { entry in
            let summary = entry.summary
            var parts = [WorkroomPaneFeed.roomStatus(summary)]
            if !summary.people.isEmpty { parts.append(summary.people.map(\.name).joined(separator: ", ")) }
            var control: NSView?
            if summary.publication.state == .open {
                let close = SettingsUI.button("Close", target: self, action: #selector(closeRoom(_:)))
                roomButtons[ObjectIdentifier(close)] = summary.room.id
                control = close
            }
            return SettingsUI.row(title: summary.room.title, subtitle: parts.joined(separator: WorkroomPaneFeedDefaults.separator),
                                  control: control, localizes: false)
        }
        if snapshot.moreRooms {
            rows.append(SettingsUI.row(title: L10n.format("Showing the newest %d rooms", WorkroomsPageDefaults.rooms),
                                       localizes: false))
        }
        rows.append(SettingsUI.row(title: "Questions and answers",
                                   subtitle: "Each chat shows its own beside it: choose Workroom from the + menu of its side panel."))
        return rows
    }

    // MARK: - Actions

    @objc private func enabledChanged() {
        AppSettings.shared.workroomsEnabled = enabledToggle.state == .on
    }

    @objc private func ownerChanged() {
        let handle = ownerPopUp.selectedItem?.representedValue as? String ?? ""
        AppSettings.shared.workroomOwnerHandle = handle.isEmpty ? nil : handle
    }

    @objc private func providerChanged() {
        guard let raw = providerPopUp.selectedItem?.representedValue as? String,
              let provider = WorkroomTunnelProvider(rawValue: raw) else { return }
        AppSettings.shared.workroomTunnelProvider = provider
    }

    @objc private func domainChanged() {
        let value = domainField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.isEmpty || WorkroomTunnelRecipe.isValidDomain(value) else {
            domainField.stringValue = AppSettings.shared.workroomNgrokDomain ?? ""
            SystemAlert.refuse()
            return
        }
        AppSettings.shared.workroomNgrokDomain = value.isEmpty ? nil : value
    }

    @objc private func addPerson() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let handle = handleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let language = languageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !handle.isEmpty, !language.isEmpty else { return }
        Task { [weak self] in
            do {
                let store = try await MacMailbox.shared.controllerStore()
                _ = try await store.addWorkroomPerson(id: WorkroomPersonID(), handle: handle, name: name, language: language)
                guard let self else { return }
                self.nameField.stringValue = ""
                self.handleField.stringValue = ""
                self.languageField.stringValue = ""
                self.addMessage = nil
                self.load()
            } catch {
                self?.addMessage = WorkroomAgentCommandService.words(for: error)
                self?.refreshData()
            }
        }
    }

    /// A fresh single-use link on the clipboard; any unused earlier one stops working.
    @objc private func copyLink(_ sender: ThemedButton) {
        guard let person = personButtons[ObjectIdentifier(sender)], let origin = WorkroomHost.shared.publishedOrigin else { return }
        Task { [weak self] in
            guard let store = try? await MacMailbox.shared.controllerStore(),
                  let issued = try? await store.issueWorkroomInvitation(person: person) else { return SystemAlert.refuse() }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("\(origin)/join/\(issued.1)", forType: .string)
            self?.copiedPerson = person
            self?.load()
        }
    }

    /// An app invitation for one person, single use, shown as a code to scan with their phone's
    /// camera and a link to copy. It reaches their questions and nothing else, until Sign Out.
    @objc private func inviteToApp(_ sender: ThemedButton) {
        guard let person = personButtons[ObjectIdentifier(sender)] else { return }
        sender.isEnabled = false
        let name = snapshot.people.first { $0.person.id == person }?.person.name ?? ""
        Task { [weak self] in
            await WorkroomAppInvitationAlert.invite(person, name: name, in: self?.view.window)
            sender.isEnabled = true
            self?.load()
        }
    }

    @objc private func signOut(_ sender: ThemedButton) {
        guard let person = personButtons[ObjectIdentifier(sender)] else { return }
        RemoteAccessCoordinator.shared.revokeWorkroomShares(person)
        Task { [weak self] in
            guard let store = try? await MacMailbox.shared.controllerStore() else { return }
            for device in (try? await store.workroomDevices(person: person)) ?? [] {
                try? await store.revokeWorkroomDevice(person: person, deviceID: device.id)
            }
            self?.load()
        }
    }

    @objc private func extendLink(_ sender: ThemedButton) {
        guard let target = invitationButtons[ObjectIdentifier(sender)] else { return }
        WorkroomLinkExtension.start(target: target, in: view.window)
    }

    @objc private func closeRoom(_ sender: ThemedButton) {
        guard let room = roomButtons[ObjectIdentifier(sender)] else { return }
        Task { [weak self] in
            _ = try? await MacMailbox.shared.controllerStore().closeWorkroom(room)
            WorkroomHost.shared.refresh()
            self?.load()
        }
    }

    @objc private func closeAll() {
        Task { [weak self] in
            await WorkroomHost.shared.closeEverything()
            self?.load()
        }
    }

    // MARK: - Formatting

    private static func short(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return iso }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

enum WorkroomsPageDefaults {
    static let people = 50
    static let rooms = 20
    static let roomPages = 4
}

enum WorkroomsPageIdentifiers {
    static let browserAnswering = "settings.workrooms.browser"
}
