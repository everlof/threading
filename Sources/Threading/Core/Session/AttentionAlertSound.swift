import Foundation
@preconcurrency import UserNotifications

// MARK: - Attention Alert Sound

/// Which sound Threading's notifications play.
///
/// Stored as the sound's file name, or nothing at all for the system default, so the preference
/// is one optional string and an absent key means what it has always meant. A name the search
/// paths no longer answer for resolves back to the default rather than to silence: the file was
/// deleted or the folder moved, and a notification nobody hears is a worse answer than one that
/// pings the way it used to.
enum AttentionAlertSound: Equatable, Hashable, Sendable {

    /// Whatever macOS itself plays for a notification. The name it is listed under, not a
    /// silent case: `nil` on `UNNotificationContent.sound` is silence, `.default` is this.
    case systemDefault

    /// A file resolvable by name in one of `NotificationSoundLibrary.searchPaths`.
    case named(String)

    init(storedValue: String?) {
        guard let storedValue, !storedValue.isEmpty else {
            self = .systemDefault
            return
        }
        self = .named(storedValue)
    }

    var storedValue: String? {
        switch self {
        case .systemDefault: return nil
        case .named(let fileName): return fileName
        }
    }

    /// What goes on the notification. Silence is not expressed here — the caller decides
    /// whether an alert sounds at all, and this decides what it sounds like.
    func resolvedSound(
        in directories: [URL] = NotificationSoundLibrary.searchPaths
    ) -> UNNotificationSound {
        switch self {
        case .systemDefault:
            return .default
        case .named(let fileName):
            guard NotificationSoundLibrary.resolve(fileName: fileName, in: directories) != nil
            else { return .default }
            return UNNotificationSound(named: UNNotificationSoundName(fileName))
        }
    }
}
