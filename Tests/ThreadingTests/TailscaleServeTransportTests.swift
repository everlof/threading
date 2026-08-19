import XCTest
@testable import Threading

/// Tailscale Serve's readiness is finer-grained than its state: the readiness steps advance while
/// the state sits on `.starting`, so the settings page can only stay truthful if readiness changes
/// are announced on their own. The Remote Access pane froze on "Checked when Remote Access turns
/// on." for the whole connection attempt before this seam existed.
///
/// Serve is the browser convenience now, not a way in — the tailnet door is a listener on this
/// Mac's own tailnet address — so what is proved here is the CLI half: what a `tailscale status`
/// run says about this Mac, and how Serve's own failures are classified.
///
/// The executable locator is injected so these tests do not depend on whether the machine
/// running them has the Tailscale CLI installed — and never spawn it if it does.
@MainActor
final class TailscaleServeTransportTests: XCTestCase {

    func testReadinessChangesAreAnnouncedIndependentlyOfState() {
        let transport = TailscaleServeTransport(locateExecutable: { nil })
        var announced: [TailscaleReadiness] = []
        transport.onReadinessChange = { announced.append(transport.readiness) }

        transport.start(port: 4321) { _ in }

        XCTAssertEqual(announced, [.checking, .actionRequired(.notInstalled, actionURL: nil)])
        XCTAssertEqual(
            transport.state,
            .unavailable(TailscaleReadinessIssue.notInstalled.message)
        )
    }

    func testTheCheckBeginsWithTheStartRequest() {
        let transport = TailscaleServeTransport(locateExecutable: { nil })

        transport.start(port: 4321) { _ in }

        // Never `.notChecked` once Remote Access asked for the transport: that is the state
        // whose copy claims the check happens when the feature turns on.
        XCTAssertEqual(transport.readiness, .actionRequired(.notInstalled, actionURL: nil))
    }

    func testStopResetsReadinessAndAnnouncesIt() {
        let transport = TailscaleServeTransport(locateExecutable: { nil })
        transport.start(port: 4321) { _ in }
        var announced: [TailscaleReadiness] = []
        transport.onReadinessChange = { announced.append(transport.readiness) }

        transport.stop()

        XCTAssertEqual(announced, [.notChecked])
        XCTAssertEqual(transport.state, .stopped)
    }

    /// The probe never reports on Serve. A machine with no `tailscale` binary is a fact about
    /// this Mac, not a claim that the browser convenience failed to publish.
    func testAMissingCLIIsAFactAboutThisMacAndNotAServeFailure() {
        let transport = TailscaleServeTransport(locateExecutable: { nil })

        transport.refreshHostFacts()

        XCTAssertEqual(transport.hostFacts, TailscaleHostFacts(state: .notInstalled, magicDNSName: nil))
        XCTAssertEqual(transport.readiness, .notChecked, "a probe reported Serve unavailable")
        XCTAssertEqual(transport.state, .stopped)
    }

    // MARK: - What `tailscale status` says about this Mac

    func testARunningTailnetYieldsItsStateAndItsMagicDNSName() throws {
        let json = """
        {"BackendState": "Running", "Self": {"DNSName": "mac-studio.tail1234.ts.net."}}
        """

        let facts = TailscaleServeTransport.hostFacts(exitStatus: 0, output: Data(json.utf8))

        XCTAssertEqual(facts.state, .running)
        XCTAssertEqual(
            facts.magicDNSName,
            "mac-studio.tail1234.ts.net",
            "the trailing root label is not a host any URL, certificate or person writes"
        )
        XCTAssertNil(facts.issue, "a running tailnet is not an issue to show anybody")
    }

    func testEachBackendStateBecomesTheIssueTheDoorReports() throws {
        let cases: [(String, TailscaleHostFacts.State, TailscaleReadinessIssue?)] = [
            ("NeedsLogin", .signedOut, .signedOut),
            ("NeedsMachineAuth", .signedOut, .signedOut),
            ("Stopped", .stopped, .stopped),
            ("Starting", .stopped, .stopped),
            ("NoMap", .stopped, .stopped),
            ("Somethingelse", .unknown, nil)
        ]
        for (backend, state, issue) in cases {
            let json = "{\"BackendState\": \"\(backend)\"}"
            let facts = TailscaleServeTransport.hostFacts(exitStatus: 0, output: Data(json.utf8))
            XCTAssertEqual(facts.state, state, backend)
            XCTAssertEqual(facts.issue, issue, backend)
            XCTAssertNil(facts.magicDNSName, backend)
        }
    }

    /// The CLI exits non-zero and says so in words often enough to be worth reading, and stays
    /// `.unknown` when it does not. `.unknown` is never an accusation: the door itself decides
    /// whether anything is bound.
    func testAFailedProbeReadsItsWordsAndOtherwiseStaysUnknown() {
        XCTAssertEqual(
            TailscaleServeTransport.hostFacts(
                exitStatus: 1,
                output: Data("Logged out.".utf8)
            ).state,
            .signedOut
        )
        XCTAssertEqual(
            TailscaleServeTransport.hostFacts(
                exitStatus: 1,
                output: Data("Tailscale is stopped.".utf8)
            ).state,
            .stopped
        )
        XCTAssertEqual(
            TailscaleServeTransport.hostFacts(exitStatus: 1, output: Data("boom".utf8)),
            .unknown
        )
        XCTAssertEqual(
            TailscaleServeTransport.hostFacts(exitStatus: 0, output: Data("not json".utf8)),
            .unknown
        )
    }

    // MARK: - Serve failure classification

    /// The CLI does not fail when the tailnet has not approved Serve: it prints the approval
    /// URL and polls until an admin visits it, so this output reaches classification through
    /// the command deadline killing the poll — with the timeout marker appended.
    func testServeApprovalOutputYieldsTheIssueAndItsURL() {
        let output = """
        Serve is not enabled on your tailnet.
        To enable, visit:

        \thttps://login.tailscale.com/f/serve?node=nTESTNODECNTRL

        Threading command timeout
        """

        let failure = TailscaleServeTransport.serveFailureIssue(from: Data(output.utf8))

        XCTAssertEqual(failure.issue, .serveNotEnabled)
        XCTAssertEqual(
            failure.actionURL,
            URL(string: "https://login.tailscale.com/f/serve?node=nTESTNODECNTRL")
        )
    }

    /// Regression: every approval URL contains the substring "https", which the certificate
    /// wording check used to match first — reporting the HTTPS-certificates issue and
    /// discarding the URL that would have fixed the real one.
    func testAnApprovalURLIsNeverMistakenForTheCertificateIssue() {
        let output = "To enable, visit: https://login.tailscale.com/f/serve?node=nTESTNODECNTRL"

        let failure = TailscaleServeTransport.serveFailureIssue(from: Data(output.utf8))

        XCTAssertEqual(failure.issue, .serveNotEnabled)
        XCTAssertNotNil(failure.actionURL)
    }

    func testAnHTTPSApprovalURLYieldsTheCertificateIssueWithTheURL() {
        let output = "To enable HTTPS, visit: https://login.tailscale.com/f/https?node=nTESTNODECNTRL"

        let failure = TailscaleServeTransport.serveFailureIssue(from: Data(output.utf8))

        XCTAssertEqual(failure.issue, .httpsRequired)
        XCTAssertEqual(
            failure.actionURL,
            URL(string: "https://login.tailscale.com/f/https?node=nTESTNODECNTRL")
        )
    }

    func testCertificateWordingWithoutAURLStillYieldsTheCertificateIssue() {
        let output = "error: certificate is not provisioned for this domain"

        let failure = TailscaleServeTransport.serveFailureIssue(from: Data(output.utf8))

        XCTAssertEqual(failure.issue, .httpsRequired)
        XCTAssertNil(failure.actionURL)
    }

    /// Only the admin console is ever offered to open: an arbitrary URL in command output
    /// must not become a button that steers the user's browser.
    func testOnlyTailscaleAdminURLsAreExtracted() {
        let output = "Something failed, see https://example.com/phishing for details"

        let failure = TailscaleServeTransport.serveFailureIssue(from: Data(output.utf8))

        XCTAssertNil(failure.actionURL)
        // "https" appears in the URL, so wording classification still lands on certificates —
        // but crucially with nothing to open.
        XCTAssertEqual(failure.issue, .httpsRequired)
    }

    func testUnrecognisedServeOutputStaysTheGenericFailure() {
        let failure = TailscaleServeTransport.serveFailureIssue(
            from: Data("something exploded".utf8)
        )

        XCTAssertEqual(failure.issue, .serveFailed)
        XCTAssertNil(failure.actionURL)
    }
}
