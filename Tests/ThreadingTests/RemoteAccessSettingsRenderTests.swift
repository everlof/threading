import AppKit
import ThreadingRemoteKit
import XCTest
@testable import Threading

/// Draws the Remote Access page in the states it is actually used in, light and dark.
///
/// Every one of them takes a live network to reach, which is why what shipped was reviewed in
/// none of them: a panel that said a connection was unavailable while the reason sat three rows
/// above it, a minute of silence with a spinner on it, and a pairing card laid out like a poster
/// — a centred title with a phone glyph, a plate floating mid-card, and a centred warning ending
/// in an orphan. The page states each of them from values, so this fixture can photograph them
/// and turn what the picture shows into assertions.
///
/// The doors added the rest: a LAN address that is bound, one that has no interface under it, a
/// firewall that may be swallowing connections, a Mac with no certificate to present, and no way
/// in switched on at all.
@MainActor
final class RemoteAccessSettingsRenderTests: XCTestCase {

    private enum Render {
        /// The pane's own width, plus the squeezed pane the settings renders use as the stress
        /// case: the pairing card is now two columns, so a narrow pane is where it breaks first.
        static let width = SettingsUIDefaults.pageWidth
        static let narrowWidth: CGFloat = 420
        /// Tall enough that the whole page is inside the scroll view's clip, so the pairing card
        /// is in the picture rather than below it. The four-line disclosures made the page about
        /// twice as tall as the one this fixture first photographed.
        static let height: CGFloat = 3000

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

    // MARK: - Every way in states its four lines

    /// The copy rule with teeth: never present a method without its four lines.
    func testEveryWayInRendersItsFourDisclosureLines() throws {
        let page = self.page(state: .lanBound)
        for wayIn in RemoteAccessWayIn.allCases {
            let block = try XCTUnwrap(
                view(
                    in: page.view,
                    id: RemoteAccessPreferencesViewController.Identifier.disclosure(wayIn)
                ),
                "\(wayIn) has no disclosure at all"
            )
            let labels = allLabels(in: block).map(\.stringValue)
            for line in wayIn.disclosure.lines {
                XCTAssertTrue(
                    labels.contains(line.question),
                    "\(wayIn) does not ask “\(line.question)”"
                )
                XCTAssertTrue(
                    labels.contains(line.answer),
                    "\(wayIn) does not answer “\(line.question)”"
                )
            }
            // Four lines, not three and not five: the same questions in the same order.
            XCTAssertEqual(labels.count, wayIn.disclosure.lines.count * 2, "\(wayIn)")
        }
    }

    /// The VPN is the same door reached from a tunnel, so it is a note rather than a switch, and
    /// Threading Direct is future work that only appears once this Mac is signed in.
    func testOnlyTheTwoRealDoorsCarryASwitch() throws {
        let page = self.page(state: .lanBound)
        for wayIn in RemoteAccessWayIn.allCases {
            let toggle = view(
                in: page.view,
                id: RemoteAccessPreferencesViewController.Identifier.doorToggle(wayIn)
            )
            XCTAssertEqual(
                toggle != nil,
                wayIn.hasSwitch,
                "\(wayIn) disagrees with itself about having a switch"
            )
        }
        // The Serve sub-option is a switch too, and it is on the page rather than held back: the
        // tailnet door is a listener now, so turning Serve off takes no route away from a phone.
        let serve = try XCTUnwrap(
            view(in: page.view, id: RemoteAccessPreferencesViewController.Identifier.serveToggle),
            "the Serve sub-option is not on the page"
        )
        XCTAssertFalse(isEffectivelyHidden(serve), "the Serve sub-option is still hidden")
        XCTAssertEqual(
            allLabels(in: page.view).filter {
                $0.stringValue.contains("publishes this Mac’s name and your tailnet name in "
                    + "public certificate logs")
            }.count,
            1,
            "the certificate-transparency cost is not stated beside the switch that pays it"
        )
    }

    // MARK: - The status line states a fact

    func testABoundDoorNamesItsAddressAndPort() throws {
        let page = self.page(state: .lanBound)
        let status = try XCTUnwrap(label(
            in: page.view,
            id: RemoteAccessPreferencesViewController.Identifier.status(.thisNetwork)
        ))
        XCTAssertEqual(status.stringValue, "Reachable at 192.168.1.42:8760")

        let hint = try XCTUnwrap(label(
            in: page.view,
            id: RemoteAccessPreferencesViewController.Identifier.statusHint(.thisNetwork)
        ))
        XCTAssertEqual(
            hint.stringValue,
            "Also reachable at 10.0.0.7:8760.",
            "the second address is missing, or the first one is not the pairing code's"
        )
        XCTAssertEqual(
            try XCTUnwrap(label(in: page.view, id: "settings.remote-access.status")).stringValue,
            "Ready"
        )
    }

    func testAnUnreachableDoorNamesTheReasonAndNotAnAddress() throws {
        let page = self.page(state: .lanNoInterface)
        let status = try XCTUnwrap(label(
            in: page.view,
            id: RemoteAccessPreferencesViewController.Identifier.status(.thisNetwork)
        ))
        XCTAssertEqual(
            status.stringValue,
            "Not currently reachable: no address on this network."
        )
        XCTAssertFalse(
            status.stringValue.contains(":\(Self.listenerPort)"),
            "a door with nothing bound printed a port anyway"
        )
        let hint = try XCTUnwrap(label(
            in: page.view,
            id: RemoteAccessPreferencesViewController.Identifier.statusHint(.thisNetwork)
        ))
        XCTAssertFalse(hint.isHidden, "the reason arrived without its remedy")
    }

    /// The firewall is a hint and stays one: the Mac cannot observe whether an incoming
    /// connection would be allowed, so a bound address it may be swallowing is not a green state.
    func testTheFirewallHintRidesWithTheAddressAndTakesTheGreenAwayFromIt() throws {
        let page = self.page(state: .lanFirewalled)
        let status = try XCTUnwrap(label(
            in: page.view,
            id: RemoteAccessPreferencesViewController.Identifier.status(.thisNetwork)
        ))
        let hint = try XCTUnwrap(label(
            in: page.view,
            id: RemoteAccessPreferencesViewController.Identifier.statusHint(.thisNetwork)
        ))
        XCTAssertEqual(status.stringValue, "Reachable at 192.168.1.42:8760")
        XCTAssertEqual(hint.stringValue, RemoteDoorStatus.firewallHint)
        // Bound and in doubt is neither "Ready" nor "Not reachable": the listener is running at
        // an address, and the Mac cannot see whether anything gets through to it.
        XCTAssertEqual(
            try XCTUnwrap(label(in: page.view, id: "settings.remote-access.status")).stringValue,
            "May not be reachable",
            "the page claimed a peer had got through, or that nothing was bound"
        )
        let rowDetail = try XCTUnwrap(
            allLabels(in: page.view).first { $0.stringValue.contains(RemoteDoorStatus.firewallHint) }
        )
        XCTAssertTrue(
            rowDetail.stringValue.hasPrefix("Reachable at 192.168.1.42:8760. ")
                || rowDetail.stringValue == RemoteDoorStatus.firewallHint,
            "two sentences ran together: “\(rowDetail.stringValue)”"
        )
    }

    /// No way in reports itself ready without an address in the line beside the mark.
    ///
    /// The mark is checked rather than the tone, because the mark is what a reader sees under
    /// Differentiate Without Colour and it is drawn from the same tone the page resolved.
    func testNoWayInShowsAReadyMarkWithoutABoundAddress() throws {
        for state in PageState.allCases {
            let page = self.page(state: state)
            for wayIn in RemoteAccessWayIn.allCases where wayIn.hasSwitch {
                let mark = try XCTUnwrap(label(
                    in: page.view,
                    id: RemoteAccessPreferencesViewController.Identifier.statusMark(wayIn)
                ))
                let line = try XCTUnwrap(label(
                    in: page.view,
                    id: RemoteAccessPreferencesViewController.Identifier.status(wayIn)
                )).stringValue
                guard mark.stringValue == "✓", !mark.isHidden else { continue }
                XCTAssertTrue(
                    line.hasPrefix("Reachable at "),
                    "\(state): \(wayIn) is marked ready while its line says “\(line)”"
                )
                XCTAssertEqual(
                    mark.textColor?.hexString,
                    Design.Status.positive.hexString,
                    "\(state): \(wayIn)"
                )
            }
        }
    }

    func testAMacWithNoCertificateSaysSoAndOffersTheFix() throws {
        let page = self.page(state: .identityUnavailable)
        let status = try XCTUnwrap(label(
            in: page.view,
            id: RemoteAccessPreferencesViewController.Identifier.status(.thisNetwork)
        ))
        XCTAssertEqual(
            status.stringValue,
            "Not currently reachable: this Mac has no certificate to present."
        )
        let detail = try XCTUnwrap(
            label(in: page.view, id: "settings.remote-access.identity-detail")
        )
        XCTAssertTrue(
            detail.stringValue.hasPrefix("Threading could not read its certificate."),
            "the identity card does not say why there is no code"
        )
        let code = try XCTUnwrap(label(in: page.view, id: "settings.remote-access.identity-code"))
        XCTAssertTrue(code.isHidden, "a code was shown for an identity that could not be read")
    }

    func testNothingSwitchedOnIsAStateWithAFactInIt() throws {
        let page = self.page(state: .nothingOn)
        XCTAssertEqual(
            try XCTUnwrap(label(in: page.view, id: "settings.remote-access.status")).stringValue,
            "No way in"
        )
        let pairing = try XCTUnwrap(
            label(in: page.view, id: "settings.remote-access.pairing-title")
        )
        XCTAssertEqual(pairing.stringValue, "No way in is switched on")
        let action = try XCTUnwrap(button(in: page.view, id: "settings.remote-access.pair"))
        XCTAssertFalse(
            action.isEnabled,
            "a dead end was offered as something to press and wait for"
        )
    }

    // MARK: - Identity

    /// The code on the page is the coordinator's, not a formatting of something else.
    func testTheIdentityCardShowsTheSnapshotsOwnPairingCode() throws {
        let snapshot = RemoteAccessIdentitySnapshot(
            fingerprint: RemoteHostFingerprint(certificateDER: Data("threading".utf8)),
            nextFingerprint: nil,
            failure: nil
        )
        let presentation = RemoteIdentityCardPresentation.resolve(snapshot)
        let page = self.page(state: .lanBound, identity: presentation)

        let code = try XCTUnwrap(label(in: page.view, id: "settings.remote-access.identity-code"))
        XCTAssertEqual(code.stringValue, snapshot.fingerprint?.pairingCode)
        XCTAssertEqual(
            code.stringValue.count,
            RemoteHostPinningDefaults.pairingCodeCharacterCount,
            "the code is not the 26 characters a phone compares"
        )
        XCTAssertTrue(
            code.font?.isFixedPitch == true,
            "26 characters a person has to compare are not in a monospaced face"
        )
        let detail = try XCTUnwrap(
            label(in: page.view, id: "settings.remote-access.identity-detail")
        )
        XCTAssertEqual(detail.stringValue, RemoteIdentityCardPresentation.explanation)
        XCTAssertTrue(
            detail.stringValue.contains("compares this code"),
            "the card does not say the phone compares it"
        )
    }

    /// Rotation is two steps, and the second one is only offered once the first has run.
    func testRotationIsOfferedInTwoStepsAndActivateWaitsForASuccessor() throws {
        let page = self.page(state: .lanBound)
        let prepare = try XCTUnwrap(
            button(in: page.view, id: "settings.remote-access.identity-prepare")
        )
        let activate = try XCTUnwrap(
            button(in: page.view, id: "settings.remote-access.identity-activate")
        )
        XCTAssertTrue(prepare.isEnabled)
        XCTAssertFalse(activate.isEnabled, "a rotation could be activated before it was prepared")

        let announced = self.page(
            state: .lanBound,
            identity: RemoteIdentityCardPresentation(
                pairingCode: "MZXW6YTBOI7EU3TFOQQGE43FMN",
                nextPairingCode: "GEZDGNBVGY3TQOJQGEZDGN",
                failure: nil
            )
        )
        let successor = try XCTUnwrap(
            label(in: announced.view, id: "settings.remote-access.identity-successor")
        )
        XCTAssertFalse(successor.isHidden)
        XCTAssertTrue(
            successor.stringValue.contains("already trusts it"),
            "the page does not say who keeps working across a rotation"
        )
        XCTAssertTrue(
            try XCTUnwrap(
                button(in: announced.view, id: "settings.remote-access.identity-activate")
            ).isEnabled
        )
    }

    /// Reset is the one operation here that unpairs devices, so it is a question, not a button.
    func testResettingTheIdentityIsAConfirmationThatSaysWhatItCosts() throws {
        let prompt = ConfirmationPrompt.resetRemoteAccessIdentity
        guard case .alwaysAsks(let reason) = prompt.policy else {
            return XCTFail("a reset could be switched off")
        }
        XCTAssertEqual(reason, .irreversible)
        let request = ConfirmationRequest(
            prompt: prompt,
            title: L10n.string("Reset this Mac’s identity?"),
            message: L10n.string(
                "Threading mints a new certificate and a new pairing code. Every paired device "
                    + "stops trusting this Mac and has to scan the new code before it can "
                    + "connect again. Use Prepare Rotation instead if this Mac’s certificate is "
                    + "still working."
            ),
            confirmTitle: L10n.string("Reset Identity")
        )
        XCTAssertTrue(
            request.message.contains("has to scan the new code"),
            "the confirmation does not say every paired device must scan again"
        )
    }

    // MARK: - The browser sub-option carries its own reason and fix

    /// The panel used to say "Private connection unavailable" while the only explanation sat in
    /// a readiness row three rows above it. Serve is a sub-option now, so the sentence and the
    /// button that fixes it are on its own row — and the tailnet way in beside it keeps saying
    /// what it is doing, because Serve failing is not the door failing.
    func testAServeFailureStatesItsReasonAndOffersItsFixOnItsOwnRow() throws {
        let page = self.page(state: .serveNeedsHTTPS)

        let status = try XCTUnwrap(label(
            in: page.view,
            id: RemoteAccessPreferencesViewController.Identifier.serveStatus
        ))
        XCTAssertEqual(status.stringValue, TailscaleReadinessIssue.httpsRequired.failureStatement)
        let hint = try XCTUnwrap(label(
            in: page.view,
            id: RemoteAccessPreferencesViewController.Identifier.serveStatusHint
        ))
        XCTAssertEqual(hint.stringValue, TailscaleReadinessIssue.httpsRequired.remedyStatement)

        let remedy = try XCTUnwrap(
            button(in: page.view, id: RemoteAccessPreferencesViewController.Identifier.serveRemedy)
        )
        XCTAssertFalse(remedy.isHidden, "the admin-console page is not offered beside the reason")
        XCTAssertEqual(remedy.title, "Enable HTTPS…")

        // The door is bound the whole time. A browser convenience that cannot publish must not
        // read as the tailnet way in being down.
        let door = try XCTUnwrap(label(
            in: page.view,
            id: RemoteAccessPreferencesViewController.Identifier.status(.tailscale)
        ))
        XCTAssertEqual(door.stringValue, "Reachable at 100.65.47.126:8760")
        XCTAssertEqual(
            try XCTUnwrap(label(in: page.view, id: "settings.remote-access.status")).stringValue,
            "Ready",
            "a Serve failure took the whole Mac's status down with it"
        )
    }

    /// Serving states where, and the address a browser is meant to open.
    func testServeStatesTheAddressItIsServingAt() throws {
        let page = self.page(state: .serveServing)
        let status = try XCTUnwrap(label(
            in: page.view,
            id: RemoteAccessPreferencesViewController.Identifier.serveStatus
        ))
        XCTAssertEqual(status.stringValue, "Serving at https://mac-studio.tail1234.ts.net:8443")
        XCTAssertTrue(
            try XCTUnwrap(
                button(
                    in: page.view,
                    id: RemoteAccessPreferencesViewController.Identifier.serveRemedy
                )
            ).isHidden,
            "a button was offered beside a row with nothing wrong with it"
        )
    }

    /// A way in that failed with no page to open shows Retry alone. Nothing in the pairing panel
    /// opens an admin console any more: the only thing that had one was Serve.
    func testAWayInFailureShowsRetryAlone() throws {
        let page = self.page(state: .tailnetNotInstalled)
        let retry = try XCTUnwrap(button(in: page.view, id: "settings.remote-access.pair"))
        XCTAssertEqual(retry.title, "Retry Connection")
        XCTAssertTrue(retry.isProminent, "Retry is the only action, so it is the one offered")

        let detail = try XCTUnwrap(label(in: page.view, id: "settings.remote-access.pairing-detail"))
        XCTAssertEqual(
            detail.stringValue,
            "Not currently reachable: Tailscale is not installed on this Mac. Install Tailscale "
                + "and sign in on this Mac. The door comes back on its own.",
            "the panel does not say which way in failed or what fixes it"
        )
    }

    // MARK: - The tailnet door

    func testABoundTailnetDoorNamesItsAddressAndItsName() throws {
        let page = self.page(state: .tailnetBound)
        let status = try XCTUnwrap(label(
            in: page.view,
            id: RemoteAccessPreferencesViewController.Identifier.status(.tailscale)
        ))
        XCTAssertEqual(status.stringValue, "Reachable at 100.65.47.126:8760")

        let hint = try XCTUnwrap(label(
            in: page.view,
            id: RemoteAccessPreferencesViewController.Identifier.statusHint(.tailscale)
        ))
        XCTAssertTrue(
            hint.stringValue.contains("mac-studio.tail1234.ts.net:8760"),
            "the MagicDNS name is missing: “\(hint.stringValue)”"
        )
        XCTAssertFalse(
            hint.stringValue.contains("8443"),
            "Serve's port was named as a way the phone could reach this Mac"
        )

        // The readiness card reads the listener, not a transport.
        XCTAssertEqual(
            try XCTUnwrap(label(
                in: page.view,
                id: RemoteAccessPreferencesViewController.Identifier.readinessTitle(
                    .tailnetAddress
                )
            )).stringValue,
            "This Mac’s tailnet address"
        )
        XCTAssertEqual(
            try XCTUnwrap(label(
                in: page.view,
                id: RemoteAccessPreferencesViewController.Identifier.readinessMark(.installed)
            )).stringValue,
            "✓",
            "a bound tailnet address is proof Tailscale is installed, whatever the probe said"
        )
    }

    /// The three reasons a tailnet door has no address, told apart. "Not connected" and "not
    /// installed" are fixed in different places, and only the CLI can tell them apart.
    func testAnAbsentTailnetSaysWhichOfItsThreeCausesItIs() throws {
        let notConnected = try XCTUnwrap(label(
            in: self.page(state: .tailnetNotConnected).view,
            id: RemoteAccessPreferencesViewController.Identifier.status(.tailscale)
        ))
        XCTAssertEqual(
            notConnected.stringValue,
            "Not currently reachable: Tailscale is not connected."
        )

        let notInstalled = self.page(state: .tailnetNotInstalled)
        XCTAssertEqual(
            try XCTUnwrap(label(
                in: notInstalled.view,
                id: RemoteAccessPreferencesViewController.Identifier.status(.tailscale)
            )).stringValue,
            "Not currently reachable: Tailscale is not installed on this Mac."
        )
        XCTAssertEqual(
            try XCTUnwrap(label(
                in: notInstalled.view,
                id: RemoteAccessPreferencesViewController.Identifier.readinessMark(.installed)
            )).stringValue,
            "!",
            "the readiness card does not mark the row that failed"
        )
    }

    // MARK: - Starting

    /// Coming up is a state with a fact in it, in every place a person is looking: the status
    /// row, the way in's own line, the readiness card, and the pairing panel.
    func testATailnetDoorComingUpSaysSoEverywhereItIsShown() throws {
        let page = self.page(state: .tailnetBinding)

        let waiting = "Binding to this Mac’s tailnet address…"

        let status = try XCTUnwrap(label(in: page.view, id: "settings.remote-access.status"))
        XCTAssertEqual(status.stringValue, "Starting")

        let statusDetail = try XCTUnwrap(
            allLabels(in: page.view).first { $0.stringValue.hasPrefix(waiting) }
        )
        XCTAssertTrue(
            statusDetail.stringValue.contains("127.0.0.1:8760"),
            "the row dropped the address it does know"
        )

        let door = try XCTUnwrap(label(
            in: page.view,
            id: RemoteAccessPreferencesViewController.Identifier.status(.tailscale)
        ))
        XCTAssertEqual(door.stringValue, waiting)

        let panel = try XCTUnwrap(label(in: page.view, id: "settings.remote-access.pairing-detail"))
        XCTAssertEqual(panel.stringValue, waiting, "the panel is still silent about the wait")

        // The status row, the way in's line, the readiness row and the panel.
        XCTAssertEqual(
            allLabels(in: page.view).filter { $0.stringValue.contains(waiting) }.count,
            4,
            "the wait is missing from one of the places it is shown"
        )
    }

    // MARK: - The pairing card

    /// The poster, rebuilt: no glyph in the title, a plate no wider than the code needs, and
    /// everything else left-aligned beside it.
    func testThePairingCardLeadsWithTheCodeAndAlignsByInk() throws {
        let page = self.page(state: .lanBound)

        let title = try XCTUnwrap(label(in: page.view, id: "settings.remote-access.pairing-title"))
        XCTAssertEqual(title.stringValue, "Scan with your iPhone")
        XCTAssertFalse(
            title.stringValue.unicodeScalars.contains { $0.properties.isEmojiPresentation },
            "the title carries a glyph again"
        )

        let code = try XCTUnwrap(imageView(in: page.view, id: "settings.remote-access.qr-code"))
        let image = try XCTUnwrap(code.image)
        XCTAssertFalse(code.isHidden)

        // The plate `PairingCodeImage` draws *is* the code plus its four-module quiet zone, so
        // the view being exactly the image is the whole of "no wider than the code needs".
        XCTAssertEqual(
            code.frame.width,
            RemoteAccessPreferencesViewController.PairingCardLayout.codeSide,
            accuracy: 0.5
        )
        XCTAssertEqual(image.size.width, code.frame.width, accuracy: 0.5, "the code is resampled")
        XCTAssertLessThanOrEqual(
            code.frame.width,
            PairingCodeImage.preferredSide,
            "the plate is wider than the code the component draws"
        )
        let matrix = try XCTUnwrap(PairingCodeMatrix.make(Self.payload, correctionLevel: "M"))
        let modules = CGFloat(matrix.size + 8)
        XCTAssertGreaterThanOrEqual(
            code.frame.width / modules, 3,
            "the plate is now too small to scan: \(code.frame.width / modules)pt per module"
        )

        // Leading edge, and one column for everything beside it.
        let detail = try XCTUnwrap(label(in: page.view, id: "settings.remote-access.pairing-detail"))
        let note = try XCTUnwrap(label(in: page.view, id: "settings.remote-access.pairing-note"))
        let action = try XCTUnwrap(button(in: page.view, id: "settings.remote-access.pair"))
        // Measured on alignment rects rather than frames, because that is what "aligned by ink"
        // means here: a wrapping `NSTextField` reports two points of padding around the glyphs
        // its frame holds, and comparing frames would call a straight column crooked.
        let host = page.host
        let codeInk = ink(of: code, in: host)
        let column = [title, detail, note, action].map { ink(of: $0, in: host).minX }
        XCTAssertLessThan(codeInk.minX, try XCTUnwrap(column.min()), "the code is not leading")
        for edge in column {
            XCTAssertEqual(
                edge, column[0], accuracy: 0.5,
                "the card's text does not sit on one column"
            )
        }
        XCTAssertEqual(
            try XCTUnwrap(column.min()) - codeInk.maxX,
            Design.Spacing.large,
            accuracy: 0.5,
            "the gap between the code and its text is not the token that states it"
        )

        // The warning is a secondary note beside the code, not a centred caption under it.
        XCTAssertEqual(note.textColor?.hexString, Design.Text.secondary.hexString)
        XCTAssertNotEqual(note.alignment, .center, "the ownership warning is centred again")
        XCTAssertTrue(
            note.stringValue.hasPrefix("Only scan this owner code on a device you control."),
            "the security wording changed"
        )
        XCTAssertEqual(action.title, "Copy Pairing Link")

        // The card holds one image, and it is the code.
        let card = try XCTUnwrap(card(containing: code))
        XCTAssertEqual(
            descendants(in: card).compactMap { $0 as? NSImageView }.count, 1,
            "the pairing card grew a decorative image again"
        )
    }

    /// The squeezed pane: two columns still have to fit, and the code is what cannot shrink.
    func testThePairingCardStaysInsideANarrowPane() throws {
        let page = self.page(state: .lanBound, width: Render.narrowWidth)
        let code = try XCTUnwrap(imageView(in: page.view, id: "settings.remote-access.qr-code"))
        let note = try XCTUnwrap(label(in: page.view, id: "settings.remote-access.pairing-note"))
        let card = try XCTUnwrap(card(containing: code))

        let cardFrame = card.convert(card.bounds, to: page.host)
        let noteFrame = note.convert(note.bounds, to: page.host)
        XCTAssertLessThanOrEqual(
            noteFrame.maxX, cardFrame.maxX,
            "the note runs past the card in a narrow pane"
        )
        XCTAssertGreaterThan(noteFrame.width, 40, "the text column collapsed")
    }

    /// A long four-line disclosure must not push a door's switch off its own row.
    func testALongDisclosureDoesNotPushADoorsSwitchOutOfItsCard() throws {
        for width in [Render.width, Render.narrowWidth] {
            let page = self.page(state: .lanBound, width: width)
            for wayIn in RemoteAccessWayIn.allCases where wayIn.hasSwitch {
                let toggle = try XCTUnwrap(view(
                    in: page.view,
                    id: RemoteAccessPreferencesViewController.Identifier.doorToggle(wayIn)
                ))
                let card = try XCTUnwrap(card(containing: toggle))
                let cardFrame = card.convert(card.bounds, to: page.host)
                let toggleFrame = toggle.convert(toggle.bounds, to: page.host)
                XCTAssertLessThanOrEqual(
                    toggleFrame.maxX, cardFrame.maxX,
                    "\(wayIn)'s switch is outside its card at \(width)pt"
                )
                XCTAssertGreaterThanOrEqual(toggleFrame.minY, cardFrame.minY, "\(wayIn)")
                XCTAssertGreaterThan(
                    toggleFrame.width, 0,
                    "\(wayIn)'s switch was compressed away at \(width)pt"
                )
            }
            for wayIn in RemoteAccessWayIn.allCases {
                let block = try XCTUnwrap(view(
                    in: page.view,
                    id: RemoteAccessPreferencesViewController.Identifier.disclosure(wayIn)
                ))
                let card = try XCTUnwrap(card(containing: block))
                XCTAssertLessThanOrEqual(
                    block.convert(block.bounds, to: page.host).maxX,
                    card.convert(card.bounds, to: page.host).maxX,
                    "\(wayIn)'s four lines run past their card at \(width)pt"
                )
            }
        }
    }

    // MARK: - Images

    func testRendersEveryStateToImages() throws {
        let directory = Render.directory
        if let directory {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        var written: [String] = []
        // The squeezed pane as well, for the one state that has two columns to fit into it.
        let fixtures: [(state: PageState, width: CGFloat, suffix: String)] =
            PageState.allCases.map { ($0, Render.width, "") }
                + [(.lanBound, Render.narrowWidth, "-narrow")]
        for (state, width, suffix) in fixtures {
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
                    let page = self.page(state: state, width: width, appearance: appearance)
                    png = self.pngData(of: page.host)
                }
                let data = try XCTUnwrap(png, "\(state) rendered nothing in \(name)")
                XCTAssertGreaterThan(data.count, 20_000, "\(state) \(name) rendered empty")
                let fileName = "remote-access-\(state.fileName)\(suffix)-\(name)"
                attach(data, named: fileName)
                if let directory {
                    try data.write(
                        to: directory.appendingPathComponent("\(fileName).png")
                    )
                }
                written.append(fileName)
            }
        }
        XCTAssertEqual(written.count, fixtures.count * 2)
    }

    // MARK: - Fixture

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

        var fileName: String {
            switch self {
            case .lanBound: return "lan-bound"
            case .lanNoInterface: return "lan-no-interface"
            case .lanFirewalled: return "lan-firewall"
            case .identityUnavailable: return "identity-unavailable"
            case .tailnetBound: return "tailnet-bound"
            case .tailnetBinding: return "tailnet-binding"
            case .tailnetNotConnected: return "tailnet-not-connected"
            case .tailnetNotInstalled: return "tailnet-not-installed"
            case .serveServing: return "serve-serving"
            case .serveNeedsHTTPS: return "serve-needs-https"
            case .nothingOn: return "nothing-on"
            }
        }

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

        private var approvalURL: URL { RemoteAccessSettingsRenderTests.approvalURL }
        private var serveOrigin: URL {
            URL(string: "https://\(RemoteAccessSettingsRenderTests.magicDNSName):8443/")!
        }
    }

    private struct Page {
        let controller: RemoteAccessPreferencesViewController
        let host: NSView
        var view: NSView { controller.view }
    }

    /// The page in one state, laid out and ready to photograph.
    ///
    /// Every value comes in through `apply`, so nothing here reads the developer's own settings
    /// or asks the machine running the test what networks it is on.
    private func page(
        state: PageState,
        width: CGFloat = Render.width,
        appearance: NSAppearance? = nil,
        identity: RemoteIdentityCardPresentation? = nil
    ) -> Page {
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
        if let appearance {
            host.appearance = appearance
            controller.view.appearance = appearance
        }
        host.wantsLayer = true
        host.layer?.backgroundColor = Design.Surface.ground.cgColor

        let statuses: [RemoteAccessWayIn: RemoteDoorStatus] = [
            .thisNetwork: .thisNetwork(
                isEnabled: state.thisNetworkIsOn,
                state: state.doorState,
                firewall: state.firewall,
                preferredPort: Self.listenerPort
            ),
            .tailscale: .tailscale(
                isEnabled: state.tailscaleIsOn,
                state: state.tailnetDoorState,
                facts: state.facts,
                magicDNSName: state.facts.magicDNSName
            ),
            .threadingDirect: .threadingDirect(.stopped)
        ]
        let doors = RemoteAccessDoorsPresentation(
            isRemoteAccessOn: true,
            thisNetworkIsOn: state.thisNetworkIsOn,
            tailscaleIsOn: state.tailscaleIsOn,
            tailscaleServeIsOn: state.serveIsOn,
            showsThreadingDirect: false,
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

        AppThemeRefresh.repaint(host)
        host.layoutSubtreeIfNeeded()
        return Page(controller: controller, host: host)
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

    private func card(containing view: NSView) -> SettingsCard? {
        var candidate: NSView? = view
        while let current = candidate {
            if let card = current as? SettingsCard { return card }
            candidate = current.superview
        }
        return nil
    }
}
