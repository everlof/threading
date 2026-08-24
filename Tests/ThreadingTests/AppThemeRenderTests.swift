import AppKit
import XCTest
@testable import Threading

/// Draws a real conversation under each stock theme and writes it out.
///
/// This is the only way the chrome refactor can be reviewed at all. A theme's job is to change
/// how the whole surface reads, and no assertion about a token catches "the panels went neon
/// and every label stayed system grey" — which is exactly the state the app is in while the
/// call sites are still being routed. The contact sheet *is* the remaining work list.
@MainActor
final class AppThemeRenderTests: XCTestCase {

    private enum Render {
        static let width: CGFloat = 720
        static let rowLimit = 22

        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }

        /// A fixture with the widest colour surface: user bubbles, tool rows, a diff, and code.
        static var fixture: URL {
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/Transcripts/claude-edit-heavy.jsonl")
        }
    }

    override func tearDown() {
        AppThemePalette.set(.system)
        super.tearDown()
    }

    func testRendersAConversationUnderEveryStockTheme() throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: Render.fixture.path),
            "Missing fixture. Regenerate with scripts/scrub_transcript.py."
        )

        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let requestedThemeID = ProcessInfo.processInfo.environment[
            "THREADING_UI_EVIDENCE_THEME_ID"
        ]
        let themes = AppThemeLibrary.stock.filter { theme in
            requestedThemeID == nil || theme.id.rawValue == requestedThemeID
        }
        if let requestedThemeID, themes.isEmpty {
            XCTFail("Unknown stock theme requested for evidence: \(requestedThemeID)")
            return
        }

        var written: [String] = []

        for theme in themes {
            AppThemePalette.set(theme)

            if theme.isAdaptive {
                for (suffix, appearanceName) in [
                    ("light", NSAppearance.Name.aqua),
                    ("dark", .darkAqua)
                ] {
                    let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
                    let data = try XCTUnwrap(
                        image(for: theme, appearance: appearance),
                        "Failed to render \(theme.name) \(suffix)"
                    )
                    let url = directory.appendingPathComponent(
                        "chrome-\(theme.id.rawValue)-\(suffix).png"
                    )
                    try data.write(to: url)
                    written.append(url.lastPathComponent)
                }
                continue
            }

            let appearance = try XCTUnwrap(theme.mode.appearance)
            let data = try XCTUnwrap(
                image(for: theme, appearance: appearance),
                "Failed to render \(theme.name)"
            )
            let url = directory.appendingPathComponent("chrome-\(theme.id.rawValue).png")
            try data.write(to: url)
            written.append(url.lastPathComponent)
        }

        print("Rendered \(written.count) themed conversations to \(directory.path)")
        let expected = themes.reduce(0) {
            $0 + ($1.isAdaptive ? 2 : 1)
        }
        XCTAssertEqual(written.count, expected)
    }

    /// The dropdown at both of its densities — a plain choice list (check column only, with a
    /// separator and an action) and the composer's identity menu, whose rows carry the most a
    /// row can: a brand mark over its meter, a runtime-led subtitle, and values inked by their
    /// own window's pressure. The menu is an overlay drawn entirely by the app, so nothing but
    /// a render can say whether its spacing reads as a menu or as a smear — or whether a tinted
    /// 99% still reads over every stock ground.
    func testRendersTheDropdownMenu() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let plain: [ThemedMenuEntry] = [
            .item(ThemedMenuItem(title: "SONDA-386-387-source-governance — this checkout", isSelected: true)),
            .item(ThemedMenuItem(title: "Codex")),
            .separator,
            .item(ThemedMenuItem(title: "New Worktree…"))
        ]

        var written = 0
        let fixtures: [(String, [ThemedMenuEntry], NSSize)] = [
            ("plain", plain, NSSize(width: 420, height: 300)),
            // Tall enough for every row, wide enough that `ThemedMenuLayout.maximumWidth` is
            // what cuts the deliberately long Codex line — the ellipsis is part of the render.
            ("detailed", identityMenuEntries(), NSSize(width: 540, height: 540))
        ]
        for (name, entries, canvas) in fixtures {
            let variants: [(String, NSAppearance.Name, AppTheme)] = [
                ("light", .aqua, .system),
                ("dark", .darkAqua, .system),
                ("win98", .aqua, AppThemeStyles.win98)
            ]
            for (mode, appearanceName, theme) in variants {
                AppThemePalette.set(theme)
                let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
                var data: Data?
                appearance.performAsCurrentDrawingAppearance {
                    data = menuImage(entries: entries, appearance: appearance, canvas: canvas)
                }
                let url = directory.appendingPathComponent("menu-\(name)-\(mode).png")
                try XCTUnwrap(data, "Failed to render \(name) \(mode)").write(to: url)
                written += 1
            }
        }
        print("Rendered \(written) menus to \(directory.path)")
        XCTAssertEqual(written, 6)
    }

    /// The composer's identity menu as the composer builds it: logins filed under a section head
    /// per runtime, rows assembled through `AccountUsageMenu.decorate`'s own helpers rather than
    /// a hand-copied approximation that drifts the first time the grammar changes. The data is
    /// chosen to hit every tone — calm values, a warning, a critical 99%, an expired `—`, a
    /// scoped model window, bare runtime rows — plus the two shapes the column layout exists to
    /// get right: a plan metering one window beside plans metering two (Codex under Claude), and
    /// a name long enough that it, rather than a number, is what gives way.
    private func identityMenuEntries() -> [ThemedMenuEntry] {
        let now = Date()

        func window(_ id: String, _ fraction: Double?, resetsIn: TimeInterval) -> AccountUsage.Window {
            AccountUsage.Window(
                id: id, label: id, fraction: fraction,
                resetsAt: now.addingTimeInterval(resetsIn), windowDuration: nil
            )
        }
        func scoped(_ model: String, _ fraction: Double?, resetsIn: TimeInterval) -> AccountUsage.Window {
            AccountUsage.Window(
                id: model, label: model, fraction: fraction,
                resetsAt: now.addingTimeInterval(resetsIn),
                windowDuration: UsageDefaults.sevenDaySeconds, scopeName: model
            )
        }
        func usage(
            _ windows: [AccountUsage.Window],
            scoped: [AccountUsage.Window] = [],
            plan: String? = nil
        ) -> AccountUsage {
            var usage = AccountUsage(windows: windows, planLabel: plan, observedAt: now, source: .api)
            usage.modelWindows = scoped
            return usage
        }
        func row(
            _ title: String, _ kind: AgentKind, _ usage: AccountUsage? = nil,
            selected: Bool = false
        ) -> ThemedMenuEntry {
            var item = ThemedMenuItem(
                title: title,
                image: AccountMarkImage.make(for: kind),
                isSelected: selected
            )
            if let usage {
                AccountUsageMenu.apply(usage, to: &item, at: now)
            }
            return .item(item)
        }

        return [
            .header(AgentKind.claude.displayName),
            row("Everlof", .claude, usage(
                [window("5h", 0.22, resetsIn: 16_440), window("7d", 0.15, resetsIn: 345_600)],
                scoped: [scoped("Fable", 0.4, resetsIn: -60)]
            )),
            row("Nova Hartley", .claude, usage(
                [window("5h", 0.01, resetsIn: 16_440), window("7d", 0.37, resetsIn: 356_000)],
                scoped: [scoped("Fable", 0.38, resetsIn: 356_000)]
            ), selected: true),
            row("Keller Ines", .claude, usage(
                [window("5h", nil, resetsIn: 3_600), window("7d", 0.79, resetsIn: 62_640)],
                scoped: [scoped("Fable", 0, resetsIn: 62_640)]
            )),
            .header(AgentKind.codex.displayName),
            row("Everlof", .codex, usage(
                [window("7d", 0.99, resetsIn: 442_800)],
                scoped: [scoped("GPT-5.3-Codex-Spark", 0, resetsIn: 442_800)],
                plan: "Pro"
            )),
            row("David", .codex, usage(
                [window("7d", 0.55, resetsIn: 442_800)],
                plan: "Team"
            )),
            // The runtimes with no login to name go last, behind a rule: left in runtime order
            // they sat under the Codex head with the same indent, which reads as Codex having
            // four logins, two of them called Grok and OpenCode.
            .separator,
            row("Grok", .grok),
            row("OpenCode", .openCode)
        ]
    }

    /// The sidebar's arrangement menu — two toggles and a chosen order — under every stock theme.
    ///
    /// This is the shape that showed a checked row must not also be a *filled* row. Three of its
    /// five rows carry a check, and while a check drew the theme's `selection` under it the menu
    /// opened three-quarters painted: at Win98's solid navy and the System theme's accent
    /// it read as three highlighted rows arguing with the one the pointer was on. Only a sweep
    /// says whether the check alone still carries in every palette.
    func testRendersACheckHeavyMenuUnderEveryStockTheme() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let entries: [ThemedMenuEntry] = [
            .item(ThemedMenuItem(title: "Group Sessions by Branch", isSelected: true)),
            .item(ThemedMenuItem(title: "Headings for Lone Branches", isSelected: true)),
            .separator,
            .item(ThemedMenuItem(title: "Sort by Order Added", isSelected: true)),
            .item(ThemedMenuItem(title: "Sort by Recent Activity")),
            .item(ThemedMenuItem(title: "Sort by Name"))
        ]

        var written: [String] = []
        for theme in AppThemeLibrary.stock {
            AppThemePalette.set(theme)

            let modes: [(String, NSAppearance)] = try theme.isAdaptive
                ? [
                    ("-light", try XCTUnwrap(NSAppearance(named: .aqua))),
                    ("-dark", try XCTUnwrap(NSAppearance(named: .darkAqua)))
                ]
                : [("", try XCTUnwrap(theme.mode.appearance))]

            for (suffix, appearance) in modes {
                var data: Data?
                appearance.performAsCurrentDrawingAppearance {
                    data = menuImage(
                        entries: entries,
                        appearance: appearance,
                        highlightsTheChecked: false
                    )
                }
                let url = directory.appendingPathComponent(
                    "menu-arrangement-\(theme.id.rawValue)\(suffix).png"
                )
                try XCTUnwrap(data, "Failed to render \(theme.name)\(suffix)").write(to: url)
                written.append(url.lastPathComponent)
            }
        }

        print("Rendered \(written.count) arrangement menus to \(directory.path)")
        let expected = AppThemeLibrary.stock.reduce(0) { $0 + ($1.isAdaptive ? 2 : 1) }
        XCTAssertEqual(written.count, expected)
    }

    /// The dropdown with a submenu open beside it — the panel pair is a composition no single
    /// panel's render can vouch for: the overlap, the aligned first row, the parent row's
    /// menu-path highlight, and the chevron column all only exist between the two.
    func testRendersASubmenuBesideItsParent() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let entries: [ThemedMenuEntry] = [
            .item(ThemedMenuItem(title: "Rename Session…")),
            .item(ThemedMenuItem(title: "Theme", submenu: [
                .item(ThemedMenuItem(title: "Inherit (Adaptive)", isSelected: true)),
                .separator,
                .item(ThemedMenuItem(title: "Solarized Dark")),
                .item(ThemedMenuItem(title: "Neon Meltdown"))
            ])),
            .item(ThemedMenuItem(title: "Session Options", submenu: [
                .item(ThemedMenuItem(title: "Interface"))
            ])),
            .separator,
            .item(ThemedMenuItem(title: "Delete Session"))
        ]

        var written = 0
        let variants: [(String, NSAppearance.Name, AppTheme)] = [
            ("light", .aqua, .system),
            ("dark", .darkAqua, .system),
            ("win98", .aqua, AppThemeStyles.win98)
        ]
        for (mode, appearanceName, theme) in variants {
            AppThemePalette.set(theme)
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            var data: Data?
            appearance.performAsCurrentDrawingAppearance {
                data = submenuImage(entries: entries, appearance: appearance)
            }
            let url = directory.appendingPathComponent("menu-submenu-\(mode).png")
            try XCTUnwrap(data, "Failed to render submenu \(mode)").write(to: url)
            written += 1
        }
        print("Rendered \(written) submenu pairs to \(directory.path)")
        XCTAssertEqual(written, 3)
    }

    /// The composer's clock, hovered, beside the primary it offers the other half of.
    ///
    /// The pair is rendered rather than merely measured because the defect it pins was visible
    /// only in a picture: at `.inline`'s nested 20 points the clock hovered a plate six points
    /// shorter than Start Session — a smudge under the System theme's soft corners, a hard
    /// square that had plainly missed its size under Bauhaus, which is where it was reported.
    /// `.besidePrimary` stands the button at the primary's own base height, and the equality is
    /// asserted beside the render so the picture review has a tripwire under it.
    func testRendersTheClockHoveredBesideThePrimaryLevelWithIt() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for (name, theme) in [("system", AppTheme.system), ("bauhaus", AppThemeStyles.bauhaus)] {
            AppThemePalette.set(theme)
            let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 90))
            root.appearance = appearance

            let start = ThemedButton(title: "Start Session", target: nil, action: nil)
            start.emphasis = .primary
            let clock = ThemedIconButton(
                symbolName: "clock",
                accessibility: "Start this session later",
                target: .besidePrimary
            )
            clock.presentsMenu = true
            for view in [start, clock] {
                view.translatesAutoresizingMaskIntoConstraints = false
                root.addSubview(view)
            }
            NSLayoutConstraint.activate([
                start.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
                start.centerYAnchor.constraint(equalTo: root.centerYAnchor),
                clock.trailingAnchor.constraint(
                    equalTo: start.leadingAnchor, constant: -Design.Spacing.small
                ),
                clock.centerYAnchor.constraint(equalTo: root.centerYAnchor)
            ])

            let window = NSWindow(
                contentRect: root.bounds,
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = appearance
            window.contentView = root
            defer { window.close() }

            markNeedingLayout(root)
            root.layoutSubtreeIfNeeded()
            // The hover is forced through the same entry the tracking area uses; the event's
            // contents are never read, so any event stands in for the pointer's arrival.
            if let event = key(125) { clock.mouseEntered(with: event) }

            XCTAssertEqual(
                clock.frame.height,
                start.frame.height,
                accuracy: 0.5,
                "the clock's hover plate stands short of the primary under \(name)"
            )

            root.wantsLayer = true
            root.layer?.backgroundColor = AppThemePalette.current.resolved(.ground).cgColor

            let scale = 3
            let rep = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(root.bounds.width) * scale,
                pixelsHigh: Int(root.bounds.height) * scale,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ))
            rep.size = root.bounds.size
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
            appearance.performAsCurrentDrawingAppearance {
                root.displayIgnoringOpacity(root.bounds, in: context)
            }
            let url = directory.appendingPathComponent("composer-clock-hover-\(name).png")
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        }
    }

    private func submenuImage(entries: [ThemedMenuEntry], appearance: NSAppearance) -> Data? {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 320))
        root.appearance = appearance
        let source = NSView(frame: NSRect(x: 24, y: 270, width: 180, height: 26))
        root.addSubview(source)

        let window = NSWindow(
            contentRect: root.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = root
        defer { window.close() }

        let token = ThemedMenuPresenter.present(
            ThemedMenuPresentation(entries: entries, minimumWidth: source.bounds.width),
            from: source,
            selectedEntryIndex: nil,
            onChoose: { _, _ in },
            onDismiss: {}
        )
        defer { ThemedMenuPresenter.dismiss(token) }

        markNeedingLayout(root)
        root.layoutSubtreeIfNeeded()

        // Down to "Theme", right-arrow opens its panel with the first row lit.
        if let overlay = window.firstResponder as? NSView,
           let down = key(125),
           let right = key(124) {
            overlay.keyDown(with: down)
            overlay.keyDown(with: right)
        }

        markNeedingLayout(root)
        root.layoutSubtreeIfNeeded()

        guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return nil }
        root.wantsLayer = true
        root.layer?.backgroundColor = AppThemePalette.current.resolved(.ground).cgColor
        root.cacheDisplay(in: root.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    private func key(_ keyCode: UInt16) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        )
    }

    /// `highlightsTheChecked` reproduces how a menu actually opens: a pop-up lands its highlight
    /// on the value it is showing, while a menu of toggles has no single value and opens with the
    /// highlight on its first row instead. Which of the two is being drawn decides what a checked
    /// row has to carry on its own.
    private func menuImage(
        entries: [ThemedMenuEntry],
        appearance: NSAppearance,
        highlightsTheChecked: Bool = true,
        canvas: NSSize = NSSize(width: 420, height: 300)
    ) -> Data? {
        let root = NSView(frame: NSRect(origin: .zero, size: canvas))
        root.appearance = appearance
        let source = NSView(frame: NSRect(x: 24, y: canvas.height - 50, width: 160, height: 26))
        root.addSubview(source)

        let window = NSWindow(
            contentRect: root.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = root
        defer { window.close() }

        let selected = highlightsTheChecked
            ? entries.firstIndex {
                guard case .item(let item) = $0 else { return false }
                return item.isSelected
            }
            : nil
        let token = ThemedMenuPresenter.present(
            ThemedMenuPresentation(entries: entries, minimumWidth: source.bounds.width),
            from: source,
            selectedEntryIndex: selected,
            onChoose: { _, _ in },
            onDismiss: {}
        )
        defer { ThemedMenuPresenter.dismiss(token) }

        // The overlay is laid out by frames during the window's display cycle, which an
        // offscreen render never enters — so the pass is forced.
        markNeedingLayout(root)
        root.layoutSubtreeIfNeeded()

        guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return nil }
        root.wantsLayer = true
        root.layer?.backgroundColor = AppThemePalette.current.resolved(.ground).cgColor
        root.cacheDisplay(in: root.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    private func markNeedingLayout(_ view: NSView) {
        view.needsLayout = true
        for subview in view.subviews { markNeedingLayout(subview) }
    }

    // MARK: - Building

    private func rows() -> [ConversationTimeline.Row] {
        let (events, _) = TranscriptReplay.read(at: Render.fixture, kind: .claude)
        var timeline = ConversationTimeline(sessionID: SessionID())
        for event in events { _ = timeline.apply(event) }
        return Array(timeline.rows.prefix(Render.rowLimit))
    }

    private func image(for theme: AppTheme, appearance: NSAppearance) -> Data? {
        // A themed app pins its appearance, or the system draws its own scrollers and selection
        // over it. System is deliberately rendered once in each macOS appearance.
        var data: Data?
        appearance.performAsCurrentDrawingAppearance {
            let host = laidOut(rows())
            host.appearance = appearance
            AppThemeRefresh.repaint(host)
            host.layoutSubtreeIfNeeded()
            data = png(of: host, ground: theme.resolved(.ground, appearance: appearance))
        }
        return data
    }

    private func laidOut(_ rows: [ConversationTimeline.Row]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.medium
        stack.translatesAutoresizingMaskIntoConstraints = false

        var previous: NSView?
        for row in rows {
            let (view, startsTurn) = ConversationRowView.make(for: row)
            stack.addArrangedSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: Design.Spacing.inset),
                view.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -Design.Spacing.inset)
            ])
            if startsTurn, let previous {
                stack.setCustomSpacing(Design.Chat.turnSpacing, after: previous)
            }
            previous = view
        }

        let host = NSView(frame: NSRect(x: 0, y: 0, width: Render.width, height: 1))
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: host.topAnchor, constant: Design.Spacing.inset),
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            stack.widthAnchor.constraint(equalToConstant: Render.width)
        ])

        host.layoutSubtreeIfNeeded()
        host.frame.size.height = stack.fittingSize.height + Design.Spacing.pane
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func png(of host: NSView, ground: NSColor) -> Data? {
        guard host.bounds.height > 1,
              let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }

        // The pane paints no ground of its own — it sits on the window — so the theme's own
        // ground is painted here, which is also what the app does.
        host.wantsLayer = true
        host.layer?.backgroundColor = ground.cgColor

        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
