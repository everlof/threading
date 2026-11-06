import AppKit
import ThreadingController
import XCTest
@testable import Threading

/// Settings ▸ Workrooms, drawn light and dark at the pane's two widths, plus the rows its search
/// entries promise. The page is the only owner surface for people outside this Mac, so what it
/// must never lose is the switch, the public address and the way to close everything.
final class WorkroomsSettingsRenderTests: HostedStoreTestCase {

    private static let widths: [CGFloat] = [420, SettingsUIDefaults.pageWidth]
    private static let height: CGFloat = 1400

    private static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ThreadingRenders", isDirectory: true)
    }

    @MainActor
    func testThePageCarriesTheSwitchTheAddressAndCloseAll() {
        let controller = WorkroomsPreferencesViewController()
        let host = laidOut(controller.view, width: SettingsUIDefaults.pageWidth)
        let labels = Self.labels(in: host)
        for title in ["Ask people outside this Mac", "Tunnel", "Reserved domain", "Add a person"] {
            XCTAssertTrue(labels.contains(L10n.string(title)), title)
        }
        XCTAssertTrue(Self.buttons(in: host).contains(L10n.string("Close All Workrooms")))
    }

    @MainActor
    func testTabMovesThroughThePersonFormAndBackToThePageAction() throws {
        let controller = WorkroomsPreferencesViewController()
        let host = laidOut(controller.view, width: SettingsUIDefaults.pageWidth)
        let window = NSWindow(contentRect: host.bounds, styleMask: [.borderless], backing: .buffered,
                              defer: false)
        window.contentView = host
        window.layoutIfNeeded()
        let fields = Self.fields(in: host)
        let name = try XCTUnwrap(fields.first { Self.placeholder(in: $0) == L10n.string("Name") })
        let handle = try XCTUnwrap(fields.first { Self.placeholder(in: $0) == L10n.string("handle") })
        let language = try XCTUnwrap(fields.first { Self.placeholder(in: $0) == "sv" })
        let add = try XCTUnwrap(Self.button(in: host, titled: "Add"))
        let closeAll = try XCTUnwrap(Self.button(in: host, titled: "Close All Workrooms"))

        XCTAssertTrue(name.nextKeyView === handle)
        XCTAssertTrue(handle.nextKeyView === language)
        XCTAssertTrue(language.nextKeyView === add)
        XCTAssertTrue(add.nextKeyView === closeAll)
    }

    @MainActor
    func testSettingRefreshKeepsTheSwitchMounted() throws {
        let controller = WorkroomsPreferencesViewController()
        let host = laidOut(controller.view, width: SettingsUIDefaults.pageWidth)
        let toggle = try XCTUnwrap(Self.toggle(in: host))
        let row = try XCTUnwrap(toggle.superview)

        NotificationCenter.default.post(AppSettingsDidChange(
            changedSetting: AppSettingIdentity.workroomsEnabled.rawValue
        ))

        XCTAssertTrue(toggle.superview === row, "a setting change detached the animated switch")
        XCTAssertTrue(toggle.isDescendant(of: controller.view))
    }

    @MainActor
    func testRendersWorkroomsSettingsToImages() async throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        var written = 0
        for width in Self.widths {
            for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let appearance = NSAppearance(named: appearanceName)
                var data: Data?
                appearance?.performAsCurrentDrawingAppearance {
                    let controller = WorkroomsPreferencesViewController()
                    let host = self.laidOut(controller.view, width: width)
                    host.appearance = appearance
                    AppThemeRefresh.repaint(host)
                    host.layoutSubtreeIfNeeded()
                    data = Self.png(of: host)
                }
                let url = Self.directory.appendingPathComponent("workrooms-\(Int(width))-\(name).png")
                try XCTUnwrap(data, "the Workrooms page rendered nothing at \(width)pt \(name)").write(to: url)
                written += 1
            }
        }
        XCTAssertEqual(written, Self.widths.count * 2)
        try await renderLinkExtensionInProductShell()
    }

    @MainActor
    private func renderLinkExtensionInProductShell() async throws {
        let store = try await MacMailbox.shared.controllerStore()
        let person = try await store.addWorkroomPerson(id: WorkroomPersonID(), handle: "link-review",
                                                       name: "Viktor", language: "sv")
        let issuedAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-01T12:00:00Z"))
        _ = try await store.issueWorkroomInvitation(person: person.id, now: issuedAt)
        let previousTheme = AppThemePalette.current
        let previousMotion = Design.Motion.reduceMotionOverrideForTesting
        defer {
            AppThemePalette.set(previousTheme)
            Design.Motion.reduceMotionOverrideForTesting = previousMotion
        }
        Design.Motion.reduceMotionOverrideForTesting = true
        let shell = makeMainWindowController()
        let window = try XCTUnwrap(shell.window)
        window.setContentSize(NSSize(width: 1400, height: 1000))
        shell.showSettingsPage(id: SettingsPages.workroomsID)
        let content = try XCTUnwrap(window.contentView)
        for _ in 0..<200 {
            if Self.button(in: content, titled: "Extend Link…") != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let extend = try XCTUnwrap(Self.button(in: content, titled: "Extend Link…"))
        XCTAssertTrue(extend.isEnabled, "an expired unused invitation can be extended")
        let variants: [(String, AppTheme, NSAppearance.Name)] = [
            ("system-light", .system, .aqua), ("system-dark", .system, .darkAqua),
            ("cyberpunk", AppThemeStyles.cyberpunk, .darkAqua), ("win98", AppThemeStyles.win98, .aqua)
        ]
        do {
            for (name, theme, appearance) in variants {
                AppThemePalette.set(theme)
                content.appearance = NSAppearance(named: appearance)
                AppThemeRefresh.repaint(content)
                content.layoutSubtreeIfNeeded()
                SettingsRowReveal.reveal(title: person.name, in: content)
                content.layoutSubtreeIfNeeded()
                try XCTUnwrap(Self.png(of: content)).write(to: Self.directory.appendingPathComponent("workrooms-shell-\(name).png"))
                XCTAssertTrue(extend.performPrimaryAction())
                for _ in 0..<200 {
                    if window.childWindows?.isEmpty == false { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                let panel = try XCTUnwrap(window.childWindows?.first)
                let dialog = try XCTUnwrap(panel.contentView)
                dialog.layoutSubtreeIfNeeded()
                try XCTUnwrap(Self.png(of: dialog)).write(to: Self.directory.appendingPathComponent("workrooms-extend-\(name).png"))
                panel.cancelOperation(nil)
            }
            _ = try await store.removeWorkroomPerson(id: person.id)
        } catch {
            _ = try? await store.removeWorkroomPerson(id: person.id)
            throw error
        }
    }

    // MARK: - Helpers

    @MainActor
    private func laidOut(_ view: NSView, width: CGFloat) -> NSView {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: Self.height))
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            host.widthAnchor.constraint(equalToConstant: width),
            host.heightAnchor.constraint(equalToConstant: Self.height),
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.bounds.width, width, accuracy: 0.5, "the page widened its pane")
        return host
    }

    @MainActor
    private static func labels(in view: NSView) -> Set<String> {
        var found: Set<String> = []
        if let field = view as? NSTextField { found.insert(field.stringValue) }
        for subview in view.subviews { found.formUnion(labels(in: subview)) }
        return found
    }

    @MainActor
    private static func buttons(in view: NSView) -> Set<String> {
        var found: Set<String> = []
        if let button = view as? ThemedButton { found.insert(button.title) }
        for subview in view.subviews { found.formUnion(buttons(in: subview)) }
        return found
    }

    @MainActor
    private static func fields(in view: NSView) -> [ThemedTextField] {
        let current = (view as? ThemedTextField).map { [$0] } ?? []
        return current + view.subviews.flatMap(fields(in:))
    }

    @MainActor
    private static func placeholder(in field: ThemedTextField) -> String? {
        field.placeholderAttributedString?.string ?? field.placeholderString
    }

    @MainActor
    private static func button(in view: NSView, titled title: String) -> ThemedButton? {
        if let button = view as? ThemedButton, button.title == L10n.string(title) { return button }
        for subview in view.subviews {
            if let found = button(in: subview, titled: title) { return found }
        }
        return nil
    }

    @MainActor
    private static func toggle(in view: NSView) -> ThemedToggle? {
        if let toggle = view as? ThemedToggle { return toggle }
        for subview in view.subviews {
            if let found = toggle(in: subview) { return found }
        }
        return nil
    }

    @MainActor
    private static func png(of host: NSView) -> Data? {
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
