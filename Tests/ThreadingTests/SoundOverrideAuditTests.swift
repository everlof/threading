import XCTest
@testable import Threading

/// The Custom sounds list — the answer to "why is this chat making that noise", two weeks after
/// somebody stopped remembering that they set it.
///
/// The property worth pinning hardest is that the list is **built from the store on every
/// reading**. A cached list is how a surface whose whole job is describing the records ends up
/// describing records that no longer say that, and the failure is silent: a stale row still
/// names a real chat and offers a Reset that clears nothing.
@MainActor
final class SoundOverrideAuditTests: HostedStoreTestCase {

    // MARK: - Fixtures

    private struct Fixture {
        let project: Project
        let session: AgentSession
        let terminal: ProjectTerminal
    }

    private func makeFixture() throws -> Fixture {
        let store = ProjectStore.shared
        let project = try XCTUnwrap(store.addProject(
            folderURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("sound-audit-\(UUID().uuidString)", isDirectory: true)
        ))
        addTeardownBlock { MainActor.assumeIsolated { _ = store.removeProject(id: project.id) } }

        let session = try XCTUnwrap(store.addSession(to: project.id, kind: .claude))
        let terminal = try XCTUnwrap(store.addTerminal(to: project.id))
        return Fixture(project: project, session: session, terminal: terminal)
    }

    /// Only this fixture's rows: the developer's own store is shared with every other test in
    /// the host, and a project they happen to have painted is not this test's business.
    private func entries(for fixture: Fixture) -> [SoundOverrideAudit.Entry] {
        let mine: Set<SoundScope> = [
            .project(fixture.project.id),
            .session(fixture.session.id),
            .terminal(fixture.terminal.id)
        ]
        return SoundOverrideAudit.entries().filter { mine.contains($0.scope) }
    }

    // MARK: - Appearing and Disappearing

    /// A record gaining an override appears; resetting it takes it away again. Both readings
    /// come from the store, which is why the second needs no invalidation.
    func testARecordAppearsWhenItGainsAnOverrideAndGoesOnReset() throws {
        let fixture = try makeFixture()
        XCTAssertTrue(entries(for: fixture).isEmpty)

        XCTAssertEqual(
            ProjectStore.shared.setSoundOverrides(
                ["all": SoundChoice.named("Submarine.aiff").storedValue],
                forSessionID: fixture.session.id
            ),
            .applied
        )

        let listed = entries(for: fixture)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.scope, .session(fixture.session.id))
        XCTAssertEqual(listed.first?.summary, "Submarine")

        SoundScope.session(fixture.session.id).resetAll()
        XCTAssertTrue(entries(for: fixture).isEmpty)
    }

    /// All three record kinds are listed, in the sidebar's own order: the checkout, then its
    /// chats, then its terminals.
    func testEveryRecordKindIsListedInTheSidebarsOrder() throws {
        let fixture = try makeFixture()
        let store = ProjectStore.shared
        for result in [
            store.setSoundOverrides(["all": SoundChoice.silent.storedValue],
                                    forProjectID: fixture.project.id),
            store.setSoundOverrides(["all": SoundChoice.silent.storedValue],
                                    forSessionID: fixture.session.id),
            store.setSoundOverrides(["all": SoundChoice.silent.storedValue],
                                    forTerminalID: fixture.terminal.id)
        ] {
            XCTAssertEqual(result, .applied)
        }

        XCTAssertEqual(entries(for: fixture).map(\.scope), [
            .project(fixture.project.id),
            .session(fixture.session.id),
            .terminal(fixture.terminal.id)
        ])
    }

    /// The list is a reading rather than a cache: nothing is told to refresh between these two
    /// calls, and the second still disagrees with the first.
    func testTheListIsReadFromTheStoreRatherThanHeld() throws {
        let fixture = try makeFixture()
        XCTAssertEqual(
            ProjectStore.shared.setSoundOverrides(
                ["all": SoundChoice.silent.storedValue],
                forProjectID: fixture.project.id
            ),
            .applied
        )
        XCTAssertEqual(entries(for: fixture).first?.summary, "Off")

        XCTAssertEqual(
            ProjectStore.shared.setSoundOverrides(
                ["all": SoundChoice.named("Glass.aiff").storedValue],
                forProjectID: fixture.project.id
            ),
            .applied
        )
        XCTAssertEqual(entries(for: fixture).first?.summary, "Glass")
    }

    // MARK: - What It Resolves To

    /// The base coat names itself, kind entries name their kind, and event entries are counted.
    func testTheSummarySaysWhatTheRecordStores() {
        XCTAssertEqual(
            SoundOverrideAudit.summary(of: ["all": SoundChoice.named("Submarine.aiff").storedValue]),
            "Submarine"
        )
        XCTAssertEqual(
            SoundOverrideAudit.summary(of: ["bell": SoundChoice.named("Glass.aiff").storedValue]),
            "Bells: Glass"
        )
        XCTAssertEqual(
            SoundOverrideAudit.summary(of: [
                "bell.launch": SoundChoice.silent.storedValue,
                "bell.agentVisible": SoundChoice.silent.storedValue,
                "alert.blocked": SoundChoice.silent.storedValue
            ]),
            "3 events"
        )
        XCTAssertEqual(
            SoundOverrideAudit.summary(of: ["bell.launch": SoundChoice.silent.storedValue]),
            "1 event",
            "one is not 1 events"
        )
        XCTAssertEqual(
            SoundOverrideAudit.summary(of: [
                "all": SoundChoice.silent.storedValue,
                "bell.launch": SoundChoice.system.storedValue
            ]),
            "Off · 1 event"
        )
    }

    /// Nothing stored is nothing to list — the section's empty state, from the same function.
    func testARecordWithNothingStoredIsNotListed() {
        XCTAssertNil(SoundOverrideAudit.summary(of: nil))
        XCTAssertNil(SoundOverrideAudit.summary(of: [:]))
    }

    /// A map holding only keys this build has never heard of still counts: the record says
    /// *something*, and dropping it would make the one surface that answers "what is overriding"
    /// quietly incomplete.
    func testAnEntryFromALaterBuildIsStillListed() {
        XCTAssertEqual(
            SoundOverrideAudit.summary(of: ["alert.somethingLater": "file:Hero.aiff"]),
            "Set by a later version"
        )
    }

    // MARK: - The Row Affordance

    /// The tooltip line exists only where there is something to explain: a row carrying nothing
    /// of its own is decorated with nothing, because configuration is not status.
    func testTheToolTipLineNamesTheSoundAndIsAbsentOtherwise() {
        XCTAssertEqual(
            SoundOverrideAudit.toolTipLine(
                for: .session(SessionID()),
                overrides: ["all": SoundChoice.named("Submarine.aiff").storedValue]
            ),
            "Sounds: Submarine (this chat)"
        )
        XCTAssertEqual(
            SoundOverrideAudit.toolTipLine(
                for: .project(ProjectID()),
                overrides: ["all": SoundChoice.silent.storedValue]
            ),
            "Sounds: Off (this project)"
        )
        XCTAssertEqual(
            SoundOverrideAudit.toolTipLine(
                for: .terminal(TerminalID()),
                overrides: ["all": SoundChoice.silent.storedValue]
            ),
            "Sounds: Off (this terminal)"
        )
        XCTAssertNil(
            SoundOverrideAudit.toolTipLine(for: .session(SessionID()), overrides: nil)
        )
    }
}
