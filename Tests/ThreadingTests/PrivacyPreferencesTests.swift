import AppKit
import UserNotifications
import XCTest
@testable import Threading

/// The Privacy page is an inventory of what the OS lets Threading do, so the thing under test is
/// mostly *honesty*: that it reports a grant it can read, admits the one it cannot, and never
/// asks for anything merely because someone opened a settings page.
@MainActor
final class PrivacyPreferencesTests: XCTestCase {

    // MARK: - Fixtures

    /// A reader whose every answer is stated by the test, so an assertion never depends on what
    /// this particular Mac happens to have approved in System Settings.
    private func reader(
        accessibility: Bool = false,
        screenRecording: Bool = false,
        notifications: SystemPrivacyStatus = .askedWhenNeeded,
        probeCount: ProbeCount? = nil
    ) -> SystemPrivacyStatusReader {
        SystemPrivacyStatusReader(
            accessibilityTrusted: {
                probeCount?.accessibility += 1
                return accessibility
            },
            screenRecordingAllowed: {
                probeCount?.screenRecording += 1
                return screenRecording
            },
            notificationStatus: { completion in
                probeCount?.notifications += 1
                completion(notifications)
            }
        )
    }

    private final class ProbeCount {
        var accessibility = 0
        var screenRecording = 0
        var notifications = 0
    }

    private func page(
        _ reader: SystemPrivacyStatusReader,
        height: CGFloat = 1100
    ) -> PrivacyPreferencesViewController {
        let controller = PrivacyPreferencesViewController(reader: reader)
        controller.view.frame = NSRect(
            x: 0,
            y: 0,
            width: SettingsUIDefaults.pageWidth,
            height: height
        )
        controller.view.layoutSubtreeIfNeeded()
        return controller
    }

    private func descendants(in root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants(in: $0) }
    }

    private func row(
        _ permission: SystemPrivacyPermission,
        in controller: NSViewController
    ) throws -> NSView {
        let identifier = "settings.privacy.\(permission.rawValue)"
        return try XCTUnwrap(
            descendants(in: controller.view).first {
                $0.accessibilityIdentifier() == identifier
            },
            "the page has no row for \(permission.rawValue)"
        )
    }

    private func labels(in view: NSView) -> [String] {
        ([view] + descendants(in: view))
            .compactMap { ($0 as? NSTextField)?.stringValue }
    }

    // MARK: - The Model

    func testEveryGrantNamesTheSettingsPaneThatOwnsIt() {
        let urls = SystemPrivacyPermission.allCases.compactMap(\.settingsURL)
        XCTAssertEqual(
            urls.count,
            SystemPrivacyPermission.allCases.count,
            "a permission offers an Open Settings button that would go nowhere"
        )
        XCTAssertEqual(
            Set(urls.map(\.absoluteString)).count,
            urls.count,
            "two permissions point at the same pane, so one of them sends the user to the wrong "
                + "switch"
        )
        for url in urls {
            XCTAssertEqual(url.scheme, "x-apple.systempreferences")
        }
    }

    /// `.provisional` delivers quietly rather than not at all. Reporting it as anything but
    /// allowed would tell a user a notification cannot arrive when one already can.
    func testNotificationAuthorizationMapsOntoWhatTheUserCanObserve() {
        XCTAssertEqual(SystemPrivacyStatus(.authorized), .allowed)
        XCTAssertEqual(SystemPrivacyStatus(.provisional), .allowed)
        XCTAssertEqual(SystemPrivacyStatus(.denied), .notAllowed)
        XCTAssertEqual(SystemPrivacyStatus(.notDetermined), .askedWhenNeeded)
    }

    func testTheReaderReportsEachGrantItCanRead() {
        var statuses: [SystemPrivacyPermission: SystemPrivacyStatus] = [:]
        reader(accessibility: true, screenRecording: false, notifications: .notAllowed)
            .load { statuses = $0 }

        XCTAssertEqual(statuses[.accessibility], .allowed)
        XCTAssertEqual(statuses[.screenRecording], .notAllowed)
        XCTAssertEqual(statuses[.notifications], .notAllowed)
        XCTAssertEqual(
            statuses.count,
            SystemPrivacyPermission.allCases.count,
            "a permission is listed on the page but has no status to show"
        )
    }

    /// The whole reason `askedWhenNeeded` exists. There is no API that reports the folder grant
    /// without requesting it, and requesting it would put a system prompt on screen because the
    /// user opened a settings page — the opposite of what the page is for.
    func testTheFolderGrantIsReportedAsUnreadableRatherThanProbed() {
        XCTAssertFalse(SystemPrivacyPermission.filesAndFolders.isStatusReadable)

        var statuses: [SystemPrivacyPermission: SystemPrivacyStatus] = [:]
        reader(accessibility: true, screenRecording: true, notifications: .allowed)
            .load { statuses = $0 }

        XCTAssertEqual(
            statuses[.filesAndFolders],
            .askedWhenNeeded,
            "the folder grant claims a status it cannot know without prompting"
        )
    }

    func testOpeningThePageReadsEachGrantExactlyOnce() {
        let probes = ProbeCount()
        _ = page(reader(probeCount: probes))

        XCTAssertEqual(probes.accessibility, 1)
        XCTAssertEqual(probes.screenRecording, 1)
        XCTAssertEqual(probes.notifications, 1)
    }

    // MARK: - The Page

    func testEachRowStatesItsStatusInWords() throws {
        let controller = page(
            reader(accessibility: true, screenRecording: false, notifications: .notAllowed)
        )

        XCTAssertTrue(
            labels(in: try row(.accessibility, in: controller)).contains("Allowed"),
            "an allowed grant is shown by colour alone"
        )
        XCTAssertTrue(
            labels(in: try row(.screenRecording, in: controller)).contains("Not allowed")
        )
        XCTAssertTrue(
            labels(in: try row(.notifications, in: controller)).contains("Not allowed")
        )
        XCTAssertTrue(
            labels(in: try row(.filesAndFolders, in: controller))
                .contains("Asked when needed")
        )
    }

    func testEachRowCarriesTitleAndStatusToVoiceOver() throws {
        let controller = page(reader(accessibility: true, notifications: .allowed))

        XCTAssertEqual(
            try row(.accessibility, in: controller).accessibilityLabel(),
            "Accessibility permission: Allowed"
        )
        XCTAssertEqual(
            try row(.filesAndFolders, in: controller).accessibilityLabel(),
            "Files & Folders permission: Asked when needed"
        )
    }

    /// Four buttons all reading "Open Settings" tell an assistive user nothing about which pane
    /// they open, and the button is the only control on the page. The context has to live in
    /// AXHelp: `ThemedButton` publishes its words as AXTitle and returns nil for AXDescription,
    /// so a label set here would be dropped without anyone noticing.
    func testTheSettingsButtonsAreDistinguishableWithoutSight() throws {
        let controller = page(reader())

        let hints = try SystemPrivacyPermission.allCases.map { permission -> String in
            let identifier = "settings.privacy.\(permission.rawValue).open"
            let button = try XCTUnwrap(
                descendants(in: controller.view).first {
                    $0.accessibilityIdentifier() == identifier
                },
                "no Open Settings button for \(permission.rawValue)"
            )
            XCTAssertEqual(
                button.accessibilityHelp(),
                button.toolTip,
                "the pointer and VoiceOver are told different things about the same button"
            )
            return button.accessibilityHelp() ?? ""
        }

        XCTAssertEqual(Set(hints).count, hints.count, "the buttons share one description")
        XCTAssertTrue(hints.allSatisfy { $0.contains("System Settings") })
        XCTAssertTrue(hints.contains("Open Accessibility in System Settings"))
    }

    func testThePageIsDiscoverableFromTheSettingsCatalogue() throws {
        let definition = try XCTUnwrap(SettingsPages.page(id: SettingsPages.privacyID))
        XCTAssertEqual(definition.title, "Privacy")
        XCTAssertTrue(
            SettingsPages.sidebarItems.contains { $0.id == SettingsPages.privacyID },
            "Privacy is not offered in the settings sidebar"
        )
        XCTAssertTrue(
            definition.searchableText.localizedCaseInsensitiveContains("keychain"),
            "searching the settings sidebar for a credential store does not find this page"
        )
    }

    /// Caught by looking at a render, not by an assertion anyone would have written first: two
    /// of the informational rows wrapped into a column a third of the card wide while their
    /// longer siblings filled it, because the horizontal stack left its slack unassigned. The
    /// numbers below are deliberately loose — this pins "uses the width it was given", not a
    /// particular wrap.
    func testEveryWrappingDetailUsesTheWidthItIsGiven() throws {
        let controller = page(reader())
        let cards = descendants(in: controller.view).compactMap { $0 as? SettingsCard }
        // A floor, not an equality: this guards against measuring an empty page, and a page
        // gaining a card is not a reason for a layout test to fail. The `measured` count below
        // is what actually proves something was inspected.
        XCTAssertGreaterThanOrEqual(cards.count, 3, "the page lost the cards this measures")

        var measured = 0
        for card in cards {
            let details = descendants(in: card)
                .compactMap { $0 as? NSTextField }
                .filter { $0.stringValue.count > 80 }

            for field in details {
                measured += 1
                XCTAssertGreaterThan(
                    field.frame.width,
                    card.frame.width * 0.6,
                    "\"\(field.stringValue.prefix(40))…\" wrapped into a narrow column while "
                        + "the rest of its row sat empty"
                )
            }
        }
        XCTAssertGreaterThan(measured, 5, "too little wrapping text found to be measuring much")
    }

    func testThePageStaysInsideTheThemeBoundary() {
        let controller = page(reader())
        XCTAssertEqual(ThemeBoundaryAudit.violations(in: controller.view), [])
    }

    func testTheStatusIndicatorFollowsALiveThemeSwitch() throws {
        AppThemePalette.set(AppThemeStyles.cyberpunk)
        let controller = page(reader(accessibility: true))

        let glyph = try XCTUnwrap(
            ([try row(.accessibility, in: controller)]
                + descendants(in: try row(.accessibility, in: controller)))
                .compactMap { $0 as? NSTextField }
                .first { $0.stringValue == "●" },
            "the row has no status indicator"
        )
        let underCyberpunk = try XCTUnwrap(glyph.textColor?.usingColorSpace(.sRGB))

        AppThemePalette.set(AppThemeStyles.swissMinimalist)
        AppThemeRefresh.repaint(controller.view)
        let underSwiss = try XCTUnwrap(glyph.textColor?.usingColorSpace(.sRGB))

        XCTAssertNotEqual(
            underCyberpunk,
            underSwiss,
            "the status indicator kept its old theme's colour through a live switch"
        )
    }

    // MARK: - Rendered State

    /// Whether four permission rows read as a scannable list or as a wall of grey is not a claim
    /// any constraint assertion settles. `THREADING_RENDER_OUT` redirects the output.
    func testPrivacyPageRendersInBothAppearances() throws {
        let output = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        if let output {
            try FileManager.default.createDirectory(
                at: output,
                withIntermediateDirectories: true
            )
        }

        for (name, appearanceName) in [
            ("light", NSAppearance.Name.aqua),
            ("dark", .darkAqua)
        ] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            var png: Data?

            appearance.performAsCurrentDrawingAppearance {
                let controller = self.page(
                    self.reader(
                        accessibility: true,
                        screenRecording: false,
                        notifications: .allowed
                    ),
                    height: 1100
                )
                let host = NSView(frame: controller.view.frame)
                controller.view.translatesAutoresizingMaskIntoConstraints = false
                host.addSubview(controller.view)
                NSLayoutConstraint.activate([
                    controller.view.topAnchor.constraint(equalTo: host.topAnchor),
                    controller.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                    controller.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                    controller.view.trailingAnchor.constraint(equalTo: host.trailingAnchor)
                ])
                host.appearance = appearance
                controller.view.appearance = appearance
                host.wantsLayer = true
                host.layer?.backgroundColor = Design.Surface.ground.cgColor
                AppThemeRefresh.repaint(host)
                host.layoutSubtreeIfNeeded()

                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                    return
                }
                host.cacheDisplay(in: host.bounds, to: rep)
                png = rep.representation(using: .png, properties: [:])
            }

            let rendered = try XCTUnwrap(png, "the \(name) page produced no image")
            XCTAssertGreaterThan(rendered.count, 20_000, "\(name) privacy page rendered empty")

            let attachment = XCTAttachment(data: rendered, uniformTypeIdentifier: "public.png")
            attachment.name = "privacy-settings-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)

            if let output {
                try rendered.write(
                    to: output.appendingPathComponent("privacy-settings-\(name).png")
                )
            }
        }
    }
}
