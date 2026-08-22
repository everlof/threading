import AppKit
import XCTest
@testable import Threading

/// The "Your Own Limits" section of the Accounts page.
///
/// Built over its own preference suite rather than the shared stores: a settings test that wrote
/// through `.shared` would be leaving rules in whatever the next test in the process reads, which
/// is exactly the contamination the redirect exists to prevent rather than one to reintroduce a
/// page at a time.
@MainActor
final class AccountLimitsSectionTests: XCTestCase {

    private enum Render {
        static let width = SettingsUIDefaults.pageWidth
        static let height: CGFloat = 900

        static var directory: URL {
            // Non-empty, deliberately: an override set to "" resolves to `/`, and the failure
            // that produces is a read-only-volume error three frames deep in a PNG write rather
            // than anything that names the environment.
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
               !override.isEmpty {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }
    }

    /// One scratch suite for the whole class, cleared at both ends.
    ///
    /// A fresh `UUID` suite per *test method* is the obvious shape and the wrong one: each is a
    /// real preferences domain the daemon then holds, a run of this target left a hundred of them
    /// behind, and `scripts/test.sh` sweeps them afterwards precisely because they accumulate.
    /// Clearing in `setUp` as well as `tearDown` buys the same isolation — a crashed test's
    /// leftovers are gone before the next one reads anything — at four domains instead of forty.
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var settings: CustomLimitSettings!
    private var accountStore: AccountPreferencesStore!
    private var section: AccountLimitsSectionController!

    private let account = AgentAccount(
        provider: .claude,
        handle: .named("claude-work"),
        configPath: "/tmp/claude-work",
        displayName: "Work"
    )

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "AccountLimitsSectionTests"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        settings = CustomLimitSettings(defaults: defaults)
        accountStore = AccountPreferencesStore(defaults: defaults)
        section = AccountLimitsSectionController(
            settings: settings,
            accountStore: accountStore
        )
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Layout

    /// The section must measure something at the width the pane actually gives it, and must not
    /// reach past that width — a control aligned by ink still has to fit the card it sits in.
    func testTheSectionBuildsAndFitsThePane() {
        section.reload(accounts: [account])
        let host = laidOut(section.view, width: Render.width)

        XCTAssertGreaterThan(section.view.frame.height, 100, "the limits section collapsed")
        XCTAssertLessThanOrEqual(section.view.frame.width, host.bounds.width)
    }

    /// Every fold fills the column.
    ///
    /// The assertion above passed while the cards sat at about a third of the pane with the rest
    /// empty — a vertical stack aligned `.leading` gives each arranged view its *fitting* width —
    /// and the label column cut to that width wrapped a one-line caption into five lines and
    /// truncated `Claude Code` to `Clau`. Only the render showed it, so the render's finding is
    /// kept as an assertion.
    func testEveryFoldFillsTheColumn() {
        section.reload(accounts: [account])
        _ = laidOut(section.view, width: Render.width)

        let folds = descendants(of: section.view).compactMap { $0 as? SettingsCard }
        XCTAssertFalse(folds.isEmpty, "the section built no cards at all")
        for fold in folds {
            XCTAssertEqual(
                fold.frame.width,
                section.view.frame.width,
                accuracy: 1,
                "a card is hugging its content instead of filling the column"
            )
        }
    }

    /// The narrow pane is where a row's trailing control gets pushed out of its card, so the
    /// section is measured there too.
    func testTheSectionSurvivesASqueezedPane() {
        settings.add(
            .alert(windowID: UsageDefaults.weeklyWindowID, at: 0.5),
            for: account.id,
            store: accountStore
        )
        section.reload(accounts: [account])

        let host = laidOut(section.view, width: 420)
        XCTAssertLessThanOrEqual(section.view.frame.width, host.bounds.width)
    }

    // MARK: - What It Says

    /// The shipped default is no rules at all, and the page has to read as that rather than as an
    /// empty form.
    func testAnUntouchedAccountReadsAsHavingNone() {
        XCTAssertEqual(AccountLimitsStrings.summary(count: 0), "No limits")
        XCTAssertEqual(AccountLimitsStrings.summary(count: 1), "1 limit")
        XCTAssertEqual(AccountLimitsStrings.summary(count: 3), "3 limits")
    }

    /// **The honesty boundary, in the page's own words.**
    ///
    /// Threading can guarantee its own conduct and cannot stop the keyboard, so the copy has to
    /// say both. This assertion exists because the first version of this page said "nothing is
    /// held back and no session is stopped" — true when the only tier was a notification, and a
    /// confident lie the day holds shipped. The render is what caught it; this is what keeps it
    /// caught.
    func testTheExplanationStatesTheHonestyBoundary() {
        let text = AccountLimitsStrings.explanation

        XCTAssertTrue(
            text.localizedCaseInsensitiveContains("never stops the keyboard"),
            "the copy stopped saying the one thing a limit cannot do: \(text)"
        )
        XCTAssertTrue(
            text.localizedCaseInsensitiveContains("yours"),
            "the copy has stopped saying whose line this is"
        )
        XCTAssertFalse(
            text.localizedCaseInsensitiveContains("nothing is held back"),
            "the copy still claims nothing is held back, which stopped being true at tier 3"
        )
    }

    /// Every operable control carries a name, including the switch, whose row title is the
    /// sentence and whose own label has to stand alone in the rotor.
    func testTheAlertsSwitchIsNamed() throws {
        section.reload(accounts: [account])
        _ = laidOut(section.view, width: Render.width)

        let toggles = descendants(of: section.view).compactMap { $0 as? ThemedToggle }
        let named = try XCTUnwrap(toggles.first)
        XCTAssertEqual(named.accessibilityLabel(), AccountLimitsStrings.alertsToggleLabel)
    }

    /// A window with no reading yet is still named, not spelled as its identifier.
    ///
    /// A limit can be drawn before its account has ever been read, and until the reading lands
    /// there is no `Window` to take a `label` from. The first render of this page said `Watch 7d`
    /// over `No 7d reading yet.` on a page whose every other line says `Weekly` — an identifier is
    /// a key, and a key on screen reads as a leak.
    func testAWindowWithNoReadingIsStillNamed() {
        XCTAssertEqual(UsageDefaults.label(forWindowID: UsageDefaults.weeklyWindowID), "Weekly")
        XCTAssertEqual(UsageDefaults.label(forWindowID: UsageDefaults.fiveHourWindowID), "5-hour")
        XCTAssertEqual(
            UsageDefaults.label(forWindowID: "opus-1m"),
            "opus-1m",
            "a window this table does not know keeps its identifier, which is then all that is known"
        )
    }

    /// A rule's row names the rule in the user's own terms and states where it stands, rather
    /// than printing a stored fraction at them.
    func testARulesRowNamesItInTheUsersTerms() {
        let rule = CustomLimit.alert(windowID: UsageDefaults.weeklyWindowID, at: 0.5)
        XCTAssertEqual(
            CustomLimitReceipt.name(for: rule, windowName: "Weekly"),
            "Keep Weekly under 50%"
        )
        XCTAssertEqual(
            CustomLimitReceipt.name(
                for: .everyStep(windowID: UsageDefaults.weeklyWindowID, step: 0.1),
                windowName: "Weekly"
            ),
            "Watch Weekly",
            "a rule at the provider's own line has no bound of its own to name"
        )
    }

    /// Exact inputs live one level below the presets so the primary menu stays readable at the
    /// Settings window's compact height. Testing the real menu tree matters: a prompt factory can
    /// exist and still be unreachable from the Add button.
    func testCustomValuesSubmenuOffersEveryExactRoute() throws {
        section.reload(accounts: [account])
        let windows = section.templateEntriesForTesting(account: account)
        guard case .item(let window) = try XCTUnwrap(windows.first),
              let submenu = window.submenu else {
            return XCTFail("the Add Limit menu built no window submenu")
        }
        let customValues = try XCTUnwrap(submenu.compactMap { entry -> ThemedMenuItem? in
            guard case .item(let item) = entry else { return nil }
            return item.title == AccountLimitsStrings.customValuesMenu ? item : nil
        }.first)
        let customEntries = try XCTUnwrap(customValues.submenu)
        let titles = customEntries.compactMap { entry -> String? in
            guard case .item(let item) = entry else { return nil }
            return item.title
        }

        XCTAssertEqual(
            titles,
            AccountLimitCustomTemplate.allCases.map(\.menuTitle),
            "the Custom values submenu does not expose every percentage-bearing rule"
        )
    }

    /// The words "leave 37%" store the complement as the pace share: Threading may use 63% of
    /// what the clock has released. That inversion is the subtle part of the feature and must
    /// not be re-derived at the call site.
    func testCustomValuesBecomeTheExactRuleThePromptDescribes() throws {
        let windowID = UsageDefaults.weeklyWindowID

        XCTAssertEqual(
            try XCTUnwrap(AccountLimitCustomTemplate.alert.rule(
                windowID: windowID,
                values: [37]
            )).bound,
            0.37,
            accuracy: 0.000_001
        )

        let repeating = try XCTUnwrap(AccountLimitCustomTemplate.repeatingAlert.rule(
            windowID: windowID,
            values: [17]
        ))
        XCTAssertEqual(repeating.thresholds, [0.17, 0.34, 0.51, 0.68, 0.85])

        let synthetic = try XCTUnwrap(AccountLimitCustomTemplate.syntheticWindow.rule(
            windowID: windowID,
            values: [23, 12]
        ))
        XCTAssertEqual(synthetic.bound, 0.23, accuracy: 0.000_001)
        XCTAssertEqual(synthetic.trailingSpan, 12 * 3_600)

        let reserve = try XCTUnwrap(AccountLimitCustomTemplate.reserveShare.rule(
            windowID: windowID,
            values: [37]
        ))
        XCTAssertEqual(reserve.metric, .paceShare)
        XCTAssertEqual(reserve.bound, 0.63, accuracy: 0.000_001)

        XCTAssertNil(AccountLimitCustomTemplate.cap.rule(windowID: windowID, values: [0]))
        XCTAssertNil(AccountLimitCustomTemplate.cap.rule(windowID: windowID, values: [100]))
        XCTAssertNil(AccountLimitCustomTemplate.syntheticWindow.rule(
            windowID: windowID,
            values: [20, CustomLimitDefaults.maximumSyntheticWindowHours + 1]
        ))
    }

    /// Invalid input stays in the real themed alert and replaces the standing range hint with a
    /// concrete correction. This is the interaction that keeps a typo from looking like an Add
    /// button that did nothing.
    func testTheCustomPromptValidatesBeforeItDismisses() throws {
        let request = AccountLimitCustomTemplate.alert.prompt(windowName: "Weekly")
        let alert = IntegerPromptAlert.makeAlert(request)
        let content = alert.makeContentView()
        let fields = descendants(of: content).compactMap { $0 as? ThemedTextField }
        let buttons = descendants(of: content).compactMap { $0 as? ThemedButton }
        let add = try XCTUnwrap(buttons.first { $0.title == AccountLimitsStrings.addAlert })
        let field = try XCTUnwrap(fields.first)

        field.stringValue = "100"
        add.performClick(nil)

        let labels = descendants(of: content).compactMap { $0 as? NSTextField }
        XCTAssertTrue(
            labels.contains { $0.stringValue.contains("1") && $0.stringValue.contains("99") },
            "the invalid percentage left no visible range correction"
        )
        XCTAssertTrue(
            content.isDescendant(of: field) || field.isDescendant(of: content),
            "validation replaced the prompt instead of keeping its field in place"
        )
    }

    // MARK: - Images

    /// Drawn light and dark, because the section is rows of quiet secondary text inside folds and
    /// that is the kind of thing an assertion cannot review.
    func testRendersTheLimitsSectionToImages() throws {
        settings.addDefault(
            .everyStep(
                windowID: UsageDefaults.weeklyWindowID,
                step: CustomLimitDefaults.tenPercentStep
            )
        )
        settings.add(
            .alert(windowID: UsageDefaults.weeklyWindowID, at: 0.5),
            for: account.id,
            store: accountStore
        )
        section.reload(accounts: [account])
        section.expandEverythingForTesting()

        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var written = 0
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            let host = laidOut(section.view, width: Render.width)
            host.appearance = appearance
            section.view.appearance = appearance

            var data: Data?
            appearance.performAsCurrentDrawingAppearance {
                host.layoutSubtreeIfNeeded()
                data = png(of: host)
            }

            let url = directory.appendingPathComponent("account-limits-\(name).png")
            try XCTUnwrap(data, "Failed to render the limits section in \(name)").write(to: url)
            written += 1
            section.view.removeFromSuperview()
        }

        XCTAssertEqual(written, 2)
    }

    /// The shipping Accounts page, its actual Add Limit submenu, the exact-value submenu, and
    /// both shapes of custom authoring dialog, under System and the two deliberately opposed
    /// authored themes used by the Settings evidence catalogue.
    /// The page is scrolled to its limit folds; a top-only capture would render the account rows
    /// and prove nothing about the feature being changed.
    func testRendersCustomLimitAuthoringSurfaces() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        settings.addDefault(.everyStep(windowID: UsageDefaults.weeklyWindowID, step: 0.17))
        settings.add(
            .paceShare(windowID: UsageDefaults.weeklyWindowID, share: 0.63),
            for: account.id,
            store: accountStore
        )

        let previousTheme = AppThemePalette.current
        defer { AppThemePalette.set(previousTheme) }

        let fixtures: [(String, AppTheme, NSAppearance.Name)] = [
            ("system-light", .system, .aqua),
            ("cyberpunk", AppThemeStyles.cyberpunk, .darkAqua),
            ("swiss", AppThemeStyles.swissMinimalist, .aqua)
        ]

        var written = 0
        for (name, theme, appearanceName) in fixtures {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            appearance.performAsCurrentDrawingAppearance {
                AppThemePalette.set(theme)
            }

            var renderedPage: Data?
            appearance.performAsCurrentDrawingAppearance {
                renderedPage = accountPageImage(appearance: appearance)
            }
            let page = try XCTUnwrap(renderedPage)
            try page.write(to: directory.appendingPathComponent(
                "account-limit-custom-settings-\(name).png"
            ))
            written += 1

            let menu = try XCTUnwrap(customMenuImage(appearance: appearance))
            try menu.write(to: directory.appendingPathComponent(
                "account-limit-custom-menu-\(name).png"
            ))
            written += 1

            let customValues = try XCTUnwrap(customValuesMenuImage(appearance: appearance))
            try customValues.write(to: directory.appendingPathComponent(
                "account-limit-custom-choices-\(name).png"
            ))
            written += 1

            for (template, values, state) in [
                (AccountLimitCustomTemplate.reserveShare, [37], "reserve"),
                (AccountLimitCustomTemplate.syntheticWindow, [17, 12], "window")
            ] {
                var renderedPrompt: Data?
                appearance.performAsCurrentDrawingAppearance {
                    renderedPrompt = promptImage(
                        template: template,
                        values: values,
                        appearance: appearance
                    )
                }
                let prompt = try XCTUnwrap(renderedPrompt)
                try prompt.write(to: directory.appendingPathComponent(
                    "account-limit-custom-\(state)-\(name).png"
                ))
                written += 1
            }
        }

        print("Rendered \(written) custom-limit authoring surfaces to \(directory.path)")
        XCTAssertEqual(written, fixtures.count * 5)
    }

    // MARK: - Helpers

    private func laidOut(_ view: NSView, width: CGFloat) -> NSView {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: Render.height))
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
        host.layoutSubtreeIfNeeded()
        host.setFrameSize(NSSize(width: width, height: max(view.fittingSize.height, 1)))
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    private func png(of host: NSView) -> Data? {
        guard host.bounds.height > 1,
              let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }

        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    private func accountPageImage(appearance: NSAppearance) -> Data? {
        let controller = AccountsPreferencesViewController(
            accountsProvider: { [account = self.account] in [account] },
            setupCoordinator: AgentAccountSetupCoordinator(),
            limitSettings: settings,
            accountStore: accountStore
        )
        _ = controller.view
        controller.viewWillAppear()
        controller.expandLimitsForTesting()

        let host = NSView(frame: NSRect(
            origin: .zero,
            size: NSSize(width: Render.width, height: Render.height)
        ))
        host.appearance = appearance
        controller.view.appearance = appearance
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: host.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            controller.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
        AppThemeRefresh.repaint(host)
        host.layoutSubtreeIfNeeded()

        if let scroll = descendants(of: controller.view).compactMap({ $0 as? ThemedScrollView }).first,
           let document = scroll.documentView {
            let y = document.isFlipped
                ? max(0, document.bounds.height - scroll.contentView.bounds.height)
                : 0
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            host.layoutSubtreeIfNeeded()
        }
        return png(of: host)
    }

    private func promptImage(
        template: AccountLimitCustomTemplate,
        values: [Int],
        appearance: NSAppearance
    ) -> Data? {
        let alert = IntegerPromptAlert.makeAlert(template.prompt(windowName: "Weekly"))
        let content = alert.makeContentView()
        content.appearance = appearance
        for (field, value) in zip(
            descendants(of: content).compactMap({ $0 as? ThemedTextField }),
            values
        ) {
            field.stringValue = String(value)
        }
        AppThemeRefresh.repaint(content)
        content.layoutSubtreeIfNeeded()
        content.frame = NSRect(origin: .zero, size: content.fittingSize)
        content.layoutSubtreeIfNeeded()
        return png(of: content)
    }

    /// Presents the production submenu directly. The first level only chooses a provider
    /// window; this is the second level the user showed, where the presets and new custom routes
    /// have to coexist without clipping or losing their group structure.
    private func customMenuImage(appearance: NSAppearance) -> Data? {
        section.reload(accounts: [account])
        guard let first = section.templateEntriesForTesting(account: account).first,
              case .item(let window) = first,
              let entries = window.submenu else { return nil }

        return menuImage(entries: entries, appearance: appearance)
    }

    /// Presents the production Custom values submenu separately so the evidence proves that all
    /// five exact inputs remain discoverable after keeping the preset menu compact.
    private func customValuesMenuImage(appearance: NSAppearance) -> Data? {
        section.reload(accounts: [account])
        guard let first = section.templateEntriesForTesting(account: account).first,
              case .item(let window) = first,
              let entries = window.submenu,
              let customValues = entries.compactMap({ entry -> ThemedMenuItem? in
                  guard case .item(let item) = entry else { return nil }
                  return item.title == AccountLimitsStrings.customValuesMenu ? item : nil
              }).first,
              let customEntries = customValues.submenu else { return nil }

        return menuImage(entries: customEntries, appearance: appearance)
    }

    private func menuImage(entries: [ThemedMenuEntry], appearance: NSAppearance) -> Data? {
        let canvas = NSSize(width: 440, height: 700)
        var data: Data?
        appearance.performAsCurrentDrawingAppearance {
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: canvas),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.appearance = appearance

            let root = ThemedSurfaceView()
            root.frame = NSRect(origin: .zero, size: canvas)
            root.applySurface(fill: Design.Surface.background, radius: .fixed(0))
            let source = NSView(frame: NSRect(x: 12, y: canvas.height - 24, width: 1, height: 1))
            root.addSubview(source)
            window.contentView = root

            let token = ThemedMenuPresenter.present(
                ThemedMenuPresentation(entries: entries, minimumWidth: 260),
                from: source,
                selectedEntryIndex: nil,
                onChoose: { _, _ in },
                onDismiss: {}
            )
            defer { ThemedMenuPresenter.dismiss(token) }

            AppThemeRefresh.repaint(root)
            root.layoutSubtreeIfNeeded()
            data = png(of: root)
        }
        return data
    }
}
