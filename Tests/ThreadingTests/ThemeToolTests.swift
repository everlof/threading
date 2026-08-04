import AppKit
import XCTest
@testable import Threading

/// The theme tools as an agent meets them: the JSON it sends, and the schema it reads.
///
/// Both halves fail quietly when they are wrong — a mistyped argument name decodes to nil and
/// the tool reports a missing value, while a colour missing from the schema is simply never
/// sent — so neither shows up as a crash or a failing build.
@MainActor
final class ThemeToolTests: XCTestCase {

    // MARK: - Decoding

    private func call(_ json: String) throws -> MCPToolCall {
        try JSONDecoder()
            .decode(MCPToolCallParameters.self, from: Data(json.utf8))
            .call
    }

    func testSetThemeDecodesItsArguments() throws {
        let call = try call("""
            {"name": "set_theme", "arguments": {"theme_id": "ocean", "scope": "project"}}
            """)

        guard case .setTheme(let arguments) = call else {
            return XCTFail("decoded as \(call.name)")
        }
        XCTAssertEqual(arguments.themeID, TerminalThemeID.ocean.rawValue)
        XCTAssertNil(arguments.theme)
        XCTAssertEqual(arguments.scope, "project")
    }

    /// Both arguments are optional: no theme means "clear this scope", and no scope means the
    /// calling session. A tool an agent can call correctly with `{}` is one it will.
    func testSetThemeDecodesWithNoArgumentsAtAll() throws {
        let call = try call("""
            {"name": "set_theme"}
            """)

        guard case .setTheme(let arguments) = call else {
            return XCTFail("decoded as \(call.name)")
        }
        XCTAssertNil(arguments.themeID)
        XCTAssertNil(arguments.theme)
        XCTAssertNil(arguments.scope)
    }

    func testSetThemeStillAcceptsThePreIDNameArgument() throws {
        let call = try call("""
            {"name": "set_theme", "arguments": {"theme": "Ocean", "scope": "session"}}
            """)

        guard case .setTheme(let arguments) = call else {
            return XCTFail("decoded as \(call.name)")
        }
        XCTAssertNil(arguments.themeID)
        XCTAssertEqual(arguments.theme, "Ocean")
    }

    func testCreateThemeDecodesAPartialPalette() throws {
        let call = try call("""
            {
              "name": "create_theme",
              "arguments": {
                "name": "Dusk",
                "base_id": "ocean",
                "colors": {"background": "#101018", "bright_magenta": "#FF77FF"},
                "apply": "session"
              }
            }
            """)

        guard case .createTheme(let arguments) = call else {
            return XCTFail("decoded as \(call.name)")
        }
        XCTAssertEqual(arguments.name, "Dusk")
        XCTAssertEqual(arguments.baseID, TerminalThemeID.ocean.rawValue)
        XCTAssertNil(arguments.base)
        XCTAssertEqual(arguments.apply, "session")
        XCTAssertEqual(arguments.colors?["background"], "#101018")
        XCTAssertEqual(arguments.colors?["bright_magenta"], "#FF77FF")
    }

    func testListThemesTakesNoArguments() throws {
        guard case .listThemes = try call("""
            {"name": "list_themes", "arguments": {}}
            """) else {
            return XCTFail("list_themes did not decode")
        }
    }

    func testExtensionInstallProposalDecodesItsPackageDirectory() throws {
        let call = try call("""
            {
              "name": "extension_propose_install",
              "arguments": {"directory": "/tmp/build-watch.threadingextension"}
            }
            """)

        guard case .extensionProposeInstall(let arguments) = call else {
            return XCTFail("decoded as \(call.name)")
        }
        XCTAssertEqual(
            arguments.directory,
            "/tmp/build-watch.threadingextension"
        )
    }

    func testCreateThemeStillAcceptsThePreIDBaseNameArgument() throws {
        let call = try call("""
            {
              "name": "create_theme",
              "arguments": {
                "name": "Legacy Client",
                "base": "Ocean",
                "colors": {"cursor": "#FFFFFF"}
              }
            }
            """)

        guard case .createTheme(let arguments) = call else {
            return XCTFail("decoded as \(call.name)")
        }
        XCTAssertNil(arguments.baseID)
        XCTAssertEqual(arguments.base, "Ocean")
    }

    // MARK: - Dynamic App Theme

    private func coordinator() -> AgentToolCoordinator {
        AgentToolCoordinator(
            displayPaneController: DisplayPaneController(),
            visibleSessionID: { nil },
            setPaneVisible: { _ in },
            windowProvider: { nil }
        )
    }

    func testListThemesAdvertisesFollowAppThemeAsDynamic() {
        let result = coordinator().listThemes(for: SessionID())

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.text.contains(TerminalThemeID.followsAppTheme.rawValue))
        XCTAssertTrue(result.text.contains(TerminalThemeNames.followsAppTheme))
        XCTAssertTrue(result.text.contains("dynamic, follows app chrome"))
    }

    func testListThemesAdvertisesStableIDsAlongsideNames() {
        let result = coordinator().listThemes(for: SessionID())

        XCTAssertTrue(result.text.contains("ocean — Ocean (built-in)"))
        XCTAssertTrue(result.text.contains("basic — Basic (built-in)"))
    }

    func testSetThemeCanMakeTheGlobalDefaultFollowAppTheme() {
        let previousDefault = ThemeAssignments.defaultTheme
        let previousAppTheme = AppThemeLibrary.current
        defer {
            ThemeAssignments.setDefaultTheme(previousDefault)
            AppThemeLibrary.apply(previousAppTheme)
        }

        let result = coordinator().setTheme(
            SetThemeArguments(
                themeID: TerminalThemeID.followsAppTheme.rawValue,
                theme: nil,
                scope: ThemeScope.global.rawValue
            ),
            for: SessionID()
        )

        XCTAssertFalse(result.isError)
        XCTAssertEqual(ThemeAssignments.defaultTheme.name, TerminalThemeNames.followsAppTheme)

        AppThemeLibrary.apply(AppThemeStyles.cyberpunk)
        let cyber = ThemeAssignments.theme(for: nil)
        AppThemeLibrary.apply(AppThemeStyles.swissMinimalist)
        let swiss = ThemeAssignments.theme(for: nil)

        XCTAssertNotEqual(cyber.background.hexString, swiss.background.hexString)
        XCTAssertEqual(cyber.background.hexString, AppThemeStyles.cyberpunk.terminalPalette.background.hexString)
        XCTAssertEqual(swiss.background.hexString, AppThemeStyles.swissMinimalist.terminalPalette.background.hexString)
    }

    func testCreateThemeCanSnapshotFollowAppThemeAsItsBase() throws {
        let previousAppTheme = AppThemeLibrary.current
        AppThemeLibrary.apply(AppThemeStyles.cyberpunk)
        defer { AppThemeLibrary.apply(previousAppTheme) }

        let name = "App Theme Snapshot \(UUID().uuidString)"
        let result = coordinator().createTheme(
            CreateThemeArguments(
                name: name,
                baseID: TerminalThemeID.followsAppTheme.rawValue,
                base: nil,
                colors: ["cursor": "#FF00FF"],
                apply: "none"
            ),
            for: SessionID()
        )

        XCTAssertFalse(result.isError)
        let created = try XCTUnwrap(ThemeManager.shared.theme(named: name))
        defer { _ = ThemeManager.shared.deleteTheme(created) }

        XCTAssertEqual(
            created.background.hexString,
            AppThemeStyles.cyberpunk.terminalPalette.background.hexString
        )
        XCTAssertEqual(created.cursor.hexString, "#FF00FF")
    }

    func testDuplicateAppThemeDecodesTheExplicitModificationWorkflow() throws {
        let call = try call("""
            {
              "name": "duplicate_app_theme",
              "arguments": {
                "theme_id": "cyberpunk",
                "name": "Cyberpunk Violet",
                "apply": false
              }
            }
            """)

        guard case .duplicateAppTheme(let arguments) = call else {
            return XCTFail("decoded as \(call.name)")
        }
        XCTAssertEqual(arguments.themeID, "cyberpunk")
        XCTAssertEqual(arguments.name, "Cyberpunk Violet")
        XCTAssertEqual(arguments.apply, false)
    }

    func testUpdateAppThemeDecodesNestedPatches() throws {
        let call = try call("""
            {
              "name": "update_app_theme",
              "arguments": {
                "theme_id": "custom-violet",
                "appearance": "adaptive",
                "variants": {
                  "dark": {
                    "roles": {"accent": "#AA77FFFF", "status_positive": "#44DD88"},
                    "material": {
                      "panel_radius": 5,
                      "text_scale": 0.8,
                      "glow": {
                        "role": "accent",
                        "radius": 8,
                        "opacity": 0.25,
                        "offset_x": 3,
                        "offset_y": -4
                      }
                    },
                    "terminal_colors": {"bright_magenta": "#DD99FF"}
                  }
                },
                "apply": true
              }
            }
            """)

        guard case .updateAppTheme(let arguments) = call else {
            return XCTFail("decoded as \(call.name)")
        }
        XCTAssertEqual(arguments.themeID, "custom-violet")
        XCTAssertEqual(arguments.appearance, "adaptive")
        let dark = try XCTUnwrap(arguments.variants?["dark"])
        XCTAssertEqual(dark.roles?["status_positive"], "#44DD88")
        XCTAssertEqual(dark.material?.panelRadius, 5)
        XCTAssertEqual(dark.material?.textScale, 0.8)
        XCTAssertEqual(dark.material?.glow?.radius, 8)
        XCTAssertEqual(dark.material?.glow?.offsetX, 3)
        XCTAssertEqual(dark.material?.glow?.offsetY, -4)
        XCTAssertEqual(dark.terminalColors?["bright_magenta"], "#DD99FF")
        XCTAssertEqual(arguments.apply, true)
    }

    func testCreateAppThemeStillDecodesTheSingleVariantLegacyShape() throws {
        let call = try call("""
            {
              "name": "create_app_theme",
              "arguments": {
                "name": "Legacy Shape",
                "mode": "dark",
                "roles": {"accent": "#AA77FF"},
                "terminal_colors": {"cursor": "#AA77FF"}
              }
            }
            """)

        guard case .createAppTheme(let arguments) = call else {
            return XCTFail("decoded as \(call.name)")
        }
        XCTAssertEqual(arguments.mode, "dark")
        XCTAssertNil(arguments.appearance)
        XCTAssertEqual(arguments.roles?["accent"], "#AA77FF")
        XCTAssertEqual(arguments.terminalColors?["cursor"], "#AA77FF")
    }

    func testAgentCanCreateAnAdaptiveThemeAndGetAReusableVariantDocument() throws {
        let name = "Adaptive Tool Theme \(UUID().uuidString)"
        let arguments = CreateAppThemeArguments(
            name: name,
            baseID: AppThemeStyles.cyberpunk.id.rawValue,
            appearance: "adaptive",
            mode: nil,
            summary: "Two deliberately authored appearances.",
            variants: [
                "light": AppThemeVariantArguments(
                    roles: authoredRoles(of: AppThemeStyles.swissMinimalist),
                    material: nil,
                    terminalColors: terminalColors(of: AppThemeStyles.swissMinimalist.terminalPalette)
                ),
                "dark": AppThemeVariantArguments(
                    roles: ["accent": "#AA77FF"],
                    material: nil,
                    terminalColors: nil
                )
            ],
            roles: nil,
            material: nil,
            terminalColors: nil,
            apply: false
        )

        let result = coordinator().createAppTheme(arguments)
        XCTAssertFalse(result.isError, result.text)
        let created = try XCTUnwrap(AppThemeLibrary.all.first { $0.name == name })
        defer { _ = AppThemeLibrary.delete(created) }

        XCTAssertEqual(created.mode, .system)
        XCTAssertEqual(Set(created.availableVariants), [.light, .dark])
        let light = try XCTUnwrap(created.variant(.light))
        let dark = try XCTUnwrap(created.variant(.dark))
        XCTAssertEqual(light.roles[.ground]?.hexString, "#FFFFFF")
        XCTAssertEqual(dark.roles[.accent]?.hexString, "#AA77FF")

        let get = coordinator().getAppTheme(
            AppThemeReferenceArguments(themeID: created.id.rawValue)
        )
        XCTAssertFalse(get.isError, get.text)
        let document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(get.text.utf8)) as? [String: Any]
        )
        XCTAssertEqual(document["appearance"] as? String, "adaptive")
        let variants = try XCTUnwrap(document["variants"] as? [String: Any])
        let lightDocument = try XCTUnwrap(variants["light"] as? [String: Any])
        let material = try XCTUnwrap(lightDocument["material"] as? [String: Any])
        let terminal = try XCTUnwrap(lightDocument["terminal_colors"] as? [String: Any])
        XCTAssertNotNil(lightDocument["roles"])
        XCTAssertNil(lightDocument["explicit_roles"])
        XCTAssertNotNil(material["panel_radius"])
        XCTAssertNil(material["panelRadius"])
        XCTAssertNotNil(terminal["bright_magenta"])
        XCTAssertNil(terminal["brightMagenta"])
    }

    func testAgentCanAddAMissingVariantThenMakeThemeAdaptive() throws {
        let name = "Growing Tool Theme \(UUID().uuidString)"
        let create = CreateAppThemeArguments(
            name: name,
            baseID: AppThemeStyles.cyberpunk.id.rawValue,
            appearance: "dark",
            mode: nil,
            summary: nil,
            variants: [
                "dark": AppThemeVariantArguments(
                    roles: ["accent": "#55AAFF"],
                    material: nil,
                    terminalColors: nil
                )
            ],
            roles: nil,
            material: nil,
            terminalColors: nil,
            apply: false
        )
        let createResult = coordinator().createAppTheme(create)
        XCTAssertFalse(createResult.isError, createResult.text)
        let created = try XCTUnwrap(AppThemeLibrary.all.first { $0.name == name })
        defer {
            if let latest = AppThemeLibrary.theme(withID: created.id) {
                _ = AppThemeLibrary.delete(latest)
            }
        }
        XCTAssertEqual(created.availableVariants, [.dark])

        let update = UpdateAppThemeArguments(
            themeID: created.id.rawValue,
            name: nil,
            appearance: "adaptive",
            mode: nil,
            summary: nil,
            variants: [
                "light": AppThemeVariantArguments(
                    roles: authoredRoles(of: AppThemeStyles.swissMinimalist),
                    material: nil,
                    terminalColors: terminalColors(of: AppThemeStyles.swissMinimalist.terminalPalette)
                )
            ],
            roles: nil,
            material: nil,
            terminalColors: nil,
            apply: false
        )
        let updateResult = coordinator().updateAppTheme(update)
        XCTAssertFalse(updateResult.isError, updateResult.text)

        let updated = try XCTUnwrap(AppThemeLibrary.theme(withID: created.id))
        XCTAssertEqual(updated.mode, .system)
        XCTAssertEqual(Set(updated.availableVariants), [.light, .dark])
        XCTAssertEqual(updated.variant(.dark)?.roles[.accent]?.hexString, "#55AAFF")
        XCTAssertEqual(updated.variant(.light)?.roles[.ground]?.hexString, "#FFFFFF")
    }

    // MARK: - Sidebar

    func testUpdateAppThemeDecodesASidebarPatch() throws {
        let call = try call("""
            {
              "name": "update_app_theme",
              "arguments": {
                "theme_id": "custom-x",
                "variants": {
                  "dark": {
                    "sidebar": {
                      "gradient": {
                        "angle_degrees": 135,
                        "stops": [
                          {"color": "#101020", "position": 0},
                          {"color": "#202040", "position": 1}
                        ]
                      },
                      "logo": "hidden",
                      "title": {"text": "Atelier", "weight": "bold", "font_size": 15}
                    }
                  }
                }
              }
            }
            """)

        guard case .updateAppTheme(let arguments) = call else {
            return XCTFail("decoded as \(call.name)")
        }
        let sidebar = try XCTUnwrap(arguments.variants?["dark"]?.sidebar)
        XCTAssertEqual(sidebar.gradient?.angleDegrees, 135)
        XCTAssertEqual(sidebar.gradient?.stops?.count, 2)
        guard case .hidden = try XCTUnwrap(sidebar.logo) else {
            return XCTFail("logo did not decode as the bare word")
        }
        XCTAssertEqual(sidebar.title?.text, "Atelier")
        XCTAssertEqual(sidebar.title?.fontSize, 15)
    }

    func testTheLogoArgumentAlsoDecodesAsAnImageObject() throws {
        let call = try call("""
            {
              "name": "create_app_theme",
              "arguments": {
                "name": "X",
                "variants": {"dark": {"sidebar": {"logo": {"base64": "AAAA"}}}}
              }
            }
            """)
        guard case .createAppTheme(let arguments) = call else {
            return XCTFail("decoded as \(call.name)")
        }
        guard case .image(let image) = try XCTUnwrap(arguments.variants?["dark"]?.sidebar?.logo) else {
            return XCTFail("logo object did not decode as an image source")
        }
        XCTAssertEqual(image.base64, "AAAA")
    }

    /// The whole loop an agent actually runs: create a theme whose sidebar carries a gradient,
    /// an image (stored from bytes), and a brand; read it back in the same vocabulary; take
    /// the block away again. The asset dies with the theme.
    func testAgentCanDressReadAndUndressTheSidebar() throws {
        let name = "Sidebar Tool Theme \(UUID().uuidString)"
        let kind = AppThemeStyles.cyberpunk.availableVariants[0]
        let surface = AppThemeStyles.cyberpunk.resolved(
            .surface,
            appearance: kind.appearance ?? NSAppearance.currentDrawing()
        ).hexString

        let pixel = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            NSColor.systemTeal.setFill()
            rect.fill()
            return true
        }
        let png = try XCTUnwrap(
            NSBitmapImageRep(data: try XCTUnwrap(pixel.tiffRepresentation))?
                .representation(using: .png, properties: [:])
        )

        let create = CreateAppThemeArguments(
            name: name,
            baseID: AppThemeStyles.cyberpunk.id.rawValue,
            appearance: nil,
            mode: nil,
            summary: nil,
            variants: [
                kind.rawValue: AppThemeVariantArguments(
                    sidebar: AppThemeSidebarArguments(
                        gradient: AppThemeGradientArguments(
                            angleDegrees: 160,
                            stops: [
                                AppThemeGradientStopArguments(color: surface, position: 0),
                                AppThemeGradientStopArguments(color: surface, position: 1)
                            ]
                        ),
                        removeGradient: nil,
                        image: AppThemeSidebarImageArguments(
                            source: AppThemeImageArguments(
                                path: nil,
                                base64: png.base64EncodedString()
                            ),
                            mode: "tile",
                            opacity: 0.3
                        ),
                        removeImage: nil,
                        logo: nil,
                        title: AppThemeSidebarTitleArguments(
                            text: "Atelier",
                            fontFamily: nil,
                            fontSize: nil,
                            weight: "semibold",
                            hidden: nil
                        ),
                        navigatorWell: AppThemeSidebarNavigatorWellArguments(
                            fill: surface,
                            bevel: "sunken"
                        )
                    )
                )
            ],
            roles: nil,
            material: nil,
            terminalColors: nil,
            apply: false
        )
        let created = coordinator().createAppTheme(create)
        XCTAssertFalse(created.isError, created.text)
        let theme = try XCTUnwrap(AppThemeLibrary.all.first { $0.name == name })
        defer {
            if let latest = AppThemeLibrary.theme(withID: theme.id) {
                _ = AppThemeLibrary.delete(latest)
            }
        }

        let stored = try XCTUnwrap(theme.variant(kind)?.sidebar)
        let assetName = try XCTUnwrap(stored.background?.image?.asset)
        XCTAssertNotNil(
            ThemeAssetStore.image(named: assetName, for: theme.id),
            "the supplied bytes should be stored under the theme"
        )

        let get = coordinator().getAppTheme(
            AppThemeReferenceArguments(themeID: theme.id.rawValue)
        )
        XCTAssertFalse(get.isError, get.text)
        let document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(get.text.utf8)) as? [String: Any]
        )
        let variants = try XCTUnwrap(document["variants"] as? [String: Any])
        let variantDocument = try XCTUnwrap(variants[kind.rawValue] as? [String: Any])
        let sidebar = try XCTUnwrap(variantDocument["sidebar"] as? [String: Any])
        let gradient = try XCTUnwrap(sidebar["gradient"] as? [String: Any])
        XCTAssertEqual(gradient["angle_degrees"] as? Double, 160)
        let image = try XCTUnwrap(sidebar["image"] as? [String: Any])
        XCTAssertEqual(image["asset"] as? String, assetName)
        XCTAssertEqual(image["mode"] as? String, "tile")
        let title = try XCTUnwrap(sidebar["title"] as? [String: Any])
        XCTAssertEqual(title["text"] as? String, "Atelier")
        let navigator = try XCTUnwrap(sidebar["navigator_well"] as? [String: Any])
        XCTAssertEqual(navigator["fill"] as? String, surface)
        XCTAssertEqual(navigator["bevel"] as? String, "sunken")

        let undress = UpdateAppThemeArguments(
            themeID: theme.id.rawValue,
            name: nil,
            appearance: nil,
            mode: nil,
            summary: nil,
            variants: [
                kind.rawValue: AppThemeVariantArguments(
                    sidebar: AppThemeSidebarArguments(
                        gradient: nil, removeGradient: nil,
                        image: nil, removeImage: nil,
                        logo: nil, title: nil, removeTitle: nil,
                        remove: true
                    )
                )
            ],
            roles: nil,
            material: nil,
            terminalColors: nil,
            apply: false
        )
        let undressed = coordinator().updateAppTheme(undress)
        XCTAssertFalse(undressed.isError, undressed.text)
        let bare = try XCTUnwrap(AppThemeLibrary.theme(withID: theme.id))
        XCTAssertNil(bare.variant(kind)?.sidebar)

        _ = AppThemeLibrary.delete(bare)
        XCTAssertNil(
            ThemeAssetStore.image(named: assetName, for: theme.id),
            "deleting the theme should take its asset folder with it"
        )
    }

    /// The gate travels the tool path too: a wash the label cannot be read on is refused with
    /// the reason, and nothing is created — including the asset folder.
    func testAnUnreadableGradientIsRefusedThroughTheTool() throws {
        let name = "Unreadable Sidebar \(UUID().uuidString)"
        let kind = AppThemeStyles.cyberpunk.availableVariants[0]
        let label = AppThemeStyles.cyberpunk.resolved(
            .label,
            appearance: kind.appearance ?? NSAppearance.currentDrawing()
        ).hexString

        let create = CreateAppThemeArguments(
            name: name,
            baseID: AppThemeStyles.cyberpunk.id.rawValue,
            appearance: nil,
            mode: nil,
            summary: nil,
            variants: [
                kind.rawValue: AppThemeVariantArguments(
                    sidebar: AppThemeSidebarArguments(
                        gradient: AppThemeGradientArguments(
                            angleDegrees: nil,
                            stops: [
                                AppThemeGradientStopArguments(color: label, position: 0),
                                AppThemeGradientStopArguments(color: label, position: 1)
                            ]
                        ),
                        removeGradient: nil,
                        image: nil, removeImage: nil,
                        logo: nil, title: nil, removeTitle: nil, remove: nil
                    )
                )
            ],
            roles: nil,
            material: nil,
            terminalColors: nil,
            apply: false
        )
        let result = coordinator().createAppTheme(create)
        XCTAssertTrue(result.isError, "a gradient in the label's own colour was accepted")
        XCTAssertTrue(result.text.contains("contrast"), result.text)
        XCTAssertNil(AppThemeLibrary.all.first { $0.name == name })
    }

    func testTheVariantSchemaDescribesTheSidebarBlock() throws {
        let schema = try schema(for: MCPTools.createAppTheme)
        let input = try XCTUnwrap(schema["inputSchema"] as? [String: Any])
        let properties = try XCTUnwrap(input["properties"] as? [String: Any])
        let variants = try XCTUnwrap(properties["variants"] as? [String: Any])
        let variantProperties = try XCTUnwrap(variants["properties"] as? [String: Any])
        let dark = try XCTUnwrap(variantProperties["dark"] as? [String: Any])
        let darkProperties = try XCTUnwrap(dark["properties"] as? [String: Any])
        let sidebar = try XCTUnwrap(
            darkProperties["sidebar"] as? [String: Any],
            "the variant schema does not describe the sidebar block"
        )
        let sidebarProperties = try XCTUnwrap(sidebar["properties"] as? [String: Any])
        for field in [
            "gradient", "image", "navigator_well", "remove_navigator_well",
            "logo", "title", "remove"
        ] {
            XCTAssertNotNil(sidebarProperties[field], "sidebar schema lost \(field)")
        }
    }

    // MARK: - Window Chrome

    /// The end-to-end customization contract for the first non-Windows takeover style: an
    /// agent can author Platinum's layout and texture, read every choice back, then remove
    /// the optional treatment without rebuilding the theme.
    func testAgentCanAuthorReadAndRevisePlatinumChrome() throws {
        let name = "Platinum Tool Theme \(UUID().uuidString)"
        let createCall = try call("""
            {
              "name": "create_app_theme",
              "arguments": {
                "name": "\(name)",
                "base_id": "swiss-minimalist",
                "appearance": "light",
                "variants": {
                  "light": {
                    "chrome": {
                      "title_bar": {
                        "active_gradient": {
                          "stops": [
                            {"color": "#DDDDDD", "position": 0},
                            {"color": "#DDDDDD", "position": 1}
                          ]
                        },
                        "inactive_gradient": {
                          "stops": [
                            {"color": "#DDDDDD", "position": 0},
                            {"color": "#DDDDDD", "position": 1}
                          ]
                        },
                        "ink": "#000000",
                        "inactive_ink": "#666666",
                        "title_alignment": "center",
                        "height": 20,
                        "button_glyph_style": "platinum",
                        "button_placement": "split",
                        "shows_app_icon": false,
                        "active_texture": {
                          "kind": "pinstripes",
                          "color": "#888888",
                          "spacing": 2
                        }
                      },
                      "frame": {"width": 2}
                    }
                  }
                },
                "apply": false
              }
            }
            """)
        guard case .createAppTheme(let create) = createCall else {
            return XCTFail("decoded as \(createCall.name)")
        }
        let decodedTitle = try XCTUnwrap(create.variants?["light"]?.chrome?.titleBar)
        XCTAssertEqual(decodedTitle.buttonGlyphStyle, "platinum")
        XCTAssertEqual(decodedTitle.buttonPlacement, "split")
        XCTAssertEqual(decodedTitle.showsAppIcon, false)
        XCTAssertEqual(decodedTitle.activeTexture?.kind, "pinstripes")
        XCTAssertEqual(decodedTitle.activeTexture?.spacing, 2)

        let result = coordinator().createAppTheme(create)
        XCTAssertFalse(result.isError, result.text)
        let theme = try XCTUnwrap(AppThemeLibrary.all.first { $0.name == name })
        defer {
            if let latest = AppThemeLibrary.theme(withID: theme.id) {
                _ = AppThemeLibrary.delete(latest)
            }
        }

        let stored = try XCTUnwrap(theme.variant(.light)?.chrome?.titleBar)
        XCTAssertEqual(stored.buttonGlyphStyle, .platinum)
        XCTAssertEqual(stored.buttonPlacement, .split)
        XCTAssertFalse(stored.showsAppIcon)
        XCTAssertEqual(stored.activeTexture?.kind, .pinstripes)
        XCTAssertEqual(stored.activeTexture?.color?.hexString, "#888888")
        XCTAssertEqual(stored.activeTexture?.spacing, 2)

        let get = coordinator().getAppTheme(
            AppThemeReferenceArguments(themeID: theme.id.rawValue)
        )
        XCTAssertFalse(get.isError, get.text)
        let document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(get.text.utf8)) as? [String: Any]
        )
        let variants = try XCTUnwrap(document["variants"] as? [String: Any])
        let light = try XCTUnwrap(variants["light"] as? [String: Any])
        let chrome = try XCTUnwrap(light["chrome"] as? [String: Any])
        let title = try XCTUnwrap(chrome["title_bar"] as? [String: Any])
        XCTAssertEqual(title["button_glyph_style"] as? String, "platinum")
        XCTAssertEqual(title["button_placement"] as? String, "split")
        XCTAssertEqual(title["shows_app_icon"] as? Bool, false)
        let texture = try XCTUnwrap(title["active_texture"] as? [String: Any])
        XCTAssertEqual(texture["kind"] as? String, "pinstripes")
        XCTAssertEqual(texture["color"] as? String, "#888888")
        XCTAssertEqual(texture["spacing"] as? Double, 2)

        let updateCall = try call("""
            {
              "name": "update_app_theme",
              "arguments": {
                "theme_id": "\(theme.id.rawValue)",
                "variants": {
                  "light": {
                    "chrome": {
                      "title_bar": {
                        "remove_active_texture": true,
                        "remove_inactive_ink": true,
                        "remove_height": true
                      }
                    }
                  }
                },
                "apply": false
              }
            }
            """)
        guard case .updateAppTheme(let update) = updateCall else {
            return XCTFail("decoded as \(updateCall.name)")
        }
        let revised = coordinator().updateAppTheme(update)
        XCTAssertFalse(revised.isError, revised.text)
        let updated = try XCTUnwrap(AppThemeLibrary.theme(withID: theme.id))
        XCTAssertNil(updated.variant(.light)?.chrome?.titleBar.activeTexture)
        XCTAssertNil(updated.variant(.light)?.chrome?.titleBar.inactiveInk)
        XCTAssertNil(updated.variant(.light)?.chrome?.titleBar.height)
    }

    func testVariantSchemaDescribesTheCompleteChromeVocabulary() throws {
        let schema = try schema(for: MCPTools.createAppTheme)
        let input = try XCTUnwrap(schema["inputSchema"] as? [String: Any])
        let properties = try XCTUnwrap(input["properties"] as? [String: Any])
        let variants = try XCTUnwrap(properties["variants"] as? [String: Any])
        let variantProperties = try XCTUnwrap(variants["properties"] as? [String: Any])
        let light = try XCTUnwrap(variantProperties["light"] as? [String: Any])
        let lightProperties = try XCTUnwrap(light["properties"] as? [String: Any])
        let chrome = try XCTUnwrap(lightProperties["chrome"] as? [String: Any])
        let chromeProperties = try XCTUnwrap(chrome["properties"] as? [String: Any])
        let title = try XCTUnwrap(chromeProperties["title_bar"] as? [String: Any])
        let titleProperties = try XCTUnwrap(title["properties"] as? [String: Any])

        for field in [
            "active_gradient", "inactive_gradient", "ink", "inactive_ink",
            "title_alignment", "height", "button_glyph_style", "button_placement",
            "shows_app_icon", "active_texture", "inactive_texture",
            "remove_active_texture", "remove_inactive_texture"
        ] {
            XCTAssertNotNil(titleProperties[field], "chrome schema lost \(field)")
        }
        let texture = try XCTUnwrap(titleProperties["active_texture"] as? [String: Any])
        let textureProperties = try XCTUnwrap(texture["properties"] as? [String: Any])
        XCTAssertEqual(
            Set(textureProperties.keys),
            ["kind", "color", "remove_color", "spacing", "remove_spacing"]
        )
    }

    // MARK: - Schema

    private func authoredRoles(of theme: AppTheme) -> [String: String] {
        Dictionary(uniqueKeysWithValues: AppThemeRole.authored.map {
            ($0.wireName, theme.resolved($0).hexString)
        })
    }

    private func terminalColors(of theme: TerminalTheme) -> [String: String] {
        Dictionary(uniqueKeysWithValues: ThemeColorKey.allCases.map {
            ($0.wireName, theme[$0].hexString)
        })
    }

    private func schema(for name: String) throws -> [String: Any] {
        let definition = try XCTUnwrap(
            MCPTools.definitions.first { $0.name == name },
            "\(name) is not in the tool definitions"
        )
        let data = try JSONEncoder().encode(definition)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    func testEveryThemeToolIsDefined() {
        for name in MCPTools.themeTools {
            XCTAssertTrue(
                MCPTools.definitions.contains { $0.name == name },
                "\(name) is advertised but has no schema"
            )
        }
    }

    func testThemeToolsAreInTheCatalogue() {
        let grouped = Set(MCPToolCatalog.groups.flatMap { $0.tools.map(\.name) })
        for name in MCPTools.themeTools {
            XCTAssertTrue(grouped.contains(name), "\(name) belongs to no settings group")
        }
    }

    func testEveryAppThemeToolIsDefinedAndCatalogued() {
        let grouped = Set(MCPToolCatalog.groups.flatMap { $0.tools.map(\.name) })
        for name in MCPTools.appThemeTools {
            XCTAssertTrue(
                MCPTools.definitions.contains { $0.name == name },
                "\(name) is advertised but has no schema"
            )
            XCTAssertTrue(grouped.contains(name), "\(name) belongs to no settings group")
        }
    }

    func testEveryExtensionAuthoringToolIsDefinedAndOnlyInItsOwnGroup() {
        let groupsByTool = Dictionary(
            grouping: MCPToolCatalog.groups.flatMap { group in
                group.tools.map { (tool: $0.name, group: group.id) }
            },
            by: \.tool
        )

        for name in MCPTools.extensionAuthoringTools {
            XCTAssertTrue(
                MCPTools.definitions.contains { $0.name == name },
                "\(name) is advertised but has no schema"
            )
            XCTAssertEqual(
                groupsByTool[name]?.map(\.group),
                [MCPToolCatalog.extensionAuthoring.id],
                "\(name) must belong only to the extension-authoring settings group"
            )
        }
    }

    func testAppThemeSchemaDescribesEverySemanticRole() throws {
        let schema = try schema(for: MCPTools.updateAppTheme)
        let input = try XCTUnwrap(schema["inputSchema"] as? [String: Any])
        let properties = try XCTUnwrap(input["properties"] as? [String: Any])
        let variants = try XCTUnwrap(properties["variants"] as? [String: Any])
        let variantProperties = try XCTUnwrap(variants["properties"] as? [String: Any])
        let dark = try XCTUnwrap(variantProperties["dark"] as? [String: Any])
        let darkProperties = try XCTUnwrap(dark["properties"] as? [String: Any])
        let roles = try XCTUnwrap(darkProperties["roles"] as? [String: Any])
        let palette = try XCTUnwrap(roles["properties"] as? [String: Any])

        XCTAssertEqual(
            Set(palette.keys),
            Set(AppThemeRole.allCases.map(\.wireName))
        )
    }

    func testAppThemeMaterialSchemaExposesDirectedShadows() throws {
        let schema = try schema(for: MCPTools.updateAppTheme)
        let input = try XCTUnwrap(schema["inputSchema"] as? [String: Any])
        let properties = try XCTUnwrap(input["properties"] as? [String: Any])
        let variants = try XCTUnwrap(properties["variants"] as? [String: Any])
        let variantProperties = try XCTUnwrap(variants["properties"] as? [String: Any])
        let light = try XCTUnwrap(variantProperties["light"] as? [String: Any])
        let lightProperties = try XCTUnwrap(light["properties"] as? [String: Any])
        let material = try XCTUnwrap(lightProperties["material"] as? [String: Any])
        let materialProperties = try XCTUnwrap(material["properties"] as? [String: Any])
        let glow = try XCTUnwrap(materialProperties["glow"] as? [String: Any])
        let glowProperties = try XCTUnwrap(glow["properties"] as? [String: Any])

        XCTAssertNotNil(glowProperties["offset_x"])
        XCTAssertNotNil(glowProperties["offset_y"])

        // A theme states a typeface as plainly as it states a palette, so the vocabulary an
        // agent reads has to offer both — and the named family beside them, for a theme whose
        // identity is a particular face rather than one of the four classes.
        XCTAssertNotNil(materialProperties["typeface"])
        XCTAssertNotNil(materialProperties["text_scale"])
        XCTAssertNotNil(materialProperties["font_family"])
        XCTAssertNotNil(materialProperties["remove_font_family"])
        XCTAssertNil(materialProperties["fontFamily"], "the wire vocabulary is snake_case")

        // The accepted values travel in the description: an agent reading a style brief that
        // says "sans-serif" has no other way to learn this vocabulary calls it "default".
        let typeface = try XCTUnwrap(materialProperties["typeface"] as? [String: Any])
        let description = try XCTUnwrap(typeface["description"] as? String)
        for value in AppTheme.Material.Typeface.allCases {
            XCTAssertTrue(
                description.contains("\"\(value.rawValue)\""),
                "the typeface description does not name \(value.rawValue)"
            )
        }
    }

    func testMaterialPatchDecodesTypefaceAndFamily() throws {
        let call = try call("""
            {
              "name": "update_app_theme",
              "arguments": {
                "theme_id": "custom-violet",
                "variants": {
                  "light": {"material": {"text_scale": 0.85, "typeface": "serif", "font_family": "Baskerville"}}
                }
              }
            }
            """)

        guard case .updateAppTheme(let arguments) = call else {
            return XCTFail("decoded as \(call.name)")
        }
        let material = try XCTUnwrap(arguments.variants?["light"]?.material)
        XCTAssertEqual(material.typeface, "serif")
        XCTAssertEqual(material.fontFamily, "Baskerville")
        XCTAssertEqual(material.textScale, 0.85)
    }

    /// `get_app_theme` reports the typeface it is actually set in, so an agent asked to make a
    /// theme "a bit more formal" can read what it is starting from rather than guessing.
    func testGetAppThemeReportsTheTypeface() throws {
        let get = coordinator().getAppTheme(AppThemeReferenceArguments(themeID: "newsprint"))
        XCTAssertFalse(get.isError, get.text)
        let document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(get.text.utf8)) as? [String: Any]
        )
        let variants = try XCTUnwrap(document["variants"] as? [String: Any])
        let light = try XCTUnwrap(variants["light"] as? [String: Any])
        let material = try XCTUnwrap(light["material"] as? [String: Any])
        XCTAssertEqual(
            material["typeface"] as? String, "serif",
            "Newsprint is a serif brief and the document should say so"
        )
    }

    func testAppThemeSchemaMakesOptionalVariantsAndAdaptiveAppearanceExplicit() throws {
        let schema = try schema(for: MCPTools.createAppTheme)
        let input = try XCTUnwrap(schema["inputSchema"] as? [String: Any])
        let properties = try XCTUnwrap(input["properties"] as? [String: Any])
        let variants = try XCTUnwrap(properties["variants"] as? [String: Any])
        let variantProperties = try XCTUnwrap(variants["properties"] as? [String: Any])

        XCTAssertNotNil(properties["appearance"])
        XCTAssertNil(properties["mode"])
        XCTAssertEqual(Set(variantProperties.keys), ["light", "dark"])
        XCTAssertTrue(
            (try XCTUnwrap(properties["appearance"] as? [String: Any])["description"] as? String)?
                .contains("Adaptive requires both variants") == true
        )
    }

    func testAgentInstructionsStateOnlyTheAppThemeBoundaries() throws {
        let update = try XCTUnwrap(
            MCPTools.definitions.first { $0.name == MCPTools.updateAppTheme }
        )

        XCTAssertTrue(update.description.contains("Built-in themes are immutable"))
        XCTAssertTrue(MCPToolCatalog.appearance.instruction.contains("separate from terminal themes"))
        XCTAssertTrue(MCPToolCatalog.appearance.instruction.contains("merge only the supplied values"))
        XCTAssertFalse(MCPToolCatalog.appearance.instruction.contains("duplicate_app_theme first"))
    }

    /// The palette is generated from `ThemeColorKey`, so a colour added to the model cannot be
    /// left out of the schema an agent reads.
    func testCreateThemeSchemaDescribesEveryColour() throws {
        let schema = try schema(for: MCPTools.createTheme)
        let input = try XCTUnwrap(schema["inputSchema"] as? [String: Any])
        let properties = try XCTUnwrap(input["properties"] as? [String: Any])
        let colors = try XCTUnwrap(properties["colors"] as? [String: Any])

        XCTAssertEqual(colors["type"] as? String, "object")

        let palette = try XCTUnwrap(colors["properties"] as? [String: Any])
        XCTAssertEqual(
            Set(palette.keys),
            Set(ThemeColorKey.allCases.map(\.wireName))
        )
    }

    /// A scalar property is unchanged by the object case existing — no stray `properties` key
    /// in a schema that has no members.
    func testScalarPropertiesCarryNoNestedProperties() throws {
        let schema = try schema(for: MCPTools.setTheme)
        let input = try XCTUnwrap(schema["inputSchema"] as? [String: Any])
        let properties = try XCTUnwrap(input["properties"] as? [String: Any])
        let theme = try XCTUnwrap(properties["theme_id"] as? [String: Any])

        XCTAssertEqual(theme["type"] as? String, "string")
        XCTAssertNil(theme["properties"])
    }

    func testTerminalThemeSchemasAdvertiseIDsNotLegacyNames() throws {
        let setSchema = try schema(for: MCPTools.setTheme)
        let setInput = try XCTUnwrap(setSchema["inputSchema"] as? [String: Any])
        let setProperties = try XCTUnwrap(setInput["properties"] as? [String: Any])
        XCTAssertNotNil(setProperties["theme_id"])
        XCTAssertNil(setProperties["theme"])

        let createSchema = try schema(for: MCPTools.createTheme)
        let createInput = try XCTUnwrap(createSchema["inputSchema"] as? [String: Any])
        let createProperties = try XCTUnwrap(createInput["properties"] as? [String: Any])
        XCTAssertNotNil(createProperties["base_id"])
        XCTAssertNil(createProperties["base"])
    }

    /// Every scope the tool documents has to be one `ThemeScope` accepts, or the tool describes
    /// a value it then rejects.
    func testDocumentedScopesAreRealScopes() {
        for raw in ["session", "project", "global"] {
            XCTAssertNotNil(ThemeScope(rawValue: raw))
        }
        XCTAssertNil(ThemeScope(rawValue: "none"), "none is an apply target, not a scope")
    }
}
