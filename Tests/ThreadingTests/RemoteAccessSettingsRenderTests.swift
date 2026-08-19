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
        let serve = try XCTUnwrap(
            view(in: page.view, id: "settings.remote-access.tailscale-serve"),
            "the Serve sub-option was removed rather than held back"
        )
        // Built and not shown: Serve *is* the tailnet door today, so a switch turning it off
        // would take the phone's only tailnet route with it.
        XCTAssertTrue(isEffectivelyHidden(serve), "the Serve sub-option is on the page already")
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

    // MARK: - The announcement, and what it buys

    /// The switch belongs to the `lan` door and to no other, so it lives in that door's card.
    ///
    /// Asserted through the card the two views actually land in rather than through the order
    /// they were appended in: a row moved one section down still reads as "This network" in the
    /// source and reads as Tailscale on the screen.
    func testTheAnnouncementSwitchIsInsideTheThisNetworkCard() throws {
        let page = self.page(state: .lanBound)
        let toggle = try XCTUnwrap(
            view(in: page.view, id: RemoteAccessPreferencesViewController.Identifier.discoveryToggle)
        )
        let door = try XCTUnwrap(view(
            in: page.view,
            id: RemoteAccessPreferencesViewController.Identifier.status(.thisNetwork)
        ))
        XCTAssertIdentical(
            card(containing: toggle),
            card(containing: door),
            "the announcement moved out of the card whose door carries it"
        )
        let wake = try XCTUnwrap(
            label(in: page.view, id: RemoteAccessPreferencesViewController.Identifier.wakeOnDemand)
        )
        XCTAssertIdentical(card(containing: wake), card(containing: door))
    }

    /// A broadcast is visible to everyone on the network, so the row says what leaves this Mac
    /// rather than that something does.
    func testTheAnnouncementRowStatesWhatIsBroadcast() throws {
        let page = self.page(state: .lanBound)
        let labels = allLabels(in: page.view).map(\.stringValue)
        let subtitle = try XCTUnwrap(
            labels.first { $0.hasPrefix("Broadcasts an opaque name") },
            "the announcement does not say what it broadcasts"
        )
        for named in ["opaque name", "id", "protocol version", "certificate fingerprint"] {
            XCTAssertTrue(subtitle.contains(named), "the payload does not name the \(named)")
        }
        XCTAssertTrue(
            subtitle.contains("Never the computer name and never your name"),
            "the row does not say what is never broadcast, which is the reason to read it"
        )
        XCTAssertTrue(
            subtitle.contains("pairing still needs the code"),
            "the row leaves a reader thinking a broadcast is a way in"
        )
        XCTAssertFalse(subtitle.contains("\u{2014}"), "an em dash reached the copy")
    }

    /// The instance name is the one part of the payload that is safe to print, and printing it
    /// is what lets a person confirm that the broadcast carries no name of theirs.
    func testTheAnnouncedLineNamesTheOpaqueInstanceAndOnlyWhenOneIsRegistered() throws {
        let announced = self.page(
            state: .lanBound,
            discovery: DiscoveryState.announcedAndCanWake.presentation
        )
        let line = try XCTUnwrap(label(
            in: announced.view,
            id: RemoteAccessPreferencesViewController.Identifier.announcedName
        ))
        XCTAssertEqual(line.stringValue, "Announced as \(Self.instanceName)")
        XCTAssertFalse(line.isHidden)
        XCTAssertEqual(
            Self.instanceName.count,
            RemoteBase32.encode(Data(repeating: 0, count: RemoteDiscoveryDefaults.instanceNameByteCount)).count,
            "the fixture is not the shape of name the Mac actually publishes"
        )

        let off = self.page(state: .lanBound, discovery: DiscoveryState.off.presentation)
        let offLine = try XCTUnwrap(label(
            in: off.view,
            id: RemoteAccessPreferencesViewController.Identifier.announcedName
        ))
        XCTAssertTrue(
            isEffectivelyHidden(offLine),
            "a line about an announcement was shown while nothing was registered"
        )
        // The whole row leaves, not only its text: hiding a label keeps the mark column's own
        // height constraint, and the card printed a blank line where the fact had been. Measured
        // by where the line below it lands, because a hidden label keeps its own frame either
        // way, which is exactly why the first version of this passed on the bug.
        let announcedWake = try XCTUnwrap(label(
            in: announced.view,
            id: RemoteAccessPreferencesViewController.Identifier.wakeOnDemand
        ))
        let offWake = try XCTUnwrap(label(
            in: off.view,
            id: RemoteAccessPreferencesViewController.Identifier.wakeOnDemand
        ))
        XCTAssertGreaterThan(
            ink(of: offWake, in: off.host).minY,
            ink(of: announcedWake, in: announced.host).minY,
            "the announced line left a gap behind it"
        )
        XCTAssertEqual(
            try XCTUnwrap(view(
                in: off.view,
                id: RemoteAccessPreferencesViewController.Identifier.discoveryToggle
            ) as? ThemedToggle).state,
            .off
        )
    }

    /// "Can wake this Mac" is a promise the network has to keep, so it is printed only when both
    /// facts hold, and each of the other three states names the exact thing that is missing.
    func testWakingIsClaimedOnlyWithBothFactsAndOtherwiseNamesTheReason() throws {
        let expected: [(DiscoveryState, String, String, NSColor)] = [
            (.announcedAndCanWake, "Can wake this Mac from sleep", "\u{2713}", Design.Status.positive),
            (
                .wakeSettingOff,
                "Wake for network access is off in System Settings \u{25B8} Energy",
                "\u{2013}",
                Design.Text.tertiary
            ),
            (
                .noSleepProxy,
                "No sleep proxy on this network; an Apple TV or HomePod provides one",
                "\u{2013}",
                Design.Text.tertiary
            ),
            (.notChecked, "Not checked yet", "\u{2013}", Design.Text.tertiary)
        ]
        for (state, text, mark, ink) in expected {
            let page = self.page(state: .lanBound, discovery: state.presentation)
            let line = try XCTUnwrap(label(
                in: page.view,
                id: RemoteAccessPreferencesViewController.Identifier.wakeOnDemand
            ))
            XCTAssertEqual(line.stringValue, text, "\(state)")
            let glyph = try XCTUnwrap(label(
                in: page.view,
                id: RemoteAccessPreferencesViewController.Identifier.wakeOnDemandMark
            ))
            // The mark as well as the ink: this is the page's only signal under Differentiate
            // Without Colour, and a green tick beside three of these would be the exact promise
            // the network cannot keep.
            XCTAssertEqual(glyph.stringValue, mark, "\(state)")
            XCTAssertEqual(glyph.textColor?.hexString, ink.hexString, "\(state)")
        }
    }

    /// A Sleep Proxy answers for an advertised service, so with nothing advertised there is
    /// nothing to wake this Mac however the two facts read.
    ///
    /// The switch being off is the reachable case: `pmset` still says the setting is on and a
    /// proxy is still on the network, so both facts hold and the page would have printed a green
    /// "can wake this Mac" for a service it had just withdrawn.
    func testWakingIsNotClaimedWhileNothingIsAnnounced() throws {
        let page = self.page(state: .lanBound, discovery: DiscoveryState.off.presentation)
        XCTAssertTrue(
            DiscoveryState.off.presentation.wakeFacts.canWakeThisMac,
            "the fixture no longer holds both facts, so it proves nothing"
        )
        let line = try XCTUnwrap(label(
            in: page.view,
            id: RemoteAccessPreferencesViewController.Identifier.wakeOnDemand
        ))
        XCTAssertEqual(line.stringValue, "Waking needs an announcement on this network")
        let glyph = try XCTUnwrap(label(
            in: page.view,
            id: RemoteAccessPreferencesViewController.Identifier.wakeOnDemandMark
        ))
        XCTAssertEqual(glyph.stringValue, "\u{2013}")
        XCTAssertEqual(glyph.textColor?.hexString, Design.Text.tertiary.hexString)
    }

    /// Unknown is never yes, on the page as well as in the facts.
    func testNoWakeClaimSurvivesEitherFactBeingMissing() throws {
        let partial: [RemoteWakeOnDemandFacts] = [
            Self.wakeFacts(true, nil),
            Self.wakeFacts(nil, true),
            Self.wakeFacts(nil, nil),
            .unknown
        ]
        for facts in partial {
            let page = self.page(
                state: .lanBound,
                discovery: RemoteDiscoveryPresentation(
                    isEnabled: true,
                    announcedName: Self.instanceName,
                    wakeFacts: facts
                )
            )
            let line = try XCTUnwrap(label(
                in: page.view,
                id: RemoteAccessPreferencesViewController.Identifier.wakeOnDemand
            ))
            XCTAssertEqual(
                line.stringValue,
                "Not checked yet",
                "a half-read answer was rendered as a reason it had looked at"
            )
            XCTAssertFalse(
                line.stringValue.contains("Can wake"),
                "the page promised waking without both facts"
            )
        }
    }

    /// The two fact lines start on one column, under the status line they qualify.
    ///
    /// A render found it: the wake line carries a mark and the announced line did not, so the
    /// two sentences began four points apart in a card where everything else is aligned by ink.
    func testTheTwoFactLinesShareTheirColumn() throws {
        let page = self.page(
            state: .lanBound,
            discovery: DiscoveryState.announcedAndCanWake.presentation
        )
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
            "the two facts under one switch begin on two columns"
        )
        // The host is unflipped, so the line higher on the page has the larger y.
        XCTAssertGreaterThan(
            ink(of: announced, in: page.host).minY,
            ink(of: wake, in: page.host).minY,
            "the wake line reads before the announcement it depends on"
        )
    }

    // MARK: - The unavailable panel

    /// The panel carries the reason and the fix, rather than naming neither and leaving both in
    /// a readiness row further up the page.
    func testTheUnavailablePanelShowsTheReasonAndTheFixBesideRetry() throws {
        let page = self.page(state: .tailscaleServeNotEnabled)

        let detail = try XCTUnwrap(label(in: page.view, id: "settings.remote-access.pairing-detail"))
        XCTAssertEqual(
            detail.stringValue,
            "Tailscale Serve is not enabled for this tailnet. Enable HTTPS certificates in the "
                + "Tailscale admin console, then retry.",
            "the panel does not say which readiness item failed or what fixes it"
        )

        let remedy = try XCTUnwrap(
            button(in: page.view, id: "settings.remote-access.pairing-remedy")
        )
        let retry = try XCTUnwrap(button(in: page.view, id: "settings.remote-access.pair"))
        XCTAssertFalse(remedy.isHidden, "the fix's action is not offered beside Retry")
        XCTAssertEqual(remedy.title, "Enable Tailscale Serve…")
        XCTAssertEqual(retry.title, "Retry Connection")
        XCTAssertTrue(remedy.isProminent, "the fix is not the button being offered")
        XCTAssertFalse(retry.isProminent, "two prominent buttons ask the same question twice")
        XCTAssertLessThan(
            remedy.frame.minX, retry.frame.minX,
            "the fix reads after the retry it replaces"
        )

        // The readiness row keeps saying it too; the panel is an addition, not a move.
        let rowDetail = TailscaleReadinessIssue.serveNotEnabled.rowDetail
        XCTAssertTrue(
            allLabels(in: page.view).contains { $0.stringValue == rowDetail },
            "the readiness row lost its own line"
        )

        // And the door's own status line carries the same failure, split into fact and fix.
        let status = try XCTUnwrap(label(
            in: page.view,
            id: RemoteAccessPreferencesViewController.Identifier.status(.tailscale)
        ))
        XCTAssertEqual(
            status.stringValue,
            TailscaleReadinessIssue.serveNotEnabled.failureStatement
        )
    }

    /// A failure with no page to open shows Retry alone.
    func testAFailureWithNoPageToOpenShowsRetryAlone() throws {
        let page = self.page(state: .tailscaleStatusUnavailable)
        let remedy = try XCTUnwrap(
            button(in: page.view, id: "settings.remote-access.pairing-remedy")
        )
        let retry = try XCTUnwrap(button(in: page.view, id: "settings.remote-access.pair"))
        XCTAssertTrue(remedy.isHidden, "a button was offered with nowhere to go")
        XCTAssertTrue(retry.isProminent, "Retry is the only action, so it is the one offered")
    }

    // MARK: - Starting

    /// The minute of silence. The page says what it is waiting for in all three places a person
    /// is looking: the status row, the tailnet door's own line, and the pairing panel.
    func testAPublishingTailnetSaysWhatItIsWaitingForEverywhereItIsShown() throws {
        let page = self.page(state: .tailscaleStarting)

        let waiting = "Waiting for the tailnet HTTPS endpoint to answer. The first time can take "
            + "up to a minute."

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

        // The status row, the door's line, the readiness row and the panel.
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
        // The squeezed pane as well, for the one state that has two columns to fit into it, and
        // the announcement's five states on the page they actually appear on.
        let fixtures: [
            (state: PageState, width: CGFloat, discovery: RemoteDiscoveryPresentation?, suffix: String)
        ] =
            PageState.allCases.map { ($0, Render.width, nil, "") }
                + [(.lanBound, Render.narrowWidth, nil, "-narrow")]
                + DiscoveryState.allCases.map {
                    (.lanBound, Render.width, $0.presentation, "-discovery-\($0.fileName)")
                }
        for (state, width, discovery, suffix) in fixtures {
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
                        state: state,
                        width: width,
                        appearance: appearance,
                        discovery: discovery
                    )
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
        /// The tailnet door, up.
        case tailscaleReady
        /// The tailnet door, a minute into its first certificate.
        case tailscaleStarting
        /// The failure that shipped with its explanation three rows away.
        case tailscaleServeNotEnabled
        /// A failure with no admin page to open.
        case tailscaleStatusUnavailable
        /// Remote Access on and no way in switched on.
        case nothingOn

        var fileName: String {
            switch self {
            case .lanBound: return "lan-bound"
            case .lanNoInterface: return "lan-no-interface"
            case .lanFirewalled: return "lan-firewall"
            case .identityUnavailable: return "identity-unavailable"
            case .tailscaleReady: return "tailscale-ready"
            case .tailscaleStarting: return "tailscale-starting"
            case .tailscaleServeNotEnabled: return "tailscale-serve-not-enabled"
            case .tailscaleStatusUnavailable: return "tailscale-status-unavailable"
            case .nothingOn: return "nothing-on"
            }
        }

        var hasBoundAddress: Bool {
            switch self {
            case .lanBound, .tailscaleReady: return true
            case .lanNoInterface, .lanFirewalled, .identityUnavailable, .tailscaleStarting,
                 .tailscaleServeNotEnabled, .tailscaleStatusUnavailable, .nothingOn:
                return false
            }
        }

        var thisNetworkIsOn: Bool { self != .nothingOn && !isTailnetState }

        var tailscaleIsOn: Bool { isTailnetState }

        private var isTailnetState: Bool {
            switch self {
            case .tailscaleReady, .tailscaleStarting, .tailscaleServeNotEnabled,
                 .tailscaleStatusUnavailable:
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
            case .tailscaleReady, .tailscaleStarting, .tailscaleServeNotEnabled,
                 .tailscaleStatusUnavailable, .nothingOn:
                return .off
            }
        }

        var firewall: RemoteFirewallHint {
            self == .lanFirewalled
                ? RemoteFirewallHint(globalState: .on, applicationState: .unknown)
                : .unknown
        }

        var readiness: TailscaleReadiness {
            switch self {
            case .tailscaleServeNotEnabled:
                return .actionRequired(.serveNotEnabled, actionURL: approvalURL)
            case .tailscaleStatusUnavailable:
                return .actionRequired(.statusUnavailable, actionURL: nil)
            case .tailscaleStarting:
                return .publishing
            case .tailscaleReady:
                return .ready(tailnetOrigin)
            case .lanBound, .lanNoInterface, .lanFirewalled, .identityUnavailable, .nothingOn:
                return .notChecked
            }
        }

        var transport: RemoteTransportState {
            switch self {
            case .tailscaleServeNotEnabled:
                return .unavailable(TailscaleReadinessIssue.serveNotEnabled.message)
            case .tailscaleStatusUnavailable:
                return .unavailable(TailscaleReadinessIssue.statusUnavailable.message)
            case .tailscaleStarting:
                return .starting
            case .tailscaleReady:
                return .connected(tailnetOrigin)
            case .lanBound, .lanNoInterface, .lanFirewalled, .identityUnavailable, .nothingOn:
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
        private var tailnetOrigin: URL {
            URL(string: "https://mac-studio.tail1234.ts.net:8443/")!
        }
    }

    /// The announcement and the wake facts, as the five states a person can be looking at.
    ///
    /// A separate axis from `PageState` rather than more cases in it: neither value changes any
    /// door's status line, and multiplying nine page states by five would photograph forty-five
    /// pages to show five differences.
    enum DiscoveryState: CaseIterable {
        /// Announced, and the network can wake this Mac. Both facts hold.
        case announcedAndCanWake
        /// The switch is off, so nothing is registered.
        case off
        /// Announced, and "Wake for network access" is off in System Settings.
        case wakeSettingOff
        /// Announced, the setting is on, and no proxy answered on this network.
        case noSleepProxy
        /// Announced, and the probe has not produced an answer yet.
        case notChecked

        var fileName: String {
            switch self {
            case .announcedAndCanWake: return "announced-can-wake"
            case .off: return "off"
            case .wakeSettingOff: return "wake-setting-off"
            case .noSleepProxy: return "no-sleep-proxy"
            case .notChecked: return "not-checked"
            }
        }

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
    /// Derived rather than typed so the fixture cannot photograph a shape the Mac never
    /// publishes.
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
        identity: RemoteIdentityCardPresentation? = nil,
        discovery: RemoteDiscoveryPresentation? = nil
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
                transport: state.transport,
                readiness: state.readiness
            ),
            .threadingDirect: .threadingDirect(.stopped)
        ]
        let doors = RemoteAccessDoorsPresentation(
            isRemoteAccessOn: true,
            thisNetworkIsOn: state.thisNetworkIsOn,
            tailscaleIsOn: state.tailscaleIsOn,
            showsThreadingDirect: false,
            statuses: statuses,
            identity: identity ?? state.identity
        )
        controller.apply(doors)
        controller.apply(discovery ?? state.discovery)
        controller.updateTailscaleReadiness(state.readiness)
        controller.applyListeningState(
            connection: RemoteConnectionStatusPresentation.resolve(
                statuses: doors.offeredStatuses,
                localPort: Self.listenerPort
            ),
            card: RemotePairingCardState.resolve(
                ownerDevicePersistenceError: nil,
                pairingCodePayload: state.payload,
                transport: state.transport,
                tailscaleReadiness: state.readiness,
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
