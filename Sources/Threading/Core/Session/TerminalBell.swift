import AppKit

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

    /// Called once for every `BEL`, after whoever owns the session has said why it rang.
    ///
    /// `cause` is nil for a surface that keeps no activity tracker — a standalone terminal, the
    /// shell drawer — where none of the state the causes are told apart by exists. Those ring at
    /// the bell's own level, which is exactly as loudly as every bell rang before causes did.
    ///
    /// `owner` is which **record** rang, so the chat's and the project's entries — or the
    /// standalone terminal's and its project's — sit in front of the app's. Nil for a terminal
    /// with no record behind it, which resolves at the app scope alone.
    ///
    /// Nothing is cached: a change in Settings applies to the next bell, with nothing to
    /// invalidate.
    ///
    /// A bell that is actually heard leaves a note behind it — see `playAndRegister` — which is
    /// how the attention alert about to describe the same edge knows not to sound twice.
    static func ring(cause: SoundEvent? = nil, owner: SoundOwner? = nil) {
        ring(
            cause: cause,
            silenced: { AppSettings.shared.silencesAllSounds },
            admits: { player.admitsPlaybackNow() },
            resolve: { cause in
                guard let cause else {
                    return SoundResolution.sound(for: SoundEvent.Kind.bell, owner: owner)
                }
                return SoundResolution.sound(for: cause, owner: owner)
            },
            play: { playAndRegister($0, owner: owner, speaker: { deliver($0) }) }
        )
    }

    /// The order the four steps happen in, with each of them handed in.
    ///
    /// **The gate runs first, then the limiter**, and only then the resolution chain and the
    /// file the chosen name has to be looked up in. A `BEL` arrives as fast as a program can
    /// write a byte, so a silenced storm costs one Boolean read per bell and nothing else — in
    /// particular it must not consume the limiter's window, which would otherwise mean the first
    /// bell after the gate opens is the one that gets swallowed. A bell the *limiter* rejects
    /// then costs a date comparison, rather than a dictionary walk and up to three `stat`s.
    ///
    /// Separate from the entry point above so the ordering can be asserted without a real
    /// player, a real settings map or a speaker.
    static func ring(
        cause: SoundEvent?,
        silenced: () -> Bool,
        admits: () -> Bool,
        resolve: (SoundEvent?) -> SoundChoice,
        play: (SoundChoice) -> Void
    ) {
        guard !silenced() else { return }
        guard admits() else { return }
        play(resolve(cause))
    }

    /// The same sound the bell would make, for the settings picker to audition. Shares the
    /// player so a preview and a real bell cannot overlap either.
    ///
    /// `system` is the *alert* beep here rather than the notification tone: a bell is the
    /// program in front of you shouting a single byte down the PTY, and this app plays it.
    ///
    /// **The global silence gate does not apply here, deliberately.** Picking an item in a sound
    /// list is an explicit ask to hear that sound while choosing it; a picker that played
    /// nothing would read as broken rather than as quiet, and the gate would be teaching the
    /// user that the sound they just chose does not work. Same rule as
    /// `NotificationSoundPreview`. Everything that plays *on the app's own initiative* is gated.
    static func play(_ sound: SoundChoice) {
        guard player.admitsPlaybackNow() else { return }
        deliver(sound)
    }

    // MARK: - The Note An Audible Bell Leaves

    /// Makes the sound, then tells `AudibleBellRegister` this session has just been spoken for.
    ///
    /// **Position is the whole point.** This is the play step and nothing earlier: a bell the
    /// global gate holds, and a bell the rate limiter rejects, never arrive here, so neither
    /// leaves a note — and rightly, because in both cases the user heard nothing and an alert
    /// sounding a moment later is not a double.
    ///
    /// The speaker is handed in for the same reason the four steps above are: the ordering, and
    /// the rule that a note follows a sound rather than replacing it, can be asserted without
    /// anything audible happening in a test.
    static func playAndRegister(
        _ sound: SoundChoice,
        owner: SoundOwner?,
        speaker: (SoundChoice) -> Void,
        register: AudibleBellRegister = .shared
    ) {
        speaker(sound)
        guard let sessionID = registration(for: sound, owner: owner) else { return }
        register.recordAudibleBell(for: sessionID)
    }

    /// Which record an audible bell speaks for, or nil when there is nothing to say.
    ///
    /// Nil for `silent`: nobody heard it, so a banner sounding beside it is not a double — and
    /// a user who set this bell to Off asked for exactly that. Nil for a standalone or an
    /// ephemeral terminal, which keeps no conversation and therefore has no attention alert to
    /// collide with; only `session` owners are ever registered.
    ///
    /// Every other choice counts as heard, **including a named sound whose file has gone**:
    /// `deliver` falls back to the alert beep rather than to silence, and a beep is a sound.
    static func registration(for sound: SoundChoice, owner: SoundOwner?) -> SessionID? {
        if case .silent = sound { return nil }
        guard case .session(let sessionID)? = owner else { return nil }
        return sessionID
    }

    // MARK: - Private Methods

    /// Plays a choice the limiter has already admitted.
    private static func deliver(_ sound: SoundChoice) {
        switch sound {
        case .silent:
            return
        case .system:
            player.playSystemAlertAdmitted()
        case .named(let fileName):
            // A name whose file has gone falls back to the system alert rather than to
            // silence, for the same reason the notification sound does: a bell nobody hears
            // is worse than the bell they used to have.
            guard let resolved = NotificationSoundLibrary.resolve(fileName: fileName) else {
                player.playSystemAlertAdmitted()
                return
            }
            player.playAdmitted(resolved.url)
        }
    }
}

// MARK: - Audible Bell Register

/// The note a bell leaves for the attention alert that is about to describe the same edge.
///
/// One `BEL` in a background session used to make two sounds: the bell, and the `.blocked`
/// banner `AttentionAlertCenter` posts for the `awaitingUser` that same bell settled. Neither
/// subsystem is wrong on its own, so one of them has to learn about the other — and **which
/// way the report flows is forced by when each of them decides**. The ring is synchronous
/// inside `TerminalSession.onBell`; the alert's decision is a main-actor turn later, because
/// the center observes the activity edge through a `Task` and its `post` reads the project
/// icon off disk, which is work that may not happen on the PTY's byte path. So the bell
/// reports what it did and the alert reads it, rather than the alert predicting itself.
///
/// **Uncertainty rings.** An absent note, an expired one, a bell the gate held, one the limiter
/// rejected, one resolved to `silent`, one from a standalone terminal — every one of them
/// leaves the alert sounding. Nothing here can quiet a bell, only an alert's sound, so a bell
/// cannot go missing for a reason the user cannot see; the worst case is the pair this exists
/// to remove.
///
/// Nothing else reads it. The register is the whole seam between these two subsystems: no
/// notifications, no I/O, one dictionary.
@MainActor
final class AudibleBellRegister {

    static let shared = AudibleBellRegister()

    private let window: TimeInterval
    private var heard: [SessionID: Date] = [:]

    init(window: TimeInterval = TerminalBellDefaults.audibleBellWindow) {
        self.window = window
    }

    // MARK: - Public Methods

    /// Records a bell this session actually made.
    func recordAudibleBell(for sessionID: SessionID, at date: Date = Date()) {
        dropStale(at: date)
        heard[sessionID] = date
    }

    /// Whether a bell this session made is still speaking for it.
    func heardBell(for sessionID: SessionID, at date: Date = Date()) -> Bool {
        dropStale(at: date)
        return heard[sessionID] != nil
    }

    // MARK: - Private Methods

    /// Bounded without a timer, because a timer for half a second of memory is a subscription
    /// nobody would want to own: one entry per session, overwritten rather than appended, and
    /// every read and every write drops what has gone stale. The map cannot grow past the
    /// number of sessions that rang inside one window.
    ///
    /// A note dated in the future is stale too. That is a clock that moved under us, and the
    /// answer to "did a bell just ring" is then unknown — which rings.
    private func dropStale(at date: Date) {
        heard = heard.filter { (0..<window).contains(date.timeIntervalSince($0.value)) }
    }
}

// MARK: - Terminal Bell Defaults

enum TerminalBellDefaults {
    /// What an install that has never chosen hears: exactly what it heard before this setting
    /// existed, which is SwiftTerm's `NSSound.beep()`.
    static let sound: SoundChoice = .system

    /// How close together two bells may be heard. Long enough that a loop of them is one
    /// sound, short enough that two deliberate bells in a row are still two.
    static let minimumInterval: TimeInterval = 0.2

    /// How long a bell that was heard speaks for its session, keeping the alert describing the
    /// same edge quiet.
    ///
    /// It has one main-actor turn to survive — the two sounds land ~0 ms apart, and the alert's
    /// decision is only deferred, not delayed — plus whatever the main thread is busy with in
    /// between. A handful of milliseconds would therefore be a race under load. It must also
    /// stay well below the gap that makes a *later* alert its own event, or a banner with
    /// nothing to do with the bell would post silently.
    ///
    /// `minimumInterval` above already answers the same shape of question for the bell itself —
    /// two bells further apart than 0.2 s are two sounds — so this stays in that order of
    /// magnitude rather than reaching for seconds: 2.5× the limiter, which is orders of
    /// magnitude above the hop it has to cover and still inside the span a person hears as one
    /// event.
    static let audibleBellWindow: TimeInterval = 0.5
}
