import XCTest
@testable import ThinkingOrbs
@testable import Threading

/// The tint seam added to the ThinkingOrbs fork, and the wrapper that drives it
/// from the theme accent. The claim under test is a colour claim — "the ink is
/// the accent hue, not grey" — which no assertion about the drawing math can
/// make, so it is checked against rendered pixels, the same way the
/// conversation and git-review renders are.
@MainActor
final class ThinkingOrbTintTests: XCTestCase {

    // MARK: - Helpers

    private func render(_ view: NSView, size: CGFloat = 64) -> NSBitmapImageRep {
        view.frame = NSRect(x: 0, y: 0, width: size, height: size)
        view.layoutSubtreeIfNeeded()
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// The observer's debounce runs on an injected clock, so only the scan's own completion is
    /// real time — a directory read off the main actor and its hop back. One second was enough
    /// alone and marginal in a full run of the target, where it surfaced as "attachment
    /// resolution did not finish" and then as every assertion after it. This is a hang bound,
    /// not a measurement, so it can afford to be generous.
    private func waitForAttachmentScan(
        _ observer: TerminalAttachmentObserver,
        timeout: TimeInterval = 5
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while observer.isScanInFlight, Date() < deadline {
            RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(0.005)))
        }
        XCTAssertFalse(observer.isScanInFlight, "attachment resolution did not finish")
    }

    /// Every dot the orb actually painted (alpha above a floor), as sRGB.
    private func inkPixels(_ rep: NSBitmapImageRep) -> [NSColor] {
        var out: [NSColor] = []
        for y in stride(from: 0, to: rep.pixelsHigh, by: 1) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 1) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.15 else { continue }
                out.append(c)
            }
        }
        return out
    }

    // MARK: - The tint seam

    func testTintColoursTheInk() {
        let orb = ThinkingOrbView(state: .working, orbSize: .px64)
        orb.tint = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)

        let ink = inkPixels(render(orb))
        XCTAssertFalse(ink.isEmpty, "the orb painted nothing to sample")

        // A red tint must produce red-dominant ink: no green- or blue-dominant
        // dot can appear, and at least one clearly-red dot must.
        let reddest = ink.max { $0.redComponent < $1.redComponent }!
        XCTAssertGreaterThan(reddest.redComponent, 0.5)
        XCTAssertLessThan(reddest.greenComponent, 0.35)
        XCTAssertLessThan(reddest.blueComponent, 0.35)

        for c in ink {
            XCTAssertGreaterThanOrEqual(c.redComponent + 0.001, c.greenComponent, "green-dominant ink under a red tint")
            XCTAssertGreaterThanOrEqual(c.redComponent + 0.001, c.blueComponent, "blue-dominant ink under a red tint")
        }
    }

    /// Connecting is the one mode with stroked edges as well as dots. Both
    /// passes must travel through Threading's tint seam; grayscale lines over
    /// accent nodes would leak the dependency's palette into themed UI.
    func testConnectingTintsLinesAndDotsTogether() {
        let orb = ThinkingOrbView(state: .connecting, orbSize: .px64)
        orb.tint = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)

        let ink = inkPixels(render(orb))
        XCTAssertFalse(ink.isEmpty, "the connecting orb painted nothing to sample")
        for color in ink {
            XCTAssertGreaterThanOrEqual(
                color.redComponent + 0.001,
                color.greenComponent,
                "a connecting edge escaped the red tint"
            )
            XCTAssertGreaterThanOrEqual(
                color.redComponent + 0.001,
                color.blueComponent,
                "a connecting edge escaped the red tint"
            )
        }
    }

    /// The default (no tint) path must stay grayscale, so the mod is additive
    /// rather than a behaviour change for anyone not passing a tint.
    func testNilTintStaysGrayscale() {
        let orb = ThinkingOrbView(state: .working, orbSize: .px64, theme: .dark)
        orb.tint = nil

        let ink = inkPixels(render(orb))
        XCTAssertFalse(ink.isEmpty)

        for c in ink {
            XCTAssertEqual(c.redComponent, c.greenComponent, accuracy: 0.02, "grayscale ink drifted red/green")
            XCTAssertEqual(c.greenComponent, c.blueComponent, accuracy: 0.02, "grayscale ink drifted green/blue")
        }
    }

    // MARK: - Visual dump

    /// Writes orb PNGs for eyeballing when `THREADING_RENDER_OUT` points somewhere,
    /// and is a no-op otherwise — the same opt-in the conversation renders use.
    func testWriteRenderSamples() throws {
        guard let out = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] else {
            throw XCTSkip("set THREADING_RENDER_OUT to dump orb PNGs")
        }
        let dir = URL(fileURLWithPath: out)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let tints: [(String, CGColor)] = [
            ("cyberpunk", CGColor(srgbRed: 0.36, green: 0.98, blue: 0.55, alpha: 1)),
            ("swiss-red", CGColor(srgbRed: 0.86, green: 0.13, blue: 0.15, alpha: 1)),
            ("system-blue", CGColor(srgbRed: 0.0, green: 0.48, blue: 1.0, alpha: 1))
        ]
        for (name, tint) in tints {
            for theme in [(OrbTheme.light, "light"), (OrbTheme.dark, "dark")] {
                let orb = ThinkingOrbView(state: .working, orbSize: .px64, theme: theme.0)
                orb.tint = tint
                let rep = render(orb, size: 128)
                let png = rep.representation(using: .png, properties: [:])!
                try png.write(to: dir.appendingPathComponent("orb-\(name)-\(theme.1).png"))
            }
        }
    }

    // MARK: - The wrapper

    func testWrapperPaintsAccentTintedInk() {
        let orb = WorkingOrbView()

        let ink = inkPixels(render(orb))
        XCTAssertFalse(ink.isEmpty, "the wrapper drew no orb")

        // The wrapper tints from Design.Surface.accent. Whatever the ambient
        // accent is, the drawn ink must match its hue rather than being grey —
        // proving the wrapper wired a tint through at all.
        let accent = Design.Surface.accent.usingColorSpace(.sRGB)!
        let grey = abs(accent.redComponent - accent.greenComponent) < 0.02
            && abs(accent.greenComponent - accent.blueComponent) < 0.02
        guard !grey else {
            // A genuinely grey accent (some CI appearances) makes the hue
            // assertion vacuous; the non-empty draw above is the real check.
            return
        }

        let colouredInk = ink.contains { c in
            abs(c.redComponent - c.greenComponent) > 0.03 || abs(c.greenComponent - c.blueComponent) > 0.03
        }
        XCTAssertTrue(colouredInk, "wrapper ink is grey despite a coloured accent — tint not applied")
    }

    func testWrapperCanDisplayEveryVariant() {
        XCTAssertEqual(
            OrbState.allCases.map(\.rawValue),
            [
                "working", "searching", "solving", "listening", "connecting",
                "weaving", "composing", "breathing", "shaping"
            ],
            "the Swift port no longer matches upstream's nine-state contract"
        )
        XCTAssertEqual(
            OrbState.allCases.map { WorkingOrbView(state: $0).state },
            OrbState.allCases
        )
    }

    func testEveryVariantRendersAtBothTunedSizes() {
        for state in OrbState.allCases {
            for size in OrbSize.allCases {
                let orb = ThinkingOrbView(state: state, orbSize: size, theme: .dark)
                let side = CGFloat(size.rawValue)
                let ink = inkPixels(render(orb, size: side))
                XCTAssertFalse(
                    ink.isEmpty,
                    "\(state.rawValue) painted nothing at \(size.rawValue)pt"
                )
            }
        }
    }

    /// Hidden is not the same thing as off screen. The component gallery keeps all nine variants
    /// in one long document: none is hidden, but eight or nine of their 60 Hz draw loops are
    /// outside the clip view at any moment. The orb follows the clip and runs only after its own
    /// drawing area enters the viewport.
    func testOrbTreatsAClippedDrawingAreaAsOffscreen() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 2_000))
        scroll.documentView = document

        let orb = ThinkingOrbView(state: .working, orbSize: .px20)
        orb.frame = NSRect(x: 20, y: 1_600, width: 20, height: 20)
        document.addSubview(orb)
        scroll.layoutSubtreeIfNeeded()

        XCTAssertTrue(
            scroll.contentView.postsBoundsChangedNotifications,
            "the orb will not hear a scroll that moves it into or out of view"
        )
        XCTAssertFalse(orb.hasVisibleDrawingArea)

        scroll.contentView.scroll(to: NSPoint(x: 0, y: 1_500))
        scroll.reflectScrolledClipView(scroll.contentView)

        XCTAssertTrue(orb.hasVisibleDrawingArea)

        NotificationCenter.default.post(
            name: NSScrollView.willStartLiveScrollNotification,
            object: scroll
        )
        XCTAssertTrue(
            orb.isSuppressedForLiveScroll,
            "the visible orb kept its display link active during a scroll gesture"
        )

        NotificationCenter.default.post(
            name: NSScrollView.didEndLiveScrollNotification,
            object: scroll
        )
        XCTAssertFalse(
            orb.isSuppressedForLiveScroll,
            "the orb did not resume after scroll momentum ended"
        )
    }

    func testRandomVariantStaysStableUntilSelectedAgainAndDoesNotRepeat() {
        let orb = WorkingOrbView()

        orb.selectRandomVariant(choosingIndex: { _ in 0 })
        let first = orb.state
        XCTAssertEqual(first, .working)

        // The second candidate list excludes the current state. Choosing its
        // first entry therefore proves consecutive turns cannot repeat.
        orb.selectRandomVariant(choosingIndex: { _ in 0 })
        XCTAssertNotEqual(orb.state, first)
    }

    func testRandomVariantPoolContainsEveryUpstreamState() {
        var selected = Set<OrbState>()
        for index in OrbState.allCases.indices {
            let orb = WorkingOrbView()
            orb.selectRandomVariant(choosingIndex: { candidates in
                XCTAssertEqual(candidates, OrbState.allCases.indices)
                return index
            })
            selected.insert(orb.state)
        }
        XCTAssertEqual(selected, Set(OrbState.allCases))
    }

    func testEveryFixedOrbPreferenceSelectsItsMatchingVariant() {
        let orb = WorkingOrbView()

        for style in WorkingOrbStyle.allCases where style != .random {
            orb.prepareForWorking(style: style)
            XCTAssertEqual(orb.state.rawValue, style.rawValue)
        }
    }

    func testMotionPreferencesDefaultAndPersist() throws {
        let suiteName = "ThinkingOrbTintTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.workingOrbStyle, .random)
        XCTAssertEqual(settings.chatNameMorphStyle, .shapeMorph)

        settings.workingOrbStyle = .breathing
        settings.chatNameMorphStyle = .scramble
        XCTAssertEqual(settings.workingOrbStyle, .breathing)
        XCTAssertEqual(settings.chatNameMorphStyle, .scramble)
    }

    func testAttachmentDetectionDefaultsOnAndCanBeDisabledPerAgent() throws {
        let suiteName = "AttachmentDetectionSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        for kind in AgentKind.allCases {
            XCTAssertTrue(settings.detectsAttachmentReferences(for: kind))
        }

        settings.setAttachmentReferenceDetection(for: .claude, enabled: false)
        XCTAssertFalse(settings.detectsAttachmentReferences(for: .claude))
        for kind in AgentKind.allCases where kind != .claude {
            XCTAssertTrue(settings.detectsAttachmentReferences(for: kind))
        }

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertFalse(reloaded.detectsAttachmentReferences(for: .claude))
        for kind in AgentKind.allCases where kind != .claude {
            XCTAssertTrue(reloaded.detectsAttachmentReferences(for: kind))
        }

        reloaded.setAttachmentReferenceDetection(for: .codex, enabled: false)
        reloaded.setAttachmentReferenceDetection(for: .claude, enabled: true)
        XCTAssertTrue(reloaded.detectsAttachmentReferences(for: .claude))
        XCTAssertFalse(reloaded.detectsAttachmentReferences(for: .codex))
        XCTAssertTrue(reloaded.detectsAttachmentReferences(for: .grok))
        XCTAssertTrue(reloaded.detectsAttachmentReferences(for: .openCode))
    }

    func testTerminalAttachmentObserverStopsAndRestartsWithItsAgentSetting() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = root.appendingPathComponent("first.png")
        let second = root.appendingPathComponent("second.pdf")
        try Data("png".utf8).write(to: first)
        try Data("%PDF".utf8).write(to: second)

        let sessionID = SessionID()
        var isEnabled = false
        var renderedText = first.path
        let observer = TerminalAttachmentObserver(
            sessionID: sessionID,
            projectRoot: { root },
            currentDirectory: { root },
            text: { renderedText },
            isEnabled: { isEnabled }
        )

        observer.scanNow()
        XCTAssertEqual(SessionAttachmentStore.shared.attachments(for: sessionID), [])

        isEnabled = true
        observer.scanNow()
        waitForAttachmentScan(observer)
        XCTAssertEqual(
            SessionAttachmentStore.shared.attachments(for: sessionID).map(\.relativePath),
            ["first.png"]
        )

        isEnabled = false
        renderedText = second.path
        observer.scanNow()
        XCTAssertEqual(
            SessionAttachmentStore.shared.attachments(for: sessionID).map(\.relativePath),
            ["first.png"]
        )

        isEnabled = true
        observer.scanNow()
        waitForAttachmentScan(observer)
        XCTAssertEqual(
            SessionAttachmentStore.shared.attachments(for: sessionID).map(\.relativePath),
            ["second.pdf", "first.png"]
        )
    }

    /// The first sighting scans at once, and sustained output re-scans on a cap — waiting for
    /// quiet alone meant a path printed early in a long build surfaced only when the output
    /// finally stopped.
    func testBusyTerminalOutputStillScansOnTheFly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let early = root.appendingPathComponent("early.png")
        let late = root.appendingPathComponent("late.png")
        try Data("png".utf8).write(to: early)
        try Data("png".utf8).write(to: late)

        let sessionID = SessionID()
        var renderedText = early.path
        var clock = Date(timeIntervalSince1970: 1_750_000_000)
        let observer = TerminalAttachmentObserver(
            sessionID: sessionID,
            projectRoot: { root },
            currentDirectory: { root },
            text: { renderedText },
            now: { clock }
        )

        // Leading edge: the very first output scans without waiting for quiet.
        observer.noteOutput()
        waitForAttachmentScan(observer)
        XCTAssertEqual(
            SessionAttachmentStore.shared.attachments(for: sessionID).map(\.relativePath),
            ["early.png"]
        )

        // Moments later the debounce holds — nothing new is recorded synchronously.
        renderedText = late.path
        clock = clock.addingTimeInterval(0.1)
        observer.noteOutput()
        XCTAssertEqual(
            SessionAttachmentStore.shared.attachments(for: sessionID).map(\.relativePath),
            ["early.png"]
        )

        // Past the busy cap the stream is still running, and the scan happens anyway.
        clock = clock.addingTimeInterval(SessionAttachmentDefaults.terminalBusyScanInterval)
        observer.noteOutput()
        waitForAttachmentScan(observer)
        XCTAssertEqual(
            SessionAttachmentStore.shared.attachments(for: sessionID).map(\.relativePath),
            ["late.png", "early.png"]
        )
    }

    func testMorphingTitleAcceptsEverySelectableStyle() {
        let label = MorphingTitleLabel()
        label.setStringValue("Before", animated: false)

        for style in ChatNameMorphStyle.allCases {
            label.morphStyleOverride = style
            label.setStringValue("After \(style.displayName)", animated: true)
            XCTAssertEqual(label.morphStyleOverride, style)
            XCTAssertEqual(label.stringValue, "After \(style.displayName)")
        }
    }

    func testMotionPreferencesPageLaysOutWithinThemeBoundary() {
        let controller = MotionPreferencesViewController()
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 620, height: 680)
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertFalse(controller.view.hasAmbiguousLayout)
        XCTAssertEqual(ThemeBoundaryAudit.violations(in: controller.view), [])
    }
}
