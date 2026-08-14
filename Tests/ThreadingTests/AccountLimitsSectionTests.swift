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
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }
    }

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
        suiteName = "AccountLimitsSectionTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
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

    /// The copy must not promise what this slice does not do. A limit sold as a stop that a
    /// keystroke walks through would be the feature's version of a confident lie.
    func testTheExplanationDoesNotPromiseToStopAnything() {
        let text = AccountLimitsStrings.explanation
        XCTAssertTrue(text.contains("nothing is held back"), text)
        XCTAssertTrue(
            text.localizedCaseInsensitiveContains("yours"),
            "the copy has stopped saying whose line this is"
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
}
