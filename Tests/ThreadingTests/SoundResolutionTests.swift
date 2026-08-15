import XCTest
@testable import Threading

/// The chain that decides which sound one event makes.
///
/// The load-bearing claim of this step is that **nothing changes yet**: the per-event table at
/// the bottom of the chain is today's behaviour written down, so an install that has chosen
/// nothing hears exactly what it heard before events existed. The rest of the file is the two
/// rules that keep it true once someone does choose — an event entry outranking its kind, and a
/// broad stroke that can quiet an event that has never sounded but can never voice one.
@MainActor
final class SoundResolutionTests: XCTestCase {

    // MARK: - The Stored Names

    /// The raw values are a wire format: they are keys in a stored map, and a map written by a
    /// later build has to keep meaning the same thing when this one reads it.
    func testEveryEventKeepsItsStoredName() {
        XCTAssertEqual(
            SoundEvent.allCases.map(\.rawValue),
            [
                "bell.agentAsking",
                "bell.agentVisible",
                "bell.launch",
                "bell.otherProgram",
                "alert.blocked",
                "alert.unread",
                "alert.finished",
                "alert.requestedUpdate",
                "alert.scheduledMessage",
            ]
        )
    }

    func testEveryEventBelongsToTheKindItsNameClaims() {
        for event in SoundEvent.allCases {
            let expected: SoundEvent.Kind = event.rawValue.hasPrefix("bell.") ? .bell : .alert
            XCTAssertEqual(event.kind, expected, event.rawValue)
        }
    }

    // MARK: - The Built-in Answers

    /// The terminus table, event by event: every bell rings, two alerts sound, three do not.
    /// This is the measurement "no behaviour change" is taken against.
    func testTheBuiltInAnswersAreTodaysBehaviour() {
        let expected: [SoundEvent: SoundChoice] = [
            .bellAgentAsking: .system,
            .bellAgentVisible: .system,
            .bellLaunch: .system,
            .bellOtherProgram: .system,
            .alertBlocked: .system,
            .alertRequestedUpdate: .system,
            .alertUnread: .silent,
            .alertFinished: .silent,
            .alertScheduledMessage: .silent,
        ]

        for event in SoundEvent.allCases {
            XCTAssertEqual(
                SoundResolution.resolve(event, through: []),
                expected[event],
                event.rawValue
            )
        }
    }

    /// The three that have never made a sound are the three that have to be asked for by name.
    func testTheSilentEventsAreTheOptInOnes() {
        XCTAssertEqual(
            SoundEvent.allCases.filter(SoundResolution.isOptIn),
            [.alertUnread, .alertFinished, .alertScheduledMessage]
        )
    }

    // MARK: - The Levels

    func testAnEventEntryOutranksItsKind() {
        let scope = SoundResolution.Scope(
            events: [.bellLaunch: .named("Tink.aiff")],
            kinds: [.bell: .named("Glass.aiff")]
        )

        XCTAssertEqual(
            SoundResolution.resolve(.bellLaunch, through: [scope]),
            .named("Tink.aiff")
        )
        XCTAssertEqual(
            SoundResolution.resolve(.bellAgentVisible, through: [scope]),
            .named("Glass.aiff"),
            "the sibling event has no entry of its own and takes the kind's"
        )
    }

    func testAKindEntryOutranksTheBuiltInAnswer() {
        let scope = SoundResolution.Scope(kinds: [.bell: .silent])

        XCTAssertEqual(SoundResolution.resolve(.bellAgentAsking, through: [scope]), .silent)
    }

    /// A narrower scope answers before a wider one is asked. One scope exists today; the array
    /// is what the session's and the project's records go in front of.
    func testTheNarrowerScopeAnswersFirst() {
        let narrow = SoundResolution.Scope(kinds: [.alert: .silent])
        let wide = SoundResolution.Scope(kinds: [.alert: .named("Glass.aiff")])

        XCTAssertEqual(SoundResolution.resolve(.alertBlocked, through: [narrow, wide]), .silent)
        XCTAssertEqual(
            SoundResolution.resolve(.alertBlocked, through: [wide, narrow]),
            .named("Glass.aiff")
        )
    }

    // MARK: - Voiced and Opt-in

    /// One click of a sound on a whole kind must not start three events that have never made
    /// one. A scope acquiring noise because it changed shape is what the contract forbids.
    func testABroadChoiceNeverVoicesAnOptInEvent() {
        let scope = SoundResolution.Scope(kinds: [.alert: .named("Submarine.aiff")])

        for event: SoundEvent in [.alertUnread, .alertFinished, .alertScheduledMessage] {
            XCTAssertEqual(
                SoundResolution.resolve(event, through: [scope]),
                .silent,
                event.rawValue
            )
        }
        XCTAssertEqual(
            SoundResolution.resolve(.alertBlocked, through: [scope]),
            .named("Submarine.aiff"),
            "the voiced events take the same entry"
        )
    }

    /// The other half of the same rule: one click of *Off* means off, including for the events
    /// a broad sound could not have reached.
    func testSilenceAtTheKindLevelStillReachesAnOptInEvent() {
        let scope = SoundResolution.Scope(kinds: [.alert: .silent])

        for event in SoundEvent.allCases where event.kind == .alert {
            XCTAssertEqual(
                SoundResolution.resolve(event, through: [scope]),
                .silent,
                event.rawValue
            )
        }
    }

    /// Only an entry naming the event itself gives it a sound — at any scope.
    func testAnEventEntryVoicesAnOptInEvent() {
        let scope = SoundResolution.Scope(
            events: [.alertFinished: .named("Purr.aiff")],
            kinds: [.alert: .silent]
        )

        XCTAssertEqual(
            SoundResolution.resolve(.alertFinished, through: [scope]),
            .named("Purr.aiff")
        )
    }

    // MARK: - The One Heuristic

    /// `bell.otherProgram` is a guess, so it sounds exactly like the bell that asks until
    /// somebody deliberately gives it a sound — at which point they have opted into the
    /// occasional wrong answer too.
    func testOtherProgramFallsThroughTheBellThatAsks() {
        let scope = SoundResolution.Scope(
            events: [.bellAgentAsking: .named("Tink.aiff")],
            kinds: [.bell: .named("Glass.aiff")]
        )

        XCTAssertEqual(
            SoundResolution.resolve(.bellOtherProgram, through: [scope]),
            .named("Tink.aiff"),
            "it borrows the asking bell's entry rather than widening to the kind"
        )
    }

    func testOtherProgramsOwnEntryWinsOnceItExists() {
        let scope = SoundResolution.Scope(
            events: [.bellAgentAsking: .named("Tink.aiff"), .bellOtherProgram: .silent]
        )

        XCTAssertEqual(SoundResolution.resolve(.bellOtherProgram, through: [scope]), .silent)
    }

    /// The fall-through is per scope: a narrower scope's asking bell answers before a wider
    /// scope is consulted at all.
    func testTheFallThroughHappensWithinAScopeBeforeWidening() {
        let narrow = SoundResolution.Scope(events: [.bellAgentAsking: .named("Tink.aiff")])
        let wide = SoundResolution.Scope(events: [.bellOtherProgram: .named("Purr.aiff")])

        XCTAssertEqual(
            SoundResolution.resolve(.bellOtherProgram, through: [narrow, wide]),
            .named("Tink.aiff")
        )
    }

    /// The gate on the only attribution that costs syscalls.
    func testAttributionIsClaimedOnlyByAnEntryOfItsOwn() {
        XCTAssertFalse(SoundResolution.attributesOtherPrograms(through: []))
        XCTAssertFalse(
            SoundResolution.attributesOtherPrograms(
                through: [SoundResolution.Scope(
                    events: [.bellAgentAsking: .silent],
                    kinds: [.bell: .named("Glass.aiff")]
                )]
            )
        )
        XCTAssertTrue(
            SoundResolution.attributesOtherPrograms(
                through: [SoundResolution.Scope(events: [.bellOtherProgram: .silent])]
            )
        )
    }

    // MARK: - A Bell With No Cause

    /// A standalone terminal and the shell drawer keep no activity tracker, so nothing there can
    /// say why a bell rang. They resolve at the kind's level — as loudly as every bell rang
    /// before causes existed.
    func testABellWithNoCauseResolvesAtItsKind() {
        XCTAssertEqual(SoundResolution.resolve(kind: .bell, through: []), .system)
        XCTAssertEqual(
            SoundResolution.resolve(
                kind: .bell,
                through: [SoundResolution.Scope(
                    events: [.bellAgentAsking: .silent],
                    kinds: [.bell: .named("Glass.aiff")]
                )]
            ),
            .named("Glass.aiff"),
            "an event entry is not an answer to a question with no event in it"
        )
    }

    // MARK: - The App Scope

    /// What every install that has chosen nothing per event hears: the two pickers at the kind
    /// level, and the three silent events still silent behind a named alert sound.
    func testAnEmptyMapKeepsEveryAlertSoundingAsItDidBefore() throws {
        let settings = try scratchSettings()
        settings.attentionAlertSound = .named("Submarine.aiff")
        settings.terminalBellSound = .named("Glass.aiff")

        let scopes = [SoundResolution.appScope(settings)]

        XCTAssertEqual(
            SoundResolution.resolve(.alertBlocked, through: scopes),
            .named("Submarine.aiff")
        )
        XCTAssertEqual(
            SoundResolution.resolve(.alertRequestedUpdate, through: scopes),
            .named("Submarine.aiff"),
            "the requested update has always carried the alert sound, unconditionally"
        )
        for event: SoundEvent in [.alertUnread, .alertFinished, .alertScheduledMessage] {
            XCTAssertEqual(SoundResolution.resolve(event, through: scopes), .silent, event.rawValue)
        }
        for event in SoundEvent.allCases where event.kind == .bell {
            XCTAssertEqual(
                SoundResolution.resolve(event, through: scopes),
                .named("Glass.aiff"),
                event.rawValue
            )
        }
        XCTAssertFalse(
            SoundResolution.attributesOtherPrograms(through: scopes),
            "nobody pays for attribution they have not asked for"
        )
    }

    func testAnEventEntryStoredByTheAppScopeIsRead() throws {
        let settings = try scratchSettings()
        settings.attentionAlertSound = .silent
        settings.setSoundChoice(.named("Purr.aiff"), for: .alertFinished)

        XCTAssertEqual(settings.soundChoice(for: .alertFinished), .named("Purr.aiff"))
        XCTAssertEqual(
            SoundResolution.resolve(.alertFinished, through: [SoundResolution.appScope(settings)]),
            .named("Purr.aiff")
        )
    }

    /// `nil` is *inherit*, and inherit is stored as absence — a value equal to what would have
    /// been inherited is what stops a later change above from reaching this event.
    func testClearingAnEntryRestoresTheInheritedAnswer() throws {
        let settings = try scratchSettings()
        settings.setSoundChoice(.named("Purr.aiff"), for: .alertFinished)
        settings.setSoundChoice(nil, for: .alertFinished)

        XCTAssertNil(settings.soundChoice(for: .alertFinished))
        XCTAssertEqual(
            SoundResolution.resolve(.alertFinished, through: [SoundResolution.appScope(settings)]),
            .silent
        )
    }

    /// A record written by a later build names events this one has never heard of. Reading it,
    /// changing one entry and writing it back must not be how those disappear.
    func testAKeyThisBuildDoesNotKnowSurvivesAWrite() throws {
        let suite = "SoundResolutionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }

        // Written past the typed accessor deliberately: an unknown key is exactly what no API
        // here can produce. The literal is pinned by `AppSettingDefinitions`, which is
        // private for the same reason every other key there is.
        defaults.set(
            ["alert.somethingLater": "file:Hero.aiff", "alert.finished": "file:Purr.aiff"],
            forKey: "soundEventChoices"
        )

        let settings = AppSettings(defaults: defaults)
        settings.setSoundChoice(.silent, for: .alertUnread)

        let reread = AppSettings(defaults: defaults)
        XCTAssertEqual(reread.soundEventChoices["alert.somethingLater"], "file:Hero.aiff")
        XCTAssertEqual(reread.soundChoice(for: .alertFinished), .named("Purr.aiff"))
        XCTAssertEqual(reread.soundChoice(for: .alertUnread), .silent)

        // And the unknown key is not an answer to anything this build asks.
        let scope = SoundResolution.appScope(reread)
        XCTAssertEqual(scope.events[.alertFinished], .named("Purr.aiff"))
        XCTAssertEqual(scope.events.count, 2)
    }

    // MARK: - Private Methods

    /// A hosted test writes to the developer's own defaults domain, so anything storing a
    /// choice gets a suite of its own.
    private func scratchSettings() throws -> AppSettings {
        let suite = "SoundResolutionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return AppSettings(defaults: defaults)
    }
}
