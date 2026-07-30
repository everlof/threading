import AppKit

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
    private var rows: [SystemPrivacyPermission: PermissionRow] = [:]

    // MARK: - Initialization

    init(reader: SystemPrivacyStatusReader = SystemPrivacyStatusReader()) {
        self.reader = reader
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

    // MARK: - Construction

    private func buildPage() {
        let page = SettingsUI.page([
            SettingsUI.heading("Privacy"),
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
                title: "Remote Access stays on this Mac",
                detail: "The listener binds to 127.0.0.1 and your iPhone reaches it through an "
                    + "outbound encrypted relay, so nothing is published on your local "
                    + "network and macOS never asks for that permission."
            )
        ])
    }

    private func credentialsCard() -> SettingsCard {
        SettingsCard(rows: [
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
                    + "it can route a session to one. It never reads or copies their credentials."
            )
        ])
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
                    + "Nothing is sent when you launch it, open a project, or run an agent."
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
    }

    private func apply(_ status: SystemPrivacyStatus, to permission: SystemPrivacyPermission) {
        guard let row = rows[permission] else { return }

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
