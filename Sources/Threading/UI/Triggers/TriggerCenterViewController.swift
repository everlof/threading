import AppKit

@MainActor
final class TriggerCenterViewController: NSViewController {
    private enum Page: Int { case triggers, activity, sources }

    private let store: TriggerStore
    private let pages = ThemedSegmentedControl()
    private let primaryAction = ThemedButton()
    private let list = PanelListView(rowSpacing: Design.Spacing.small)
    private let status = NSTextField(labelWithString: "")
    private let events = AppEventObservations()
    private var page: Page = .triggers

    init(store: TriggerStore = .shared) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        build()
        events.observe(.triggersDidChange) { [weak self] in self?.reload() }
        reload()
    }

    private func build() {
        let title = NSTextField(labelWithString: L10n.string("Triggers"))
        title.applyFont(.heading)
        title.textColor = Design.Text.label

        let subtitle = NSTextField(labelWithString: L10n.string(
            "Listen for events, assess them with an agent, and fix only the straightforward ones."
        ))
        subtitle.applyFont(.subheading)
        subtitle.textColor = Design.Text.secondary
        subtitle.lineBreakMode = .byTruncatingTail

        status.applyFont(.detail())
        status.textColor = Design.Text.tertiary
        status.alignment = .right

        pages.configure(titles: [
            L10n.string("Triggers"),
            L10n.string("Activity"),
            L10n.string("Sources"),
        ])
        pages.onSelect = { [weak self] index in
            guard let self, let page = Page(rawValue: index) else { return }
            self.page = page
            self.reload()
        }

        primaryAction.title = L10n.string("Connect Source")
        primaryAction.emphasis = .primary
        primaryAction.target = self
        primaryAction.action = #selector(connectSourcePressed)
        primaryAction.isHidden = true

        let heading = NSStackView(views: [title, subtitle])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = Design.Spacing.tight

        let top = NSStackView(views: [heading, NSView(), status])
        top.orientation = .horizontal
        top.alignment = .centerY
        top.spacing = Design.Spacing.medium
        top.translatesAutoresizingMaskIntoConstraints = false

        let controls = NSStackView(views: [pages, NSView(), primaryAction])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.translatesAutoresizingMaskIntoConstraints = false

        list.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(top)
        view.addSubview(controls)
        view.addSubview(list)

        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: view.topAnchor, constant: Design.Spacing.large),
            top.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Design.Spacing.large),
            top.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Design.Spacing.large),
            controls.topAnchor.constraint(equalTo: top.bottomAnchor, constant: Design.Spacing.medium),
            controls.leadingAnchor.constraint(equalTo: top.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: top.trailingAnchor),
            pages.widthAnchor.constraint(greaterThanOrEqualToConstant: 360),
            list.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: Design.Spacing.medium),
            list.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func reload() {
        status.stringValue = L10n.string("Updating…")
        primaryAction.isHidden = page != .sources
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                switch page {
                case .triggers: renderTriggers(try await store.triggers())
                case .activity:
                    renderRuns(
                        try await store.runs(limit: 250),
                        triggers: try await store.triggers()
                    )
                case .sources:
                    let sources = try await store.sources()
                    let daemonStatusTask = Task.detached(priority: .utility) {
                        try TriggerDaemonStatusStore.statuses()
                    }
                    let registrationTask = Task.detached(priority: .utility) {
                        TriggerDaemonRegistrationCoordinator.currentStatus()
                    }
                    let daemonStatuses = (try? await daemonStatusTask.value) ?? [:]
                    renderSources(
                        sources,
                        daemonStatuses: daemonStatuses,
                        registrationStatus: await registrationTask.value
                    )
                }
            } catch {
                list.clear()
                list.addNote(error.localizedDescription)
                status.stringValue = L10n.string("Unavailable")
            }
        }
    }

    #if DEBUG
    /// Deterministic render-test seam: the shipping segmented control owns the same selection,
    /// while the evidence test awaits the async store projection before capturing pixels.
    func prepareEvidencePage(index: Int) async throws {
        guard let page = Page(rawValue: index) else { return }
        self.page = page
        pages.selectedIndex = index
        primaryAction.isHidden = page != .sources
        switch page {
        case .triggers:
            renderTriggers(try await store.triggers())
        case .activity:
            renderRuns(try await store.runs(limit: 250), triggers: try await store.triggers())
        case .sources:
            renderSources(
                try await store.sources(),
                daemonStatuses: [:],
                registrationStatus: .enabled
            )
        }
    }
    #endif

    private func renderTriggers(
        _ pairs: [(definition: TriggerDefinition, revision: TriggerRevision)]
    ) {
        list.clear()
        status.stringValue = pairs.isEmpty
            ? L10n.string("No triggers")
            : L10n.format("%lld configured", Int64(pairs.count))
        list.addSection(L10n.string("Configured triggers"))
        guard !pairs.isEmpty else {
            list.addNote(L10n.string(
                "Ask an agent to create a disabled draft, or connect a source first. Nothing listens until you activate an exact revision."
            ))
            return
        }
        for pair in pairs {
            let isDraft = pair.definition.draftRevisionID == pair.revision.id
            let state = isDraft
                ? L10n.string("Draft — not listening")
                : (pair.definition.enabled ? L10n.string("Listening") : L10n.string("Paused"))
            let detail = "\(pair.revision.eventKind)  ·  \(state)  ·  "
                + pair.revision.executionMode.displayTitle
            let action: String
            if isDraft {
                action = L10n.string("Review & Activate")
            } else if pair.definition.enabled {
                action = L10n.string("Pause")
            } else {
                action = L10n.string("Resume")
            }
            list.addRow(TriggerCenterRowView(
                title: pair.definition.name,
                detail: detail,
                actionTitle: action,
                onAction: { [weak self] in self?.act(on: pair) },
                secondaryActionTitle: nil,
                onSecondaryAction: nil
            ))
        }
    }

    private func renderRuns(
        _ runs: [TriggerRun],
        triggers: [(definition: TriggerDefinition, revision: TriggerRevision)]
    ) {
        list.clear()
        status.stringValue = runs.isEmpty
            ? L10n.string("No activity")
            : L10n.format("%lld recent", Int64(runs.count))
        list.addSection(L10n.string("Recent activity"))
        guard !runs.isEmpty else {
            list.addNote(L10n.string("Matched events and their agent runs will appear here."))
            return
        }
        let triggerNames = Dictionary(uniqueKeysWithValues: triggers.map {
            ($0.definition.id, $0.definition.name)
        })
        for run in runs {
            let detail = [
                run.state.displayTitle,
                run.result?.summary ?? run.boundedDiagnostic,
                Self.relativeDate.localizedString(for: run.queuedAt, relativeTo: Date()),
            ].compactMap { $0 }.joined(separator: "  ·  ")
            list.addRow(TriggerCenterRowView(
                title: triggerNames[run.triggerID] ?? run.id.uuidString,
                detail: detail,
                actionTitle: nil,
                onAction: nil,
                secondaryActionTitle: nil,
                onSecondaryAction: nil
            ))
        }
    }

    private func renderSources(
        _ sources: [TriggerSourceInstallation],
        daemonStatuses: [TriggerSourceInstallationID: TriggerDaemonSourceStatus],
        registrationStatus: TriggerDaemonRegistrationStatus
    ) {
        list.clear()
        status.stringValue = sources.isEmpty
            ? L10n.string("No sources")
            : (sources.count == 1
                ? L10n.string("1 source")
                : L10n.format("%lld sources", Int64(sources.count)))
        guard !sources.isEmpty else {
            list.addSection(L10n.string("Event sources"))
            list.addNote(L10n.string(
                "Sources run through Threading’s background listener, so events can wake the app even when its window is closed."
            ))
            return
        }
        list.addSection(L10n.string("Background listener"))
        list.addRow(TriggerCenterRowView(
            title: L10n.string("Runs while Threading is closed"),
            detail: registrationStatus.displayTitle,
            actionTitle: registrationStatus.actionTitle,
            onAction: registrationStatus.actionTitle == nil ? nil : { [weak self] in
                guard let self else { return }
                if registrationStatus == .requiresApproval {
                    TriggerDaemonRegistrationCoordinator.openLoginItemsSettings()
                } else {
                    TriggerDaemonRegistrationCoordinator.shared.reconcile(shouldRun: true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        self?.reload()
                    }
                }
            },
            secondaryActionTitle: nil,
            onSecondaryAction: nil
        ))
        list.addSection(L10n.string("Event sources"))
        for source in sources {
            let daemonStatus = daemonStatuses[source.id].flatMap {
                $0.lastCheckedAt >= source.updatedAt ? $0 : nil
            }
            let checked = (daemonStatus?.lastCheckedAt ?? source.lastCheckedAt).map {
                Self.relativeDate.localizedString(for: $0, relativeTo: Date())
            }
            let health = source.enabled ? (daemonStatus?.health ?? source.health) : .disconnected
            let detail = [source.sourceType, health.displayTitle, checked,
                          daemonStatus?.boundedDiagnostic ?? source.boundedDiagnostic]
                .compactMap { $0 }.joined(separator: "  ·  ")
            list.addRow(TriggerCenterRowView(
                title: source.displayName,
                detail: detail,
                actionTitle: source.credentialReference == nil
                    ? L10n.string("Reconnect")
                    : (source.enabled ? L10n.string("Pause") : L10n.string("Resume")),
                onAction: { [weak self] in
                    if source.credentialReference == nil {
                        self?.connectSource(replacing: source)
                    } else {
                        self?.toggleSource(source)
                    }
                },
                secondaryActionTitle: source.credentialReference == nil
                    ? nil : L10n.string("Disconnect"),
                onSecondaryAction: { [weak self] in self?.disconnectSource(source) }
            ))
        }
    }

    @objc private func connectSourcePressed() {
        connectSource(replacing: nil)
    }

    private func connectSource(replacing existing: TriggerSourceInstallation?) {
        let name = ThemedTextField()
        name.placeholderString = L10n.string("Sonda Demo")
        name.stringValue = existing?.displayName ?? ""
        let baseURL = ThemedTextField()
        // localization-ignore: HTTPS format example, not presentation prose.
        baseURL.placeholderString = "https://demo.example.com"
        if case .string(let configuredURL)? = existing?.configuration["base_url"] {
            baseURL.stringValue = configuredURL
        }
        let credential = ThemedSecureField()
        credential.placeholderString = L10n.string("Scoped API key")

        let adapter = NSTextField(labelWithString: L10n.string(
            "Adapter: Sonda review-required events"
        ))
        adapter.applyFont(.detail())
        adapter.textColor = Design.Text.secondary
        let fields = NSStackView(views: [adapter, name, baseURL, credential])
        fields.orientation = .vertical
        fields.alignment = .leading
        fields.spacing = Design.Spacing.small
        for field in [name, baseURL, credential] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 420).isActive = true
        }

        let request = ConfirmationRequest(
            prompt: .connectTriggerSource,
            title: L10n.string("Connect an Event Source"),
            message: L10n.string(
                "Threading stores the scoped key in your Keychain. Its background listener uses it only to read bounded event metadata from this exact HTTPS service."
            ),
            confirmTitle: L10n.string("Connect"),
            accessory: fields
        )
        ConfirmationAlert.ask(request, in: view.window) { [weak self] approved in
            guard approved else { return }
            self?.saveSondaSource(
                name: name.stringValue,
                baseURL: baseURL.stringValue,
                credential: credential.stringValue,
                replacing: existing
            )
        }
    }

    private func saveSondaSource(
        name rawName: String,
        baseURL rawURL: String,
        credential: String,
        replacing existing: TriggerSourceInstallation?
    ) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawURL = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 160,
              !credential.isEmpty,
              let url = URL(string: rawURL),
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false,
              url.user == nil,
              url.password == nil else {
            presentSourceFailure(L10n.string(
                "Enter a short name, a full HTTPS URL without embedded credentials, and a scoped API key."
            ))
            return
        }

        let sourceID = existing?.id ?? TriggerSourceInstallationID()
        let credentialReference = UUID().uuidString.lowercased()
        let now = Date()
        let source = TriggerSourceInstallation(
            id: sourceID,
            sourceType: "sonda",
            displayName: name,
            configuration: ["base_url": .string(url.absoluteString)],
            credentialReference: credentialReference,
            enabled: true,
            health: .checking,
            lastCheckedAt: nil,
            lastEventAt: nil,
            boundedDiagnostic: nil,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.detached(priority: .utility) {
                    try TriggerSourceCredentialStore.save(
                        credential,
                        reference: credentialReference
                    )
                }.value
                try await store.saveSource(source)
                if let previous = existing?.credentialReference,
                   previous != credentialReference {
                    try? await Task.detached(priority: .utility) {
                        try TriggerSourceCredentialStore.delete(reference: previous)
                    }.value
                }
            } catch {
                let persistedReference = (try? await store.source(id: sourceID))?
                    .credentialReference
                if persistedReference != credentialReference {
                    try? await Task.detached(priority: .utility) {
                        try TriggerSourceCredentialStore.delete(reference: credentialReference)
                    }.value
                }
                presentSourceFailure(error.localizedDescription)
            }
        }
    }

    private func presentSourceFailure(_ detail: String) {
        let alert = ThemedAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.string("The source was not connected")
        alert.informativeText = detail
        alert.addButton(withTitle: L10n.string("OK"))
        if let window = view.window { alert.beginSheetModal(for: window) }
    }

    private func toggleSource(_ original: TriggerSourceInstallation) {
        guard original.credentialReference != nil else {
            connectSource(replacing: original)
            return
        }
        var source = original
        source.enabled.toggle()
        source.health = source.enabled ? .checking : .disconnected
        source.updatedAt = Date()
        source.boundedDiagnostic = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await store.saveSource(source)
                if source.enabled { try? await TriggerRuntime.shared.releaseQueue() }
            } catch {
                presentSourceFailure(error.localizedDescription)
            }
        }
    }

    private func disconnectSource(_ original: TriggerSourceInstallation) {
        let request = ConfirmationRequest(
            prompt: .connectTriggerSource,
            title: L10n.format("Disconnect “%@”?", original.displayName),
            message: L10n.string(
                "Threading will stop this listener and remove its scoped key from Keychain. Existing trigger definitions and run history stay visible, but they cannot receive new events until you reconnect the source."
            ),
            confirmTitle: L10n.string("Disconnect")
        )
        ConfirmationAlert.ask(request, in: view.window) { [weak self] approved in
            guard approved, let self else { return }
            Task { @MainActor in
                var source = original
                let credentialReference = source.credentialReference
                source.credentialReference = nil
                source.enabled = false
                source.health = .disconnected
                source.updatedAt = Date()
                source.boundedDiagnostic = nil
                do {
                    try await self.store.saveSource(source)
                    if let credentialReference {
                        try await Task.detached(priority: .utility) {
                            try TriggerSourceCredentialStore.delete(reference: credentialReference)
                        }.value
                    }
                } catch {
                    self.presentSourceFailure(error.localizedDescription)
                }
            }
        }
    }

    private func act(
        on pair: (definition: TriggerDefinition, revision: TriggerRevision)
    ) {
        if pair.definition.draftRevisionID == pair.revision.id {
            let request = ConfirmationRequest(
                prompt: .approveTriggerActivation,
                title: L10n.format("Activate “%@”?", pair.definition.name),
                message: L10n.string(
                    "Review the exact listener, project, instructions, and authority below. The first stage is read-only; local fixes use a separate permission stage. Threading will not push, deploy, open a review, or write back to the source."
                ),
                confirmTitle: L10n.string("Activate"),
                accessory: triggerReviewAccessory(pair.revision)
            )
            ConfirmationAlert.ask(request, in: view.window) { [weak self] approved in
                guard approved else { return }
                Task { @MainActor in
                    try? await self?.store.activate(
                        triggerID: pair.definition.id,
                        revisionID: pair.revision.id
                    )
                }
            }
            return
        }

        Task { @MainActor [weak self] in
            try? await self?.store.setEnabled(
                !pair.definition.enabled,
                triggerID: pair.definition.id
            )
        }
    }

    private func triggerReviewAccessory(_ revision: TriggerRevision) -> NSView {
        let facts = NSTextField(wrappingLabelWithString: L10n.format(
            "Source: %@\nEvent: %@\nProject: %@\nAgent: %@\nMode: %@\nCheckout: %@\nMaximum concurrent runs: %lld",
            revision.sourceInstallationID.uuidString,
            revision.eventKind,
            revision.projectID.uuidString,
            revision.agentKind.displayName,
            revision.executionMode.displayTitle,
            revision.checkoutPolicy.displayTitle,
            Int64(revision.limits.maximumConcurrentRuns)
        ))
        facts.applyFont(.detail())
        facts.textColor = Design.Text.secondary

        let conditionsTitle = NSTextField(labelWithString: L10n.string("Match conditions"))
        conditionsTitle.applyFont(.emphasizedBody)
        conditionsTitle.textColor = Design.Text.label
        let conditions = ThemedTextView.scrolling()
        conditions.textView.string = revision.conditions.isEmpty
            ? L10n.string("Any event of this kind")
            : revision.conditions.map(\.reviewDescription).joined(separator: "\n")
        conditions.textView.isEditable = false
        conditions.textView.isSelectable = true
        conditions.translatesAutoresizingMaskIntoConstraints = false

        let instructionsTitle = NSTextField(labelWithString: L10n.string("Agent instructions"))
        instructionsTitle.applyFont(.emphasizedBody)
        instructionsTitle.textColor = Design.Text.label
        let instructions = ThemedTextView.scrolling()
        instructions.textView.string = revision.instructions
        instructions.textView.isEditable = false
        instructions.textView.isSelectable = true
        instructions.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [
            facts,
            conditionsTitle,
            conditions,
            instructionsTitle,
            instructions,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.small
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: 520),
            conditions.widthAnchor.constraint(equalTo: stack.widthAnchor),
            conditions.heightAnchor.constraint(equalToConstant: 90),
            instructions.widthAnchor.constraint(equalTo: stack.widthAnchor),
            instructions.heightAnchor.constraint(equalToConstant: 150),
        ])
        return stack
    }

    private static let relativeDate: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

private extension TriggerCheckoutPolicy {
    var displayTitle: String {
        switch self {
        case .projectCheckout: return L10n.string("Existing project checkout")
        case .managedWorktree: return L10n.string("Isolated managed worktree")
        }
    }
}

@MainActor
private final class TriggerCenterRowView: NSView {
    private let onAction: (() -> Void)?
    private let onSecondaryAction: (() -> Void)?

    init(
        title: String,
        detail: String,
        actionTitle: String?,
        onAction: (() -> Void)?,
        secondaryActionTitle: String?,
        onSecondaryAction: (() -> Void)?
    ) {
        self.onAction = onAction
        self.onSecondaryAction = onSecondaryAction
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.applyFont(.emphasizedBody)
        titleLabel.textColor = Design.Text.label
        titleLabel.lineBreakMode = .byTruncatingMiddle

        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.applyFont(.detail())
        detailLabel.textColor = Design.Text.secondary
        detailLabel.maximumNumberOfLines = 2

        let copy = NSStackView(views: [titleLabel, detailLabel])
        copy.orientation = .vertical
        copy.alignment = .leading
        copy.spacing = Design.Spacing.tight

        var views: [NSView] = [copy, NSView()]
        if let secondaryActionTitle {
            let button = ThemedButton()
            button.title = secondaryActionTitle
            button.emphasis = .tertiary
            button.target = self
            button.action = #selector(secondaryPressed)
            views.append(button)
        }
        if let actionTitle {
            let button = ThemedButton()
            button.title = actionTitle
            button.emphasis = .secondary
            button.target = self
            button.action = #selector(pressed)
            views.append(button)
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Design.Spacing.medium
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: Design.Spacing.small),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Design.Spacing.small),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func pressed() { onAction?() }
    @objc private func secondaryPressed() { onSecondaryAction?() }
}

private extension TriggerExecutionMode {
    var displayTitle: String {
        switch self {
        case .assessOnly: return L10n.string("Assess only")
        case .assessThenFix: return L10n.string("Assess, then fix if straightforward")
        }
    }
}

private extension TriggerCondition {
    var reviewDescription: String {
        let comparisonText = comparison.rawValue
        guard let value else { return "\(attribute)  \(comparisonText)" }
        return "\(attribute)  \(comparisonText)  \(value.reviewDescription)"
    }
}

private extension TriggerAttributeValue {
    var reviewDescription: String {
        switch self {
        case .string(let value): return String(reflecting: value)
        case .integer(let value): return String(value)
        case .decimal(let value): return String(value)
        case .boolean(let value): return String(value)
        case .timestamp(let value): return value.formatted(.iso8601)
        }
    }
}

private extension TriggerRunState {
    var displayTitle: String {
        switch self {
        case .received: return L10n.string("Received")
        case .suppressed: return L10n.string("Suppressed")
        case .queued: return L10n.string("Queued")
        case .assessing: return L10n.string("Assessing")
        case .fixQueued: return L10n.string("Queued")
        case .fixing: return L10n.string("Fixing")
        case .needsAttention: return L10n.string("Needs attention")
        case .completed: return L10n.string("Ready to verify")
        case .failed: return L10n.string("Failed")
        case .cancelled: return L10n.string("Cancelled")
        }
    }
}

private extension TriggerSourceHealth {
    var displayTitle: String {
        switch self {
        case .disconnected: return L10n.string("Disconnected")
        case .healthy: return L10n.string("Healthy")
        case .checking: return L10n.string("Checking")
        case .backingOff: return L10n.string("Backing off")
        case .authenticationRequired: return L10n.string("Authentication required")
        case .failed: return L10n.string("Failed")
        }
    }
}

private extension TriggerDaemonRegistrationStatus {
    var displayTitle: String {
        switch self {
        case .enabled:
            return L10n.string("Enabled in Login Items")
        case .requiresApproval:
            return L10n.string("Waiting for approval in System Settings ▸ General ▸ Login Items")
        case .notRegistered, .notFound, .unknown:
            return L10n.string("Not running; retry registration to keep listening in the background")
        case .missingHelper:
            return L10n.string("The background listener is unavailable in this build")
        }
    }

    var actionTitle: String? {
        switch self {
        case .requiresApproval: return L10n.string("Open Login Items…")
        case .notRegistered, .notFound, .unknown: return L10n.string("Retry")
        case .enabled, .missingHelper: return nil
        }
    }
}
