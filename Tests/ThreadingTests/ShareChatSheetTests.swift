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

    // MARK: - The sheet

    func testTheSheetOffersOneButtonPerGrantInTheGrantsOwnOrder() {
        let request = ShareChatSheet.request(chatTitle: "Fix the parser", isRunning: true)

        XCTAssertEqual(request.options.count, ShareLinkGrant.allCases.count)
        XCTAssertEqual(
            request.options.map(\.title),
            ShareLinkGrant.allCases.map(\.buttonTitle)
        )
        XCTAssertTrue(
            request.title.contains("Fix the parser"),
            "the sheet names which chat is being shared"
        )
    }

    /// Who the invitation is for, in the first sentence.
    ///
    /// A share used to reach anybody with a browser, because a public relay carried it. It does
    /// not any more: the link points at a door of this Mac's own, so the person on the other end
    /// has to be on that network and running the app. Leaving that out is how somebody sends a
    /// link to a colleague in another country and waits.
    func testTheMessageSaysWhoCanUseTheInvitation() {
        let message = ShareChatSheet.request(chatTitle: "Fix the parser", isRunning: true).message

        XCTAssertTrue(message.contains("Wi-Fi or tailnet"))
        XCTAssertTrue(message.contains("Threading app"))
        XCTAssertFalse(message.lowercased().contains("relay"))
    }

    func testTheMessageKeepsTheInvitationMechanicsAndNotTheGrants() {
        let message = ShareChatSheet.request(chatTitle: "Fix the parser", isRunning: true).message

        XCTAssertTrue(message.contains("single-use"))
        XCTAssertTrue(message.contains("24 hours"))
        XCTAssertTrue(
            message.contains("Stop Sharing Chat"),
            "the message names the menu item that ends the share, since access otherwise lasts"
        )
        XCTAssertTrue(
            message.contains("other chats"),
            "what a link cannot reach is as much of the decision as what it can"
        )
        XCTAssertFalse(
            message.contains(ShareLinkGrant.collaborateAndApprove.summary),
            "the grants belong beside their buttons, not stacked into one paragraph"
        )
    }

    func testADormantChatDimsTheWatchingButtonAndSaysWhyBesideIt() {
        let dormant = ShareChatSheet.request(chatTitle: "Fix the parser", isRunning: false)
        let index = try? XCTUnwrap(ShareLinkGrant.allCases.firstIndex(of: .view))

        XCTAssertEqual(dormant.options[index ?? 0].isEnabled, false)
        XCTAssertTrue(
            dormant.options.filter({ !$0.isEnabled }).count == 1,
            "only the grant that needs a running chat waits for one"
        )
        XCTAssertTrue(
            accessoryText(isRunning: false).contains(ShareLinkGrant.unavailableUntilRunning),
            "a dimmed button explains itself in the accessory rather than being guessed at"
        )
        XCTAssertFalse(
            accessoryText(isRunning: true).contains(ShareLinkGrant.unavailableUntilRunning),
            "a running chat has nothing to explain"
        )
    }

    func testTheAccessoryNamesAndDescribesEveryGrant() {
        let text = accessoryText(isRunning: true)

        for grant in ShareLinkGrant.allCases {
            XCTAssertTrue(text.contains(grant.name), "the sheet names \(grant)")
            XCTAssertTrue(text.contains(grant.summary), "the sheet describes \(grant)")
        }
    }

    /// `NSAlert` lays an accessory out by its frame, so a stack left at its natural size arrives
    /// one line tall with everything below it clipped — the failure this measurement exists for.
    func testTheAccessoryIsMeasuredTallEnoughForEveryLineItHolds() {
        let accessory = ShareChatSheet.grantsAccessory(isRunning: false)

        XCTAssertEqual(accessory.frame.width, ShareSheetDefaults.accessoryWidth)
        XCTAssertGreaterThan(
            accessory.frame.height,
            Design.Typography.emphasizedBody().pointSize * CGFloat(ShareLinkGrant.allCases.count),
            "one line per grant is not enough; each carries a wrapped summary under its name"
        )

        let deepest = accessory.subviews.first?.fittingSize.height ?? 0
        XCTAssertEqual(accessory.frame.height, deepest, accuracy: 0.5)
    }

    /// Height alone is not enough, and the render is what proved it: sized after the layout pass
    /// rather than before it, the stack was pinned to the top of a box of no height, which in
    /// AppKit's unflipped coordinates put every label *below* the bounds the alert draws. The
    /// frame was right, the assertions passed, and the accessory came out blank.
    func testEveryLabelLandsInsideTheBoundsTheAlertWillDraw() {
        let accessory = ShareChatSheet.grantsAccessory(isRunning: false)

        let fields = labels(in: accessory)
        XCTAssertGreaterThanOrEqual(fields.count, ShareLinkGrant.allCases.count * 2)
        for field in fields {
            // The alignment rect rather than the frame: a text field's frame bleeds a couple of
            // points past the ink on either side, which is not the same as being out of bounds.
            let ink = field.alignmentRect(forFrame: field.convert(field.bounds, to: accessory))
            XCTAssertTrue(
                accessory.bounds.contains(ink),
                "“\(field.stringValue.prefix(28))…” is laid out outside the accessory at \(ink)"
            )
        }
    }

    // MARK: - What the recipient is sent

    /// The invitation used to travel as `url.absoluteString` and nothing else, from three
    /// separate call sites: both copy actions here and the iPhone's share sheet. That handed
    /// somebody a bare `https://192.168.1.181:8760/#…` — no way to know it wanted the Threading
    /// app, no way to know it wanted their network, and a certificate interstitial waiting if
    /// they tapped it in a browser, because the pin that vouches for that door lives in the app.
    func testACopiedInvitationSaysWhatItNeedsAndOpensInTheApp() throws {
        let shareURL = try XCTUnwrap(RemoteConnectionLink(
            baseURL: try XCTUnwrap(URL(string: "https://192.168.1.181:8760")),
            token: "invitation-bearer",
            pinnedFingerprintCode: String(repeating: "A", count: 26)
        )).shareURL

        let lines = ShareInvitationText.pasteboard(for: shareURL)
            .split(separator: "\n")
            .map(String.init)

        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0], ShareInvitationText.guidance)
        XCTAssertTrue(
            lines[1].hasPrefix("threading://join#"),
            "the app link goes first because it is the one that works"
        )
        XCTAssertEqual(
            lines[2],
            shareURL.absoluteString,
            "the https line stays for the messaging clients that will not linkify a scheme"
        )
    }

    /// The Mac and the iPhone compose through the same `RemoteInvitationShare`, so a recipient
    /// reads the same message whichever end minted the link. This holds the Mac's half to that
    /// composition rather than to a sentence of its own.
    func testTheMacComposesTheSameMessageTheKitDefines() throws {
        let link = try XCTUnwrap(RemoteConnectionLink(
            baseURL: try XCTUnwrap(URL(string: "https://mac.tail1234.ts.net")),
            token: "invitation-bearer"
        ))

        XCTAssertEqual(
            ShareInvitationText.pasteboard(for: link.shareURL),
            RemoteInvitationShare.text(for: link, guidance: ShareInvitationText.guidance)
        )
        XCTAssertTrue(ShareInvitationText.guidance.contains("Threading"))
    }

    // MARK: - Rendered

    /// The accessory sits on the alert's own material rather than a themed ground, so the one
    /// thing an assertion cannot check is whether its three tiers still read there. Written out
    /// light and dark; `THREADING_RENDER_OUT` redirects the output.
    func testRendersTheGrantsLightAndDark() throws {
        let directory = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"].map {
            URL(fileURLWithPath: $0)
        } ?? URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ThreadingRenders", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var written = 0
        for name: NSAppearance.Name in [.aqua, .darkAqua] {
            for isRunning in [true, false] {
                guard let data = accessoryImage(appearance: name, isRunning: isRunning) else {
                    XCTFail("no image for \(name.rawValue) running=\(isRunning)")
                    continue
                }
                let state = isRunning ? "running" : "dormant"
                try data.write(to: directory.appendingPathComponent(
                    "share-chat-grants-\(state)-\(name == .aqua ? "light" : "dark").png"
                ))
                written += 1
            }
        }
        XCTAssertEqual(written, 4)
    }

    // MARK: - Helpers

    private func accessoryImage(appearance name: NSAppearance.Name, isRunning: Bool) -> Data? {
        let appearance = NSAppearance(named: name)
        var data: Data?
        appearance?.performAsCurrentDrawingAppearance {
            let accessory = ShareChatSheet.grantsAccessory(isRunning: isRunning)
            let inset = Design.Spacing.large
            let host = NSView(frame: NSRect(
                x: 0,
                y: 0,
                width: accessory.frame.width + inset * 2,
                height: accessory.frame.height + inset * 2
            ))
            host.appearance = appearance
            host.wantsLayer = true
            host.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            accessory.frame.origin = NSPoint(x: inset, y: inset)
            host.addSubview(accessory)
            host.layoutSubtreeIfNeeded()

            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            data = rep.representation(using: .png, properties: [:])
        }
        return data
    }

    private func accessoryText(isRunning: Bool) -> String {
        labels(in: ShareChatSheet.grantsAccessory(isRunning: isRunning))
            .map(\.stringValue)
            .joined(separator: "\n")
    }

    private func labels(in view: NSView) -> [NSTextField] {
        view.subviews.flatMap { subview -> [NSTextField] in
            if let field = subview as? NSTextField { return [field] }
            return labels(in: subview)
        }
    }
}
