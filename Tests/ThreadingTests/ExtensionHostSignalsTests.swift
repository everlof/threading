import AppKit
import Metal
import ThreadingExtensionKit
import XCTest
@testable import Threading

/// The live values a custom surface may bind to, and the promise that the SDK's list and the
/// host's answers cannot drift apart.
@MainActor
final class ExtensionHostSignalsTests: XCTestCase {

    private var previousIntensity: (() -> AgentIntensity)!
    private var previousUptime: (() -> TimeInterval)!
    private var previousNow: (() -> Date)!
    private var previousCalendar: (() -> Calendar)!
    private var previousUsage: (() -> Double?)!
    private var previousAudio: (() -> AudioSpectrum?)!
    private var previousTheme: (() -> AppTheme)!
    private var previousMoments: ((ThemeMomentEvent) -> TimeInterval?)!
    private var previousSettings: DesignSettingsReading!
    private var previousReduceMotion: Bool?
    private var previousStartMonitor: (@MainActor () -> Void)!

    override func setUp() async throws {
        try await super.setUp()
        previousIntensity = ExtensionHostSignals.intensity
        previousUptime = ExtensionHostSignals.uptime
        previousNow = ExtensionHostSignals.now
        previousCalendar = ExtensionHostSignals.calendar
        previousUsage = ExtensionHostSignals.activeAccountUsageRemaining
        previousAudio = ExtensionHostSignals.audio
        previousTheme = ExtensionHostSignals.theme
        previousMoments = ExtensionHostSignals.momentOccurredAt
        previousSettings = DesignSettings.current
        previousReduceMotion = Design.Motion.reduceMotionOverrideForTesting
        previousStartMonitor = ExtensionMomentSignalReader.shared.startMonitor
        // A test never starts the real mood monitor on the shared reader's behalf.
        ExtensionMomentSignalReader.shared.startMonitor = {}
    }

    override func tearDown() async throws {
        ExtensionHostSignals.intensity = previousIntensity
        ExtensionHostSignals.uptime = previousUptime
        ExtensionHostSignals.now = previousNow
        ExtensionHostSignals.calendar = previousCalendar
        ExtensionHostSignals.activeAccountUsageRemaining = previousUsage
        ExtensionHostSignals.audio = previousAudio
        ExtensionHostSignals.theme = previousTheme
        ExtensionHostSignals.momentOccurredAt = previousMoments
        DesignSettings.current = previousSettings
        Design.Motion.reduceMotionOverrideForTesting = previousReduceMotion
        ExtensionMomentSignalReader.shared.startMonitor = previousStartMonitor
        try await super.tearDown()
    }

    private func appearance(_ name: NSAppearance.Name) throws -> NSAppearance {
        try XCTUnwrap(NSAppearance(named: name))
    }

    private func context(_ appearance: NSAppearance) -> ExtensionHostSignalContext {
        ExtensionHostSignalContext(appearance: appearance)
    }

    private func reading(
        _ signal: ExtensionHostSignal,
        in appearance: NSAppearance
    ) throws -> Double {
        try XCTUnwrap(ExtensionHostSignals.value(signal, in: context(appearance)))
    }

    /// The sRGB components a theme role resolves to under `appearance`, read independently of
    /// the host's own cache.
    private func components(
        _ role: AppThemeRole,
        of theme: AppTheme,
        in appearance: NSAppearance
    ) throws -> [Double] {
        var color: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            color = theme.resolved(role, appearance: appearance).usingColorSpace(.sRGB)
        }
        let srgb = try XCTUnwrap(color)
        return [srgb.redComponent, srgb.greenComponent, srgb.blueComponent].map(Double.init)
    }

    /// Every signal the SDK names, this host answers — and nothing the SDK does not name.
    func testTheHostAnswersExactlyTheSignalsTheSDKNames() {
        XCTAssertEqual(ExtensionHostSignals.supported, Set(ExtensionHostSignal.all))
    }

    @MainActor
    func testWorkloadSignalsReadTheMonitorsEnvelope() {
        ExtensionHostSignals.intensity = {
            AgentIntensity(
                workload: AgentWorkload(workingCount: 3, anyAtTopEffort: false),
                recentActivity: 0.5,
                measuredAt: 100
            )
        }
        ExtensionHostSignals.uptime = { 100 }

        let intensity = try? XCTUnwrap(ExtensionHostSignals.value(.workloadIntensity))
        XCTAssertNotNil(intensity)
        XCTAssertGreaterThan(intensity ?? 0, 0)
        XCTAssertLessThanOrEqual(intensity ?? 2, 1)
        XCTAssertEqual(ExtensionHostSignals.value(.workloadWorkingCount), 3)

        ExtensionHostSignals.intensity = { .none }
        XCTAssertEqual(ExtensionHostSignals.value(.workloadIntensity), 0)
        XCTAssertEqual(ExtensionHostSignals.value(.workloadWorkingCount), 0)
    }

    @MainActor
    func testTheDayFractionFollowsTheUsersCalendar() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        ExtensionHostSignals.calendar = { calendar }

        ExtensionHostSignals.now = { Date(timeIntervalSince1970: 86_400 * 100 + 43_200) }
        XCTAssertEqual(ExtensionHostSignals.value(.timeOfDayFraction) ?? -1, 0.5, accuracy: 0.0001)

        ExtensionHostSignals.now = { Date(timeIntervalSince1970: 86_400 * 100) }
        XCTAssertEqual(ExtensionHostSignals.value(.timeOfDayFraction), 0)

        ExtensionHostSignals.now = { Date(timeIntervalSince1970: 86_400 * 101 - 1) }
        let almostMidnight = try XCTUnwrap(ExtensionHostSignals.value(.timeOfDayFraction))
        XCTAssertLessThan(almostMidnight, 1)
        XCTAssertGreaterThan(almostMidnight, 0.99)
    }

    @MainActor
    func testTheAccountSignalIsWhateverTheWindowInstalled() {
        ExtensionHostSignals.activeAccountUsageRemaining = { nil }
        XCTAssertNil(
            ExtensionHostSignals.value(.activeAccountUsageRemaining),
            "no window, no account: the surface falls back"
        )
        ExtensionHostSignals.activeAccountUsageRemaining = { 0.25 }
        XCTAssertEqual(ExtensionHostSignals.value(.activeAccountUsageRemaining), 0.25)
    }

    @MainActor
    func testAnUnknownSignalIsNilRatherThanAGuess() {
        XCTAssertNil(ExtensionHostSignals.value(ExtensionHostSignal(rawValue: "future.signal")))
    }

    // MARK: - Theme

    /// A fixed dark theme reads dark under either appearance and states its own ground; a
    /// fixed light theme the reverse; every component stays in `0...1`.
    func testThemeSignalsReadTheVariantInForceAndItsColours() throws {
        let aqua = try appearance(.aqua)
        let darkAqua = try appearance(.darkAqua)
        ExtensionHostSignals.theme = { AppThemeStyles.cyberpunk }
        XCTAssertEqual(try reading(.themeDark, in: aqua), 1)
        XCTAssertEqual(try reading(.themeDark, in: darkAqua), 1)
        // Cyberpunk's ground is #0A0A0F.
        XCTAssertEqual(try reading(.themeGroundRed, in: aqua), 10.0 / 255, accuracy: 0.002)
        XCTAssertEqual(try reading(.themeGroundGreen, in: aqua), 10.0 / 255, accuracy: 0.002)
        XCTAssertEqual(try reading(.themeGroundBlue, in: aqua), 15.0 / 255, accuracy: 0.002)
        let accent = try components(.accent, of: AppThemeStyles.cyberpunk, in: darkAqua)
        let accentSignals: [ExtensionHostSignal] = [
            .themeAccentRed, .themeAccentGreen, .themeAccentBlue
        ]
        for (signal, expected) in zip(accentSignals, accent) {
            XCTAssertEqual(try reading(signal, in: darkAqua), expected, accuracy: 0.002)
        }

        ExtensionHostSignals.theme = { AppThemeStyles.newsprint }
        XCTAssertEqual(try reading(.themeDark, in: darkAqua), 0)
        // Newsprint's ground is #F9F9F7.
        XCTAssertEqual(try reading(.themeGroundRed, in: darkAqua), 249.0 / 255, accuracy: 0.002)
        for signal in ExtensionHostSignal.themeSignals {
            XCTAssertTrue((0...1).contains(try reading(signal, in: aqua)), signal.rawValue)
        }
    }

    /// An adaptive theme answers each surface for the appearance that surface is drawn in.
    func testAnAdaptiveThemeAnswersEachAppearanceForItself() throws {
        let aqua = try appearance(.aqua)
        let darkAqua = try appearance(.darkAqua)
        let theme = AppThemeStyles.threading
        XCTAssertTrue(theme.isAdaptive)
        ExtensionHostSignals.theme = { theme }

        XCTAssertEqual(try reading(.themeDark, in: aqua), 0)
        XCTAssertEqual(try reading(.themeDark, in: darkAqua), 1)
        let light = try components(.ground, of: theme, in: aqua)
        let dark = try components(.ground, of: theme, in: darkAqua)
        XCTAssertNotEqual(light, dark, "the variants' grounds differ")
        XCTAssertEqual(try reading(.themeGroundRed, in: aqua), light[0], accuracy: 0.002)
        XCTAssertEqual(try reading(.themeGroundRed, in: darkAqua), dark[0], accuracy: 0.002)
        XCTAssertEqual(try reading(.themeGroundBlue, in: darkAqua), dark[2], accuracy: 0.002)
    }

    /// Readings are resolved once and answered from the cache until the theme changes; the
    /// app's own theme-change event is what drops them.
    func testThemeReadingsAreCachedUntilTheThemeChanges() throws {
        let aqua = try appearance(.aqua)
        var current = AppThemeStyles.newsprint
        ExtensionHostSignals.theme = { current }
        XCTAssertEqual(try reading(.themeDark, in: aqua), 0)

        current = AppThemeStyles.cyberpunk
        XCTAssertEqual(
            try reading(.themeDark, in: aqua),
            0,
            "a frame read does not re-resolve the theme"
        )

        NotificationCenter.default.post(AppThemeDidChange(themeID: current.id))
        XCTAssertEqual(try reading(.themeDark, in: aqua), 1)
    }

    /// The surface hands its own effective appearance to every read and follows it when it
    /// changes — the widening that lets an adaptive theme answer each window for itself.
    func testASurfaceReadsSignalsForItsOwnAppearance() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal is unavailable on this test host.")
        }
        ExtensionHostSignals.theme = { AppThemeStyles.threading }
        let surface = try ExtensionMetalSurfaceView(
            specification: ExtensionMetalSurface(
                shaderResource: "Resources/dark.metal",
                inputs: [.init(name: "dark", value: .signal(.themeDark, mapping: .identity))]
            ),
            source: Self.redFromFirstInput,
            signalProvider: { ExtensionHostSignals.value($0, in: $1) }
        )
        try await surface.waitForPreparation()
        let size = NSSize(width: 4, height: 4)

        surface.appearance = try appearance(.darkAqua)
        let dark = try XCTUnwrap(surface.snapshotImage(size: size, time: 0))
        XCTAssertEqual(try redComponent(of: dark), 1, accuracy: 0.02)

        surface.appearance = try appearance(.aqua)
        let light = try XCTUnwrap(surface.snapshotImage(size: size, time: 0))
        XCTAssertEqual(try redComponent(of: light), 0, accuracy: 0.02)
    }

    // MARK: - Moments

    /// One at the event, a smooth fall to zero over the SDK's duration, zero before and after.
    func testAMomentPulsesAndDecaysSmoothly() {
        let duration = ExtensionHostSignal.momentPulseDuration
        XCTAssertEqual(ExtensionHostSignals.momentPulse(since: nil, at: 10), 0)
        XCTAssertEqual(ExtensionHostSignals.momentPulse(since: 10, at: 10), 1)
        XCTAssertEqual(
            ExtensionHostSignals.momentPulse(since: 10, at: 10 + duration / 2),
            0.5,
            accuracy: 1e-9
        )
        XCTAssertEqual(ExtensionHostSignals.momentPulse(since: 10, at: 10 + duration), 0)
        XCTAssertEqual(ExtensionHostSignals.momentPulse(since: 10, at: 10 + duration * 4), 0)
        XCTAssertEqual(ExtensionHostSignals.momentPulse(since: 10, at: 9), 0)
        var previous = 1.0
        for step in 1...30 {
            let pulse = ExtensionHostSignals.momentPulse(
                since: 10,
                at: 10 + duration * Double(step) / 30
            )
            XCTAssertLessThanOrEqual(pulse, previous, "the pulse only falls")
            previous = pulse
        }

        ExtensionHostSignals.uptime = { 20 + duration / 2 }
        ExtensionHostSignals.momentOccurredAt = { $0 == .turnFinished ? 20 : nil }
        XCTAssertEqual(
            ExtensionHostSignals.value(.momentTurnFinished) ?? -1,
            0.5,
            accuracy: 1e-9
        )
        XCTAssertEqual(ExtensionHostSignals.value(.momentNeedsAttention), 0)
    }

    /// The reader listens — and starts the mood monitor — only while somebody wants moments,
    /// records each event on the uptime clock, and forgets them when the last one leaves.
    func testTheMomentReaderListensOnlyWhileWanted() {
        let reader = ExtensionMomentSignalReader()
        let starts = Counter()
        reader.startMonitor = { starts.count += 1 }
        ExtensionHostSignals.uptime = { 42 }

        NotificationCenter.default.post(
            AgentMomentDidOccur(event: .turnFinished, sessionID: SessionID())
        )
        XCTAssertFalse(reader.isListening)
        XCTAssertNil(reader.lastOccurrence(of: .turnFinished), "nobody asked yet")
        XCTAssertEqual(starts.count, 0)

        let first = UUID()
        let second = UUID()
        reader.setDemand(first, active: true)
        reader.setDemand(second, active: true)
        XCTAssertTrue(reader.isListening)
        XCTAssertEqual(starts.count, 1, "the monitor is started once, lazily")

        NotificationCenter.default.post(
            AgentMomentDidOccur(event: .needsAttention, sessionID: SessionID())
        )
        XCTAssertEqual(reader.lastOccurrence(of: .needsAttention), 42)
        XCTAssertNil(reader.lastOccurrence(of: .turnFinished))

        reader.setDemand(first, active: false)
        XCTAssertTrue(reader.isListening, "one surface still wants moments")
        reader.setDemand(second, active: false)
        XCTAssertFalse(reader.isListening)
        XCTAssertNil(reader.lastOccurrence(of: .needsAttention), "a stale event is forgotten")
    }

    /// A surface binding a moment holds the shared reader's interest exactly while it is
    /// mounted in a window; a surface binding none never asks.
    func testOnlyAMountedMomentSurfaceKeepsTheReaderListening() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal is unavailable on this test host.")
        }
        let reader = ExtensionMomentSignalReader.shared
        XCTAssertFalse(reader.isListening, "nothing in the test host binds a moment")
        let pulse = try ExtensionMetalSurfaceView(
            specification: ExtensionMetalSurface(
                shaderResource: "Resources/pulse.metal",
                inputs: [
                    .init(name: "pulse", value: .signal(.momentTurnFinished, mapping: .identity))
                ]
            ),
            source: Self.redFromFirstInput,
            signalProvider: { _, _ in nil }
        )
        try await pulse.waitForPreparation()
        let still = try ExtensionMetalSurfaceView(
            specification: ExtensionMetalSurface(
                shaderResource: "Resources/still.metal",
                inputs: [.init(name: "dark", value: .signal(.themeDark, mapping: .identity))]
            ),
            source: Self.redFromFirstInput,
            signalProvider: { _, _ in nil }
        )
        try await still.waitForPreparation()
        XCTAssertFalse(reader.isListening, "built is not mounted")

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 64, height: 64),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        let content = try XCTUnwrap(window.contentView)
        content.addSubview(still)
        XCTAssertFalse(reader.isListening)
        content.addSubview(pulse)
        XCTAssertTrue(reader.isListening)
        pulse.removeFromSuperview()
        XCTAssertFalse(reader.isListening)
        still.removeFromSuperview()
    }

    /// With motion held, a moment reads its binding's fallback — the rule audio follows.
    func testAMomentReadsItsFallbackWhileMotionIsHeld() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal is unavailable on this test host.")
        }
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else {
            throw XCTSkip("Low Power Mode holds motion on this host.")
        }
        DesignSettings.current = StubDesignSettings()
        Design.Motion.reduceMotionOverrideForTesting = false
        ExtensionHostSignals.uptime = { 50 }
        ExtensionHostSignals.momentOccurredAt = { _ in 50 }
        let surface = try ExtensionMetalSurfaceView(
            specification: ExtensionMetalSurface(
                shaderResource: "Resources/pulse.metal",
                inputs: [
                    .init(
                        name: "pulse",
                        value: .signal(.momentTurnFinished, mapping: .init(fallback: 0.25))
                    )
                ]
            ),
            source: Self.redFromFirstInput,
            signalProvider: { ExtensionHostSignals.value($0, in: $1) }
        )
        try await surface.waitForPreparation()
        let size = NSSize(width: 4, height: 4)
        XCTAssertEqual(
            try redComponent(of: XCTUnwrap(surface.snapshotImage(size: size, time: 0))),
            1,
            accuracy: 0.02
        )

        DesignSettings.current = StubDesignSettings(playsThemeMotion: false)
        XCTAssertEqual(
            try redComponent(of: XCTUnwrap(surface.snapshotImage(size: size, time: 0))),
            0.25,
            accuracy: 0.02
        )

        DesignSettings.current = StubDesignSettings()
        Design.Motion.reduceMotionOverrideForTesting = true
        XCTAssertEqual(
            try redComponent(of: XCTUnwrap(surface.snapshotImage(size: size, time: 0))),
            0.25,
            accuracy: 0.02
        )
    }

    /// Paints the first input into the red channel, opaque, so a pixel reads a signal back.
    private static let redFromFirstInput = """
    float4 threadingExtensionFragment(
        float2 uv,
        constant ThreadingSurfaceUniforms &uniforms
    ) {
        return float4(uniforms.values[0], 0.0, 0.0, 1.0);
    }
    """

    private func redComponent(of image: NSImage) throws -> Double {
        try SurfaceSnapshotPixels.rgba(in: image, x: 1, y: 1).red
    }

    @MainActor
    private final class Counter {
        var count = 0
    }

    // MARK: - Audio

    func testAudioSignalsDistinguishUnavailableFromRealSilence() {
        ExtensionHostSignals.audio = { nil }
        XCTAssertEqual(ExtensionHostSignals.value(.audioAvailable), 0)
        for signal in ExtensionHostSignal.audioSignals where signal != .audioAvailable {
            XCTAssertNil(ExtensionHostSignals.value(signal))
        }
        ExtensionHostSignals.audio = { .silence }
        XCTAssertEqual(ExtensionHostSignals.value(.audioAvailable), 1)
        for signal in ExtensionHostSignal.audioSignals where signal != .audioAvailable {
            XCTAssertEqual(ExtensionHostSignals.value(signal), 0)
        }
        let snapshot = AudioSpectrum(level: 0.8, bands: [0.2, 0.4, 0.6, 0.8, 1, 0.1, 0.2, 0.3])
        ExtensionHostSignals.audio = { snapshot }
        XCTAssertEqual(ExtensionHostSignals.value(.audioLevel), 0.8)
        XCTAssertEqual(ExtensionHostSignals.value(.audioBass), snapshot.bass)
        XCTAssertEqual(ExtensionHostSignals.value(.audioMids), snapshot.mids)
        XCTAssertEqual(ExtensionHostSignals.value(.audioTreble), snapshot.treble)
        for (index, signal) in ExtensionHostSignal.audioBands.enumerated() {
            XCTAssertEqual(ExtensionHostSignals.value(signal), snapshot.bands[index])
        }
    }
}
