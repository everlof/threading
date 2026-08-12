import Foundation

// MARK: - Sound Event

/// One occasion Threading makes a sound on.
///
/// Not a wish list: every case is something the app already computes for another purpose — the
/// four bells from the state `SessionActivityTracker.recordBell` reads, the five alerts from the
/// paths that already post them — which is what makes routing them a routing problem rather than
/// new instrumentation.
///
/// The raw values are dotted (`bell.agentAsking`) because they are **stored** keys: a per-event
/// map written by a later build naming an event this one does not know must survive being read
/// and written here, so the names are a wire format and must not be renamed.
enum SoundEvent: String, CaseIterable, Sendable {

    // MARK: - Bells

    /// Not visible, and not an unattended launch — the bell that raises the sidebar's hand.
    case bellAgentAsking = "bell.agentAsking"

    /// You are looking at the session that rang.
    case bellAgentVisible = "bell.agentVisible"

    /// A bell during a launch nobody made by hand: boot noise rather than an ask.
    case bellLaunch = "bell.launch"

    /// The PTY's foreground process group is not the agent — a test runner finishing, a build
    /// failing. The one heuristic here, and the reason it resolves through `bellAgentAsking`
    /// before widening: a wrong guess must be inaudible until someone asks to hear this apart.
    case bellOtherProgram = "bell.otherProgram"

    // MARK: - Alerts

    /// A turn stopped on an approval.
    case alertBlocked = "alert.blocked"

    /// Finished or asked while you were elsewhere.
    case alertUnread = "alert.unread"

    /// A turn ended in the background.
    case alertFinished = "alert.finished"

    /// The agent called `notify_user`.
    case alertRequestedUpdate = "alert.requestedUpdate"

    /// A scheduled message was sent, or could not be.
    case alertScheduledMessage = "alert.scheduledMessage"

    // MARK: - Kind

    /// Which of the app's two sounds this event is, which is also what gives `SoundChoice.system`
    /// its meaning: the macOS notification tone for an alert, the system alert beep for a bell.
    enum Kind: String, CaseIterable, Sendable {
        case bell
        case alert
    }

    var kind: Kind {
        switch self {
        case .bellAgentAsking, .bellAgentVisible, .bellLaunch, .bellOtherProgram:
            return .bell
        case .alertBlocked, .alertUnread, .alertFinished, .alertRequestedUpdate,
             .alertScheduledMessage:
            return .alert
        }
    }

    // MARK: - Alerts That Have a Case of Their Own

    /// The event a state alert posts under.
    ///
    /// Here rather than on `AttentionAlert` because the mapping belongs to the routing table:
    /// three of the five alert events have an `AttentionAlert` case, and two — the requested
    /// update and the scheduled message — post through paths of their own with no case to hang
    /// a property on.
    init(_ alert: AttentionAlert) {
        switch alert {
        case .blocked: self = .alertBlocked
        case .unread: self = .alertUnread
        case .finished: self = .alertFinished
        }
    }
}

// MARK: - Stored Override Keys

/// The keys a scope's stored override map may carry beside the event names.
///
/// One map holds all three levels rather than three fields, because the map is what
/// round-trips: a record written by a later build keeps whatever it wrote, whichever level it
/// meant it for. The two kind tokens are `SoundEvent.Kind`'s own raw values, so a kind cannot
/// be spelled two ways; `all` is the only name invented here, and it is reserved for good —
/// `SoundEvent`'s raw values are dotted precisely so no event can ever collide with it.
enum SoundOverrideKeys {
    /// The one-click tier's level: every event this scope has not answered more narrowly.
    static let all = "all"

    static func key(for kind: SoundEvent.Kind) -> String { kind.rawValue }
}

// MARK: - Stored Overrides

/// Edits to a record's stored override map.
///
/// Read-modify-write on the raw map rather than on a decoded value, which is the whole of
/// constraint 2: the keys this build does not know are carried along untouched instead of being
/// dropped by a round trip through a typed dictionary. An empty result is stored as *absence* —
/// a record with nothing left to say must be indistinguishable from one that never said
/// anything, or the scope would keep sitting in the chain answering nothing.
enum SoundOverrides {

    /// The map with one level set, or cleared when `choice` is nil.
    static func setting(
        _ choice: SoundChoice?,
        forKey key: String,
        in overrides: [String: String]?
    ) -> [String: String]? {
        var raw = overrides ?? [:]
        raw[key] = choice?.storedValue
        return raw.isEmpty ? nil : raw
    }

    /// What one scope's own `all` entry says, or nil where it inherits.
    static func choice(forKey key: String, in overrides: [String: String]?) -> SoundChoice? {
        SoundChoice(storedValue: overrides?[key])
    }
}
