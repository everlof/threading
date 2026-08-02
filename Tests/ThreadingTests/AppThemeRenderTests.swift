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

        var written: [String] = []

        for theme in AppThemeLibrary.stock {
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
        let expected = AppThemeLibrary.stock.reduce(0) {
            $0 + ($1.isAdaptive ? 2 : 1)
        }
        XCTAssertEqual(written.count, expected)
    }

    /// The dropdown at both of its densities — a plain choice list (check column only, with a
    /// separator and an action) and rows carrying images and subtitles — over light and dark.
    /// The menu is an overlay drawn entirely by the app, so nothing but a render can say
    /// whether its spacing reads as a menu or as a smear.
    func testRendersTheDropdownMenu() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let plain: [ThemedMenuEntry] = [
            .item(ThemedMenuItem(title: "SONDA-386-387-source-governance — this checkout", isSelected: true)),
            .item(ThemedMenuItem(title: "Codex")),
            .separator,
            .item(ThemedMenuItem(title: "New Worktree…"))
        ]
        let icon = NSImage(
            systemSymbolName: "person.crop.circle",
            accessibilityDescription: nil
        )
        let detailed: [ThemedMenuEntry] = [
            .item(ThemedMenuItem(
                title: "Everlof", subtitle: "5h 30% · 7d 10%", image: icon, isSelected: true
            )),
            .item(ThemedMenuItem(title: "Daniel Block", subtitle: "5h — · 7d 25%", image: icon)),
            .item(ThemedMenuItem(title: "Lundborg Viktor", subtitle: "5h 21% · 7d 31%", image: icon))
        ]

        var written = 0
        for (name, entries) in [("plain", plain), ("detailed", detailed)] {
            for (mode, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
                var data: Data?
                appearance.performAsCurrentDrawingAppearance {
                    data = menuImage(entries: entries, appearance: appearance)
                }
                let url = directory.appendingPathComponent("menu-\(name)-\(mode).png")
                try XCTUnwrap(data, "Failed to render \(name) \(mode)").write(to: url)
                written += 1
            }
        }
        print("Rendered \(written) menus to \(directory.path)")
        XCTAssertEqual(written, 4)
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
        for (mode, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
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
        XCTAssertEqual(written, 2)
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

    private func menuImage(entries: [ThemedMenuEntry], appearance: NSAppearance) -> Data? {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 300))
        root.appearance = appearance
        let source = NSView(frame: NSRect(x: 24, y: 250, width: 160, height: 26))
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

        let selected = entries.firstIndex {
            guard case .item(let item) = $0 else { return false }
            return item.isSelected
        }
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
