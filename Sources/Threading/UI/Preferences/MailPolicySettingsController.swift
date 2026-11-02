import AppKit
import ThreadingController

/// One owner-policy row. The table vends its controls only near the viewport; the database is
/// read once when Tools opens and written only by Save, through the mailbox actor.
@MainActor
final class MailPolicySettingsController: NSObject, NSTextFieldDelegate {
    static let title = "Mail chain message limit"
    private let mailbox: MacMailbox
    private var savedLimit: Int?
    private var draft = ""
    private var busy = false
    private var failure: String?
    private weak var field: ThemedTextField?
    private weak var button: ThemedButton?
    private weak var subtitle: NSTextField?

    init(mailbox: MacMailbox) {
        self.mailbox = mailbox
    }

    func makeRow() -> NSView {
        let field = SettingsUI.textField(target: self, action: #selector(savePressed), width: 100)
        field.delegate = self
        field.setAccessibilityIdentifier("settings.tools.mail.chainMessageLimit")
        field.setAccessibilityLabel(L10n.string(Self.title))
        let button = SettingsUI.button("Save", target: self, action: #selector(savePressed))
        button.setAccessibilityIdentifier("settings.tools.mail.save")
        let controls = NSStackView(views: [field, button])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = Design.Spacing.small
        var subtitle: NSTextField?
        let row = SettingsUI.row(
            title: Self.title,
            subtitle: "Messages per chain on this Mac.",
            help: SettingsUI.help(
                Self.title,
                "Counts messages from all agents in the same chain on this Mac. Changes apply to the next send, including existing chains. Other hosts have their own limits.",
                "A new prompt from you lets that chat start a fresh chain. Replies to old mail still belong to the old chain; reading or acknowledging old mail can inherit it again.",
                "When a send reaches the limit, the agent is told to explain in the chat that its message was not sent and how a new prompt can continue the work."
            ),
            control: controls,
            subtitleField: &subtitle
        )
        self.field = field
        self.button = button
        self.subtitle = subtitle
        refresh()
        return row
    }

    func load() async {
        guard !busy else { return }
        busy = true
        failure = nil
        refresh()
        do {
            let policy = try await mailbox.policy()
            savedLimit = policy.chainMessageLimit
            draft = String(policy.chainMessageLimit)
        } catch {
            failure = L10n.string("Could not load the mail policy. Try again.")
        }
        busy = false
        refresh()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? ThemedTextField, field === self.field else { return }
        draft = field.stringValue
        failure = nil
        refresh()
    }

    @objc private func savePressed() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if savedLimit == nil { await load() }
            else { await save() }
        }
    }

    func save() async {
        guard !busy, savedLimit != nil, let limit = parsedLimit, limit != savedLimit else { return }
        busy = true
        failure = nil
        refresh()
        do {
            let policy = try await mailbox.setPolicy(chainMessageLimit: limit)
            savedLimit = policy.chainMessageLimit
            draft = String(policy.chainMessageLimit)
        } catch {
            failure = L10n.string("Could not save the mail policy. Try again.")
        }
        busy = false
        refresh()
    }

    private var parsedLimit: Int? {
        guard let value = Int(draft.trimmingCharacters(in: .whitespacesAndNewlines)), value > 0 else { return nil }
        return value
    }

    private func refresh() {
        if field?.stringValue != draft { field?.stringValue = draft }
        field?.placeholderString = L10n.string("Loading…")
        field?.isEnabled = !busy && savedLimit != nil
        button?.title = L10n.string(savedLimit == nil && failure != nil ? "Retry" : "Save")
        button?.isEnabled = !busy && (savedLimit == nil ? failure != nil : parsedLimit != nil && parsedLimit != savedLimit)
        if let failure {
            subtitle?.stringValue = failure
        } else if busy {
            subtitle?.stringValue = L10n.string(savedLimit == nil ? "Loading mail policy…" : "Saving mail policy…")
        } else if savedLimit != nil && parsedLimit == nil {
            subtitle?.stringValue = L10n.string("Enter a whole number greater than zero.")
        } else {
            subtitle?.stringValue = L10n.string("Messages per chain on this Mac.")
        }
    }
}
