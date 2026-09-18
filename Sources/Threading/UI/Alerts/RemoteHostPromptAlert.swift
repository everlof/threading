import AppKit

// MARK: - Remote Host Prompt

/// The editor for a project's execution host: which machine, and the folder on it.
///
/// **A machine is chosen, not retyped.** Hosts are records configured once in Settings
/// (`RemoteHostStore`), so this dialog picks one of them and asks only for what is the project's
/// own — its folder there. Add Host… in the same menu opens the machine editor, because being sent
/// to Settings mid-thought to add the machine you are already describing is worse than one more
/// dialog.
///
/// A validated dialog on `IntegerPromptAlert`'s terms: a relative folder keeps the dialog open with
/// the exact correction on its helper line, rather than closing and saving something a launch would
/// refuse. Remove is offered only when there is a host to remove.
@MainActor
enum RemoteHostPromptAlert {

    enum Answer: Equatable {
        case save(ProjectExecutionHost)
        case remove
    }

    /// `nil` is Cancel.
    static func ask(projectName: String, current: ProjectExecutionHost?) -> Answer? {
        let accessory = RemoteHostPromptAccessory(current: current)
        let alert = makeAlert(projectName: projectName, current: current, accessory: accessory)
        let optionCount = current == nil ? 1 : 2
        switch ConfirmationAlert.chosenIndex(alert.runModal(), optionCount: optionCount) {
        case 0:
            let host = accessory.host
            return host.isValid ? .save(host) : nil
        case 1:
            return .remove
        default:
            return nil
        }
    }

    /// Builds the real themed dialog without running it, for behavior tests and rendered evidence.
    static func makeAlert(projectName: String, current: ProjectExecutionHost?) -> ThemedAlert {
        makeAlert(
            projectName: projectName,
            current: current,
            accessory: RemoteHostPromptAccessory(current: current)
        )
    }

    private static func makeAlert(
        projectName: String,
        current: ProjectExecutionHost?,
        accessory: RemoteHostPromptAccessory
    ) -> ThemedAlert {
        let alert = ThemedAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.format("Run “%@” on a Remote Host", projectName)
        alert.informativeText = L10n.string(
            "Claude Code terminal sessions in this project run on the machine you choose here, in the folder you name on it."
        )
        alert.accessoryView = accessory
        alert.initialFirstResponder = accessory.firstField
        alert.addButton(withTitle: L10n.string("Save"))
        if current != nil {
            alert.addButton(withTitle: L10n.string("Remove Host"))
        }
        alert.addButton(withTitle: L10n.string("Cancel"))
        alert.shouldChooseButton = { [weak accessory] index in
            index != 0 || accessory?.validate(announcing: true) == true
        }
        return alert
    }
}

enum RemoteHostPromptDefaults {
    static let width: CGFloat = 420
    static let labelWidth: CGFloat = 110
    static let destinationIdentifier = "remote-host.destination"
    static let configFileIdentifier = "remote-host.ssh-config"
    static let remoteDirectoryIdentifier = "remote-host.remote-directory"
    static let helperIdentifier = "remote-host.helper"
}

// MARK: - Accessory

/// Structural form layout. Every visible control remains a design-system component.
@MainActor
final class RemoteHostPromptAccessory: NSView, NSTextFieldDelegate {

    let hostPopUp = ThemedPopUp()
    let remoteDirectoryField = ThemedTextField()
    let helperLabel = NSTextField(wrappingLabelWithString: "")
    private var hasValidationError = false
    /// The records the menu offers, in its order. The last menu item is Add Host…, which is why
    /// this is read by index rather than by title.
    private(set) var records: [RemoteHostRecord]
    private let store: RemoteHostStore

    var firstField: ThemedTextField { remoteDirectoryField }

    /// The chosen machine, or nil while Add Host… is selected.
    var selectedRecord: RemoteHostRecord? {
        let index = hostPopUp.indexOfSelectedItem
        return records.indices.contains(index) ? records[index] : nil
    }

    var host: ProjectExecutionHost {
        guard let record = selectedRecord else {
            return ProjectExecutionHost.typed(
                destination: "",
                sshConfigFile: "",
                remoteDirectory: remoteDirectoryField.stringValue
            )
        }
        return .on(record, remoteDirectory: remoteDirectoryField.stringValue)
    }

    private static var helperText: String {
        L10n.string("The folder must already exist on the host. Machines are added and checked in Settings ▸ Remote Hosts; the new-chat openings from Settings aren’t sent to remote sessions.")
    }

    init(current: ProjectExecutionHost?, store: RemoteHostStore = .shared) {
        self.store = store
        self.records = store.ordered
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        remoteDirectoryField.stringValue = current?.remoteDirectory ?? ""
        setup()
        selectHost(current)
        offerDefaultDirectory()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup() {
        helperLabel.stringValue = Self.helperText
        helperLabel.applyFont(.caption)
        helperLabel.textColor = Design.Text.secondary
        helperLabel.maximumNumberOfLines = 0
        helperLabel.preferredMaxLayoutWidth = RemoteHostPromptDefaults.width
        helperLabel.setAccessibilityIdentifier(RemoteHostPromptDefaults.helperIdentifier)

        hostPopUp.target = self
        hostPopUp.action = #selector(hostChosen)
        hostPopUp.setAccessibilityLabel(L10n.string("Host"))
        hostPopUp.setAccessibilityIdentifier(RemoteHostPromptDefaults.destinationIdentifier)
        reloadHosts()

        let rows = [
            popUpRow(title: L10n.string("Host"), control: hostPopUp),
            row(
                title: L10n.string("Folder on host"),
                field: remoteDirectoryField,
                placeholder: L10n.string("/home/you/project"),
                identifier: RemoteHostPromptDefaults.remoteDirectoryIdentifier
            )
        ]

        let stack = NSStackView(views: rows + [helperLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.small
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: RemoteHostPromptDefaults.width),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        for row in rows {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        helperLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func row(
        title: String,
        field: ThemedTextField,
        placeholder: String,
        identifier: String
    ) -> NSView {
        field.placeholderString = placeholder
        field.applyFont(.body)
        field.delegate = self
        field.setAccessibilityLabel(title)
        field.setAccessibilityIdentifier(identifier)

        let label = NSTextField(labelWithString: title)
        label.applyFont(.body)
        label.textColor = Design.Text.secondary
        label.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [label, field])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Design.Spacing.small
        label.widthAnchor.constraint(equalToConstant: RemoteHostPromptDefaults.labelWidth).isActive = true
        return row
    }

    /// Rebuilds the menu from the list, keeping the machine that was chosen if it is still there.
    func reloadHosts() {
        let chosen = selectedRecord?.id
        records = store.ordered
        hostPopUp.removeAllItems()
        for record in records {
            hostPopUp.addItem(withTitle: record.displayName)
        }
        hostPopUp.addItem(withTitle: L10n.string("Add Host…"))
        if let chosen, let index = records.firstIndex(where: { $0.id == chosen }) {
            hostPopUp.selectItem(at: index)
        } else if !records.isEmpty {
            hostPopUp.selectItem(at: 0)
        } else {
            hostPopUp.selectItem(at: 0)
        }
    }

    /// Selects the machine a project already names, adopting it into the list if it was set up
    /// before hosts were records.
    private func selectHost(_ current: ProjectExecutionHost?) {
        guard let current, !current.destination.isEmpty else { return }
        let record = current.hostID.flatMap { store.host(withID: $0) }
            ?? store.adopt(destination: current.destination, sshConfigFile: current.sshConfigFile)
        guard let record else { return }
        reloadHosts()
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            hostPopUp.selectItem(at: index)
        }
    }

    /// Add Host… is the last item: it opens the machine editor and comes back with it chosen.
    @objc private func hostChosen() {
        guard hostPopUp.indexOfSelectedItem == records.count else {
            offerDefaultDirectory()
            return
        }
        guard let record = RemoteHostRecordPromptAlert.ask(editing: nil),
              store.add(record) == .applied else {
            reloadHosts()
            return
        }
        records = store.ordered
        reloadHosts()
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            hostPopUp.selectItem(at: index)
        }
        offerDefaultDirectory()
    }

    /// Fills an empty folder from the machine's own default. Only ever *offers*: a folder already
    /// typed is the project's answer and is not replaced by picking a different machine.
    private func offerDefaultDirectory() {
        guard remoteDirectoryField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let folder = selectedRecord?.defaultDirectory else { return }
        remoteDirectoryField.stringValue = folder
    }

    private func popUpRow(title: String, control: ThemedPopUp) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.applyFont(.body)
        label.textColor = Design.Text.secondary
        label.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Design.Spacing.small
        label.widthAnchor.constraint(equalToConstant: RemoteHostPromptDefaults.labelWidth).isActive = true
        return row
    }

    /// Checks what was typed, and on a problem keeps the dialog open with the correction on the
    /// helper line and the keyboard in the field it names.
    @discardableResult
    func validate(announcing: Bool) -> Bool {
        guard let problem = host.problem else {
            hasValidationError = false
            helperLabel.stringValue = Self.helperText
            helperLabel.textColor = Design.Text.secondary
            return true
        }
        hasValidationError = true
        helperLabel.stringValue = problem.message
        helperLabel.textColor = Design.Status.negative

        // Every problem but the folder belongs to the machine, which is chosen rather than typed;
        // the keyboard goes to the only field this dialog owns.
        let field = remoteDirectoryField
        field.window?.makeFirstResponder(field)
        field.selectText(nil)
        if announcing {
            NSAccessibility.post(
                element: field,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: problem.message,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue
                ]
            )
        }
        return false
    }

    func controlTextDidChange(_ notification: Notification) {
        guard hasValidationError else { return }
        validate(announcing: false)
    }
}

// MARK: - Editing a project's host

/// The one operation behind every way of editing a project's host — the project row's menu, the
/// View menu and the command palette — so they cannot disagree about what is allowed.
///
/// A build that cannot run remote sessions offers only removal of a host that is already set: it
/// refuses to launch such a project, and the person needs a way out that is not editing defaults.
@MainActor
enum ProjectExecutionHostEditor {

    /// Answers a failure sentence to show, or nil when there is nothing to say.
    static func edit(projectID: ProjectID, store: ProjectStore) -> String? {
        guard let project = store.project(withID: projectID) else { return nil }

        let answer: RemoteHostPromptAlert.Answer?
        if RemoteExecutionHostRoute.buildSupportsRemoteHosts {
            answer = RemoteHostPromptAlert.ask(projectName: project.name, current: project.executionHost)
        } else if let host = project.executionHost {
            answer = confirmRemoval(projectName: project.name, host: host) ? .remove : nil
        } else {
            return L10n.string("This build of Threading can’t run sessions on remote hosts.")
        }

        let result: ProjectMutationResult
        switch answer {
        case .save(let host)?:
            result = store.setExecutionHost(host, forProjectID: projectID)
        case .remove?:
            result = store.setExecutionHost(nil, forProjectID: projectID)
        case nil:
            return nil
        }
        return result.succeeded ? nil : L10n.string("The project data could not be saved.")
    }

    private static func confirmRemoval(projectName: String, host: ProjectExecutionHost) -> Bool {
        let alert = ThemedAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.format("Run “%@” on This Mac?", projectName)
        alert.informativeText = RemoteExecutionHostRefusal.unsupportedBuild.message
            + "\n\n" + RemoteExecutionHostMark.runsOn(host.destination)
        alert.addButton(withTitle: L10n.string("Remove Host"))
        alert.addButton(withTitle: L10n.string("Cancel"))
        return ConfirmationAlert.chosenIndex(alert.runModal(), optionCount: 1) == 0
    }
}
