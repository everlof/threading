import Foundation

// MARK: - Sound Resolution

/// Which sound one event makes.
///
/// Pure, in the same way `AttentionAlertScope.resolve` is pure and for the same reason: the
/// chain is the part that has to be right, and it is testable without a store, a settings page
/// or a speaker. The `@MainActor` conveniences at the foot read the app's own entries and hand
/// them in; nothing above them touches storage.
///
/// The order within one scope is three levels wide, narrowest first:
///
/// ```
/// scope[event]  →  scope[kind]  →  scope[all]  →  next scope out  →  built-in default
/// ```
///
/// and the scopes themselves are an array so the session's and the project's go **in front** of
/// the app's without a caller changing shape:
///
/// ```
/// session (or standalone terminal)  →  project  →  app  →  built-in default
/// ```
///
/// A record carrying no overrides contributes no scope at all, which is what makes the whole
/// model opt-in: with every `soundOverrides` absent — the state every install is in until
/// somebody picks something — the array is exactly `[appScope()]` and every answer is the one
/// the app-wide pickers have always given.
///
/// The app scope deliberately has **no `all` level**: its two pickers are its outermost
/// entries, and a third app-wide answer above them would be a setting with nowhere to live.
///
/// **The global silence gate is not in here, deliberately.** It is a gate rather than a scope —
/// it does not answer the question "what is this event set to", it refuses to ask it — so it
/// lives on the `@MainActor` conveniences at the foot, where the app's own state is already
/// being read. Keeping it out of the chain is what leaves `resolve` a pure function of its
/// arguments, and what makes "toggling the gate off restores every scope's answer untouched"
/// something a test can state directly against this file.
enum SoundResolution {

    // MARK: - One Scope's Entries

    /// What one scope has been given a say about.
    ///
    /// Absent entries are the common case: a scope with nothing to say is an empty value here
    /// and nothing at all in storage, which is what makes the whole model opt-in rather than a
    /// table of inherited values copied into every record.
    struct Scope: Equatable, Sendable {

        /// Entries for one event each. Narrower than `kinds`, and the only level that can give
        /// an opt-in event a sound.
        var events: [SoundEvent: SoundChoice]

        /// One entry for every bell, one for every alert — the level the app's two existing
        /// pickers occupy.
        var kinds: [SoundEvent.Kind: SoundChoice]

        /// The base coat: every event this scope has not answered more narrowly. What the
        /// one-click submenu writes, and the widest thing a record can say.
        var all: SoundChoice?

        init(
            events: [SoundEvent: SoundChoice] = [:],
            kinds: [SoundEvent.Kind: SoundChoice] = [:],
            all: SoundChoice? = nil
        ) {
            self.events = events
            self.kinds = kinds
            self.all = all
        }

        /// Reads the stored map, which is `[String: String]` rather than a typed dictionary so
        /// a key written by a later build survives a read and a write here.
        ///
        /// A key this build does not know is therefore **not** an error and not a loss: it is
        /// simply not an answer to any question this build asks. The raw map stays whole in
        /// storage — see `AppSettings.setSoundChoice(_:for:)` and
        /// `ProjectStore.setSoundOverrides(_:forSessionID:)`.
        ///
        /// `bell` and `alert` are handed in separately because the **app** scope keeps its two
        /// kind entries in the two preferences the settings pickers already write, not in the
        /// per-event map. A record keeps all three levels in one map and uses
        /// `init(storedOverrides:)` below, which reads the reserved keys out of it.
        init(
            storedEvents: [String: String],
            bell: SoundChoice? = nil,
            alert: SoundChoice? = nil,
            all: SoundChoice? = nil
        ) {
            var events: [SoundEvent: SoundChoice] = [:]
            for (key, value) in storedEvents {
                guard let event = SoundEvent(rawValue: key),
                      let choice = SoundChoice(storedValue: value)
                else { continue }
                events[event] = choice
            }

            var kinds: [SoundEvent.Kind: SoundChoice] = [:]
            kinds[.bell] = bell
            kinds[.alert] = alert

            self.init(events: events, kinds: kinds, all: all)
        }

        /// One record's whole say, read out of the single map it stores.
        ///
        /// Nil for a record with nothing to say — which is the common case, and the reason it
        /// is optional rather than empty: a scope that answers nothing must not sit in the
        /// chain at all, so "no overrides anywhere" is literally the array it was before
        /// records could carry any.
        init?(storedOverrides: [String: String]?) {
            guard let storedOverrides, !storedOverrides.isEmpty else { return nil }

            var kinds: [SoundEvent.Kind: SoundChoice] = [:]
            for kind in SoundEvent.Kind.allCases {
                kinds[kind] = SoundChoice(storedValue: storedOverrides[SoundOverrideKeys.key(for: kind)])
            }

            self.init(
                storedEvents: storedOverrides,
                bell: kinds[.bell],
                alert: kinds[.alert],
                all: SoundChoice(storedValue: storedOverrides[SoundOverrideKeys.all])
            )
        }
    }

    // MARK: - The Chain

    /// The sound one event makes, resolved through the scopes narrowest first.
    ///
    /// At most three lookups per scope, plus `bellOtherProgram`'s one indirection. A bell is
    /// driven by a PTY and can arrive as fast as a program can write a byte, so this stays O(1)
    /// in the number of scopes and never touches the filesystem — the file a name resolves to
    /// is looked up by whoever plays it, and only if the limiter admitted it.
    static func resolve(_ event: SoundEvent, through scopes: [Scope]) -> SoundChoice {
        for scope in scopes {
            if let entry = scope.events[event] { return entry }
            if let borrowed = borrowedEvent(for: event), let entry = scope.events[borrowed] {
                return entry
            }
            if let entry = scope.kinds[event.kind], admits(entry, for: event) { return entry }
            if let entry = scope.all, admits(entry, for: event) { return entry }
        }
        return builtInDefault(for: event)
    }

    /// The sound a bell makes when nothing can say **why** it rang.
    ///
    /// A standalone terminal and the shell drawer keep no activity tracker, so none of the state
    /// the four bell events are told apart by exists there. They resolve at the kind's own level
    /// — exactly as loudly as every bell did before events existed.
    static func resolve(kind: SoundEvent.Kind, through scopes: [Scope]) -> SoundChoice {
        for scope in scopes {
            if let entry = scope.kinds[kind] { return entry }
            if let entry = scope.all { return entry }
        }
        return builtInDefault(for: kind)
    }

    // MARK: - What One Row Inherits

    /// One level a scope can be asked about by name — the two the Customize sheet has a row for.
    ///
    /// `all` is deliberately absent: it is the one-click tier's level, written by the submenu
    /// through `SoundOverrideKeys.all`, and it is not a row anywhere. A level here is a level
    /// something can inherit *around*, which the base coat — being the widest thing a scope can
    /// say — is not.
    enum Level: Hashable, Sendable {
        case event(SoundEvent)
        case kind(SoundEvent.Kind)

        /// The key this level occupies in a record's stored map.
        var storageKey: String {
            switch self {
            case .event(let event): return event.rawValue
            case .kind(let kind): return SoundOverrideKeys.key(for: kind)
            }
        }
    }

    /// What one row of the Customize sheet reads **without an entry of its own at this scope**.
    ///
    /// The definition the whole sheet turns on, in one function because the parentheticals are
    /// the part that will silently go wrong: *Inherit (…)* names this, and the writer compares a
    /// chosen sound against this to decide whether the row stores anything at all. Two readings
    /// from one expression cannot disagree about what "inherited" means.
    ///
    /// Only this scope's entry **for that level** is removed. Everything else stands, including
    /// this scope's other levels — an event row over a scope whose `all` is Submarine reads
    /// *Inherit (Submarine)*, because that is exactly what the row would resolve to if it were
    /// cleared. It is the chain answering the question, not a shortcut past it.
    static func inherited(_ level: Level, at scope: Scope, beyond outer: [Scope]) -> SoundChoice {
        var stripped = scope
        switch level {
        case .event(let event):
            stripped.events[event] = nil
            return resolve(event, through: [stripped] + outer)
        case .kind(let kind):
            stripped.kinds[kind] = nil
            return resolve(kind: kind, through: [stripped] + outer)
        }
    }

    /// The one answer every **voiced** event resolves to through `scopes`, or nil when they
    /// differ.
    ///
    /// What the submenu's *Inherit* parenthetical names, and what its writer compares a chosen
    /// sound against so a value equal to the inherited one is stored as nothing. Opt-in events
    /// take no part: they are silent by construction until somebody names them, and counting
    /// that silence as disagreement would make the parenthetical read *mixed* on every install
    /// that has chosen nothing at all.
    ///
    /// Nil is the honest answer rather than a favourite, and it is the common one right after
    /// migration: the app scope usually holds a bell sound and a different notification tone.
    static func uniformAnswer(through scopes: [Scope]) -> SoundChoice? {
        var answer: SoundChoice?
        for event in SoundEvent.allCases where !isOptIn(event) {
            let resolved = resolve(event, through: scopes)
            if let answer {
                guard answer == resolved else { return nil }
            } else {
                answer = resolved
            }
        }
        return answer
    }

    /// Whether anyone has asked to hear `bell.otherProgram` apart from the bell that asks.
    ///
    /// The gate on the only attribution that costs anything: without an entry of its own, the
    /// event would resolve through `bell.agentAsking` and sound identical, so asking the kernel
    /// who holds the PTY would buy a distinction nobody could hear. Nobody pays for attribution
    /// until somebody has asked for it.
    static func attributesOtherPrograms(through scopes: [Scope]) -> Bool {
        scopes.contains { $0.events[.bellOtherProgram] != nil }
    }

    // MARK: - The Built-in Answers

    /// The bottom of every chain, per event — today's behaviour, verbatim.
    ///
    /// Not one value: the app has never made the same sound for all nine. Every bell is the
    /// system alert beep, the two alerts that sound are the macOS notification tone, and the
    /// three that have never made a sound stay silent. That last row is what "no behaviour
    /// change" is measured against, and the opt-in rule below is what keeps it true when
    /// somebody paints a whole kind with one sound.
    static func builtInDefault(for event: SoundEvent) -> SoundChoice {
        switch event {
        case .bellAgentAsking, .bellAgentVisible, .bellLaunch, .bellOtherProgram:
            return TerminalBellDefaults.sound
        case .alertBlocked, .alertRequestedUpdate:
            return AttentionAlertDefaults.sound
        case .alertUnread, .alertFinished, .alertScheduledMessage:
            return .silent
        }
    }

    /// The bottom of the chain for a sound with no event — see `resolve(kind:through:)`.
    static func builtInDefault(for kind: SoundEvent.Kind) -> SoundChoice {
        switch kind {
        case .bell: return TerminalBellDefaults.sound
        case .alert: return AttentionAlertDefaults.sound
        }
    }

    /// Whether this event has to be asked for by name.
    ///
    /// The three events whose built-in answer is silence have never made a sound in this app,
    /// and a broad stroke must not be what starts them.
    static func isOptIn(_ event: SoundEvent) -> Bool {
        builtInDefault(for: event) == .silent
    }

    // MARK: - Private Methods

    /// Whether an entry broader than the event applies to it — the kind level and the `all`
    /// level alike, since both are strokes wider than one event.
    ///
    /// Both halves of the voiced/opt-in rule are load-bearing. One click of a sound on a whole
    /// kind or a whole chat must not voice three events that have never sounded — a scope
    /// acquiring noise because it changed shape is what the contract forbids. One click of *Off*
    /// must still mean off, so `silent` at a broader level **does** reach them.
    ///
    /// Written here rather than as explicit `silent` entries at migration, which fails
    /// structurally: a narrower `all` entry added later would sit ahead of them and voice the
    /// events anyway.
    private static func admits(_ choice: SoundChoice, for event: SoundEvent) -> Bool {
        !isOptIn(event) || choice == .silent
    }

    /// The event whose entries this one borrows before widening to its kind.
    ///
    /// `bell.otherProgram` is the app's only heuristic cause, and this is what makes a wrong
    /// guess inaudible: it sounds exactly like the bell that asks until someone deliberately
    /// gives it a sound of its own — at which point they have also opted into the occasional
    /// wrong answer.
    private static func borrowedEvent(for event: SoundEvent) -> SoundEvent? {
        event == .bellOtherProgram ? .bellAgentAsking : nil
    }
}

// MARK: - Sound Owner

/// Which record a sound belongs to, and therefore which scopes answer for it.
///
/// A bell has one of three owners, which is why this is a type rather than a `SessionID?`: an
/// agent's terminal and the shell under it belong to a conversation, a standalone terminal
/// belongs to its own record, and an ephemeral terminal belongs to nothing and resolves at the
/// app scope alone. `TerminalInstanceIdentity` already draws exactly that line — see its
/// `ownerSessionID`, which this widens rather than replaces.
enum SoundOwner: Hashable, Sendable {
    case session(SessionID)
    case terminal(TerminalID)

    /// Nil for a terminal with no record behind it. Nothing goes silent because of that: a
    /// scope-less bell resolves through the app scope, exactly as every bell did before records
    /// could carry a sound.
    init?(_ identity: TerminalInstanceIdentity) {
        switch identity {
        case .agentSession(let id), .sessionShell(let id):
            self = .session(id)
        case .projectTerminal(let id):
            self = .terminal(id)
        case .ephemeral:
            return nil
        }
    }
}

// MARK: - The Live Scopes

@MainActor
extension SoundResolution {

    /// The app's own entries: the two existing pickers at the kind level, and the per-event map
    /// beneath them.
    static func appScope(_ settings: AppSettings = .shared) -> Scope {
        Scope(
            storedEvents: settings.soundEventChoices,
            bell: settings.terminalBellSound,
            alert: settings.attentionAlertSound
        )
    }

    /// Every scope with a say about this owner, narrowest first.
    ///
    /// Records are reached through `ProjectStore`'s public accessors — dictionary lookups plus
    /// an array index, the same route `AttentionAlertScope.isMuted` takes and for the same
    /// reason: `locate` is private, and a bell must not scan.
    ///
    /// A record with nothing to say contributes nothing, so an install that has chosen no
    /// sounds gets `[appScope()]` back — the array this returned before records existed.
    static func scopes(for owner: SoundOwner? = nil) -> [Scope] {
        guard let owner else { return [appScope()] }

        let store = ProjectStore.shared
        var scopes: [Scope] = []
        switch owner {
        case .session(let sessionID):
            if let scope = Scope(storedOverrides: store.session(withID: sessionID)?.soundOverrides) {
                scopes.append(scope)
            }
            if let scope = Scope(
                storedOverrides: store.project(forSessionID: sessionID)?.soundOverrides
            ) {
                scopes.append(scope)
            }
        case .terminal(let terminalID):
            if let scope = Scope(storedOverrides: store.terminal(withID: terminalID)?.soundOverrides) {
                scopes.append(scope)
            }
            // The record that persists the terminal is the project that answers for it. This
            // lookup stays O(1), which matters because a bell arrives as fast as a program can
            // write a byte, and it matches the same ownership used by themes and placement.
            if let scope = Scope(
                storedOverrides: store.homeProject(forTerminalID: terminalID)?.soundOverrides
            ) {
                scopes.append(scope)
            }
        }
        scopes.append(appScope())
        return scopes
    }

    /// The scopes answering for one conversation. The alert paths only ever have a session.
    static func scopes(forSessionID sessionID: SessionID?) -> [Scope] {
        scopes(for: sessionID.map(SoundOwner.session))
    }

    // MARK: - What a Scope Inherits

    /// The scopes **above** one record: what it resolves through with nothing of its own.
    ///
    /// The submenu needs this twice — to name the inherited answer in its first item, and to
    /// decide whether a chosen sound is worth storing — and both readings have to come from one
    /// place, or the parenthetical and the writer could disagree about what "inherited" means.
    static func inheritedScopes(forSessionID sessionID: SessionID) -> [Scope] {
        var scopes: [Scope] = []
        if let scope = Scope(
            storedOverrides: ProjectStore.shared.project(forSessionID: sessionID)?.soundOverrides
        ) {
            scopes.append(scope)
        }
        scopes.append(appScope())
        return scopes
    }

    /// A project inherits from the app alone.
    static func inheritedScopes(forProjectID projectID: ProjectID) -> [Scope] {
        [appScope()]
    }

    /// A standalone terminal inherits from the project that persists it — see `scopes(for:)`
    /// for why that is the home project and not the cwd-derived one.
    static func inheritedScopes(forTerminalID terminalID: TerminalID) -> [Scope] {
        var scopes: [Scope] = []
        if let scope = Scope(
            storedOverrides: ProjectStore.shared.homeProject(forTerminalID: terminalID)?.soundOverrides
        ) {
            scopes.append(scope)
        }
        scopes.append(appScope())
        return scopes
    }

    /// Whether the app is currently holding every sound it can make.
    ///
    /// Read here rather than at each caller so the alert paths have **one** seam: whatever asks
    /// this chain for a sound while the gate is closed is told `silent`, and a silent answer is
    /// already a complete answer everywhere — a banner posts with no sound, and nothing visual
    /// turns on it.
    ///
    /// The bell does **not** rely on this. It checks the gate itself, ahead of its rate limiter,
    /// because a silenced storm must not consume the window or reach a dictionary at all — see
    /// `TerminalBell.ring`.
    static var isSilenced: Bool { AppSettings.shared.silencesAllSounds }

    static func sound(for event: SoundEvent, owner: SoundOwner? = nil) -> SoundChoice {
        guard !isSilenced else { return .silent }
        return resolve(event, through: scopes(for: owner))
    }

    static func sound(for kind: SoundEvent.Kind, owner: SoundOwner? = nil) -> SoundChoice {
        guard !isSilenced else { return .silent }
        return resolve(kind: kind, through: scopes(for: owner))
    }

    static func sound(for event: SoundEvent, sessionID: SessionID?) -> SoundChoice {
        sound(for: event, owner: sessionID.map(SoundOwner.session))
    }

    /// Nobody pays for attribution they have not asked for — nor for one nobody could hear.
    /// The cause is still classified while the gate holds; only the syscalls that would tell
    /// two inaudible sounds apart are skipped, and `SessionActivityTracker.recordBell` sets the
    /// sidebar's hand from state of its own rather than from the cause.
    static func attributesOtherPrograms(owner: SoundOwner? = nil) -> Bool {
        guard !isSilenced else { return false }
        return attributesOtherPrograms(through: scopes(for: owner))
    }

    static func attributesOtherPrograms(sessionID: SessionID?) -> Bool {
        attributesOtherPrograms(owner: sessionID.map(SoundOwner.session))
    }
}
