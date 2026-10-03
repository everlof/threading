import AppKit
import ThreadingController

@MainActor
final class RemoteAutomationsViewController: NSViewController {
    private let hosts = ThemedPopUp()
    private let executable = ThemedTextField()
    private let database = ThemedTextField()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let list = PanelListView(rowSpacing: Design.Spacing.small)
    private var records: [RemoteHostRecord] = []
    private var cursor: Int64 = 0
    private var nextCursor: Int64 = 0
    private var busy = false
    private var actions: [ObjectIdentifier: () -> Void] = [:]
    private var connectionActions: [ThemedButton] = []

    override func loadView() {
        view = NSView()
        let form = NSStackView(); form.orientation = .vertical; form.alignment = .leading
        form.spacing = Design.Spacing.small; form.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(form)
        records = RemoteHostStore.shared.ordered
        for host in records { hosts.addItem(withTitle: host.displayName) }
        hosts.target = self; hosts.action = #selector(hostChanged)
        // localization-ignore: example absolute executable path
        executable.placeholderString = "/home/user/.local/bin/threading-controller"
        // localization-ignore: example absolute database path
        database.placeholderString = "/home/user/.local/state/threading/controller/controller.db"
        for (title, control) in [("Host", hosts as NSView), ("Controller executable", executable), ("Controller database", database)] {
            let label = NSTextField(labelWithString: L10n.string(title)); label.applyFont(.detail())
            control.setAccessibilityLabel(L10n.string(title))
            form.addArrangedSubview(label); form.addArrangedSubview(control)
        }
        let refresh = button("Connect", #selector(refreshPressed))
        let create = button("New automation", #selector(createPressed))
        let previous = button("First page", #selector(firstPressed))
        let next = button("Next", #selector(nextPressed))
        refresh.setAccessibilityIdentifier("automation.remote.connect")
        let usage = button("Agent usage…", #selector(usagePressed))
        usage.setAccessibilityIdentifier("automation.remote.usage")
        connectionActions = [refresh, create, usage, previous, next]
        let actions = NSStackView(views: [refresh, create, usage, NSView(), previous, next]); actions.orientation = .horizontal
        form.addArrangedSubview(actions)
        status.applyFont(.detail()); status.textColor = Design.Text.secondary
        form.addArrangedSubview(status); form.addArrangedSubview(list)
        for child in form.arrangedSubviews { child.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([
            form.topAnchor.constraint(equalTo: view.topAnchor), form.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: view.trailingAnchor), form.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        hostChanged()
    }
    private func button(_ title: String, _ selector: Selector) -> ThemedButton {
        let button = ThemedButton(); button.title = L10n.string(title); button.target = self; button.action = selector
        return button
    }
    @objc private func hostChanged() {
        cursor = 0; nextCursor = 0; list.clear()
        let hasHost = records.indices.contains(hosts.indexOfSelectedItem)
        for action in connectionActions { action.isEnabled = hasHost }
        guard hasHost else {
            status.stringValue = L10n.string("Add a remote host in Settings first."); return
        }
        let host = records[hosts.indexOfSelectedItem]
        executable.stringValue = host.controllerExecutable ?? ""
        database.stringValue = host.controllerDatabase ?? ""
        status.stringValue = L10n.string("Connect to the controller installed on this host. Its supervisor runs schedules even when this Mac is offline.")
    }
    func refreshHosts() {
        let current = RemoteHostStore.shared.ordered
        guard current != records else { return }
        let selected = records.indices.contains(hosts.indexOfSelectedItem) ? records[hosts.indexOfSelectedItem].id : nil
        records = current; hosts.removeAllItems()
        for host in records { hosts.addItem(withTitle: host.displayName) }
        if let selected, let index = records.firstIndex(where: { $0.id == selected }) { hosts.selectItem(at: index) }
        hostChanged()
    }

    private func endpoint() throws -> (RemoteAutomationEndpoint, RemoteHostRecord) {
        guard records.indices.contains(hosts.indexOfSelectedItem) else { throw TriggerStore.StoreError.missing }
        let host = records[hosts.indexOfSelectedItem]
        let endpoint = RemoteAutomationEndpoint(hostID: host.id, executable: executable.stringValue, database: database.stringValue)
        try endpoint.validate()
        return (endpoint, host)
    }
    @objc private func refreshPressed() { refresh() }
    /// What this host's workers spent, from its own ledger (RemoteWorkerUsageViewController).
    @objc private func usagePressed() {
        do {
            let (endpoint, host) = try endpoint()
            presentAsSheet(RemoteWorkerUsageViewController(host: RemoteAgentUsageHost(
                id: host.id, name: host.displayName, endpoint: endpoint, destination: host.sshDestination)))
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func firstPressed() { cursor = 0; refresh() }
    @objc private func nextPressed() { cursor = nextCursor; refresh() }
    private func refresh() {
        guard !busy else { return }
        do {
            let (endpoint, host) = try endpoint()
            busy = true; status.stringValue = L10n.string("Connecting…")
            Task { @MainActor in
                defer { busy = false }
                do {
                    let json = try await AutomationCommands.remote(.init(operation: "list", remote: endpoint, cursor: cursor), destination: host.sshDestination)
                    let page = try await Task.detached(priority: .utility) { try JSONDecoder().decode(ControllerPage<ControllerAutomation>.self, from: Data(json.utf8)) }.value
                    guard try self.endpoint().0 == endpoint else { return }
                    guard RemoteHostStore.shared.host(withID: host.id) == host else {
                        throw TriggerStore.StoreError.invalidRecord("The host changed while connecting. Refresh the connection.")
                    }
                    var saved = host; saved.controllerExecutable = endpoint.executable; saved.controllerDatabase = endpoint.database
                    guard RemoteHostStore.shared.update(saved) == .applied else { throw TriggerStore.StoreError.invalidRecord("could not save controller connection") }
                    if let index = records.firstIndex(where: { $0.id == host.id }) { records[index] = saved }
                    nextCursor = page.items.isEmpty ? 0 : page.next
                    render(page.items, endpoint: endpoint, host: host)
                    status.stringValue = L10n.format("%lld automations on %@", Int64(page.items.count), host.displayName)
                } catch { status.stringValue = error.localizedDescription }
            }
        } catch { status.stringValue = error.localizedDescription }
    }
    private func render(_ automations: [ControllerAutomation], endpoint: RemoteAutomationEndpoint, host: RemoteHostRecord) {
        list.clear(); actions.removeAll()
        for automation in automations where !automation.deleted {
            let title = NSTextField(labelWithString: automation.spec.name); title.applyFont(.emphasizedBody)
            let timing = automation.spec.schedule?.summary ?? L10n.string("Manual or event-driven")
            let next = automation.nextRunAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—"
            let detailText = "\(timing) · \(automation.enabled ? L10n.string("Enabled") : L10n.string("Paused")) · \(next)"
            let detail = NSTextField(wrappingLabelWithString: detailText)
            detail.applyFont(.detail()); detail.textColor = Design.Text.secondary
            let edit = action("Edit…") { [weak self] in self?.edit(automation, endpoint: endpoint, host: host) }
            let toggle = action(automation.enabled ? "Pause" : "Enable") { [weak self] in
                self?.perform(automation.enabled ? "pause" : "enable", automation: automation, endpoint: endpoint, host: host)
            }
            let run = action("Run now") { [weak self] in self?.perform("run", automation: automation, endpoint: endpoint, host: host) }
            let history = action("Activity") { [weak self] in self?.perform("runs", automation: automation, endpoint: endpoint, host: host) }
            let delete = action("Delete") { [weak self] in self?.perform("delete", automation: automation, endpoint: endpoint, host: host) }
            let actions = NSStackView(views: [edit, toggle, run, history, delete]); actions.orientation = .horizontal
            let row = NSStackView(views: [title, detail, actions]); row.orientation = .vertical; row.alignment = .leading
            row.spacing = Design.Spacing.small; list.addRow(row)
        }
    }
    private func action(_ title: String, _ block: @escaping () -> Void) -> ThemedButton {
        let button = ThemedButton(); button.title = L10n.string(title)
        button.target = self; button.action = #selector(actionPressed(_:))
        actions[ObjectIdentifier(button)] = block
        return button
    }
    @objc private func actionPressed(_ sender: ThemedButton) { actions[ObjectIdentifier(sender)]?() }
    @objc private func createPressed() {
        do { let (endpoint, host) = try endpoint(); edit(nil, endpoint: endpoint, host: host) }
        catch { status.stringValue = error.localizedDescription }
    }
    private func edit(_ automation: ControllerAutomation?, endpoint: RemoteAutomationEndpoint, host: RemoteHostRecord) {
        let automationID = automation?.id.description ?? UUID().uuidString
        Task { @MainActor in
        do {
        let response = try await AutomationCommands.remote(.init(operation: "workers", remote: endpoint), destination: host.sshDestination)
        let page = try await Task.detached(priority: .utility) {
            try JSONDecoder().decode(ControllerPage<ControllerWorker>.self, from: Data(response.utf8))
        }.value
        let editor = AutomationEditorViewController(remoteSpec: automation?.spec, remote: true, workers: page.items)
        editor.onSave = { [weak self] _, spec in
            _ = try await AutomationCommands.remote(.init(operation: "configure",
                id: automationID,
                expectedRevision: String(automation?.revision ?? 0), remote: endpoint, remoteSpec: spec), destination: host.sshDestination)
            self?.refresh()
        }
        presentAsSheet(editor)
        } catch { status.stringValue = error.localizedDescription }
        }
    }
    private static func confirmDelete(_ automation: ControllerAutomation, host: RemoteHostRecord, in window: NSWindow) async -> Bool {
        let request = ConfirmationRequest(
            prompt: .deleteAutomation,
            title: L10n.format("Delete “%@” on %@?", automation.spec.name, host.displayName),
            message: L10n.string("Its schedule stops on the host. Its run history stays there and remains visible here."),
            confirmTitle: L10n.string("Delete")
        )
        return await withCheckedContinuation { continuation in
            ConfirmationAlert.ask(request, in: window) { continuation.resume(returning: $0) }
        }
    }
    private func perform(_ operation: String, automation: ControllerAutomation, endpoint: RemoteAutomationEndpoint, host: RemoteHostRecord) {
        guard !busy, let window = view.window else { return }
        busy = true
        Task { @MainActor in
            do {
                // Enabling, running and deleting act on a machine that keeps going without this
                // Mac. Each shows what it applies to first; the controller re-checks the revision.
                if let approval = AutomationApprovalRequest.Operation(rawValue: operation) {
                    guard await AutomationApprovalPresenter.ask(.remote(approval, automation: automation, hostName: host.displayName),
                                                                in: window, byAgent: false) else { busy = false; return }
                } else if operation == "delete" {
                    guard await Self.confirmDelete(automation, host: host, in: window) else { busy = false; return }
                }
                let response = try await AutomationCommands.remote(.init(operation: operation, id: automation.id.description,
                    expectedRevision: String(automation.revision), requestKey: UUID().uuidString, remote: endpoint), destination: host.sshDestination)
                busy = false
                if operation == "runs" {
                    let page = try await Task.detached(priority: .utility) { try JSONDecoder().decode(ControllerPage<ControllerAutomationRunStatus>.self, from: Data(response.utf8)) }.value
                    let history = RemoteAutomationHistoryViewController(automation: automation, endpoint: endpoint,
                        destination: host.sshDestination, page: page)
                    presentAsSheet(history)
                } else { refresh() }
            } catch { busy = false; status.stringValue = error.localizedDescription }
        }
    }
}
