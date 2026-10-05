import AppKit
import ThreadingExtensionKit
import XCTest
@testable import Threading

/// The theme's welcome on the new-session composer: which lines an arrival shows and how they
/// are set, the manager's brief left alone, a re-pick only when the theme's words change, the
/// on-the-minute re-render that runs only while the composer can be seen, where the scrims and
/// the extension plane are told the hero and the box are — and the composer itself, light and
/// dark, in every mark the theme may stand over the greeting.
@MainActor
final class ComposerWelcomeTests: HostedStoreTestCase {

    private enum Fixture {
        static let tall = NSSize(width: 900, height: 640)
        static let short = NSSize(width: 720, height: 300)
    }

    override func setUp() async throws {
        try await super.setUp()
        // Lines land at once rather than morphing, so a test reads what is up.
        Design.Motion.reduceMotionOverrideForTesting = true
    }

    /// Synchronous and self-free, so the hosted store's own asynchronous teardown runs after it
    /// without this class crossing an isolation boundary; XCTest calls it on the main thread.
    /// The theme goes back to the one the app launches into.
    override func tearDown() {
        MainActor.assumeIsolated {
            AppThemeLibrary.apply(AppThemeLibrary.defaultTheme)
            Design.Motion.reduceMotionOverrideForTesting = nil
            ThemeAssetStore.removeAll(for: ThemeWelcomeFixtures.themeID)
        }
        super.tearDown()
    }

    // MARK: - Picking

    /// A theme line is picked for the arrival and its tokens are filled from the moment.
    func testAThemeLineIsPickedAndRenderedAtTheMoment() throws {
        AppThemeLibrary.apply(try ThemeWelcomeFixtures.theme(ThemeWelcomeFixtures.words(
            greeting: [.init(
                text: "Good {daypart}, {user}.",
                when: .init(dayparts: [.evening])
            )],
            caption: [.init(text: "{time} on {weekday}")]
        )))
        let clock = ThemeWelcomeFixtures.Clock()
        let composer = makeComposer(clock)
        _ = host(composer)
        composer.show(projectID: nil)

        XCTAssertEqual(try greeting(in: composer).stringValue, "Good evening, Ada.")
        XCTAssertEqual(composer.welcomeCaption, "19:42 on Monday")
    }

    /// The app's own greeting joins a theme's pool as one candidate of weight 1 — so against
    /// one theme line of weight 3 it comes up about a quarter of the time — and only when asked.
    func testIncludeAppLinesAddsTheAppsGreetingAsOneCandidateOfWeightOne() {
        let context = ThemeWelcomeFixtures.context()
        let line = ThemeWelcome.Line(text: "Theme line.", weight: 3)
        let trials = 400
        var appPicks = 0
        for seed in 0..<UInt64(trials) {
            var generator = WelcomeSeededGenerator(state: seed)
            let pick = ComposerWelcome.pick(
                greeting: ThemeWelcome.Wording(lines: [line], includesAppLines: true),
                caption: nil,
                at: context,
                using: &generator
            )
            var replay = WelcomeSeededGenerator(state: seed)
            let appLine = ComposerGreeting.message(
                on: context.date,
                calendar: context.calendar,
                using: &replay
            )
            switch pick.greeting {
            case .app(let text):
                appPicks += 1
                XCTAssertEqual(text, appLine, "the app's candidate is the app's own greeting")
            case .theme(let picked):
                XCTAssertEqual(picked, line)
            }
        }
        XCTAssertEqual(Double(appPicks) / Double(trials), 0.25, accuracy: 0.07)

        for seed in 0..<UInt64(50) {
            var generator = WelcomeSeededGenerator(state: seed)
            let pick = ComposerWelcome.pick(
                greeting: ThemeWelcome.Wording(lines: [line]),
                caption: nil,
                at: context,
                using: &generator
            )
            XCTAssertEqual(pick.greeting, .theme(line), "without the flag the pool is the theme's")
        }
    }

    /// No eligible theme line is the app's greeting, and no eligible caption is no caption.
    func testNoEligibleThemeLineFallsBackToTheAppAndNoCaptionIsShown() throws {
        let context = ThemeWelcomeFixtures.context()
        var generator = WelcomeSeededGenerator(state: 11)
        let pick = ComposerWelcome.pick(
            greeting: ThemeWelcome.Wording(lines: [
                .init(text: "Morning!", when: .init(dayparts: [.morning])),
                .init(text: "In {project}.")
            ]),
            caption: ThemeWelcome.Wording(lines: [
                .init(text: "Weekend.", when: .init(weekdays: [.sat, .sun]))
            ]),
            at: context,
            using: &generator
        )
        XCTAssertEqual(pick.greeting, .app(pick.appGreeting), "an evening with no project")
        XCTAssertNil(pick.caption)

        AppThemeLibrary.apply(try ThemeWelcomeFixtures.theme(ThemeWelcomeFixtures.words(
            greeting: [.init(text: "Morning!", when: .init(dayparts: [.morning]))],
            caption: [.init(text: "Weekend.", when: .init(weekdays: [.sat, .sun]))]
        )))
        let composer = makeComposer(ThemeWelcomeFixtures.Clock())
        _ = host(composer)
        composer.show(projectID: nil)
        let candidates = ComposerGreeting.candidates(
            for: ThemeWelcomeFixtures.evening,
            calendar: ThemeWelcomeFixtures.calendar
        )
        XCTAssertTrue(
            Set(candidates.plain + candidates.daypart + candidates.special)
                .contains(try greeting(in: composer).stringValue),
            "the hero fell back to something other than the app's own greeting"
        )
        XCTAssertNil(composer.welcomeCaption)
    }

    /// A line naming the project waits for one.
    func testAProjectLineIsShownOnlyWithAProject() throws {
        AppThemeLibrary.apply(try ThemeWelcomeFixtures.theme(ThemeWelcomeFixtures.words(
            greeting: [.init(text: "Back to {project}.")]
        )))
        let composer = makeComposer(ThemeWelcomeFixtures.Clock())
        _ = host(composer)
        composer.show(projectID: nil)
        XCTAssertNotEqual(try greeting(in: composer).stringValue.prefix(8), "Back to ")

        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("threading-welcome-\(UUID().uuidString)")
            .appendingPathComponent("Voyager")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: folder))
        defer { ProjectStore.shared.removeProject(id: project.id) }

        composer.show(projectID: project.id)
        XCTAssertEqual(try greeting(in: composer).stringValue, "Back to Voyager.")
    }

    // MARK: - Style

    /// The theme's scale, weight, face and ink set the greeting; the caption is measured from
    /// the body the same way.
    func testTheGreetingAndCaptionAreSetInTheThemesTypeAndInk() throws {
        let red = NSColor(srgbRed: 0.9, green: 0.1, blue: 0.2, alpha: 1)
        AppThemeLibrary.apply(try ThemeWelcomeFixtures.theme(ThemeWelcome(
            greeting: ThemeWelcome.Wording(
                lines: [.init(text: "Hello.")],
                style: .init(scale: 1.5, weight: .bold, ink: .color(red), typeface: .monospaced)
            ),
            caption: ThemeWelcome.Wording(
                lines: [.init(text: "A caption.")],
                style: .init(scale: 1.2, typeface: .serif)
            )
        )))
        let composer = makeComposer(ThemeWelcomeFixtures.Clock())
        _ = host(composer)
        composer.show(projectID: nil)

        let greeting = try greeting(in: composer)
        let font = try XCTUnwrap(greeting.appliedRoleFont)
        XCTAssertEqual(greeting.recordedFontRoleForTesting, .welcomeGreeting)
        XCTAssertEqual(font.pointSize, Design.Typography.heading().pointSize * 1.5, accuracy: 0.01)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.monoSpace), "\(font)")
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold), "\(font)")
        let ink = try XCTUnwrap(
            descendants(of: greeting).compactMap { $0 as? MorphingTitleLabel }.first?.textColor
                .usingColorSpace(.sRGB)
        )
        XCTAssertEqual(ink.redComponent, 0.9, accuracy: 0.01)
        XCTAssertEqual(ink.greenComponent, 0.1, accuracy: 0.01)

        let caption = try caption(in: composer)
        let captionFont = try XCTUnwrap(caption.appliedRoleFont)
        XCTAssertEqual(caption.recordedFontRoleForTesting, .welcomeCaption)
        XCTAssertEqual(
            captionFont.pointSize,
            Design.Typography.body().pointSize * 1.2,
            accuracy: 0.01
        )
        XCTAssertNotEqual(
            captionFont.familyName,
            Design.Typography.body().familyName,
            "a serif caption kept the app's face"
        )
    }

    /// The manager's brief is the app's: its words, its heading, its ink, and no caption — and
    /// the chat's welcome comes back unchanged.
    func testTheManagersBriefIsLeftAlone() throws {
        AppThemeLibrary.apply(try ThemeWelcomeFixtures.theme(ThemeWelcome(
            greeting: ThemeWelcome.Wording(
                lines: [.init(text: "Welcome aboard.")],
                style: .init(scale: 1.6, ink: .role(.accent))
            ),
            caption: ThemeWelcome.Wording(lines: [.init(text: "Below the line.")])
        )))
        let composer = makeComposer(ThemeWelcomeFixtures.Clock())
        _ = host(composer)
        composer.show(projectID: nil)
        let greeting = try greeting(in: composer)
        XCTAssertEqual(greeting.stringValue, "Welcome aboard.")
        XCTAssertEqual(composer.welcomeCaption, "Below the line.")

        composer.presetManagerRole()
        XCTAssertEqual(greeting.stringValue, ComposerDefaults.managerGreeting)
        XCTAssertEqual(greeting.recordedFontRoleForTesting, .heading)
        XCTAssertEqual(greeting.appliedRoleFont, Design.Typography.heading())
        XCTAssertNil(composer.welcomeCaption, "the brief has no caption")
        let ink = try XCTUnwrap(
            descendants(of: greeting).compactMap { $0 as? MorphingTitleLabel }.first?.textColor
        )
        composer.view.effectiveAppearance.performAsCurrentDrawingAppearance {
            XCTAssertEqual(
                ink.usingColorSpace(.sRGB),
                Design.Text.label.usingColorSpace(.sRGB),
                "the brief took the theme's ink"
            )
        }

        composer.selectedRole = .chat
        composer.refreshChips()
        XCTAssertEqual(greeting.stringValue, "Welcome aboard.")
        XCTAssertEqual(greeting.recordedFontRoleForTesting, .welcomeGreeting)
        XCTAssertEqual(composer.welcomeCaption, "Below the line.")
    }

    // MARK: - Re-picking

    /// A theme whose words differ is a new pick; a theme change that leaves the words alone —
    /// a colour, a scrim — keeps the line without drawing again.
    func testTheWelcomeIsRepickedOnlyWhenTheThemesWordsChange() throws {
        AppThemeLibrary.apply(try ThemeWelcomeFixtures.theme(
            ThemeWelcomeFixtures.words(greeting: [.init(text: "Alpha.")])
        ))
        let clock = ThemeWelcomeFixtures.Clock()
        let composer = makeComposer(clock)
        _ = host(composer)
        composer.show(projectID: nil)
        let greeting = try greeting(in: composer)
        XCTAssertEqual(greeting.stringValue, "Alpha.")

        var beta = ThemeWelcomeFixtures.words(greeting: [.init(text: "Beta.")])
        AppThemeLibrary.apply(try ThemeWelcomeFixtures.theme(beta))
        XCTAssertEqual(greeting.stringValue, "Beta.", "a theme with other words is a new welcome")

        let draws = clock.draws
        beta.scrim = ThemeWelcome.Scrim(hero: 0.4)
        AppThemeLibrary.apply(try ThemeWelcomeFixtures.theme(beta))
        XCTAssertEqual(greeting.stringValue, "Beta.")
        XCTAssertEqual(clock.draws, draws, "the same words were picked again")

        AppThemeLibrary.apply(.system)
        XCTAssertNotEqual(greeting.stringValue, "Beta.", "leaving the theme kept its line")
        XCTAssertNil(composer.welcomeCaption)
    }

    // MARK: - The Clock

    /// A line reading the clock is set again on the minute — the next boundary, not sixty
    /// seconds on — and only while the composer can be seen.
    func testAClockLineIsRenderedAgainOnTheMinuteOnlyWhileShown() throws {
        AppThemeLibrary.apply(try ThemeWelcomeFixtures.theme(ThemeWelcomeFixtures.words(
            greeting: [.init(text: "It is {time}.")]
        )))
        let clock = ThemeWelcomeFixtures.Clock()
        let composer = makeComposer(clock)
        let window = window(for: composer)
        composer.show(projectID: nil)
        let greeting = try greeting(in: composer)
        XCTAssertEqual(greeting.stringValue, "It is 19:42.")
        XCTAssertTrue(composer.isWelcomeClockRunning)
        XCTAssertEqual(clock.pending.count, 1)
        XCTAssertEqual(
            clock.pending.first?.date,
            ThemeWelcomeFixtures.evening.addingTimeInterval(30),
            "the tick lands on the minute boundary"
        )

        clock.fireNext()
        XCTAssertEqual(greeting.stringValue, "It is 19:43.")
        XCTAssertEqual(clock.pending.count, 1, "one tick at a time")
        XCTAssertEqual(
            clock.pending.first?.date,
            ThemeWelcomeFixtures.evening.addingTimeInterval(90)
        )

        composer.view.isHidden = true
        XCTAssertFalse(composer.isWelcomeClockRunning, "a hidden composer keeps no timer")
        XCTAssertTrue(clock.pending.isEmpty)

        composer.view.isHidden = false
        XCTAssertTrue(composer.isWelcomeClockRunning)
        XCTAssertEqual(clock.pending.count, 1)

        window.contentView = NSView()
        XCTAssertFalse(composer.isWelcomeClockRunning, "a composer out of its window keeps none")
        XCTAssertTrue(clock.pending.isEmpty)
    }

    /// Words that do not read the clock — and the app's own greeting — hold no timer at all.
    func testNoTimerForWordsThatDoNotReadTheClock() throws {
        let clock = ThemeWelcomeFixtures.Clock()
        let composer = makeComposer(clock)
        _ = window(for: composer)
        composer.show(projectID: nil)
        XCTAssertFalse(composer.isWelcomeClockRunning, "the app's greeting reads no clock")

        AppThemeLibrary.apply(try ThemeWelcomeFixtures.theme(ThemeWelcomeFixtures.words(
            greeting: [.init(text: "Hello, {user}.")],
            caption: [.init(text: "{working} working")]
        )))
        XCTAssertEqual(try greeting(in: composer).stringValue, "Hello, Ada.")
        XCTAssertFalse(composer.isWelcomeClockRunning)
        XCTAssertTrue(clock.scheduled.isEmpty)

        AppThemeLibrary.apply(try ThemeWelcomeFixtures.theme(ThemeWelcomeFixtures.words(
            greeting: [.init(text: "Hello.")],
            caption: [.init(text: "{days_until:12-24} days to go")]
        )))
        XCTAssertEqual(composer.welcomeCaption, "80 days to go")
        XCTAssertTrue(composer.isWelcomeClockRunning, "a caption that reads the date ticks too")

        composer.presetManagerRole()
        XCTAssertFalse(composer.isWelcomeClockRunning, "a manager's brief reads no clock")
    }

    // MARK: - Regions

    /// The extension plane hears where the hero and the box are, in its own coordinates, and
    /// that the hero is gone when a short pane hides it. The scrims hear the same.
    func testThePlaneAndTheScrimsAreToldWhereTheHeroAndTheBoxAre() throws {
        AppThemeLibrary.apply(try ThemeWelcomeFixtures.theme(
            ThemeWelcomeFixtures.dressedWelcome(mark: .app)
        ))
        let composer = makeComposer(ThemeWelcomeFixtures.Clock())
        let host = host(composer)
        composer.show(projectID: nil)
        host.layoutSubtreeIfNeeded()

        let plane = try XCTUnwrap(composer.extensionBackdrop)
        let hero = try XCTUnwrap(try greeting(in: composer).superview)
        let box = composer.promptHandoffView
        let scrim = try XCTUnwrap(composer.view.subviews.compactMap { $0 as? ThemeWelcomeScrimView }.first)

        assertRect(plane.focus.primary, plane.convert(hero.bounds, from: hero), "hero")
        assertRect(plane.focus.secondary, plane.convert(box.bounds, from: box), "box")
        XCTAssertFalse(plane.focus.primary.isEmpty)
        assertRect(scrim.heroRegion, scrim.convert(hero.bounds, from: hero), "scrim hero")
        assertRect(scrim.promptRegion, scrim.convert(box.bounds, from: box), "scrim box")
        XCTAssertEqual(scrim.veils.count, 2)

        host.setFrameSize(Fixture.short)
        host.layoutSubtreeIfNeeded()
        composer.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(hero.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(plane.focus.primary, .zero, "a hidden hero is no region")
        XCTAssertEqual(scrim.heroRegion, .zero)
        assertRect(plane.focus.secondary, plane.convert(box.bounds, from: box), "short box")
        XCTAssertEqual(scrim.veils.count, 1, "only the box is veiled")
    }

    /// Bottom to top: the theme's backdrop (the root's own layer), the extension plane (still
    /// the root's first subview), the scrims, then everything the person reads.
    func testTheWelcomeStacksBeneathThePlaneAndTheScrimAboveIt() throws {
        AppThemeLibrary.apply(try ThemeWelcomeFixtures.theme(
            ThemeWelcomeFixtures.dressedWelcome(mark: .app)
        ))
        let composer = makeComposer(ThemeWelcomeFixtures.Clock())
        let host = host(composer)
        composer.show(projectID: nil)
        host.layoutSubtreeIfNeeded()

        let ground = try XCTUnwrap(composer.view as? ThemeWelcomeGroundView)
        XCTAssertTrue(ground.isDressed)
        XCTAssertEqual(ground.layer?.sublayers?.first?.name, ThemeWelcomeGroundView.layerName)
        XCTAssertTrue(composer.view.subviews.first === composer.extensionBackdrop)
        XCTAssertTrue(composer.view.subviews[1] is ThemeWelcomeScrimView)

        let point = composer.promptHandoffView.convert(
            NSPoint(
                x: composer.promptHandoffView.bounds.midX,
                y: composer.promptHandoffView.bounds.midY
            ),
            to: host
        )
        let hit = host.hitTest(point)
        XCTAssertTrue(
            hit?.isDescendant(of: composer.promptHandoffView) ?? false,
            "a veil took the box's click: \(String(describing: hit))"
        )
    }

    // MARK: - Facts

    /// A `{fact:KEY}` line shows the fact as the host words it, and a change to that fact
    /// renders the picked lines again on the next turn — once for a burst, never re-picked, and
    /// not at all for a change that cannot move what they read. When the value goes (stale or
    /// cleared) the greeting falls back to the app's and the caption leaves.
    func testAFactLineIsRenderedAgainWhenItsFactChangesAndNeverPickedAgain() throws {
        let status = ExtensionFactKey(id: "ci.status")
        let weather = ExtensionFactKey(id: "weather.summary", version: 2)
        AppThemeLibrary.apply(try ThemeWelcomeFixtures.theme(ThemeWelcomeFixtures.words(
            greeting: [.init(text: "CI is {fact:ci.status}.")],
            caption: [.init(text: "{fact:weather.summary@2} outside")]
        )))
        let facts = FactTable()
        facts.values[status] = .string("passing")
        facts.values[weather] = .string("Sunny")
        let turns = DeferredTurns()
        let clock = ThemeWelcomeFixtures.Clock()
        let composer = SessionComposerViewController(
            newSessionAccountHandle: { _ in .standard },
            welcomeEnvironment: clock.environment(
                fact: { key, project in facts.read(key, project) },
                nextTurn: { turns.pending.append($0) }
            )
        )
        _ = host(composer)
        composer.show(projectID: nil)
        let greeting = try greeting(in: composer)
        XCTAssertEqual(greeting.stringValue, "CI is passing.")
        XCTAssertEqual(composer.welcomeCaption, "Sunny outside")
        XCTAssertEqual(facts.askedProjects.last, .some(nil), "no project asks for the application's facts")
        XCTAssertFalse(composer.isWelcomeClockRunning, "a fact moves when it is published, not on the minute")
        let draws = clock.draws

        facts.values[status] = .string("failing")
        for _ in 0..<3 { post(.exact([ExtensionFactCell(subject: .application, key: status)])) }
        XCTAssertEqual(turns.pending.count, 1, "a burst of publications renders once")
        XCTAssertTrue(composer.isWelcomeFactRenderScheduled)
        XCTAssertEqual(greeting.stringValue, "CI is passing.", "nothing moves before its turn")
        turns.runAll()
        XCTAssertEqual(greeting.stringValue, "CI is failing.")
        XCTAssertEqual(clock.draws, draws, "rendered again, never picked again")

        post(.exact([ExtensionFactCell(subject: .application, key: .init(id: "other.reading"))]))
        XCTAssertTrue(turns.pending.isEmpty, "a fact these words do not read renders nothing")

        post(.exact([ExtensionFactCell(subject: .project("p"), key: ExtensionHostFactKey.projectBranch)]))
        XCTAssertEqual(turns.pending.count, 1, "a branch move may change where a key is looked up")
        turns.runAll()

        facts.values[status] = nil
        facts.values[weather] = nil
        post(.all)
        turns.runAll()
        XCTAssertFalse(greeting.stringValue.hasPrefix("CI is"), "a line whose fact went falls back")
        XCTAssertNil(composer.welcomeCaption)
        XCTAssertEqual(clock.draws, draws)
    }

    /// Words that read no fact ignore every fact change, and a composer for a project asks for
    /// that project's facts.
    func testWordsWithoutAFactIgnoreFactChangesAndAProjectAsksForItsOwn() throws {
        AppThemeLibrary.apply(try ThemeWelcomeFixtures.theme(ThemeWelcomeFixtures.words(
            greeting: [.init(text: "Hello, {user}.")]
        )))
        let facts = FactTable()
        let turns = DeferredTurns()
        let composer = SessionComposerViewController(
            newSessionAccountHandle: { _ in .standard },
            welcomeEnvironment: ThemeWelcomeFixtures.Clock().environment(
                fact: { key, project in facts.read(key, project) },
                nextTurn: { turns.pending.append($0) }
            )
        )
        _ = host(composer)
        composer.show(projectID: nil)
        post(.all)
        XCTAssertTrue(turns.pending.isEmpty)
        XCTAssertTrue(facts.askedProjects.isEmpty, "words that name no fact read no fact")

        AppThemeLibrary.apply(try ThemeWelcomeFixtures.theme(ThemeWelcomeFixtures.words(
            greeting: [.init(text: "{fact:ci.status} in {project}.")]
        )))
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("threading-welcome-\(UUID().uuidString)")
            .appendingPathComponent("Voyager")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: folder))
        defer { ProjectStore.shared.removeProject(id: project.id) }
        facts.values[.init(id: "ci.status")] = .boolean(true)
        composer.show(projectID: project.id)
        XCTAssertEqual(facts.askedProjects.last, .some(project.id))
        XCTAssertEqual(try greeting(in: composer).stringValue, "\(L10n.string("yes")) in Voyager.")
    }

    // MARK: - Renders

    /// The composer under a fully dressed welcome, light and dark, once per mark: a wash with a
    /// picture and snow, the veils, a styled greeting and caption read from a fixed evening, and
    /// the app's mark, the theme's logo, its mascot, or nothing. The PNGs land in
    /// `THREADING_RENDER_OUT` as `composer-welcome-<mark>-<appearance>.png`.
    func testRendersTheDressedWelcomeInEveryMark() throws {
        let directory = ThemeWelcomeFixtures.renderDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var written = 0
        for mark in [ThemeWelcome.Mark.app, .logo, .mascot, .hidden] {
            for (suffix, appearanceName) in [
                ("light", NSAppearance.Name.aqua),
                ("dark", NSAppearance.Name.darkAqua)
            ] {
                let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
                let kind: AppTheme.VariantKind = suffix == "dark" ? .dark : .light
                let picture = try XCTUnwrap(ThemeAssetStore.store(
                    imageData: try ThemeWelcomeFixtures.wallpaperPNG(),
                    for: ThemeWelcomeFixtures.themeID,
                    slot: .welcome,
                    variant: kind
                ))
                AppThemeLibrary.apply(try ThemeWelcomeFixtures.theme(
                    ThemeWelcomeFixtures.dressedWelcome(mark: mark, picture: picture),
                    logo: true,
                    mascot: true
                ))

                // Built, laid out and drawn inside one still-frame scope: an emitter's
                // particles never reach an offscreen capture, so the field draws its still.
                let (composer, renderHost, data) = ThemeParticleHold.withStillFrames {
                    () -> (SessionComposerViewController, NSView, Data?) in
                    let composer = makeComposer(ThemeWelcomeFixtures.Clock())
                    let renderHost = host(composer)
                    renderHost.appearance = appearance
                    AppThemeRefresh.repaint(renderHost)
                    composer.show(projectID: nil)
                    var data: Data?
                    appearance.performAsCurrentDrawingAppearance {
                        renderHost.layoutSubtreeIfNeeded()
                        composer.view.layoutSubtreeIfNeeded()
                        guard let rep = renderHost.bitmapImageRepForCachingDisplay(
                            in: renderHost.bounds
                        ) else { return }
                        renderHost.wantsLayer = true
                        renderHost.layer?.backgroundColor = AppThemePalette.current
                            .resolved(.ground, appearance: appearance).cgColor
                        renderHost.cacheDisplay(in: renderHost.bounds, to: rep)
                        data = rep.representation(using: .png, properties: [:])
                    }
                    return (composer, renderHost, data)
                }
                _ = renderHost

                let ground = try XCTUnwrap(composer.view as? ThemeWelcomeGroundView)
                XCTAssertTrue(ground.backdrop.showsGradient, "\(mark) \(suffix)")
                XCTAssertTrue(ground.backdrop.showsPicture, "\(mark) \(suffix): no picture")
                XCTAssertTrue(ground.backdrop.showsParticles, "\(mark) \(suffix): no snow")
                XCTAssertEqual(try greeting(in: composer).stringValue, "Good evening, Ada.")
                XCTAssertEqual(composer.welcomeCaption, "19:42 · 2 working, 1 waiting")
                let markView = try XCTUnwrap(
                    descendants(of: composer.view).compactMap { $0 as? ThemeWelcomeMarkView }.first
                )
                XCTAssertEqual(markView.shown, expectedShown(mark), "\(suffix)")
                if mark != .hidden {
                    XCTAssertEqual(markView.side, 64)
                }
                let scrim = try XCTUnwrap(
                    composer.view.subviews.compactMap { $0 as? ThemeWelcomeScrimView }.first
                )
                XCTAssertEqual(scrim.veils.count, 2, "\(mark) \(suffix): the veils are missing")
                try XCTUnwrap(data).write(to: directory.appendingPathComponent(
                    "composer-welcome-\(mark.rawValue)-\(suffix).png"
                ))
                written += 1
            }
        }
        XCTAssertEqual(written, 8)
    }

    // MARK: - Fixtures

    /// Stands in for the fact registry: what each key reads, and which project each read named.
    @MainActor
    private final class FactTable {
        var values: [ExtensionFactKey: ExtensionFactValue] = [:]
        private(set) var askedProjects: [ProjectID?] = []

        func read(_ key: ExtensionFactKey, _ project: ProjectID?) -> ExtensionFact? {
            askedProjects.append(project)
            return values[key].map {
                ExtensionFact(key: key, subject: .application, value: $0, observedAt: ThemeWelcomeFixtures.evening)
            }
        }
    }

    /// The deferred fact renders, run when the test says.
    @MainActor
    private final class DeferredTurns {
        var pending: [@MainActor @Sendable () -> Void] = []

        func runAll() {
            let work = pending
            pending.removeAll()
            work.forEach { $0() }
        }
    }

    private func post(_ change: ExtensionFactChange) {
        NotificationCenter.default.post(ExtensionFactsDidChange(change: change))
    }

    private func makeComposer(_ clock: ThemeWelcomeFixtures.Clock) -> SessionComposerViewController {
        SessionComposerViewController(
            newSessionAccountHandle: { _ in .standard },
            welcomeEnvironment: clock.environment()
        )
    }

    private func host(_ composer: SessionComposerViewController, size: NSSize = Fixture.tall) -> NSView {
        let host = NSView(frame: NSRect(origin: .zero, size: size))
        let view = composer.view
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
        return host
    }

    /// A real window, never ordered on screen: the composer is in one, so it can be seen as far
    /// as its own clock is concerned.
    private func window(for composer: SessionComposerViewController) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Fixture.tall),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = composer
        window.setContentSize(Fixture.tall)
        return window
    }

    private func greeting(in composer: SessionComposerViewController) throws -> MorphingMultilineTitleLabel {
        try XCTUnwrap(
            descendants(of: composer.view)
                .compactMap { $0 as? MorphingMultilineTitleLabel }
                .first { $0.accessibilityIdentifier() != "composer.session-start.caption" },
            "the composer's greeting is the morphing block"
        )
    }

    private func caption(in composer: SessionComposerViewController) throws -> MorphingMultilineTitleLabel {
        try XCTUnwrap(
            descendants(of: composer.view)
                .compactMap { $0 as? MorphingMultilineTitleLabel }
                .first { $0.accessibilityIdentifier() == "composer.session-start.caption" }
        )
    }

    private func expectedShown(_ mark: ThemeWelcome.Mark) -> ThemeWelcomeMarkView.Shown {
        switch mark {
        case .app: return .app
        case .logo: return .logo
        case .mascot: return .mascot
        case .hidden: return .hidden
        }
    }

    private func assertRect(
        _ actual: CGRect,
        _ expected: CGRect,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.5, label, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.5, label, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.5, label, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.5, label, file: file, line: line)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}
