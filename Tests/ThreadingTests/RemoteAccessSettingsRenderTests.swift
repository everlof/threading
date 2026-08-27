import AppKit
import ThreadingRemoteKit
import XCTest
@testable import Threading

/// Draws the Remote Access page in the states it is actually used in, light and dark.
///
/// Every one of them takes a live network to reach, which is why what shipped was reviewed in
/// none of them: a panel that said a connection was unavailable while the reason sat three rows
/// above it, a minute of silence with a spinner on it, and a pairing card laid out like a poster.
/// The page states each of them from values, so this fixture can photograph them and turn what
/// the picture shows into assertions.
///
/// **The fixture is a window, and that is not a detail.** It used to be a bare `NSView` with the
/// page pinned to its four edges, which is a tree that is laid out once — and the four-line
/// disclosure blocks had an ambiguous column whose width the layout engine settled differently
/// depending on how many passes it had been through. So these renders showed the answers beside
/// their questions while the app, whose page lives in a window that lays out repeatedly, put them
/// in a ragged strip against the trailing edge. The fixture now hosts the page by calling the
/// shell's own `SettingsUI.install(page:in:top:)` inside a real window — the same function
/// `TerminalContainerViewController.install(settings:)` calls, rather than a copy of its
/// constraints — and `testTheFixtureAndTheAppLayThePageOutIdentically` holds a page laid out once
/// against a page laid out in a window that moves, which is the difference the two hosts used to
/// settle in opposite directions.
@MainActor
final class RemoteAccessSettingsRenderTests: XCTestCase {

    private enum Render {
        /// What the pane gives this page when the window is wide enough, which is the cap the
        /// shell states for every settings destination.
        static let pageWidth = SettingsUIDefaults.pageWidth
        /// The squeezed pane, where the hero's two columns run out of room first.
        static let narrowPageWidth: CGFloat = 420
        /// Tall enough that the whole page is inside the scroll view's clip, so the hero and the
        /// ways in are in one picture rather than two screens apart.
        static let height: CGFloat = 1_460
        /// A believable pane height, for the one test that proves the tall fixture above changes
        /// nothing but how much of the page is in the frame.
        static let paneHeight: CGFloat = 760

        /// The room beside a page that is already at the shared cap. A pane exactly as wide as
        /// the canvas never exercises the cap, and the cap is half of what these pictures are of.
        static let paneSlack: CGFloat = 200

        /// The pane a page of `pageWidth` needs, given the shell's own margins.
        ///
        /// At the cap the pane is wider than the page and the page is centred in it, which is
        /// the wide window. Below the cap the pane is exactly the page plus its margins, because
        /// a pane with two hundred points of slack in it is not a squeezed pane — and a fixture
        /// that asked for 420 and got 620 was photographing a width nobody was squeezed to.
        static func paneWidth(for pageWidth: CGFloat) -> CGFloat {
            pageWidth + Design.Spacing.large * 2 + (pageWidth < Self.pageWidth ? 0 : paneSlack)
        }

        static var directory: URL? {
            ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"].map {
                URL(fileURLWithPath: $0, isDirectory: true)
            }
        }
    }

    /// A real pairing payload, written the way `RemoteConnectionLink.scannablePayload` writes it.
    private static let payload =
        "HTTPS://192.168.1.42:8760/#MZXW6YTBOI7EU3TFOQQGE43FMN"

    private static let approvalURL = URL(
        string: "https://login.tailscale.com/f/serve?node=abcdef"
    )!

    private static let listenerPort: UInt16 = 8760

    /// One address on the Wi-Fi, and a second on an Ethernet cable, because a Mac with two is
    /// what makes the status line choose which one to name.
    private static let bindings = [
        RemoteListenerBinding(
            door: .lan,
            address: RemoteNetworkAddress(interfaceName: "en0", address: "192.168.1.42"),
            port: listenerPort
        ),
        RemoteListenerBinding(
            door: .lan,
            address: RemoteNetworkAddress(interfaceName: "en5", address: "10.0.0.7"),
            port: listenerPort
        )
    ]

    /// The tailnet, as the listener reports it: the `100.64.0.0/10` address the pairing code
    /// would name first, and the IPv6 address beside it on the same `utun`.
    private static let tailnetBindings = [
        RemoteListenerBinding(
            door: .tailscale,
            address: RemoteNetworkAddress(interfaceName: "utun4", address: "100.65.47.126"),
            port: listenerPort
        ),
        RemoteListenerBinding(
            door: .tailscale,
            address: RemoteNetworkAddress(
                interfaceName: "utun4",
                address: "fd7a:115c:a1e0::cd38:2f7e",
                isIPv6: true
            ),
            port: listenerPort
        )
    ]

    private static let magicDNSName = "mac-studio.tail1234.ts.net"

    private static let identity = RemoteIdentityCardPresentation(
        pairingCode: "MZXW6YTBOI7EU3TFOQQGE43FMN",
        nextPairingCode: nil,
        failure: nil
    )

    // MARK: - The fixture is the app

    /// **The regression boundary for the defect that started this rework.**
    ///
    /// The owner's screenshots and these renders disagreed about the same page. The cause was an
    /// under-determined layout — a constraint at `.defaultLow` competing with a wrapping label's
    /// `.defaultLow` content hugging — which a tree laid out once and a tree laid out repeatedly
    /// settled in opposite directions. So the fixture and the app must be the same shape *and*
    /// must be shown to be, or a render test is a picture of something nobody is looking at.
    ///
    /// This lays the page out both ways and compares every label's ink. It also resizes, because
    /// a window does, and the old fixture never did.
    func testTheFixtureAndTheAppLayThePageOutIdentically() throws {
        let detached = detachedPage(state: .lanBound)
        let hosted = page(state: .lanBound)

        // The app's pane moves: a person drags the window, opens the sidebar, enters full screen.
        // Each of those is another layout pass at another width, and passing through them is
        // what a fixture laid out exactly once never did.
        for size in [
            NSSize(width: Render.paneWidth(for: Render.narrowPageWidth), height: Render.paneHeight),
            NSSize(width: Render.paneWidth(for: 720), height: Render.paneHeight),
            NSSize(width: Render.paneWidth(for: Render.pageWidth), height: Render.height)
        ] {
            hosted.host.setFrameSize(size)
            hosted.host.layoutSubtreeIfNeeded()
        }

        let detachedLabels = labelInk(in: detached.view)
        let hostedLabels = labelInk(in: hosted.view)
        XCTAssertEqual(
            Set(detachedLabels.keys),
            Set(hostedLabels.keys),
            "the two hosts printed different text"
        )
        XCTAssertGreaterThan(detachedLabels.count, 20, "the fixture stopped finding the page")
        for (text, detachedRect) in detachedLabels {
            let hostedRect = try XCTUnwrap(hostedLabels[text])
            XCTAssertEqual(
                detachedRect.minX, hostedRect.minX, accuracy: 1,
                "“\(text.prefix(40))” starts in a different column in a window"
            )
            XCTAssertEqual(
                detachedRect.width, hostedRect.width, accuracy: 1,
                "“\(text.prefix(40))” wraps differently in a window"
            )
        }
    }

    /// The canvas is the pane's, not the content's.
    ///
    /// The page used to *prefer* the shared width with nothing else asking for one, so the engine
    /// dropped that preference and handed the page its fitting size: the states with no pairing
    /// code came out about 690 points wide inside a 1,124-point canvas, with every card 594. That
    /// is the drifting-edges defect the shared cap exists to prevent, and it is invisible to any
    /// fixture that pins the page to its host's four edges.
    func testEveryStateFillsTheSameCanvas() throws {
        for state in PageState.allCases {
            let page = self.page(state: state)
            XCTAssertEqual(
                page.view.frame.width,
                Render.pageWidth,
                accuracy: 1,
                "\(state) drew on a canvas of its own"
            )
        }
    }

    /// The fixture asks the *shell* for its canvas, so there is no second arrangement to drift.
    ///
    /// `SettingsUI.install(page:in:top:)` is the one function that pins a settings destination
    /// into a pane; `TerminalContainerViewController.install(settings:)` calls it and so does
    /// `page(state:…)` below. This states what that function promises, at the three pane widths
    /// that tell its constraints apart: below the cap the page is the pane less its margins, at
    /// the cap the fill and the cap are numerically identical and either could give, and above it
    /// the cap wins and the page is centred.
    func testTheShellGivesEverySettingsPageTheSameCanvas() throws {
        let margins = Design.Spacing.large * 2
        for paneWidth in [
            Render.narrowPageWidth + margins,
            Render.pageWidth + margins,
            Render.pageWidth + margins + Render.paneSlack
        ] {
            // A pane inside a window's content view, never the content view itself: a layout
            // root with nothing holding it is resized by Auto Layout to suit its subtree, and a
            // pane that grows to the page's preferred width proves nothing about either.
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: paneWidth, height: Render.height),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            let root = NSView(frame: NSRect(x: 0, y: 0, width: paneWidth, height: Render.height))
            window.contentView = root
            let host = NSView(frame: NSRect(x: 0, y: 0, width: paneWidth, height: Render.height))
            root.addSubview(host)

            let content = NSView()
            SettingsUI.install(page: content, in: host)
            host.layoutSubtreeIfNeeded()

            XCTAssertEqual(
                content.frame.width,
                min(paneWidth - margins, Render.pageWidth),
                accuracy: 1,
                "a \(paneWidth)pt pane gave the page a canvas of its own"
            )
            XCTAssertEqual(
                content.frame.midX, host.bounds.midX, accuracy: 1,
                "the page is off-centre in a \(paneWidth)pt pane"
            )
        }
    }

    /// The squeezed pane has to actually be squeezed, or the narrow picture is of the wide page.
    func testTheNarrowFixtureIsNarrow() throws {
        let wide = page(state: .lanBound)
        XCTAssertEqual(wide.view.frame.width, Render.pageWidth, accuracy: 1)

        let narrow = page(state: .lanBound, width: Render.narrowPageWidth)
        XCTAssertEqual(narrow.view.frame.width, Render.narrowPageWidth, accuracy: 1)
        XCTAssertEqual(
            narrow.host.bounds.width,
            Render.paneWidth(for: Render.narrowPageWidth),
            accuracy: 1,
            "the fixture window grew to the page's preferred width"
        )
    }

    /// The tall fixture is only a taller pane. If the height changed the layout, every picture
    /// below would be of a page nobody has.
    func testTheTallFixtureIsOnlyATallerPane() throws {
        let tall = page(state: .lanBound)
        let real = page(state: .lanBound, height: Render.paneHeight)
        let tallInk = labelInk(in: tall.view)
        let realInk = labelInk(in: real.view)

        for (text, rect) in tallInk {
            guard let other = realInk[text] else { continue }
            XCTAssertEqual(rect.minX, other.minX, accuracy: 1, "“\(text.prefix(40))”")
            XCTAssertEqual(rect.width, other.width, accuracy: 1, "“\(text.prefix(40))”")
        }
    }

    // MARK: - Every way in still states its four lines

    /// The copy rule with teeth: never present a method without its four lines.
    ///
    /// They are behind a "?" now rather than printed under every switch, which is what turned
    /// three quarters of the page back into page. "Available" is what the rule asks for, and this
    /// asserts all three routes to them: the topic the button carries, the words the panel prints,
    /// and the sentence a screen reader hears without opening anything.
    func testEveryWayInKeepsItsFourLinesOnePressAway() throws {
        let page = self.page(state: .lanBound)
        for wayIn in RemoteAccessWayIn.allCases {
            if wayIn == .threadingDirect { continue }
            if wayIn == .tailscale { page.controller.select(.tailscale) }
            let button = try XCTUnwrap(
                help(in: page.view, titled: wayIn.title),
                "\(wayIn) has no help at all"
            )
            XCTAssertEqual(
                button.topic.lines.map(\.term),
                wayIn.disclosure.lines.map(\.question),
                "\(wayIn) asks different questions, or asks them in a different order"
            )
            XCTAssertEqual(
                button.topic.lines.map(\.detail),
                wayIn.disclosure.lines.map(\.answer),
                "\(wayIn) answers them differently"
            )

            let printed = allLabels(in: button.makeContent().view).map(\.stringValue)
            for line in wayIn.disclosure.lines {
                XCTAssertTrue(printed.contains(line.question), "\(wayIn): \(line.question)")
                XCTAssertTrue(printed.contains(line.answer), "\(wayIn): \(line.answer)")
            }
            if let note = wayIn.note {
                XCTAssertTrue(printed.contains(note), "\(wayIn) dropped its note")
            }

            let spoken = try XCTUnwrap(button.accessibilityHelp())
            for line in wayIn.disclosure.lines {
                XCTAssertTrue(spoken.contains(line.answer), "\(wayIn) is silent about \(line.question)")
            }
        }
    }

    /// Threading Direct is future work, so it is only a segment once this Mac is signed in — and
    /// when it is, it answers the same four questions as the rest.
    func testThreadingDirectJoinsTheRunOnlyWhenSignedIn() throws {
        let off = page(state: .lanBound)
        XCTAssertFalse(
            segmentTitles(in: off.view).contains(RemoteAccessWayIn.threadingDirect.title),
            "a way in nothing can carry yet is on offer"
        )

        let on = page(state: .lanBound, showsThreadingDirect: true)
        XCTAssertTrue(
            segmentTitles(in: on.view).contains(RemoteAccessWayIn.threadingDirect.title)
        )
        on.controller.select(.threadingDirect)
        let button = try XCTUnwrap(help(in: on.view, titled: RemoteAccessWayIn.threadingDirect.title))
        XCTAssertEqual(
            button.topic.lines.map(\.term),
            RemoteAccessWayIn.threadingDirect.disclosure.lines.map(\.question)
        )
    }

    /// Nothing on the page offers, mentions or blames the public relay.
    ///
    /// Two ways in may still say "relay" and mean something true: Tailscale relays encrypted
    /// WireGuard when peers cannot connect directly, and Threading Direct falls back to TURN.
    /// Both are named in their own four lines as traffic the relay cannot read, which is the
    /// disclosure working rather than a leftover.
    func testNoWayInMentionsTheRelayThatNoLongerExists() throws {
        let page = self.page(state: .lanBound)
        let network = try XCTUnwrap(help(in: page.view, titled: RemoteAccessWayIn.thisNetwork.title))
        XCTAssertFalse(network.topic.spokenSummary.lowercased().contains("relay"))

        var text = allLabels(in: page.view).map(\.stringValue)
            + helpButtons(in: page.view).map(\.topic.spokenSummary)
        page.controller.select(.tailscale)
        text += allLabels(in: page.view).map(\.stringValue)
            + helpButtons(in: page.view).map(\.topic.spokenSummary)

        for line in text {
            let lowered = line.lowercased()
            for word in ["cloudflare", "cloudflared", "quick tunnel", "secure relay"] {
                XCTAssertFalse(lowered.contains(word), "“\(line)” still names \(word)")
            }
        }
    }

    func testOnlyTheTwoRealDoorsCarryASwitch() throws {
        let page = self.page(state: .lanBound)
        XCTAssertNotNil(
            view(in: page.view, id: RemoteAccessPreferencesViewController.Identifier.doorToggle(.thisNetwork))
        )
        XCTAssertNil(
            view(in: page.view, id: RemoteAccessPreferencesViewController.Identifier.doorToggle(.throughAVPN)),
            "the VPN grew a switch it cannot honour"
        )

        page.controller.select(.tailscale)
        XCTAssertNotNil(
            view(in: page.view, id: RemoteAccessPreferencesViewController.Identifier.doorToggle(.tailscale))
        )
    }

    // MARK: - The run says what you are not looking at

    /// A segmented run hides two panels out of three, which is the whole point of using one and
    /// the whole risk. Each segment carries the state of its own way in.
    func testEachSegmentCarriesItsWayInsState() throws {
        let bound = page(state: .lanBound)
        XCTAssertEqual(
            marks(in: bound.view),
            [.ready, .idle],
            "a bound network and an unselected tailnet did not read as themselves"
        )

        let unreachable = page(state: .lanNoInterface)
        XCTAssertEqual(unreachable.marks.first, .attention)

        // The mark comes from the status line rather than from the switch, so a way in that is
        // on and bound to nothing cannot show a tick.
        let tailnetDown = page(state: .tailnetNotConnected)
        XCTAssertEqual(tailnetDown.marks, [.idle, .attention])
    }

    // MARK: - The status line states a fact

    /// One address on the page's own line, and it is the one the pairing code carries.
    ///
    /// It used to join every ready way in's sentence together, so a Mac with two interfaces
    /// answered "can anything reach this Mac?" with a paragraph of four addresses.
    func testTheOverallStatusNamesOneAddressAndTheWayInCarriesTheRest() throws {
        let page = self.page(state: .lanBound)
        let status = try XCTUnwrap(label(in: page.view, id: "settings.remote-access.status"))
        XCTAssertEqual(status.stringValue, "Ready")

        let detail = try XCTUnwrap(statusDetail(in: page.view))
        XCTAssertTrue(detail.contains("192.168.1.42:8760"), detail)
        XCTAssertFalse(detail.contains("10.0.0.7"), "the second address is on the page's own line")

        let hint = try XCTUnwrap(label(
            in: page.view,
            id: RemoteAccessPreferencesViewController.Identifier.statusHint(.thisNetwork)
        ))
        XCTAssertTrue(hint.stringValue.contains("10.0.0.7"), "the other address went nowhere")
    }

    func testABoundDoorNamesItsAddressAndPort() throws {
        let page = self.page(state: .lanBound)
        let status = try XCTUnwrap(label(
            in: page.view,
            id: RemoteAccessPreferencesViewController.Identifier.status(.thisNetwork)
        ))
        XCTAssertTrue(status.stringValue.contains("192.168.1.42:8760"), status.stringValue)
        XCTAssertEqual(
            mark(in: page.view, for: .thisNetwork),
            "✓",
            "a bound door is not showing a met mark"
        )
    }

    func testAnUnreachableDoorNamesTheReasonAndNotAnAddress() throws {
        let page = self.page(state: .lanNoInterface)
        let status = try XCTUnwrap(label(
            in: page.view,
            id: RemoteAccessPreferencesViewController.Identifier.status(.thisNetwork)
        ))
        XCTAssertTrue(status.stringValue.contains("no address on this network"), status.stringValue)
        XCTAssertFalse(status.stringValue.contains(":8760"))
        XCTAssertEqual(mark(in: page.view, for: .thisNetwork), "!")

        let hint = try XCTUnwrap(label(
            in: page.view,
            id: RemoteAccessPreferencesViewController.Identifier.statusHint(.thisNetwork)
        ))
        XCTAssertTrue(hint.stringValue.contains("Connect this Mac"), hint.stringValue)
    }

    /// A bound address with the firewall in doubt is still an address, and still not green.
    func testTheFirewallHintRidesWithTheAddressAndTakesTheGreenAwayFromIt() throws {
        let page = self.page(state: .lanFirewalled)
        let status = try XCTUnwrap(label(
            in: page.view,
            id: RemoteAccessPreferencesViewController.Identifier.status(.thisNetwork)
        ))
        XCTAssertTrue(status.stringValue.contains("192.168.1.42:8760"))
        XCTAssertEqual(mark(in: page.view, for: .thisNetwork), "!")

        let hint = try XCTUnwrap(label(
            in: page.view,
            id: RemoteAccessPreferencesViewController.Identifier.statusHint(.thisNetwork)
        ))
        XCTAssertTrue(hint.stringValue.contains("firewall"), hint.stringValue)
        XCTAssertEqual(page.marks.first, .attention)
    }

    func testNothingSwitchedOnIsAStateWithAFactInIt() throws {
        let page = self.page(state: .nothingOn)
        let detail = try XCTUnwrap(statusDetail(in: page.view))
        XCTAssertTrue(detail.contains("127.0.0.1:8760"), detail)

        let pairing = try XCTUnwrap(label(in: page.view, id: "settings.remote-access.pairing-title"))
        XCTAssertEqual(pairing.stringValue, "No way in is switched on")
        let code = try XCTUnwrap(imageView(in: page.view, id: "settings.remote-access.qr-code"))
        XCTAssertTrue(code.isHidden, "a page with no way in is showing a pairing code")
    }

    // MARK: - The hero

    /// The page leads with what it is for: the code, the identity the code is a fingerprint of,
    /// and one instruction. Everything longer is behind the "?" beside the title.
    func testTheHeroLeadsWithTheCodeAndTheIdentityBesideIt() throws {
        let page = self.page(state: .lanBound)
        let host = page.host

        let title = try XCTUnwrap(label(in: page.view, id: "settings.remote-access.pairing-title"))
        XCTAssertEqual(title.stringValue, "Scan with your iPhone")
        XCTAssertFalse(
            title.stringValue.unicodeScalars.contains { $0.properties.isEmojiPresentation },
            "the title carries a glyph again"
        )

        let code = try XCTUnwrap(imageView(in: page.view, id: "settings.remote-access.qr-code"))
        let image = try XCTUnwrap(code.image)
        XCTAssertFalse(code.isHidden)
        XCTAssertEqual(
            code.frame.width,
            RemoteAccessPreferencesViewController.PairingCardLayout.codeSide,
            accuracy: 0.5
        )
        XCTAssertEqual(image.size.width, code.frame.width, accuracy: 0.5, "the code is resampled")
        let matrix = try XCTUnwrap(PairingCodeMatrix.make(Self.payload, correctionLevel: "M"))
        XCTAssertGreaterThanOrEqual(
            code.frame.width / CGFloat(matrix.size + 8), 3,
            "the plate is now too small to scan"
        )

        // The identity is part of the hero, in the code's own column of text.
        let caption = try XCTUnwrap(label(
            in: page.view,
            id: RemoteAccessPreferencesViewController.Identifier.identityCaption
        ))
        let identityCode = try XCTUnwrap(
            label(in: page.view, id: "settings.remote-access.identity-code")
        )
        XCTAssertEqual(identityCode.stringValue, Self.identity.pairingCode)
        XCTAssertEqual(identityCode.stringValue.count, 26)
        XCTAssertTrue(
            identityCode.font?.fontName.lowercased().contains("mono") == true
                || identityCode.font?.isFixedPitch == true,
            "the code a person compares character by character is not monospaced"
        )

        let detail = try XCTUnwrap(label(in: page.view, id: "settings.remote-access.pairing-detail"))
        let action = try XCTUnwrap(button(in: page.view, id: "settings.remote-access.pair"))
        XCTAssertEqual(action.title, "Copy Pairing Link")

        // Leading edge, and one column for everything beside it. Measured on alignment rects
        // rather than frames, because that is what "aligned by ink" means here.
        let codeInk = ink(of: code, in: host)
        let column = [title, detail, caption, identityCode, action].map { ink(of: $0, in: host).minX }
        XCTAssertLessThan(codeInk.minX, try XCTUnwrap(column.min()), "the code is not leading")
        for edge in column {
            XCTAssertEqual(edge, column[0], accuracy: 0.5, "the hero's text is not on one column")
        }
        XCTAssertEqual(
            try XCTUnwrap(column.min()) - codeInk.maxX,
            Design.Spacing.large,
            accuracy: 0.5,
            "the gap between the code and its text is not the token that states it"
        )

        // The card holds one image, and it is the code.
        let card = try XCTUnwrap(card(containing: code))
        XCTAssertEqual(
            descendants(in: card).compactMap { $0 as? NSImageView }.count, 1,
            "the hero grew a decorative image again"
        )
    }

    /// The ownership warning and the pinning explanation left the page for the "?" beside the
    /// title. They are the two things a person is entitled to read before scanning an owner code,
    /// so "left the page" has to mean "one press away and complete", not "gone".
    func testTheHeroKeepsItsWarningAndItsPinningExplanationOnePressAway() throws {
        let page = self.page(state: .lanBound)
        let button = try XCTUnwrap(help(in: page.view, titled: "Pairing this Mac"))
        let printed = allLabels(in: button.makeContent().view).map(\.stringValue)

        XCTAssertTrue(
            printed.contains { $0.hasPrefix("Only scan this owner code on a device you control.") },
            "the ownership warning is gone rather than moved"
        )
        XCTAssertTrue(
            printed.contains(RemoteIdentityCardPresentation.explanation),
            "what the phone pins is gone rather than moved"
        )

        // And nothing that long is on the page itself any more.
        for label in allLabels(in: page.view) where !label.isHidden {
            XCTAssertLessThan(
                label.stringValue.count, 220,
                "a paragraph came back onto the page: “\(label.stringValue.prefix(60))…”"
            )
        }
    }

    func testAMacWithNoCertificateSaysSoAndOffersTheFix() throws {
        let page = self.page(state: .identityUnavailable)
        let detail = try XCTUnwrap(
            label(in: page.view, id: "settings.remote-access.identity-detail")
        )
        XCTAssertFalse(detail.isHidden, "the reason there is no code is hidden")
        XCTAssertTrue(detail.stringValue.contains("could not read its certificate"), detail.stringValue)

        let code = try XCTUnwrap(label(in: page.view, id: "settings.remote-access.identity-code"))
        XCTAssertTrue(code.isHidden, "a Mac with no certificate is showing one")

        let status = try XCTUnwrap(label(
            in: page.view,
            id: RemoteAccessPreferencesViewController.Identifier.status(.thisNetwork)
        ))
        XCTAssertTrue(status.stringValue.contains("no certificate to present"), status.stringValue)
    }

    /// A healthy Mac shows the code and no sentence about it: the explanation is behind the "?",
    /// and only a *reason* ever takes a line of the page.
    func testTheIdentityLineIsAReasonOrNothing() throws {
        let healthy = page(state: .lanBound)
        let detail = try XCTUnwrap(
            label(in: healthy.view, id: "settings.remote-access.identity-detail")
        )
        XCTAssertTrue(detail.isHidden, "the page is explaining what a code is again")
    }

    func testRotationIsOfferedInOneRowAndActivateWaitsForASuccessor() throws {
        let waiting = page(state: .lanBound)
        let prepare = try XCTUnwrap(
            button(in: waiting.view, id: "settings.remote-access.identity-prepare")
        )
        let activate = try XCTUnwrap(
            button(in: waiting.view, id: "settings.remote-access.identity-activate")
        )
        let reset = try XCTUnwrap(
            button(in: waiting.view, id: "settings.remote-access.identity-reset")
        )
        XCTAssertTrue(prepare.isEnabled)
        XCTAssertFalse(activate.isEnabled, "Activate is offered with nothing to activate")
        XCTAssertTrue(reset.isEnabled)

        // One row, one card: all three sit on the same line under the hero.
        XCTAssertEqual(card(containing: prepare), card(containing: reset))
        let host = waiting.host
        XCTAssertEqual(
            ink(of: prepare, in: host).minY,
            ink(of: reset, in: host).minY,
            accuracy: 1,
            "the identity actions are not on one row"
        )

        let announced = page(
            state: .lanBound,
            identity: RemoteIdentityCardPresentation(
                pairingCode: Self.identity.pairingCode,
                nextPairingCode: "MFRGGZDFMZTWQ2LKNNWG23TPOB",
                failure: nil
            )
        )
        XCTAssertTrue(
            try XCTUnwrap(
                button(in: announced.view, id: "settings.remote-access.identity-activate")
            ).isEnabled
        )
        let successor = try XCTUnwrap(
            label(in: announced.view, id: "settings.remote-access.identity-successor")
        )
        XCTAssertFalse(successor.isHidden)
        XCTAssertTrue(successor.stringValue.contains("MFRGGZDFMZTWQ2LKNNWG23TPOB"))
    }

    /// The two operations cost different things, so the "?" beside them says which is which.
    func testTheIdentityHelpSaysWhatEachOperationCosts() throws {
        let page = self.page(state: .lanBound)
        let button = try XCTUnwrap(help(in: page.view, titled: "Rotate or reset this Mac’s identity"))
        let spoken = button.topic.spokenSummary
        XCTAssertTrue(spoken.contains("Prepare mints the next certificate"), spoken)
        XCTAssertTrue(
            spoken.contains("has to scan the new pairing code"),
            "the reset's real cost is not stated"
        )
    }

    // MARK: - Sharing & Security

    /// The section keeps its four rows, and each one keeps the whole of what it used to say.
    ///
    /// This is the rule the redesign is most able to break by accident: moving prose behind a
    /// press is only honest while every sentence survives the move. So each row is held to both
    /// halves — the short line still on the page, and the rest one press away and complete.
    func testEverySharingRowKeepsItsSentencesWithTheLongHalfOnePressAway() throws {
        let page = self.page(state: .lanBound)
        let onPage = allLabels(in: page.view)
            .filter { !isEffectivelyHidden($0) }
            .map(\.stringValue)

        let rows: [(title: String, page: String, help: String)] = [
            (
                "New shared chats",
                "Collaborative lets everyone with reply access send.",
                "You can switch a live chat at any time."
            ),
            (
                "Reports from your phone",
                "Shake to report, then Send to Mac, starts a chat here while you are away from it.",
                "Its own workspace keeps that chat out of the checkout you left open."
            ),
            (
                "Your own devices",
                "The QR code is owner access.",
                "A paired device can see and manage your chats"
            ),
            (
                "Other people",
                "Use Share Chat… from that chat’s ⋯ menu.",
                "It grants only the selected chat"
            )
        ]

        for row in rows {
            XCTAssertTrue(
                onPage.contains { $0.contains(row.page) },
                "“\(row.title)” lost the line that stays on the page"
            )
            let button = try XCTUnwrap(help(in: page.view, titled: row.title), row.title)
            XCTAssertTrue(
                button.topic.spokenSummary.contains(row.help),
                "“\(row.title)” lost the half that moved behind its “?”"
            )
            // The long half moved; it did not get printed twice.
            XCTAssertFalse(
                onPage.contains { $0.contains(row.help) },
                "“\(row.title)” prints its explanation on the page as well as behind the press"
            )
        }
    }

    // MARK: - The announcement, and what it buys

    func testTheAnnouncementLivesInsideTheNetworkPanel() throws {
        let page = self.page(state: .lanBound)
        let toggle = try XCTUnwrap(view(
            in: page.view,
            id: RemoteAccessPreferencesViewController.Identifier.discoveryToggle
        ))
        let networkToggle = try XCTUnwrap(view(
            in: page.view,
            id: RemoteAccessPreferencesViewController.Identifier.doorToggle(.thisNetwork)
        ))
        XCTAssertEqual(
            card(containing: toggle),
            card(containing: networkToggle),
            "the announcement is not in the panel it belongs to"
        )

        // And it leaves with the panel: it is the LAN listeners' broadcast and nothing else's.
        page.controller.select(.tailscale)
        XCTAssertNil(view(
            in: page.view,
            id: RemoteAccessPreferencesViewController.Identifier.discoveryToggle
        ))
    }

    /// The exact payload is a decision somebody takes once, so it is behind the "?" — complete,
    /// and not four lines of the page for everybody who has already taken it.
    func testWhatIsBroadcastIsStatedInFull() throws {
        let page = self.page(state: .lanBound)
        let button = try XCTUnwrap(help(in: page.view, titled: "Announce on this network"))
        let spoken = button.topic.spokenSummary
        for fact in ["opaque name", "protocol version", "certificate fingerprint"] {
            XCTAssertTrue(spoken.contains(fact), "the broadcast no longer states “\(fact)”")
        }
        XCTAssertTrue(spoken.contains("Never the computer name"), spoken)
    }

    func testTheAnnouncedLineNamesTheOpaqueInstanceAndOnlyWhenOneIsRegistered() throws {
        let announced = page(state: .lanBound, discovery: DiscoveryState.announcedAndCanWake.presentation)
        let name = try XCTUnwrap(label(
            in: announced.view,
            id: RemoteAccessPreferencesViewController.Identifier.announcedName
        ))
        XCTAssertFalse(isEffectivelyHidden(name))
        XCTAssertTrue(name.stringValue.contains(Self.instanceName), name.stringValue)

        let off = page(state: .lanBound, discovery: DiscoveryState.off.presentation)
        let quiet = try XCTUnwrap(label(
            in: off.view,
            id: RemoteAccessPreferencesViewController.Identifier.announcedName
        ))
        XCTAssertTrue(isEffectivelyHidden(quiet), "nothing is registered and the page says it is")
    }

    /// "Can wake this Mac" is a promise the network has to keep, so it is printed only when both
    /// facts hold, and each of the other four cases names the exact thing that is missing.
    func testWakingIsClaimedOnlyWithBothFactsAndOtherwiseNamesTheReason() throws {
        let expected: [(DiscoveryState, String)] = [
            (.announcedAndCanWake, "Can wake this Mac from sleep"),
            (.off, "Waking needs an announcement on this network"),
            (.wakeSettingOff, "Wake for network access is off in System Settings ▸ Energy"),
            (.noSleepProxy, "No sleep proxy on this network; an Apple TV or HomePod provides one"),
            (.notChecked, "Not checked yet")
        ]
        for (state, text) in expected {
            let page = self.page(state: .lanBound, discovery: state.presentation)
            let wake = try XCTUnwrap(label(
                in: page.view,
                id: RemoteAccessPreferencesViewController.Identifier.wakeOnDemand
            ))
            XCTAssertEqual(wake.stringValue, text, "\(state)")
            let mark = try XCTUnwrap(label(
                in: page.view,
                id: RemoteAccessPreferencesViewController.Identifier.wakeOnDemandMark
            ))
            XCTAssertEqual(
                mark.stringValue,
                state == .announcedAndCanWake ? "✓" : "–",
                "\(state) drew the wrong mark"
            )
        }
    }

    func testTheTwoFactLinesShareTheirColumn() throws {
        let page = self.page(state: .lanBound, discovery: DiscoveryState.announcedAndCanWake.presentation)
        let announced = try XCTUnwrap(label(
            in: page.view,
            id: RemoteAccessPreferencesViewController.Identifier.announcedName
        ))
        let wake = try XCTUnwrap(label(
            in: page.view,
            id: RemoteAccessPreferencesViewController.Identifier.wakeOnDemand
        ))
        XCTAssertEqual(
            ink(of: announced, in: page.host).minX,
            ink(of: wake, in: page.host).minX,
            accuracy: 0.5,
            "the two facts are indented differently"
        )
    }

    // MARK: - The browser sub-option carries its own reason and fix

    func testAServeFailureStatesItsReasonAndOffersItsFixOnItsOwnRow() throws {
        let page = self.page(state: .serveNeedsHTTPS)
        let status = try XCTUnwrap(label(
            in: page.view,
            id: RemoteAccessPreferencesViewController.Identifier.serveStatus
        ))
        XCTAssertTrue(status.stringValue.contains("HTTPS"), status.stringValue)

        let hint = try XCTUnwrap(label(
            in: page.view,
            id: RemoteAccessPreferencesViewController.Identifier.serveStatusHint
        ))
        XCTAssertFalse(hint.stringValue.isEmpty, "the remedy is missing from the row that failed")

        let remedy = try XCTUnwrap(
            button(in: page.view, id: RemoteAccessPreferencesViewController.Identifier.serveRemedy)
        )
        XCTAssertFalse(remedy.isHidden)
        XCTAssertEqual(
            card(containing: remedy),
            card(containing: status),
            "the fix is not beside the sentence that needs it"
        )

        // The pairing panel is not the place the reason lives, and it is not blamed for Serve
        // either: a browser convenience never stops a phone from pairing.
        let pairing = try XCTUnwrap(label(in: page.view, id: "settings.remote-access.pairing-title"))
        XCTAssertEqual(pairing.stringValue, "Scan with your iPhone")
    }

    func testServeStatesTheAddressItIsServingAt() throws {
        let page = self.page(state: .serveServing)
        let status = try XCTUnwrap(label(
            in: page.view,
            id: RemoteAccessPreferencesViewController.Identifier.serveStatus
        ))
        XCTAssertTrue(status.stringValue.contains(Self.magicDNSName), status.stringValue)
        XCTAssertTrue(
            try XCTUnwrap(
                button(in: page.view, id: RemoteAccessPreferencesViewController.Identifier.serveRemedy)
            ).isHidden,
            "a working Serve is offering a fix"
        )
    }

    /// The certificate-transparency cost is what a person is deciding about, so it is one press
    /// from the switch rather than in a document.
    func testTheServeHelpStatesItsPublicCost() throws {
        let page = self.page(state: .serveServing)
        let button = try XCTUnwrap(help(in: page.view, titled: "Open in a browser on your tailnet"))
        XCTAssertTrue(
            button.topic.spokenSummary.contains("public certificate logs"),
            button.topic.spokenSummary
        )
    }

    // MARK: - The tailnet way in

    func testABoundTailnetDoorNamesItsAddressAndItsName() throws {
        let page = self.page(state: .tailnetBound)
        let status = try XCTUnwrap(label(
            in: page.view,
            id: RemoteAccessPreferencesViewController.Identifier.status(.tailscale)
        ))
        XCTAssertTrue(status.stringValue.contains("100.65.47.126:8760"), status.stringValue)

        let hint = try XCTUnwrap(label(
            in: page.view,
            id: RemoteAccessPreferencesViewController.Identifier.statusHint(.tailscale)
        ))
        XCTAssertTrue(hint.stringValue.contains(Self.magicDNSName), hint.stringValue)
        XCTAssertEqual(mark(in: page.view, for: .tailscale), "✓")
    }

    /// The readiness card is gone, so the door's own line has to carry the whole reason and its
    /// remedy — which is what the card was duplicating.
    func testAnAbsentTailnetSaysWhichOfItsThreeCausesItIsWithoutASecondCard() throws {
        let expected: [(PageState, String, String)] = [
            (.tailnetNotInstalled, "not installed on this Mac", "Install Tailscale"),
            (.tailnetNotConnected, "not connected", "Turn on Tailscale")
        ]
        for (state, reason, remedy) in expected {
            let page = self.page(state: state)
            let status = try XCTUnwrap(label(
                in: page.view,
                id: RemoteAccessPreferencesViewController.Identifier.status(.tailscale)
            ))
            XCTAssertTrue(status.stringValue.contains(reason), "\(state): \(status.stringValue)")
            let hint = try XCTUnwrap(label(
                in: page.view,
                id: RemoteAccessPreferencesViewController.Identifier.statusHint(.tailscale)
            ))
            XCTAssertTrue(hint.stringValue.contains(remedy), "\(state): \(hint.stringValue)")

            // The readiness card that used to restate all three steps is gone. The overall
            // status row and the pairing panel do carry the same sentence, and that is the copy
            // rule working rather than a duplicate: a panel states the reason it is showing.
            let printed = allLabels(in: page.view).filter { !isEffectivelyHidden($0) }
            for title in ["Tailscale installed", "Signed in"] {
                XCTAssertFalse(
                    printed.contains { $0.stringValue == title },
                    "\(state) grew a readiness card again"
                )
            }
        }
    }

    func testATailnetDoorComingUpSaysSoWithoutClaimingAnAddress() throws {
        let page = self.page(state: .tailnetBinding)
        let status = try XCTUnwrap(label(
            in: page.view,
            id: RemoteAccessPreferencesViewController.Identifier.status(.tailscale)
        ))
        XCTAssertTrue(status.stringValue.contains("Binding"), status.stringValue)
        XCTAssertFalse(status.stringValue.contains(":8760"))

        let pairing = try XCTUnwrap(label(in: page.view, id: "settings.remote-access.pairing-title"))
        XCTAssertEqual(pairing.stringValue, "Preparing your pairing code")
        let detail = try XCTUnwrap(label(in: page.view, id: "settings.remote-access.pairing-detail"))
        XCTAssertTrue(detail.stringValue.contains("Binding"), "the panel is silent while it waits")
    }

    // MARK: - Nothing runs past its card

    /// A "?" beside a title must not push the switch it explains out of its own row, and the
    /// squeezed pane is where it would.
    func testNothingIsPushedOutOfItsCardInEitherPane() throws {
        for width in [Render.pageWidth, Render.narrowPageWidth] {
            for wayIn in [RemoteAccessWayIn.thisNetwork, .tailscale] {
                let page = self.page(state: .lanBound, width: width, selecting: wayIn)
                let toggle = try XCTUnwrap(view(
                    in: page.view,
                    id: RemoteAccessPreferencesViewController.Identifier.doorToggle(wayIn)
                ))
                let panel = try XCTUnwrap(card(containing: toggle))
                let cardFrame = panel.convert(panel.bounds, to: page.host)
                let toggleFrame = toggle.convert(toggle.bounds, to: page.host)
                XCTAssertLessThanOrEqual(
                    toggleFrame.maxX, cardFrame.maxX,
                    "\(wayIn)'s switch is outside its card at \(width)pt"
                )
                XCTAssertGreaterThan(
                    toggleFrame.width, 0,
                    "\(wayIn)'s switch was compressed away at \(width)pt"
                )

                for button in helpButtons(in: page.view) {
                    let frame = button.convert(button.bounds, to: page.host)
                    guard let host = card(containing: button) else { continue }
                    XCTAssertLessThanOrEqual(
                        frame.maxX,
                        host.convert(host.bounds, to: page.host).maxX,
                        "a help mark runs past its card at \(width)pt"
                    )
                }
            }

            // The hero is two columns, and the code is what cannot shrink.
            let page = self.page(state: .lanBound, width: width)
            let code = try XCTUnwrap(imageView(in: page.view, id: "settings.remote-access.qr-code"))
            let detail = try XCTUnwrap(
                label(in: page.view, id: "settings.remote-access.pairing-detail")
            )
            let hero = try XCTUnwrap(card(containing: code))
            XCTAssertLessThanOrEqual(
                detail.convert(detail.bounds, to: page.host).maxX,
                hero.convert(hero.bounds, to: page.host).maxX,
                "the hero's text runs past its card at \(width)pt"
            )
            XCTAssertGreaterThan(
                detail.frame.width, 40,
                "the hero's text column collapsed at \(width)pt"
            )
        }
    }

    // MARK: - Images

    /// The credential warning is security copy, but it still has to survive the theme boundary:
    /// the fallback is the longest line in this card and is the one ad-hoc builds actually show.
    /// Keep one real settings-shell page under System and two deliberately different authored
    /// themes, as required for a changed durable surface by `docs/THEME_BOUNDARY.md`.
    func testRendersCredentialStorageDisclosureAcrossThemes() throws {
        let previousTheme = AppThemeLibrary.current
        defer {
            AppThemePalette.set(previousTheme)
            NotificationCenter.default.post(AppThemeDidChange(themeID: previousTheme.id))
        }

        let directory = Render.directory
        if let directory {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let fixtures: [(String, AppTheme, NSAppearance.Name, Bool)] = [
            ("system-light", .system, .aqua, true),
            ("system-protected", .system, .aqua, false),
            ("cyberpunk", AppThemeStyles.cyberpunk, .darkAqua, true),
            ("swiss", AppThemeStyles.swissMinimalist, .aqua, true),
        ]

        for (name, theme, appearanceName, isShellReachable) in fixtures {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            var png: Data?
            appearance.performAsCurrentDrawingAppearance {
                AppThemePalette.set(theme)
                NotificationCenter.default.post(AppThemeDidChange(themeID: theme.id))
                let page = self.page(
                    state: .lanBound,
                    appearance: appearance,
                    credentialStorageIsShellReachable: isShellReachable
                )
                png = self.pngData(of: page.trimmedToContent().host)
            }
            let data = try XCTUnwrap(png, "\(name) rendered nothing")
            XCTAssertGreaterThan(data.count, 20_000, "\(name) rendered empty")
            let fileName = "remote-credential-storage-\(name)"
            attach(data, named: fileName)
            if let directory {
                try data.write(to: directory.appendingPathComponent("\(fileName).png"))
            }
        }
    }

    func testRendersEveryStateToImages() throws {
        let directory = Render.directory
        if let directory {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        var written: [String] = []
        for fixture in ImageFixture.allCases {
            for (name, appearanceName) in [
                ("light", NSAppearance.Name.aqua),
                ("dark", .darkAqua)
            ] {
                let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
                var png: Data?
                // Built inside the drawing appearance, not merely drawn inside it: the host's
                // own ground is a `Design` colour resolved when the fixture is assembled, and
                // built outside it every label that sits on the ground rather than on a card
                // came out dark on dark.
                appearance.performAsCurrentDrawingAppearance {
                    let page = self.page(
                        state: fixture.state,
                        width: fixture.width,
                        appearance: appearance,
                        discovery: fixture.discovery,
                        selecting: fixture.wayIn,
                        showsThreadingDirect: fixture.showsThreadingDirect
                    )
                    png = self.pngData(of: page.trimmedToContent().host)
                }
                let data = try XCTUnwrap(png, "\(fixture) rendered nothing in \(name)")
                XCTAssertGreaterThan(data.count, 20_000, "\(fixture) \(name) rendered empty")
                let fileName = "remote-access-\(fixture.fileName)-\(name)"
                attach(data, named: fileName)
                if let directory {
                    try data.write(to: directory.appendingPathComponent("\(fileName).png"))
                }
                written.append(fileName)
            }
        }
        XCTAssertEqual(written.count, ImageFixture.allCases.count * 2)
    }

    /// The panel behind every "?", photographed. The four lines left the page; this is the
    /// picture that proves they are still legible somewhere.
    func testRendersEveryHelpPanelToImages() throws {
        let directory = Render.directory
        if let directory {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        var written = 0
        for (title, wayIn) in [
            ("this-network", RemoteAccessWayIn.thisNetwork),
            ("through-a-vpn", .throughAVPN),
            ("tailscale", .tailscale)
        ] {
            for (name, appearanceName) in [
                ("light", NSAppearance.Name.aqua),
                ("dark", .darkAqua)
            ] {
                let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
                var png: Data?
                appearance.performAsCurrentDrawingAppearance {
                    png = self.pngData(of: self.helpPanelHost(
                        RemoteAccessPreferencesViewController.help(for: wayIn),
                        appearance: appearance
                    ))
                }
                let data = try XCTUnwrap(png, "\(title) rendered nothing")
                let fileName = "remote-access-help-\(title)-\(name)"
                attach(data, named: fileName)
                if let directory {
                    try data.write(to: directory.appendingPathComponent("\(fileName).png"))
                }
                written += 1
            }
        }
        XCTAssertEqual(written, 6)
    }

    /// One picture of the two long explanations that used to be the bottom third of the page.
    func testRendersTheHeroAndSharingHelpPanels() throws {
        let directory = Render.directory
        let page = self.page(state: .lanBound)
        var written = 0
        for title in ["Pairing this Mac", "Rotate or reset this Mac’s identity", "Your own devices"] {
            let button = try XCTUnwrap(help(in: page.view, titled: title), title)
            for (name, appearanceName) in [
                ("light", NSAppearance.Name.aqua),
                ("dark", .darkAqua)
            ] {
                let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
                var png: Data?
                appearance.performAsCurrentDrawingAppearance {
                    png = self.pngData(of: self.helpPanelHost(button.topic, appearance: appearance))
                }
                let data = try XCTUnwrap(png)
                let slug = title.lowercased()
                    .replacingOccurrences(of: "’", with: "")
                    .replacingOccurrences(of: " ", with: "-")
                let fileName = "remote-access-help-\(slug)-\(name)"
                attach(data, named: fileName)
                if let directory {
                    try data.write(to: directory.appendingPathComponent("\(fileName).png"))
                }
                written += 1
            }
        }
        XCTAssertEqual(written, 6)
    }

    // MARK: - Fixture

    /// The states worth a picture, which is a smaller set than it was: the ways in are one card
    /// with a run on it now, so a tailnet state is a *selection* rather than another whole page.
    enum ImageFixture: CaseIterable {
        /// Everything on and reachable, with the network panel open.
        case everythingOn
        /// The same, squeezed into a narrow pane.
        case everythingOnNarrow
        /// The tailnet panel, with the browser sub-option publishing.
        case tailnetServing
        /// A failure with its reason and its fix in the panel that failed.
        case serveNeedsHTTPS
        /// The network is there and nothing on it can reach this Mac.
        case unreachable
        /// Announced, and the network can wake this Mac. Deliberately the same picture as
        /// `everythingOn`: a bound LAN door *is* announced and wakeable, and the state is worth
        /// a file of its own so the two announcement facts can be reviewed beside `cannotWake`
        /// rather than hunted for in the happy path.
        case announcedAndCanWake
        /// Announced, and the setting that would let a proxy answer is off.
        case cannotWake
        /// Remote Access on and no way in switched on.
        case nothingOn
        /// Signed in, so Threading Direct is a segment.
        case threadingDirect

        var state: PageState {
            switch self {
            case .everythingOn, .everythingOnNarrow, .announcedAndCanWake, .cannotWake,
                 .threadingDirect:
                return .lanBound
            case .tailnetServing: return .serveServing
            case .serveNeedsHTTPS: return .serveNeedsHTTPS
            case .unreachable: return .lanNoInterface
            case .nothingOn: return .nothingOn
            }
        }

        var wayIn: RemoteAccessWayIn? {
            switch self {
            case .tailnetServing, .serveNeedsHTTPS: return .tailscale
            case .threadingDirect: return .threadingDirect
            case .everythingOn, .everythingOnNarrow, .unreachable, .announcedAndCanWake,
                 .cannotWake, .nothingOn:
                return nil
            }
        }

        var width: CGFloat {
            self == .everythingOnNarrow ? Render.narrowPageWidth : Render.pageWidth
        }

        var showsThreadingDirect: Bool { self == .threadingDirect }

        var discovery: RemoteDiscoveryPresentation? {
            switch self {
            case .announcedAndCanWake: return DiscoveryState.announcedAndCanWake.presentation
            case .cannotWake: return DiscoveryState.wakeSettingOff.presentation
            default: return nil
            }
        }

        var fileName: String {
            switch self {
            case .everythingOn: return "everything-on"
            case .everythingOnNarrow: return "everything-on-narrow"
            case .tailnetServing: return "tailnet-serving"
            case .serveNeedsHTTPS: return "serve-needs-https"
            case .unreachable: return "unreachable"
            case .announcedAndCanWake: return "announced-can-wake"
            case .cannotWake: return "cannot-wake"
            case .nothingOn: return "nothing-on"
            case .threadingDirect: return "threading-direct"
            }
        }
    }

    enum PageState: CaseIterable {
        /// The primary case: a phone on the same Wi-Fi, and a Mac with two addresses.
        case lanBound
        /// The Mac is off every network it could answer on.
        case lanNoInterface
        /// Bound, and the Application Firewall may be swallowing what arrives.
        case lanFirewalled
        /// No certificate, so nothing routable may be bound at all.
        case identityUnavailable
        /// The tailnet door, bound at this Mac's own tailnet address.
        case tailnetBound
        /// The tailnet door, still binding.
        case tailnetBinding
        /// `tailscaled` is not running, so no `utun` carries a tailnet address.
        case tailnetNotConnected
        /// There is no `tailscale` binary on this Mac at all.
        case tailnetNotInstalled
        /// The browser convenience, publishing at the `*.ts.net` name.
        case serveServing
        /// The browser convenience, refused until the tailnet enables HTTPS certificates.
        case serveNeedsHTTPS
        /// Remote Access on and no way in switched on.
        case nothingOn

        var hasBoundAddress: Bool {
            switch self {
            case .lanBound, .tailnetBound, .serveServing, .serveNeedsHTTPS: return true
            case .lanNoInterface, .lanFirewalled, .identityUnavailable, .tailnetBinding,
                 .tailnetNotConnected, .tailnetNotInstalled, .nothingOn:
                return false
            }
        }

        var thisNetworkIsOn: Bool { self != .nothingOn && !isTailnetState }

        var tailscaleIsOn: Bool { isTailnetState }

        /// The sub-option is only ever on beside a door that is up: it is a browser convenience,
        /// and a person who has not turned the tailnet way in on is not looking at it.
        var serveIsOn: Bool { self == .serveServing || self == .serveNeedsHTTPS }

        /// Which panel a state is about, so a test naming a tailnet state does not also have to
        /// remember to select the segment that shows it.
        var wayIn: RemoteAccessWayIn { isTailnetState ? .tailscale : .thisNetwork }

        private var isTailnetState: Bool {
            switch self {
            case .tailnetBound, .tailnetBinding, .tailnetNotConnected, .tailnetNotInstalled,
                 .serveServing, .serveNeedsHTTPS:
                return true
            case .lanBound, .lanNoInterface, .lanFirewalled, .identityUnavailable, .nothingOn:
                return false
            }
        }

        var doorState: RemoteAccessDoorState {
            switch self {
            case .lanBound, .lanFirewalled:
                return .bound(RemoteAccessSettingsRenderTests.bindings)
            case .lanNoInterface:
                return .notReachable(.noInterface)
            case .identityUnavailable:
                return .notReachable(.identityUnavailable)
            case .tailnetBound, .tailnetBinding, .tailnetNotConnected, .tailnetNotInstalled,
                 .serveServing, .serveNeedsHTTPS, .nothingOn:
                return .off
            }
        }

        /// What the listener bound on the tailnet, which is the whole of what the door is.
        var tailnetDoorState: RemoteAccessDoorState {
            switch self {
            case .tailnetBound, .serveServing, .serveNeedsHTTPS:
                return .bound(RemoteAccessSettingsRenderTests.tailnetBindings)
            case .tailnetBinding:
                return .binding
            case .tailnetNotConnected, .tailnetNotInstalled:
                return .notReachable(.tailscaleNotConnected)
            case .lanBound, .lanNoInterface, .lanFirewalled, .identityUnavailable, .nothingOn:
                return .off
            }
        }

        /// What `tailscale status` said, which only sharpens the sentence beside a door that is
        /// down. A bound door never consults it.
        var facts: TailscaleHostFacts {
            switch self {
            case .tailnetBound, .serveServing, .serveNeedsHTTPS:
                return TailscaleHostFacts(
                    state: .running,
                    magicDNSName: RemoteAccessSettingsRenderTests.magicDNSName
                )
            case .tailnetNotInstalled:
                return TailscaleHostFacts(state: .notInstalled, magicDNSName: nil)
            case .tailnetNotConnected:
                return TailscaleHostFacts(state: .stopped, magicDNSName: nil)
            case .tailnetBinding, .lanBound, .lanNoInterface, .lanFirewalled,
                 .identityUnavailable, .nothingOn:
                return .unknown
            }
        }

        var firewall: RemoteFirewallHint {
            self == .lanFirewalled
                ? RemoteFirewallHint(globalState: .on, applicationState: .unknown)
                : .unknown
        }

        /// Serve's readiness, which is about the browser convenience and nothing else.
        var readiness: TailscaleReadiness {
            switch self {
            case .serveNeedsHTTPS:
                return .actionRequired(.httpsRequired, actionURL: approvalURL)
            case .serveServing:
                return .ready(serveOrigin)
            case .lanBound, .lanNoInterface, .lanFirewalled, .identityUnavailable, .tailnetBound,
                 .tailnetBinding, .tailnetNotConnected, .tailnetNotInstalled, .nothingOn:
                return .notChecked
            }
        }

        var transport: RemoteTransportState {
            switch self {
            case .serveNeedsHTTPS:
                return .unavailable(TailscaleReadinessIssue.httpsRequired.message)
            case .serveServing:
                return .connected(serveOrigin)
            case .lanBound, .lanNoInterface, .lanFirewalled, .identityUnavailable, .tailnetBound,
                 .tailnetBinding, .tailnetNotConnected, .tailnetNotInstalled, .nothingOn:
                return .stopped
            }
        }

        /// A code exists exactly when something is answering at an address it can name.
        var payload: String? {
            hasBoundAddress ? RemoteAccessSettingsRenderTests.payload : nil
        }

        var identity: RemoteIdentityCardPresentation {
            self == .identityUnavailable
                ? RemoteIdentityCardPresentation(
                    pairingCode: nil,
                    nextPairingCode: nil,
                    failure: RemoteIdentityCardPresentation.resolve(
                        RemoteAccessIdentitySnapshot(
                            fingerprint: nil,
                            nextFingerprint: nil,
                            failure: .unreadable
                        )
                    ).failure
                )
                : RemoteAccessSettingsRenderTests.identity
        }

        /// What the announcement is doing in this page state, when a test does not say.
        ///
        /// Announced exactly when the `lan` door has an address under it: the registration rides
        /// on that door's listeners and nowhere else, so a page with the tailnet door up and the
        /// LAN door off has the switch on and nothing on the network.
        var discovery: RemoteDiscoveryPresentation {
            hasBoundAddress && thisNetworkIsOn
                ? DiscoveryState.announcedAndCanWake.presentation
                : RemoteDiscoveryPresentation(
                    isEnabled: true,
                    announcedName: nil,
                    wakeFacts: .unknown
                )
        }

        private var approvalURL: URL { RemoteAccessSettingsRenderTests.approvalURL }
        private var serveOrigin: URL {
            URL(string: "https://\(RemoteAccessSettingsRenderTests.magicDNSName):8443/")!
        }
    }

    /// The announcement and the wake facts, as the five states a person can be looking at.
    enum DiscoveryState: CaseIterable {
        case announcedAndCanWake
        case off
        case wakeSettingOff
        case noSleepProxy
        case notChecked

        var presentation: RemoteDiscoveryPresentation {
            switch self {
            case .announcedAndCanWake:
                return RemoteDiscoveryPresentation(
                    isEnabled: true,
                    announcedName: RemoteAccessSettingsRenderTests.instanceName,
                    wakeFacts: RemoteAccessSettingsRenderTests.wakeFacts(true, true)
                )
            case .off:
                // Both wake facts hold and nothing is registered, which is the combination that
                // would have printed a green "can wake" through a service that does not exist.
                return RemoteDiscoveryPresentation(
                    isEnabled: false,
                    announcedName: nil,
                    wakeFacts: RemoteAccessSettingsRenderTests.wakeFacts(true, true)
                )
            case .wakeSettingOff:
                return RemoteDiscoveryPresentation(
                    isEnabled: true,
                    announcedName: RemoteAccessSettingsRenderTests.instanceName,
                    wakeFacts: RemoteAccessSettingsRenderTests.wakeFacts(false, true)
                )
            case .noSleepProxy:
                return RemoteDiscoveryPresentation(
                    isEnabled: true,
                    announcedName: RemoteAccessSettingsRenderTests.instanceName,
                    wakeFacts: RemoteAccessSettingsRenderTests.wakeFacts(true, false)
                )
            case .notChecked:
                return RemoteDiscoveryPresentation(
                    isEnabled: true,
                    announcedName: RemoteAccessSettingsRenderTests.instanceName,
                    wakeFacts: .unknown
                )
            }
        }
    }

    /// The opaque instance name a Mac broadcasts, as `RemoteDiscoveryDefaults` derives one.
    nonisolated private static let instanceName = RemoteDiscoveryDefaults.instanceName(
        hostID: "6B0C6A4E-1C6E-4A5B-9F4E-9C2A2E9E5A11"
    )

    nonisolated private static func wakeFacts(
        _ womp: Bool?,
        _ proxy: Bool?
    ) -> RemoteWakeOnDemandFacts {
        RemoteWakeOnDemandFacts(
            wakeForNetworkAccess: womp,
            sleepProxyPresent: proxy,
            readAt: Date(timeIntervalSince1970: 1_760_000_000)
        )
    }

    private struct Page {
        let controller: RemoteAccessPreferencesViewController
        let window: NSWindow
        let host: NSView
        var view: NSView { controller.view }
        var marks: [ThemedSegmentedControl.SegmentMark?] {
            (([host] + host.subviews.flatMap { RemoteAccessSettingsRenderTests.walk($0) })
                .compactMap { $0 as? ThemedSegmentedControl }
                .first { $0.accessibilityIdentifier()
                    == RemoteAccessPreferencesViewController.Identifier.waysInControl })?
                .marks ?? []
        }

        /// Shrinks the pane to the page standing in it, so a picture is of the page rather than
        /// of the empty pane below it.
        ///
        /// Only ever shorter, and never shorter than the content: the tall fixture exists so the
        /// whole page is inside the scroll view's clip in one frame, and cutting into it would
        /// photograph a page the reviewer has to guess the bottom of.
        /// `testTheTallFixtureIsOnlyATallerPane` is why this is safe to do to a picture — the
        /// pane's height decides how much of the page is in the frame and nothing else.
        @MainActor
        func trimmedToContent() -> Page {
            guard let scroll = (RemoteAccessSettingsRenderTests.walk(view)
                .compactMap { $0 as? NSScrollView }.first),
                  let document = scroll.documentView else { return self }
            let chrome = view.frame.height - scroll.frame.height
            let needed = (chrome + document.fittingSize.height).rounded(.up)
            guard needed > 0, needed < host.frame.height else { return self }
            host.setFrameSize(NSSize(width: host.frame.width, height: needed))
            host.layoutSubtreeIfNeeded()
            return self
        }
    }

    nonisolated private static func walk(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { walk($0) }
    }

    /// The page in one state, hosted the way the app hosts it, laid out and ready to photograph.
    ///
    /// Every value comes in through `apply`, so nothing here reads the developer's own settings
    /// or asks the machine running the test what networks it is on. The window is never ordered
    /// on screen: none of this needs to be visible, and it stays in the fast lane.
    private func page(
        state: PageState,
        width: CGFloat = Render.pageWidth,
        height: CGFloat = Render.height,
        appearance: NSAppearance? = nil,
        credentialStorageIsShellReachable: Bool = KeychainStoragePolicy.isShellReachable,
        identity: RemoteIdentityCardPresentation? = nil,
        discovery: RemoteDiscoveryPresentation? = nil,
        selecting wayIn: RemoteAccessWayIn? = nil,
        showsThreadingDirect: Bool = false
    ) -> Page {
        let controller = RemoteAccessPreferencesViewController(
            credentialStorageIsShellReachable: credentialStorageIsShellReachable
        )
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: Render.paneWidth(for: width),
                height: height
            ),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        // The pane is sized by the split view it lives in, so the page's preferred width is a
        // *preference* there and simply breaks in a narrower pane. A window's content view has
        // nothing holding it, and Auto Layout grows the window to that preference instead —
        // which rendered the squeezed pane at the full width and said nothing about it. So the
        // pane stands inside the content view rather than being it: its frame is its own, the
        // window is only the ancestor that makes the tree lay out the way the app's does.
        let size = NSSize(width: Render.paneWidth(for: width), height: height)
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = root
        let host = NSView(frame: NSRect(origin: .zero, size: size))
        root.addSubview(host)
        if let appearance {
            window.appearance = appearance
            host.appearance = appearance
            controller.view.appearance = appearance
        }
        host.wantsLayer = true
        host.layer?.backgroundColor = Design.Surface.ground.cgColor

        // **The app's own call, not a copy of it.** `SettingsUI.install(page:in:top:)` is where
        // the Settings shell pins a destination into its pane, and this fixture calls the same
        // function with the same arguments. The two used to be two sets of constraints written
        // twice, they drifted, and the drift is the defect this whole file is the boundary for.
        SettingsUI.install(page: controller.view, in: host)

        apply(state, to: controller, identity: identity, discovery: discovery,
              showsThreadingDirect: showsThreadingDirect)
        controller.select(wayIn ?? state.wayIn)

        AppThemeRefresh.repaint(host)
        host.layoutSubtreeIfNeeded()
        return Page(controller: controller, window: window, host: host)
    }

    /// The fixture this file used to be: the page pinned to a bare view's four edges, laid out
    /// once. Kept for exactly one test — the one that holds it against the app's own shape.
    private func detachedPage(state: PageState, width: CGFloat = Render.pageWidth) -> Page {
        let controller = RemoteAccessPreferencesViewController()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: Render.height))
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: host.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            controller.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
        host.wantsLayer = true
        host.layer?.backgroundColor = Design.Surface.ground.cgColor
        apply(state, to: controller, identity: nil, discovery: nil, showsThreadingDirect: false)
        controller.select(state.wayIn)
        AppThemeRefresh.repaint(host)
        host.layoutSubtreeIfNeeded()
        return Page(
            controller: controller,
            window: NSWindow(),
            host: host
        )
    }

    private func apply(
        _ state: PageState,
        to controller: RemoteAccessPreferencesViewController,
        identity: RemoteIdentityCardPresentation?,
        discovery: RemoteDiscoveryPresentation?,
        showsThreadingDirect: Bool
    ) {
        let statuses: [RemoteAccessWayIn: RemoteDoorStatus] = [
            .thisNetwork: .thisNetwork(
                isEnabled: state.thisNetworkIsOn,
                state: state.doorState,
                firewall: state.firewall
            ),
            .tailscale: .tailscale(
                isEnabled: state.tailscaleIsOn,
                state: state.tailnetDoorState,
                facts: state.facts
            ),
            .threadingDirect: .threadingDirect(showsThreadingDirect ? .ready : .stopped)
        ]
        let doors = RemoteAccessDoorsPresentation(
            isRemoteAccessOn: true,
            thisNetworkIsOn: state.thisNetworkIsOn,
            tailscaleIsOn: state.tailscaleIsOn,
            tailscaleServeIsOn: state.serveIsOn,
            showsThreadingDirect: showsThreadingDirect,
            statuses: statuses,
            serveStatus: .tailscaleServe(
                isEnabled: state.serveIsOn,
                transport: state.transport,
                readiness: state.readiness
            ),
            serveRemedy: RemoteDoorStatus.serveRemedy(state.readiness),
            tailnetReadiness: .resolve(
                isEnabled: state.tailscaleIsOn,
                facts: state.facts,
                doorState: state.tailnetDoorState,
                doorStatus: statuses[.tailscale] ?? .remoteAccessOff()
            ),
            identity: identity ?? state.identity
        )
        controller.apply(doors)
        controller.apply(discovery ?? state.discovery)
        controller.applyListeningState(
            connection: RemoteConnectionStatusPresentation.resolve(
                statuses: doors.offeredStatuses,
                localPort: Self.listenerPort
            ),
            card: RemotePairingCardState.resolve(
                ownerDevicePersistenceError: nil,
                pairingCodePayload: state.payload,
                wayIn: RemotePairingCardState.mostAdvanced(of: doors.offeredStatuses),
                hasWayIn: state.thisNetworkIsOn || state.tailscaleIsOn
            )
        )
    }

    /// One help panel on a card-coloured ground, sized the way a popover sizes it.
    ///
    /// The height is the panel's own, taken after a layout pass rather than guessed: these
    /// explanations run from two lines to two paragraphs, and one fixed frame would either cut
    /// the long ones off or print the short ones on a field of empty panel.
    private func helpPanelHost(_ topic: HelpTopic, appearance: NSAppearance) -> NSView {
        let content = HelpPopoverButton(topic: topic).makeContent()
        let inset = Design.Spacing.inset
        let host = NSView(frame: NSRect(
            x: 0,
            y: 0,
            width: HelpPopoverMetrics.contentWidth + inset * 2,
            height: 240
        ))
        host.appearance = appearance
        host.wantsLayer = true
        host.layer?.backgroundColor = Design.Surface.panel.cgColor
        content.view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(content.view)
        NSLayoutConstraint.activate([
            content.view.leadingAnchor.constraint(
                equalTo: host.leadingAnchor,
                constant: inset
            ),
            content.view.topAnchor.constraint(
                equalTo: host.topAnchor,
                constant: inset
            )
        ])
        AppThemeRefresh.repaint(host)
        host.layoutSubtreeIfNeeded()
        host.setFrameSize(NSSize(
            width: host.frame.width,
            height: (content.view.fittingSize.height + inset * 2).rounded(.up)
        ))
        host.layoutSubtreeIfNeeded()
        return host
    }

    // MARK: - Helpers

    private func pngData(of view: NSView) -> Data? {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    private func attach(_ data: Data, named name: String) {
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// A view's visible ink in `host`'s coordinates. `NSStackView` aligns alignment rects, so
    /// this is also what its alignment actually produced.
    private func ink(of view: NSView, in host: NSView) -> NSRect {
        let rect = view.alignmentRect(forFrame: view.frame)
        guard let parent = view.superview else { return rect }
        return parent.convert(rect, to: host)
    }

    /// Every visible label's ink, keyed by what it says. The comparison two hosts are held to.
    private func labelInk(in root: NSView) -> [String: NSRect] {
        var result: [String: NSRect] = [:]
        for label in allLabels(in: root)
        where !isEffectivelyHidden(label) && !label.stringValue.isEmpty {
            result[label.stringValue] = ink(of: label, in: root)
        }
        return result
    }

    private func descendants(in view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(in: $0) }
    }

    private func view(in root: NSView, id: String) -> NSView? {
        ([root] + descendants(in: root)).first { $0.accessibilityIdentifier() == id }
    }

    /// A row hidden by its container is as absent as one hidden by itself.
    private func isEffectivelyHidden(_ view: NSView) -> Bool {
        var candidate: NSView? = view
        while let current = candidate {
            if current.isHidden { return true }
            candidate = current.superview
        }
        return false
    }

    private func label(in root: NSView, id: String) -> NSTextField? {
        view(in: root, id: id) as? NSTextField
    }

    private func button(in root: NSView, id: String) -> ThemedButton? {
        view(in: root, id: id) as? ThemedButton
    }

    private func imageView(in root: NSView, id: String) -> NSImageView? {
        view(in: root, id: id) as? NSImageView
    }

    private func allLabels(in root: NSView) -> [NSTextField] {
        ([root] + descendants(in: root)).compactMap { $0 as? NSTextField }
    }

    private func helpButtons(in root: NSView) -> [HelpPopoverButton] {
        ([root] + descendants(in: root)).compactMap { $0 as? HelpPopoverButton }
    }

    private func help(in root: NSView, titled title: String) -> HelpPopoverButton? {
        helpButtons(in: root).first { $0.topic.title == title }
    }

    private func segmentTitles(in root: NSView) -> [String] {
        (([root] + descendants(in: root)).compactMap { $0 as? ThemedSegmentedControl }
            .first {
                $0.accessibilityIdentifier()
                    == RemoteAccessPreferencesViewController.Identifier.waysInControl
            })?.titles ?? []
    }

    private func marks(in root: NSView) -> [ThemedSegmentedControl.SegmentMark?] {
        (([root] + descendants(in: root)).compactMap { $0 as? ThemedSegmentedControl }
            .first {
                $0.accessibilityIdentifier()
                    == RemoteAccessPreferencesViewController.Identifier.waysInControl
            })?.marks ?? []
    }

    private func mark(in root: NSView, for wayIn: RemoteAccessWayIn) -> String? {
        label(
            in: root,
            id: RemoteAccessPreferencesViewController.Identifier.statusMark(wayIn)
        )?.stringValue
    }

    private func statusDetail(in root: NSView) -> String? {
        guard let title = label(in: root, id: "settings.remote-access.status"),
              let row = title.superview else { return nil }
        return allLabels(in: row).first { $0 !== title }?.stringValue
    }

    private func card(containing view: NSView) -> SettingsCard? {
        var candidate: NSView? = view
        while let current = candidate {
            if let card = current as? SettingsCard { return card }
            candidate = current.superview
        }
        return nil
    }
}
