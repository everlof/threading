import AppKit

// MARK: - Change Event

/// Posted when a binding changes, so the menu bar can re-apply itself. The menu is built once at
/// launch and never rebuilt, so without this a new chord would not take effect until relaunch.
struct KeyboardShortcutsDidChange: AppEvent {
    static let name = Notification.Name("keyboardShortcutsDidChange")
}

// MARK: - Shortcut Override Store

/// The user's own bindings over defaults from the shared built-in/extension command registry.
///
/// A separate store rather than properties on `AppSettings`, following `AccountPreferencesStore`:
/// this is a dictionary keyed by something the app invents, and giving each command its own
/// `UserDefaults` key would spread one decision across a growing list of them.
///
/// **Unbinding is a state, not an absence.** "No override" and "deliberately no shortcut" have to
/// be told apart, or clearing a chord would silently restore its default on the next launch — so
/// the payload records the cleared ids rather than simply omitting them.
///
/// All access is on the main queue — the settings page writes it and the menu bar reads it, both
/// on main — so it needs no locking, and no isolation either: the menu is built from
/// `AppDelegate`, which is not itself actor-isolated. This is `DisplayPaneStore`'s arrangement.
final class ShortcutOverrideStore {

    static let shared = ShortcutOverrideStore()

    private struct Payload: Codable {
        var bound: [String: KeyboardShortcut] = [:]
        var cleared: [String] = []
    }

    private var payload = Payload()

    /// False only when a stored value could not be decoded *and* could not be kept aside. A
    /// write then has nowhere to put what it would destroy, so it does not happen.
    private var writesAllowed = true

    private let defaults: UserDefaults
    private let registry: CommandRegistry

    /// The defaults are injectable so tests can exercise the resolution and conflict rules
    /// without writing bindings into the user's own preferences.
    init(
        defaults: UserDefaults = .standard,
        registry: CommandRegistry = .shared
    ) {
        self.defaults = defaults
        self.registry = registry
        load()
    }

    // MARK: - Reading

    /// What a command runs on now: the user's binding, the command's default, or nothing.
    func shortcut(for command: AppCommand) -> KeyboardShortcut? {
        guard command.isEditable else { return command.defaultShortcut }
        if payload.cleared.contains(command.id) { return nil }
        if let override = payload.bound[command.id] { return override }
        guard let candidate = command.defaultShortcut else { return nil }

        // An extension default is a suggestion, not permission to steal a chord. Suppress it
        // when any active command already resolves to that key. The user can still bind it after
        // moving or clearing the owner in Keyboard settings.
        if command.origin.extensionIdentifier != nil,
           registry.all.contains(where: { other in
               other.id != command.id && unsuppressedShortcut(for: other) == candidate
           }) {
            return nil
        }
        return candidate
    }

    func shortcut(forID id: String) -> KeyboardShortcut? {
        registry.command(id: id).flatMap(shortcut(for:))
    }

    func isOverridden(_ command: AppCommand) -> Bool {
        payload.bound[command.id] != nil || payload.cleared.contains(command.id)
    }

    var hasAnyOverride: Bool {
        !payload.bound.isEmpty || !payload.cleared.isEmpty
    }

    // MARK: - Writing

    /// Binds a command, or clears it when `shortcut` is nil. Setting a command back to its own
    /// default drops the override rather than storing it, so a later change to the default is
    /// still picked up by a user who never really chose anything.
    func setShortcut(_ shortcut: KeyboardShortcut?, for command: AppCommand) {
        guard command.isEditable else { return }

        payload.bound.removeValue(forKey: command.id)
        payload.cleared.removeAll { $0 == command.id }

        if let shortcut {
            if shortcut != command.defaultShortcut || defaultConflict(for: command) != nil {
                payload.bound[command.id] = shortcut
            }
        } else if command.defaultShortcut != nil {
            payload.cleared.append(command.id)
        }

        save()
    }

    func reset(_ command: AppCommand) {
        payload.bound.removeValue(forKey: command.id)
        payload.cleared.removeAll { $0 == command.id }
        save()
    }

    func resetAll() {
        payload = Payload()
        save()
    }

    // MARK: - Conflicts

    /// The other command already answering to a chord, if any.
    ///
    /// Fixed commands are included: taking ⌘Q for something of ours would leave the user unable
    /// to quit, and that is exactly the collision worth refusing rather than the one to ignore.
    func conflict(for shortcut: KeyboardShortcut, excluding command: AppCommand) -> AppCommand? {
        registry.all.first { candidate in
            candidate.id != command.id && self.shortcut(for: candidate) == shortcut
        }
    }

    /// Why an extension's declared default is currently unbound, if it is.
    func defaultConflict(for command: AppCommand) -> AppCommand? {
        guard command.origin.extensionIdentifier != nil,
              payload.bound[command.id] == nil,
              !payload.cleared.contains(command.id),
              let candidate = command.defaultShortcut else {
            return nil
        }
        return registry.all.first { other in
            other.id != command.id && unsuppressedShortcut(for: other) == candidate
        }
    }

    private func unsuppressedShortcut(for command: AppCommand) -> KeyboardShortcut? {
        guard command.isEditable else { return command.defaultShortcut }
        if payload.cleared.contains(command.id) { return nil }
        return payload.bound[command.id] ?? command.defaultShortcut
    }

    // MARK: - Persistence

    private func save() {
        guard writesAllowed else {
            ThreadingLogger.session.error(
                "Refusing to save shortcut overrides: the unreadable previous value is still there"
            )
            return
        }

        do {
            defaults.set(try JSONEncoder().encode(payload), forKey: Keys.overrides)
            NotificationCenter.default.post(KeyboardShortcutsDidChange())
        } catch {
            ThreadingLogger.session.error("Could not save shortcut overrides: \(error.localizedDescription)")
        }
    }

    /// Missing and unreadable are different answers.
    ///
    /// Both used to fall through to the default payload, and the next rebinding then wrote that
    /// default straight over the stored blob — so a user whose overrides failed to decode lost
    /// every one of them, permanently, the first time they touched a shortcut. The unreadable
    /// case is now kept aside and only then overwritten; see `DefaultsQuarantine`.
    private func load() {
        guard let data = defaults.data(forKey: Keys.overrides) else { return }

        guard let decoded = try? JSONDecoder().decode(Payload.self, from: data) else {
            writesAllowed = DefaultsQuarantine.quarantine(
                data,
                forKey: Keys.overrides,
                in: defaults
            )
            return
        }

        payload = decoded
    }

    private enum Keys {
        static let overrides = "keyboardShortcutOverrides"
    }
}
