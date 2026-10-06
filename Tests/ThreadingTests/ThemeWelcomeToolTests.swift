import AppKit
@testable import Threading
import ThreadingExtensionKit
import XCTest

/// The welcome block as an agent and a package author meet it: the snake-case wire through
/// create, get and update, every refusal by field, the merge-and-remove idiom, the welcome
/// surviving edits that never mention it, its picture's slot, rollback, inspection and
/// duplication, the legibility advisory, the layer report and the schema.
@MainActor
final class ThemeWelcomeToolTests: XCTestCase {

    private var createdIDs: [AppThemeID] = []
    private var preservedThemeID: String?

    override func setUp() async throws {
        try await super.setUp()
        preservedThemeID = PreferenceStore.shared.string(forKey: "appThemeID")
    }

    override func tearDown() async throws {
        for id in createdIDs {
            if let theme = AppThemeLibrary.theme(withID: id) { _ = AppThemeLibrary.delete(theme) }
        }
        createdIDs = []
        ExtensionAppearanceRegistry.shared.replace(contributions: [])
        if let preservedThemeID {
            PreferenceStore.shared.set(preservedThemeID, forKey: "appThemeID")
        } else {
            PreferenceStore.shared.removeObject(forKey: "appThemeID")
        }
        try await super.tearDown()
    }

    // MARK: - Round trip

    func testAWelcomeIsCreatedReadBackAndUpdatedUnchangedFromItsOwnDocument() async throws {
        let picture = try Self.png(hex: "#202020")
        let (theme, report) = try await create(welcome: [
            "backdrop": [
                "gradient": [
                    "angle_degrees": 160,
                    "stops": [["color": "#000000", "position": 0], ["color": "#001A00", "position": 1]]
                ],
                "image": ["source": ["base64": picture.base64EncodedString()], "opacity": 0.3]
            ],
            "mark": "logo",
            "mark_size": 56,
            "greeting": [
                "lines": [
                    [
                        "text": "Wake up, {user}…",
                        "weight": 3,
                        "when": [
                            "dayparts": ["night"],
                            "hours": ["from": 22, "to": 4],
                            "weekdays": ["fri"],
                            "dates": [["from": "12-24", "to": "12-26"], ["from": "02-29"]],
                            "months": [12, 2]
                        ]
                    ],
                    ["text": "Follow the white rabbit."]
                ],
                "include_app_lines": true,
                "style": [
                    "scale": 1.4, "weight": "bold", "ink": "label",
                    "font_family": "Menlo", "typeface": "monospaced"
                ]
            ],
            "caption": [
                "lines": [["text": "{days_until:12-24} days to go"]],
                "style": ["ink": "#E0E0E0", "scale": 0.9]
            ],
            "scrim": ["hero": 0.4, "prompt": 0.6]
        ])
        XCTAssertTrue(report.contains("character: changed"), report)

        let welcome = try XCTUnwrap(theme.variant(.dark)?.welcome)
        XCTAssertEqual(welcome.mark, .logo)
        XCTAssertEqual(welcome.markSize, 56)
        XCTAssertEqual(welcome.scrim, .init(hero: 0.4, prompt: 0.6))
        let greeting = try XCTUnwrap(welcome.greeting)
        XCTAssertTrue(greeting.includesAppLines)
        XCTAssertEqual(greeting.lines.map(\.text), ["Wake up, {user}…", "Follow the white rabbit."])
        XCTAssertEqual(greeting.lines.map(\.weight), [3, 1])
        let when = try XCTUnwrap(greeting.lines.first?.when)
        XCTAssertEqual(when.dayparts, [.night])
        XCTAssertEqual(when.hours, .init(from: 22, to: 4))
        XCTAssertEqual(when.weekdays, [.fri])
        XCTAssertEqual(when.months, [12, 2])
        XCTAssertEqual(when.dates.map(\.from.wireValue), ["12-24", "02-29"])
        XCTAssertEqual(when.dates.map(\.to.wireValue), ["12-26", "02-29"], "a single day spans itself")
        XCTAssertEqual(greeting.style, .init(scale: 1.4, weight: .bold, ink: .role(.label),
                                             fontFamily: "Menlo", typeface: .monospaced))
        XCTAssertEqual(welcome.caption?.style?.ink?.wireValue, "#E0E0E0")
        XCTAssertFalse(welcome.caption?.includesAppLines ?? true)

        let asset = try XCTUnwrap(welcome.backdrop?.image?.asset)
        XCTAssertEqual(asset, ThemeAssetSlot.welcome.fileName(for: .dark))
        XCTAssertEqual(asset, "dark-welcome.png")
        XCTAssertNotNil(ThemeAssetStore.image(named: asset, for: theme.id), "the bytes are the theme's")
        XCTAssertNil(theme.variant(.dark)?.material.backdrop, "the material's slot is untouched")

        let document = try welcomeDocument(of: theme)
        XCTAssertEqual(document["mark"] as? String, "logo")
        XCTAssertEqual(document["mark_size"] as? Double, 56)
        let greetingDocument = try XCTUnwrap(document["greeting"] as? [String: Any])
        XCTAssertEqual(greetingDocument["include_app_lines"] as? Bool, true)
        let style = try XCTUnwrap(greetingDocument["style"] as? [String: Any])
        XCTAssertEqual(style["ink"] as? String, "label")
        XCTAssertEqual(style["font_family"] as? String, "Menlo")
        let captionDocument = try XCTUnwrap(document["caption"] as? [String: Any])
        XCTAssertNil(captionDocument["include_app_lines"], "a caption has no app lines to report")
        let image = try XCTUnwrap((document["backdrop"] as? [String: Any])?["image"] as? [String: Any])
        XCTAssertEqual(image["asset"] as? String, asset)

        // The document read back is a patch that changes nothing.
        let echoed = try await update(theme, welcome: document)
        XCTAssertEqual(echoed.variant(.dark)?.welcome, welcome)
    }

    // MARK: - Refusals

    func testEveryRefusalNamesItsField() async throws {
        let ground = try XCTUnwrap(
            AppThemeStyles.threading.resolved(.ground, appearance: NSAppearance(named: .darkAqua)!)
                .usingColorSpace(.sRGB)?.hexString
        )
        let line = ["text": "Hello"]
        let tooMany = Array(repeating: line, count: ThemeWelcomeLimits.maximumLines + 1)
        let manyDates = Array(repeating: ["from": "01-01"], count: ThemeWelcomeLimits.maximumDateSpans + 1)
        let refusals: [(String, [String: Any], String)] = [
            ("too many lines", ["greeting": ["lines": tooMany]], "at most \(ThemeWelcomeLimits.maximumLines) lines"),
            ("no text", ["greeting": ["lines": [["text": "  "]]]], "lines[0] needs text"),
            ("long text", ["greeting": ["lines": [["text": String(repeating: "a", count: 161)]]]],
             "1 to \(ThemeWelcomeLimits.maximumLineLength) characters"),
            ("unknown token", ["greeting": ["lines": [["text": "Hi {name}"]]]], "{name} is not a token"),
            ("token list", ["caption": ["lines": [["text": "Hi {name}"]]]], "{days_until:MM-DD}"),
            ("unterminated", ["greeting": ["lines": [["text": "Hi {user"]]]], "never closes"),
            ("stray brace", ["greeting": ["lines": [["text": "Hi }"]]]], "closes no token"),
            ("bad day", ["greeting": ["lines": [["text": "{days_until:13-40}"]]]], "needs a day written MM-DD"),
            ("fact list", ["caption": ["lines": [["text": "Hi {name}"]]]], "{fact:KEY}"),
            ("no fact key", ["greeting": ["lines": [["text": "CI {fact}"]]]], "needs a fact key, as {fact:KEY}"),
            ("bad fact key", ["greeting": ["lines": [["text": "CI {fact:CI.Status}"]]]],
             "{fact:CI.Status} needs a fact key: a lowercase letter, then"),
            ("bad fact version", ["greeting": ["lines": [["text": "CI {fact:ci.status@0}"]]]],
             "@VERSION (1–1000000; 1 when omitted)"),
            ("light weight", ["greeting": ["lines": [["text": "Hi", "weight": 0]]]], "weight must be 1–10"),
            ("heavy weight", ["greeting": ["lines": [["text": "Hi", "weight": 11]]]], "weight must be 1–10"),
            ("hour", ["greeting": ["lines": [["text": "Hi", "when": ["hours": ["from": 22, "to": 24]]]]]],
             "when.hours from and to must each be 0–23"),
            ("half hours", ["greeting": ["lines": [["text": "Hi", "when": ["hours": ["from": 22]]]]]],
             "needs both from and to"),
            ("date", ["greeting": ["lines": [["text": "Hi", "when": ["dates": [["from": "13-01"]]]]]]],
             "dates[0].from must be a day written MM-DD"),
            ("dates", ["greeting": ["lines": [["text": "Hi", "when": ["dates": manyDates]]]]],
             "at most \(ThemeWelcomeLimits.maximumDateSpans) spans"),
            ("month", ["greeting": ["lines": [["text": "Hi", "when": ["months": [13]]]]]], "months must each be 1–12"),
            ("daypart", ["greeting": ["lines": [["text": "Hi", "when": ["dayparts": ["noon"]]]]]], "\"noon\" is not one of"),
            ("weekday", ["greeting": ["lines": [["text": "Hi", "when": ["weekdays": ["funday"]]]]]], "\"funday\" is not one of"),
            ("mark", ["mark": "hologram"], "welcome.mark must be one of"),
            ("mark size", ["mark_size": 200], "welcome.mark_size must be 16–160 points"),
            ("scale", ["greeting": ["style": ["scale": 4]]], "welcome.greeting.style.scale must be 0.5–3"),
            ("type weight", ["greeting": ["style": ["weight": "black"]]], "welcome.greeting.style.weight must be one of"),
            ("ink word", ["greeting": ["style": ["ink": "sparkly"]]], "neither a theme role nor #RRGGBB"),
            ("missing family", ["caption": ["style": ["font_family": "No Such Family \(UUID())"]]],
             "add_app_theme_font"),
            ("typeface", ["greeting": ["style": ["typeface": "comic"]]], "welcome.greeting.style.typeface"),
            ("ink on ground", ["greeting": ["style": ["ink": ground]]], "welcome.greeting.style.ink"),
            ("caption ink on ground", ["caption": ["lines": [line], "style": ["ink": ground]]],
             "welcome.caption.style.ink"),
            ("greeting on a stop", ["backdrop": ["gradient": ["stops": [
                ["color": "#FFFFFF", "position": 0], ["color": "#000000", "position": 1]
            ]]], "greeting": ["style": ["ink": "#FFFFFF"]]], "welcome.greeting ink on the welcome gradient stop"),
            ("label on a stop", ["backdrop": ["gradient": ["stops": [
                ["color": "#FFFFFF", "position": 0], ["color": "#FFFFFF", "position": 1]
            ]]]], "text on the welcome gradient stop"),
            ("caption on a stop", ["backdrop": ["gradient": ["stops": [
                ["color": "#000000", "position": 0], ["color": "#000000", "position": 1]
            ]]], "caption": ["lines": [line], "style": ["ink": "#050505"]]],
             "welcome.caption ink on the welcome gradient stop"),
            ("picture opacity", ["backdrop": ["image": [
                "source": ["base64": try Self.png(hex: "#000000").base64EncodedString()], "opacity": 2
            ]]], "welcome.backdrop.image.opacity"),
            ("particle sprite", ["backdrop": ["particles": ["style": "snow", "sprites": ["paw"]]]],
             "welcome.backdrop.particles.sprites names \"paw\""),
            ("scrim", ["scrim": ["hero": 0.95]], "welcome.scrim.hero must be 0–0.9"),
            ("backdrop and remove", ["backdrop": ["remove_gradient": true], "remove_backdrop": true],
             "remove_backdrop in the same patch"),
            ("mark and remove", ["mark_size": 40, "remove_mark": true], "remove_mark in the same patch"),
            ("greeting and remove", ["greeting": ["lines": [line]], "remove_greeting": true],
             "remove_greeting in the same patch"),
            ("caption and remove", ["caption": ["lines": [line]], "remove_caption": true],
             "remove_caption in the same patch"),
            ("scrim and remove", ["scrim": ["hero": 0.2], "remove_scrim": true], "remove_scrim in the same patch"),
            ("style and remove", ["greeting": ["style": ["scale": 1], "remove_style": true]],
             "remove_style in the same patch"),
            ("inner backdrop remove", ["backdrop": ["remove": true, "gradient": ["stops": []]]],
             "welcome.backdrop cannot set fields and remove")
        ]
        for (label, welcome, fragment) in refusals {
            let name = "Refused \(label) \(UUID().uuidString)"
            let result = await coordinator().createAppTheme(try Self.createArguments(
                name: name, variant: ["welcome": welcome]
            ))
            XCTAssertTrue(result.isError, "\(label) was accepted")
            XCTAssertTrue(result.text.contains(fragment), "\(label): \(result.text)")
            XCTAssertNil(AppThemeLibrary.all.first { $0.name == name }, "\(label) left a theme behind")
        }

        let both = await coordinator().createAppTheme(try Self.createArguments(
            name: "Refused both \(UUID())",
            variant: ["welcome": ["mark": "none"], "remove_welcome": true]
        ))
        XCTAssertTrue(both.text.contains("welcome cannot be set and removed"), both.text)
    }

    /// The document gate itself, as a contributed package meets it with no tool in between.
    func testTheValidatorHoldsADocumentFromAnywhere() throws {
        let base = try XCTUnwrap(AppThemeStyles.threading.variant(.dark))
        func refusal(_ welcome: ThemeWelcome) -> String? {
            let theme = AppTheme(
                id: AppThemeID("custom-welcome-\(UUID().uuidString)"), name: "Welcome",
                mode: .dark, summary: nil, variants: [.dark: base.replacingWelcome(welcome)]
            )
            do {
                try AppThemeEditing.validate(theme)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        func wording(_ lines: [ThemeWelcome.Line], style: ThemeWelcome.TextStyle? = nil) -> ThemeWelcome {
            ThemeWelcome(greeting: .init(lines: lines, style: style))
        }

        XCTAssertNil(refusal(wording([.init(text: "Good {daypart}, {user}", weight: 10)])))
        XCTAssertNil(refusal(wording([.init(text: "CI {fact:ci.status}, {fact:weather.now@2} out")])),
                     "a fact line is held to the key's shape, never to a fact being published")
        let token = try XCTUnwrap(refusal(wording([.init(text: "{clock}")])))
        XCTAssertTrue(token.contains("welcome.greeting.lines[0].text: {clock} is not a token"), token)
        for name in ThemeWelcome.Template.Token.names {
            XCTAssertTrue(token.contains("{\(name)"), "the refusal lists \(name): \(token)")
        }
        XCTAssertNotNil(refusal(wording(Array(
            repeating: .init(text: "Hi"), count: ThemeWelcomeLimits.maximumLines + 1
        ))))
        XCTAssertNotNil(refusal(wording([.init(text: String(repeating: "x", count: 161))])))
        XCTAssertNotNil(refusal(wording([.init(text: "Hi", weight: 11)])))
        XCTAssertNotNil(refusal(wording([.init(text: "Hi", when: .init(months: [0]))])))
        XCTAssertNotNil(refusal(wording([.init(text: "Hi", when: .init(hours: .init(from: -1, to: 3)))])))
        XCTAssertNotNil(refusal(wording([.init(text: "Hi", when: .init(dates: [
            .init(from: .init(month: 2, day: 30), to: .init(month: 3, day: 1))
        ]))])), "a day built in code is checked too")
        XCTAssertNotNil(refusal(wording([.init(text: "Hi", when: .init(dates: Array(
            repeating: .init(from: .init(month: 1, day: 1), to: .init(month: 1, day: 2)),
            count: ThemeWelcomeLimits.maximumDateSpans + 1
        )))])))
        XCTAssertNotNil(refusal(wording([.init(text: "Hi")], style: .init(scale: 0.4))))
        XCTAssertNotNil(refusal(wording([.init(text: "Hi")], style: .init(
            fontFamily: String(repeating: "F", count: ThemeWelcomeLimits.maximumFontFamilyLength + 1)
        ))))
        XCTAssertNotNil(refusal(ThemeWelcome(markSize: 15)))
        XCTAssertNotNil(refusal(ThemeWelcome(markSize: .nan)))
        XCTAssertNotNil(refusal(ThemeWelcome(scrim: .init(prompt: -0.1))))
        XCTAssertNil(refusal(ThemeWelcome(mark: ThemeWelcome.Mark.hidden, markSize: 16,
                                          scrim: .init(hero: 0, prompt: 0.9))))
    }

    // MARK: - Merge and remove

    func testSubBlocksMergeAndEachRemoveGivesOneBack() async throws {
        let picture = try Self.png(hex: "#101010")
        var (theme, _) = try await create(welcome: [
            "backdrop": [
                "gradient": ["stops": [["color": "#000000", "position": 0], ["color": "#000000", "position": 1]]],
                "image": ["source": ["base64": picture.base64EncodedString()], "opacity": 0.2]
            ],
            "mark": "mascot", "mark_size": 64,
            "greeting": [
                "lines": [["text": "One"], ["text": "Two"]],
                "include_app_lines": true,
                "style": ["ink": "label", "weight": "bold"]
            ],
            "caption": ["lines": [["text": "Below"]]],
            "scrim": ["hero": 0.3, "prompt": 0.5]
        ])
        func welcome() throws -> ThemeWelcome { try XCTUnwrap(theme.variant(.dark)?.welcome) }

        theme = try await update(theme, welcome: ["greeting": ["style": ["weight": "light"]]])
        XCTAssertEqual(try welcome().greeting?.style, .init(weight: .light, ink: .role(.label)),
                       "a style field merges onto the stated style")
        XCTAssertEqual(try welcome().greeting?.lines.map(\.text), ["One", "Two"])

        theme = try await update(theme, welcome: ["greeting": ["lines": [["text": "Only"]]]])
        XCTAssertEqual(try welcome().greeting?.lines.map(\.text), ["Only"], "stated lines replace the list")
        XCTAssertEqual(try welcome().greeting?.includesAppLines, true, "an unstated flag is kept")

        theme = try await update(theme, welcome: ["caption": ["include_app_lines": true]])
        XCTAssertEqual(try welcome().caption?.includesAppLines, false, "a caption has no app lines")

        theme = try await update(theme, welcome: ["scrim": ["hero": 0.1]])
        XCTAssertEqual(try welcome().scrim, .init(hero: 0.1, prompt: 0.5), "each veil merges")

        theme = try await update(theme, welcome: ["backdrop": ["remove_image": true]])
        XCTAssertNil(try welcome().backdrop?.image)
        XCTAssertNotNil(try welcome().backdrop?.gradient, "the gradient stays")

        theme = try await update(theme, welcome: ["remove_caption": true, "remove_scrim": true])
        XCTAssertNil(try welcome().caption)
        XCTAssertNil(try welcome().scrim)
        XCTAssertNotNil(try welcome().greeting, "the greeting stays")

        theme = try await update(theme, welcome: ["remove_mark": true, "greeting": ["remove_style": true]])
        XCTAssertNil(try welcome().mark)
        XCTAssertNil(try welcome().markSize, "remove_mark returns the app's size too")
        XCTAssertNil(try welcome().greeting?.style)

        theme = try await update(theme, welcome: ["remove_backdrop": true])
        XCTAssertNil(try welcome().backdrop)

        theme = try await update(theme, variant: ["remove_welcome": true])
        XCTAssertNil(theme.variant(.dark)?.welcome)
    }

    // MARK: - Survival

    func testEditingAnythingElseKeepsTheWelcome() async throws {
        var (theme, _) = try await create(welcome: [
            "mark": "none",
            "greeting": ["lines": [["text": "Still here, {user}"]]]
        ])
        let welcome = try XCTUnwrap(theme.variant(.dark)?.welcome)

        theme = try await update(theme, variant: [
            "roles": ["accent": "#33CC66"],
            "words": ["composer_placeholder": "Speak"],
            "material": ["panel_radius": 6]
        ])
        XCTAssertEqual(theme.variant(.dark)?.welcome, welcome, "an update that never names it keeps it")

        let source = try XCTUnwrap(theme.variant(.dark))
        let rebuilt = AppThemeEditing.makeVariant(named: "Rebuilt", from: theme, kind: .dark,
                                                  roles: [.accent: .systemPink])
        XCTAssertEqual(rebuilt.welcome, source.welcome, "makeVariant inherits it by default")
        XCTAssertEqual(source.replacing(material: source.material).welcome, welcome)

        let copy = try AppThemeLibrary.duplicate(theme, name: "Welcome copy \(UUID())")
        createdIDs.append(copy.id)
        XCTAssertEqual(copy.variant(.dark)?.welcome, welcome, "a duplicate carries it")
    }

    func testARefusedUpdatePutsThePreviousPictureBack() async throws {
        let first = try Self.png(hex: "#203040")
        let (theme, _) = try await create(welcome: [
            "backdrop": ["image": ["source": ["base64": first.base64EncodedString()], "opacity": 0.2]]
        ])
        let asset = ThemeAssetSlot.welcome.fileName(for: .dark)
        let stored = try XCTUnwrap(ThemeAssetStore.pngData(named: asset, for: theme.id))

        let refused = await coordinator().updateAppTheme(try Self.updateArguments(theme, variant: [
            "welcome": [
                "backdrop": ["image": ["source": ["base64": try Self.png(hex: "#F0E0D0").base64EncodedString()]]],
                "greeting": ["style": ["scale": 9]]
            ]
        ]))
        XCTAssertTrue(refused.isError, refused.text)
        XCTAssertEqual(ThemeAssetStore.pngData(named: asset, for: theme.id), stored,
                       "the replaced picture is restored with the refused document")

        let copy = try AppThemeLibrary.duplicate(try XCTUnwrap(AppThemeLibrary.theme(withID: theme.id)),
                                                 name: "Pictured copy \(UUID())")
        createdIDs.append(copy.id)
        XCTAssertEqual(ThemeAssetStore.pngData(named: asset, for: copy.id), stored,
                       "a duplicate owns a copy of the picture")
    }

    func testAContributedPackageCarriesItsWelcomePictureIntoADuplicate() throws {
        let base = AppThemeStyles.newsprint
        let variants = base.variants.mapValues {
            $0.replacingWelcome(ThemeWelcome(
                backdrop: ThemeBackdrop(image: .init(asset: "Resources/welcome.png", opacity: 0.2)),
                greeting: .init(lines: [.init(text: "Extra, extra")])
            ))
        }
        let document = AppTheme(id: base.id, name: base.name, mode: base.mode,
                                summary: base.summary, variants: variants)
        let root = try Self.package(resources: [
            "Resources/press.json": try JSONEncoder().encode(document),
            "Resources/welcome.png": try Self.png(hex: "#EEEEEE")
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let contributed = try XCTUnwrap(try ExtensionBundleInspector.inspect(at: root).themes.first)
        XCTAssertNotNil(contributed.sidebarAssets["Resources/welcome.png"],
                        "the welcome picture is read at inspection")

        ExtensionAppearanceRegistry.shared.replace(contributions: [.init(
            extensionIdentifier: "com.example.press",
            extensionName: "Press",
            themes: [contributed.theme],
            fontURLs: [],
            sidebarAssets: [contributed.theme.id: contributed.sidebarAssets]
        )])
        let copy = try AppThemeLibrary.duplicate(contributed.theme, name: "Press copy \(UUID())")
        createdIDs.append(copy.id)
        for kind in copy.availableVariants {
            let asset = try XCTUnwrap(copy.variant(kind)?.welcome?.backdrop?.image?.asset)
            XCTAssertEqual(asset, ThemeAssetSlot.welcome.fileName(for: kind),
                           "the copy names the store's slot, not the package's path")
            XCTAssertNotNil(ThemeAssetStore.image(named: asset, for: copy.id))
        }

        let missing = try Self.package(resources: ["Resources/press.json": try JSONEncoder().encode(document)])
        defer { try? FileManager.default.removeItem(at: missing) }
        XCTAssertThrowsError(try ExtensionBundleInspector.inspect(at: missing)) { error in
            XCTAssertTrue("\(error)".contains("welcome.png"), "\(error)")
        }
    }

    // MARK: - Advisory, layers, schema

    func testABusyPictureIsReportedWithTheGreetingsInk() async throws {
        let (theme, report) = try await create(welcome: [
            "backdrop": ["image": [
                "source": ["base64": try Self.png(hex: "#FFFFFF").base64EncodedString()], "opacity": 1
            ]],
            "greeting": ["style": ["ink": "#F8F8F8"]]
        ])
        XCTAssertTrue(report.contains("dark.welcome.backdrop: labels reach"), report)

        let sample = try XCTUnwrap(ThemeImageLegibility.samples(for: theme, kinds: [.dark])
            .first { $0.region == .welcome })
        XCTAssertEqual(sample.label.r, Double(0xF8) / 255, accuracy: 0.001,
                       "measured with the greeting's ink, not the label")
    }

    func testTheWelcomeIsCharacter() throws {
        let base = try XCTUnwrap(AppThemeStyles.threading.variant(.dark))
        // `.logo` rather than `.none`: in an optional position `.none` is Optional's nil.
        let welcomed = base.replacingWelcome(ThemeWelcome(mark: .logo))
        XCTAssertTrue(AppThemeLayer.character.isStated(in: welcomed))
        XCTAssertFalse(AppThemeLayer.character.isUnchanged(from: base, to: welcomed))
        XCTAssertTrue(AppThemeLayer.material.isUnchanged(from: base, to: welcomed))

        let before = AppTheme(id: AppThemeID("custom-welcome-before"), name: "Before", mode: .dark,
                              summary: nil, variants: [.dark: base])
        let after = AppTheme(id: before.id, name: "Before", mode: .dark, summary: nil,
                             variants: [.dark: welcomed])
        let report = AppThemeLayerReport(theme: after, startingFrom: before, origin: .previous)
        XCTAssertEqual(report.states[.character], .changed)
        XCTAssertEqual(report.states[.chrome], AppThemeLayerReport(
            theme: before, startingFrom: before, origin: .previous
        ).states[.chrome])
    }

    func testTheSchemaDocumentsTheWelcomeFromItsLimits() throws {
        let entries = MCPTools.appThemeSchemaEntries
        func description(_ path: String) throws -> String {
            try XCTUnwrap(entries[path]?.description, path)
        }
        XCTAssertTrue(MCPTools.appVariantListingSchema["welcome"]?.description.contains("welcome") == true)
        XCTAssertNotNil(MCPTools.appVariantListingSchema["remove_welcome"])
        XCTAssertFalse(MCPTools.appThemeDocumentation(section: "welcome").isError)
        XCTAssertFalse(MCPTools.appThemeDocumentation(section: "welcome.greeting.lines.when.dates.from").isError)
        XCTAssertTrue(try description("welcome.mark_size").contains(ThemeLimitText.span(ThemeWelcomeLimits.markSides)))
        XCTAssertTrue(try description("welcome.greeting.lines.weight").contains(ThemeLimitText.span(ThemeWelcomeLimits.weights)))
        XCTAssertTrue(try description("welcome.greeting.lines.text").contains(ThemeWelcomeText.tokens))
        XCTAssertTrue(try description("welcome.greeting.lines").contains("\(ThemeWelcomeLimits.maximumLines)"))
        XCTAssertTrue(try description("welcome.scrim.hero").contains(ThemeLimitText.span(ThemeWelcomeLimits.scrimOpacities)))
        XCTAssertTrue(try description("welcome.greeting.style.scale").contains(ThemeLimitText.span(ThemeWelcomeLimits.greetingScales)))
        XCTAssertNotNil(entries["welcome.greeting.include_app_lines"])
        XCTAssertNil(entries["welcome.caption.include_app_lines"], "only the greeting has app lines")
        XCTAssertNotNil(entries["welcome.backdrop.image.source.base64"], "the backdrop speaks material.backdrop")
    }

    // MARK: - Helpers

    private func create(welcome: [String: Any]) async throws -> (AppTheme, String) {
        let name = "Welcome \(UUID().uuidString)"
        let result = await coordinator().createAppTheme(try Self.createArguments(
            name: name, variant: ["welcome": welcome]
        ))
        XCTAssertFalse(result.isError, result.text)
        let theme = try XCTUnwrap(AppThemeLibrary.all.first { $0.name == name }, result.text)
        createdIDs.append(theme.id)
        return (theme, result.text)
    }

    private func update(_ theme: AppTheme, welcome: [String: Any]) async throws -> AppTheme {
        try await update(theme, variant: ["welcome": welcome])
    }

    private func update(_ theme: AppTheme, variant: [String: Any]) async throws -> AppTheme {
        let result = await coordinator().updateAppTheme(try Self.updateArguments(theme, variant: variant))
        XCTAssertFalse(result.isError, result.text)
        return try XCTUnwrap(AppThemeLibrary.theme(withID: theme.id))
    }

    private func welcomeDocument(of theme: AppTheme) throws -> [String: Any] {
        let get = coordinator().getAppTheme(AppThemeReferenceArguments(themeID: theme.id.rawValue))
        XCTAssertFalse(get.isError, get.text)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(get.text.utf8)) as? [String: Any])
        let variants = try XCTUnwrap(document["variants"] as? [String: Any])
        let dark = try XCTUnwrap(variants["dark"] as? [String: Any])
        return try XCTUnwrap(dark["welcome"] as? [String: Any], "get_app_theme shows the block")
    }

    /// Decoded from JSON rather than built by hand: the snake-case keys are the contract.
    private static func createArguments(name: String, variant: [String: Any]) throws -> CreateAppThemeArguments {
        let object: [String: Any] = [
            "name": name,
            "base_id": AppThemeStyles.threading.id.rawValue,
            "appearance": "dark",
            "apply": false,
            "variants": ["dark": variant]
        ]
        return try JSONDecoder().decode(
            CreateAppThemeArguments.self, from: JSONSerialization.data(withJSONObject: object)
        )
    }

    private static func updateArguments(_ theme: AppTheme, variant: [String: Any]) throws -> UpdateAppThemeArguments {
        let object: [String: Any] = [
            "theme_id": theme.id.rawValue,
            "apply": false,
            "variants": ["dark": variant]
        ]
        return try JSONDecoder().decode(
            UpdateAppThemeArguments.self, from: JSONSerialization.data(withJSONObject: object)
        )
    }

    private static func png(hex: String, side: Int = 16) throws -> Data {
        let color = try XCTUnwrap(NSColor(hex: hex))
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            color.setFill()
            rect.fill()
            return true
        }
        return try XCTUnwrap(
            NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?
                .representation(using: .png, properties: [:])
        )
    }

    /// An inspectable package contributing one theme document at `Resources/press.json`.
    private static func package(resources: [String: Data]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThreadingWelcomeTests-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let manifest = ExtensionManifest(
            identifier: "com.example.press",
            name: "Press",
            version: "0.1.0",
            runtime: .native,
            executable: "bin/extension",
            capabilities: [.themeProvider],
            themes: [.init(id: "press", resource: "Resources/press.json")]
        )
        try JSONEncoder().encode(manifest).write(
            to: root.appendingPathComponent(ExtensionBundleInspector.manifestName)
        )
        let executable = bin.appendingPathComponent("extension")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        for (path, data) in resources {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url)
        }
        return root
    }

    private func coordinator() -> AgentToolCoordinator {
        AgentToolCoordinator(
            displayPaneController: DisplayPaneController(),
            visibleSessionID: { nil },
            setPaneVisible: { _ in },
            windowProvider: { nil }
        )
    }
}
