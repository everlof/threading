import AppKit
import ThreadingRemoteKit
import XCTest
@testable import Threading

/// What the Share Chat sheet tells someone before they hand a link to another person.
///
/// The sheet used to offer three buttons — "Copy View-Only Link", "Copy Collaborator Link",
/// "Copy Collaborator + Approval Link" — above one paragraph about invitations that never said
/// what any of the three actually granted. "Collaborator + Approval" is a permission model
/// written as a button label: nothing on screen connected it to *letting the agent run commands
/// and change files without asking you*, which is the only sentence that makes it a decision
/// rather than a guess. These tests hold each grant to naming both halves — what the holder may
/// do, and what they still may not — and hold the sheet to printing that beside the button that
/// hands it out. Built without being run, so no modal is involved.
@MainActor
final class ShareChatSheetTests: XCTestCase {

    // MARK: - Grants

    func testEachGrantCarriesItsOwnCapabilityAndApprovalRight() {
        XCTAssertEqual(ShareLinkGrant.view.capability, .view)
        XCTAssertFalse(ShareLinkGrant.view.canApprovePermissions)

        XCTAssertEqual(ShareLinkGrant.collaborate.capability, .interact)
        XCTAssertFalse(
            ShareLinkGrant.collaborate.canApprovePermissions,
            "collaboration and permission approval are separate rights; a collaborator link "
                + "must not quietly carry the second"
        )

        XCTAssertEqual(ShareLinkGrant.collaborateAndApprove.capability, .interact)
        XCTAssertTrue(ShareLinkGrant.collaborateAndApprove.canApprovePermissions)
    }

    func testOnlyTheWatchingGrantWaitsForARunningChat() {
        XCTAssertTrue(
            ShareLinkGrant.view.requiresRunningSession,
            "a viewer cannot wake a dormant chat, so there would be nothing to watch"
        )
        XCTAssertFalse(ShareLinkGrant.collaborate.requiresRunningSession)
        XCTAssertFalse(ShareLinkGrant.collaborateAndApprove.requiresRunningSession)
    }

    func testTheApprovalGrantSaysWhatApprovingLetsTheAgentDo() {
        let summary = ShareLinkGrant.collaborateAndApprove.summary

        XCTAssertTrue(
            summary.contains("run commands"),
            "the consequence of approval, not the word “approval”, is what a person decides on"
        )
        XCTAssertTrue(summary.contains("change files"))
        XCTAssertTrue(summary.contains("without asking you"))
    }

    func testTheWatchingGrantSaysWhatItWithholds() {
        let summary = ShareLinkGrant.view.summary

        XCTAssertTrue(summary.contains("Cannot type"))
        XCTAssertTrue(
            summary.contains("permission request"),
            "the sheet's three grants differ mostly in what they refuse; each has to say so"
        )
    }

    func testTheCollaboratorGrantSaysPermissionRequestsStillComeToTheOwner() {
        XCTAssertTrue(
            ShareLinkGrant.collaborate.summary.contains("still come to you"),
            "the difference from the next grant down is where a permission request lands"
        )
    }

    func testSheetHasOneCopyActionAndNamesItsReachability() {
        let local = ShareChatSheet.request(chatTitle: "Fix parser", isRunning: true)
        XCTAssertEqual(local.options.map(\.title), ["Copy Link"])
        XCTAssertTrue(local.message.contains("Wi-Fi or tailnet"))
        let hosted = ShareChatSheet.request(chatTitle: "Fix parser", isRunning: true, hosted: true)
        XCTAssertTrue(hosted.message.contains("any network"))
        XCTAssertTrue(hosted.message.contains("Threading app"))
    }

    /// A development build can point at Hosted Direct; a public build has no Hosted Direct row to
    /// enable, so it states the private-network requirement and stops there.
    func testPublicBuildCopyStatesTheNetworkRequirementWithoutHostedDirect() {
        let development = ShareChatSheet.request(
            chatTitle: "Fix parser", isRunning: true, hostedDirectIsOffered: true
        )
        XCTAssertTrue(development.message.contains("Hosted Direct"))

        let publicBuild = ShareChatSheet.request(
            chatTitle: "Fix parser", isRunning: true, hostedDirectIsOffered: false
        )
        XCTAssertTrue(publicBuild.message.contains("Wi-Fi or tailnet"))
        XCTAssertTrue(publicBuild.message.contains("Threading app"))
        XCTAssertFalse(
            publicBuild.message.contains("Hosted Direct"),
            "a public build told someone to enable a feature it does not contain"
        )
    }

    func testViewNeverCarriesApprovalAndDormantChatDefaultsToCollaborating() {
        let running = ShareChatOptionsView(isRunning: true)
        XCTAssertEqual(running.selectedGrant, .view)
        XCTAssertFalse(running.selectedGrant.canApprovePermissions)
        let dormant = ShareChatOptionsView(isRunning: false)
        XCTAssertEqual(dormant.selectedGrant, .collaborate)
        XCTAssertFalse(dormant.role.item(at: 0)!.isEnabled)
    }

    func testCopiedInvitationIsOnePublicLinkThatPreservesCapabilityAndPin() throws {
        let link = try XCTUnwrap(RemoteConnectionLink(baseURL: URL(string: "https://192.168.1.2:8760")!,
            token: "invitation", pinnedFingerprintCode: String(repeating: "A", count: 26)))
        let text = ShareInvitationText.pasteboard(for: link.shareURL)
        XCTAssertFalse(text.contains("\n"))
        XCTAssertEqual(URL(string: text)?.scheme, "https")
        XCTAssertEqual(RemoteInvitation(payload: text), .connection(link))
    }

    /// Render the shipping alert content, including its chrome and button row, not an isolated
    /// accessory. The same request and presenter construct the modal used by the sidebar.
    func testRendersTheGrantsLightAndDark() throws {
        let previous = AppThemeLibrary.current
        AppThemePalette.set(.system)
        defer { AppThemePalette.set(previous) }
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"]
            ?? NSTemporaryDirectory() + "/ThreadingRenders")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name: NSAppearance.Name in [.aqua, .darkAqua] {
            for isRunning in [true, false] {
                let appearance = try XCTUnwrap(NSAppearance(named: name))
                appearance.performAsCurrentDrawingAppearance {
                    do {
                    let alert = ConfirmationAlert.makeAlert(ShareChatSheet.request(
                        chatTitle: "Remote access review", isRunning: isRunning, hosted: true))
                    let content = alert.makeContentView()
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 450),
                        styleMask: [.borderless], backing: .buffered, defer: false)
                    window.appearance = appearance
                    window.contentView = content
                    content.layoutSubtreeIfNeeded()
                    content.frame.size = content.fittingSize
                    content.layoutSubtreeIfNeeded()
                    XCTAssertEqual(ThemeBoundaryAudit.violations(in: content), [])
                    let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                    content.cacheDisplay(in: content.bounds, to: rep)
                    let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                    let state = isRunning ? "running" : "dormant"
                    let mode = name == .aqua ? "light" : "dark"
                    try data.write(to: directory.appendingPathComponent("share-chat-grants-\(state)-\(mode).png"))
                    } catch { XCTFail("Share render failed: \(error)") }
                }
            }
        }
    }
}
