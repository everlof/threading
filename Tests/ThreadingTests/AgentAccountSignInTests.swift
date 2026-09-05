import AppKit
import XCTest
@testable import Threading

/// The sign-in link a provider login prints, and what the setup card does with it.
///
/// The fixtures below are the real bytes each CLI writes when its output is a pipe, taken from a
/// login started against a scratch config home. They are the whole reason this feature can exist:
/// Claude Code prints a *different* URL from the one it hands the browser — its printed one ends
/// on a page showing a code — while Codex prints the same loopback redirect it opened, which
/// completes on its own. A change in either shape should fail here rather than in somebody's
/// half-finished login.
final class AgentAccountSignInScannerTests: XCTestCase {

    // MARK: - Fixtures

    private enum Fixture {
        /// `claude auth login`, stdout, stdin and stdout both pipes.
        static let claude = """
            Opening browser to sign in\u{2026}
            If the browser didn't open, visit: \(claudeURL)
            Paste code here if prompted >
            """

        static let claudeURL = "https://claude.com/cai/oauth/authorize?code=true"
            + "&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&response_type=code"
            + "&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback"
            + "&scope=org%3Acreate_api_key+user%3Aprofile&code_challenge=2rBs_ZCH_8R2ZGZFv5GEbKV9O"
            + "&code_challenge_method=S256&state=P1bhsNKBpbv78wuI2BrpJZ9tnICmoy_T2tYfd401FGI"

        /// `codex login`, stderr. Note the first line: a loopback *server* address, not a link.
        static let codex = """
            Starting local login server on http://localhost:1455.
            If your browser did not open, navigate to this URL to authenticate:

            \(codexURL)

            On a remote or headless machine? Use `codex login --device-auth` instead.
            """

        static let codexURL = "https://auth.openai.com/oauth/authorize?response_type=code"
            + "&client_id=app_EMoamEEZ73f0CkXaXp7hrann"
            + "&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback"
            + "&scope=openid%20profile%20email&code_challenge=y33UiBEnfMjn6S18pOfygrZeDG2lgl08"
            + "&code_challenge_method=S256&state=aW7XMXDMNUquT_uYWgA2J&originator=codex_cli_rs"
    }

    // MARK: - Tests

    func testFindsTheLinkClaudeCodePrintsWhenItsOwnBrowserDidNotOpen() {
        var scanner = AgentAccountSignInScanner()

        let found = scanner.consume(Fixture.claude)

        XCTAssertEqual(found?.absoluteString, Fixture.claudeURL)
        XCTAssertEqual(scanner.url?.absoluteString, Fixture.claudeURL)
    }

    /// Codex names its own loopback server one line above the link. Offering that address would
    /// send somebody to a callback endpoint with nothing to callback, so only `https` is a link.
    func testFindsCodexsLinkAndNotTheLoopbackServerItAnnouncesFirst() {
        var scanner = AgentAccountSignInScanner()

        let found = scanner.consume(Fixture.codex)

        XCTAssertEqual(found?.absoluteString, Fixture.codexURL)
    }

    /// A 400-character URL does not arrive in one `read(2)`; a pipe hands over whatever is there.
    func testRecoversALinkSplitAcrossTwoReads() {
        var scanner = AgentAccountSignInScanner()
        let split = Fixture.claude.index(
            Fixture.claude.startIndex,
            offsetBy: Fixture.claude.count / 2
        )

        let first = scanner.consume(String(Fixture.claude[..<split]))
        let second = scanner.consume(String(Fixture.claude[split...]))

        XCTAssertNil(first, "half a URL is not a URL somebody can open")
        XCTAssertEqual(second?.absoluteString, Fixture.claudeURL)
    }

    /// Even a scheme can land on a read boundary, so the carry has to survive a burst that
    /// contains nothing else of interest.
    func testRecoversALinkWhoseSchemeLandsOnTheBoundary() {
        var scanner = AgentAccountSignInScanner()

        XCTAssertNil(scanner.consume("visit: htt"))
        XCTAssertEqual(
            scanner.consume("ps://claude.com/cai/oauth/authorize?code=true\n")?.absoluteString,
            "https://claude.com/cai/oauth/authorize?code=true"
        )
    }

    /// The login keeps printing after the link: a rejected code says so, and a second attempt
    /// prints a second authorize URL. The first one is still the one the person is looking at.
    func testKeepsTheFirstLinkAndStopsLookingAfterIt() {
        var scanner = AgentAccountSignInScanner()
        _ = scanner.consume(Fixture.claude)

        let later = scanner.consume(
            "Invalid code. Please make sure the full code was copied.\nhttps://example.test/other\n"
        )

        XCTAssertNil(later)
        XCTAssertEqual(scanner.url?.absoluteString, Fixture.claudeURL)
    }

    func testIgnoresABareSchemeAndDropsTheSentencesOwnPunctuation() {
        var scanner = AgentAccountSignInScanner()

        let found = scanner.consume("see https:// or, better, https://claude.com/setup.\n")

        XCTAssertEqual(found?.absoluteString, "https://claude.com/setup")
    }

    /// The bound that matters is the amount examined. A login that prints megabytes without ever
    /// terminating a candidate must not turn the carry into an accumulating copy of its output.
    func testTheCarryStaysBoundedWhenNoCandidateEverTerminates() {
        var scanner = AgentAccountSignInScanner()
        let unterminated = "https://" + String(repeating: "a", count: 4_096)

        for _ in 0..<32 {
            XCTAssertNil(scanner.consume(unterminated))
            XCTAssertLessThanOrEqual(
                scanner.carriedCharactersForTesting,
                AgentAccountSignInDefaults.maximumCarryCharacters
            )
        }
        // Dropping an over-long candidate must not deafen the scanner to the real link.
        XCTAssertEqual(
            scanner.consume("\nvisit: \(Fixture.codexURL)\n")?.absoluteString,
            Fixture.codexURL
        )
    }

    func testEachLoginAdapterStatesWhetherItsLinkNeedsACodePastedBack() {
        XCTAssertTrue(AgentAccountSetupProvider.claude.acceptsPastedSignInCode)
        XCTAssertFalse(AgentAccountSetupProvider.codex.acceptsPastedSignInCode)
    }
}

// MARK: - Setup Card

/// What the running card offers once the link exists, in the container it ships in.
@MainActor
final class AccountSetupSignInLinkTests: XCTestCase {

    private let link = URL(string: "https://claude.com/cai/oauth/authorize?code=true&state=abc")!

    func testShowsTheLinkAndItsTwoActionsOnceTheAgentHasPrintedIt() {
        let controller = card(prompt: AgentAccountSignInPrompt(
            url: link,
            acceptsPastedCode: true
        ))
        let views = descendants(of: controller.view)

        let shown = views
            .compactMap { $0 as? NSTextField }
            .first { $0.accessibilityIdentifier() == "account-setup.sign-in-link" }
        XCTAssertEqual(shown?.stringValue, link.absoluteString)
        XCTAssertEqual(shown?.isSelectable, true, "the whole link has to be selectable to copy")
        XCTAssertEqual(identifiers(in: views).contains("account-setup.copy-link"), true)
        XCTAssertEqual(identifiers(in: views).contains("account-setup.open-link"), true)
        XCTAssertFalse(
            identifiers(in: views).contains("account-setup.link-pending"),
            "the waiting line belongs to the moment before the link arrives"
        )
    }

    /// The row exists before the URL does, so the Cancel button does not move under the pointer
    /// the moment the CLI prints.
    func testSaysTheLinkHasNotArrivedYetRatherThanShowingNothing() {
        let controller = card(prompt: nil)
        let views = descendants(of: controller.view)

        XCTAssertTrue(identifiers(in: views).contains("account-setup.link-pending"))
        XCTAssertFalse(identifiers(in: views).contains("account-setup.sign-in-link"))
        XCTAssertFalse(identifiers(in: views).contains("account-setup.copy-link"))
    }

    func testCopyGoesThroughTheSeamSoASuiteNeverWritesThePasteboard() throws {
        let controller = card(prompt: AgentAccountSignInPrompt(
            url: link,
            acceptsPastedCode: true
        ))
        var copied: [URL] = []
        controller.onCopySignInLink = { copied.append($0) }

        let copy = try XCTUnwrap(
            descendants(of: controller.view)
                .compactMap { $0 as? ThemedButton }
                .first { $0.accessibilityIdentifier() == "account-setup.copy-link" }
        )
        // `ThemedButton` routes its own press; `NSControl.performClick(_:)` is not that path.
        copy.performClick()

        XCTAssertEqual(copied, [link])
    }

    /// Only the provider whose printed link ends on a page displaying a code gets somewhere to
    /// put one. Codex's link completes by itself, so a field there would be a question with no
    /// answer.
    func testOnlyAProviderThatReadsACodeBackOffersTheField() {
        let claude = card(
            provider: .claude,
            prompt: AgentAccountSignInPrompt(url: link, acceptsPastedCode: true)
        )
        let codex = card(
            provider: .codex,
            prompt: AgentAccountSignInPrompt(url: link, acceptsPastedCode: false)
        )

        XCTAssertTrue(identifiers(in: descendants(of: claude.view)).contains("account-setup.code"))
        XCTAssertTrue(
            identifiers(in: descendants(of: claude.view)).contains("account-setup.submit-code")
        )
        XCTAssertFalse(identifiers(in: descendants(of: codex.view)).contains("account-setup.code"))
    }

    /// A card whose naming state enables Sign In only for a non-empty name must not have that
    /// rule fired by the code field, which belongs to a different state entirely.
    func testTheCodeFieldDoesNotDriveTheNamingStatesButton() {
        let controller = card(prompt: AgentAccountSignInPrompt(
            url: link,
            acceptsPastedCode: true
        ))
        let field = descendants(of: controller.view)
            .compactMap { $0 as? ThemedTextField }
            .first { $0.accessibilityIdentifier() == "account-setup.code" }
        XCTAssertNotNil(field)

        field?.stringValue = "code-from-the-page"
        controller.controlTextDidChange(Notification(
            name: NSControl.textDidChangeNotification,
            object: field
        ))

        // Nothing to assert about a button that is not on screen; the contract is that this does
        // not trap or reach into the other state's fields.
        XCTAssertEqual(field?.stringValue, "code-from-the-page")
    }

    // MARK: - Helpers

    private func card(
        provider: AgentAccountSetupProvider = .claude,
        prompt: AgentAccountSignInPrompt?
    ) -> AccountSetupCardViewController {
        let context = AgentAccountSetupContext(
            provider: provider,
            displayName: "Consulting",
            handle: .named("\(provider.rawValue)-consulting"),
            configPath: "/Users/dev/.\(provider.rawValue)-consulting",
            isReconnect: false
        )
        let controller = AccountSetupCardViewController(
            coordinator: AgentAccountSetupCoordinator(
                initialState: .running(context, prompt: prompt)
            )
        )
        _ = controller.view
        return controller
    }

    private func identifiers(in views: [NSView]) -> Set<String> {
        Set(views.map { $0.accessibilityIdentifier() }.filter { !$0.isEmpty })
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}
