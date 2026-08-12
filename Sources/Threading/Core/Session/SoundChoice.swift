import Foundation
@preconcurrency import UserNotifications

// MARK: - Sound Choice

/// What one of Threading's sounds is set to.
///
/// One type for both sounds the app makes. They were two — the notification alert could not be
/// silenced because a separate switch did that, and the bell had no switch so silence had to be
/// one of its values — and the moment silence became a value on both, two types carrying one
/// idea was the thing that would drift.
///
/// The kind is still what gives `system` its meaning: an alert's system sound is the macOS
/// notification tone, played by Notification Center from a name it resolves later, and a bell's
/// is the system alert beep this app plays itself. The choice is the same either way; who plays
/// it is not.
enum SoundChoice: Equatable, Hashable, Sendable {

    /// Posted or rung without a sound. Nothing visual is suppressed: the banner still arrives,
    /// the sidebar still raises its hand, the bell still ends the inferred turn.
    case silent

    /// The kind's own system sound — the macOS notification tone when this is an alert's
    /// choice, the system alert beep when it is a bell's.
    case system

    /// A file resolvable by name in one of `NotificationSoundLibrary.searchPaths`.
    case named(String)

    // MARK: - Stored Form

    /// Reads the stored string, including both forms written before this type existed.
    ///
    /// Fails rather than substituting a default, because the two settings that read this do not
    /// share one: an absent bell is the system alert, an absent alert is the macOS tone, and a
    /// later per-event map will want absence to mean "inherit". The property supplies its own.
    ///
    /// Three shapes decode. The current one is prefixed (`file:Glass.aiff`); the bell's old form
    /// stored a bare file name beside the same two reserved words; the alert's old form stored a
    /// bare file name and nothing at all for the system tone. A bare word that is not reserved
    /// is therefore a file name from one of those two, which is why the prefix exists going
    /// forward — it keeps `silent` and `system` out of the file-name namespace for good.
    init?(storedValue: String?) {
        guard let storedValue, !storedValue.isEmpty else { return nil }
        switch storedValue {
        case SoundChoiceDefaults.silentToken:
            self = .silent
        case SoundChoiceDefaults.systemToken:
            self = .system
        case let value where value.hasPrefix(SoundChoiceDefaults.namePrefix):
            let fileName = String(value.dropFirst(SoundChoiceDefaults.namePrefix.count))
            guard !fileName.isEmpty else { return nil }
            self = .named(fileName)
        case let fileName:
            self = .named(fileName)
        }
    }

    /// Always the prefixed form. Nothing writes a bare name any more.
    var storedValue: String {
        switch self {
        case .silent: return SoundChoiceDefaults.silentToken
        case .system: return SoundChoiceDefaults.systemToken
        case .named(let fileName): return SoundChoiceDefaults.namePrefix + fileName
        }
    }

    // MARK: - Resolution

    /// What goes on a notification: `nil` is silence, `.default` is the macOS tone.
    ///
    /// A name is resolved here rather than handed straight over, because
    /// `UNNotificationSound(named:)` takes a name a system process looks up later and a name
    /// that resolves nowhere posts the banner in silence — no fallback of the system's own. A
    /// stored choice whose file has gone therefore degrades to the tone it used to be heard
    /// beside, never to nothing.
    ///
    /// - Parameter directories: injectable for tests; delivery always uses the search paths.
    func notificationSound(
        in directories: [URL] = NotificationSoundLibrary.searchPaths
    ) -> UNNotificationSound? {
        switch self {
        case .silent:
            return nil
        case .system:
            return .default
        case .named(let fileName):
            guard NotificationSoundLibrary.resolve(fileName: fileName, in: directories) != nil
            else { return .default }
            return UNNotificationSound(named: UNNotificationSoundName(fileName))
        }
    }
}

// MARK: - Sound Choice Defaults

enum SoundChoiceDefaults {
    /// Reserved stored values, and the prefix that keeps a file name from ever being one.
    static let silentToken = "silent"
    static let systemToken = "system"
    static let namePrefix = "file:"
}
