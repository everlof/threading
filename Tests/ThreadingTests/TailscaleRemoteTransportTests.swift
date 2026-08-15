import XCTest
@testable import Threading

/// The Tailscale transport's readiness is finer-grained than its state: the readiness steps
/// advance while the state sits on `.starting`, so the settings page can only stay truthful if
/// readiness changes are announced on their own. The Remote Access pane froze on "Checked when
/// Remote Access turns on." for the whole connection attempt before this seam existed.
///
/// The executable locator is injected so these tests do not depend on whether the machine
/// running them has the Tailscale CLI installed — and never spawn it if it does.
@MainActor
final class TailscaleRemoteTransportTests: XCTestCase {

    func testReadinessChangesAreAnnouncedIndependentlyOfState() {
        let transport = TailscaleRemoteTransport(locateExecutable: { nil })
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
        let transport = TailscaleRemoteTransport(locateExecutable: { nil })

        transport.start(port: 4321) { _ in }

        // Never `.notChecked` once Remote Access asked for the transport: that is the state
        // whose copy claims the check happens when the feature turns on.
        XCTAssertEqual(transport.readiness, .actionRequired(.notInstalled, actionURL: nil))
    }

    func testStopResetsReadinessAndAnnouncesIt() {
        let transport = TailscaleRemoteTransport(locateExecutable: { nil })
        transport.start(port: 4321) { _ in }
        var announced: [TailscaleReadiness] = []
        transport.onReadinessChange = { announced.append(transport.readiness) }

        transport.stop()

        XCTAssertEqual(announced, [.notChecked])
        XCTAssertEqual(transport.state, .stopped)
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

        let failure = TailscaleRemoteTransport.serveFailureIssue(from: Data(output.utf8))

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

        let failure = TailscaleRemoteTransport.serveFailureIssue(from: Data(output.utf8))

        XCTAssertEqual(failure.issue, .serveNotEnabled)
        XCTAssertNotNil(failure.actionURL)
    }

    func testAnHTTPSApprovalURLYieldsTheCertificateIssueWithTheURL() {
        let output = "To enable HTTPS, visit: https://login.tailscale.com/f/https?node=nTESTNODECNTRL"

        let failure = TailscaleRemoteTransport.serveFailureIssue(from: Data(output.utf8))

        XCTAssertEqual(failure.issue, .httpsRequired)
        XCTAssertEqual(
            failure.actionURL,
            URL(string: "https://login.tailscale.com/f/https?node=nTESTNODECNTRL")
        )
    }

    func testCertificateWordingWithoutAURLStillYieldsTheCertificateIssue() {
        let output = "error: certificate is not provisioned for this domain"

        let failure = TailscaleRemoteTransport.serveFailureIssue(from: Data(output.utf8))

        XCTAssertEqual(failure.issue, .httpsRequired)
        XCTAssertNil(failure.actionURL)
    }

    /// Only the admin console is ever offered to open: an arbitrary URL in command output
    /// must not become a button that steers the user's browser.
    func testOnlyTailscaleAdminURLsAreExtracted() {
        let output = "Something failed, see https://example.com/phishing for details"

        let failure = TailscaleRemoteTransport.serveFailureIssue(from: Data(output.utf8))

        XCTAssertNil(failure.actionURL)
        // "https" appears in the URL, so wording classification still lands on certificates —
        // but crucially with nothing to open.
        XCTAssertEqual(failure.issue, .httpsRequired)
    }

    func testUnrecognisedServeOutputStaysTheGenericFailure() {
        let failure = TailscaleRemoteTransport.serveFailureIssue(
            from: Data("something exploded".utf8)
        )

        XCTAssertEqual(failure.issue, .serveFailed)
        XCTAssertNil(failure.actionURL)
    }
}
