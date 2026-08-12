import AppKit

// MARK: - Terminal Bell Sound

/// What a program's `BEL` does.
///
/// Distinct from `AttentionAlertSound` even though both pick from the same folders, because the
/// two are not the same event and do not have the same cases. An attention alert is Threading
/// noticing something for you and goes out through `UNUserNotificationCenter`, where "the
/// default" means the system's *notification* tone. A bell is the program in front of you
/// shouting a single byte down the PTY: Threading plays it directly, "the default" means the
/// system *alert* sound, and it can be switched off outright — which the alert sound cannot,
/// because a switch already does that.
enum TerminalBellSound: Equatable, Hashable, Sendable {

    /// The bell is seen (the sidebar mark, the activity edge) but not heard.
    case silent

    /// `NSSound.beep()` — the system alert sound, which is what a terminal bell has always
    /// been on this platform and what SwiftTerm's own default did.
    case systemAlert

    /// A file resolvable by name in one of `NotificationSoundLibrary.searchPaths`.
    case named(String)

    /// Stored as one string. The two tokens cannot collide with a sound: a stored name is
    /// always a *file* name and every file name the library will offer carries one of the
    /// playable extensions, so neither `silent` nor `system` can ever name one.
    init(storedValue: String?) {
        switch storedValue {
        case .none: self = TerminalBellDefaults.sound
        case TerminalBellDefaults.silentToken: self = .silent
        case TerminalBellDefaults.systemToken: self = .systemAlert
        case .some(let fileName) where fileName.isEmpty: self = TerminalBellDefaults.sound
        case .some(let fileName): self = .named(fileName)
        }
    }

    var storedValue: String {
        switch self {
        case .silent: return TerminalBellDefaults.silentToken
        case .systemAlert: return TerminalBellDefaults.systemToken
        case .named(let fileName): return fileName
        }
    }
}

// MARK: - Terminal Bell

/// Rings the bell, or does not.
///
/// One player for the whole app rather than one per session. A bell is a sound in a room, and
/// four sessions ringing at once should not be four overlapping copies of it; the rate limit
/// below is what makes a program looping on `printf '\a'` cost one sound instead of hundreds.
/// That also keeps the terminal's output path free of unbounded work, which is the rule for
/// anything a PTY can drive.
@MainActor
enum TerminalBell {

    private static let player = SoundPlayer(minimumInterval: TerminalBellDefaults.minimumInterval)

    /// Called for every `BEL`. Reading the preference here rather than caching it means a
    /// change in Settings applies to the next bell, with nothing to invalidate.
    static func ring() {
        play(AppSettings.shared.terminalBellSound)
    }

    /// The same sound the bell would make, for the settings picker to audition. Shares the
    /// player so a preview and a real bell cannot overlap either.
    static func play(_ sound: TerminalBellSound) {
        switch sound {
        case .silent:
            return
        case .systemAlert:
            player.playSystemAlert()
        case .named(let fileName):
            // A name whose file has gone falls back to the system alert rather than to
            // silence, for the same reason the notification sound does: a bell nobody hears
            // is worse than the bell they used to have.
            guard let resolved = NotificationSoundLibrary.resolve(fileName: fileName) else {
                player.playSystemAlert()
                return
            }
            player.play(resolved.url)
        }
    }
}

// MARK: - Terminal Bell Defaults

enum TerminalBellDefaults {
    /// What an install that has never chosen hears: exactly what it heard before this setting
    /// existed, which is SwiftTerm's `NSSound.beep()`.
    static let sound: TerminalBellSound = .systemAlert

    /// Reserved stored values. Not file names: every offered sound carries a playable
    /// extension, so a bare word can never be one.
    static let silentToken = "silent"
    static let systemToken = "system"

    /// How close together two bells may be heard. Long enough that a loop of them is one
    /// sound, short enough that two deliberate bells in a row are still two.
    static let minimumInterval: TimeInterval = 0.2
}
