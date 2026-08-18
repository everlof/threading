import AppKit

// MARK: - System Alert

/// The beep the app makes when it cannot do what it was just asked to do.
///
/// A third sound, beside the terminal bell and the attention alert, and for a long time the only
/// one nothing could turn off. Fifty-eight call sites rang `NSSound.beep()` directly — a menu item
/// with no folder behind it, a back step with nothing behind it, a Quick Look that would not open,
/// a tab that could not be selected — while `AppSettings.silencesAllSounds` reached only
/// `SoundResolution` and `TerminalBell`. So Silence Sounds silenced the bell and the banners and
/// left the app's most frequent sound untouched, which is the one shape of bug a silence switch
/// cannot survive: the user asks for quiet, hears a beep, and learns the setting does not work.
///
/// **It is a gate and not a choice.** This sound is not in `SoundEvent`, has no scope chain and no
/// picker entry. It is the platform's refusal tone rather than a sound anybody chose, and the only
/// question worth asking of it is whether the app may be heard at all. `SoundResolution` answers
/// that question already, for the two sounds that *are* choices, and this asks the same one rather
/// than reading the setting itself — one seam, not two.
///
/// A run nobody is sitting in front of is silent; see `AutomatedRun`.
@MainActor
enum SystemAlert {

    // MARK: - Public Methods

    /// Say, in the only way a beep can, that the action just asked for did not happen.
    ///
    /// Nothing visual is implied and nothing here substitutes for it: a refusal the user needs to
    /// understand still needs words somewhere they are looking. This is the sound that goes with
    /// them, and on its own it means only "not that".
    static func refuse() {
        guard isAudible else { return }
        NSSound.beep()
    }

    /// Whether a refusal can be heard at all, asked of this process and this app's settings.
    static var isAudible: Bool {
        isAudible(silenced: SoundResolution.isSilenced, isAutomated: AutomatedRun.isUnderway)
    }

    /// The decision itself, with both inputs handed in.
    ///
    /// Separate from the property above for the reason `TerminalBell.ring` splits the same way:
    /// the rule is assertable, while the live property is answered by a process that is by
    /// definition a test one and could otherwise only ever report a single row of the table.
    static func isAudible(silenced: Bool, isAutomated: Bool) -> Bool {
        !silenced && !isAutomated
    }
}
