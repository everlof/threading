import AppKit
import XCTest
@testable import Threading

/// Which screen a Claude terminal session draws its interface on, and the two places Threading
/// can answer for it: an app-wide default for new sessions and one conversation's override.
///
/// The distinction under test is the same one Remote Control's suite guards, turned the other
/// way up. There, *off* and *no opinion* had to stay apart because writing `false` would
/// override a `/config` the user set. Here the shipped default deliberately **is** a stated
/// value — this app's terminal, and the iPhone mirroring it, can only scroll what lands in the
/// retained buffer — so what has to stay reachable is the third state that hands the question
/// back, including to the machine-local record the CLI writes for itself.
@MainActor
final class ClaudeTerminalRendererTests: XCTestCase {

    private var previousDefault: ClaudeTerminalRenderer = .terminalScrollback

    override func setUp() async throws {
        try await super.setUp()
        previousDefault = AppSettings.shared.claudeTerminalRenderer
        addTeardownBlock { @MainActor [previousDefault] in
            AppSettings.shared.claudeTerminalRenderer = previousDefault
        }
    }

    // MARK: - Resolution

    func testTheShippedDefaultKeepsTheTranscriptInThisAppsScrollback() {
        XCTAssertEqual(ClaudeTerminalRenderer.terminalScrollback.startupValue, false)
        XCTAssertEqual(
            AppSettings(defaults: scratchDefaults()).claudeTerminalRenderer,
            .terminalScrollback,
            "a machine that has never chosen must still get the terminal's own scrolling"
        )
    }

    func testFollowingClaudeDecidesNothing() {
        XCTAssertNil(ClaudeTerminalRenderer.followClaude.startupValue)
        XCTAssertNil(
            AgentLauncher.terminalRendererAtStartup(
                for: AgentSession(kind: .claude, title: "Chat"),
                appDefault: .followClaude
            )
        )
    }

    /// The case the per-chat override exists for, both ways round: one conversation on Claude's
    /// own renderer while everything else stays in the terminal's scrollback, and one pinned to
    /// the terminal while the app-wide answer defers.
    func testOneChatCanDisagreeWithTheAppDefaultInEitherDirection() {
        var loud = AgentSession(kind: .claude, title: "Loud")
        XCTAssertTrue(loud.setClaudeFullscreenRenderer(true))
        XCTAssertEqual(
            AgentLauncher.terminalRendererAtStartup(for: loud, appDefault: .terminalScrollback),
            true
        )

        var quiet = AgentSession(kind: .claude, title: "Quiet")
        XCTAssertTrue(quiet.setClaudeFullscreenRenderer(false))
        XCTAssertEqual(
            AgentLauncher.terminalRendererAtStartup(for: quiet, appDefault: .followClaude),
            false
        )

        XCTAssertTrue(quiet.setClaudeFullscreenRenderer(nil))
        XCTAssertNil(
            AgentLauncher.terminalRendererAtStartup(for: quiet, appDefault: .followClaude),
            "clearing a chat's choice returns it to the app-wide answer, deferral included"
        )
    }

    /// Codex reaches the same screen through `--no-alt-screen` on every launch, so it has no
    /// choice to record; the rest have no measured equivalent at all.
    func testOnlyClaudeIsOfferedTheChoice() {
        for kind in AgentKind.allCases {
            XCTAssertEqual(
                kind.supports(.selectableTerminalRenderer),
                kind == .claude,
                "\(kind) renderer choice contract drifted"
            )
            var session = AgentSession(kind: kind, title: "Chat")
            XCTAssertEqual(
                session.setClaudeFullscreenRenderer(true),
                kind == .claude,
                "\(kind) must refuse a choice its launch cannot state"
            )
        }
    }

    // MARK: - Persistence

    func testTheChoiceSurvivesAnEncodeDecodeRound() throws {
        for value in [true, false] {
            var session = AgentSession(kind: .claude, title: "Chat")
            XCTAssertTrue(session.setClaudeFullscreenRenderer(value))

            let decoded = try JSONDecoder().decode(
                AgentSession.self,
                from: try JSONEncoder().encode(session)
            )
            XCTAssertEqual(decoded.fullscreenRenderer, value)
        }
    }

    /// A record written before this existed has no opinion, rather than a screen it never asked
    /// for. That is what lets the app-wide default reach conversations that already exist.
    func testARecordWrittenBeforeThisFeatureDecodesAsNoChoice() throws {
        let session = AgentSession(kind: .claude, title: "Chat")
        let data = try JSONEncoder().encode(session)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNil(json["fullscreenRenderer"], "An absent choice must not be encoded at all")
        XCTAssertNil(
            try JSONDecoder().decode(AgentSession.self, from: data).fullscreenRenderer
        )
    }

    func testARecordCarryingTheChoiceForAnotherRuntimeIsRefused() throws {
        let data = try JSONEncoder().encode(AgentSession(kind: .codex, title: "Codex"))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["fullscreenRenderer"] = true

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                AgentSession.self,
                from: try JSONSerialization.data(withJSONObject: json)
            ),
            "a runtime with no renderer to choose must not decode one"
        )
    }

    /// A side chat is the same conversation continued, so it opens on the screen its parent was
    /// using rather than falling back to the app-wide answer mid-thread.
    func testAForkKeepsTheScreenItsParentChose() throws {
        var parent = AgentSession(kind: .claude, title: "Parent")
        XCTAssertTrue(parent.setClaudeFullscreenRenderer(true))

        let child = try XCTUnwrap(parent.forkedConfiguration)
        guard case .claude(_, let fullscreenRenderer, _, _) = child else {
            return XCTFail("a Claude fork must stay a Claude configuration")
        }
        XCTAssertEqual(fullscreenRenderer, true)
    }

    // MARK: - Session Menu

    func testTheInterfaceFoldOffersInheritAndBothScreens() throws {
        AppSettings.shared.claudeTerminalRenderer = .terminalScrollback

        XCTAssertEqual(
            try scrollingSubmenu(for: AgentSession(kind: .claude, title: "Chat"))
                .compactMap(\.item).map(\.title),
            [
                "Use Default (Terminal Scrolling)",
                "Terminal's Own Scrolling",
                "Claude's Fullscreen Renderer"
            ]
        )
    }

    /// Two of the three app-wide answers can be named outright, which is the difference from
    /// Remote Control's inherit row: only "follow" hands the question to a file this app cannot
    /// read, and only then does the row say so instead of naming a value.
    func testTheInheritItemNamesWhatItDefersTo() throws {
        let expected: [ClaudeTerminalRenderer: String] = [
            .terminalScrollback: "Use Default (Terminal Scrolling)",
            .claudeFullscreen: "Use Default (Fullscreen)",
            .followClaude: "Use Claude's Setting"
        ]
        for (value, title) in expected {
            AppSettings.shared.claudeTerminalRenderer = value
            XCTAssertEqual(
                try scrollingSubmenu(for: AgentSession(kind: .claude, title: "Chat"))
                    .compactMap(\.item).first?.title,
                title
            )
        }
    }

    /// The tick sits on the session's own state, including when that state is "no choice" — an
    /// override a user cannot see is one they cannot undo.
    func testTheTickMarksWhatTheSessionActuallyStored() throws {
        AppSettings.shared.claudeTerminalRenderer = .claudeFullscreen
        var session = AgentSession(kind: .claude, title: "Chat")

        XCTAssertEqual(try tickedTitles(for: session), ["Use Default (Fullscreen)"])

        XCTAssertTrue(session.setClaudeFullscreenRenderer(false))
        XCTAssertEqual(try tickedTitles(for: session), ["Terminal's Own Scrolling"])

        XCTAssertTrue(session.setClaudeFullscreenRenderer(true))
        XCTAssertEqual(try tickedTitles(for: session), ["Claude's Fullscreen Renderer"])
    }

    /// The surface switch and the screen choice are two marked selections, so they may not be
    /// flattened into one list: the Interface fold keeps them apart with a separator.
    func testTheInterfaceFoldKeepsTheTwoSelectionsApart() throws {
        let entries = try interfaceSubmenu(for: AgentSession(kind: .claude, title: "Chat"))

        XCTAssertEqual(entries.filter { !$0.isItem }.count, 1, "one separator, not two groups run together")
        XCTAssertEqual(
            entries.compactMap(\.item).last?.title,
            "Terminal Scrolling",
            "the screen choice is the fold's last item"
        )
    }

    func testCodexSessionsAreNotOfferedTheItem() throws {
        let entries = try interfaceSubmenu(for: AgentSession(kind: .codex, title: "Codex"))

        XCTAssertNil(entries.compactMap(\.item).first { $0.title == "Terminal Scrolling" })
        XCTAssertFalse(entries.isEmpty, "Codex still switches surfaces; only the screen is fixed")
    }

    // MARK: - Settings Page

    /// The row is built rather than assumed: a pop-up that never reached the page is
    /// indistinguishable from a setting nobody set.
    func testTheGeneralPageOffersEveryStateAndShowsTheCurrentOne() throws {
        AppSettings.shared.claudeTerminalRenderer = .claudeFullscreen

        let controller = GeneralPreferencesViewController()
        let host = laidOut(controller.view)
        let popUp = try XCTUnwrap(
            rendererPopUp(in: host),
            "the Claude Terminal row is not on the General page"
        )

        XCTAssertEqual(
            (0..<popUp.numberOfItems).compactMap { popUp.item(at: $0)?.title },
            ClaudeTerminalRenderer.allCases.map(\.settingsTitle)
        )
        XCTAssertEqual(
            popUp.selectedItem?.representedValue as? ClaudeTerminalRenderer,
            .claudeFullscreen
        )
        XCTAssertTrue(labels(in: host).contains("Scrolling in new Claude terminals"))
    }

    // MARK: - Helpers

    private func scratchDefaults() -> UserDefaults {
        let suite = "ClaudeTerminalRendererTests"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        return UserDefaults(suiteName: suite) ?? .standard
    }

    private func interfaceSubmenu(for session: AgentSession) throws -> [ThemedMenuEntry] {
        let entries = ProjectSidebarViewController().sessionActionEntries(for: session)
        let options = try XCTUnwrap(
            entries.compactMap(\.item)
                .first { $0.title == SessionActionMenuDefaults.sessionOptionsTitle }?
                .submenu,
            "the session menu has no Session Options fold"
        )
        return try XCTUnwrap(
            options.compactMap(\.item).first { $0.title == "Interface" }?.submenu,
            "Session Options has no Interface item"
        )
    }

    private func scrollingSubmenu(for session: AgentSession) throws -> [ThemedMenuEntry] {
        let item = try XCTUnwrap(
            try interfaceSubmenu(for: session)
                .compactMap(\.item).first { $0.title == "Terminal Scrolling" },
            "Interface has no Terminal Scrolling item"
        )
        return try XCTUnwrap(item.submenu, "the item has no submenu")
    }

    private func tickedTitles(for session: AgentSession) throws -> [String] {
        try scrollingSubmenu(for: session).compactMap(\.item).filter(\.isSelected).map(\.title)
    }

    /// Found by the states it offers rather than by position, so the row can move without this
    /// test caring and the Remote Control pop-up above it cannot be mistaken for it.
    private func rendererPopUp(in view: NSView) -> ThemedPopUp? {
        if let popUp = view as? ThemedPopUp,
           popUp.item(at: 0)?.title == ClaudeTerminalRenderer.terminalScrollback.settingsTitle {
            return popUp
        }
        for subview in view.subviews {
            if let found = rendererPopUp(in: subview) { return found }
        }
        return nil
    }

    private func labels(in view: NSView) -> [String] {
        var result = (view as? NSTextField).map { [$0.stringValue] } ?? []
        for subview in view.subviews {
            result.append(contentsOf: labels(in: subview))
        }
        return result
    }

    private func laidOut(_ view: NSView, width: CGFloat = SettingsUIDefaults.pageWidth) -> NSView {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 1400))
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
        host.layoutSubtreeIfNeeded()
        return host
    }
}
