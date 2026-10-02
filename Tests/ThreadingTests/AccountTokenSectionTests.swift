import AppKit
import XCTest
@testable import Threading

/// The Accounts page's one-year sign-in card.
@MainActor
final class AccountTokenSectionTests: XCTestCase {

    private enum Render {
        static let width = SettingsUIDefaults.pageWidth

        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
               !override.isEmpty {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }
    }

    private let claude = AgentAccount(
        provider: .claude,
        handle: .named("claude-work"),
        configPath: "/tmp/claude-work",
        displayName: "Work"
    )
    private let codex = AgentAccount(
        provider: .codex,
        handle: .named("codex-work"),
        configPath: "/tmp/codex-work",
        displayName: "Codex Work"
    )
    private let token = "sk-ant-oat01-" + String(repeating: "Ab1-_", count: 20)
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private var store: AgentAccountTokenStore!
    private var vault: AgentAccountTokenVault!

    override func setUp() {
        super.setUp()
        store = AgentAccountTokenStore(
            keychain: InMemoryKeychainItemAccess(),
            service: "test",
            dataProtection: { false }
        )
        let fixedNow = now
        vault = AgentAccountTokenVault(store: store, now: { fixedNow })
    }

    // MARK: - Status

    func testTheRowSaysHowTheLoginSignsInAndWhenThatEnds() {
        XCTAssertEqual(
            AccountTokenSectionController.status(of: nil, at: now),
            "Signs in through the browser"
        )

        let fresh = AgentAccountToken(value: token, savedAt: now)
        XCTAssertTrue(
            AccountTokenSectionController.status(of: fresh, at: now).hasPrefix("One-year token until ")
        )

        let ending = AgentAccountToken(value: token, savedAt: now.addingTimeInterval(-350 * 86_400))
        XCTAssertTrue(
            AccountTokenSectionController.status(of: ending, at: now).hasSuffix("Replace it soon.")
        )

        let ended = AgentAccountToken(value: token, savedAt: now.addingTimeInterval(-400 * 86_400))
        XCTAssertTrue(
            AccountTokenSectionController.status(of: ended, at: now).hasPrefix("Token ran out ")
        )
    }

    // MARK: - Rows

    func testListsOnlyLoginsWhoseRuntimeTakesAToken() {
        let section = AccountTokenSectionController(vault: vault)
        XCTAssertEqual(section.eligibleIndices(in: [codex, claude, codex]), [1])
        XCTAssertEqual(section.eligibleIndices(in: [codex]), [])
    }

    func testOffersATokenUntilOneIsSavedThenOffersToReplaceOrRemoveIt() {
        let section = AccountTokenSectionController(vault: vault, now: { self.now })
        _ = section.eligibleIndices(in: [claude])

        XCTAssertEqual(buttonTitles(in: section.rowContent(forAccountAt: 0)), ["Use Token…"])

        XCTAssertTrue(store.save(AgentAccountToken(value: token, savedAt: now), for: claude.id))
        _ = vault.token(for: claude.id)
        XCTAssertEqual(
            buttonTitles(in: section.rowContent(forAccountAt: 0)),
            ["Replace…", "Remove"]
        )
    }

    func testRemoveReturnsTheLoginToTheBrowserAndRestampsTheRow() throws {
        let section = AccountTokenSectionController(vault: vault, now: { self.now })
        _ = section.eligibleIndices(in: [claude])
        XCTAssertTrue(store.save(AgentAccountToken(value: token, savedAt: now), for: claude.id))
        _ = vault.token(for: claude.id)

        let restamped = expectation(description: "restamped")
        section.onRowsChange = { restamped.fulfill() }
        let remove = try XCTUnwrap(buttons(in: section.rowContent(forAccountAt: 0))
            .first { $0.title == "Remove" })
        _ = (remove.target as AnyObject?)?.perform(remove.action, with: remove)
        wait(for: [restamped], timeout: 5)

        XCTAssertNil(vault.token(for: claude.id))
        XCTAssertEqual(buttonTitles(in: section.rowContent(forAccountAt: 0)), ["Use Token…"])
    }

    /// The limit decides whether to use a token at all, so it is said on the card and in the
    /// sheet, not only behind the "?".
    func testTheModelsOnlyLimitIsVisibleWhereTheChoiceIsMade() {
        let section = AccountTokenSectionController(vault: vault)
        let note = section.noteContent() as? NSTextField

        for text in [note?.stringValue ?? "", AccountTokenStrings.sheetMessage] {
            XCTAssertTrue(text.contains("models only"), text)
            XCTAssertTrue(text.contains("Remote Control"), text)
            XCTAssertTrue(text.contains("connectors"), text)
        }
    }

    func testTheAccountsPageListsTheCardForClaudeLoginsOnly() throws {
        let suite = "AccountTokenSectionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let controller = AccountsPreferencesViewController(
            accountsProvider: { [claude, codex] in [claude, codex] },
            limitSettings: CustomLimitSettings(defaults: defaults),
            accountStore: AccountPreferencesStore(defaults: defaults)
        )
        let page = controller.view
        controller.viewWillAppear()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 2_400),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let host = try XCTUnwrap(window.contentView)
        page.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: host.topAnchor),
            page.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
        host.layoutSubtreeIfNeeded()

        let titles = buttons(in: host).map(\.title)
        XCTAssertEqual(titles.filter { $0 == "Use Token…" }.count, 1, "One row, for the Claude login")
        XCTAssertTrue(labels(in: host).contains { $0.contains("models only") })
    }

    // MARK: - Render

    func testRendersTheCardToImages() throws {
        XCTAssertTrue(store.save(AgentAccountToken(value: token, savedAt: now), for: claude.id))
        let other = AgentAccount(
            provider: .claude,
            handle: .named("claude-personal"),
            configPath: "/tmp/claude-personal",
            displayName: "Personal"
        )
        let ending = AgentAccount(
            provider: .claude,
            handle: .named("claude-ending"),
            configPath: "/tmp/claude-ending",
            displayName: "Ending Soon"
        )
        XCTAssertTrue(store.save(
            AgentAccountToken(value: token, savedAt: now.addingTimeInterval(-350 * 86_400)),
            for: ending.id
        ))
        let section = AccountTokenSectionController(vault: vault, now: { self.now })
        let indices = section.eligibleIndices(in: [claude, other, ending])
        indices.forEach { _ = vault.token(for: [claude, other, ending][$0].id) }

        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            let stack = NSStackView(views: [section.captionContent()]
                + indices.map { section.rowContent(forAccountAt: $0) }
                + [section.noteContent()])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = Design.Spacing.small
            stack.edgeInsets = NSEdgeInsets(
                top: Design.Spacing.large,
                left: Design.Spacing.large,
                bottom: Design.Spacing.large,
                right: Design.Spacing.large
            )
            stack.appearance = appearance
            for row in stack.arrangedSubviews {
                row.widthAnchor.constraint(
                    equalToConstant: Render.width - 2 * Design.Spacing.large
                ).isActive = true
            }
            let host = NSView(frame: NSRect(x: 0, y: 0, width: Render.width, height: 10))
            host.appearance = appearance
            stack.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: host.topAnchor),
                stack.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                stack.widthAnchor.constraint(equalToConstant: Render.width)
            ])
            host.layoutSubtreeIfNeeded()
            host.setFrameSize(NSSize(width: Render.width, height: max(stack.fittingSize.height, 1)))
            host.layoutSubtreeIfNeeded()

            var data: Data?
            appearance.performAsCurrentDrawingAppearance {
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
                host.wantsLayer = true
                host.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                host.cacheDisplay(in: host.bounds, to: rep)
                data = rep.representation(using: .png, properties: [:])
            }
            try XCTUnwrap(data, "Failed to render the card in \(name)")
                .write(to: directory.appendingPathComponent("account-tokens-\(name).png"))

            // Every control stays inside the pane at the real Settings width.
            for button in buttons(in: host) {
                let frame = button.convert(button.bounds, to: host)
                XCTAssertLessThanOrEqual(frame.maxX, host.bounds.maxX + 0.5, button.title)
            }
        }
    }

    // MARK: - Helpers

    private func buttons(in view: NSView) -> [ThemedButton] {
        ((view as? ThemedButton).map { [$0] } ?? []) + view.subviews.flatMap { buttons(in: $0) }
    }

    private func buttonTitles(in view: NSView) -> [String] {
        buttons(in: view).map(\.title)
    }

    private func labels(in view: NSView) -> [String] {
        ((view as? NSTextField).map { [$0.stringValue] } ?? [])
            + view.subviews.flatMap { labels(in: $0) }
    }
}
