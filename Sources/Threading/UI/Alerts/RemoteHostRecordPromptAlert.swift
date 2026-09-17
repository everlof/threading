import AppKit

// MARK: - Remote Host Record Prompt

/// The editor for a *machine*: what to call it, what `ssh` connects to, and which ssh config
/// defines it.
///
/// Deliberately not the project editor beside it (`RemoteHostPromptAlert`). A machine is configured
/// once and used by any number of projects, so the folder a project's sessions run in is asked
/// where the project is, not here. Validated on the same terms: a destination `ssh` would misread
/// keeps the dialog open with the correction on its helper line.
@MainActor
enum RemoteHostRecordPromptAlert {

    /// `nil` is Cancel.
    static func ask(editing existing: RemoteHostRecord?) -> RemoteHostRecord? {
        let accessory = RemoteHostRecordPromptAccessory(current: existing)
        let alert = makeAlert(editing: existing, accessory: accessory)
        guard ConfirmationAlert.chosenIndex(alert.runModal(), optionCount: 1) == 0 else { return nil }
        let record = accessory.record(replacing: existing)
        return record.isValid ? record : nil
    }

    /// Builds the real themed dialog without running it, for behavior tests and rendered evidence.
    static func makeAlert(editing existing: RemoteHostRecord?) -> ThemedAlert {
        makeAlert(editing: existing, accessory: RemoteHostRecordPromptAccessory(current: existing))
    }

    private static func makeAlert(
        editing existing: RemoteHostRecord?,
        accessory: RemoteHostRecordPromptAccessory
    ) -> ThemedAlert {
        let alert = ThemedAlert()
        alert.alertStyle = .informational
        alert.messageText = existing == nil
            ? L10n.string("Add a Remote Host")
            : L10n.format("Edit “%@”", existing?.displayName ?? "")
        alert.informativeText = L10n.string(
            "A Linux machine you can reach with ssh. Threading installs its own background host there the first time a project runs on it."
        )
        alert.accessoryView = accessory
        alert.initialFirstResponder = accessory.firstField
        alert.addButton(withTitle: existing == nil ? L10n.string("Add Host") : L10n.string("Save"))
        alert.addButton(withTitle: L10n.string("Cancel"))
        alert.shouldChooseButton = { [weak accessory] index in
            index != 0 || accessory?.validate(announcing: true) == true
        }
        return alert
    }
}

enum RemoteHostRecordPromptDefaults {
    static let labelIdentifier = "remote-host-record.label"
    static let destinationIdentifier = "remote-host-record.destination"
    static let configFileIdentifier = "remote-host-record.ssh-config"
    static let helperIdentifier = "remote-host-record.helper"
}

// MARK: - Accessory

/// Structural form layout. Every visible control remains a design-system component.
@MainActor
final class RemoteHostRecordPromptAccessory: NSView, NSTextFieldDelegate {

    let labelField = ThemedTextField()
    let destinationField = ThemedTextField()
    let configFileField = ThemedTextField()
    let helperLabel = NSTextField(wrappingLabelWithString: "")

    var firstField: ThemedTextField { destinationField }

    /// What was typed, keeping the identity of the record being edited so every project naming it
    /// follows the edit rather than losing its host.
    func record(replacing existing: RemoteHostRecord?) -> RemoteHostRecord {
        let typed = RemoteHostRecord.typed(
            label: labelField.stringValue,
            destination: destinationField.stringValue,
            sshConfigFile: configFileField.stringValue
        )
        guard let existing else { return typed }
        return RemoteHostRecord(
            id: existing.id,
            label: typed.label,
            destination: typed.destination,
            sshConfigFile: typed.sshConfigFile,
            addedAt: existing.addedAt
        )
    }

    private static var helperText: String {
        L10n.string("Uses your own ssh keys, agent and known_hosts; leave the config file empty for ~/.ssh/config.")
    }

    init(current: RemoteHostRecord?) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        labelField.stringValue = current?.label ?? ""
        destinationField.stringValue = current?.destination ?? ""
        configFileField.stringValue = current?.sshConfigFile ?? ""
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup() {
        helperLabel.stringValue = Self.helperText
        helperLabel.applyFont(.caption)
        helperLabel.textColor = Design.Text.secondary
        helperLabel.maximumNumberOfLines = 0
        helperLabel.preferredMaxLayoutWidth = RemoteHostPromptDefaults.width
        helperLabel.setAccessibilityIdentifier(RemoteHostRecordPromptDefaults.helperIdentifier)

        let rows = [
            row(
                title: L10n.string("Name"),
                field: labelField,
                placeholder: L10n.string("Optional"),
                identifier: RemoteHostRecordPromptDefaults.labelIdentifier
            ),
            row(
                title: L10n.string("SSH host"),
                field: destinationField,
                placeholder: L10n.string("hetzner or user@host"),
                identifier: RemoteHostRecordPromptDefaults.destinationIdentifier
            ),
            row(
                title: L10n.string("SSH config"),
                field: configFileField,
                placeholder: L10n.string("Optional"),
                identifier: RemoteHostRecordPromptDefaults.configFileIdentifier
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

    /// Checks what was typed, and on a problem keeps the dialog open with the correction on the
    /// helper line and the keyboard in the field it names.
    @discardableResult
    func validate(announcing: Bool) -> Bool {
        guard let problem = record(replacing: nil).problem else {
            helperLabel.stringValue = Self.helperText
            helperLabel.textColor = Design.Text.secondary
            return true
        }
        helperLabel.stringValue = problem.message
        helperLabel.textColor = Design.Status.negative

        let field: ThemedTextField
        switch problem {
        case .missingDestination, .unsafeDestination: field = destinationField
        case .relativeConfigFile, .relativeRemoteDirectory: field = configFileField
        }
        field.window?.makeFirstResponder(field)
        field.selectText(nil)
        if announcing {
            NSAccessibility.post(element: field, notification: .announcementRequested, userInfo: [
                .announcement: problem.message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ])
        }
        return false
    }

    func controlTextDidChange(_ notification: Notification) {
        guard helperLabel.textColor == Design.Status.negative else { return }
        validate(announcing: false)
    }
}
