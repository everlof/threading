import AppKit

/// The Keyboard page: every command the menu bar offers, and the chord it answers to.
///
/// It lists the fixed commands alongside the editable ones on purpose. Most of why a shortcuts
/// page gets opened is "what is this key already doing" — a page that showed only what it would
/// let you change could not answer that, and would make a conflict with ⌘Q look like a free slot.
final class KeyboardPreferencesViewController: NSViewController {

    // MARK: - Properties

    private let store = ShortcutOverrideStore.shared
    private let registry = CommandRegistry.shared
    private let appEvents = AppEventObservations()

    /// Rebuilt wholesale on any change, following `ArchivedPreferencesViewController`: a rebind
    /// can move a conflict warning onto a row far from the one that was edited, so redrawing the
    /// page is both simpler and more correct than patching the row that changed.
    private var recorders: [String: ShortcutRecorderView] = [:]

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        rebuild()
        appEvents.observe(CommandRegistryDidChange.self) { [weak self] _ in
            self?.rebuild()
        }
    }

    // MARK: - Building

    private func rebuild() {
        view.subviews.forEach { $0.removeFromSuperview() }
        recorders.removeAll()

        var sections: [NSView] = [
            SettingsUI.heading(Strings.heading),
            SettingsUI.note(Strings.note)
        ]

        for (group, commands) in registry.grouped() {
            let rows = commands.map(makeRow)
            sections.append(SettingsUI.section(group.rawValue, SettingsCard(rows: rows)))
        }

        sections.append(SettingsUI.section(nil, SettingsCard(rows: [
            SettingsUI.row(
                title: Strings.resetTitle,
                subtitle: Strings.resetSubtitle,
                control: SettingsUI.button(Strings.resetButton, target: self, action: #selector(resetAllClicked))
            )
        ])))

        let page = SettingsUI.page(sections, hostPage: .keyboard)
        page.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(page)

        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: view.topAnchor),
            page.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            page.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func makeRow(_ command: AppCommand) -> NSView {
        let shortcut = store.shortcut(for: command)

        guard command.isEditable else {
            // A plain label, not a disabled recorder: a dimmed control still invites a click,
            // and these can never be clicked to any effect.
            let label = NSTextField(labelWithString: shortcut?.displayString ?? ShortcutRecorderStrings.unbound)
            label.applyFont(.code())
            label.textColor = Design.Text.tertiary
            return SettingsUI.row(title: rowTitle(command), subtitle: nil, control: label)
        }

        let recorder = ShortcutRecorderView(shortcut: shortcut)
        recorder.onRecord = { [weak self] captured in
            self?.record(captured, for: command)
        }
        recorders[command.id] = recorder

        return SettingsUI.row(
            title: rowTitle(command),
            subtitle: subtitle(for: command, shortcut: shortcut),
            control: recorder
        )
    }

    private func rowTitle(_ command: AppCommand) -> String {
        guard let extensionName = command.origin.extensionName else { return command.title }
        return "\(extensionName) — \(command.title)"
    }

    /// The row's second line carries the two things that are not visible in the chord itself:
    /// that it collides with something, and that it is no longer the default.
    private func subtitle(for command: AppCommand, shortcut: KeyboardShortcut?) -> String? {
        if let shortcut, let other = store.conflict(for: shortcut, excluding: command) {
            return L10n.format(Strings.conflictFormat, other.title)
        }
        if let fallback = command.defaultShortcut,
           let other = store.defaultConflict(for: command) {
            return L10n.format(
                Strings.defaultConflictFormat,
                fallback.displayString,
                other.title
            )
        }
        guard store.isOverridden(command) else { return nil }

        guard let fallback = command.defaultShortcut else { return Strings.changedNoDefault }
        return L10n.format(Strings.changedFormat, fallback.displayString)
    }

    // MARK: - Actions

    /// A chord already spoken for is refused rather than taken.
    ///
    /// Stealing it would be the other reasonable design, and is worse here: the command that lost
    /// its shortcut is somewhere else on a long page, so the user would be told nothing and would
    /// discover it the next time they reached for the key that no longer works.
    private func record(_ shortcut: KeyboardShortcut?, for command: AppCommand) {
        if let shortcut, let other = store.conflict(for: shortcut, excluding: command) {
            presentConflict(shortcut, taken: other)
            rebuild()
            return
        }

        store.setShortcut(shortcut, for: command)
        rebuild()
    }

    private func presentConflict(_ shortcut: KeyboardShortcut, taken other: AppCommand) {
        let alert = ThemedAlert()
        alert.messageText = L10n.format(Strings.conflictTitle, shortcut.displayString)
        alert.informativeText = L10n.format(Strings.conflictBody, other.title)
        alert.alertStyle = .warning
        alert.runModal()
    }

    @objc private func resetAllClicked() {
        store.resetAll()
        rebuild()
    }
}

// MARK: - Strings

private enum Strings {
    static var heading: String { L10n.string("Keyboard") }
    static var note: String {
        L10n.string(
            "Click a shortcut and press the keys you want. "
                + "Escape cancels, Delete removes the shortcut."
        )
    }

    static let conflictFormat = "Already used by %@"
    static let defaultConflictFormat = "Default %@ is used by %@"
    static let changedFormat = "Changed from %@"
    static var changedNoDefault: String { L10n.string("Changed") }

    static let conflictTitle = "%@ is already in use"
    static let conflictBody = "That combination belongs to “%@”. "
        + "Choose a different one, or clear that shortcut first."

    static var resetTitle: String { L10n.string("Reset Shortcuts") }
    static var resetSubtitle: String {
        L10n.string("Puts every shortcut back to its default.")
    }
    static var resetButton: String { L10n.string("Reset All") }
}
