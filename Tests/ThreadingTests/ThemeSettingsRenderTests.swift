import AppKit
import XCTest
@testable import Threading

/// Draws the Themes settings page and writes it out as an image, light and dark.
///
/// The same reason the conversation and git-review renders exist: a claim about whether twenty
/// colour chips read as a grid or as a smear cannot be checked by asserting on constants. The
/// page's previous layout passed every assertion anyone would have written for it and still put
/// sixteen swatches four points apart in two rows that did not line up.
///
/// The assertions catch what an image cannot: a card that measures nothing, a palette that
/// overflows the pane it is drawn in.
final class ThemeSettingsRenderTests: XCTestCase {

    private enum Render {
        /// The shared width the pane gives every settings page, plus a squeezed pane since the
        /// eight-column ANSI grid is the widest fixed thing here and is what breaks first.
        static let widths: [CGFloat] = [420, SettingsUIDefaults.pageWidth]
        static let height: CGFloat = 1000

        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }
    }

    // MARK: - Layout

    @MainActor
    func testPaletteFitsTheNarrowSettingsPane() {
        let editor = ThemeColorEditor()
        editor.show(.ocean, isEditable: true)

        let host = laidOut(editor, width: Render.widths[0])

        XCTAssertGreaterThan(editor.frame.height, 100, "the palette card collapsed")
        XCTAssertLessThanOrEqual(
            editor.frame.width, host.bounds.width,
            "the ANSI grid is wider than the pane it sits in"
        )
    }

    @MainActor
    func testPreviewDrawsEveryLineOfItsSample() {
        let preview = ThemePreviewView()
        preview.show(.pro)

        _ = laidOut(preview, width: Render.widths[1])

        XCTAssertGreaterThan(preview.frame.height, 100, "the preview collapsed")
    }

    /// The sample stages every role the editor can change, and bold text is the one that was
    /// missing: before this run the card drew nothing at all in `boldForeground`, so the well
    /// beside it moved a colour the preview never showed. It is drawn where a terminal draws
    /// it — the typed command — in the bold face, because the role is a weight and a colour.
    @MainActor
    func testPreviewDrawsTheTypedCommandInThePalettesBoldText() {
        XCTAssertNotEqual(
            TerminalTheme.pro.boldForeground.hexString,
            TerminalTheme.pro.foreground.hexString,
            "the fixture palette has to state a bold colour of its own to prove anything"
        )

        let preview = ThemePreviewView()
        preview.show(.pro)

        let sample = preview.renderedSample
        var boldRuns = 0
        sample.enumerateAttributes(
            in: NSRange(location: 0, length: sample.length)
        ) { attributes, range, _ in
            guard (sample.string as NSString).substring(with: range).contains("git status")
            else { return }
            boldRuns += 1

            XCTAssertEqual(
                (attributes[.foregroundColor] as? NSColor)?.hexString,
                TerminalTheme.pro.boldForeground.hexString
            )
            guard let face = attributes[.font] as? NSFont else {
                return XCTFail("the run carries no font")
            }
            XCTAssertTrue(
                NSFontManager.shared.traits(of: face).contains(.boldFontMask),
                "the bold text role is drawn in the regular face"
            )
        }

        XCTAssertEqual(boldRuns, 1, "the sample draws no run in the palette's bold text")
    }

    @MainActor
    func testPageBuildsWithoutCollapsing() {
        let controller = ThemePreferencesViewController()
        let host = laidOut(controller.view, width: Render.widths[1], height: Render.height)

        XCTAssertEqual(controller.view.frame.width, host.bounds.width)
        XCTAssertGreaterThan(controller.view.frame.height, 200)
    }

    @MainActor
    func testHistoricalFontFallbackNoticeExplainsTheActualResolution() {
        let fallback = ThemePreferencesViewController.historicalFontFallbackMessage(
            themeName: "Mac OS 9 Platinum",
            fontFamilies: ["Charcoal", "Geneva"],
            availableFamilies: ["Geneva"],
            overrideFamily: nil
        )
        XCTAssertEqual(
            fallback,
            "“Mac OS 9 Platinum” requests Charcoal, which is not installed. Using Geneva. "
                + "Install a legitimately licensed copy of Charcoal to use it automatically."
        )
        XCTAssertNil(
            ThemePreferencesViewController.historicalFontFallbackMessage(
                themeName: "Mac OS 9 Platinum",
                fontFamilies: ["Charcoal", "Geneva"],
                availableFamilies: ["Charcoal", "Geneva"],
                overrideFamily: nil
            ),
            "no warning is needed when the requested historical face is installed"
        )
        XCTAssertNil(
            ThemePreferencesViewController.historicalFontFallbackMessage(
                themeName: "Mac OS 9 Platinum",
                fontFamilies: ["Charcoal", "Geneva"],
                availableFamilies: ["Geneva"],
                overrideFamily: "Avenir Next"
            ),
            "an explicit app-font override is the user's choice, not an implicit fallback"
        )

        XCTAssertEqual(
            ThemePreferencesViewController.historicalFontFallbackMessage(
                themeName: "Windows 98",
                fontFamilies: ["MS Sans Serif", "Microsoft Sans Serif", "W95FA", "Geneva"],
                availableFamilies: ["W95FA", "Geneva"],
                overrideFamily: nil
            ),
            "“Windows 98” requests MS Sans Serif, which is not installed. Using W95FA. "
                + "Install a legitimately licensed copy of MS Sans Serif to use it automatically."
        )
    }

    // MARK: - The Halo Contract

    /// A glowing theme's halo must fade on all four sides of a card, and only a render can
    /// say so: the shadow is always set correctly on the card's own layer — it is an
    /// *ancestor* that eats it. The page's scroll view clips at its own bounds, and before
    /// the column kept `Design.Size.glowGutter` clear of them the halo was cut off flat at
    /// the cards' left and right edges while the vertical spill survived in the section
    /// spacing — a fade in one axis only, which no assertion about layer properties could
    /// see.
    @MainActor
    func testCardHaloSurvivesTheScrollViewOnAllFourSides() throws {
        AppThemePalette.set(AppThemeStyles.cyberpunk)
        defer { AppThemePalette.set(.system) }

        let card = SettingsCard(rows: [SettingsUI.row(title: "Row")])
        let page = SettingsUI.page([SettingsUI.section(nil, card)])
        let host = laidOut(page, width: SettingsUIDefaults.pageWidth, height: 300)

        host.wantsLayer = true
        host.layer?.backgroundColor = AppThemePalette.current.resolved(.ground).cgColor
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)

        let frame = card.convert(card.bounds, to: host)
        let reach: CGFloat = 3
        let samples: [(side: String, point: NSPoint)] = [
            ("left", NSPoint(x: frame.minX - reach, y: frame.midY)),
            ("right", NSPoint(x: frame.maxX + reach, y: frame.midY)),
            ("top", NSPoint(x: frame.midX, y: frame.maxY + reach)),
            ("bottom", NSPoint(x: frame.midX, y: frame.minY - reach))
        ]

        for sample in samples {
            let excess = accentExcess(at: sample.point, in: rep, host: host)
            XCTAssertGreaterThan(
                excess, 0.01,
                "no halo \(sample.side) of the card — its glow is being clipped on that side"
            )
        }
    }

    /// How much of the theme's green accent a pixel carries beyond its own red and blue —
    /// zero on the ground and on anything neutral, positive inside the accent's halo. The
    /// card's border is blue-violet, so bleed from the edge can only *lower* it.
    @MainActor
    private func accentExcess(at point: NSPoint, in rep: NSBitmapImageRep, host: NSView) -> CGFloat {
        let scale = CGFloat(rep.pixelsWide) / host.bounds.width
        let x = Int(point.x * scale)
        // The rep's rows run top-down while the host's coordinates run bottom-up.
        let y = Int((host.bounds.height - point.y) * scale)

        guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return 0 }
        return colour.greenComponent - max(colour.redComponent, colour.blueComponent)
    }

    // MARK: - Images

    @MainActor
    func testRendersThemeSettingsToImages() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var written: [String] = []

        for width in Render.widths {
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let url = directory.appendingPathComponent("themes-\(Int(width))-\(name).png")
                let data = try XCTUnwrap(
                    pageImage(width: width, appearance: appearance),
                    "Failed to render the themes page at \(width)pt in \(name)"
                )
                try data.write(to: url)
                written.append(url.lastPathComponent)
            }
        }

        print("Rendered \(written.count) theme pages to \(directory.path)")
        XCTAssertEqual(written.count, Render.widths.count * 2)
    }

    /// The page that first exposed the Clay button problem: secondary actions had no readable
    /// white body, so their violet depth looked like a detached blur. Keep a deterministic
    /// theme-specific fixture instead of relying on whichever preference the test host restored.
    @MainActor
    func testRendersClayThemeSettingsToImage() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let previous = AppThemeLibrary.current
        defer { AppThemeLibrary.apply(previous) }
        AppThemeLibrary.apply(AppThemeStyles.claymorphism)

        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let controller = ThemePreferencesViewController()
        let host = laidOut(
            controller.view,
            width: SettingsUIDefaults.pageWidth,
            height: Render.height
        )
        host.appearance = appearance
        controller.view.appearance = appearance

        var data: Data?
        appearance.performAsCurrentDrawingAppearance {
            host.applySurface(fill: Design.Surface.ground, radius: .fixed(0))
            AppThemeRefresh.repaint(host)
            host.layoutSubtreeIfNeeded()
            data = png(of: host)
        }

        let url = directory.appendingPathComponent("themes-claymorphism.png")
        try XCTUnwrap(data, "Failed to render the Claymorphism themes page").write(to: url)
    }

    /// The fixture for the centred-glow failure: a Core Animation companion shadow used to
    /// composite above every dark card and turn the whole Themes page lime. Keep the complete
    /// page beside the pixel-level surface assertion so hierarchy changes cannot hide a repeat.
    @MainActor
    func testRendersCyberpunkThemeSettingsToImage() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let previous = AppThemeLibrary.current
        defer { AppThemeLibrary.apply(previous) }
        AppThemeLibrary.apply(AppThemeStyles.cyberpunk)

        let appearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let controller = ThemePreferencesViewController()
        let host = laidOut(
            controller.view,
            width: SettingsUIDefaults.pageWidth,
            height: Render.height
        )
        host.appearance = appearance
        controller.view.appearance = appearance

        var data: Data?
        appearance.performAsCurrentDrawingAppearance {
            host.applySurface(fill: Design.Surface.ground, radius: .fixed(0))
            AppThemeRefresh.repaint(host)
            host.layoutSubtreeIfNeeded()
            data = png(of: host)
        }

        let url = directory.appendingPathComponent("themes-cyberpunk.png")
        try XCTUnwrap(data, "Failed to render the Cyberpunk themes page").write(to: url)
    }

    /// Industrial separates two kinds of raised action: coral CTAs keep the tight coral pair,
    /// while ordinary grey actions reuse the broad grey/white neumorphic relief. The full page
    /// catches regressions where every compact action becomes a detached coral blur.
    @MainActor
    func testRendersIndustrialThemeSettingsToImage() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let previous = AppThemeLibrary.current
        defer { AppThemeLibrary.apply(previous) }
        AppThemeLibrary.apply(AppThemeStyles.industrial)

        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let controller = ThemePreferencesViewController()
        let host = laidOut(
            controller.view,
            width: SettingsUIDefaults.pageWidth,
            height: Render.height
        )
        host.appearance = appearance
        controller.view.appearance = appearance

        var data: Data?
        appearance.performAsCurrentDrawingAppearance {
            host.applySurface(fill: Design.Surface.ground, radius: .fixed(0))
            AppThemeRefresh.repaint(host)
            host.layoutSubtreeIfNeeded()
            data = png(of: host)
        }

        let url = directory.appendingPathComponent("themes-industrial.png")
        try XCTUnwrap(data, "Failed to render the Industrial themes page").write(to: url)
    }

    // MARK: - Current App Theme

    @MainActor
    func testSettingsSidebarLeavesTheCurrentThemeDocumentToTheWorkspace() {
        XCTAssertFalse(
            SettingsPages.sidebarItems.contains { $0.title == L10n.string("Current Theme") },
            "the collaborative theme document returned to Settings"
        )
    }

    @MainActor
    func testABuiltInThemeIsLockedAndDuplicatesStraightIntoEditing() throws {
        let previous = AppThemeLibrary.current
        var created: AppTheme?
        defer {
            AppThemeLibrary.apply(previous)
            if let created { _ = AppThemeLibrary.delete(created) }
        }

        AppThemeLibrary.apply(AppThemeStyles.swissMinimalist)
        let controller = CurrentThemeViewController()
        _ = laidOut(controller.view, width: Render.widths[1], height: Render.height)

        let duplicate = try XCTUnwrap(
            descendant(
                in: controller.view,
                accessibilityIdentifier: "current-theme.duplicate"
            ) as? ThemedButton
        )
        let accent = try XCTUnwrap(
            descendant(
                in: controller.view,
                accessibilityIdentifier: "current-theme.color.accent"
            ) as? ThemeSwatchView
        )

        XCTAssertFalse(duplicate.isHidden)
        XCTAssertEqual(duplicate.title, L10n.string("Duplicate to Edit"))
        XCTAssertFalse(accent.isEditable, "a built-in theme exposed an editable color well")

        duplicate.performClick()
        created = AppThemeLibrary.current

        XCTAssertTrue(AppThemeLibrary.isCustom(try XCTUnwrap(created)))
        XCTAssertTrue(duplicate.isHidden, "the duplicate action survived on the editable copy")
        XCTAssertTrue(accent.isEditable, "the duplicate did not unlock the editor")
    }

    @MainActor
    func testAColorEditAppliesToTheActiveThemeImmediately() throws {
        let previous = AppThemeLibrary.current
        let copy = try AppThemeLibrary.duplicate(
            AppThemeStyles.swissMinimalist,
            name: "Live Editor \(UUID().uuidString)"
        )
        defer {
            AppThemeLibrary.apply(previous)
            _ = AppThemeLibrary.delete(copy)
        }
        AppThemeLibrary.apply(copy)

        let controller = CurrentThemeViewController()
        _ = laidOut(controller.view, width: Render.widths[1], height: Render.height)
        let accent = try XCTUnwrap(
            descendant(
                in: controller.view,
                accessibilityIdentifier: "current-theme.color.accent"
            ) as? ThemeSwatchView
        )
        let changed = try XCTUnwrap(NSColor(hex: "#0055BB"))

        accent.onChange?(changed)

        XCTAssertEqual(
            AppThemeLibrary.current.resolved(.accent).hexString,
            changed.hexString,
            "the color editor stored a value without applying the active theme"
        )
        XCTAssertEqual(accent.color.hexString, changed.hexString)
    }

    @MainActor
    func testAnExternalUpdateAppearsInTheOpenCurrentThemePage() throws {
        let previous = AppThemeLibrary.current
        let copy = try AppThemeLibrary.duplicate(
            AppThemeStyles.swissMinimalist,
            name: "Agent Update \(UUID().uuidString)"
        )
        defer {
            AppThemeLibrary.apply(previous)
            _ = AppThemeLibrary.delete(copy)
        }
        AppThemeLibrary.apply(copy)

        let controller = CurrentThemeViewController()
        _ = laidOut(controller.view, width: Render.widths[1], height: Render.height)
        let positive = try XCTUnwrap(
            descendant(
                in: controller.view,
                accessibilityIdentifier: "current-theme.color.status_positive"
            ) as? ThemeSwatchView
        )
        let changed = try XCTUnwrap(NSColor(hex: "#006B3C"))

        let updated = try replacing(
            .statusPositive,
            with: changed,
            in: copy,
            variant: .light
        )
        try AppThemeLibrary.update(updated)

        XCTAssertEqual(
            positive.color.hexString,
            changed.hexString,
            "the open page kept the value from before the agent-style update"
        )
    }

    @MainActor
    func testRendersCurrentThemePageInLockedAndEditableStates() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let previous = AppThemeLibrary.current
        let custom = try AppThemeLibrary.duplicate(
            AppThemeStyles.swissMinimalist,
            name: "Editable Render \(UUID().uuidString)"
        )
        defer {
            AppThemeLibrary.apply(previous)
            _ = AppThemeLibrary.delete(custom)
        }

        let fixtures: [(String, AppTheme, NSAppearance.Name)] = [
            ("system-light-locked", .system, .aqua),
            ("system-dark-locked", .system, .darkAqua),
            ("cyberpunk-locked", AppThemeStyles.cyberpunk, .darkAqua),
            ("custom-editable", custom, .aqua)
        ]
        var written: [String] = []
        for (name, theme, appearanceName) in fixtures {
            AppThemeLibrary.apply(theme)
            let controller = CurrentThemeViewController()
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            controller.view.appearance = appearance
            let host = laidOut(
                controller.view,
                width: SettingsUIDefaults.pageWidth,
                height: Render.height
            )
            host.appearance = appearance
            var topData: Data?
            appearance.performAsCurrentDrawingAppearance {
                host.applySurface(fill: Design.Surface.ground, radius: .fixed(0))
                AppThemeRefresh.repaint(host)
                host.layoutSubtreeIfNeeded()
                topData = png(of: host)
            }

            let topURL = directory.appendingPathComponent("current-theme-\(name)-top.png")
            try XCTUnwrap(
                topData,
                "Failed to render the top of the current-theme page for \(name)"
            ).write(to: topURL)
            written.append(topURL.lastPathComponent)

            let scroll = try XCTUnwrap(
                controller.view.subviews.first { $0 is NSScrollView } as? NSScrollView
            )
            let document = try XCTUnwrap(scroll.documentView)
            XCTAssertGreaterThan(
                document.bounds.height,
                scroll.contentView.bounds.height,
                "\(name) did not expose the lower theme roles through scrolling"
            )
            scroll.contentView.scroll(
                to: NSPoint(
                    x: 0,
                    y: max(0, document.bounds.height - scroll.contentView.bounds.height)
                )
            )
            scroll.reflectScrolledClipView(scroll.contentView)
            host.layoutSubtreeIfNeeded()

            var bottomData: Data?
            appearance.performAsCurrentDrawingAppearance {
                bottomData = png(of: host)
            }
            let bottomURL = directory.appendingPathComponent("current-theme-\(name)-bottom.png")
            try XCTUnwrap(
                bottomData,
                "Failed to render the bottom of the current-theme page for \(name)"
            ).write(to: bottomURL)
            written.append(bottomURL.lastPathComponent)
        }
        XCTAssertEqual(written.count, fixtures.count * 2)
    }

    // MARK: - Helpers

    @MainActor
    private func replacing(
        _ role: AppThemeRole,
        with color: NSColor,
        in theme: AppTheme,
        variant kind: AppTheme.VariantKind
    ) throws -> AppTheme {
        let source = try XCTUnwrap(theme.variant(kind))
        var roles = source.roles
        roles[role] = color
        var variants = theme.variants
        variants[kind] = AppTheme.Variant(
            roles: roles,
            terminalPalette: source.terminalPalette,
            material: source.material,
            sidebar: source.sidebar
        )
        return try AppThemeEditing.assemble(
            id: theme.id,
            name: theme.name,
            mode: theme.mode,
            summary: theme.summary,
            variants: variants
        )
    }

    @MainActor
    private func descendant(
        in view: NSView,
        accessibilityIdentifier: String
    ) -> NSView? {
        if view.accessibilityIdentifier() == accessibilityIdentifier { return view }
        return view.subviews.lazy.compactMap {
            self.descendant(in: $0, accessibilityIdentifier: accessibilityIdentifier)
        }.first
    }

    @MainActor
    private func pageImage(width: CGFloat, appearance name: NSAppearance.Name) -> Data? {
        let appearance = NSAppearance(named: name)

        var data: Data?
        let render = {
            let controller = ThemePreferencesViewController()
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

    @MainActor
    @discardableResult
    private func laidOut(_ view: NSView, width: CGFloat, height: CGFloat? = nil) -> NSView {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height ?? Render.height))
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)

        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])

        if height != nil {
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor).isActive = true
        }

        host.layoutSubtreeIfNeeded()

        // A view whose height comes from its content needs the host resized around it, or the
        // image is cropped to a frame nothing asked for.
        if height == nil {
            host.setFrameSize(NSSize(width: width, height: view.fittingSize.height))
            host.layoutSubtreeIfNeeded()
        }

        return host
    }

    // MARK: - The Sweep Reaches a Real Tree

    /// A live typeface switch has to move a page that was **already built**, which is the half
    /// the unit tests cannot show: they drive one label, and the claim here is that every label
    /// down a real settings page follows.
    ///
    /// The two themes differ in `typeface` and in nothing else — same roles, same palette, same
    /// radii — so a pixel that moves moved because of the typeface. Switching between two stock
    /// styles would have proved only that their colours differ.
    @MainActor
    func testALiveTypefaceSwitchMovesAPageThatWasAlreadyBuilt() throws {
        let sans = AppThemeStyles.swissMinimalist
        let serif = typefaceTwin(of: sans, .serif)
        defer { AppThemePalette.set(.system) }

        AppThemePalette.set(sans)
        let controller = ThemePreferencesViewController()
        let host = laidOut(controller.view, width: SettingsUIDefaults.pageWidth, height: Render.height)
        host.layoutSubtreeIfNeeded()

        let before = try XCTUnwrap(png(of: host))
        let proseBefore = proseFonts(in: host)
        XCTAssertFalse(proseBefore.isEmpty, "the page drew no prose at all — nothing is under test")
        let codeBefore = codeFonts(in: host)

        AppThemePalette.set(serif)
        AppThemeRefresh.repaint(host)
        host.layoutSubtreeIfNeeded()

        let proseAfter = proseFonts(in: host)
        XCTAssertEqual(proseAfter.count, proseBefore.count, "the sweep added or lost labels")
        for (index, after) in proseAfter.enumerated() where after.family == proseBefore[index].family {
            XCTFail("\(after.role) kept \(after.family) — the sweep did not reach it")
        }
        XCTAssertEqual(
            codeFonts(in: host).map(\.family), codeBefore.map(\.family),
            "a code label followed the typeface; code is monospaced under every style"
        )

        XCTAssertNotEqual(
            try XCTUnwrap(png(of: host)), before,
            "every label re-fonted and the page still drew identically"
        )
    }

    /// The recorded roles a tree is actually carrying, so a failure names the label rather than
    /// reporting that two images differ.
    @MainActor
    private func recordedFonts(in view: NSView) -> [(role: Design.FontRole, family: String)] {
        var found: [(Design.FontRole, String)] = []
        if let role = view.recordedFontRoleForTesting,
           let font = (view as? FontRoleApplying)?.appliedRoleFont {
            found.append((role, font.familyName ?? font.fontName))
        }
        for subview in view.subviews { found += recordedFonts(in: subview) }
        return found
    }

    @MainActor
    private func proseFonts(in view: NSView) -> [(role: Design.FontRole, family: String)] {
        recordedFonts(in: view).filter(\.role.followsTheme)
    }

    @MainActor
    private func codeFonts(in view: NSView) -> [(role: Design.FontRole, family: String)] {
        recordedFonts(in: view).filter { !$0.role.followsTheme }
    }

    /// The same theme with one field changed, which no stock pair provides.
    private func typefaceTwin(
        of theme: AppTheme,
        _ typeface: AppTheme.Material.Typeface
    ) -> AppTheme {
        var variants: [AppTheme.VariantKind: AppTheme.Variant] = [:]
        for (kind, variant) in theme.variants {
            let material = variant.material
            variants[kind] = AppTheme.Variant(
                roles: variant.roles,
                terminalPalette: variant.terminalPalette,
                material: AppTheme.Material(
                    panelRadius: material.panelRadius,
                    controlRadius: material.controlRadius,
                    borderWidth: material.borderWidth,
                    textScale: material.textScale,
                    glow: material.glow,
                    typeface: typeface
                )
            )
        }
        return AppTheme(
            id: AppThemeID("\(theme.id.rawValue)-typeface-twin"),
            name: theme.name,
            mode: theme.mode,
            summary: theme.summary,
            variants: variants
        )
    }

    @MainActor
    private func png(of host: NSView) -> Data? {
        guard host.bounds.height > 1,
              let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }

        // The settings page sits on the window's material and paints no ground of its own, so
        // one is painted here — otherwise every label draws onto transparency.
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
