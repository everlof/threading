import AppKit
import XCTest
@testable import Threading

/// Measures the pixels inside the real outline in the shipping window. Reading the tint property
/// missed NSImageCell's emphasized white treatment, even when the property was correctly black.
@MainActor
final class SidebarIconContrastTests: HostedStoreTestCase {
    func testDormantTemplateReplacementDoesNotInheritArtworkDimming() throws {
        let previous = AppThemePalette.current
        defer { AppThemeLibrary.apply(previous) }
        AppThemeLibrary.apply(try theme(accent: "#00FF41", marks: .natural))
        let registry = ComponentCustomizationRegistry()
        let contract = HostComponentContracts.sidebarSessionRow
        try registry.register(contract)
        let session = AgentSession(kind: .claude, title: "THEMES")
        let row = SessionRowView(customizationLookup: registry.customization(for:))
        row.configure(with: session, activity: .dormant)
        let mark = try XCTUnwrap(descendants(row).first {
            $0.accessibilityIdentifier() == "sidebar.session.identity"
        } as? GlyphView)
        XCTAssertEqual(mark.image?.isTemplate, false)
        XCTAssertLessThan(mark.alphaValue, 1)
        let source = ComponentCustomizationSource(
            extensionIdentifier: "com.example.contrast", processGeneration: "one", order: 0
        )
        try registry.replacePatches([
            .init(id: "template", target: .init(
                component: contract.id, contractVersion: contract.version,
                entityID: session.id.uuidString.lowercased()
            ), properties: [.init(property: .identityImage, value: .image(.systemSymbol("hammer.fill")))])
        ], from: source)
        XCTAssertEqual(mark.image?.isTemplate, true)
        XCTAssertEqual(mark.alphaValue, 1)
        row.configure(with: session, activity: .dormant)
        XCTAssertEqual(mark.alphaValue, 1)
        registry.removePatches(extensionIdentifier: source.extensionIdentifier,
                               processGeneration: source.processGeneration)
        XCTAssertEqual(mark.image?.isTemplate, false)
        XCTAssertLessThan(mark.alphaValue, 1)
    }

    func testSelectedMarkPixelsReadOnCustomGroundsInShippingSidebar() throws {
        let previous = AppThemePalette.current
        defer { AppThemeLibrary.apply(previous) }
        AppThemeLibrary.apply(try theme(accent: "#00FF41", marks: .natural))

        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidebar-icon-contrast-\(UUID().uuidString)")
        let directory = temporaryRoot.appendingPathComponent("Contrast")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: directory))
        let session = try XCTUnwrap(ProjectStore.shared.addSession(
            to: project.id, kind: .codex, title: "THEMES"
        ))
        let terminal = try XCTUnwrap(ProjectStore.shared.addTerminal(to: project.id, customTitle: "Terminal"))
        let controller = makeMainWindowController(initialFramePlan: .useDefaultFrame)
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1120, height: 720))
        let content = try XCTUnwrap(window.contentView)
        let item = try XCTUnwrap(controller.splitViewController.splitViewItems.first)
        controller.splitViewController.setCollapsed(false, on: item, animated: false)
        controller.splitViewController.splitView.setPosition(320, ofDividerAt: 0)
        let sidebar = controller.sidebarViewController
        sidebar.mountInitialTreeIfNeeded()
        let outline = try XCTUnwrap(descendants(sidebar.view).compactMap { $0 as? ThemedOutlineView }.first)
        outline.fixtureIsKey = true
        sidebar.select(sessionID: session.id, notifyDelegate: false)
        _ = try capture(content)
        let cell = try XCTUnwrap(descendants(content).compactMap { $0 as? SessionRowView }.first)
        let row = try XCTUnwrap(cell.superview as? SidebarHoverRowView)
        XCTAssertTrue(row.isSelected, "The actual outline must own this selection")
        row.isEmphasized = true
        XCTAssertTrue(row.isEmphasized)
        cell.backgroundStyle = .emphasized

        // Keep the same mounted cell through theme and activity changes. Both the template
        // provider and the colored provider converted into a template must read, even dormant.
        for (name, accent, marks) in [
            ("green", "#00FF41", AppTheme.Material.IdentityMarks.natural),
            ("navy", "#000080", .natural),
            ("green-tinted", "#00FF41", .tinted),
        ] {
            AppThemeLibrary.apply(try theme(accent: accent, marks: marks))
            AppThemeRefresh.repaint(content)
            for provider in [AgentKind.codex, .claude, .grok] {
                var sample = AgentSession(kind: provider, title: "THEMES")
                sample.isPinned = true
                for activity in [SessionActivity.idle, .working, .dormant] {
                    cell.configure(with: sample, activity: activity)
                    let bitmap = try capture(content)
                    let ground = SidebarHoverRowView.contentGround(for: cell)
                    for identifier in ["sidebar.session.identity", "sidebar.session.pinned"] {
                        let mark = try XCTUnwrap(descendants(cell).first {
                            $0.accessibilityIdentifier() == identifier
                        } as? GlyphView)
                        XCTAssertEqual(mark.accessibilityRole(), .image)
                        XCTAssertTrue(mark.isAccessibilityElement())
                        XCTAssertEqual(mark.alphaValue, 1, "A template must not be dimmed after its ink is measured")
                        try assertContrast(of: mark, in: content, bitmap: bitmap, ground: ground,
                                           context: "\(name) / \(provider) / \(activity) / \(identifier)")
                    }
                    if provider == .codex, activity == .idle {
                        try write(bitmap, named: "sidebar-row-contrast-\(name).png")
                    }
                }
            }
        }

        sidebar.select(terminalID: terminal.id, notifyDelegate: false)
        _ = try capture(content)
        let terminalCell = try XCTUnwrap(descendants(content).compactMap { $0 as? ProjectTerminalRowView }.first)
        let terminalRow = try XCTUnwrap(terminalCell.superview as? SidebarHoverRowView)
        XCTAssertTrue(terminalRow.isSelected)
        terminalRow.isEmphasized = true
        terminalCell.backgroundStyle = .emphasized
        for running in [true, false] {
            terminalCell.configure(with: terminal, running: running, busy: false, projectRoot: directory.path)
            let bitmap = try capture(content)
            let mark = try XCTUnwrap(descendants(terminalCell).first {
                $0.accessibilityIdentifier() == "sidebar.terminal.identity"
            } as? GlyphView)
            try assertContrast(of: mark, in: content, bitmap: bitmap,
                               ground: SidebarHoverRowView.contentGround(for: terminalCell), context: "terminal")
            if running { try write(bitmap, named: "sidebar-row-contrast-terminal.png") }
        }
    }

    private func theme(accent: String, marks: AppTheme.Material.IdentityMarks) throws -> AppTheme {
        let base = try XCTUnwrap(AppThemeStyles.threading.variant(.dark))
        var roles = base.roles
        roles[.accent] = try XCTUnwrap(NSColor(hex: accent))
        var material = base.material
        material.identityMarks = marks
        return AppTheme(
            id: AppThemeID("custom-icon-contrast-\(accent)-\(marks)"), name: "Contrast", mode: .dark,
            summary: nil, variants: [.dark: base.replacing(roles: roles, material: material)]
        )
    }

    private func assertContrast(
        of mark: GlyphView, in content: NSView, bitmap: NSBitmapImageRep,
        ground: NSColor, context: String
    ) throws {
        let rect = mark.convert(mark.bounds, to: content)
        let scale = CGFloat(bitmap.pixelsWide) / content.bounds.width
        let edgeY = Int(rect.minY * scale)
        let edge = color(
            in: bitmap,
            x: Int(rect.minX * scale),
            y: content.isFlipped ? edgeY : bitmap.pixelsHigh - 1 - edgeY
        )
        let expected = try XCTUnwrap(ground.usingColorSpace(.sRGB))
        XCTAssertEqual(edge.redComponent, expected.redComponent, accuracy: 0.01, context)
        XCTAssertEqual(edge.greenComponent, expected.greenComponent, accuracy: 0.01, context)
        XCTAssertEqual(edge.blueComponent, expected.blueComponent, accuracy: 0.01, context)
        var readingPixels = 0
        var bestRatio: CGFloat = 1
        for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
            for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
                let bitmapY = content.isFlipped ? y : bitmap.pixelsHigh - 1 - y
                let pixel = color(in: bitmap, x: x, y: bitmapY)
                let ratio = ThemeContrast.ratio(pixel, edge)
                bestRatio = max(bestRatio, ratio)
                if ratio >= 3 { readingPixels += 1 }
            }
        }
        XCTAssertGreaterThan(readingPixels, 4, "\(context): strongest rendered contrast \(bestRatio):1")
    }

    /// AppKit's colorAt labels sRGB channels as calibrated RGB. Preserve the capture's space.
    private func color(in bitmap: NSBitmapImageRep, x: Int, y: Int) -> NSColor {
        var pixel = [Int](repeating: 0, count: bitmap.samplesPerPixel)
        bitmap.getPixel(&pixel, atX: x, y: y)
        return NSColor(srgbRed: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
                       blue: CGFloat(pixel[2]) / 255, alpha: CGFloat(pixel[3]) / 255)
    }

    private func capture(_ view: NSView) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)?.retagging(with: .sRGB))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    private func write(_ bitmap: NSBitmapImageRep, named filename: String) throws {
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"]
            ?? NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: output.appendingPathComponent(filename))
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
