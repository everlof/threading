import AppKit
import XCTest
@testable import Threading

/// Draws the Remote Access page in the three states it is actually used in, light and dark.
///
/// Every one of them takes a live tailnet to reach, which is why what shipped was reviewed in
/// none of them: a panel that said a connection was unavailable while the reason sat three rows
/// above it, a minute of silence with a spinner on it, and a pairing card laid out like a poster
/// — a centred title with a phone glyph, a plate floating mid-card, and a centred warning ending
/// in an orphan. The page states each of them from values, so this fixture can photograph them
/// and turn what the picture shows into assertions.
@MainActor
final class RemoteAccessSettingsRenderTests: XCTestCase {

    private enum Render {
        /// The pane's own width, plus the squeezed pane the settings renders use as the stress
        /// case: the pairing card is now two columns, so a narrow pane is where it breaks first.
        static let width = SettingsUIDefaults.pageWidth
        static let narrowWidth: CGFloat = 420
        /// Tall enough that the whole page is inside the scroll view's clip, so the pairing card
        /// is in the picture rather than below it.
        static let height: CGFloat = 1500

        static var directory: URL? {
            ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"].map {
                URL(fileURLWithPath: $0, isDirectory: true)
            }
        }
    }

    /// A real pairing payload, written the way `RemoteConnectionLink.scannablePayload` writes it.
    private static let payload =
        "HTTPS://MAC-STUDIO.TAIL1234.TS.NET:8443/#MZXW6YTBOI7EU3TFOQQGE43FMN"

    private static let approvalURL = URL(
        string: "https://login.tailscale.com/f/serve?node=abcdef"
    )!

    // MARK: - The unavailable panel

    /// The panel carries the reason and the fix, rather than naming neither and leaving both in
    /// a readiness row further up the page.
    func testTheUnavailablePanelShowsTheReasonAndTheFixBesideRetry() throws {
        let page = page(state: .unavailable)

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
    }

    /// A failure with no page to open shows Retry alone.
    func testAFailureWithNoPageToOpenShowsRetryAlone() throws {
        let page = page(state: .unavailableWithoutRemedy)
        let remedy = try XCTUnwrap(
            button(in: page.view, id: "settings.remote-access.pairing-remedy")
        )
        let retry = try XCTUnwrap(button(in: page.view, id: "settings.remote-access.pair"))
        XCTAssertTrue(remedy.isHidden, "a button was offered with nowhere to go")
        XCTAssertTrue(retry.isProminent, "Retry is the only action, so it is the one offered")
    }

    // MARK: - Starting

    /// The minute of silence. The page says what it is waiting for in both places a person is
    /// looking: the status row under Connection, and the pairing panel itself.
    func testAPublishingTailnetSaysWhatItIsWaitingForInTheRowAndThePanel() throws {
        let page = page(state: .starting)

        let waiting = "Waiting for the tailnet HTTPS endpoint to answer. The first time can take "
            + "up to a minute."

        let status = try XCTUnwrap(label(in: page.view, id: "settings.remote-access.status"))
        XCTAssertEqual(status.stringValue, "Publishing on your tailnet")

        let statusDetail = try XCTUnwrap(
            allLabels(in: page.view).first { $0.stringValue.hasPrefix(waiting) }
        )
        XCTAssertTrue(
            statusDetail.stringValue.contains("127.0.0.1:8760"),
            "the row dropped the address it does know"
        )

        let panel = try XCTUnwrap(label(in: page.view, id: "settings.remote-access.pairing-detail"))
        XCTAssertEqual(panel.stringValue, waiting, "the panel is still silent about the wait")

        // And the readiness row it belongs to says the same thing rather than less.
        XCTAssertEqual(
            allLabels(in: page.view).filter { $0.stringValue.contains(waiting) }.count,
            3,
            "the wait is missing from the status row, the readiness row, or the panel"
        )
    }

    // MARK: - The pairing card

    /// The poster, rebuilt: no glyph in the title, a plate no wider than the code needs, and
    /// everything else left-aligned beside it.
    func testThePairingCardLeadsWithTheCodeAndAlignsByInk() throws {
        let page = page(state: .ready)

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
        let page = page(state: .ready, width: Render.narrowWidth)
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

    // MARK: - Images

    func testRendersTheThreeStatesToImages() throws {
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
                + [(.ready, Render.narrowWidth, "-narrow")]
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
        case unavailable
        case unavailableWithoutRemedy
        case starting
        case ready

        var fileName: String {
            switch self {
            case .unavailable: return "unavailable"
            case .unavailableWithoutRemedy: return "unavailable-no-remedy"
            case .starting: return "starting"
            case .ready: return "ready"
            }
        }

        var readiness: TailscaleReadiness {
            switch self {
            case .unavailable:
                return .actionRequired(.serveNotEnabled, actionURL: approvalURL)
            case .unavailableWithoutRemedy:
                return .actionRequired(.statusUnavailable, actionURL: nil)
            case .starting:
                return .publishing
            case .ready:
                return .ready(URL(string: "https://mac-studio.tail1234.ts.net:8443/")!)
            }
        }

        var transport: RemoteTransportState {
            switch self {
            case .unavailable:
                return .unavailable(TailscaleReadinessIssue.serveNotEnabled.message)
            case .unavailableWithoutRemedy:
                return .unavailable(TailscaleReadinessIssue.statusUnavailable.message)
            case .starting:
                return .starting
            case .ready:
                return .connected(URL(string: "https://mac-studio.tail1234.ts.net:8443/")!)
            }
        }

        var payload: String? {
            self == .ready ? RemoteAccessSettingsRenderTests.payload : nil
        }

        private var approvalURL: URL { RemoteAccessSettingsRenderTests.approvalURL }
    }

    private struct Page {
        let controller: RemoteAccessPreferencesViewController
        let host: NSView
        var view: NSView { controller.view }
    }

    /// The page in one state, laid out and ready to photograph.
    ///
    /// The connection mode is the one behavioural setting the page reads that decides whether
    /// the tailnet is on screen at all, so it is set for the fixture and put back.
    private func page(
        state: PageState,
        width: CGFloat = Render.width,
        appearance: NSAppearance? = nil
    ) -> Page {
        let previousMode = AppSettings.shared.remoteAccessConnectionMode
        AppSettings.shared.remoteAccessConnectionMode = .tailscale
        addTeardownBlock { @MainActor in
            AppSettings.shared.remoteAccessConnectionMode = previousMode
        }

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

        controller.updateTailscaleReadiness(state.readiness)
        controller.applyListeningState(
            connection: RemoteConnectionStatusPresentation.resolve(
                mode: .tailscale,
                relay: .stopped,
                tailscale: state.transport,
                tailscaleReadiness: state.readiness,
                allowsOwnerRelayFallback: false,
                localPort: 8760
            ),
            card: RemotePairingCardState.resolve(
                ownerDevicePersistenceError: nil,
                pairingCodePayload: state.payload,
                transport: state.transport,
                tailscaleReadiness: state.readiness
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
