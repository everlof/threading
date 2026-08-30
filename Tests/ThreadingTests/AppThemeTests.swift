import AppKit
import XCTest
@testable import Threading

/// The app-chrome theme: its roles, its derivations, and the promise that matters most —
/// that the **System theme remains available unchanged**.
///
/// That promise is the whole reason this refactor is safe to land before any style exists. The
/// design system's "system colours only" rule is not abolished by theming. System remains the
/// identity option while Threading supplies the fresh-profile product default.
@MainActor
final class AppThemeTests: HostedStoreTestCase {

    /// These tests run hosted in the app, so `UserDefaults.standard` is the shipping app's own
    /// domain — clearing the font-override keys outright would delete the developer's actual
    /// chosen fonts every time the suite runs. The real values are set aside before each test
    /// (which also keeps a machine where the feature is in use from failing the layer-order
    /// assertions) and put back after it.
    private var preservedFontOverrides: [String: String?] = [:]

    override func setUp() {
        super.setUp()
        preservedFontOverrides = [
            "chromeFontFamily": UserDefaults.standard.string(forKey: "chromeFontFamily"),
            "conversationFontFamily": UserDefaults.standard.string(forKey: "conversationFontFamily"),
            "appTextSize": UserDefaults.standard.string(forKey: "appTextSize")
        ]
        clearFontOverrides()
        UserDefaults.standard.set(AppTextSize.standard.rawValue, forKey: "appTextSize")
    }

    override func tearDown() {
        AppThemePalette.set(.system)
        for (key, value) in preservedFontOverrides {
            if let value {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        super.tearDown()
    }

    // MARK: - Font Helpers

    /// Two families macOS has shipped for its whole history, so the font tests do not depend on
    /// what this particular machine has installed. Asserted present rather than assumed.
    private static let chromeTestFamily = "Baskerville"
    private static let conversationTestFamily = "Palatino"

    func testThemeAssetPathsRefuseTraversalComponents() throws {
        for invalid in ["", ".", "..", "../outside", "nested/asset"] {
            XCTAssertFalse(AppThemeID(invalid).isSafeAssetDirectoryName)
            XCTAssertNil(ThemeAssetStore.image(
                named: "light-logo.png",
                for: AppThemeID(invalid)
            ))
        }
        XCTAssertFalse(AppThemeID.isSafePathComponent("../logo.png"))
        XCTAssertThrowsError(try ThemeAssetStore.restore(
            pngData: Data([0]),
            named: "../logo.png",
            for: AppThemeID("safe-theme")
        ))

        let source = AppThemeStyles.cyberpunk
        let invalidTheme = AppTheme(
            id: AppThemeID("../outside"),
            name: source.name,
            mode: source.mode,
            summary: source.summary,
            variants: source.variants
        )
        XCTAssertThrowsError(try AppThemeEditing.validate(invalidTheme))
    }

    func testTheFontFixturesAreInstalled() {
        let families = NSFontManager.shared.availableFontFamilies
        XCTAssertTrue(families.contains(Self.chromeTestFamily))
        XCTAssertTrue(families.contains(Self.conversationTestFamily))
    }

    /// The keys are written directly rather than through `AppSettings.shared`, so the tests do
    /// not post `AppSettingsDidChange` into a running app's observers.
    private func clearFontOverrides() {
        UserDefaults.standard.removeObject(forKey: "chromeFontFamily")
        UserDefaults.standard.removeObject(forKey: "conversationFontFamily")
    }

    /// A copy of a stock theme that replaces (or clears) its named family.
    private func themeNaming(family: String?, on theme: AppTheme) -> AppTheme {
        var variants: [AppTheme.VariantKind: AppTheme.Variant] = [:]
        for (kind, variant) in theme.variants {
            var material = variant.material
            material.fontFamily = family
            variants[kind] = AppTheme.Variant(
                roles: variant.roles,
                terminalPalette: variant.terminalPalette,
                material: material
            )
        }
        return AppTheme(
            id: AppThemeID("\(theme.id.rawValue)-family"),
            name: theme.name,
            mode: theme.mode,
            summary: theme.summary,
            variants: variants
        )
    }

    // MARK: - The System Theme Changes Nothing

    /// Pure fixes both its grounds at the extremes, and true black is the one ground dark
    /// enough that the derived quiet tiers — `label × {0.7, 0.45}`, floored only at the
    /// glanceable 3:1 — leave a small mark like a dormant session's agent icon at the edge of
    /// visible: thin strokes anti-alias into the black and it reads as gone. Both variants state
    /// their own quiet ramp instead; this guards that each ramp stays legible on its ground and
    /// on the slightly shifted sidebar surface it is drawn over, so a revert to derivation fails
    /// rather than ships an invisible icon.
    func testPureQuietLabelTiersStayLegibleOnBothOfItsGrounds() throws {
        let theme = AppThemeStyles.pure
        for kind in AppTheme.VariantKind.allCases {
            let appearance = try XCTUnwrap(kind.appearance)
            let ground = theme.resolved(.ground, appearance: appearance)
            let surface = theme.resolved(.surface, appearance: appearance)
            for role in [AppThemeRole.secondaryLabel, .tertiaryLabel] {
                let ink = theme.resolved(role, appearance: appearance)
                XCTAssertGreaterThanOrEqual(
                    ThemeContrast.ratio(ink, ground), 4.0,
                    "\(role) at \(ink.hexString) is too faint on Pure's \(kind.rawValue) ground"
                )
                XCTAssertGreaterThanOrEqual(
                    ThemeContrast.ratio(ink, surface), 4.0,
                    "\(role) at \(ink.hexString) is too faint on Pure's \(kind.rawValue) sidebar surface"
                )
            }
        }
    }

    /// Pure shipped as the fixed dark "Pure Black" under the id `pure-black`, and a stock id
    /// is persistence identity: every Mac that chose it has that slug on disk. The retired id
    /// resolves to its successor without becoming a catalogue entry of its own.
    func testARetiredStockIDResolvesToItsSuccessorWithoutJoiningTheCatalogue() {
        let retired = AppThemeStyles.retiredPureBlackID

        XCTAssertEqual(AppThemeLibrary.theme(withID: retired)?.id, AppThemeStyles.pure.id)
        XCTAssertFalse(
            AppThemeLibrary.all.contains { $0.id == retired },
            "a retired id is an alias, not a second row in the picker"
        )
        XCTAssertNil(
            AppThemeLibrary.theme(withID: AppThemeID("pure-white")),
            "only a retired id is redirected; an unknown one still misses"
        )
    }

    /// The standing choice recorded before the rename still comes back as Pure at launch.
    /// `restore` deliberately writes nothing, so the old slug is left on disk and keeps
    /// resolving through the alias until the next deliberate pick records the successor.
    func testAStoredRetiredIDRestoresItsSuccessor() {
        let store = PreferenceStore.shared
        let preserved = store.string(forKey: "appThemeID")
        defer {
            if let preserved {
                store.set(preserved, forKey: "appThemeID")
            } else {
                store.removeObject(forKey: "appThemeID")
            }
            AppThemeLibrary.restore()
        }

        store.set(AppThemeStyles.retiredPureBlackID.rawValue, forKey: "appThemeID")
        AppThemeLibrary.restore()

        XCTAssertEqual(AppThemeLibrary.current.id, AppThemeStyles.pure.id)
        XCTAssertEqual(
            store.string(forKey: "appThemeID"), AppThemeStyles.retiredPureBlackID.rawValue,
            "restore does not write"
        )
    }

    func testSystemThemeResolvesEveryRoleToItsSystemColour() {
        AppThemePalette.set(.system)

        for role in AppThemeRole.allCases {
            XCTAssertEqual(
                AppTheme.system.resolved(role),
                role.systemColor,
                "\(role.rawValue) drifted from the colour the app used before theming"
            )
        }
    }

    func testSystemThemeIsExplicitlyAdaptiveAcrossLightAndDarkAppearances() throws {
        XCTAssertEqual(AppTheme.system.mode, .system)
        XCTAssertNil(AppTheme.Mode.system.appearance)
        XCTAssertTrue(AppTheme.system.variants.isEmpty)

        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        var lightGround = ""
        var darkGround = ""
        var lightLabel = ""
        var darkLabel = ""

        light.performAsCurrentDrawingAppearance {
            lightGround = (AppTheme.system.resolved(.ground).usingColorSpace(.sRGB) ?? .black).hexString
            lightLabel = (AppTheme.system.resolved(.label).usingColorSpace(.sRGB) ?? .black).hexString
        }
        dark.performAsCurrentDrawingAppearance {
            darkGround = (AppTheme.system.resolved(.ground).usingColorSpace(.sRGB) ?? .black).hexString
            darkLabel = (AppTheme.system.resolved(.label).usingColorSpace(.sRGB) ?? .black).hexString
        }

        XCTAssertNotEqual(lightGround, darkGround)
        XCTAssertNotEqual(lightLabel, darkLabel)
        XCTAssertNotNil(AppTheme.Mode.light.appearance)
        XCTAssertNotNil(AppTheme.Mode.dark.appearance)
    }

    func testAuthoredAdaptiveThemeResolvesItsCompleteMatchingVariant() throws {
        let theme = try adaptiveFixture()
        let lightAppearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let darkAppearance = try XCTUnwrap(NSAppearance(named: .darkAqua))

        XCTAssertEqual(
            theme.resolved(.ground, appearance: lightAppearance).hexString,
            AppThemeStyles.swissMinimalist.resolved(.ground).hexString
        )
        XCTAssertEqual(
            theme.resolved(.ground, appearance: darkAppearance).hexString,
            AppThemeStyles.cyberpunk.resolved(.ground).hexString
        )
        XCTAssertEqual(
            theme.variant(for: lightAppearance)?.material,
            AppThemeStyles.swissMinimalist.material
        )
        XCTAssertEqual(
            theme.variant(for: darkAppearance)?.material,
            AppThemeStyles.cyberpunk.material
        )
        XCTAssertEqual(
            theme.variant(for: lightAppearance)?.terminalPalette.id,
            AppThemeStyles.swissMinimalist.terminalPalette.id
        )
        XCTAssertEqual(
            theme.variant(for: darkAppearance)?.terminalPalette.id,
            AppThemeStyles.cyberpunk.terminalPalette.id
        )
    }

    /// Material follows the drawing appearance — it is read while drawing. The terminal palette
    /// deliberately does **not**: it is consumed as data from setup code and notification
    /// handlers, where the ambient drawing appearance is stale, so its variant is chosen by the
    /// appearance a caller states (`terminalPalette(for:)`), and the parameterless var anchors
    /// to the application's.
    func testCompatibilityProjectionsFollowTheAppearanceTheyAreAskedFor() throws {
        let theme = try adaptiveFixture()
        let lightAppearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let darkAppearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        var lightRadius: CGFloat = -1
        var darkRadius: CGFloat = -1

        lightAppearance.performAsCurrentDrawingAppearance {
            lightRadius = theme.material.panelRadius
        }
        darkAppearance.performAsCurrentDrawingAppearance {
            darkRadius = theme.material.panelRadius
        }

        XCTAssertEqual(lightRadius, AppThemeStyles.swissMinimalist.material.panelRadius)
        XCTAssertEqual(darkRadius, AppThemeStyles.cyberpunk.material.panelRadius)
        XCTAssertEqual(
            theme.terminalPalette(for: lightAppearance).background.hexString,
            AppThemeStyles.swissMinimalist.terminalPalette.background.hexString
        )
        XCTAssertEqual(
            theme.terminalPalette(for: darkAppearance).background.hexString,
            AppThemeStyles.cyberpunk.terminalPalette.background.hexString
        )
    }

    // MARK: - Typeface

    /// The other half of a style brief: a theme states which platform typeface the chrome is
    /// set in, `Design.Typography` interprets it, and System keeps SF exactly.
    func testTheThemeTypefaceReachesProseAndSparesCode() throws {
        AppThemePalette.set(.system)
        let plain = NSFont.systemFont(ofSize: 13, weight: .regular)
        XCTAssertEqual(Design.Typography.body().fontName, plain.fontName)

        AppThemePalette.set(AppThemeStyles.newsprint)
        let serifBody = Design.Typography.body()
        XCTAssertNotEqual(
            serifBody.fontName, plain.fontName,
            "Newsprint is a serif brief; its body must not still be SF Sans"
        )
        XCTAssertEqual(serifBody.pointSize, 13)

        // Code is monospaced under every style; a serif diff is not a style, it is a defect.
        let code = Design.Typography.code()
        XCTAssertTrue(
            code.fontDescriptor.symbolicTraits.contains(.monoSpace),
            "code stopped being monospaced under a serif theme"
        )

        AppThemePalette.set(AppThemeStyles.cyberpunk)
        XCTAssertTrue(
            Design.Typography.body().fontDescriptor.symbolicTraits.contains(.monoSpace),
            "Cyberpunk is a mono brief; its prose should be monospaced"
        )
    }

    /// Reference styles may set display typography independently from their reading face.
    /// Botanical is the load-bearing example: serif headings over sans body copy.
    func testHeadingStyleChangesHeadingsWithoutRefontingBodyCopy() throws {
        AppThemePalette.set(AppThemeStyles.botanical)

        let heading = Design.Typography.heading()
        let body = Design.Typography.body()
        XCTAssertNotEqual(
            heading.familyName,
            body.familyName,
            "Botanical collapsed its measured serif-display/sans-body pairing"
        )

        AppThemePalette.set(AppThemeStyles.artDeco)
        let decoHeading = Design.Typography.heading()
        let decoBody = Design.Typography.body()
        XCTAssertNotEqual(
            decoHeading.familyName,
            decoBody.familyName,
            "Art Deco's display face leaked into the reference's plain sans body copy"
        )
        XCTAssertEqual(decoHeading.familyName, "Avenir Next")
        XCTAssertFalse(
            decoHeading.fontDescriptor.symbolicTraits.contains(.bold),
            "Art Deco's regular display weight became heavier than its reference"
        )
    }

    // MARK: - A Live Switch Moves the Whole Window

    /// A label keeps the `NSFont` object it was handed, exactly as a layer keeps a `CGColor`, so
    /// a theme switch leaves it set in the previous typeface until something takes the decision
    /// again. This is that sweep, on one label.
    func testARecordedRoleFollowsALiveTypefaceSwitch() throws {
        AppThemePalette.set(.system)
        let label = NSTextField(labelWithString: "Threading")
        label.applyFont(.body)
        let sans = try XCTUnwrap(label.font)

        AppThemePalette.set(AppThemeStyles.newsprint)
        XCTAssertEqual(
            label.font?.fontName, sans.fontName,
            "the freeze this exists to undo stopped happening — the test is no longer testing it"
        )

        label.reapplyRecordedFontForTesting()
        let serif = try XCTUnwrap(label.font)
        XCTAssertEqual(serif.fontName, Design.Typography.body().fontName)
        XCTAssertNotEqual(serif.fontName, sans.fontName, "the label kept SF Sans under Newsprint")
        XCTAssertEqual(serif.pointSize, sans.pointSize, "the sweep changed the size as well as the design")
    }

    /// The round trip is the case nothing read back off the *font* could ever serve: under a
    /// mono brief a prose font and a code font are byte-identical, so only the recorded role
    /// knows that one of these two labels must return to SF Sans and the other must not.
    func testProseReturnsFromAMonoThemeWhileCodeStaysPut() throws {
        AppThemePalette.set(AppThemeStyles.cyberpunk)
        let prose = NSTextField(labelWithString: "Ready")
        prose.applyFont(.body)
        let code = NSTextField(labelWithString: "git status")
        code.applyFont(.code())

        XCTAssertTrue(
            try XCTUnwrap(prose.font).fontDescriptor.symbolicTraits.contains(.monoSpace),
            "Cyberpunk's prose should be monospaced, which is what makes this ambiguous"
        )

        AppThemePalette.set(AppThemeStyles.newsprint)
        prose.reapplyRecordedFontForTesting()
        code.reapplyRecordedFontForTesting()

        XCTAssertFalse(
            try XCTUnwrap(prose.font).fontDescriptor.symbolicTraits.contains(.monoSpace),
            "prose stayed monospaced after leaving a mono theme"
        )
        XCTAssertTrue(
            try XCTUnwrap(code.font).fontDescriptor.symbolicTraits.contains(.monoSpace),
            "code followed the theme into serif; a serif diff is not a style, it is a defect"
        )
    }

    /// A role is the whole call, not a category: a weight given at the call site has to come
    /// back after the switch, or every emphasised label quietly returns as regular.
    func testARecordedRoleKeepsItsWeightAndScale() throws {
        AppThemePalette.set(.system)
        let label = NSTextField(labelWithString: "Detail")
        label.applyFont(.detail(weight: .medium))

        AppThemePalette.set(AppThemeStyles.newsprint)
        label.reapplyRecordedFontForTesting()

        XCTAssertEqual(label.font?.fontName, Design.Typography.detail(weight: .medium).fontName)
        XCTAssertNotEqual(
            label.font?.fontName, Design.Typography.detail().fontName,
            "the medium weight was dropped on the way through the sweep"
        )
    }

    /// Numeric keeps SF's monospaced digits under every typeface — a usage column that stops
    /// aligning costs more than a serif digit is worth.
    func testNumericRolesDoNotFollowTheTypeface() throws {
        AppThemePalette.set(.system)
        let numeric = NSTextField(labelWithString: "5h 43%")
        numeric.applyFont(.numericControl())
        let before = try XCTUnwrap(numeric.font)

        AppThemePalette.set(AppThemeStyles.newsprint)
        numeric.reapplyRecordedFontForTesting()

        XCTAssertEqual(numeric.font?.fontName, before.fontName, "a usage column went serif")
    }

    /// A font the design system never vended is not the sweep's business — the terminal's own
    /// font is the case that matters, and it belongs to the user's profile.
    func testAnUnrecordedFontIsLeftAlone() throws {
        AppThemePalette.set(.system)
        let label = NSTextField(labelWithString: "Terminal")
        let chosen = try XCTUnwrap(NSFont(name: "Menlo", size: 12))
        label.font = chosen

        AppThemePalette.set(AppThemeStyles.newsprint)
        label.reapplyRecordedFontForTesting()

        XCTAssertNil(label.recordedFontRoleForTesting)
        XCTAssertEqual(
            label.font?.fontName, chosen.fontName,
            "the sweep re-fonted a view the design system never vended to"
        )
    }

    // MARK: - The User's Own Font

    /// The four layers, in order, on one label. Each step removes the layer above it and the
    /// answer has to fall exactly one rung — not to SF, which is the failure this orders against.
    func testAnOverrideBeatsTheThemeAndFallsThroughOneLayerAtATime() throws {
        defer { clearFontOverrides() }
        AppThemePalette.set(AppThemeStyles.newsprint)

        let serif = Design.Typography.body().familyName
        XCTAssertEqual(
            serif, Design.Typography.body(surface: .conversation).familyName,
            "with no overrides set, both surfaces answer with the theme"
        )

        UserDefaults.standard.set(Self.chromeTestFamily, forKey: "chromeFontFamily")
        XCTAssertEqual(Design.Typography.body().familyName, Self.chromeTestFamily)
        XCTAssertEqual(
            Design.Typography.body(surface: .conversation).familyName, Self.chromeTestFamily,
            "the conversation must fall through to the app override, not past it to the theme"
        )

        UserDefaults.standard.set(Self.conversationTestFamily, forKey: "conversationFontFamily")
        XCTAssertEqual(Design.Typography.body().familyName, Self.chromeTestFamily)
        XCTAssertEqual(
            Design.Typography.body(surface: .conversation).familyName, Self.conversationTestFamily,
            "the nearer override must win for its own surface"
        )

        clearFontOverrides()
        XCTAssertEqual(Design.Typography.body().familyName, serif, "the theme should be back")
    }

    /// A family the machine does not have is not an error — it is the next layer's turn. This is
    /// the same rule a dangling terminal-theme name already follows.
    func testAnUninstalledFamilyDegradesRatherThanFailing() throws {
        defer { clearFontOverrides() }
        AppThemePalette.set(AppThemeStyles.newsprint)
        let serif = try XCTUnwrap(Design.Typography.body().familyName)

        UserDefaults.standard.set("NoSuchFamilyXYZ123", forKey: "chromeFontFamily")
        XCTAssertEqual(
            Design.Typography.body().familyName, serif,
            "an uninstalled override should fall to the theme, not to a substituted font"
        )

        // And the same for a *theme* that names one, which is the portable case: a theme is
        // authored on one machine and read on another.
        AppThemePalette.set(themeNaming(family: "NoSuchFamilyXYZ123", on: AppThemeStyles.newsprint))
        clearFontOverrides()
        let fallback = Design.Typography.body().familyName

        // Newsprint intentionally names Baskerville. Once that name is replaced by an invalid
        // portable family, the next layer is its serif *design*, not the replaced Baskerville
        // string. Compare with the same material after explicitly clearing the family.
        AppThemePalette.set(themeNaming(family: nil, on: AppThemeStyles.newsprint))
        XCTAssertEqual(fallback, Design.Typography.body().familyName)
    }

    /// A theme may be more specific than the four classes its brief states.
    func testAThemeMayNameItsOwnFamily() throws {
        defer { clearFontOverrides() }
        AppThemePalette.set(themeNaming(family: Self.chromeTestFamily, on: AppThemeStyles.swissMinimalist))
        XCTAssertEqual(Design.Typography.body().familyName, Self.chromeTestFamily)

        // ...and the user still outranks it.
        UserDefaults.standard.set(Self.conversationTestFamily, forKey: "chromeFontFamily")
        XCTAssertEqual(Design.Typography.body().familyName, Self.conversationTestFamily)
    }

    /// Code, numerics and the terminal are the three things no font setting reaches.
    func testTheOverrideSparesCodeAndNumerics() throws {
        defer { clearFontOverrides() }
        let code = Design.Typography.code().fontName
        let numeric = Design.Typography.numericBody().fontName

        UserDefaults.standard.set(Self.chromeTestFamily, forKey: "chromeFontFamily")
        UserDefaults.standard.set(Self.conversationTestFamily, forKey: "conversationFontFamily")

        XCTAssertEqual(Design.Typography.code().fontName, code, "a diff went proportional")
        XCTAssertEqual(Design.Typography.numericBody().fontName, numeric, "a usage column stopped aligning")
    }

    /// Weight survives the family swap — the trap being that the obvious
    /// `fontDescriptor.withFamily` route silently keeps the system font instead.
    func testAnOverrideKeepsItsWeight() throws {
        defer { clearFontOverrides() }
        UserDefaults.standard.set(Self.chromeTestFamily, forKey: "chromeFontFamily")

        let regular = Design.Typography.body()
        let bold = Design.Typography.strongBody()
        XCTAssertEqual(regular.familyName, Self.chromeTestFamily)
        XCTAssertEqual(bold.familyName, Self.chromeTestFamily)
        XCTAssertNotEqual(regular.fontName, bold.fontName, "both weights resolved to one face")
        XCTAssertTrue(bold.fontDescriptor.symbolicTraits.contains(.bold))
    }

    /// A recorded role carries its surface, so the sweep re-resolves a conversation label
    /// against the conversation's override rather than the chrome's.
    func testTheSweepRemembersWhichSurfaceALabelBelongsTo() throws {
        defer { clearFontOverrides() }
        let label = NSTextField(labelWithString: "Ready")
        label.applyFont(.body, in: .conversation)
        XCTAssertEqual(label.recordedFontSurfaceForTesting, .conversation)

        UserDefaults.standard.set(Self.conversationTestFamily, forKey: "conversationFontFamily")
        label.reapplyRecordedFontForTesting()
        XCTAssertEqual(label.font?.familyName, Self.conversationTestFamily)

        let chrome = NSTextField(labelWithString: "Settings")
        chrome.applyFont(.body)
        chrome.reapplyRecordedFontForTesting()
        XCTAssertNotEqual(
            chrome.font?.familyName, Self.conversationTestFamily,
            "a chrome label took the conversation's font"
        )
    }

    /// Transcript text resolves in the conversation's font. Plain notice/streaming rows record
    /// their role for the sweep; thinking is parsed Markdown, so it rebuilds its attributed runs
    /// on the same event instead of printing the provider's markers or freezing the old face.
    func testConversationRowsAreSetInTheConversationFontAndFollowTheSweep() throws {
        defer { clearFontOverrides() }
        UserDefaults.standard.set(Self.conversationTestFamily, forKey: "conversationFontFamily")

        let streaming = ConversationRowView.streaming("Working")
        let thinking = try XCTUnwrap(
            ConversationRowView.thinking("**Reasoning**") as? MarkdownView
        )
        let notice = try XCTUnwrap(
            ConversationRowView.notice("Truncated", kind: .muted) as? NSTextField
        )
        for label in [streaming, notice] {
            XCTAssertEqual(label.font?.familyName, Self.conversationTestFamily)
            XCTAssertEqual(label.recordedFontSurfaceForTesting, .conversation)
        }

        let renderedThinking = try XCTUnwrap(
            Self.textFields(in: thinking).first { $0.stringValue == "Reasoning" }
        )
        let thinkingFont = try XCTUnwrap(
            renderedThinking.attributedStringValue.attribute(
                .font,
                at: 0,
                effectiveRange: nil
            ) as? NSFont
        )
        XCTAssertEqual(thinkingFont.familyName, Self.conversationTestFamily)
        XCTAssertTrue(thinkingFont.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertFalse(renderedThinking.stringValue.contains("**"))

        // Both mechanisms take the decision again when the setting changes.
        clearFontOverrides()
        streaming.reapplyRecordedFontForTesting()
        XCTAssertNotEqual(streaming.font?.familyName, Self.conversationTestFamily)
        NotificationCenter.default.post(AppThemeDidChange(themeID: AppThemeLibrary.current.id))

        let restyledThinking = try XCTUnwrap(
            Self.textFields(in: thinking).first { $0.stringValue == "Reasoning" }
        )
        let restyledFont = try XCTUnwrap(
            restyledThinking.attributedStringValue.attribute(
                .font,
                at: 0,
                effectiveRange: nil
            ) as? NSFont
        )
        XCTAssertNotEqual(restyledFont.familyName, Self.conversationTestFamily)
    }

    /// A `# Heading` scales from the body through `Typography`, which re-enters the four
    /// layers — and it must re-enter them in its own document's surface, or a conversation
    /// font leaves the heading in one family and its paragraph in another.
    func testAMarkdownHeadingStaysInItsParagraphsFamily() throws {
        defer { clearFontOverrides() }
        UserDefaults.standard.set(Self.conversationTestFamily, forKey: "conversationFontFamily")

        let blocks = Markdown.parse("# Title\n\nBody text", style: .assistant)
        guard case .heading(let heading) = blocks.first,
              case .paragraph(let paragraph) = blocks.dropFirst().first else {
            return XCTFail("expected a heading and a paragraph, got \(blocks)")
        }
        let headingFont = try XCTUnwrap(heading.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let bodyFont = try XCTUnwrap(paragraph.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)

        XCTAssertEqual(headingFont.familyName, Self.conversationTestFamily)
        XCTAssertEqual(headingFont.familyName, bodyFont.familyName)
        XCTAssertGreaterThan(headingFont.pointSize, bodyFont.pointSize, "a heading that stopped being one")
    }

    /// Fonts are consumed as data — a label keeps the `NSFont` it was handed — so the theme's
    /// half of the resolution anchors to the **application's** appearance, the same anchoring
    /// `terminalPalette` chose for the same reason. Resolved under an ambient drawing
    /// appearance that contradicts the app's, an adaptive theme whose variants state different
    /// families must still answer with the app's variant.
    func testProseResolvesTheVariantForTheAppsAppearanceNotTheAmbientOne() throws {
        let base = AppThemeStyles.newsprint
        let variant = try XCTUnwrap(base.variants.values.first)
        func naming(_ family: String) -> AppTheme.Variant {
            var material = variant.material
            material.fontFamily = family
            return AppTheme.Variant(
                roles: variant.roles,
                terminalPalette: variant.terminalPalette,
                material: material
            )
        }
        AppThemePalette.set(AppTheme(
            id: AppThemeID("adaptive-faces"),
            name: "Adaptive Faces",
            mode: .system,
            summary: nil,
            variants: [
                .light: naming(Self.chromeTestFamily),
                .dark: naming(Self.conversationTestFamily)
            ]
        ))

        let appKind = AppTheme.VariantKind.current(in: NSApplication.shared.effectiveAppearance)
        let expected = appKind == .dark ? Self.conversationTestFamily : Self.chromeTestFamily
        let contradicting = try XCTUnwrap(
            NSAppearance(named: appKind == .dark ? .aqua : .darkAqua)
        )

        var resolved: String?
        contradicting.performAsCurrentDrawingAppearance {
            resolved = Design.Typography.body().familyName
        }
        XCTAssertEqual(resolved, expected, "the ambient appearance chose the variant")
    }

    /// `setOrRemove` never writes an empty string, but a hand-edited or migrated default could —
    /// and `""` must read as "no override", not as a question for the descriptor matcher.
    func testAnEmptyStringOverrideIsIgnoredRatherThanResolved() throws {
        defer { clearFontOverrides() }
        AppThemePalette.set(AppThemeStyles.newsprint)
        let themed = Design.Typography.body().familyName

        UserDefaults.standard.set("", forKey: "chromeFontFamily")
        XCTAssertEqual(Design.Typography.body().familyName, themed)
    }

    /// A pre-font-family document still decodes, the same promise the typeface field made.
    func testPreFontFamilyMaterialDocumentsDecodeWithDefaults() throws {
        let legacy = Data(#"{"panelRadius": 18, "typeface": "serif"}"#.utf8)
        let material = try JSONDecoder().decode(AppTheme.Material.self, from: legacy)
        XCTAssertEqual(material.panelRadius, 18)
        XCTAssertEqual(material.typeface, .serif)
        XCTAssertNil(material.fontFamily)
        XCTAssertTrue(material.fontFallbacks.isEmpty)
        XCTAssertNil(material.controlGlow)
        XCTAssertNil(material.controlBorderWidth)
        XCTAssertEqual(material.resolvedControlBorderWidth, material.borderWidth)
        XCTAssertEqual(material.textScale, 1)
        XCTAssertEqual(material.choiceHeight, 26)
        XCTAssertEqual(material.buttonStyle, .system)
        XCTAssertNil(material.headingStyle)
        XCTAssertEqual(material.popoverStyle, .system)
        XCTAssertEqual(material.menuAppearance, .automatic)
        XCTAssertEqual(material.checkboxStyle, .automatic)
        XCTAssertEqual(material.toggleStyle, .automatic)

        let named = AppTheme.Material(
            textScale: 0.8,
            typeface: .serif,
            fontFamily: "Baskerville",
            fontFallbacks: ["Palatino"]
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                AppTheme.Material.self, from: try JSONEncoder().encode(named)
            ),
            named
        )
    }

    func testAnUnavailableHistoricalFamilyUsesItsFirstInstalledFallback() {
        let base = AppThemeStyles.newsprint
        var variants: [AppTheme.VariantKind: AppTheme.Variant] = [:]
        for (kind, variant) in base.variants {
            var material = variant.material
            material.fontFamily = "Definitely Not An Installed Family"
            material.fontFallbacks = [Self.chromeTestFamily, Self.conversationTestFamily]
            variants[kind] = AppTheme.Variant(
                roles: variant.roles,
                terminalPalette: variant.terminalPalette,
                material: material,
                sidebar: variant.sidebar,
                chrome: variant.chrome
            )
        }
        AppThemePalette.set(AppTheme(
            id: AppThemeID("historical-face-fallback"),
            name: "Historical face fallback",
            mode: base.mode,
            summary: nil,
            variants: variants
        ))

        XCTAssertEqual(Design.Typography.body().familyName, Self.chromeTestFamily)
    }

    func testRetroThemesKeepExactFontsAheadOfSafeInstalledSubstitutes() throws {
        let win98 = try XCTUnwrap(AppThemeStyles.win98.variant(.light)?.material)
        XCTAssertEqual(Array(win98.fontFamilies.prefix(5)), [
            "MS Sans Serif", "Microsoft Sans Serif", "W95FA", "Tahoma", "Geneva"
        ])
        XCTAssertEqual(win98.progressStyle, .segmented)
        XCTAssertEqual(win98.choiceStyle, .dropdown)
        XCTAssertEqual(win98.menuAppearance, .windows98)
        XCTAssertEqual(win98.choiceHeight, 21)
        XCTAssertEqual(win98.buttonStyle.primaryTreatment, .raised)
        XCTAssertEqual(win98.buttonStyle.fontWeight, .regular)
        XCTAssertEqual(win98.checkboxStyle, .windows98Tick)
        // COLOR_WINDOWFRAME, this theme's black `.label` — not `.border`, which is COLOR_BTNSHADOW
        // gray and is already drawing the bevel. `ThemedControlTests` samples the pixel this
        // decides: in shadow gray the default button's extra frame reads as one more bevel edge,
        // and the dialog stops saying which action Return takes.
        XCTAssertEqual(win98.buttonStyle.primaryRole, .label)
        XCTAssertEqual(win98.textScale, 0.80)
        XCTAssertEqual(AppThemeStyles.win98.resolved(.fieldSurface).hexString, "#FFFFFF")

        let platinum = try XCTUnwrap(AppThemeStyles.platinum.variant(.light)?.material)
        XCTAssertEqual(platinum.fontFamilies, ["Charcoal", "Geneva"])
        XCTAssertEqual(platinum.choiceStyle, .doubleArrowPopup)
        XCTAssertEqual(platinum.menuAppearance, .platinum)
        XCTAssertEqual(platinum.choiceHeight, 16)
        XCTAssertEqual(AppThemeStyles.platinum.resolved(.floatingSurface).hexString, "#DDDDDD")
        XCTAssertNotEqual(
            AppThemeStyles.platinum.resolved(.floatingSurface).hexString,
            AppThemeStyles.platinum.resolved(.fieldSurface).hexString,
            "Platinum floating chrome became the white/value-well surface again"
        )

        let tiger = try XCTUnwrap(AppThemeStyles.aquaTiger.variant(.light)?.material)
        XCTAssertEqual(tiger.fontFamilies, ["Lucida Grande", "Helvetica Neue"])
        XCTAssertEqual(tiger.choiceStyle, .aquaPopup)
        XCTAssertEqual(tiger.choiceHeight, 22)
        XCTAssertEqual(tiger.scrollerAppearance, .aquaTiger)
        XCTAssertEqual(tiger.menuAppearance, .aquaTiger)
        XCTAssertTrue(tiger.scrollerAppearance.groupsArrowsAtTrailingEnd)

        let beOS = try XCTUnwrap(AppThemeStyles.beOS.variant(.light)?.material)
        XCTAssertEqual(beOS.fontFamilies, ["Swis721 BT", "Swiss 721", "Helvetica"])
        XCTAssertEqual(beOS.choiceStyle, .popup)
        XCTAssertEqual(beOS.menuAppearance, .beOS)
        XCTAssertEqual(beOS.choiceHeight, 18)
        XCTAssertEqual(beOS.checkboxStyle, .beOSCross)
        XCTAssertEqual(AppThemeStyles.beOS.resolved(.fieldSurface).hexString, "#FFFFFF")

        let amiga = try XCTUnwrap(AppThemeStyles.amiga.variant(.light)?.material)
        XCTAssertEqual(amiga.fontFamilies, [
            "Topaz",
            "Topaz a600a1200a400",
            "Topaz a600a1200a4000",
            "TopazPlus a600a1200a4000",
            "TopazPlus",
            "Monaco"
        ])
        XCTAssertEqual(amiga.choiceStyle, .cycle)
        XCTAssertEqual(amiga.menuAppearance, .amiga)
        XCTAssertEqual(amiga.progressStyle, .amiga)
        XCTAssertEqual(amiga.choiceHeight, 18)
        XCTAssertEqual(amiga.checkboxStyle, .recessedTick)
        XCTAssertEqual(
            AppThemeStyles.amiga.resolved(.panel).hexString,
            "#AAAAAA",
            "Workbench panels must stay inside the stock four-colour palette"
        )

        let openStep = try XCTUnwrap(AppThemeStyles.openStep.variant(.light)?.material)
        XCTAssertEqual(openStep.choiceStyle, .popup)
        XCTAssertEqual(openStep.menuAppearance, .openStep)
        XCTAssertEqual(openStep.choiceHeight, 18)
        let irix = try XCTUnwrap(AppThemeStyles.irix.variant(.light)?.material)
        XCTAssertEqual(irix.choiceStyle, .popup)
        XCTAssertEqual(irix.menuAppearance, .irix)
        XCTAssertEqual(irix.progressStyle, .irix)
        XCTAssertEqual(irix.choiceHeight, 20)
        XCTAssertEqual(AppThemeStyles.irix.resolved(.statusPositive).hexString, "#2F8A4F")

        let classicPlayer = try XCTUnwrap(
            AppThemeStyles.classicPlayer.variant(.dark)?.material
        )
        XCTAssertEqual(classicPlayer.toggleStyle, .onOffButton)
        XCTAssertEqual(classicPlayer.chartStyle, .spectrum)
        XCTAssertEqual(classicPlayer.buttonStyle.textTransform, .uppercase)
        XCTAssertEqual(classicPlayer.buttonStyle.titleRendering, .pixel5x6)
        XCTAssertTrue(classicPlayer.buttonStyle.antialiasesTitle)

        for material in [platinum, beOS, openStep, irix, amiga] {
            XCTAssertEqual(material.buttonStyle.primaryTreatment, .raised)
            XCTAssertEqual(material.buttonStyle.fontWeight, .regular)
            XCTAssertEqual(material.buttonStyle.primaryRole, .border)
        }
    }

    func testControlGlowRoundTripsWithoutChangingOlderMaterials() throws {
        let authored = AppTheme.Material(
            controlGlow: AppTheme.Glow(
                role: .accent,
                radius: 6,
                opacity: 0.3,
                offsetX: 6,
                offsetY: -6,
                highlight: AppTheme.Glow.Highlight(
                    role: .bevelHighlight,
                    radius: 4,
                    opacity: 0.45,
                    offsetX: -4,
                    offsetY: 4
                )
            )
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                AppTheme.Material.self,
                from: JSONEncoder().encode(authored)
            ),
            authored
        )
    }

    func testPopoverStyleRoundTripsAndSparseDocumentsKeepSystemDefaults() throws {
        let authored = AppTheme.Material(
            popoverStyle: AppTheme.Material.PopoverStyle(
                arrow: .none,
                surfaceRole: .panel,
                edge: .material,
                shadow: .none,
                density: .compact,
                glyphStyle: .classic,
                cornerRadius: 1
            )
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                AppTheme.Material.self,
                from: JSONEncoder().encode(authored)
            ),
            authored
        )

        let sparse = try JSONDecoder().decode(
            AppTheme.Material.self,
            from: Data(#"{"popoverStyle":{"arrow":"none"}}"#.utf8)
        )
        XCTAssertEqual(sparse.popoverStyle.arrow, .none)
        XCTAssertEqual(sparse.popoverStyle.surfaceRole, .floatingSurface)
        XCTAssertEqual(sparse.popoverStyle.edge, .flat)
        XCTAssertEqual(sparse.popoverStyle.shadow, .automatic)
        XCTAssertEqual(sparse.popoverStyle.density, .regular)
        XCTAssertEqual(sparse.popoverStyle.glyphStyle, .system)
        XCTAssertNil(sparse.popoverStyle.cornerRadius)
    }

    func testPeriodAndConstructedMaterialsStateTheirPopoverLanguage() {
        XCTAssertEqual(AppThemeStyles.win98.material.popoverStyle, .init(
            arrow: .none,
            edge: .flat,
            shadow: .none,
            density: .compact,
            glyphStyle: .classic
        ))
        for theme in [
            AppThemeStyles.platinum,
            AppThemeStyles.beOS,
            AppThemeStyles.openStep,
            AppThemeStyles.irix,
            AppThemeStyles.amiga
        ] {
            XCTAssertEqual(theme.material.popoverStyle, AppThemeStyles.periodPopoverStyle)
        }
        XCTAssertEqual(AppThemeStyles.aqua.material.popoverStyle, AppThemeStyles.aquaHelpTagPopoverStyle)
        XCTAssertEqual(AppThemeStyles.aquaTiger.material.popoverStyle, AppThemeStyles.aquaHelpTagPopoverStyle)
        XCTAssertEqual(AppThemeStyles.aqua.resolved(.tooltipSurface).hexString, "#FFF8B0")
        XCTAssertEqual(AppThemeStyles.aquaTiger.resolved(.tooltipSurface).hexString, "#FFF7B2")
        for theme in [AppThemeStyles.neoBrutalism, AppThemeStyles.claymorphism] {
            XCTAssertEqual(theme.material.popoverStyle.arrow, .none)
            XCTAssertEqual(theme.material.popoverStyle.edge, .material)
            XCTAssertEqual(theme.material.popoverStyle.shadow, .material)
        }
    }

    func testControlBorderRoundTripsWithoutChangingOlderMaterials() throws {
        let authored = AppTheme.Material(borderWidth: 4, controlBorderWidth: 2)
        XCTAssertEqual(
            try JSONDecoder().decode(
                AppTheme.Material.self,
                from: JSONEncoder().encode(authored)
            ),
            authored
        )

        let legacy = try JSONDecoder().decode(
            AppTheme.Material.self,
            from: Data(#"{"borderWidth":3}"#.utf8)
        )
        XCTAssertNil(legacy.controlBorderWidth)
        XCTAssertEqual(legacy.resolvedControlBorderWidth, 3)
    }

    func testBackdropPatternRoundTripsWithoutChangingOlderMaterials() throws {
        let authored = AppTheme.Material(
            backdropPattern: AppTheme.Material.BackdropPattern(
                kind: .diagonalGrid,
                role: .accent,
                opacity: 0.03,
                spacing: 40,
                lineWidth: 1
            )
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                AppTheme.Material.self,
                from: JSONEncoder().encode(authored)
            ),
            authored
        )

        let legacy = try JSONDecoder().decode(
            AppTheme.Material.self,
            from: Data(#"{"borderWidth":2}"#.utf8)
        )
        XCTAssertNil(legacy.backdropPattern)

        let sparse = try JSONDecoder().decode(
            AppTheme.Material.self,
            from: Data(#"{"backdropPattern":{"kind":"grid"}}"#.utf8)
        )
        XCTAssertEqual(sparse.backdropPattern?.kind, .grid)
        XCTAssertEqual(sparse.backdropPattern?.role, .border)
        XCTAssertEqual(sparse.backdropPattern?.opacity, 0.08)
        XCTAssertEqual(sparse.backdropPattern?.spacing, 20)
        XCTAssertEqual(sparse.backdropPattern?.lineWidth, 1)
    }

    func testHeadingStyleRoundTripsAndSparseDocumentsInheritProse() throws {
        let authored = AppTheme.Material(
            headingStyle: AppTheme.Material.HeadingStyle(
                typeface: .serif,
                fontFamily: "Baskerville",
                fontWeight: .regular,
                italic: true
            )
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                AppTheme.Material.self,
                from: JSONEncoder().encode(authored)
            ),
            authored
        )

        let sparse = try JSONDecoder().decode(
            AppTheme.Material.self,
            from: Data(#"{"headingStyle":{"fontWeight":"bold"}}"#.utf8)
        )
        XCTAssertNil(sparse.headingStyle?.typeface)
        XCTAssertNil(sparse.headingStyle?.fontFamily)
        XCTAssertEqual(sparse.headingStyle?.fontWeight, .bold)
        XCTAssertEqual(sparse.headingStyle?.italic, false)

        let legacy = try JSONDecoder().decode(
            AppTheme.Material.self,
            from: Data(#"{"typeface":"serif"}"#.utf8)
        )
        XCTAssertNil(legacy.headingStyle)
    }

    func testButtonStyleRoundTripsAndSparseDocumentsKeepSystemDefaults() throws {
        let authored = AppTheme.Material(
            buttonStyle: AppTheme.Material.ButtonStyle(
                textTransform: .uppercase,
                titleRendering: .pixel5x6,
                fontWeight: .bold,
                typeface: .serif,
                fontFamily: "Baskerville",
                tracking: 0.75,
                primaryTreatment: .outlined,
                primaryRole: .syntaxType,
                secondaryRole: .elevated,
                secondaryHoverRole: .panel,
                secondaryShadow: .panel,
                primaryBorderRole: .label,
                hoverOffsetX: 4,
                hoverOffsetY: 4,
                pressedOffsetX: 2,
                pressedOffsetY: 2,
                collapseShadowOnHover: true
            )
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                AppTheme.Material.self,
                from: JSONEncoder().encode(authored)
            ),
            authored
        )

        let sparse = Data(#"{"buttonStyle":{"textTransform":"uppercase"}}"#.utf8)
        let decoded = try JSONDecoder().decode(AppTheme.Material.self, from: sparse)
        XCTAssertEqual(decoded.buttonStyle.textTransform, .uppercase)
        XCTAssertEqual(decoded.buttonStyle.titleRendering, .font)
        XCTAssertEqual(decoded.buttonStyle.fontWeight, .medium)
        XCTAssertNil(decoded.buttonStyle.typeface)
        XCTAssertNil(decoded.buttonStyle.fontFamily)
        XCTAssertEqual(decoded.buttonStyle.primaryTreatment, .filled)
        XCTAssertEqual(decoded.buttonStyle.primaryRole, .accent)
        XCTAssertEqual(decoded.buttonStyle.secondaryRole, .controlResting)
        XCTAssertEqual(decoded.buttonStyle.secondaryHoverRole, .controlHover)
        XCTAssertEqual(decoded.buttonStyle.secondaryShadow, .control)
        XCTAssertEqual(decoded.buttonStyle.tracking, 0)
        XCTAssertEqual(decoded.buttonStyle.hoverOffsetX, 0)
        XCTAssertFalse(decoded.buttonStyle.collapseShadowOnHover)

        let classic = AppTheme.Material(
            choiceHeight: 16,
            buttonStyle: .init(primaryTreatment: .raised),
            choiceStyle: .doubleArrowPopup
        )
        let classicRoundTrip = try JSONDecoder().decode(
            AppTheme.Material.self,
            from: JSONEncoder().encode(classic)
        )
        XCTAssertEqual(classicRoundTrip.buttonStyle.primaryTreatment, .raised)
        XCTAssertEqual(classicRoundTrip.choiceHeight, 16)
        XCTAssertEqual(classicRoundTrip.choiceStyle, .doubleArrowPopup)
    }

    func testDesignPromptsThemesAuthorTheirMeasuredActionLanguage() {
        let themes = [
            AppThemeStyles.bauhaus,
            AppThemeStyles.newsprint,
            AppThemeStyles.swissMinimalist,
            AppThemeStyles.artDeco,
            AppThemeStyles.neoBrutalism,
            AppThemeStyles.cyberpunk,
            AppThemeStyles.botanical,
            AppThemeStyles.vaporwave,
            AppThemeStyles.industrial
        ]
        for theme in themes {
            XCTAssertEqual(
                theme.material.buttonStyle.textTransform,
                .uppercase,
                "\(theme.name) lost the uppercase action convention measured on its reference"
            )
            XCTAssertNotNil(
                theme.material.headingStyle,
                "\(theme.name) lost the display typography measured on its reference"
            )
        }

        XCTAssertEqual(AppThemeStyles.artDeco.material.buttonStyle.primaryTreatment, .outlined)
        XCTAssertEqual(AppThemeStyles.cyberpunk.material.buttonStyle.primaryTreatment, .outlined)
        XCTAssertEqual(AppThemeStyles.vaporwave.material.buttonStyle.primaryTreatment, .outlined)
        XCTAssertEqual(AppThemeStyles.newsprint.material.buttonStyle.primaryRole, .label)
        XCTAssertEqual(AppThemeStyles.botanical.material.buttonStyle.primaryRole, .label)
        XCTAssertEqual(AppThemeStyles.vaporwave.material.buttonStyle.primaryRole, .syntaxType)
        XCTAssertEqual(AppThemeStyles.claymorphism.material.buttonStyle.secondaryRole, .elevated)
        XCTAssertEqual(AppThemeStyles.claymorphism.material.buttonStyle.secondaryHoverRole, .elevated)
        XCTAssertEqual(AppThemeStyles.claymorphism.material.buttonStyle.hoverOffsetY, -2)
        XCTAssertEqual(AppThemeStyles.neoBrutalism.material.buttonStyle.hoverOffsetX, 4)
        XCTAssertTrue(AppThemeStyles.neoBrutalism.material.buttonStyle.collapseShadowOnHover)
        XCTAssertEqual(AppThemeStyles.industrial.material.buttonStyle.pressedOffsetY, 2)
        XCTAssertEqual(AppThemeStyles.industrial.material.buttonStyle.secondaryShadow, .panel)
        XCTAssertEqual(AppThemeStyles.artDeco.material.buttonStyle.fontFamily, "Avenir Next")
        XCTAssertEqual(AppThemeStyles.newsprint.material.buttonStyle.fontFamily, "Baskerville")

        AppThemePalette.set(AppThemeStyles.artDeco)
        XCTAssertEqual(
            Design.Typography.button(style: AppThemeStyles.artDeco.material.buttonStyle).familyName,
            "Avenir Next"
        )
        XCTAssertNotEqual(
            Design.Typography.button(style: AppThemeStyles.artDeco.material.buttonStyle).familyName,
            Design.Typography.body().familyName,
            "Art Deco's display action face leaked into body copy"
        )

        XCTAssertEqual(AppThemeStyles.bauhaus.material.borderWidth, 4)
        XCTAssertEqual(AppThemeStyles.bauhaus.material.controlBorderWidth, 2)
        XCTAssertEqual(AppThemeStyles.bauhaus.material.resolvedControlBorderWidth, 2)
        XCTAssertNil(AppThemeStyles.neoBrutalism.material.controlBorderWidth)
        XCTAssertEqual(AppThemeStyles.neoBrutalism.material.resolvedControlBorderWidth, 4)

        XCTAssertEqual(AppThemeStyles.bauhaus.material.backdropPattern?.kind, .dots)
        XCTAssertEqual(AppThemeStyles.swissMinimalist.material.backdropPattern?.kind, .grid)
        XCTAssertEqual(AppThemeStyles.artDeco.material.backdropPattern?.kind, .diagonalGrid)
        XCTAssertEqual(AppThemeStyles.neoBrutalism.material.backdropPattern?.kind, .dots)
        XCTAssertEqual(AppThemeStyles.cyberpunk.material.backdropPattern?.kind, .grid)
        XCTAssertEqual(AppThemeStyles.vaporwave.material.backdropPattern?.kind, .perspectiveGrid)
        XCTAssertNil(AppThemeStyles.newsprint.material.backdropPattern)
        XCTAssertNil(AppThemeStyles.botanical.material.backdropPattern)
        XCTAssertNil(AppThemeStyles.industrial.material.backdropPattern)
        XCTAssertEqual(AppThemeStyles.artDeco.material.headingStyle?.fontWeight, .regular)
        XCTAssertEqual(AppThemeStyles.botanical.material.headingStyle?.typeface, .serif)
        XCTAssertEqual(AppThemeStyles.botanical.material.headingStyle?.fontWeight, .regular)
        XCTAssertEqual(AppThemeStyles.newsprint.material.headingStyle?.fontWeight, .bold)
    }

    /// Why the role is recorded on the **view** and not tagged onto the font.
    ///
    /// Two platform facts ruled out the cheaper design, and both were measured rather than
    /// assumed. If a future macOS changes either, this fails — which is the point: the plan
    /// would then have an option it does not have today, and should be told rather than left
    /// carrying a note that has quietly stopped being true.
    func testAFontCannotBeMadeToCarryItsOwnRole() throws {
        let key = NSFontDescriptor.AttributeName("threadingFontRole")
        let base = NSFont.systemFont(ofSize: 13, weight: .regular)
        let tagged = try XCTUnwrap(
            NSFont(descriptor: base.fontDescriptor.addingAttributes([key: "prose"]), size: 13)
        )
        XCTAssertNil(
            tagged.fontDescriptor.object(forKey: key),
            "NSFont now keeps unknown descriptor attributes — a font could carry its own role"
        )

        let descriptor = try XCTUnwrap(base.fontDescriptor.withDesign(.monospaced))
        let proseUnderMono = try XCTUnwrap(NSFont(descriptor: descriptor, size: 13))
        XCTAssertEqual(
            proseUnderMono.fontName,
            NSFont.monospacedSystemFont(ofSize: 13, weight: .regular).fontName,
            "prose under a mono theme is no longer identical to code — inference is now possible"
        )
    }

    /// A material document written before `typeface` existed decodes to the values the app
    /// used then — the synthesized decoder threw on the missing key instead, and the throw
    /// was swallowed upstream into discarding the user's whole authored material.
    func testPreTypefaceMaterialDocumentsDecodeWithDefaults() throws {
        let legacy = Data(#"{"panelRadius": 18, "controlRadius": 10, "borderWidth": 2}"#.utf8)
        let material = try JSONDecoder().decode(AppTheme.Material.self, from: legacy)
        XCTAssertEqual(material.panelRadius, 18)
        XCTAssertEqual(material.controlRadius, 10)
        XCTAssertEqual(material.borderWidth, 2)
        XCTAssertNil(material.controlBorderWidth)
        XCTAssertEqual(material.resolvedControlBorderWidth, 2)
        XCTAssertNil(material.backdropPattern)
        XCTAssertNil(material.headingStyle)
        XCTAssertEqual(material.typeface, .standard)
        XCTAssertEqual(material.scrollerPlacement, .trailing)
        XCTAssertEqual(material.scrollerTrackStyle, .solid)
        XCTAssertEqual(material.scrollerAppearance, .automatic)
        XCTAssertEqual(material.menuAppearance, .automatic)
        XCTAssertEqual(material.progressStyle, .continuous)
        XCTAssertEqual(material.chartStyle, .continuous)
        XCTAssertEqual(material.choiceStyle, .chip)
        XCTAssertEqual(material.checkboxStyle, .automatic)
        XCTAssertEqual(material.toggleStyle, .automatic)
        XCTAssertEqual(material.choiceHeight, 26)

        let sparse = Data(#"{}"#.utf8)
        XCTAssertEqual(
            try JSONDecoder().decode(AppTheme.Material.self, from: sparse),
            .system
        )

        let updated = AppTheme.Material(typeface: .serif)
        let round = try JSONDecoder().decode(
            AppTheme.Material.self,
            from: JSONEncoder().encode(updated)
        )
        XCTAssertEqual(round.typeface, .serif)
        XCTAssertEqual(round.scrollerPlacement, .trailing)
        XCTAssertEqual(round.scrollerTrackStyle, .solid)
        XCTAssertEqual(round.scrollerAppearance, .automatic)
        XCTAssertEqual(round.menuAppearance, .automatic)
        XCTAssertEqual(round.progressStyle, .continuous)
        XCTAssertEqual(round.chartStyle, .continuous)
        XCTAssertEqual(round.choiceStyle, .chip)
        XCTAssertEqual(round.checkboxStyle, .automatic)
        XCTAssertEqual(round.toggleStyle, .automatic)
    }

    func testScrollerMaterialRoundTrips() throws {
        let authored = AppTheme.Material(
            scrollerPlacement: .leading,
            scrollerTrackStyle: .stippled,
            scrollerAppearance: .openStep,
            menuAppearance: .openStep,
            progressStyle: .segmented,
            chartStyle: .spectrum,
            checkboxStyle: .beOSCross,
            toggleStyle: .onOffButton
        )
        let roundTrip = try JSONDecoder().decode(
            AppTheme.Material.self,
            from: JSONEncoder().encode(authored)
        )

        XCTAssertEqual(roundTrip.scrollerPlacement, .leading)
        XCTAssertEqual(roundTrip.scrollerTrackStyle, .stippled)
        XCTAssertEqual(roundTrip.scrollerAppearance, .openStep)
        XCTAssertEqual(roundTrip.menuAppearance, .openStep)
        XCTAssertEqual(roundTrip.progressStyle, .segmented)
        XCTAssertEqual(roundTrip.chartStyle, .spectrum)
        XCTAssertEqual(roundTrip.checkboxStyle, .beOSCross)
        XCTAssertEqual(roundTrip.toggleStyle, .onOffButton)
    }

    /// The paired terminal's cursor is the palette's own ink, never its accent.
    ///
    /// A block cursor sits *on* a character — over queued input it drew each theme's loudest
    /// hue as an alarm block on the first letter of text that is only a suggestion. The
    /// foreground-coloured block is the classic quiet answer: always legible, and the letter
    /// under it inverts. Identity stays in the ANSI ramp, the ground and the selection.
    func testEveryPairedTerminalCursorIsThePalettesOwnInk() {
        for theme in AppThemeStyles.all {
            for kind in theme.availableVariants {
                guard let palette = theme.variant(kind)?.terminalPalette else { continue }
                XCTAssertEqual(
                    palette.cursor.hexString,
                    palette.foreground.hexString,
                    "\(theme.name) (\(kind.rawValue)) draws its cursor in an accent, "
                        + "which screams over queued input"
                )
            }
        }
    }

    /// The gate that catches a variant carrying the *other* appearance's code colours — the
    /// live failure was a light variant with a dark syntax set, every keyword white-on-white.
    func testAThemeWhoseSyntaxVanishesAgainstItsGroundIsRefused() throws {
        let base = AppThemeStyles.swissMinimalist
        let light = try XCTUnwrap(base.variant(.light))
        var roles = light.roles
        roles[.syntaxKeyword] = try XCTUnwrap(
            NSColor(hex: base.resolved(.ground).hexString)
        )

        let broken = AppTheme(
            id: AppThemeID("broken-syntax"),
            name: "Broken Syntax",
            mode: .light,
            summary: nil,
            variants: [.light: AppTheme.Variant(
                roles: roles,
                terminalPalette: light.terminalPalette,
                material: light.material
            )]
        )

        XCTAssertThrowsError(try AppThemeEditing.validate(broken)) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("syntax_keyword"),
                "the refusal must name the role that vanished: \(error.localizedDescription)"
            )
        }
    }

    func testControlBorderOverrideMustStayInsideTheMaterialContract() throws {
        let base = AppThemeStyles.bauhaus
        let source = try XCTUnwrap(base.variant(.light))
        var material = source.material
        material.controlBorderWidth = 5
        let broken = AppTheme(
            id: AppThemeID("broken-control-border"),
            name: "Broken Control Border",
            mode: .light,
            summary: nil,
            variants: [.light: AppTheme.Variant(
                roles: source.roles,
                terminalPalette: source.terminalPalette,
                material: material
            )]
        )

        XCTAssertThrowsError(try AppThemeEditing.validate(broken)) { error in
            XCTAssertTrue(error.localizedDescription.contains("control_border_width"))
        }
    }

    func testBackdropPatternMustStayInsideTheMaterialContract() throws {
        let base = AppThemeStyles.bauhaus
        let source = try XCTUnwrap(base.variant(.light))
        var material = source.material
        material.backdropPattern = AppTheme.Material.BackdropPattern(
            kind: .dots,
            role: .label,
            opacity: 1.1,
            spacing: 20,
            lineWidth: 1
        )
        let broken = AppTheme(
            id: AppThemeID("broken-backdrop-pattern"),
            name: "Broken Backdrop Pattern",
            mode: .light,
            summary: nil,
            variants: [.light: AppTheme.Variant(
                roles: source.roles,
                terminalPalette: source.terminalPalette,
                material: material
            )]
        )

        XCTAssertThrowsError(try AppThemeEditing.validate(broken)) { error in
            XCTAssertTrue(error.localizedDescription.contains("backdrop_pattern.opacity"))
        }
    }

    func testSecondVariantIsOptionalUntilThemeBecomesAdaptive() throws {
        XCTAssertNoThrow(try AppThemeEditing.validate(AppThemeStyles.cyberpunk))

        let dark = try XCTUnwrap(AppThemeStyles.cyberpunk.variant(.dark))
        let invalid = AppTheme(
            id: AppThemeID("missing-light"),
            name: "Missing Light",
            mode: .system,
            summary: nil,
            variants: [.dark: dark]
        )
        XCTAssertThrowsError(try AppThemeEditing.validate(invalid)) { error in
            XCTAssertTrue(error.localizedDescription.contains("both light and dark"))
        }
    }

    /// The catalogue's one seasonal style is also its one *adaptive* style, so it is the only
    /// stock theme whose identity has to survive both appearances rather than pinning one.
    /// Every other style is named after a movement and a movement has a single look; a season
    /// is snow in daylight and fir after dark.
    func testTheSeasonalStyleAuthorsBothAppearances() throws {
        let theme = AppThemeStyles.christmas
        XCTAssertTrue(theme.isAdaptive)
        XCTAssertEqual(Set(theme.availableVariants), Set(AppTheme.VariantKind.allCases))
        XCTAssertNil(
            theme.mode.appearance,
            "an adaptive theme leaves NSApp.appearance unset so macOS still drives it"
        )

        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))

        XCTAssertNotEqual(
            theme.resolved(.ground, appearance: light).hexString,
            theme.resolved(.ground, appearance: dark).hexString,
            "both appearances resolve the same ground, so only one of them was authored"
        )
        XCTAssertNotEqual(
            theme.terminalPalette(for: light).background.hexString,
            theme.terminalPalette(for: dark).background.hexString,
            "a terminal following this theme would not move with macOS"
        )

        // The pairing is the style rather than the hue — red alone is Swiss Minimalist's accent
        // already. A control that rests fir and lifts holly is that pairing where it is seen.
        for (name, appearance) in [("light", light), ("dark", dark)] {
            XCTAssertNotEqual(
                theme.resolved(.controlResting, appearance: appearance).hexString,
                theme.resolved(.controlHover, appearance: appearance).hexString,
                "\(name) rests and hovers in the same colour"
            )
        }
    }

    func testDuplicatingAnAdaptiveThemePreservesBothVariants() throws {
        let source = try adaptiveFixture()
        let copy = try AppThemeEditing.duplicate(
            source,
            id: AppThemeID("adaptive-copy"),
            name: "Adaptive Copy"
        )

        XCTAssertEqual(copy.mode, .system)
        XCTAssertEqual(Set(copy.availableVariants), [.light, .dark])
        XCTAssertEqual(copy.variant(.light)?.roles, source.variant(.light)?.roles)
        XCTAssertEqual(copy.variant(.dark)?.roles, source.variant(.dark)?.roles)
        XCTAssertEqual(copy.variant(.light)?.terminalPalette.name, "Adaptive Copy")
        XCTAssertEqual(copy.variant(.dark)?.terminalPalette.name, "Adaptive Copy")
    }

    func testDuplicatingSystemMaterialisesEditableLightAndDarkVariants() throws {
        let copy = try AppThemeEditing.duplicate(
            .system,
            id: AppThemeID("system-copy"),
            name: "System Copy"
        )

        XCTAssertEqual(copy.mode, .system)
        XCTAssertEqual(Set(copy.availableVariants), [.light, .dark])
        for kind in AppTheme.VariantKind.allCases {
            let variant = try XCTUnwrap(copy.variant(kind))
            for role in AppThemeRole.authored {
                XCTAssertNotNil(variant.roles[role], "\(kind.rawValue).\(role.wireName)")
            }
        }
    }

    /// The unheld tokens as their call sites see them, pinned against the expressions System
    /// states. If one of these changes, the app's default appearance changed.
    ///
    /// The quiet text tiers are deliberately absent. `LabelLegibility` raises AppKit's own
    /// translucent System colours only when their rendered contrast misses the tier's floor;
    /// `LabelLegibilityTests` pins that measured contract over every stock theme and appearance.
    ///
    /// `panel` is pinned to the ink wash rather than to the `textBackgroundColor` expression it
    /// replaced: on the modern system grounds that colour *is* the ground, so a System panel was
    /// a border around nothing — see `AppThemeRole.systemColor`.
    func testUnheldDesignTokensAreUnchangedUnderTheSystemTheme() {
        AppThemePalette.set(.system)

        // Build the expected colours under the same appearance `resolvedHex` uses below.
        // Calling `withAlphaComponent` on a dynamic system colour resolves it immediately;
        // constructing these in the test process's ambient (usually light) appearance and then
        // comparing them under dark made the expected side light while the token side stayed
        // correctly dynamic.
        var expected: [(String, NSColor, NSColor)] = []
        let appearance = NSAppearance(named: .darkAqua) ?? NSAppearance.currentDrawing()
        appearance.performAsCurrentDrawingAppearance {
            // Written out longhand so a revert to the replace-alpha expression fails this pin.
            let halfStrengthSeparator = NSColor(name: nil) { _ in
                guard let separator = NSColor.separatorColor.usingColorSpace(.sRGB) else {
                    return .separatorColor
                }
                return separator.withAlphaComponent(separator.alphaComponent * 0.5)
            }

            expected = [
                ("panel", Design.Surface.panel, .labelColor.withAlphaComponent(0.05)),
                ("border", Design.Surface.border, .separatorColor),
                ("accent", Design.Surface.accent, .controlAccentColor),
                ("controlResting", Design.Surface.controlResting,
                 .unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.5)),
                ("controlHover", Design.Surface.controlHover,
                 .unemphasizedSelectedContentBackgroundColor),
                ("bubbleFill", Design.Chat.bubbleFill, .controlAccentColor.withAlphaComponent(0.22)),
                // Half the separator's *own* strength — resolve, then multiply. The expression
                // this replaced, `.separatorColor.withAlphaComponent(0.5)`, hit the design
                // system's documented trap: `withAlphaComponent` replaces alpha, and
                // `separatorColor` carries its own 10%, so the "quieter" rule drew at 50% — the
                // one bright line in a dark window.
                ("turnDivider", Design.Chat.turnDivider, halfStrengthSeparator),
                ("syntaxKeyword", Design.Syntax.keyword, .systemPurple),
                ("syntaxComment", Design.Syntax.comment, .tertiaryLabelColor),
                ("label", Design.Text.label, .labelColor)
            ]
        }

        for (name, token, original) in expected {
            XCTAssertEqual(
                token.resolvedHex, original.resolvedHex,
                "\(name) no longer matches the system colour it replaced"
            )
        }
    }

    // MARK: - Material

    /// The System theme's geometry is the geometry the app always had. These are the literals
    /// `Design.Radius` held before it read a theme.
    func testSystemGeometryIsUnchanged() {
        AppThemePalette.set(.system)

        XCTAssertEqual(Design.Radius.panel, 12)
        XCTAssertEqual(Design.Radius.control, 8)
        XCTAssertEqual(Design.Radius.border, 1)
        XCTAssertEqual(Design.Radius.controlBorder, 1)
        XCTAssertEqual(Design.Radius.pill(height: 26), 13, "a System pill is still fully rounded")
    }

    /// The point of the material layer: two themes that differ only in hue read as one app in
    /// two tints. A style has to change the *silhouette* as well.
    func testEveryStyleHasItsOwnSilhouette() {
        for theme in AppThemeStyles.all {
            XCTAssertNotEqual(
                theme.material, AppTheme.Material.system,
                "\(theme.name) has the same geometry as System, so it is only a tint"
            )
        }
    }

    func testAStyleSquaresItsPillsWhenItSquaresEverythingElse() {
        AppThemePalette.set(AppThemeStyles.swissMinimalist)
        XCTAssertEqual(Design.Radius.pill(height: 26), 0, "Swiss left its chips rounded")

        AppThemePalette.set(.system)
        XCTAssertEqual(Design.Radius.pill(height: 26), 13)
    }

    /// A glow is opt-in per theme; a style without one must not inherit a halo from the last.
    func testOnlyThemesThatAskForAGlowHaveOne() {
        XCTAssertNotNil(AppThemeStyles.cyberpunk.material.glow)
        XCTAssertNil(AppThemeStyles.swissMinimalist.material.glow)
        XCTAssertNil(AppTheme.system.material.glow)
    }

    /// A glow is a layer shadow, and a shadow spills past the panel that casts it — so any
    /// clipping host budgets `Design.Size.glowGutter` around glowing panels. The gutter is a
    /// stated constant rather than a derivation, because layout must not move when a theme
    /// does; this is what makes shipping a wider glow a loud decision instead of a silent
    /// clip. The blur's visible extent is about twice its radius, after travelling its offset.
    func testGlowGutterCoversEveryStockGlow() {
        for theme in AppThemeLibrary.stock {
            let glows = [("panel", theme.material.glow), ("control", theme.material.controlGlow)]
            for (kind, glow) in glows {
                guard let glow else { continue }
                var shadows: [(name: String, radius: CGFloat, x: CGFloat, y: CGFloat)] = [
                    ("shadow", glow.radius, glow.offsetX, glow.offsetY)
                ]
                if let highlight = glow.highlight {
                    shadows.append(
                        ("highlight", highlight.radius, highlight.offsetX, highlight.offsetY)
                    )
                }
                for shadow in shadows {
                    XCTAssertGreaterThanOrEqual(
                        Design.Size.glowGutter,
                        abs(shadow.x) + shadow.radius * 2,
                        "\(theme.name)'s horizontal \(kind) \(shadow.name) spills past its gutter"
                    )
                    XCTAssertGreaterThanOrEqual(
                        Design.Size.glowGutter,
                        abs(shadow.y) + shadow.radius * 2,
                        "\(theme.name)'s vertical \(kind) \(shadow.name) spills past its gutter"
                    )
                }
            }
        }
    }

    func testDirectedPanelShadowsFitTheMaterialContract() {
        let hard = AppThemeStyles.neoBrutalism.material.glow
        XCTAssertEqual(hard?.radius, 0)
        XCTAssertNotEqual(hard?.offsetX ?? 0, 0)
        XCTAssertNotEqual(hard?.offsetY ?? 0, 0)

        let halo = AppThemeStyles.vaporwave.material.glow
        XCTAssertGreaterThan(halo?.radius ?? 0, 0)
        XCTAssertEqual(halo?.offsetX, 0)
        XCTAssertEqual(halo?.offsetY, 0)
    }

    /// The accent has to be *stated* for the surfaces that carry a style's identity — the
    /// selected row, the chips, the focus. Derived-from-label greys are what made the first
    /// pass read as the same app in a different tint.
    func testStylesStateTheirOwnControlFills() {
        for theme in AppThemeStyles.all {
            XCTAssertNotNil(
                theme.roles[.controlResting],
                "\(theme.name) leaves its controls to the grey derivation"
            )
            XCTAssertNotNil(theme.roles[.accent], "\(theme.name) states no accent")
        }
    }

    // MARK: - Dynamic Resolution

    /// The measured fact the whole refactor rests on: a themed colour re-resolves when the
    /// *theme* changes, not only when the system appearance does. Without this, every one of
    /// the app's ~220 colour call sites would need a re-assignment path of its own.
    func testAThemedColourFollowsTheCurrentTheme() {
        let color = AppThemePalette.color(.accent)

        AppThemePalette.set(.system)
        let underSystem = color.resolvedHex

        AppThemePalette.set(AppThemeStyles.cyberpunk)
        let underCyberpunk = color.resolvedHex

        XCTAssertEqual(underCyberpunk, AppThemeStyles.cyberpunk.resolved(.accent).resolvedHex)
        XCTAssertNotEqual(underSystem, underCyberpunk, "the same colour object did not re-resolve")
    }

    // MARK: - Surfaces That Follow the Appearance

    /// The other half of the frozen-`CGColor` problem, and the one nothing swept: a **system
    /// light/dark switch**. A theme change runs `AppThemeRefresh`; an appearance change ran
    /// nothing, so dynamic text turned dark while the surface under it stayed dark too.
    ///
    /// It stayed invisible while the largest surface in the window was a system material AppKit
    /// repainted itself. The sidebar paints its own ground now, so the gap is real, and
    /// `ThemedSurfaceView` is the view that closes it.
    @MainActor
    func testAThemedSurfaceViewReResolvesWhenTheAppearanceChanges() throws {
        AppThemePalette.set(.system)

        let surface = ThemedSurfaceView()
        surface.frame = NSRect(x: 0, y: 0, width: 10, height: 10)
        surface.appearance = NSAppearance(named: .darkAqua)
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            surface.applySurface(fill: Design.Surface.background, radius: .fixed(0))
        }

        let dark = try XCTUnwrap(surface.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) })

        // The switch AppKit reports through `viewDidChangeEffectiveAppearance`.
        surface.appearance = NSAppearance(named: .aqua)

        let light = try XCTUnwrap(surface.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) })
        XCTAssertGreaterThan(
            (light.usingColorSpace(.sRGB)?.brightnessComponent ?? 0),
            (dark.usingColorSpace(.sRGB)?.brightnessComponent ?? 1),
            "the ground kept its dark fill after the appearance turned light"
        )
    }

    /// The freeze is taken in the view's own appearance, not the thread's ambient one.
    ///
    /// Setup code and notification handlers run with whatever drawing appearance AppKit last
    /// had in hand, and a surface applied there froze in it — a light window's settings cards
    /// arrived dark. The view's own answer is the only one that is right by construction.
    @MainActor
    func testASurfaceFreezesInTheViewsOwnAppearanceNotTheAmbientOne() throws {
        AppThemePalette.set(.system)

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        view.appearance = NSAppearance(named: .aqua)

        // The ambient drawing appearance says dark; the view says light. The view must win.
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            view.applySurface(fill: Design.Surface.background, radius: .fixed(0))
        }

        let frozen = try XCTUnwrap(view.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) })
        XCTAssertGreaterThan(
            frozen.usingColorSpace(.sRGB)?.brightnessComponent ?? 0, 0.5,
            "the surface froze in the ambient dark appearance instead of the view's own light one"
        )
    }

    /// A plain view is what the sidebar used before, and it is the failure this exists to
    /// prevent: the layer keeps whatever it was handed.
    @MainActor
    func testAPlainViewKeepsItsFillAcrossAnAppearanceChange() throws {
        AppThemePalette.set(.system)

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        view.appearance = NSAppearance(named: .darkAqua)
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            view.applySurface(fill: Design.Surface.background, radius: .fixed(0))
        }
        let before = try XCTUnwrap(view.layer?.backgroundColor)

        view.appearance = NSAppearance(named: .aqua)

        XCTAssertEqual(view.layer?.backgroundColor, before)
    }

    // MARK: - The Sidebar's Ground

    /// The identity theme's sidebar is the platform's material; a style's is its own opaque
    /// surface. Which one is showing is the component's decision, re-taken on every theme
    /// change without the host saying anything — the wiring a call site cannot forget.
    @MainActor
    func testTheSidebarBackdropShowsTheMaterialOnlyUnderTheIdentityTheme() throws {
        AppThemePalette.set(.system)

        let backdrop = SidebarBackdropView()
        let material = try XCTUnwrap(
            backdrop.subviews.first { $0 is NSVisualEffectView },
            "the backdrop no longer contains the system material"
        )
        let fill = try XCTUnwrap(backdrop.subviews.first { $0 is ThemedSurfaceView })

        XCTAssertFalse(material.isHidden, "System lost the platform's own sidebar")
        XCTAssertTrue(fill.isHidden)

        AppThemePalette.set(AppThemeStyles.cyberpunk)
        NotificationCenter.default.post(AppThemeDidChange(themeID: AppThemeStyles.cyberpunk.id))

        XCTAssertTrue(material.isHidden, "a style must state its surface, not frost the desktop")
        XCTAssertFalse(fill.isHidden)
    }

    /// The contained effect view is legitimate; one beside the component is still a violation.
    @MainActor
    func testTheSidebarBackdropPermitsOnlyItsOwnMaterial() {
        AppThemePalette.set(.system)

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        host.addSubview(SidebarBackdropView())
        XCTAssertEqual(ThemeBoundaryAudit.violations(in: host), [])

        host.addSubview(NSVisualEffectView())
        XCTAssertEqual(
            ThemeBoundaryAudit.violations(in: host).map(\.className),
            ["NSVisualEffectView"],
            "the boundary leaked past the component's own material"
        )
    }

    // MARK: - The System Terminal Pair

    /// The identity theme pairs a palette per appearance the way its roles resolve per
    /// appearance. The old single answer was pure black under both: beside a light chrome it
    /// painted the whole backdrop black, and beside the dark chrome's `#1E1E1E` it was a hole.
    ///
    /// Resolved through `terminalPalette(for:)`, the explicit-appearance entry point: the
    /// parameterless var deliberately anchors to `NSApp.effectiveAppearance`, because palettes
    /// are consumed as data from contexts where the ambient drawing appearance is stale.
    func testTheSystemThemePairsATerminalPalettePerAppearance() throws {
        let lightPalette = try AppTheme.system.terminalPalette(
            for: XCTUnwrap(NSAppearance(named: .aqua))
        )
        let darkPalette = try AppTheme.system.terminalPalette(
            for: XCTUnwrap(NSAppearance(named: .darkAqua))
        )

        // Both are named after the theme, the way every app theme's palette is.
        XCTAssertEqual(lightPalette.name, "System")
        XCTAssertEqual(darkPalette.name, "System")

        XCTAssertEqual(lightPalette.background.resolvedHex, NSColor.white.resolvedHex)
        XCTAssertEqual(darkPalette.background.resolvedHex, NSColor(hex: "#1E1E1E")?.resolvedHex)
        XCTAssertTrue(
            ThemeContrast.isLegible(
                foreground: lightPalette.foreground,
                background: lightPalette.background
            )
        )
        XCTAssertTrue(
            ThemeContrast.isLegible(
                foreground: darkPalette.foreground,
                background: darkPalette.background
            )
        )
    }

    // MARK: - The Divider's Ownership

    /// `ThemedSplitView.visibleLineRatio`, restated: the view keeps its floor private, and a test
    /// that asserted against a softer number would pass a seam the app calls invisible.
    private static let visibleLineRatio: CGFloat = 1.2

    /// The theme's own line wherever it reads on the backdrop; the measured neutral only where
    /// it cannot. A neutral over the chrome drew a pale grey seam across themes whose every
    /// other rule is their own hue — and a themed line over a backdrop it vanishes against is
    /// the invisible seam this view originally existed to restore.
    ///
    /// The theme's line is its *rule* ink — `Design.Surface.divider`, where the ink budget is
    /// enforced — not its border: drawn in `Surface.border` the seam was the one full-strength
    /// rule left in the window, stepping in ink at the same crossing it once stepped in weight.
    @MainActor
    func testTheSplitDividerTakesTheThemeRuleInkWhereverItReadsOnTheBackdrop() throws {
        let original = WindowBackdrop.ground
        defer { WindowBackdrop.set(original) }

        let split = ThemedSplitView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))

        // Cyberpunk's rule reads on its own ground, so the seam keeps the theme's line.
        AppThemePalette.set(AppThemeStyles.cyberpunk)
        WindowBackdrop.set(.chrome)
        XCTAssertEqual(
            split.dividerColor.resolvedHex,
            Design.Surface.divider.resolvedHex,
            "the chrome's seam ignored the theme's own rule ink"
        )

        // Cyberpunk's rule still reads on a black terminal, so the seam stays the theme's.
        WindowBackdrop.set(.terminal(.black))
        XCTAssertEqual(
            split.dividerColor.resolvedHex,
            Design.Surface.divider.resolvedHex,
            "a rule that reads on the backdrop should be the seam"
        )

        // Swiss rules and borders near-black alike; over a black terminal neither survives, so
        // the seam falls back to ink cut from the tone that ground reads against.
        AppThemePalette.set(AppThemeStyles.swissMinimalist)
        let measured = try XCTUnwrap(split.dividerColor.usingColorSpace(.sRGB))
        let tone = try XCTUnwrap(WindowBackdrop.ink.base.usingColorSpace(.sRGB))
        XCTAssertEqual(
            [measured.redComponent, measured.greenComponent, measured.blueComponent],
            [tone.redComponent, tone.greenComponent, tone.blueComponent],
            "a rule the backdrop swallows must fall back to the measured neutral"
        )
    }

    /// The measured neutral is the **least** of that tone that still reads, not the strongest.
    ///
    /// `WindowBackdrop.ink.rule` is the derived border under a second name — 30% of the tone the
    /// ground reads against — so reaching for it whole drew a seam three times the ink of the
    /// theme's own border and six times its rule. Clearing the visibility floor is what the
    /// fallback exists for; clearing it by a factor of three is a different bug in the fix's
    /// clothes. Asserted from both sides, because "the least that reads" is two claims: this ink
    /// reads, and a step under it does not.
    func testTheMeasuredSeamCarriesTheLeastInkThatStillReads() throws {
        let original = WindowBackdrop.ground
        defer { WindowBackdrop.set(original) }

        // System's own rule *and* border are swallowed by black — 1.07:1 and 1.19:1, the second
        // only just — which is what leaves the measurement to answer.
        AppThemePalette.set(.system)
        WindowBackdrop.set(.terminal(.black))

        let split = ThemedSplitView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let backdrop = WindowBackdrop.color
        let seam = try XCTUnwrap(split.dividerColor.usingColorSpace(.sRGB))
        let strongest = try XCTUnwrap(WindowBackdrop.ink.rule.usingColorSpace(.sRGB))

        func reads(_ ink: NSColor) -> CGFloat {
            ThemeContrast.ratio(backdrop.composited(under: ink), backdrop)
        }

        XCTAssertGreaterThanOrEqual(
            reads(seam),
            Self.visibleLineRatio,
            "the measured seam cannot be seen on the ground it was measured against"
        )
        XCTAssertLessThan(
            reads(seam.withAlphaComponent(seam.alphaComponent - 0.02)),
            Self.visibleLineRatio,
            "the seam carried more ink than it takes to read"
        )
        XCTAssertLessThan(
            seam.alphaComponent,
            strongest.alphaComponent / 2,
            "the seam took the derived border's ink where a rule's own weight would have read"
        )
    }

    /// The same colour under the seam draws the same seam, whoever painted it.
    ///
    /// The step past a swallowed rule used to ask who owned the ground: the theme's border on the
    /// chrome, a measured neutral over a terminal palette. Under System dark those are the same
    /// `#1E1E1E` — the theme's ground *is* that palette's background — so selecting a session
    /// lifted the seam from 9.8% ink to 30% over pixels that had not changed, and the window drew
    /// a line six times the weight of the sidebar's own rules right where the two crossed.
    /// Reported off a screenshot: (98, 98, 98) beside a footer rule at (51, 51, 53).
    func testTheSeamDoesNotChangeWeightWhenATerminalPaintsTheThemesOwnGround() throws {
        let original = WindowBackdrop.ground
        defer { WindowBackdrop.set(original) }

        AppThemePalette.set(.system)
        let split = ThemedSplitView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let appearance = try XCTUnwrap(NSAppearance(named: .darkAqua))

        var onChrome = ""
        var onItsOwnColour = ""
        var ground = NSColor.clear
        appearance.performAsCurrentDrawingAppearance {
            WindowBackdrop.set(.chrome)
            ground = WindowBackdrop.color.usingColorSpace(.sRGB) ?? .clear
            onChrome = (split.dividerColor.usingColorSpace(.sRGB) ?? .clear).hexString

            // The very same colour, now painted by a session rather than by the chrome.
            WindowBackdrop.set(.terminal(ground))
            onItsOwnColour = (split.dividerColor.usingColorSpace(.sRGB) ?? .clear).hexString
        }

        XCTAssertEqual(ground.hexString, "#1E1E1E", "System dark restated its ground")
        XCTAssertEqual(
            onItsOwnColour,
            onChrome,
            "the seam changed ink over a ground that had not changed colour"
        )
    }

    /// System light's separator is deliberately quieter than a border, but at that opacity it
    /// disappears as the only seam between the sidebar material and the pale content pane. The
    /// split view's visibility floor applies to the chrome ground too: ownership cannot make an
    /// otherwise invisible colour register.
    func testSystemLightSplitDividerFallsBackToVisibleBorderOnTheChromeGround() throws {
        let original = WindowBackdrop.ground
        defer { WindowBackdrop.set(original) }

        AppThemePalette.set(.system)
        WindowBackdrop.set(.chrome)

        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let split = ThemedSplitView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        var actual = ""
        var fallback = ""
        var authored = ""
        appearance.performAsCurrentDrawingAppearance {
            actual = (split.dividerColor.usingColorSpace(.sRGB) ?? .clear).hexString
            fallback = (Design.Surface.border.usingColorSpace(.sRGB) ?? .clear).hexString
            authored = (Design.Surface.divider.usingColorSpace(.sRGB) ?? .clear).hexString
        }

        XCTAssertEqual(actual, fallback, "System light left its sidebar seam below visibility")
        XCTAssertNotEqual(actual, authored, "the fixture's authored rule was not faint enough")
    }

    // MARK: - The Divider's Weight

    /// Two panes, sized so a seam between them can be read out of the pixels.
    private func splitFixture() -> ThemedSplitView {
        let split = ThemedSplitView(frame: NSRect(x: 0, y: 0, width: 60, height: 10))
        split.addArrangedSubview(PaintedPane())
        split.addArrangedSubview(PaintedPane())
        split.adjustSubviews()
        return split
    }

    /// The gap the split view actually left between its panes, which is what a divider's
    /// thickness *does* — the property is only the claim.
    private func seamWidth(in split: ThemedSplitView) throws -> CGFloat {
        let panes = split.arrangedSubviews
        XCTAssertEqual(panes.count, 2, "the fixture lost a pane")
        return try XCTUnwrap(panes.last).frame.minX - (try XCTUnwrap(panes.first)).frame.maxX
    }

    /// The same theme with a different rule weight, for widths no stock style states.
    private func themeRuling(width: CGFloat, on theme: AppTheme) -> AppTheme {
        var variants: [AppTheme.VariantKind: AppTheme.Variant] = [:]
        for (kind, variant) in theme.variants {
            var material = variant.material
            material.borderWidth = width
            variants[kind] = AppTheme.Variant(
                roles: variant.roles,
                terminalPalette: variant.terminalPalette,
                material: material
            )
        }
        return AppTheme(
            id: AppThemeID("\(theme.id.rawValue)-ruled"),
            name: theme.name,
            mode: theme.mode,
            summary: theme.summary,
            variants: variants
        )
    }

    /// A seam between two panes is a rule, and a rule's weight belongs to the theme.
    ///
    /// `dividerStyle = .thin` is a fixed point, while every other rule in the window — the pane
    /// headers' and footers' `SeparatorView`s, the shell drawer's grab strip — is
    /// `Design.Radius.border` thick. On Bauhaus and Neo Brutalism (both 4) the window therefore
    /// drew heavy horizontal rules and a hairline vertical seam between the very same panes:
    /// the sidebar's header rule stepped down exactly where it crossed the split.
    func testTheSplitSeamWeighsWhatTheThemesOtherRulesWeigh() {
        let split = ThemedSplitView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))

        for theme in [AppTheme.system, AppThemeStyles.bauhaus, AppThemeStyles.neoBrutalism] {
            AppThemePalette.set(theme)
            XCTAssertEqual(
                split.dividerThickness,
                SeparatorView(.vertical).intrinsicContentSize.width,
                "\(theme.name) ruled between its panes and inside them at two different weights"
            )
        }
    }

    /// The seam is the drag handle as well as the rule, and a theme may state any width at all —
    /// the ones an agent writes through `create_app_theme` are not held to the stock range. Below
    /// a point the line would still be visible and the target would not be.
    func testTheSeamStaysGrabbableUnderAThemeThatRulesFinerThanAPoint() {
        AppThemePalette.set(themeRuling(width: 0.25, on: AppThemeStyles.bauhaus))

        let split = ThemedSplitView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(split.dividerThickness, 1, "a fine rule left nothing to grab")
    }

    /// Read off the drawn pixels rather than the property, because a divider AppKit *places* at
    /// one width and *paints* at another is the same mismatch by another route.
    func testTheSeamIsPaintedAcrossItsWholeWidth() throws {
        let original = WindowBackdrop.ground
        defer { WindowBackdrop.set(original) }
        WindowBackdrop.set(.chrome)
        AppThemePalette.set(AppThemeStyles.neoBrutalism)

        let split = splitFixture()
        let rep = try XCTUnwrap(split.bitmapImageRepForCachingDisplay(in: split.bounds))
        split.cacheDisplay(in: split.bounds, to: rep)

        let scale = CGFloat(rep.pixelsWide) / split.bounds.width
        let row = rep.pixelsHigh / 2
        var inked = 0
        for x in 0..<rep.pixelsWide {
            let pixel = try XCTUnwrap(rep.colorAt(x: x, y: row)?.usingColorSpace(.sRGB))
            if pixel.brightnessComponent < 0.5 { inked += 1 }
        }

        XCTAssertEqual(
            CGFloat(inked) / scale,
            split.dividerThickness,
            accuracy: 0.5,
            "the seam was drawn narrower than the space the panes left for it"
        )
    }

    // MARK: - The Divider Under the Pointer

    /// The same two panes inside an unshown window, which is what hover needs that the bare
    /// fixture lacks: a fabricated crossing carries window coordinates, and the attach zone is
    /// asked of `hitTest` through a superview.
    private func hoverableSplitFixture() -> (window: NSWindow, split: ThemedSplitView) {
        let split = ThemedSplitView(frame: NSRect(x: 0, y: 0, width: 200, height: 60))
        split.addArrangedSubview(PaintedPane())
        split.addArrangedSubview(PaintedPane())
        split.adjustSubviews()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = split
        split.layoutSubtreeIfNeeded()
        return (window, split)
    }

    /// Delivers the crossing a tracking area would: the view re-derives the hovered divider
    /// from the event's own location, so the fabricated event needs no tracking number.
    private func pointer(
        crosses type: NSEvent.EventType,
        at point: NSPoint,
        over split: ThemedSplitView,
        in window: NSWindow
    ) throws {
        let event = try XCTUnwrap(
            NSEvent.enterExitEvent(
                with: type,
                location: split.convert(point, to: nil),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                trackingNumber: 0,
                userData: nil
            )
        )
        switch type {
        case .mouseEntered: split.mouseEntered(with: event)
        case .mouseExited: split.mouseExited(with: event)
        default: split.mouseMoved(with: event)
        }
    }

    /// The colour actually standing in the middle of the seam, off the drawn pixels.
    private func seamPixel(of split: ThemedSplitView) throws -> NSColor {
        let rep = try XCTUnwrap(split.bitmapImageRepForCachingDisplay(in: split.bounds))
        split.cacheDisplay(in: split.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / split.bounds.width
        let seam = try XCTUnwrap(split.arrangedSubviews.first).frame.maxX
        let x = Int((seam + split.dividerThickness / 2) * scale)
        return try XCTUnwrap(rep.colorAt(x: x, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB))
    }

    /// Whether a drawn pixel is the given token's ink, compared by hue, saturation and
    /// brightness rather than by channel: the cached bitmap comes back in the window's colour
    /// space — measured, a pure sRGB red reads back as (0.94, 0.29, 0.18) — so a channel-exact
    /// comparison asserts the conversion rather than the ink. Hue survives the shift; the wide
    /// saturation and brightness bands are what separate a vivid accent from the fixture's
    /// white panes and the theme's near-black rule.
    private func pixel(_ pixel: NSColor, draws expected: NSColor, under view: NSView) -> Bool {
        var matches = false
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            guard let drawn = pixel.usingColorSpace(.sRGB),
                  let ink = expected.usingColorSpace(.sRGB) else { return }
            let spin = abs(drawn.hueComponent - ink.hueComponent)
            matches = min(spin, 1 - spin) < 0.06
                && abs(drawn.saturationComponent - ink.saturationComponent) < 0.25
                && abs(drawn.brightnessComponent - ink.brightnessComponent) < 0.25
        }
        return matches
    }

    /// The seam lights with the accent exactly where a drag would attach, and nowhere else.
    ///
    /// "Where a drag would attach" is the platform's own claim — `NSSplitView.hitTest` takes the
    /// points around a divider from its panes, and that claim is what turns a press into a drag
    /// and flips the resize cursor. The sweep asserts agreement point by point rather than a
    /// restated zone, so the hint and the cursor cannot drift apart; the two counters keep the
    /// sweep honest about having crossed both sides of the boundary.
    func testTheSeamLightsWithTheAccentExactlyWhereADragWouldAttach() throws {
        let original = WindowBackdrop.ground
        defer { WindowBackdrop.set(original) }
        WindowBackdrop.set(.chrome)
        AppThemePalette.set(AppThemeStyles.neoBrutalism)

        let (window, split) = hoverableSplitFixture()
        let seam = try XCTUnwrap(split.arrangedSubviews.first).frame.maxX
        let superview = try XCTUnwrap(split.superview)

        var attachable = 0
        var handedToAPane = 0
        for dx in stride(from: CGFloat(-8), through: 8, by: 1) {
            let point = NSPoint(x: seam + dx, y: split.bounds.midY)
            let attaches = split.hitTest(split.convert(point, to: superview)) === split
            try pointer(crosses: .mouseEntered, at: point, over: split, in: window)

            let drawn = pixel(try seamPixel(of: split), draws: Design.Surface.accent, under: split)
            XCTAssertEqual(
                drawn,
                attaches,
                attaches
                    ? "a point the platform grabs from (seam \(dx)) left the seam unlit"
                    : "a point the platform hands to a pane (seam \(dx)) lit the seam"
            )
            if attaches { attachable += 1 } else { handedToAPane += 1 }
        }

        XCTAssertGreaterThan(attachable, 0, "the sweep never crossed the attach zone")
        XCTAssertGreaterThan(handedToAPane, 0, "the sweep never left the attach zone")
    }

    /// Leaving puts the rule ink back: the accent means "ready to act", and a pointer elsewhere
    /// is not that.
    func testLeavingTheSeamPutsTheRuleInkBack() throws {
        let original = WindowBackdrop.ground
        defer { WindowBackdrop.set(original) }
        WindowBackdrop.set(.chrome)
        AppThemePalette.set(AppThemeStyles.neoBrutalism)

        let (window, split) = hoverableSplitFixture()
        let seam = try XCTUnwrap(split.arrangedSubviews.first).frame.maxX
        let onTheSeam = NSPoint(x: seam, y: split.bounds.midY)

        try pointer(crosses: .mouseEntered, at: onTheSeam, over: split, in: window)
        XCTAssertTrue(
            pixel(try seamPixel(of: split), draws: Design.Surface.accent, under: split),
            "the pointer arrived on the seam and nothing lit"
        )

        try pointer(
            crosses: .mouseExited,
            at: NSPoint(x: 30, y: split.bounds.midY),
            over: split,
            in: window
        )
        XCTAssertFalse(
            pixel(try seamPixel(of: split), draws: Design.Surface.accent, under: split),
            "the pointer left and the seam stayed lit"
        )
    }

    /// A drag moves the seam without moving the split view's own frame, which is the one
    /// geometry change AppKit does not re-ask tracking areas for on its own — measured, a
    /// `setPosition` move calls neither `updateTrackingAreas()` nor (without a run-loop turn)
    /// `layout()`, and only `didResizeSubviewsNotification` arrives with the frames already
    /// moved. The hover strip has to follow the seam, or the hint would keep pointing at where
    /// the divider used to be.
    func testTheHoverStripFollowsTheSeamAfterADividerMove() throws {
        let (_, split) = hoverableSplitFixture()
        let oldSeam = try XCTUnwrap(split.arrangedSubviews.first).frame.maxX

        split.setPosition(40, ofDividerAt: 0)
        split.layoutSubtreeIfNeeded()
        let newSeam = try XCTUnwrap(split.arrangedSubviews.first).frame.maxX
        XCTAssertNotEqual(oldSeam, newSeam, "the fixture's divider did not move")

        let mid = split.bounds.midY
        XCTAssertTrue(
            split.trackingAreas.contains { $0.rect.contains(NSPoint(x: newSeam + 1, y: mid)) },
            "no hover strip follows the seam to where it moved"
        )
        XCTAssertFalse(
            split.trackingAreas.contains { $0.rect.contains(NSPoint(x: oldSeam + 1, y: mid)) },
            "a hover strip stayed at the seam's old position"
        )
    }

    /// A pane that is not on screen has no seam to grab — `SidebarSplitViewController` hides the
    /// divider beside a collapsed pane — so nothing near where it stood may light. Driven at the
    /// view level with a hidden pane, which is how a split view expresses a collapsed neighbour.
    func testASeamBesideAHiddenPaneDoesNotLight() throws {
        let original = WindowBackdrop.ground
        defer { WindowBackdrop.set(original) }
        WindowBackdrop.set(.chrome)
        AppThemePalette.set(AppThemeStyles.neoBrutalism)

        let (window, split) = hoverableSplitFixture()
        try XCTUnwrap(split.arrangedSubviews.first).isHidden = true
        split.adjustSubviews()
        split.layoutSubtreeIfNeeded()

        for x in stride(from: CGFloat(0), through: 8, by: 1) {
            try pointer(
                crosses: .mouseEntered,
                at: NSPoint(x: x, y: split.bounds.midY),
                over: split,
                in: window
            )
        }

        let rep = try XCTUnwrap(split.bitmapImageRepForCachingDisplay(in: split.bounds))
        split.cacheDisplay(in: split.bounds, to: rep)
        let row = rep.pixelsHigh / 2
        for x in 0..<rep.pixelsWide {
            let drawn = try XCTUnwrap(rep.colorAt(x: x, y: row)?.usingColorSpace(.sRGB))
            XCTAssertFalse(
                pixel(drawn, draws: Design.Surface.accent, under: split),
                "a hidden pane's seam lit up at x = \(x)"
            )
        }
    }

    // MARK: - The Divider That Arrives

    /// A pane revealed from collapsed arrives at a strip nobody has painted.
    ///
    /// AppKit resizes the panes and posts `didResizeSubviewsNotification` through the whole
    /// transition without calling `drawDivider(in:)` once, so the seam beside the display panel
    /// kept whatever stood there while it was still inside the session pane — that pane's own
    /// ground. On the start page under a project, where the panel and the pane beside it are the
    /// same colour, the panel opened with no visible edge at all; the first hover fixed it,
    /// because pointing at a seam invalidates it by hand.
    ///
    /// Asserted against the *panel's* leading edge rather than against the seam list the view
    /// keeps, so this pins the strip that has to be repainted rather than restating how it is
    /// computed. Read off `repaintedSeams` rather than the pixels: `cacheDisplay` redraws
    /// everything unconditionally, which is exactly the redraw this bug never got.
    func testRevealingTheDisplayPanelRepaintsTheSeamItArrivesAt() throws {
        let controller = makeMainWindowController()
        controller.window?.setContentSize(NSSize(width: 1200, height: 700))
        let split = try XCTUnwrap(controller.splitViewController.splitView as? ThemedSplitView)
        split.layoutSubtreeIfNeeded()

        let before = split.repaintedSeams
        controller.setDisplayPaneVisible(true, animated: false)
        split.layoutSubtreeIfNeeded()

        let panel = try XCTUnwrap(split.arrangedSubviews.last)
        XCTAssertFalse(panel.frame.isEmpty, "the panel did not come out of its collapse")
        XCTAssertNotEqual(
            before,
            split.repaintedSeams,
            "the panel arrived and the view asked for no seam to be repainted"
        )
        XCTAssertTrue(
            split.repaintedSeams.contains {
                abs($0.minX - (panel.frame.minX - split.dividerThickness)) < 0.5
                    && $0.height == split.bounds.height
            },
            "the strip the panel's own edge arrived at was never asked to repaint"
        )
    }

    /// The fixture proves the view; this proves the window. Its panes are placed by
    /// `NSSplitViewController` through constraints, which is a different path from a fixture's
    /// arranged subviews and the only one the user ever looks at.
    func testTheWindowsOwnPanesAreSpacedByTheThemesRuleWeight() throws {
        AppThemePalette.set(AppThemeStyles.bauhaus)

        let controller = makeMainWindowController()
        controller.window?.setContentSize(NSSize(width: 1200, height: 700))
        let split = controller.splitViewController.splitView
        split.layoutSubtreeIfNeeded()

        XCTAssertEqual(split.dividerThickness, 4, "Bauhaus rules at 4; the window's seam did not")

        // A collapsed pane has no seam beside it. It keeps the width it had before collapsing
        // and loses its height, so "on screen" means an area rather than a width.
        let panes = split.arrangedSubviews
            .filter { !$0.frame.isEmpty }
            .sorted { $0.frame.minX < $1.frame.minX }
        XCTAssertGreaterThanOrEqual(panes.count, 2, "the window had no seam to measure")
        for (left, right) in zip(panes, panes.dropFirst()) {
            XCTAssertEqual(
                right.frame.minX - left.frame.maxX,
                split.dividerThickness,
                accuracy: 0.01,
                "the window's panes were spaced by AppKit's hairline rather than the theme's rule"
            )
        }
    }

    /// A theme change moves the seam's weight, not only its ink, and the panes are placed against
    /// that weight. Repainting alone left them spaced for the outgoing theme until something else
    /// — a window resize — happened to re-lay the split out.
    func testTheSeamIsRelaidOutWhenTheThemeChangesUnderIt() throws {
        AppThemePalette.set(.system)
        let split = splitFixture()
        split.layoutSubtreeIfNeeded()
        XCTAssertEqual(try seamWidth(in: split), 1, "the fixture did not start at a hairline")

        AppThemePalette.set(AppThemeStyles.neoBrutalism)
        NotificationCenter.default.post(AppThemeDidChange(themeID: AppThemeStyles.neoBrutalism.id))
        split.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            try seamWidth(in: split),
            4,
            "the panes stayed spaced for the theme that just left"
        )
    }

    // MARK: - Repainting What Is Already On Screen

    /// The half that dynamic colours cannot fix. A `CALayer` resolves `backgroundColor` to a
    /// `CGColor` once and keeps it, so a view filled before the theme changed would hold its old
    /// colour forever — the same freeze that left the terminal's pane stale. `applySurface`
    /// records what it was given so the sweep can resolve it again.
    func testARecordedSurfaceIsResolvedAgainWhenTheThemeChanges() {
        AppThemePalette.set(.system)

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        view.applySurface(fill: Design.Surface.panel, radius: .fixed(4), border: Design.Surface.border)

        let before = view.layer?.backgroundColor
        XCTAssertNotNil(before)

        AppThemePalette.set(AppThemeStyles.cyberpunk)

        // Nothing has repainted yet: this is the stale state the sweep exists to fix.
        XCTAssertEqual(view.layer?.backgroundColor, before, "the layer resolved itself, unexpectedly")

        view.reapplyRecordedSurfaceForTesting()

        let after = try? XCTUnwrap(view.layer?.backgroundColor)
        XCTAssertNotEqual(after, before, "the recorded surface was not resolved again")
        XCTAssertEqual(
            after.flatMap { NSColor(cgColor: $0)?.hexString },
            AppThemeStyles.cyberpunk.resolved(.panel).hexString
        )
    }

    /// Semantic radius identity cannot be recovered from its current number. Swiss deliberately
    /// gives panels, controls, and pills the same zero radius; a numeric recorder therefore
    /// classified every one as the first matching role and replayed the wrong shape when the
    /// next theme separated them again.
    func testRecordedSurfaceRadiusKeepsItsRoleAcrossEqualRadiusThemes() {
        AppThemePalette.set(AppThemeStyles.swissMinimalist)

        let panel = NSView()
        panel.applySurface(fill: Design.Surface.panel, radius: .panel)

        let control = NSView()
        control.applySurface(fill: Design.Surface.panel, radius: .control)

        let pill = NSView()
        pill.applySurface(fill: Design.Surface.panel, radius: .pill(height: 26))

        let fixed = NSView()
        fixed.applySurface(fill: Design.Surface.panel, radius: .fixed(5))

        XCTAssertEqual(panel.layer?.cornerRadius, 0)
        XCTAssertEqual(control.layer?.cornerRadius, 0)
        XCTAssertEqual(pill.layer?.cornerRadius, 0)
        XCTAssertEqual(fixed.layer?.cornerRadius, 5)

        AppThemePalette.set(.system)
        for view in [panel, control, pill, fixed] {
            view.reapplyRecordedSurfaceForTesting()
        }

        XCTAssertEqual(panel.layer?.cornerRadius, 12)
        XCTAssertEqual(control.layer?.cornerRadius, 8)
        XCTAssertEqual(pill.layer?.cornerRadius, 13)
        XCTAssertEqual(fixed.layer?.cornerRadius, 5)
    }

    /// State-specific fills use the lighter layer helper rather than replacing the surface
    /// record. It must retain the dynamic NSColor for the same reason `applySurface` does.
    func testARecordedLayerColourIsResolvedAgainWhenTheThemeChanges() {
        AppThemePalette.set(.system)

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        view.applyLayerBackground(Design.Surface.controlResting)
        let before = view.layer?.backgroundColor

        AppThemePalette.set(AppThemeStyles.swissMinimalist)
        XCTAssertEqual(view.layer?.backgroundColor, before)

        view.reapplyRecordedLayerColorsForTesting()

        let after = view.layer?.backgroundColor
        XCTAssertNotEqual(after, before)
        XCTAssertEqual(
            after.flatMap { NSColor(cgColor: $0)?.hexString },
            AppThemeStyles.swissMinimalist.resolved(.controlResting).hexString
        )
    }

    /// A view with no recorded surface must survive the sweep untouched — most views have none.
    func testTheSweepLeavesUnrecordedViewsAlone() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.magenta.cgColor

        view.reapplyRecordedSurfaceForTesting()

        XCTAssertEqual(
            NSColor(cgColor: view.layer!.backgroundColor!)?.hexString,
            NSColor.magenta.hexString
        )
    }

    // MARK: - Derivation

    /// A style states a dozen roles; the rest are derived. What must never happen is a themed
    /// role falling back to a *system* colour — a fixed dark ground with system labels over it
    /// would flip half the window when macOS switched appearance.
    func testEveryRoleIsThemedOnceAStyleIsApplied() {
        for theme in AppThemeStyles.all {
            for role in AppThemeRole.allCases {
                let resolved = theme.resolved(role)
                XCTAssertNotEqual(
                    resolved.resolvedComponents, role.systemColor.resolvedComponents,
                    "\(theme.name) leaves \(role.rawValue) on the system colour"
                )
            }
        }
    }

    func testDerivedLabelTiersDescendFromTheStatedLabel() {
        let theme = AppThemeStyles.cyberpunk
        let label = theme.resolved(.label)

        for role in [AppThemeRole.secondaryLabel, .tertiaryLabel, .quaternaryLabel] {
            let derived = theme.resolved(role)
            XCTAssertEqual(
                derived.withAlphaComponent(1).resolvedHex,
                label.withAlphaComponent(1).resolvedHex,
                "\(role.rawValue) changed hue"
            )
            XCTAssertLessThan(derived.alphaComponent, label.alphaComponent)
        }
    }

    /// Threading is the product dress, not a renamed generic palette. Its light and dark app,
    /// terminal, and sidebar variants remain one authored set while AppKit owns the window frame.
    func testThreadingThemeShipsOneCompleteProductDress() throws {
        let theme = AppThemeStyles.threading
        let lightAppearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let darkAppearance = try XCTUnwrap(NSAppearance(named: .darkAqua))

        XCTAssertEqual(theme.mode, .system)
        XCTAssertEqual(Set(theme.availableVariants), Set(AppTheme.VariantKind.allCases))
        XCTAssertFalse(theme.takesOverWindowChrome)

        let light = try XCTUnwrap(theme.variant(for: lightAppearance))
        let lightGround = theme.resolved(.ground, appearance: lightAppearance).oklch
        XCTAssertEqual(lightGround.lightness, 0.975, accuracy: 0.001)
        XCTAssertEqual(lightGround.hueDegrees, 75, accuracy: 0.1)
        let lightAccent = theme.resolved(.accent, appearance: lightAppearance).oklch
        XCTAssertEqual(lightAccent.lightness, 0.640, accuracy: 0.001)
        XCTAssertEqual(lightAccent.hueDegrees, 55, accuracy: 0.2)
        XCTAssertEqual(light.terminalPalette.background.hexString, "#FEFBF7")
        XCTAssertNotNil(light.sidebar?.background?.gradient)
        XCTAssertEqual(
            light.sidebar?.navigatorWell?.bevel,
            SidebarStyle.NavigatorWell.Bevel.none
        )
        XCTAssertNil(light.chrome, "the product theme must keep the native macOS window")

        let dark = try XCTUnwrap(theme.variant(for: darkAppearance))
        XCTAssertLessThan(
            ThemeContrast.perceptualDistance(
                theme.resolved(.accent, appearance: darkAppearance),
                try XCTUnwrap(NSColor(hex: "#FF9A3D"))
            ),
            1
        )
        XCTAssertLessThan(
            ThemeContrast.perceptualDistance(
                theme.resolved(.selection, appearance: darkAppearance),
                try XCTUnwrap(NSColor(hex: "#17405C"))
            ),
            1
        )
        XCTAssertEqual(dark.terminalPalette.background.hexString, "#040A12")
        XCTAssertNotNil(dark.sidebar?.background?.gradient)
        XCTAssertEqual(
            dark.sidebar?.navigatorWell?.bevel,
            SidebarStyle.NavigatorWell.Bevel.none
        )
        XCTAssertNil(dark.chrome, "the product theme must keep the native macOS window")
    }

    // MARK: - Legibility

    /// A style that cannot be read is not a style. Every stock theme's text must clear the same
    /// contrast floor the terminal themes are held to, on each of its own surfaces.
    func testEveryStockStyleIsLegibleOnItsOwnSurfaces() {
        for theme in AppThemeStyles.all {
            for surface in [AppThemeRole.ground, .surface, .panel] {
                let ratio = ThemeContrast.ratio(theme.resolved(.label), theme.resolved(surface))
                XCTAssertGreaterThanOrEqual(
                    ratio, ThemeContrast.minimumRatio,
                    "\(theme.name): label on \(surface.rawValue) is \(String(format: "%.1f", ratio)):1"
                )
            }
        }
    }

    func testStockStyleAccentsStandOutFromTheirGround() {
        for theme in AppThemeStyles.all {
            let ratio = ThemeContrast.ratio(theme.resolved(.accent), theme.resolved(.ground))
            XCTAssertGreaterThanOrEqual(ratio, 2.0, "\(theme.name)'s accent vanishes into its ground")
        }
    }

    // MARK: - Identity

    /// Stock themes are addressed by slug, never by display name — the mistake the terminal
    /// themes made, where renaming one in a release would silently reset every assignment.
    func testStockThemesHaveUniqueStableIdentifiers() {
        let ids = AppThemeLibrary.stock.map(\.id.rawValue)
        XCTAssertEqual(Set(ids).count, ids.count, "two stock themes share an id")
        XCTAssertTrue(ids.contains(AppThemeID.system.rawValue))
        // 29 = System + Threading + eleven design movements + five palette-first styles +
        // Christmas + ten period and authored chrome themes.
        XCTAssertEqual(ids.count, 29, "the curated stock catalogue unexpectedly changed size")
    }

    // MARK: - Sections

    /// A style that is filed nowhere does not exist: `AppThemeStyles.all` *is* the families
    /// flattened, so the picker cannot show a catalogue the rest of the app does not have — the
    /// drift a second hand-maintained list produces within weeks (see `takeovers`).
    func testEveryStockStyleIsFiledUnderExactlyOneFamily() {
        let filed = AppThemeStyles.families.flatMap(\.themes).map(\.id)
        XCTAssertEqual(filed, AppThemeStyles.all.map(\.id),
                       "the catalogue and its families disagree")
        XCTAssertEqual(Set(filed).count, filed.count, "a style is filed under two families")
        XCTAssertTrue(
            AppThemeStyles.styleFamilies.allSatisfy { !($0.title ?? "").isEmpty },
            "a named family lost its head"
        )
        XCTAssertNil(AppThemeStyles.house.title, "the house group grew a head")
        XCTAssertTrue(
            AppThemeStyles.families.allSatisfy { !$0.themes.isEmpty },
            "an empty section would draw a head over nothing"
        )
    }

    /// The sectioned catalogue is the flat one — every theme, exactly once — so a picker built
    /// from `sections` and a caller reasoning about `all` name the same list. The stock tier
    /// keeps the catalogue's order outright; the contributed tier groups by extension, which is
    /// the one place the two may run in a different sequence.
    func testSectionsAreTheWholeCatalogueInOrder() {
        let filed = AppThemeLibrary.sections.flatMap(\.themes).map(\.id)
        XCTAssertEqual(Set(filed), Set(AppThemeLibrary.all.map(\.id)))
        XCTAssertEqual(Set(filed).count, filed.count, "a theme is filed under two sections")
        XCTAssertEqual(
            AppThemeLibrary.stockSections.flatMap(\.themes).map(\.id),
            AppThemeLibrary.stock.map(\.id)
        )
        // System leads, under no head of its own: it is not a style, and a head over one row
        // repeating its name is furniture.
        let first = AppThemeLibrary.sections.first
        XCTAssertNil(first?.title)
        XCTAssertEqual(first?.themes.first?.id, .system)
    }

    /// The user's own themes are a section rather than a suffix on every row. Before this, each
    /// custom row wrote `— Custom` into its own title — the same word, on every row, in the
    /// widest column the menu has.
    func testACustomThemeIsFiledUnderItsOwnSectionRatherThanLabelledPerRow() throws {
        let name = "Section Fixture \(UUID().uuidString.prefix(8))"
        let custom = try AppThemeLibrary.duplicate(AppThemeStyles.dracula, name: name)
        defer { AppThemeLibrary.delete(custom) }

        let section = try XCTUnwrap(
            AppThemeLibrary.sections.last,
            "the custom tier is filed nowhere"
        )
        XCTAssertEqual(section.title, L10n.string("Custom"))
        XCTAssertTrue(section.themes.contains { $0.id == custom.id })
        XCTAssertFalse(
            section.themes.contains { $0.name.contains("—") },
            "a row still carries its tier in its own title"
        )
    }

    /// A takeover chrome is not complete merely because its Swift document exists. Every stock
    /// frame must have the same component-by-component evidence ledger, and a deleted chrome must
    /// not leave a stale historical identity behind. This closes both directions of that drift.
    func testEveryTakeoverChromeHasExactlyOneReferenceManifest() throws {
        let authoredChromeIDs = Set(AppThemeStyles.all.compactMap { theme in
            theme.variants.values.contains(where: { $0.chrome != nil })
                ? theme.id.rawValue
                : nil
        })
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let referenceRoot = repository
            .appendingPathComponent("docs/references/chrome", isDirectory: true)
        let referenceChromeIDs = Set(try FileManager.default.contentsOfDirectory(
            at: referenceRoot,
            includingPropertiesForKeys: nil
        ).compactMap { candidate in
            FileManager.default.fileExists(
                atPath: candidate.appendingPathComponent("reference.json").path
            ) ? candidate.lastPathComponent : nil
        })

        XCTAssertEqual(
            referenceChromeIDs,
            authoredChromeIDs,
            "takeover themes and their component evidence ledgers drifted apart"
        )
    }

    func testEveryStockStylePassesTheSameValidationAsAgentCreatedThemes() throws {
        for theme in AppThemeStyles.all {
            XCTAssertNoThrow(
                try AppThemeEditing.validate(theme),
                "\(theme.name) fails the public theme contract"
            )
        }
    }

    func testEveryStockStyleHasAUniquePairedTerminalPalette() {
        let ids = AppThemeStyles.all.map(\.terminalPalette.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testThemesRoundTripThroughTheirDocument() throws {
        for theme in AppThemeStyles.all {
            let data = try JSONEncoder().encode(theme)
            let decoded = try JSONDecoder().decode(AppTheme.self, from: data)

            XCTAssertEqual(decoded.id, theme.id)
            XCTAssertEqual(decoded.mode, theme.mode)
            XCTAssertEqual(Set(decoded.variants.keys), Set(theme.variants.keys))
            for kind in theme.availableVariants {
                XCTAssertEqual(decoded.variant(kind)?.material, theme.variant(kind)?.material)
                for (role, color) in theme.variant(kind)?.roles ?? [:] {
                    XCTAssertEqual(
                        decoded.variant(kind)?.roles[role]?.hexString,
                        color.hexString,
                        "\(kind.rawValue).\(role.rawValue)"
                    )
                }
            }
        }
    }

    func testAdaptiveThemeRoundTripsBothVariants() throws {
        let theme = try adaptiveFixture()
        let encoded = try JSONEncoder().encode(theme)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertNotNil(object["variants"])
        XCTAssertNil(object["roles"], "new documents must not write the legacy single-variant shape")

        let decoded = try JSONDecoder().decode(AppTheme.self, from: encoded)
        XCTAssertEqual(decoded.mode, .system)
        XCTAssertEqual(Set(decoded.variants.keys), Set(theme.variants.keys))
        for kind in theme.availableVariants {
            let original = try XCTUnwrap(theme.variant(kind))
            let restored = try XCTUnwrap(decoded.variant(kind))
            XCTAssertEqual(restored.material, original.material)
            for role in AppThemeRole.allCases {
                XCTAssertEqual(
                    restored.roles[role]?.hexString,
                    original.roles[role]?.hexString,
                    "\(kind.rawValue).\(role.wireName)"
                )
            }
            for color in ThemeColorKey.allCases {
                XCTAssertEqual(
                    restored.terminalPalette[color].hexString,
                    original.terminalPalette[color].hexString,
                    "\(kind.rawValue).terminal.\(color.wireName)"
                )
            }
        }
    }

    func testThemeDocumentsPreserveTranslucentRoles() throws {
        let color = try XCTUnwrap(NSColor(hex: "#12345680"))
        let theme = AppTheme(
            id: AppThemeID("alpha"),
            name: "Alpha",
            mode: .dark,
            summary: nil,
            roles: [.accentMuted: color],
            terminalPalette: .basic,
            material: .system
        )

        let decoded = try JSONDecoder().decode(
            AppTheme.self,
            from: JSONEncoder().encode(theme)
        )
        let restored = try XCTUnwrap(decoded.roles[.accentMuted])
        XCTAssertEqual(restored.hexString, "#12345680")
        XCTAssertEqual(restored.alphaComponent, color.alphaComponent, accuracy: 1 / 255)
    }

    func testCustomThemeStorePersistsCompleteDocuments() throws {
        let suite = "AppThemeStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppThemeStore(defaults: defaults, key: "themes")

        store.insert(AppThemeStyles.cyberpunk)

        let restored = try XCTUnwrap(store.themes.first)
        XCTAssertEqual(restored.id, AppThemeStyles.cyberpunk.id)
        XCTAssertEqual(
            restored.roles[.accentMuted]?.hexString,
            AppThemeStyles.cyberpunk.roles[.accentMuted]?.hexString
        )
        XCTAssertEqual(restored.material, AppThemeStyles.cyberpunk.material)
        XCTAssertEqual(restored.terminalPalette, AppThemeStyles.cyberpunk.terminalPalette)
    }

    func testCustomThemeMaterialisesSystemRolesBeforeItIsStored() throws {
        let theme = try AppThemeEditing.make(
            id: AppThemeID("fixed-system-copy"),
            name: "Fixed System Copy",
            base: .system,
            mode: .dark,
            roles: [
                .ground: NSColor(hex: "#080808")!,
                .surface: NSColor(hex: "#101010")!,
                .panel: NSColor(hex: "#181818")!,
                .label: NSColor(hex: "#F4F4F4")!,
                .accent: NSColor(hex: "#66CCFF")!
            ]
        )

        for role in AppThemeRole.authored {
            XCTAssertNotNil(theme.roles[role], "\(role.wireName) stayed dynamic")
        }
    }

    func testCustomThemeValidationRejectsUnreadableChrome() {
        XCTAssertThrowsError(
            try AppThemeEditing.make(
                id: AppThemeID("unreadable"),
                name: "Unreadable",
                base: AppThemeStyles.cyberpunk,
                roles: [
                    .ground: NSColor(hex: "#111111")!,
                    .surface: NSColor(hex: "#111111")!,
                    .panel: NSColor(hex: "#111111")!,
                    .label: NSColor(hex: "#111111")!
                ]
            )
        )
    }

    func testCustomThemeValidationMeasuresTranslucentTextAsDrawn() {
        XCTAssertThrowsError(
            try AppThemeEditing.make(
                id: AppThemeID("faint"),
                name: "Faint",
                base: AppThemeStyles.cyberpunk,
                roles: [
                    .label: NSColor(hex: "#FFFFFF20")!
                ]
            )
        )
    }

    /// A role added in a later release must not stop an older document loading.
    func testAnUnknownRoleInADocumentIsSkippedRatherThanFatal() throws {
        let json = """
        {"id":"future","name":"Future","mode":"dark",
         "roles":{"ground":"#101010","label":"#EEEEEE","hologram":"#FF00FF"}}
        """
        let decoded = try JSONDecoder().decode(AppTheme.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.roles[.ground]?.hexString, "#101010")
        XCTAssertEqual(decoded.roles.count, 2)
    }

    func testLegacySingleVariantDocumentMigratesDuringDecode() throws {
        let json = """
        {
          "id":"legacy-dark",
          "name":"Legacy Dark",
          "mode":"dark",
          "roles":{"ground":"#101010","label":"#EEEEEE"},
          "material":{"panelRadius":4,"controlRadius":3,"borderWidth":1}
        }
        """
        let decoded = try JSONDecoder().decode(AppTheme.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.availableVariants, [.dark])
        XCTAssertNil(decoded.variant(.light))
        XCTAssertEqual(decoded.variant(.dark)?.roles[.ground]?.hexString, "#101010")
        XCTAssertEqual(decoded.variant(.dark)?.material.panelRadius, 4)
    }

    func testAppThemeRolesAcceptAgentFacingSnakeCase() {
        XCTAssertEqual(AppThemeRole.named("status_positive"), .statusPositive)
        XCTAssertEqual(AppThemeRole.named("controlResting"), .controlResting)
        XCTAssertNil(AppThemeRole.named("wallpaper"))
    }

    // MARK: - Typography

    func testSemanticTypographyRolesKeepAConsistentHierarchy() {
        XCTAssertGreaterThan(
            Design.Typography.heading().pointSize,
            Design.Typography.placeholderTitle().pointSize
        )
        XCTAssertGreaterThan(
            Design.Typography.placeholderTitle().pointSize,
            Design.Typography.body().pointSize
        )
        XCTAssertGreaterThan(
            Design.Typography.body().pointSize,
            Design.Typography.detail().pointSize
        )
        XCTAssertEqual(
            Design.Typography.body().pointSize,
            Design.Typography.emphasizedBody().pointSize,
            "emphasis changed size instead of weight"
        )
    }

    func testCodeAndNumericRolesUseTheExpectedFixedWidthFamilies() {
        XCTAssertTrue(Design.Typography.code().fontDescriptor.symbolicTraits.contains(.monoSpace))
        XCTAssertTrue(Design.Typography.inlineCode().fontDescriptor.symbolicTraits.contains(.monoSpace))

        let numeric = Design.Typography.numericBody()
        let one = ("1" as NSString).size(withAttributes: [.font: numeric]).width
        let eight = ("8" as NSString).size(withAttributes: [.font: numeric]).width
        XCTAssertEqual(one, eight, accuracy: 0.001)
    }

    func testAppTextSizeScalesEverySemanticRoleAndRepaintsExistingLabels() {
        let bodyAtStandard = Design.Typography.body().pointSize
        let codeAtStandard = Design.Typography.code().pointSize
        let label = NSTextField(labelWithString: "Existing label")
        label.applyFont(.body)
        XCTAssertEqual(label.font?.pointSize, bodyAtStandard)

        UserDefaults.standard.set(AppTextSize.extraLarge.rawValue, forKey: "appTextSize")
        AppThemeRefresh.repaint(label)

        XCTAssertEqual(
            Design.Typography.body().pointSize,
            bodyAtStandard * AppTextSize.extraLarge.scale,
            accuracy: 0.001
        )
        XCTAssertEqual(
            Design.Typography.code().pointSize,
            codeAtStandard * AppTextSize.extraLarge.scale,
            accuracy: 0.001
        )
        XCTAssertEqual(
            label.font?.pointSize ?? 0,
            bodyAtStandard * AppTextSize.extraLarge.scale,
            accuracy: 0.001,
            "an existing host-rendered label did not follow the new text scale"
        )
    }

    func testThemeTextScaleCompactsEverySemanticRoleBeforeTheUserScale() {
        AppThemePalette.set(.system)
        let bodyAtOne = Design.Typography.body().pointSize
        let codeAtOne = Design.Typography.code().pointSize

        AppThemePalette.set(AppThemeStyles.win98)

        XCTAssertEqual(
            Design.Typography.body().pointSize,
            bodyAtOne * AppThemeStyles.win98.material.textScale,
            accuracy: 0.001
        )
        XCTAssertEqual(
            Design.Typography.code().pointSize,
            codeAtOne * AppThemeStyles.win98.material.textScale,
            accuracy: 0.001
        )
    }

    func testAppTextSizeUsesAnInjectedDefaultsDomain() throws {
        let suite = "AppThemeTests.TextSize.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.appTextSize, .standard)
        settings.appTextSize = .large
        XCTAssertEqual(settings.appTextSize, .large)
        XCTAssertEqual(defaults.string(forKey: "appTextSize"), AppTextSize.large.rawValue)
    }

    func testThemePreferencesExposeTheTextSizeControl() throws {
        let controller = ThemePreferencesViewController()
        _ = controller.view

        let control = try XCTUnwrap(
            descendant(
                in: controller.view,
                accessibilityIdentifier: "settings.themes.text-size"
            )
        )
        XCTAssertTrue(control is ThemedPopUp)
    }

    private func descendant(
        in view: NSView,
        accessibilityIdentifier: String
    ) -> NSView? {
        if view.accessibilityIdentifier() == accessibilityIdentifier {
            return view
        }
        return view.subviews.lazy.compactMap {
            self.descendant(in: $0, accessibilityIdentifier: accessibilityIdentifier)
        }.first
    }

    private static func textFields(in root: NSView) -> [NSTextField] {
        var fields: [NSTextField] = []
        if let field = root as? NSTextField { fields.append(field) }
        for child in root.subviews {
            fields.append(contentsOf: textFields(in: child))
        }
        return fields
    }

    private func adaptiveFixture() throws -> AppTheme {
        let light = try XCTUnwrap(AppThemeStyles.swissMinimalist.variant(.light))
        let dark = try XCTUnwrap(AppThemeStyles.cyberpunk.variant(.dark))
        return try AppThemeEditing.assemble(
            id: AppThemeID("adaptive-fixture"),
            name: "Adaptive Fixture",
            mode: .system,
            summary: nil,
            variants: [.light: light, .dark: dark]
        )
    }
}

// MARK: - Helpers

/// A pane that paints, so the seam between two of them is something a pixel read can find. An
/// unpainted `NSView` leaves the bitmap transparent, where every column reads as ink.
private final class PaintedPane: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        dirtyRect.fill()
    }
}

private extension NSColor {
    /// Compares colours by what they actually draw as, since a dynamic colour and a literal are
    /// never `==` even when they render identically.
    var resolvedHex: String {
        let appearance = NSAppearance(named: .darkAqua) ?? NSAppearance.currentDrawing()
        var hex = ""
        appearance.performAsCurrentDrawingAppearance {
            hex = (usingColorSpace(.sRGB) ?? .black).hexString
        }
        return hex
    }

    /// The same resolution at full precision, for the questions a hex string cannot answer.
    ///
    /// `hexString` quantises to eight bits per channel, which is right for a colour on its way
    /// to a raster or into a theme document and wrong for *is this the same colour*: white at
    /// 90% alpha and Claymorphism's stated `#FFFFFFE6` are 229.5 and 230 of the same byte, so
    /// they render identically and are not the same ink. Asking "did this role fall back?" of
    /// the rendering therefore accused a theme that states the role.
    var resolvedComponents: [CGFloat] {
        let appearance = NSAppearance(named: .darkAqua) ?? NSAppearance.currentDrawing()
        var components: [CGFloat] = []
        appearance.performAsCurrentDrawingAppearance {
            let color = usingColorSpace(.sRGB) ?? .black
            components = [
                color.redComponent,
                color.greenComponent,
                color.blueComponent,
                color.alphaComponent
            ]
        }
        return components
    }
}
