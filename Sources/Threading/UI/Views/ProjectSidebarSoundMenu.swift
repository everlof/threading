import AppKit

// MARK: - Sound Choice Menu Item

/// What one item in the Sounds submenu would do: which record it paints, and with what.
///
/// Carried in the row's own closure rather than read from the controller when it fires, for the
/// same reason `ThemeMenuChoice` is: the submenu is built from several places — a session's
/// `⋯`, a session's right-click, a project's menu, a terminal's menu — and ambient "whichever
/// row was last clicked" state is exactly what goes stale between them.
struct SoundMenuChoice {

    enum Target {
        case session(SessionID)
        case terminal(TerminalID)
        case project(ProjectID)
    }

    let target: Target

    /// Nil clears the scope's `all` entry, so the record inherits again.
    let choice: SoundChoice?
}

// MARK: - Sound Menu Builder

/// Builds the Sounds submenu — the one-click tier, offered beside the Theme submenu on all
/// three row kinds because both are presentation: how this scope looks, how this scope sounds.
///
/// It writes one level only, `scope[all]`, which is the base coat under every event this scope
/// has not answered more narrowly. Per-event exceptions are a different surface and are never
/// touched here; a menu item that silently discarded configured choices would be a trap.
///
/// A class rather than free functions because the persistence-failure notice belongs to whoever
/// presented the menu; each presenter keeps one and tells it how to complain.
@MainActor
final class SoundMenuBuilder {

    /// Says that the store refused the write, in whatever way the presenter reports things.
    var onPersistenceFailure: (() -> Void)?

    /// Opens the per-event sheet for one scope. Held by the presenter for the same reason the
    /// failure notice is: a menu built in a test has no window to put a sheet over.
    var onCustomize: ((SoundScope) -> Void)?

    /// A conversation's sound: its own base coat, or the project's and the app's answer.
    func sessionSoundEntry(for sessionID: SessionID) -> ThemedMenuEntry {
        makeSoundEntry(
            target: .session(sessionID),
            stored: storedChoice(
                in: ProjectStore.shared.session(withID: sessionID)?.soundOverrides
            ),
            inherited: SoundResolution.uniformAnswer(
                through: SoundResolution.inheritedScopes(forSessionID: sessionID)
            ),
            customizes: .session(sessionID)
        )
    }

    /// A checkout's sound, which its chats and terminals follow unless they answered for
    /// themselves.
    func projectSoundEntry(for projectID: ProjectID) -> ThemedMenuEntry {
        makeSoundEntry(
            target: .project(projectID),
            stored: storedChoice(
                in: ProjectStore.shared.project(withID: projectID)?.soundOverrides
            ),
            inherited: SoundResolution.uniformAnswer(
                through: SoundResolution.inheritedScopes(forProjectID: projectID)
            ),
            customizes: .project(projectID)
        )
    }

    /// A standalone terminal's sound. The same submenu the other two rows carry **minus
    /// Customize…**: a terminal keeps no activity tracker, so nothing there can say why a bell
    /// rang, and a sheet offering nine causes to scope would be offering eight it cannot tell
    /// apart. The one-click tier is the whole tier here.
    ///
    /// The sheet still opens on a terminal from the Custom sounds list in Settings, because a
    /// record that somehow carries event entries — written by a later build, or by the sheet
    /// before this rule existed — has to be reachable to be cleared.
    func terminalSoundEntry(for terminalID: TerminalID) -> ThemedMenuEntry {
        makeSoundEntry(
            target: .terminal(terminalID),
            stored: storedChoice(
                in: ProjectStore.shared.terminal(withID: terminalID)?.soundOverrides
            ),
            inherited: SoundResolution.uniformAnswer(
                through: SoundResolution.inheritedScopes(forTerminalID: terminalID)
            )
        )
    }

    // MARK: - Private Methods

    private func storedChoice(in overrides: [String: String]?) -> SoundChoice? {
        SoundOverrides.choice(forKey: SoundOverrideKeys.all, in: overrides)
    }

    /// One builder for all three scopes: they differ in what they read and write, not in what
    /// they offer.
    ///
    /// The list is the settings pickers' list, in the settings pickers' order and words — Off,
    /// the system default, the library, then the way in for a sound of the user's own — because
    /// two surfaces offering the same sounds differently is the drift `SoundPickerMenu` exists
    /// to prevent.
    private func makeSoundEntry(
        target: SoundMenuChoice.Target,
        stored: SoundChoice?,
        inherited: SoundChoice?,
        customizes scope: SoundScope? = nil
    ) -> ThemedMenuEntry {
        var rows: [ThemedMenuEntry] = [
            soundChoiceEntry(
                title: inheritTitle(for: inherited),
                choice: SoundMenuChoice(target: target, choice: nil),
                isChecked: stored == nil
            ),
            .separator
        ]

        for (title, value) in [
            (L10n.string("Off"), SoundChoice.silent),
            (L10n.string("macOS Alert Sound"), SoundChoice.system)
        ] {
            rows.append(soundChoiceEntry(
                title: title,
                choice: SoundMenuChoice(target: target, choice: value),
                isChecked: stored == value
            ))
        }

        rows.append(contentsOf: SoundPickerMenu.soundEntries { sound in
            let choice = SoundMenuChoice(target: target, choice: .named(sound.fileName))
            return ThemedMenuItem(
                title: sound.displayName,
                representedValue: choice,
                isSelected: stored == choice.choice,
                onChoose: { [weak self] in self?.apply(choice) }
            )
        })

        rows.append(.separator)
        rows.append(.item(SoundPickerMenu.customSoundItem { [weak self] in
            self?.addSound(for: target)
        }))

        // The door to the per-event tier, last because it is the tier this menu is not.
        //
        // It never clears anything, and the count is the only indicator that exceptions exist:
        // event-level entries do not move the checkmark, so without this the menu would show a
        // scope as plainly inheriting while three of its nine events were not. A menu item that
        // silently discarded those choices was the first revision's idea and is a trap; the
        // clearing lives in the sheet, where what is being reset is on screen.
        if let scope {
            rows.append(.item(ThemedMenuItem(
                title: customizeTitle(for: scope),
                onChoose: { [weak self] in self?.onCustomize?(scope) }
            )))
        }

        return .item(ThemedMenuItem(
            title: SoundMenuDefaults.title,
            image: ThemedMenuIcon.symbol(SoundMenuDefaults.symbol),
            submenu: rows
        ))
    }

    /// *Inherit* names the inherited answer when every voiced event agrees, and reads plain when
    /// they do not — right after migration the app scope usually holds a bell sound and a
    /// different notification tone, so mixed is the ordinary state and a parenthetical naming
    /// one of the two would be a lie about the other.
    private func inheritTitle(for inherited: SoundChoice?) -> String {
        guard let inherited else { return L10n.string("Inherit") }
        return L10n.format("Inherit (%@)", SoundMenuNames.displayName(of: inherited))
    }

    /// *Customize…*, or *Customize (3 Events)…* when this scope holds exceptions.
    ///
    /// Event-level entries only. The kind and `all` levels are what the checkmark above already
    /// reports, and counting a one-click choice here would make a base coat read as an exception
    /// to itself.
    private func customizeTitle(for scope: SoundScope) -> String {
        switch scope.eventEntryCount {
        case 0: return L10n.string("Customize…")
        case 1: return L10n.format("Customize (%lld Event)…", 1)
        case let count: return L10n.format("Customize (%lld Events)…", count)
        }
    }

    private func soundChoiceEntry(
        title: String,
        choice: SoundMenuChoice,
        isChecked: Bool
    ) -> ThemedMenuEntry {
        .item(ThemedMenuItem(
            title: title,
            representedValue: choice,
            isSelected: isChecked,
            onChoose: { [weak self] in self?.apply(choice) }
        ))
    }

    // MARK: - Handlers

    /// Writes the choice, and previews it.
    ///
    /// **Nil where the value matches what would have been inherited**, which is the mute
    /// writer's rule and the reason the field is optional rather than a stored table: storing
    /// the matching value is what would stop a later change to the project from reaching the
    /// chat. Selecting *Inherit* clears the entry by the same expression — nil equals nil.
    func apply(_ choice: SoundMenuChoice) {
        let stored = choice.choice == inheritedAnswer(for: choice.target) ? nil : choice.choice
        guard write(stored, to: choice.target) else {
            onPersistenceFailure?()
            return
        }
        preview(choice.choice)
    }

    /// The one answer this scope would give with nothing of its own, or nil when the voiced
    /// events disagree — the same reading the *Inherit* item shows, from the same function.
    private func inheritedAnswer(for target: SoundMenuChoice.Target) -> SoundChoice? {
        switch target {
        case .session(let sessionID):
            return SoundResolution.uniformAnswer(
                through: SoundResolution.inheritedScopes(forSessionID: sessionID)
            )
        case .project(let projectID):
            return SoundResolution.uniformAnswer(
                through: SoundResolution.inheritedScopes(forProjectID: projectID)
            )
        case .terminal(let terminalID):
            return SoundResolution.uniformAnswer(
                through: SoundResolution.inheritedScopes(forTerminalID: terminalID)
            )
        }
    }

    /// Read-modify-write on the record's raw map, so the levels this menu does not touch — and
    /// any key a later build wrote — come back out untouched.
    private func write(_ choice: SoundChoice?, to target: SoundMenuChoice.Target) -> Bool {
        let store = ProjectStore.shared
        func updated(_ overrides: [String: String]?) -> [String: String]? {
            SoundOverrides.setting(choice, forKey: SoundOverrideKeys.all, in: overrides)
        }

        switch target {
        case .session(let sessionID):
            return store.setSoundOverrides(
                updated(store.session(withID: sessionID)?.soundOverrides),
                forSessionID: sessionID
            ).succeeded
        case .project(let projectID):
            return store.setSoundOverrides(
                updated(store.project(withID: projectID)?.soundOverrides),
                forProjectID: projectID
            ).succeeded
        case .terminal(let terminalID):
            return store.setSoundOverrides(
                updated(store.terminal(withID: terminalID)?.soundOverrides),
                forTerminalID: terminalID
            ).succeeded
        }
    }

    /// Choosing a sound plays it, the way every alert-sound list does: a name is not a sound.
    ///
    /// The two reserved answers stay quiet, exactly as the settings pickers leave them — macOS's
    /// notification tone is not a file any name resolves to, and *Off* previews as silence,
    /// which is the honest answer. *Inherit* previews nothing because it chooses nothing.
    private func preview(_ choice: SoundChoice?) {
        guard case .named(let fileName) = choice,
              let sound = NotificationSoundLibrary.resolve(fileName: fileName) else { return }
        NotificationSoundPreview.play(sound)
    }

    /// Copies a chosen file into `~/Library/Sounds` and paints this scope with it.
    private func addSound(for target: SoundMenuChoice.Target) {
        SoundPickerMenu.addCustomSound { [weak self] sound in
            guard let self, let sound else { return }
            self.apply(SoundMenuChoice(target: target, choice: .named(sound.fileName)))
        }
    }
}

// MARK: - Sound Menu Names

/// What a stored choice is called in a menu.
///
/// The two reserved answers borrow the settings pickers' own words rather than inventing a
/// second vocabulary for them; a file is called what the picker calls it, which is its name
/// without the extension.
enum SoundMenuNames {
    static func displayName(of choice: SoundChoice) -> String {
        switch choice {
        case .silent: return L10n.string("Off")
        case .system: return L10n.string("macOS Alert Sound")
        case .named(let fileName): return (fileName as NSString).deletingPathExtension
        }
    }

    /// What a whole kind is called where one has to be named beside a sound — the Custom sounds
    /// list, which has to say *which* half of the app a stored kind entry covers.
    static func displayName(of kind: SoundEvent.Kind) -> String {
        switch kind {
        case .bell: return L10n.string("Bells")
        case .alert: return L10n.string("Notifications")
        }
    }

    /// What an **inherited** answer is called, which is not always what the item choosing it is
    /// called: silence reads *Silent* where it is being reported and *Off* where it is being
    /// asked for.
    ///
    /// The difference is the mood rather than a second vocabulary. *Off* is an instruction in a
    /// list of instructions; *Inherit (Silent)* describes what will happen, and the Customize
    /// sheet's footnote — "Events shown as Silent make no sound anywhere unless given one here"
    /// — names the same state in the same word. A row reading *Inherit (Off)* under that
    /// sentence would be the one line on the sheet that did not agree with it.
    static func inheritedName(of choice: SoundChoice) -> String {
        choice == .silent ? L10n.string("Silent") : displayName(of: choice)
    }
}

// MARK: - Sound Menu Defaults

enum SoundMenuDefaults {
    static var title: String { L10n.string("Sounds") }

    /// A speaker mid-wave: the same family as the footer's silence gate, which is the other
    /// control in this app that says something about audio.
    static let symbol = "speaker.wave.2"
}

// MARK: - Sidebar Wrappers

/// The submenu sits in a row's own menu rather than in Settings for the same reason the Theme
/// submenu does: a scope is chosen *at* the thing it applies to. The app-wide answers stay in
/// Settings, which is the scope with no row to hang from.
extension ProjectSidebarViewController {

    func sessionSoundEntry(for sessionID: SessionID) -> ThemedMenuEntry {
        sidebarSoundBuilder().sessionSoundEntry(for: sessionID)
    }

    func projectSoundEntry(for projectID: ProjectID) -> ThemedMenuEntry {
        sidebarSoundBuilder().projectSoundEntry(for: projectID)
    }

    func terminalSoundEntry(for terminalID: TerminalID) -> ThemedMenuEntry {
        sidebarSoundBuilder().terminalSoundEntry(for: terminalID)
    }

    private func sidebarSoundBuilder() -> SoundMenuBuilder {
        soundMenuBuilder.onPersistenceFailure = { [weak self] in
            guard let self else { return }
            self.reload()
            self.presentProjectNotice(L10n.string("The project data could not be saved."))
        }
        // Presented from the sidebar rather than by the builder, for the same reason the notice
        // is: a menu built in a test has no window to put a sheet over.
        soundMenuBuilder.onCustomize = { [weak self] scope in
            guard let self else { return }
            SoundCustomizeViewController.present(scope, from: self)
        }
        return soundMenuBuilder
    }
}
