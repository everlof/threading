import Foundation

// MARK: - Sound Scope

/// One place a sound can be chosen, and the storage behind it.
///
/// `SoundResolution` answers *what* a scope says; this answers *where it is written*. The four
/// are not one storage: three are records in the projects store, each carrying its whole say in
/// one raw map, while the app's is spread across the two preferences its settings pickers have
/// always written plus the per-event map beneath them. The Customize sheet is one sheet at every
/// scope precisely because that difference is answered here rather than in the UI.
///
/// Keys are stored strings rather than a typed level, and read-modify-write is on the raw map,
/// for the constraint that runs through this whole feature: a key written by a later build,
/// naming an event this one has never heard of, must survive being read and written here.
enum SoundScope: Hashable, Sendable {

    /// Every chat, project and terminal that has not answered for itself. Not a record.
    case app

    case project(ProjectID)
    case session(SessionID)
    case terminal(TerminalID)
}

// MARK: - Storage

@MainActor
extension SoundScope {

    /// What this scope stores, whole. Nil where nothing is stored — the common case.
    ///
    /// The app scope has no single map, so it is presented as one: the per-event entries plus
    /// the two kind keys its pickers write. Reading is what this is for; writing goes through
    /// `setChoice(_:forKey:)`, which knows which of the three places a key belongs in.
    var storedOverrides: [String: String]? {
        switch self {
        case .app:
            var raw = AppSettings.shared.soundEventChoices
            raw[SoundOverrideKeys.key(for: .bell)] = AppSettings.shared.terminalBellSound.storedValue
            raw[SoundOverrideKeys.key(for: .alert)] =
                AppSettings.shared.attentionAlertSound.storedValue
            return raw
        case .project(let projectID):
            return ProjectStore.shared.project(withID: projectID)?.soundOverrides
        case .session(let sessionID):
            return ProjectStore.shared.session(withID: sessionID)?.soundOverrides
        case .terminal(let terminalID):
            return ProjectStore.shared.terminal(withID: terminalID)?.soundOverrides
        }
    }

    /// This scope's own entry at one level, or nil where it says nothing there.
    ///
    /// Never nil for the app scope's two kind keys: those are the pickers on the General page,
    /// and a picker always reads *something*. That is the same fact the sheet's app-scope kind
    /// rows encode by offering no *Default* item — there is nothing above them to fall back to.
    func choice(forKey key: String) -> SoundChoice? {
        switch self {
        case .app:
            if key == SoundOverrideKeys.key(for: .bell) {
                return AppSettings.shared.terminalBellSound
            }
            if key == SoundOverrideKeys.key(for: .alert) {
                return AppSettings.shared.attentionAlertSound
            }
            guard let event = SoundEvent(rawValue: key) else { return nil }
            return AppSettings.shared.soundChoice(for: event)
        case .project, .session, .terminal:
            return SoundOverrides.choice(forKey: key, in: storedOverrides)
        }
    }

    /// Writes one level, or clears it. Nil is stored as **absence**, which is what keeps a later
    /// change to a broader scope reaching this one.
    ///
    /// - Returns: whether the write landed. A record's write goes through the store and can be
    ///   refused; the app's cannot.
    @discardableResult
    func setChoice(_ choice: SoundChoice?, forKey key: String) -> Bool {
        switch self {
        case .app:
            return setAppChoice(choice, forKey: key)
        case .project(let projectID):
            return ProjectStore.shared.setSoundOverrides(
                updated(with: choice, forKey: key),
                forProjectID: projectID
            ).succeeded
        case .session(let sessionID):
            return ProjectStore.shared.setSoundOverrides(
                updated(with: choice, forKey: key),
                forSessionID: sessionID
            ).succeeded
        case .terminal(let terminalID):
            return ProjectStore.shared.setSoundOverrides(
                updated(with: choice, forKey: key),
                forTerminalID: terminalID
            ).succeeded
        }
    }

    /// Clears every entry this scope holds — the sheet's *Reset All*.
    ///
    /// A record loses its whole map rather than the nine keys this build knows about: a scope
    /// with nothing left to say must be indistinguishable from one that never said anything, and
    /// leaving a later build's key behind would keep it in the chain answering something the
    /// sheet did not show. The app scope keeps no map to drop, so its three keys go instead.
    @discardableResult
    func resetAll() -> Bool {
        switch self {
        case .app:
            AppSettings.shared.resetSoundChoices()
            return true
        case .project(let projectID):
            return ProjectStore.shared.setSoundOverrides(nil, forProjectID: projectID).succeeded
        case .session(let sessionID):
            return ProjectStore.shared.setSoundOverrides(nil, forSessionID: sessionID).succeeded
        case .terminal(let terminalID):
            return ProjectStore.shared.setSoundOverrides(nil, forTerminalID: terminalID).succeeded
        }
    }

    /// How many entries this scope holds for one event each — the count the submenu's
    /// *Customize (N Events)…* reads.
    ///
    /// Event keys only. The kind and `all` levels are broad strokes the menu already shows
    /// through its checkmark, and counting them would make a one-click choice look like an
    /// exception it is not.
    var eventEntryCount: Int {
        (storedOverrides ?? [:]).keys.reduce(into: 0) { count, key in
            if SoundEvent(rawValue: key) != nil { count += 1 }
        }
    }

    // MARK: - The Chain Around This Scope

    /// This scope's own entries, as the resolver reads them.
    var resolutionScope: SoundResolution.Scope {
        switch self {
        case .app:
            return SoundResolution.appScope()
        case .project, .session, .terminal:
            return SoundResolution.Scope(storedOverrides: storedOverrides) ?? .init()
        }
    }

    /// The scopes **beyond** this one: what it resolves through with nothing of its own.
    ///
    /// The app scope has nothing beyond it but the built-in table, so its list is empty — which
    /// is also why its outermost rows read *Default* rather than *Inherit*.
    var inheritedScopes: [SoundResolution.Scope] {
        switch self {
        case .app:
            return []
        case .project(let projectID):
            return SoundResolution.inheritedScopes(forProjectID: projectID)
        case .session(let sessionID):
            return SoundResolution.inheritedScopes(forSessionID: sessionID)
        case .terminal(let terminalID):
            return SoundResolution.inheritedScopes(forTerminalID: terminalID)
        }
    }

    /// What one row reads without an entry of its own here — see `SoundResolution.inherited`.
    func inherited(_ level: SoundResolution.Level) -> SoundChoice {
        SoundResolution.inherited(level, at: resolutionScope, beyond: inheritedScopes)
    }

    // MARK: - Private Methods

    private func updated(with choice: SoundChoice?, forKey key: String) -> [String: String]? {
        SoundOverrides.setting(choice, forKey: key, in: storedOverrides)
    }

    /// The app's three storages, told apart by key. A kind cleared here goes back to the answer
    /// it had before the setting existed rather than to nothing, because there is nothing.
    private func setAppChoice(_ choice: SoundChoice?, forKey key: String) -> Bool {
        if key == SoundOverrideKeys.key(for: .bell) {
            AppSettings.shared.terminalBellSound =
                choice ?? SoundResolution.builtInDefault(for: .bell)
            return true
        }
        if key == SoundOverrideKeys.key(for: .alert) {
            AppSettings.shared.attentionAlertSound =
                choice ?? SoundResolution.builtInDefault(for: .alert)
            return true
        }
        guard let event = SoundEvent(rawValue: key) else { return false }
        AppSettings.shared.setSoundChoice(choice, for: event)
        return true
    }
}
