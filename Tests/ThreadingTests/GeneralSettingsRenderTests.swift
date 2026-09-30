import AppKit
import XCTest
@testable import Threading

/// Draws General and the four pages split out of it — Sidebar, Chats, Notifications and
/// Integration — and writes them out, light and dark.
///
/// General was the longest page in the app and the one that grew: every behavioural setting
/// landed there as another card until it ran to twenty-two captions. The split holds only while
/// each page stays something a reader can take in at a glance, and that is decided by things no
/// assertion is written for — whether a refinement row sits *under* the switch it refines,
/// whether a disabled toggle still looks like a control that is waiting rather than one that is
/// broken, whether a card's second lines have crept back into a wall.
///
/// The assertions catch what an image cannot: a card that measures nothing, refinement rows that
/// outlive the switch they belong to, and explanations that moved behind a "?" and went missing.
final class GeneralSettingsRenderTests: XCTestCase {

    private enum Render {
        /// The width the pane gives a settings page, and a squeezed pane — the notification
        /// rows carry the longest second lines on the page, so they wrap first.
        static let widths: [CGFloat] = [420, SettingsUIDefaults.pageWidth]

        /// The page is a scroll view, so it has no height of its own to be sized to. Tall
        /// enough for the longest of the five at the squeezed width, so every card has rendered
        /// evidence without a second, bottom-pinned viewport.
        static let height: CGFloat = 2400

        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
               !override.isEmpty {
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
        let controller = NotificationsPreferencesViewController()
        laidOut(controller.view, width: SettingsUIDefaults.pageWidth)

        let labels = Self.labels(in: controller.view)

        for alert in AttentionAlert.allCases {
            XCTAssertTrue(
                labels.contains(alert.settingsTitle),
                "\(alert.rawValue) has no row on the Notifications page"
            )
            XCTAssertTrue(
                labels.contains { $0.contains(alert.body) },
                "\(alert.rawValue)'s row does not say what its notification says"
            )
        }

        XCTAssertTrue(labels.contains(L10n.string("Alert sound")))
        XCTAssertTrue(labels.contains(L10n.string("Notify when a session needs you")))
    }

    /// The sound picker lists what this machine actually has.
    ///
    /// Read-only on purpose: the bundle is hosted in the app, so writing a choice here would
    /// change the sound the developer's own copy plays. What is worth holding is the shape —
    /// Off and the default first, every sound the search paths answer for, and the way in for
    /// one of the user's own last — plus the fact that a name is only ever offered if it
    /// resolves, since a name that resolves nowhere posts the banner in silence.
    ///
    /// Off is here because the checkbox that used to express it is gone: if silence is not in
    /// this list, an install that had alerts switched off has no way to say so again.
    @MainActor
    func testTheAlertSoundPickerOffersTheDefaultEveryInstalledSoundAndAWayToAddOne() throws {
        let controller = NotificationsPreferencesViewController()
        laidOut(controller.view, width: SettingsUIDefaults.pageWidth)

        let popUp = try XCTUnwrap(
            Self.view(in: controller.view, identifiedBy: "settings.notifications.alert-sound")
                as? ThemedPopUp,
            "the notification card has no reachable alert sound control"
        )
        let items = (0..<popUp.numberOfItems).compactMap { popUp.item(at: $0) }

        XCTAssertEqual(items.first?.title, L10n.string("Off"))
        XCTAssertEqual(items.first?.representedValue as? SoundChoice, .silent)
        XCTAssertEqual(items.dropFirst().first?.title, L10n.string("macOS Alert Sound"))
        XCTAssertEqual(items.dropFirst().first?.representedValue as? SoundChoice, .system)
        XCTAssertEqual(items.last?.title, L10n.string("Add a Sound…"))

        let offered = Set(items.dropFirst(2).dropLast().compactMap {
            ($0.representedValue as? SoundChoice).flatMap {
                if case .named(let fileName) = $0 { return fileName } else { return nil }
            }
        })
        XCTAssertEqual(offered, Set(NotificationSoundLibrary.available().map(\.fileName)))
        XCTAssertFalse(offered.isEmpty, "macOS ships alert sounds; none were listed")
        for fileName in offered {
            XCTAssertNotNil(
                NotificationSoundLibrary.resolve(fileName: fileName),
                "\(fileName) is offered but resolves nowhere, so it would post in silence"
            )
        }

        XCTAssertEqual(
            popUp.selectedItem?.representedValue as? SoundChoice,
            AppSettings.shared.attentionAlertSound
        )
    }

    /// The bell picker offers the same sounds in the same order.
    ///
    /// Nothing in the Notifications card applies to the bell, so if Off is not in this list
    /// there is no way to stop a program beeping, which is the thing people actually want from
    /// a bell setting. It is also deliberately *first*: reaching for a bell setting usually
    /// means reaching for silence.
    @MainActor
    func testTheBellPickerLeadsWithOffAndOffersTheSameSounds() throws {
        let controller = NotificationsPreferencesViewController()
        laidOut(controller.view, width: SettingsUIDefaults.pageWidth)

        let popUp = try XCTUnwrap(
            Self.view(in: controller.view, identifiedBy: "settings.notifications.bell-sound")
                as? ThemedPopUp,
            "the terminal bell card has no reachable sound control"
        )
        let items = (0..<popUp.numberOfItems).compactMap { popUp.item(at: $0) }

        XCTAssertEqual(items.first?.representedValue as? SoundChoice, .silent)
        XCTAssertEqual(items.dropFirst().first?.representedValue as? SoundChoice, .system)
        XCTAssertEqual(items.last?.title, L10n.string("Add a Sound…"))

        // The same vocabulary as the alert sound, which is the point of sharing the builder.
        let offered = Set(items.dropFirst(2).dropLast().compactMap {
            ($0.representedValue as? SoundChoice).flatMap {
                if case .named(let fileName) = $0 { return fileName } else { return nil }
            }
        })
        XCTAssertEqual(offered, Set(NotificationSoundLibrary.available().map(\.fileName)))

        XCTAssertEqual(
            popUp.selectedItem?.representedValue as? SoundChoice,
            AppSettings.shared.terminalBellSound
        )
        XCTAssertTrue(Self.labels(in: controller.view).contains(L10n.string("Bell sound")))
    }

    /// The other half of the register, and the half a type cannot enforce: a prompt whose alert
    /// offers "Don't ask again" must have a row that turns it back on, or ticking that box is a
    /// one-way door. Built from `ConfirmationPrompt.suppressible` for exactly that reason, and
    /// held to it here. The section's "?" is asserted too — six toggles cannot say by
    /// themselves that everything destructive is deliberately absent.
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
        let help = Self.helpText(in: controller.view)
        XCTAssertTrue(
            help.contains { $0.contains("always asks") },
            "the section has to say why the destructive prompts are not on this list"
        )

        // The notice register's half of the same invariant: its keys are dynamic, so instead
        // of a row per key the card carries the one control that un-hides everything — and a
        // "Don't show this message again" box with no way back is the same one-way door.
        XCTAssertTrue(
            labels.contains(L10n.string("Hidden extension messages")),
            "notices can be hidden with no control to bring them back"
        )
        XCTAssertTrue(
            help.contains { $0.contains("failures always show") },
            "the row has to say that errors cannot be hidden"
        )
    }

    /// The startup policy is useful only if each provider is independently reachable and every
    /// state survives the UI boundary. Accessibility identifiers are part of that contract too:
    /// two identical three-row pop-ups cannot otherwise be distinguished by automation.
    @MainActor
    func testClaudeAndCodexStartupSpeedRowsOfferEveryState() throws {
        let controller = ChatsPreferencesViewController()
        laidOut(controller.view, width: SettingsUIDefaults.pageWidth)

        for (kind, identifier) in [
            (AgentKind.claude, "settings.chats.claude-startup-speed"),
            (AgentKind.codex, "settings.chats.codex-startup-speed")
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

    /// The subscription picker is the only way back off a beta, so it has to offer both levels
    /// and show the one currently in force.
    ///
    /// Read-only on purpose, for the reason the sound pickers are: the bundle is hosted in the
    /// app, so writing a choice here would change which builds the developer's own copy accepts.
    ///
    /// The copy is asserted — on the row's "?", where the long answer lives — because it
    /// carries the part the control cannot. Nightly is
    /// deliberately not an option — its date version outranks every release, so choosing stable
    /// again would strand the user — and a channel a person can be on with no mention on the
    /// page is a channel they cannot reason about. The row must name it and say how to leave.
    @MainActor
    func testUpdateChannelPickerOffersBothLevelsAndNamesNightly() throws {
        let controller = GeneralPreferencesViewController()
        laidOut(controller.view, width: SettingsUIDefaults.pageWidth)

        let popUp = try XCTUnwrap(
            Self.view(in: controller.view, identifiedBy: "settings.general.update-channel")
                as? ThemedPopUp,
            "the Software Updates card has no reachable channel control"
        )
        XCTAssertEqual(
            (0..<popUp.numberOfItems).compactMap { popUp.item(at: $0)?.title },
            UpdateChannelSubscription.allCases.map(\.settingsTitle)
        )
        XCTAssertEqual(
            popUp.selectedItem?.representedValue as? UpdateChannelSubscription,
            AppSettings.shared.updateChannelSubscription,
            "the picker shows a level other than the one the updater is actually using"
        )

        let labels = Self.labels(in: controller.view)
        XCTAssertTrue(labels.contains(L10n.string("Updates you receive")))
        XCTAssertTrue(
            Self.helpText(in: controller.view).contains {
                $0.contains("Nightly") && $0.contains("stable build yourself")
            },
            "the row has to name nightly and say that leaving it is a manual download"
        )
    }

    /// Detection is stored and consumed per `AgentKind`; the page must be built from that same
    /// set or a new runtime can tell the user to change a switch that does not exist.
    @MainActor
    func testEveryAgentKindHasAnAttachmentDetectionRow() throws {
        let controller = ChatsPreferencesViewController()
        laidOut(controller.view, width: SettingsUIDefaults.pageWidth)
        let labels = Self.labels(in: controller.view)

        for kind in AgentKind.allCases {
            XCTAssertTrue(
                labels.contains("Detect attachments from \(kind.displayName)"),
                "\(kind.displayName) has no attachment detection row"
            )
            let identifier = "settings.chats.\(kind.rawValue)-attachment-detection"
            let toggle = try XCTUnwrap(
                Self.view(in: controller.view, identifiedBy: identifier) as? ThemedToggle,
                "\(kind.displayName) has no reachable attachment detection control"
            )
            XCTAssertEqual(
                toggle.state == .on,
                AppSettings.shared.detectsAttachmentReferences(for: kind)
            )
        }
    }

    /// The power setting states its exact boundary on its "?": this is idle sleep only, not a
    /// promise that Threading can override a MacBook lid closure or keep the display lit.
    @MainActor
    func testPowerSettingIsReachableAndExplainsTheLidBoundary() throws {
        let controller = GeneralPreferencesViewController()
        laidOut(controller.view, width: SettingsUIDefaults.pageWidth)

        let toggle = try XCTUnwrap(
            Self.view(
                in: controller.view,
                identifiedBy: "settings.general.prevent-idle-system-sleep"
            ) as? ThemedToggle
        )
        XCTAssertEqual(
            toggle.state == .on,
            AppSettings.shared.preventsIdleSystemSleepWhileAgentsWork
        )

        let labels = Self.labels(in: controller.view)
        XCTAssertTrue(labels.contains(L10n.string("Keep this Mac awake while agents work")))
        XCTAssertTrue(
            Self.helpText(in: controller.view).contains { $0.contains("MacBook") },
            "the setting must not imply that an idle-sleep assertion overrides lid closure"
        )
    }

    @MainActor
    private static func labels(in view: NSView) -> Set<String> {
        var found: Set<String> = []
        if let field = view as? NSTextField { found.insert(field.stringValue) }
        for subview in view.subviews {
            found.formUnion(labels(in: subview))
        }
        return found
    }

    /// Everything the page's "?" buttons explain, as VoiceOver hears it. The long half of a
    /// row's copy moved behind the press, and this is where an assertion about it now looks.
    @MainActor
    private static func helpText(in view: NSView) -> [String] {
        var found: [String] = []
        if let button = view as? HelpPopoverButton { found.append(button.topic.spokenSummary) }
        for subview in view.subviews {
            found += helpText(in: subview)
        }
        return found
    }

    @MainActor
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
        try render("general") { GeneralPreferencesViewController() }
    }

    @MainActor
    func testRendersSidebarSettingsToImages() throws {
        try render("sidebar") { SidebarPreferencesViewController() }
    }

    @MainActor
    func testRendersChatsSettingsToImages() throws {
        try render("chats") { ChatsPreferencesViewController() }
    }

    @MainActor
    func testRendersNotificationsSettingsToImages() throws {
        try render("notifications") { NotificationsPreferencesViewController() }
    }

    @MainActor
    func testRendersIntegrationSettingsToImages() throws {
        try render("integration") { IntegrationPreferencesViewController() }
    }

    /// One page at both widths, light and dark, named `<page>-<width>-<appearance>.png` so each
    /// page's UI-evidence entry can glob its own images.
    @MainActor
    private func render(
        _ page: String,
        _ make: @escaping () -> NSViewController
    ) throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var written: [String] = []
        for width in Render.widths {
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let url = directory.appendingPathComponent("\(page)-\(Int(width))-\(name).png")
                let data = try XCTUnwrap(
                    pageImage(make, width: width, appearance: appearance),
                    "Failed to render the \(page) page at \(width)pt in \(name)"
                )
                try data.write(to: url)
                written.append(url.lastPathComponent)
            }
        }

        print("Rendered \(written.count) \(page) pages to \(directory.path)")
        XCTAssertEqual(written.count, Render.widths.count * 2)
    }

    // MARK: - Helpers

    @MainActor
    private func pageImage(
        _ make: @escaping () -> NSViewController,
        width: CGFloat,
        appearance name: NSAppearance.Name
    ) -> Data? {
        let appearance = NSAppearance(named: name)

        var data: Data?
        let render = {
            let controller = make()
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
            // A detached fixture's frame is only an initial size. State both capture dimensions
            // as constraints so content cannot turn the 420-point evidence into a wide page that
            // is merely photographed through the old frame.
            host.widthAnchor.constraint(equalToConstant: width),
            host.heightAnchor.constraint(equalToConstant: height),
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])

        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.bounds.width, width, accuracy: 0.5, "the fixture widened its capture")
        XCTAssertEqual(
            host.bounds.height,
            height,
            accuracy: 0.5,
            "the fixture changed its capture height"
        )
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
