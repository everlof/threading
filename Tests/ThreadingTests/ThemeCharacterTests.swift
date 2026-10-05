import AppKit
import XCTest
@testable import Threading

/// A theme with a character: its sprite library and the particles that draw from it, pictures
/// pinned to an edge, the sidebar mascot and the mood it follows, the moments it answers, the
/// words it speaks, its logo on the Dock — the model and wire forms, the gates, the renderers'
/// bounded cells, the mood edges, the presenter's cooldown, the tool loop and the preview.
@MainActor
final class ThemeCharacterTests: XCTestCase {

    private struct Snapshot {
        let theme: AppTheme
        let settings: DesignSettingsReading
    }

    private static var snapshots: [ObjectIdentifier: Snapshot] = [:]

    override func setUp() {
        super.setUp()
        let testID = ObjectIdentifier(self)
        MainActor.assumeIsolated {
            Self.snapshots[testID] = Snapshot(
                theme: AppThemeLibrary.current,
                settings: DesignSettings.current
            )
            DesignSettings.current = StubDesignSettings()
            Design.Motion.reduceMotionOverrideForTesting = false
            ThemeParticleHold.seenOverrideForTesting = true
        }
    }

    override func tearDown() {
        let testID = ObjectIdentifier(self)
        MainActor.assumeIsolated {
            guard let snapshot = Self.snapshots.removeValue(forKey: testID) else {
                preconditionFailure("theme character fixture was not installed")
            }
            ThemeParticleHold.seenOverrideForTesting = nil
            Design.Motion.reduceMotionOverrideForTesting = nil
            DesignSettings.current = snapshot.settings
            AppThemePalette.set(snapshot.theme)
            AppThemeLibrary.apply(snapshot.theme)
        }
        super.tearDown()
    }

    // MARK: - Fixtures

    /// A small opaque picture as PNG bytes — a sprite, a pose, a logo.
    private func png(width: CGFloat = 32, height: CGFloat = 32, color: NSColor = .white) throws -> Data {
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
            return true
        }
        return try XCTUnwrap(
            NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?
                .representation(using: .png, properties: [:])
        )
    }

    private func cgImage(width: Int = 32, height: Int = 32) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
        context.fillEllipse(in: CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    /// A stock adaptive variant with the given character blocks, for validation.
    private func variant(
        sprites: [ThemeSprite] = [],
        sidebar: SidebarStyle? = nil,
        moments: ThemeMoments? = nil,
        words: ThemeWords? = nil,
        transition: ThemeTransition? = nil
    ) throws -> AppTheme.Variant {
        let base = try XCTUnwrap(AppThemeStyles.threading.variant(.dark))
        return base
            .replacingSidebar(sidebar)
            .replacingTransition(transition)
            .replacingCharacter(sprites: sprites, moments: moments, words: words)
    }

    private func theme(_ variant: AppTheme.Variant) -> AppTheme {
        AppTheme(
            id: AppThemeID("custom-character-\(UUID().uuidString)"),
            name: "Character",
            mode: .dark,
            summary: nil,
            variants: [.dark: variant]
        )
    }

    private func assertRefused(
        _ variant: AppTheme.Variant,
        mentioning fragment: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try AppThemeEditing.validate(theme(variant)), file: file, line: line) {
            XCTAssertTrue(
                $0.localizedDescription.contains(fragment),
                "\($0.localizedDescription) should mention \(fragment)",
                file: file,
                line: line
            )
        }
    }

    private func mascot(_ poses: [ThemeMascotMood: ThemeMascot.Pose]) -> SidebarStyle {
        SidebarStyle(mascot: ThemeMascot(poses: poses))
    }

    // MARK: - Model

    func testCharacterBlocksRoundTripAndOlderDocumentsDecodeWithout() throws {
        let original = try variant(
            sprites: [ThemeSprite(name: "paw", asset: "dark-sprite-paw.png", tinted: false)],
            sidebar: SidebarStyle(
                background: ThemeBackdrop(image: .init(
                    asset: "dark-background.png",
                    mode: .fit,
                    opacity: 0.5,
                    alignment: .bottom
                )),
                brand: SidebarStyle.Brand(logo: .asset("dark-logo.png"), dockIcon: true),
                mascot: ThemeMascot(
                    poses: [
                        .idle: .init(asset: "dark-mascot-idle.png", motion: .breathe),
                        .celebrating: .init(
                            asset: "dark-mascot-celebrating.png",
                            motion: .hop,
                            every: 0.8,
                            particles: ThemeParticles(style: .confetti, sprites: ["paw"])
                        )
                    ],
                    size: 88,
                    placement: .leading
                )
            ),
            moments: ThemeMoments(moments: [
                .needsAttention: .init(particles: ThemeParticles(style: .sparkle), duration: 1.8),
                .turnFinished: .init(sound: "dark-sound-turn_finished.caf")
            ]),
            words: ThemeWords(working: ["Herding…"], composerPlaceholder: "Woof?")
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(AppTheme.Variant.self, from: data)
        // Colours travel as hex, so the document — not the in-memory floats — is what round-trips.
        XCTAssertEqual(try encoder.encode(decoded), data)
        XCTAssertEqual(decoded.sprites, original.sprites)
        XCTAssertEqual(decoded.moments, original.moments)
        XCTAssertEqual(decoded.words, original.words)
        XCTAssertEqual(decoded.sidebar?.mascot, original.sidebar?.mascot)
        XCTAssertEqual(decoded.sidebar?.mascot?.poses[.celebrating]?.particles?.sprites, ["paw"])
        XCTAssertEqual(decoded.sidebar?.background?.image?.alignment, .bottom)
        XCTAssertTrue(decoded.sidebar?.brand?.dockIcon == true)

        // A document written before any of it existed decodes to none of it.
        let plain = try XCTUnwrap(AppThemeStyles.threading.variant(.dark))
        let plainJSON = try XCTUnwrap(
            String(data: try JSONEncoder().encode(plain), encoding: .utf8)
        )
        for key in ["sprites", "moments", "words", "mascot", "dockIcon", "alignment"] {
            XCTAssertFalse(plainJSON.contains("\"\(key)\""), "\(key) is omitted when unstated")
        }
        let reread = try JSONDecoder().decode(AppTheme.Variant.self, from: Data(plainJSON.utf8))
        XCTAssertTrue(reread.sprites.isEmpty)
        XCTAssertNil(reread.moments)
        XCTAssertNil(reread.words)
    }

    func testEditsCarryTheCharacterBlocks() throws {
        let dressed = try variant(
            sprites: [ThemeSprite(name: "paw", asset: "a.png")],
            moments: ThemeMoments(moments: [.needsAttention: .init(sound: "s.caf")]),
            words: ThemeWords(working: ["Fetching…"])
        )
        let recoloured = dressed.replacing(roles: [.accent: .systemRed])
        XCTAssertEqual(recoloured.sprites, dressed.sprites)
        XCTAssertEqual(recoloured.moments, dressed.moments)
        XCTAssertEqual(recoloured.words, dressed.words)
        XCTAssertEqual(recoloured.replacingSidebar(nil).sprites, dressed.sprites)
    }

    // MARK: - Gates

    func testTheSpriteLibraryAndItsReferencesAreGated() throws {
        assertRefused(
            try variant(sprites: [ThemeSprite(name: "Paw Print", asset: "a.png")]),
            mentioning: "lowercase"
        )
        assertRefused(
            try variant(sprites: [
                ThemeSprite(name: "paw", asset: "a.png"),
                ThemeSprite(name: "paw", asset: "b.png")
            ]),
            mentioning: "twice"
        )
        assertRefused(
            try variant(transition: ThemeTransition(
                particles: ThemeParticles(style: .confetti, sprites: ["bone"])
            )),
            mentioning: "transition.particles.sprites"
        )
        assertRefused(
            try variant(
                sprites: [ThemeSprite(name: "paw", asset: "a.png")],
                transition: ThemeTransition(
                    particles: ThemeParticles(style: .confetti, shape: .dot, sprites: ["paw"])
                )
            ),
            mentioning: "both a shape and sprites"
        )
        XCTAssertNoThrow(try AppThemeEditing.validate(theme(try variant(
            sprites: [ThemeSprite(name: "paw", asset: "a.png")],
            transition: ThemeTransition(particles: ThemeParticles(style: .confetti, sprites: ["paw"]))
        ))))
    }

    func testTheMascotMomentsWordsAndDockIconAreGated() throws {
        assertRefused(
            try variant(sidebar: mascot([.working: .init(asset: "w.png")])),
            mentioning: "idle pose"
        )
        var tooBig = ThemeMascot(poses: [.idle: .init(asset: "i.png")])
        tooBig.size = 400
        assertRefused(try variant(sidebar: SidebarStyle(mascot: tooBig)), mentioning: "size")
        assertRefused(
            try variant(sidebar: mascot([.idle: .init(asset: "i.png", motion: .bob, every: 60)])),
            mentioning: "every"
        )
        assertRefused(
            try variant(moments: ThemeMoments(moments: [.turnFinished: .init()])),
            mentioning: "neither particles nor a sound"
        )
        assertRefused(
            try variant(words: ThemeWords(working: [String(repeating: "w", count: 40)])),
            mentioning: "words.working"
        )
        assertRefused(
            try variant(words: ThemeWords(composerPlaceholder: "two\nlines")),
            mentioning: "composer_placeholder"
        )
        assertRefused(
            try variant(words: ThemeWords(untitledSession: String(repeating: "n", count: 40))),
            mentioning: "untitled_session"
        )
        assertRefused(
            try variant(words: ThemeWords(untitledSession: "   ")),
            mentioning: "untitled_session"
        )
        assertRefused(
            try variant(sidebar: SidebarStyle(brand: SidebarStyle.Brand(logo: .mark, dockIcon: true))),
            mentioning: "logo_in_dock"
        )
        // An opaque well is painted over the region the mascot stands in.
        assertRefused(
            try variant(sidebar: SidebarStyle(
                navigatorWell: .init(fill: NSColor(hex: "#061321")!, bevel: .none),
                mascot: ThemeMascot(poses: [.idle: .init(asset: "i.png")])
            )),
            mentioning: "remove_navigator_well"
        )
    }

    // MARK: - Pinned Pictures

    func testABottomAlignedFitStandsOnTheRegionsFoot() throws {
        let tall = CGRect(x: 0, y: 0, width: 200, height: 800)
        let wide = CGSize(width: 400, height: 200)

        // Unflipped (y up): the foot is minY.
        let unflipped = try XCTUnwrap(ThemeImageAlignment.bottom.frame(
            for: wide, in: tall, mode: .fit, flipped: false
        ))
        XCTAssertEqual(unflipped, CGRect(x: 0, y: 0, width: 200, height: 100))

        // Flipped (y down): the foot is maxY.
        let flipped = try XCTUnwrap(ThemeImageAlignment.bottom.frame(
            for: wide, in: tall, mode: .fit, flipped: true
        ))
        XCTAssertEqual(flipped.maxY, tall.maxY)

        // A fill covers the region and keeps the stated edge.
        let fill = try XCTUnwrap(ThemeImageAlignment.topLeading.frame(
            for: wide, in: tall, mode: .fill, flipped: false
        ))
        XCTAssertEqual(fill.height, tall.height)
        XCTAssertEqual(fill.minX, tall.minX)
        XCTAssertEqual(fill.maxY, tall.maxY)

        // Leading follows the reading direction.
        let rtl = try XCTUnwrap(ThemeImageAlignment.leading.frame(
            for: CGSize(width: 100, height: 400),
            in: tall,
            mode: .fit,
            flipped: false,
            layoutDirection: .rightToLeft
        ))
        XCTAssertEqual(rtl.maxX, tall.maxX)

        XCTAssertNil(ThemeImageAlignment.center.frame(for: wide, in: tall, mode: .tile, flipped: false))
    }

    // MARK: - Sprites in the Renderer

    func testSpritesShareTheBlocksBudgetAcrossTheirCells() throws {
        let image = try cgImage()
        let tinted = ThemeParticleSprite(key: "t/paw", image: image, tinted: true)
        let ownColours = ThemeParticleSprite(key: "t/sheep", image: image, tinted: false)
        let particles = ThemeParticles(style: .confetti, sprites: ["paw", "sheep"])
        let inks: [NSColor] = [.white, .systemOrange]

        let pictures = ThemeParticleArtwork.cellPictures(
            particles: particles,
            colors: inks,
            sprites: [tinted, ownColours],
            points: 12,
            scale: 2
        )
        XCTAssertEqual(pictures.count, 3, "a tinted sprite per ink, a full-colour one once")
        XCTAssertTrue(pictures.allSatisfy { $0.image != nil })

        let emitter = CAEmitterLayer()
        ThemeParticleEmitter.configure(
            emitter,
            particles: particles,
            colors: inks,
            sprites: [tinted, ownColours],
            placement: .ambient,
            region: CGRect(x: 0, y: 0, width: 240, height: 600),
            scale: 2,
            rate: 30,
            opacity: 0.5,
            up: 1
        )
        let cells = try XCTUnwrap(emitter.emitterCells)
        XCTAssertEqual(cells.count, 3)
        XCTAssertEqual(cells.map(\.birthRate).reduce(0, +), 30, accuracy: 0.001)

        // A tinted raster is a white silhouette; the cell's colour does the rest.
        let raster = try XCTUnwrap(ThemeParticleArtwork.raster(tinted, points: 12, scale: 2))
        XCTAssertEqual(raster.width, 24)
    }

    func testAStillFrameStampsSprites() throws {
        let sprite = ThemeParticleSprite(key: "t/paw", image: try cgImage(), tinted: true)
        let tile = try XCTUnwrap(ThemeParticleStill.tile(
            particles: ThemeParticles(style: .snow, sprites: ["paw"], density: 1),
            colors: [.systemRed],
            sprites: [sprite],
            side: 120,
            scale: 1,
            opacity: 1
        ))
        let rep = NSBitmapImageRep(cgImage: tile)
        var coloured = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                if let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.3 { coloured += 1 }
            }
        }
        XCTAssertGreaterThan(coloured, 0, "the still frame draws the sprite, not nothing")
    }

    // MARK: - Mood

    func testTheMoodRanksCelebrationThenAttentionThenWork() {
        XCTAssertEqual(ThemeMascotMood.resolve(live: 0, working: 0, attention: 0, celebrating: false), .resting)
        XCTAssertEqual(ThemeMascotMood.resolve(live: 2, working: 0, attention: 0, celebrating: false), .idle)
        XCTAssertEqual(ThemeMascotMood.resolve(live: 2, working: 1, attention: 0, celebrating: false), .working)
        XCTAssertEqual(ThemeMascotMood.resolve(live: 2, working: 1, attention: 1, celebrating: false), .attention)
        XCTAssertEqual(ThemeMascotMood.resolve(live: 2, working: 1, attention: 1, celebrating: true), .celebrating)
    }

    func testAMoodWithoutAPoseBorrowsOne() {
        let idle = ThemeMascot.Pose(asset: "i.png")
        let working = ThemeMascot.Pose(asset: "w.png")
        let mascot = ThemeMascot(poses: [.idle: idle, .working: working])
        XCTAssertEqual(mascot.pose(for: .resting), idle)
        XCTAssertEqual(mascot.pose(for: .attention), working, "attention borrows working first")
        XCTAssertNil(mascot.pose(for: .celebrating), "no celebrating pose, no celebration")
        XCTAssertEqual(ThemeMascot(poses: [.idle: idle]).pose(for: .attention), idle)
    }

    private func snapshot(
        activity: SessionActivity,
        turn: SessionTurnState = .none,
        process: SessionProcessState = .ready,
        blocker: SessionRuntimeBlocker = .none
    ) -> SessionRuntimeSnapshot {
        SessionRuntimeSnapshot(
            process: process,
            turn: turn,
            continuation: .none,
            blocker: blocker,
            activity: activity,
            reportsOwnTurns: true
        )
    }

    func testOnlyAnAnsweredTurnIsAFinishAndOnlyANewWaitIsAttention() {
        let working = snapshot(activity: .working, turn: .inFlight(.reported))
        let finished = SessionRuntimeTransition(previous: working, current: snapshot(activity: .idle))
        XCTAssertTrue(AgentMoodMonitor.finishedTurn(finished, cause: .turnFinished))
        XCTAssertFalse(AgentMoodMonitor.finishedTurn(finished, cause: .turnInterrupted))
        XCTAssertFalse(AgentMoodMonitor.finishedTurn(finished, cause: .turnRefused))
        XCTAssertFalse(AgentMoodMonitor.finishedTurn(
            SessionRuntimeTransition(previous: working, current: snapshot(activity: .dormant, process: .dormant)),
            cause: .turnFinished
        ), "a process that exited did not answer")
        XCTAssertFalse(AgentMoodMonitor.finishedTurn(
            SessionRuntimeTransition(
                previous: working,
                current: snapshot(activity: .limitReached, blocker: .usageLimit)
            ),
            cause: nil
        ), "a limit is not an answer")

        let waiting = SessionRuntimeTransition(
            previous: working,
            current: snapshot(activity: .awaitingUser, blocker: .awaitingUser)
        )
        XCTAssertTrue(AgentMoodMonitor.startedWaiting(waiting))
        XCTAssertFalse(AgentMoodMonitor.startedWaiting(SessionRuntimeTransition(
            previous: waiting.current,
            current: waiting.current
        )), "still waiting is not a new wait")
    }

    func testTheMonitorCelebratesAFinishAndPostsTheMoment() {
        let monitor = AgentMoodMonitor()
        monitor.countsProvider = { .init(live: 1, working: 0, attention: 0) }
        monitor.refresh()
        XCTAssertEqual(monitor.mood, .idle)

        let heard = MomentLog()
        let token = NotificationCenter.default.observe(AgentMomentDidOccur.self) { event in
            heard.events.append(event.event)
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let working = snapshot(activity: .working, turn: .inFlight(.reported))
        monitor.runtimeDidChange(
            SessionRuntimeTransition(previous: working, current: snapshot(activity: .idle)),
            cause: .turnFinished,
            sessionID: SessionID()
        )
        XCTAssertEqual(monitor.mood, .celebrating)
        XCTAssertEqual(monitor.baseMood, .idle)
        XCTAssertEqual(heard.events, [.turnFinished])
    }

    // MARK: - Mascot View

    func testTheMascotShowsItsMoodsPoseAndLoopsOnlyWhileMotionIsAllowed() throws {
        let idleImage = NSImage(data: try png(width: 40, height: 30))!
        let workImage = NSImage(data: try png(width: 40, height: 30, color: .systemOrange))!
        let resolved = SidebarAppearance.Mascot(
            spec: ThemeMascot(poses: [
                .idle: .init(asset: "i.png", motion: .breathe),
                .working: .init(asset: "w.png", motion: .hop)
            ]),
            poses: [
                .idle: .init(spec: .init(asset: "i.png", motion: .breathe), image: idleImage, particles: nil),
                .working: .init(spec: .init(asset: "w.png", motion: .hop), image: workImage, particles: nil)
            ]
        )
        XCTAssertEqual(resolved.aspectRatio, 40.0 / 30.0, accuracy: 0.001)

        let figure = ThemeMascotView(frame: NSRect(x: 0, y: 0, width: 96, height: 72))
        figure.configure(resolved, mood: .resting, fallbackMood: .resting)
        figure.layoutSubtreeIfNeeded()
        figure.layout()
        XCTAssertEqual(figure.pose?.spec.asset, "i.png", "resting borrows idle")
        XCTAssertTrue(figure.isLooping)

        figure.setMood(.working, fallbackMood: .working)
        XCTAssertEqual(figure.pose?.spec.asset, "w.png")
        XCTAssertTrue(figure.isLooping)

        figure.setMood(.celebrating, fallbackMood: .working)
        XCTAssertEqual(figure.pose?.spec.asset, "w.png", "no celebrating pose: the base mood's")

        Design.Motion.reduceMotionOverrideForTesting = true
        figure.refreshParticleMotion()
        XCTAssertFalse(figure.isLooping, "Reduce Motion holds the pose still")
        figure.setMood(.idle, fallbackMood: .idle)
        XCTAssertEqual(figure.pose?.spec.asset, "i.png", "and still changes pose — that is state")
    }

    func testEveryLoopEndsWhereItBegan() {
        for motion in ThemeMascot.Motion.allCases {
            let frames = ThemeMascotView.frames(for: motion, height: 72, up: 1)
            XCTAssertTrue(CATransform3DIsIdentity(frames[0]), "\(motion) starts at rest")
            let last = frames[frames.count - 1]
            if motion == .spin {
                // A full turn is identity up to rounding.
                XCTAssertEqual(last.m11, 1, accuracy: 0.0001)
                XCTAssertEqual(last.m41, 0, accuracy: 0.0001)
                XCTAssertEqual(last.m42, 0, accuracy: 0.0001)
            } else {
                XCTAssertTrue(CATransform3DIsIdentity(last), "\(motion) ends at rest")
            }
        }
    }

    // MARK: - Moments

    func testAMomentPlaysOnceThenCoolsDown() throws {
        let stated = theme(try variant(moments: ThemeMoments(moments: [
            .needsAttention: .init(particles: ThemeParticles(style: .confetti))
        ])))
        AppThemePalette.set(stated)

        var clock: TimeInterval = 100
        let presenter = ThemeMomentPresenter()
        presenter.now = { clock }
        presenter.windowsProvider = { [] }
        presenter.isAppActive = { false }

        XCTAssertEqual(presenter.handle(.turnFinished), .nothingStated)
        XCTAssertEqual(presenter.handle(.needsAttention), .played(particles: false, sound: false))
        clock += 2
        XCTAssertEqual(presenter.handle(.needsAttention), .coolingDown)
        clock += ThemeMomentLimits.cooldown
        XCTAssertEqual(presenter.handle(.needsAttention), .played(particles: false, sound: false))

        AppThemePalette.set(AppTheme.system)
        presenter.resetCooldown()
        XCTAssertEqual(presenter.handle(.needsAttention), .noTheme)
    }

    func testAFinishedTurnIsAnsweredBySoundAlone() throws {
        XCTAssertFalse(ThemeMomentEvent.turnFinished.showsParticles)
        XCTAssertTrue(ThemeMomentEvent.needsAttention.showsParticles)

        let shower = ThemeParticles(style: .confetti)
        var moments = ThemeMoments(moments: [
            .turnFinished: .init(particles: shower, duration: 2, sound: "s.caf"),
            .needsAttention: .init(particles: shower, duration: 2)
        ])
        XCTAssertEqual(moments[.turnFinished], .init(sound: "s.caf"))
        XCTAssertEqual(moments[.needsAttention]?.particles, shower)
        moments[.turnFinished] = .init(particles: shower)
        XCTAssertNil(moments[.turnFinished], "a moment that was only a shower answers with nothing")

        // A document written while a finished turn could still shower loses it on read, and a
        // block that held nothing else reads as none.
        let particlesJSON = try XCTUnwrap(
            String(data: try JSONEncoder().encode(shower), encoding: .utf8)
        )
        let older = Data("""
            {"turn_finished":{"duration":1.6,"particles":\(particlesJSON),"sound":"t.caf"}}
            """.utf8)
        XCTAssertEqual(
            try JSONDecoder().decode(ThemeMoments.self, from: older)[.turnFinished],
            .init(sound: "t.caf")
        )
        let plain = try XCTUnwrap(AppThemeStyles.threading.variant(.dark))
        var document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any]
        )
        document["moments"] = ["turn_finished": [
            "duration": 1.6,
            "particles": try JSONSerialization.jsonObject(with: Data(particlesJSON.utf8))
        ]]
        let reread = try JSONDecoder().decode(
            AppTheme.Variant.self,
            from: JSONSerialization.data(withJSONObject: document)
        )
        XCTAssertNil(reread.moments)
    }

    func testAnAgentCannotGiveAFinishedTurnAShower() throws {
        let refused: [AppThemeMomentArguments] = [
            AppThemeMomentArguments(particles: AppThemeParticlesArguments(style: "confetti")),
            AppThemeMomentArguments(duration: 1.6)
        ]
        for patch in refused {
            XCTAssertThrowsError(try AppThemeToolParsing.moments(
                AppThemeMomentsArguments(turnFinished: patch),
                remove: nil,
                base: nil,
                themeID: AppThemeID("custom-character-\(UUID().uuidString)"),
                kind: .dark
            )) {
                XCTAssertTrue($0.localizedDescription.contains("takes a sound only"))
            }
        }

        // The schema never offers the fields the parser refuses.
        let tool = MCPTools.appVariantSchema
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(tool)) as? [String: Any]
        )
        let turnFinished = try XCTUnwrap(firstObject(named: "turn_finished", in: json))
        let attention = try XCTUnwrap(firstObject(named: "needs_attention", in: json))
        let offered = { (moment: [String: Any]) in
            Set(((moment["properties"] as? [String: Any]) ?? [:]).keys)
        }
        XCTAssertTrue(
            offered(turnFinished).isDisjoint(with: ["particles", "remove_particles", "duration"])
        )
        XCTAssertTrue(offered(turnFinished).contains("sound"))
        XCTAssertTrue(offered(attention).isSuperset(of: ["particles", "duration", "sound"]))
    }

    /// The first object stored under `name` anywhere in a decoded JSON tree.
    private func firstObject(named name: String, in node: Any) -> [String: Any]? {
        if let object = node as? [String: Any] {
            if let match = object[name] as? [String: Any] { return match }
            for value in object.values {
                if let match = firstObject(named: name, in: value) { return match }
            }
        } else if let array = node as? [Any] {
            for value in array {
                if let match = firstObject(named: name, in: value) { return match }
            }
        }
        return nil
    }

    // MARK: - Words

    func testTheThemesWorkingWordsReplaceTheBagAtOnce() {
        var cycle = WorkingWordCycle()
        _ = cycle.next(drawingFrom: WorkingWords.all)
        let themed = ["Herding…", "Fetching…"]
        let first = cycle.next(drawingFrom: themed)
        let second = cycle.next(drawingFrom: themed)
        XCTAssertTrue(themed.contains(first), "the very next word is the theme's")
        XCTAssertEqual(Set([first, second]), Set(themed), "every word before any repeats")
        XCTAssertTrue(WorkingWords.all.contains(cycle.next(drawingFrom: [])), "empty is the app's own")
    }

    func testThemeWordingFallsBackToTheAppsOwn() throws {
        let worded = theme(try variant(words: ThemeWords(
            working: ["  Herding…  ", ""],
            composerPlaceholder: "Where shall we herd today?"
        )))
        AppThemePalette.set(worded)
        XCTAssertEqual(ThemeWording.workingWords, ["Herding…"])
        XCTAssertEqual(ThemeWording.composerPlaceholder, "Where shall we herd today?")
        XCTAssertEqual(ComposerDefaults.invitation, "Where shall we herd today?")

        AppThemePalette.set(AppTheme.system)
        XCTAssertEqual(ThemeWording.workingWords, WorkingWords.all)
        XCTAssertNil(ThemeWording.composerPlaceholder)
        XCTAssertNil(ThemeWording.untitledSessionName)
        XCTAssertEqual(ComposerDefaults.invitation, ComposerDefaults.promptPlaceholder)
    }

    func testAnUnnamedSessionWearsTheThemesNameOnScreenOnly() throws {
        let worded = theme(try variant(words: ThemeWords(untitledSession: "  Unknown program ")))
        AppThemePalette.set(worded)
        defer { AppThemePalette.set(AppTheme.system) }

        let unnamed = AgentSession(kind: .claude, title: "")
        XCTAssertTrue(unnamed.isUnnamed)
        XCTAssertEqual(ThemeWording.untitledSessionName, "Unknown program")
        XCTAssertEqual(unnamed.presentedTitle, "Unknown program")
        XCTAssertEqual(
            unnamed.displayTitle, AgentDefaults.untitledSessionName,
            "the name a migration stores or a notification reads stays the app's own"
        )

        var named = AgentSession(kind: .claude, title: "Fix the login redirect")
        XCTAssertFalse(named.isUnnamed)
        XCTAssertEqual(named.presentedTitle, "Fix the login redirect")
        named.customTitle = "Mine"
        XCTAssertEqual(named.presentedTitle, "Mine")

        AppThemePalette.set(AppTheme.system)
        XCTAssertEqual(unnamed.presentedTitle, AgentDefaults.untitledSessionName)
    }

    func testTheThemesWordsReachTheIPhone() throws {
        let worded = theme(try variant(words: ThemeWords(
            working: ["Jacking in…", " "],
            composerPlaceholder: "Follow the white rabbit.",
            untitledSession: "Unknown program"
        )))
        let words = try XCTUnwrap(RemoteThemeBridge.appTheme(worded).words)
        XCTAssertEqual(words.working, ["Jacking in…"])
        XCTAssertEqual(words.composerPlaceholder, "Follow the white rabbit.")
        XCTAssertEqual(words.untitledSession, "Unknown program")
        XCTAssertNil(RemoteThemeBridge.appTheme(theme(try variant())).words, "silent theme sends none")
    }

    // MARK: - Tools

    private func coordinator() -> AgentToolCoordinator {
        AgentToolCoordinator(
            displayPaneController: DisplayPaneController(),
            visibleSessionID: { nil },
            setPaneVisible: { _ in },
            windowProvider: { nil }
        )
    }

    func testAgentCanGiveAThemeACharacterAndReadItBack() async throws {
        let name = "Character Tool Theme \(UUID().uuidString)"
        let picture = AppThemeImageArguments(path: nil, base64: try png().base64EncodedString())
        let variant = AppThemeVariantArguments(
            sidebar: AppThemeSidebarArguments(
                image: AppThemeSidebarImageArguments(
                    source: picture,
                    mode: "fit",
                    opacity: 0.4,
                    alignment: "bottom"
                ),
                logo: .image(picture),
                // Threading's own well would cover the mascot; an author removes it.
                removeNavigatorWell: true,
                mascot: AppThemeMascotArguments(
                    size: 64,
                    placement: "center",
                    poses: [
                        "idle": AppThemeMascotPoseArguments(source: picture, motion: "breathe"),
                        "working": AppThemeMascotPoseArguments(
                            source: picture,
                            motion: "hop",
                            particles: AppThemeParticlesArguments(style: "sparkle", sprites: ["paw"])
                        )
                    ]
                ),
                logoInDock: true
            ),
            transition: AppThemeTransitionArguments(
                particles: AppThemeParticlesArguments(style: "confetti", sprites: ["paw"])
            ),
            sprites: [AppThemeSpriteArguments(name: "paw", source: picture)],
            moments: AppThemeMomentsArguments(
                needsAttention: AppThemeMomentArguments(
                    particles: AppThemeParticlesArguments(style: "confetti", sprites: ["paw"]),
                    duration: 1.6
                )
            ),
            words: AppThemeWordsArguments(
                working: ["Herding…"],
                composerPlaceholder: "Woof?",
                untitledSession: "Fresh pup"
            )
        )
        let created = await coordinator().createAppTheme(CreateAppThemeArguments(
            name: name,
            baseID: AppThemeStyles.threading.id.rawValue,
            appearance: "dark",
            mode: nil,
            summary: nil,
            variants: ["dark": variant],
            roles: nil,
            material: nil,
            terminalColors: nil,
            apply: false
        ))
        XCTAssertFalse(created.isError, created.text)
        let stored = try XCTUnwrap(AppThemeLibrary.all.first { $0.name == name })
        defer {
            if let latest = AppThemeLibrary.theme(withID: stored.id) {
                _ = AppThemeLibrary.delete(latest)
            }
        }

        let dark = try XCTUnwrap(stored.variant(.dark))
        XCTAssertEqual(dark.sprites.map(\.name), ["paw"])
        XCTAssertTrue(ThemeAssetStore.assetExists(named: dark.sprites[0].asset, for: stored.id))
        XCTAssertEqual(dark.sidebar?.mascot?.poses.count, 2)
        XCTAssertEqual(dark.sidebar?.mascot?.placement, .center)
        XCTAssertEqual(dark.sidebar?.background?.image?.alignment, .bottom)
        XCTAssertEqual(dark.sidebar?.brand?.dockIcon, true)
        XCTAssertEqual(dark.moments?[.needsAttention]?.duration, 1.6)
        XCTAssertEqual(dark.words?.composerPlaceholder, "Woof?")
        XCTAssertEqual(dark.words?.untitledSession, "Fresh pup")

        let get = coordinator().getAppTheme(AppThemeReferenceArguments(themeID: stored.id.rawValue))
        let document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(get.text.utf8)) as? [String: Any]
        )
        let darkDocument = try XCTUnwrap(
            (document["variants"] as? [String: Any])?["dark"] as? [String: Any]
        )
        XCTAssertNotNil(darkDocument["sprites"])
        XCTAssertNotNil(darkDocument["moments"])
        XCTAssertNotNil(darkDocument["words"])
        let sidebar = try XCTUnwrap(darkDocument["sidebar"] as? [String: Any])
        XCTAssertEqual(sidebar["logo_in_dock"] as? Bool, true)
        let mascot = try XCTUnwrap(sidebar["mascot"] as? [String: Any])
        XCTAssertNotNil((mascot["poses"] as? [String: Any])?["working"])
        XCTAssertEqual((sidebar["image"] as? [String: Any])?["alignment"] as? String, "bottom")

        // Removing a sprite something still names is refused; the document stays as it was.
        let refused = await coordinator().updateAppTheme(UpdateAppThemeArguments(
            themeID: stored.id.rawValue,
            name: nil,
            appearance: nil,
            mode: nil,
            summary: nil,
            variants: ["dark": AppThemeVariantArguments(removeSprites: ["paw"])],
            roles: nil,
            material: nil,
            terminalColors: nil,
            apply: false
        ))
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.text.contains("sprites"), refused.text)

        // A patch restyles without re-uploading, and merges the rest.
        let updated = await coordinator().updateAppTheme(UpdateAppThemeArguments(
            themeID: stored.id.rawValue,
            name: nil,
            appearance: nil,
            mode: nil,
            summary: nil,
            variants: ["dark": AppThemeVariantArguments(
                sidebar: AppThemeSidebarArguments(
                    image: AppThemeSidebarImageArguments(alignment: "bottom_trailing"),
                    mascot: AppThemeMascotArguments(removePoses: ["working"])
                ),
                words: AppThemeWordsArguments(
                    removeComposerPlaceholder: true,
                    removeUntitledSession: true
                )
            )],
            roles: nil,
            material: nil,
            terminalColors: nil,
            apply: false
        ))
        XCTAssertFalse(updated.isError, updated.text)
        let after = try XCTUnwrap(AppThemeLibrary.theme(withID: stored.id)?.variant(.dark))
        XCTAssertEqual(after.sidebar?.background?.image?.alignment, .bottomTrailing)
        XCTAssertEqual(after.sidebar?.background?.image?.asset, dark.sidebar?.background?.image?.asset)
        XCTAssertEqual(after.sidebar?.mascot?.poses.keys.sorted { $0.rawValue < $1.rawValue }, [.idle])
        XCTAssertEqual(after.words?.working, ["Herding…"])
        XCTAssertNil(after.words?.composerPlaceholder)
        XCTAssertNil(after.words?.untitledSession)
        XCTAssertEqual(after.sprites.map(\.name), ["paw"], "an unnamed block is kept")
    }

    func testTheVariantSchemaDescribesTheCharacterBlocks() throws {
        let tool = MCPTools.appVariantSchema
        let json = try XCTUnwrap(String(data: try JSONEncoder().encode(tool), encoding: .utf8))
        for key in ["\"sprites\"", "\"moments\"", "\"turn_finished\"", "\"words\"", "\"mascot\"",
                    "\"logo_in_dock\"", "\"alignment\"", "\"celebrating\""] {
            XCTAssertTrue(json.contains(key), "\(key) is described")
        }
    }

    // MARK: - Preview

    func testThePreviewDrawsTheMascotInEveryMoodItStates() async throws {
        let name = "Character Preview \(UUID().uuidString)"
        let picture = AppThemeImageArguments(path: nil, base64: try png(color: .systemOrange).base64EncodedString())
        let created = await coordinator().createAppTheme(CreateAppThemeArguments(
            name: name,
            baseID: AppThemeStyles.threading.id.rawValue,
            appearance: "dark",
            mode: nil,
            summary: nil,
            variants: ["dark": AppThemeVariantArguments(
                sidebar: AppThemeSidebarArguments(
                    removeNavigatorWell: true,
                    mascot: AppThemeMascotArguments(poses: [
                        "idle": AppThemeMascotPoseArguments(source: picture),
                        "attention": AppThemeMascotPoseArguments(source: picture)
                    ])
                )
            )],
            roles: nil,
            material: nil,
            terminalColors: nil,
            apply: false
        ))
        XCTAssertFalse(created.isError, created.text)
        let stored = try XCTUnwrap(AppThemeLibrary.all.first { $0.name == name })
        defer {
            if let latest = AppThemeLibrary.theme(withID: stored.id) {
                _ = AppThemeLibrary.delete(latest)
            }
        }
        XCTAssertNotNil(AppThemePreviewService.render(stored, kinds: [.dark]))
    }
}

/// The moments a test heard, on the main actor the observer delivers on.
@MainActor
private final class MomentLog {
    var events: [ThemeMomentEvent] = []
}
