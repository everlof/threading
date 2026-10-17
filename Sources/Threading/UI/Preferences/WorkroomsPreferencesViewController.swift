import AppKit
import ThreadingController

// MARK: - Workrooms Preferences

/// Settings ▸ Workrooms: whether agents may ask people outside this Mac at all, how an opened
/// room is reached, who those people are, and which rooms are open to them. Everything an
/// outsider can do starts here or in the opening sheet — the web portal has no owner side.
///
/// The people and rooms are externally sized, so the page reads bounded slices of them
/// (`WorkroomsPageDefaults`) off the main actor and rebuilds only its own small stack.
final class WorkroomsPreferencesViewController: NSViewController {

    private struct PersonEntry {
        let person: WorkroomPerson
        let devices: [WorkroomDevice]
        let invitation: WorkroomInvitation?
    }

    private struct RoomEntry {
        let summary: WorkroomSummary
        let questions: [WorkroomQuestion]
        let people: [WorkroomPersonID: String]
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
    private var page: NSView?
    private var personButtons: [ObjectIdentifier: WorkroomPersonID] = [:]
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
    private lazy var nameField = SettingsUI.textField(target: self, action: #selector(addPerson), width: 150)
    private lazy var handleField = SettingsUI.textField(target: self, action: #selector(addPerson), width: 110)
    private lazy var languageField = SettingsUI.textField(target: self, action: #selector(addPerson), width: 60)

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        nameField.placeholderString = L10n.string("Name")
        handleField.placeholderString = L10n.string("handle")
        languageField.placeholderString = "sv" // localization-ignore: a BCP-47 example, not copy
        appEvents.observe(WorkroomStatusDidChange.self) { [weak self] _ in self?.load() }
        appEvents.observe(AppSettingsDidChange.self) { [weak self] change in
            guard change.affects(AppSettingIdentity.workroomsEnabled.rawValue,
                                 AppSettingIdentity.workroomTunnelProvider.rawValue,
                                 AppSettingIdentity.workroomNgrokDomain.rawValue) else { return }
            self?.rebuild()
        }
        rebuild()
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
            self.rebuild()
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
                                                   invitation: try await store.latestWorkroomInvitation(person: person.id)))
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
            let names = Dictionary(snapshot.people.map { ($0.person.id, $0.person.name) }, uniquingKeysWith: { first, _ in first })
            for room in rooms.suffix(WorkroomsPageDefaults.rooms).reversed() {
                let questions = try await store.workroomAsks(roomID: room.id, limit: WorkroomsPageDefaults.questionsPerRoom)
                snapshot.rooms.append(RoomEntry(summary: try await store.workroomSummary(room.id),
                                                questions: questions.items, people: names))
            }
        } catch {
            snapshot.failure = MacMailbox.describe(error)
        }
        return snapshot
    }

    // MARK: - Building

    private func rebuild() {
        personButtons.removeAll()
        roomButtons.removeAll()
        enabledToggle.state = AppSettings.shared.workroomsEnabled ? .on : .off
        let provider = AppSettings.shared.workroomTunnelProvider
        providerPopUp.selectItem(at: WorkroomTunnelProvider.allCases.firstIndex(of: provider) ?? 0)
        if domainField.currentEditor() == nil { domainField.stringValue = AppSettings.shared.workroomNgrokDomain ?? "" }
        domainField.isEnabled = provider == .ngrok

        var sections: [NSView] = [
            SettingsUI.section(nil, SettingsCard(rows: [SettingsUI.row(
                title: "Ask people outside this Mac",
                subtitle: "Structured questions to domain experts; answers return as mail.",
                help: SettingsUI.help(
                    "Linked Workrooms",
                    "An agent can create a private room in its project when you ask, and put questions in it to people you add here. Nothing is reachable from outside this Mac until you approve opening a room to a person.",
                    "The person answers through a link you send them. Their answers are information for the agent, never approvals or permissions."
                ),
                control: enabledToggle
            )])),
            SettingsUI.section("Public Address", SettingsCard(rows: [
            SettingsUI.row(title: "Tunnel", subtitle: statusLine(), control: providerPopUp),
            SettingsUI.row(title: "Reserved domain", subtitle: "Optional. Keeps links working after a restart.",
                           control: domainField)
        ]), help: SettingsUI.help(
            "Public Address",
            "An open room is published through a tunnel to a port on this Mac that serves only the people's pages. The tunnel provider terminates the connection and can read what passes through it.",
            "ngrok uses your own ngrok configuration and account. A Cloudflare Quick Tunnel needs no account, but its address changes whenever Threading restarts, so links you sent stop working."
        ))
        ]
        sections.append(SettingsUI.section("People", SettingsCard(rows: peopleRows())))
        sections.append(SettingsUI.section("Rooms", SettingsCard(rows: roomRows())))

        let closeAll = SettingsUI.button("Close All Workrooms", target: self, action: #selector(closeAll))
        let built = SettingsUI.page(title: "Workrooms",
                                    summary: "Questions for people outside this Mac.",
                                    actions: [closeAll], sections: sections)
        page?.removeFromSuperview()
        built.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(built)
        NSLayoutConstraint.activate([
            built.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            built.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            built.topAnchor.constraint(equalTo: view.topAnchor),
            built.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        page = built
    }

    private func statusLine() -> String {
        switch WorkroomHost.shared.status {
        case .off: return L10n.string("Workrooms is off.")
        case .idle: return L10n.string("Nothing is published until you open a room.")
        case .starting: return L10n.string("Starting the tunnel…")
        case .published(let url): return L10n.format("Published at %@", url.host ?? url.absoluteString)
        case .unavailable(let message): return message
        }
    }

    private func peopleRows() -> [NSView] {
        var rows: [NSView] = snapshot.people.map { entry in
            let person = entry.person
            let copy = SettingsUI.button(copiedPerson == person.id ? "Copied" : "Copy Link", target: self,
                                         action: #selector(copyLink(_:)))
            copy.isEnabled = WorkroomHost.shared.publishedOrigin != nil
            personButtons[ObjectIdentifier(copy)] = person.id
            let signOut = SettingsUI.button("Sign Out", target: self, action: #selector(signOut(_:)))
            signOut.isEnabled = !entry.devices.isEmpty
            personButtons[ObjectIdentifier(signOut)] = person.id
            return SettingsUI.row(title: person.name, subtitle: personLine(entry),
                                  control: SettingsUI.controlGroup([copy, signOut], spacing: Design.Spacing.small),
                                  localizes: false)
        }
        if snapshot.morePeople {
            rows.append(SettingsUI.row(title: L10n.format("and more than %d others", WorkroomsPageDefaults.people),
                                       localizes: false))
        }
        let add = SettingsUI.button("Add", target: self, action: #selector(addPerson))
        rows.append(SettingsUI.row(
            title: "Add a person",
            subtitle: addMessage ?? "Their name, a short handle agents use, and their language.",
            control: SettingsUI.controlGroup([nameField, handleField, languageField, add], spacing: Design.Spacing.small),
            localizes: addMessage == nil
        ))
        return rows
    }

    private func personLine(_ entry: PersonEntry) -> String {
        var parts = [entry.person.handle, entry.person.language]
        if let device = entry.devices.first {
            parts.append(L10n.format("%d browsers, last %@", entry.devices.count, Self.short(device.lastSeenAt)))
            parts.append(device.label)
        } else if let invitation = entry.invitation, invitation.state == .pending {
            parts.append(L10n.format("link sent, unused until %@", Self.short(invitation.expiresAt)))
        } else {
            parts.append(L10n.string("no link yet"))
        }
        return parts.joined(separator: " · ")
    }

    private func roomRows() -> [NSView] {
        if let failure = snapshot.failure {
            return [SettingsUI.row(title: L10n.string("Workrooms cannot be read"), subtitle: failure, localizes: false)]
        }
        guard !snapshot.rooms.isEmpty else {
            return [SettingsUI.row(title: "No rooms yet", subtitle: "An agent creates one when you ask it to.")]
        }
        var rows: [NSView] = []
        for entry in snapshot.rooms {
            let summary = entry.summary
            var parts = [WorkroomAgentCommandService.state(summary.publication)]
            if summary.publication.isOpen(), let until = summary.publication.expiresAt {
                parts.append(L10n.format("until %@", Self.short(until)))
            }
            if !summary.people.isEmpty { parts.append(summary.people.map(\.name).joined(separator: ", ")) }
            parts.append(L10n.format("%d open questions", summary.openQuestions))
            var control: NSView?
            if summary.publication.state == .open {
                let close = SettingsUI.button("Close", target: self, action: #selector(closeRoom(_:)))
                roomButtons[ObjectIdentifier(close)] = summary.room.id
                control = close
            }
            rows.append(SettingsUI.row(title: summary.room.title, subtitle: parts.joined(separator: " · "),
                                       control: control, localizes: false))
            for question in entry.questions {
                rows.append(SettingsUI.detailRow(
                    symbol: Self.symbol(question.state),
                    title: question.draft.title,
                    detail: [entry.people[question.person] ?? "", question.state.rawValue,
                             question.answerRevision > 0 ? L10n.format("revision %d", question.answerRevision) : ""]
                        .filter { !$0.isEmpty }.joined(separator: " · "),
                    localizes: false
                ))
            }
        }
        if snapshot.moreRooms {
            rows.append(SettingsUI.row(title: L10n.format("Showing the newest %d rooms", WorkroomsPageDefaults.rooms),
                                       localizes: false))
        }
        return rows
    }

    // MARK: - Actions

    @objc private func enabledChanged() {
        AppSettings.shared.workroomsEnabled = enabledToggle.state == .on
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
                self?.rebuild()
            }
        }
    }

    /// A fresh single-use link on the clipboard; any unused earlier one stops working.
    @objc private func copyLink(_ sender: NSButton) {
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

    @objc private func signOut(_ sender: NSButton) {
        guard let person = personButtons[ObjectIdentifier(sender)] else { return }
        Task { [weak self] in
            guard let store = try? await MacMailbox.shared.controllerStore() else { return }
            for device in (try? await store.workroomDevices(person: person)) ?? [] {
                try? await store.revokeWorkroomDevice(person: person, deviceID: device.id)
            }
            self?.load()
        }
    }

    @objc private func closeRoom(_ sender: NSButton) {
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

    private static func symbol(_ state: WorkroomQuestionState) -> String {
        switch state {
        case .open: return "questionmark.bubble"
        case .answered: return "checkmark.bubble"
        case .declined: return "xmark.bubble"
        case .withdrawn: return "arrow.uturn.backward"
        }
    }
}

enum WorkroomsPageDefaults {
    static let people = 50
    static let rooms = 20
    static let roomPages = 4
    static let questionsPerRoom = 5
}
