import XCTest
@testable import Threading

/// The chain once records can answer: the `all` level inside one scope, and the three scopes a
/// sound actually resolves through — the chat (or the standalone terminal), its project, the app.
///
/// The load-bearing claim of this step is the same as the last one's: **nothing changes until a
/// record carries entries**. With every `soundOverrides` absent — the state every install is in
/// until somebody picks something — `scopes(for:)` returns exactly `[appScope()]`, which is the
/// array it returned before records could carry a sound at all. That is asserted directly below
/// rather than argued for.
@MainActor
final class SoundScopeTests: HostedStoreTestCase {

    // MARK: - The `all` Level

    /// The whole order, in one assertion per rung: an event entry beats the base coat beside it,
    /// which beats the next scope's event entry, which beats *its* base coat, which beats the app.
    func testTheNarrowLevelAnswersBeforeTheBroadOneAtEveryScope() {
        let session = SoundResolution.Scope(
            events: [.bellLaunch: .named("Tink.aiff")],
            all: .named("Purr.aiff")
        )
        let project = SoundResolution.Scope(
            events: [.bellAgentVisible: .named("Ping.aiff")],
            all: .named("Glass.aiff")
        )
        let app = SoundResolution.Scope(kinds: [.bell: .named("Submarine.aiff")])
        let chain = [session, project, app]

        XCTAssertEqual(
            SoundResolution.resolve(.bellLaunch, through: chain),
            .named("Tink.aiff"),
            "session[event]"
        )
        XCTAssertEqual(
            SoundResolution.resolve(.bellAgentVisible, through: chain),
            .named("Purr.aiff"),
            "session[all] outranks the project's own entry for this event"
        )
        XCTAssertEqual(
            SoundResolution.resolve(.bellAgentVisible, through: [project, app]),
            .named("Ping.aiff"),
            "project[event]"
        )
        XCTAssertEqual(
            SoundResolution.resolve(.bellLaunch, through: [project, app]),
            .named("Glass.aiff"),
            "project[all]"
        )
        XCTAssertEqual(
            SoundResolution.resolve(.bellLaunch, through: [app]),
            .named("Submarine.aiff"),
            "the app's kind level, which is where the two existing pickers live"
        )
    }

    /// A kind entry is narrower than the base coat beside it: painting a whole chat *Purr* does
    /// not undo the bell sound that chat was already given.
    func testAKindEntryOutranksTheBaseCoatInTheSameScope() {
        let scope = SoundResolution.Scope(
            kinds: [.bell: .named("Tink.aiff")],
            all: .named("Purr.aiff")
        )

        XCTAssertEqual(SoundResolution.resolve(.bellLaunch, through: [scope]), .named("Tink.aiff"))
        XCTAssertEqual(SoundResolution.resolve(.alertBlocked, through: [scope]), .named("Purr.aiff"))
    }

    // MARK: - Voiced and Opt-in at the `all` Level

    /// One click of *Submarine* on a chat must not start three events that have never made a
    /// sound in this app. A scope acquiring noise because it changed shape is what the contract
    /// forbids, and the base coat is the one click that would do it.
    func testTheBaseCoatNeverVoicesAnOptInEvent() {
        let scope = SoundResolution.Scope(all: .named("Submarine.aiff"))

        for event: SoundEvent in [.alertUnread, .alertFinished, .alertScheduledMessage] {
            XCTAssertEqual(
                SoundResolution.resolve(event, through: [scope]),
                .silent,
                event.rawValue
            )
        }
        for event in SoundEvent.allCases where !SoundResolution.isOptIn(event) {
            XCTAssertEqual(
                SoundResolution.resolve(event, through: [scope]),
                .named("Submarine.aiff"),
                event.rawValue
            )
        }
    }

    /// The other half of the same rule: one click of *Off* on a chat means off, including for
    /// the three events a sound could not have reached — and it means off even where the app
    /// scope has deliberately given one of them a voice.
    func testSilenceAtTheBaseCoatStillReachesAnOptInEvent() {
        let chat = SoundResolution.Scope(all: .silent)
        let app = SoundResolution.Scope(events: [.alertUnread: .named("Purr.aiff")])

        for event in SoundEvent.allCases {
            XCTAssertEqual(
                SoundResolution.resolve(event, through: [chat, app]),
                .silent,
                event.rawValue
            )
        }
    }

    /// Only an entry naming the event itself gives it a sound, at any scope and at any level.
    func testAnEventEntryStillVoicesAnOptInEventPastABaseCoat() {
        let scope = SoundResolution.Scope(
            events: [.alertFinished: .named("Purr.aiff")],
            all: .silent
        )

        XCTAssertEqual(
            SoundResolution.resolve(.alertFinished, through: [scope]),
            .named("Purr.aiff")
        )
    }

    // MARK: - A Bell With No Cause

    /// A standalone terminal's bell has no cause to resolve by, so it takes the kind's own
    /// level — and the base coat beneath it, which is the only level its submenu writes.
    func testACauselessBellConsultsTheKindThenTheBaseCoat() {
        XCTAssertEqual(
            SoundResolution.resolve(
                kind: .bell,
                through: [SoundResolution.Scope(all: .named("Purr.aiff"))]
            ),
            .named("Purr.aiff")
        )
        XCTAssertEqual(
            SoundResolution.resolve(
                kind: .bell,
                through: [SoundResolution.Scope(
                    kinds: [.bell: .named("Tink.aiff")],
                    all: .named("Purr.aiff")
                )],
            ),
            .named("Tink.aiff"),
            "the kind is the narrower answer"
        )
        XCTAssertEqual(
            SoundResolution.resolve(
                kind: .bell,
                through: [
                    SoundResolution.Scope(all: .named("Purr.aiff")),
                    SoundResolution.Scope(kinds: [.bell: .named("Tink.aiff")])
                ]
            ),
            .named("Purr.aiff"),
            "and a narrower scope's base coat still answers before a wider scope is asked"
        )
    }

    // MARK: - The One Heuristic, Against Every Level

    /// `bell.otherProgram` is a guess, and it stays inaudible as a guess: within one scope it
    /// borrows the asking bell's entry before widening to the kind or to the base coat, and it
    /// does that at *every* scope, so a chat's asking bell answers before its project's base coat.
    func testOtherProgramBorrowsTheAskingBellBeforeAnyBroaderLevel() {
        let scope = SoundResolution.Scope(
            events: [.bellAgentAsking: .named("Tink.aiff")],
            kinds: [.bell: .named("Glass.aiff")],
            all: .named("Purr.aiff")
        )

        XCTAssertEqual(
            SoundResolution.resolve(.bellOtherProgram, through: [scope]),
            .named("Tink.aiff")
        )

        let session = SoundResolution.Scope(events: [.bellAgentAsking: .named("Tink.aiff")])
        let project = SoundResolution.Scope(all: .named("Purr.aiff"))
        XCTAssertEqual(
            SoundResolution.resolve(.bellOtherProgram, through: [session, project]),
            .named("Tink.aiff"),
            "the borrow happens inside the narrow scope, before the wide one is consulted"
        )
    }

    // MARK: - The Uniform Inherited Answer

    /// What the submenu's *Inherit* parenthetical names, and what its writer compares against.
    func testTheUniformAnswerIsNilWhenTheVoicedEventsDisagree() {
        let mixed = SoundResolution.Scope(
            kinds: [.bell: .named("Glass.aiff"), .alert: .named("Submarine.aiff")]
        )
        XCTAssertNil(SoundResolution.uniformAnswer(through: [mixed]))

        let painted = SoundResolution.Scope(all: .named("Purr.aiff"))
        XCTAssertEqual(
            SoundResolution.uniformAnswer(through: [painted]),
            .named("Purr.aiff")
        )
    }

    /// The three events that have never sounded take no part in the agreement: their silence is
    /// not a disagreement, and counting it would read *mixed* on every default install.
    func testOptInEventsDoNotBreakTheAgreement() {
        let scope = SoundResolution.Scope(all: .named("Purr.aiff"))

        XCTAssertEqual(
            SoundResolution.resolve(.alertUnread, through: [scope]),
            .silent,
            "the opt-in event really is silent here"
        )
        XCTAssertEqual(
            SoundResolution.uniformAnswer(through: [scope]),
            .named("Purr.aiff"),
            "and the answer is still uniform"
        )
    }

    // MARK: - The Live Scopes

    /// The measurement "no behaviour change until a record carries entries" is taken against.
    func testARecordWithNoOverridesContributesNoScope() throws {
        let fixture = try makeFixture()

        XCTAssertEqual(
            SoundResolution.scopes(for: .session(fixture.session.id)),
            [SoundResolution.appScope()]
        )
        XCTAssertEqual(
            SoundResolution.scopes(for: .terminal(fixture.terminal.id)),
            [SoundResolution.appScope()]
        )
        XCTAssertEqual(SoundResolution.scopes(for: nil), [SoundResolution.appScope()])
    }

    /// A chat resolves through itself, its project, then the app — in that order.
    func testAChatResolvesThroughItsRecordThenItsProjectThenTheApp() throws {
        let fixture = try makeFixture()
        let store = ProjectStore.shared

        XCTAssertEqual(
            store.setSoundOverrides(["all": SoundChoice.named("Purr.aiff").storedValue],
                                    forSessionID: fixture.session.id),
            .applied
        )
        XCTAssertEqual(
            store.setSoundOverrides(["all": SoundChoice.silent.storedValue,
                                     "bell": SoundChoice.named("Tink.aiff").storedValue],
                                    forProjectID: fixture.project.id),
            .applied
        )

        let scopes = SoundResolution.scopes(for: .session(fixture.session.id))
        XCTAssertEqual(scopes.count, 3)
        XCTAssertEqual(scopes[0].all, .named("Purr.aiff"))
        XCTAssertEqual(scopes[1].all, .silent)
        XCTAssertEqual(scopes[1].kinds[.bell], .named("Tink.aiff"))
        XCTAssertEqual(scopes[2], SoundResolution.appScope())
    }

    /// A standalone terminal resolves through its own record, then the project that persists it,
    /// then the app.
    func testAStandaloneTerminalResolvesThroughItsProjectThenTheApp() throws {
        let fixture = try makeFixture()
        let store = ProjectStore.shared

        XCTAssertEqual(
            store.setSoundOverrides(["all": SoundChoice.silent.storedValue],
                                    forProjectID: fixture.project.id),
            .applied
        )
        XCTAssertEqual(
            SoundResolution.scopes(for: .terminal(fixture.terminal.id)).count,
            2,
            "the terminal itself says nothing yet"
        )

        XCTAssertEqual(
            store.setSoundOverrides(["all": SoundChoice.named("Glass.aiff").storedValue],
                                    forTerminalID: fixture.terminal.id),
            .applied
        )

        let scopes = SoundResolution.scopes(for: .terminal(fixture.terminal.id))
        XCTAssertEqual(scopes.count, 3)
        XCTAssertEqual(scopes[0].all, .named("Glass.aiff"))
        XCTAssertEqual(scopes[1].all, .silent)
        XCTAssertEqual(scopes[2], SoundResolution.appScope())
    }

    /// A key this build does not know is not an answer to anything it asks — and it does not
    /// stop the keys beside it from being read.
    func testAnUnknownKeyIsNotAnAnswerButDoesNotBlockTheOthers() throws {
        let fixture = try makeFixture()
        XCTAssertEqual(
            ProjectStore.shared.setSoundOverrides(
                [
                    "alert.somethingLater": "file:Hero.aiff",
                    "alert.blocked": "file:Purr.aiff",
                    "all": "silent"
                ],
                forSessionID: fixture.session.id
            ),
            .applied
        )

        let scope = try XCTUnwrap(SoundResolution.scopes(for: .session(fixture.session.id)).first)
        XCTAssertEqual(scope.events, [.alertBlocked: .named("Purr.aiff")])
        XCTAssertEqual(scope.all, .silent)
    }

    /// Attribution turns on for the scope that asked for it, not for the app alone.
    func testARecordCanClaimOtherProgramAttribution() throws {
        let fixture = try makeFixture()
        XCTAssertEqual(
            ProjectStore.shared.setSoundOverrides(
                ["bell.otherProgram": SoundChoice.named("Tink.aiff").storedValue],
                forProjectID: fixture.project.id
            ),
            .applied
        )

        XCTAssertTrue(
            SoundResolution.attributesOtherPrograms(
                through: SoundResolution.scopes(for: .session(fixture.session.id))
            )
        )
        XCTAssertFalse(
            SoundResolution.attributesOtherPrograms(through: [SoundResolution.appScope()]),
            "nobody else pays for it"
        )
    }

    // MARK: - Which Record Rang

    /// The bell's owner, derived from the terminal identity it already carries: an agent's
    /// terminal and the shell under it belong to the conversation, a standalone terminal to its
    /// own record, and an ephemeral one to nothing at all.
    func testTheOwnerFollowsTheTerminalIdentity() {
        let sessionID = SessionID()
        let terminalID = TerminalID()

        XCTAssertEqual(SoundOwner(.agentSession(sessionID)), .session(sessionID))
        XCTAssertEqual(SoundOwner(.sessionShell(sessionID)), .session(sessionID))
        XCTAssertEqual(SoundOwner(.projectTerminal(terminalID)), .terminal(terminalID))
        XCTAssertNil(SoundOwner(.ephemeral(UUID())))
    }

    // MARK: - Private Methods

    private struct Fixture {
        let project: Project
        let session: AgentSession
        let terminal: ProjectTerminal
    }

    /// A real project, chat and standalone terminal in the shared store, removed with the test.
    private func makeFixture() throws -> Fixture {
        let store = ProjectStore.shared
        let project = try XCTUnwrap(store.addProject(
            folderURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("sound-scope-\(UUID().uuidString)", isDirectory: true)
        ))
        addTeardownBlock { MainActor.assumeIsolated { _ = store.removeProject(id: project.id) } }

        let session = try XCTUnwrap(store.addSession(to: project.id, kind: .claude))
        let terminal = try XCTUnwrap(store.addTerminal(to: project.id))
        return Fixture(
            project: try XCTUnwrap(store.project(withID: project.id)),
            session: session,
            terminal: terminal
        )
    }
}
