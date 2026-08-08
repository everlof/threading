import AppKit
import XCTest
@testable import Threading

/// Draws the General settings page and writes it out, light and dark.
///
/// General is the longest page in the app and the one that grows: every behavioural setting
/// lands here as another card, and a card reads as part of the page or as a pile depending on
/// things no assertion is written for — whether a refinement row sits *under* the switch it
/// refines, whether a disabled toggle still looks like a control that is waiting rather than
/// one that is broken, whether four rows of second lines turn a card into a wall.
///
/// The assertions catch what an image cannot: a card that measures nothing, and refinement
/// rows that outlive the switch they belong to.
final class GeneralSettingsRenderTests: XCTestCase {

    private enum Render {
        /// The width the pane gives a settings page, and a squeezed pane — the notification
        /// rows carry the longest second lines on the page, so they wrap first.
        static let widths: [CGFloat] = [420, SettingsUIDefaults.pageWidth]

        /// The page is a scroll view, so it has no height of its own to be sized to. Tall
        /// enough that the whole page is in the image rather than only what a window shows —
        /// the point is to review cards that sit well down the list, and the Confirmations
        /// card turned one row into six.
        static let height: CGFloat = 3600

        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }
    }

    // MARK: - Rows

    /// Every alert kind reaches the page. The rows are built from `AttentionAlert.allCases`
    /// precisely so a kind added later cannot arrive with no way to switch it off, and this is
    /// what holds that: a fourth case with no row would silently notify forever.
    @MainActor
    func testEveryAlertKindHasARowAndSoDoesTheSound() {
        let controller = GeneralPreferencesViewController()
        laidOut(controller.view, width: SettingsUIDefaults.pageWidth)

        let labels = Self.labels(in: controller.view)

        for alert in AttentionAlert.allCases {
            XCTAssertTrue(
                labels.contains(alert.settingsTitle),
                "\(alert.rawValue) has no row on the General page"
            )
            XCTAssertTrue(
                labels.contains { $0.contains(alert.body) },
                "\(alert.rawValue)'s row does not say what its notification says"
            )
        }

        XCTAssertTrue(labels.contains(L10n.string("Play a sound")))
        XCTAssertTrue(labels.contains(L10n.string("Notify when a session needs you")))
    }

    /// The other half of the register, and the half a type cannot enforce: a prompt whose alert
    /// offers "Don't ask again" must have a row that turns it back on, or ticking that box is a
    /// one-way door. Built from `ConfirmationPrompt.suppressible` for exactly that reason, and
    /// held to it here. The note is asserted too — six toggles cannot say by themselves that
    /// everything destructive is deliberately absent.
    @MainActor
    func testEverySuppressiblePromptHasARowAndTheNoteSaysWhatIsMissing() {
        let controller = GeneralPreferencesViewController()
        laidOut(controller.view, width: SettingsUIDefaults.pageWidth)

        let labels = Self.labels(in: controller.view)

        for prompt in ConfirmationPrompt.allCases {
            guard let suppression = prompt.suppression else {
                continue
            }
            XCTAssertTrue(
                labels.contains(suppression.settingsTitle),
                "\(prompt.rawValue) can be switched off with no row to switch it back on"
            )
            XCTAssertTrue(
                labels.contains(suppression.settingsSubtitle),
                "\(prompt.rawValue)'s row does not say what it stops asking about"
            )
        }

        // Section captions are drawn uppercased.
        XCTAssertTrue(labels.contains(L10n.string("Confirmations").localizedUppercase))
        XCTAssertTrue(
            labels.contains { $0.contains("always asks") },
            "the card has to say why the destructive prompts are not on this list"
        )

        // The notice register's half of the same invariant: its keys are dynamic, so instead
        // of a row per key the card carries the one control that un-hides everything — and a
        // "Don't show this message again" box with no way back is the same one-way door.
        XCTAssertTrue(
            labels.contains(L10n.string("Hidden extension messages")),
            "notices can be hidden with no control to bring them back"
        )
        XCTAssertTrue(
            labels.contains { $0.contains("failures always show") },
            "the row has to say that errors cannot be hidden"
        )
    }

    /// The startup policy is useful only if each provider is independently reachable and every
    /// state survives the UI boundary. Accessibility identifiers are part of that contract too:
    /// two identical three-row pop-ups cannot otherwise be distinguished by automation.
    @MainActor
    func testClaudeAndCodexStartupSpeedRowsOfferEveryState() throws {
        let controller = GeneralPreferencesViewController()
        laidOut(controller.view, width: SettingsUIDefaults.pageWidth)

        for (kind, identifier) in [
            (AgentKind.claude, "settings.general.claude-startup-speed"),
            (AgentKind.codex, "settings.general.codex-startup-speed")
        ] {
            let popUp = try XCTUnwrap(
                Self.view(in: controller.view, identifiedBy: identifier) as? ThemedPopUp,
                "\(kind) has no startup speed control"
            )
            XCTAssertEqual(
                (0..<popUp.numberOfItems).compactMap { popUp.item(at: $0)?.title },
                AgentStartupSpeed.allCases.map(\.settingsTitle)
            )
            XCTAssertEqual(
                popUp.selectedItem?.representedValue as? AgentStartupSpeed,
                AppSettings.shared.startupSpeed(for: kind)
            )
        }

        let labels = Self.labels(in: controller.view)
        XCTAssertTrue(labels.contains(L10n.string("Claude sessions start in")))
        XCTAssertTrue(labels.contains(L10n.string("Codex sessions start in")))
    }

    private static func labels(in view: NSView) -> Set<String> {
        var found: Set<String> = []
        if let field = view as? NSTextField { found.insert(field.stringValue) }
        for subview in view.subviews {
            found.formUnion(labels(in: subview))
        }
        return found
    }

    private static func view(in root: NSView, identifiedBy identifier: String) -> NSView? {
        if root.accessibilityIdentifier() == identifier { return root }
        for subview in root.subviews {
            if let found = view(in: subview, identifiedBy: identifier) { return found }
        }
        return nil
    }

    // MARK: - Rendering

    @MainActor
    func testRendersGeneralSettingsToImages() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var written: [String] = []

        for width in Render.widths {
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let url = directory.appendingPathComponent("general-\(Int(width))-\(name).png")
                let data = try XCTUnwrap(
                    pageImage(width: width, appearance: appearance),
                    "Failed to render the general page at \(width)pt in \(name)"
                )
                try data.write(to: url)
                written.append(url.lastPathComponent)
            }
        }

        print("Rendered \(written.count) general pages to \(directory.path)")
        XCTAssertEqual(written.count, Render.widths.count * 2)
    }

    // MARK: - Helpers

    @MainActor
    private func pageImage(width: CGFloat, appearance name: NSAppearance.Name) -> Data? {
        let appearance = NSAppearance(named: name)

        var data: Data?
        let render = {
            let controller = GeneralPreferencesViewController()
            let host = self.laidOut(controller.view, width: width, height: Render.height)
            host.appearance = appearance
            controller.view.appearance = appearance
            AppThemeRefresh.repaint(host)
            host.layoutSubtreeIfNeeded()
            data = self.png(of: host)
        }

        appearance?.performAsCurrentDrawingAppearance(render)
        return data
    }

    /// The page is a scroll view and has no fitting height, so the host states one and the
    /// page fills it — sizing to content would produce a zero-high image.
    @MainActor
    @discardableResult
    private func laidOut(
        _ view: NSView,
        width: CGFloat,
        height: CGFloat = Render.height
    ) -> NSView {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)

        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])

        host.layoutSubtreeIfNeeded()
        return host
    }

    @MainActor
    private func png(of host: NSView) -> Data? {
        guard host.bounds.height > 1,
              let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }

        // The settings page paints no ground of its own — it sits on the window's material —
        // so one is painted here, or every label draws onto transparency.
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
