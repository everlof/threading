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
@MainActor
final class ShortcutOverrideStore {

    static let shared = ShortcutOverrideStore()

    private struct Payload: Codable {
        var bound: [String: KeyboardShortcut] = [:]
        var cleared: [String] = []
    }

    private var payload: Payload
    private let persistence: RecoverableDefaultsStore<Payload>
    private let registry: CommandRegistry

    /// The defaults are injectable so tests can exercise the resolution and conflict rules
    /// without writing bindings into the user's own preferences.
    init(
        defaults: UserDefaults = .standard,
        registry: CommandRegistry = .shared
    ) {
        self.registry = registry
        self.persistence = RecoverableDefaultsStore(
            defaults: defaults,
            key: Keys.overrides,
            criticality: .preference,
            sizePolicy: .compactMetadata
        )
        self.payload = persistence.load(defaultValue: Payload()).value
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
               other.id != command.id
                    && unsuppressedShortcut(for: other, payload: payload) == candidate
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

        var candidate = payload
        candidate.bound.removeValue(forKey: command.id)
        candidate.cleared.removeAll { $0 == command.id }

        if let shortcut {
            if shortcut != command.defaultShortcut
                || defaultConflict(for: command, payload: candidate) != nil {
                candidate.bound[command.id] = shortcut
            }
        } else if command.defaultShortcut != nil {
            candidate.cleared.append(command.id)
        }

        commit(candidate)
    }

    func reset(_ command: AppCommand) {
        var candidate = payload
        candidate.bound.removeValue(forKey: command.id)
        candidate.cleared.removeAll { $0 == command.id }
        commit(candidate)
    }

    func resetAll() {
        commit(Payload())
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
        defaultConflict(for: command, payload: payload)
    }

    private func defaultConflict(
        for command: AppCommand,
        payload: Payload
    ) -> AppCommand? {
        guard command.origin.extensionIdentifier != nil,
              payload.bound[command.id] == nil,
              !payload.cleared.contains(command.id),
              let candidate = command.defaultShortcut else {
            return nil
        }
        return registry.all.first { other in
            other.id != command.id
                && unsuppressedShortcut(for: other, payload: payload) == candidate
        }
    }

    private func unsuppressedShortcut(
        for command: AppCommand,
        payload: Payload
    ) -> KeyboardShortcut? {
        guard command.isEditable else { return command.defaultShortcut }
        if payload.cleared.contains(command.id) { return nil }
        return payload.bound[command.id] ?? command.defaultShortcut
    }

    // MARK: - Persistence

    private func commit(_ candidate: Payload) {
        if persistence.save(candidate) {
            payload = candidate
            NotificationCenter.default.post(KeyboardShortcutsDidChange())
        }
    }

    private enum Keys {
        static let overrides = "keyboardShortcutOverrides"
    }
}
