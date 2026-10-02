import XCTest
@testable import Threading

@MainActor
final class AudioSpectrumServiceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var settings: AppSettings!

    override func setUp() async throws {
        suite = "audio-spectrum-test-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        settings = AppSettings(defaults: defaults)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        settings = nil
        defaults = nil
    }

    func testConsentAndVisibleDemandAreBothRequiredAndDisablingClearsImmediately() async throws {
        let capture = FakeCapture()
        let service = AudioSpectrumService(settings: settings, makeCapture: { capture })
        let consumer = UUID()
        defer { service.stop() }
        service.setDemand(consumer, active: true)
        XCTAssertFalse(settings.sharesThemeAudio)
        XCTAssertNil(service.reading())
        let startsWhileDisabled = await capture.starts
        XCTAssertEqual(startsWhileDisabled, [])
        settings.sharesThemeAudio = true
        try await wait { service.spectrum != nil }
        XCTAssertEqual(service.reading()?.level, 0.8)
        XCTAssertEqual(service.consumerCount, 1)
        XCTAssertNil(service.reading(at: ProcessInfo.processInfo.systemUptime + 1), "stale readings expire")
        settings.sharesThemeAudio = false
        XCTAssertNil(service.spectrum)
        XCTAssertNil(service.reading())
        try await wait { await capture.stops > 0 }
    }

    func testMultipleConsumersShareOneTapAndTheLastReleaseStopsIt() async throws {
        let capture = FakeCapture()
        let service = AudioSpectrumService(settings: settings, makeCapture: { capture })
        defer { service.stop() }
        settings.sharesThemeAudio = true
        let first = UUID(), second = UUID()
        service.setDemand(first, active: true)
        service.setDemand(second, active: true)
        try await wait { service.spectrum != nil }
        let starts = await capture.starts
        XCTAssertEqual(starts.count, 1)
        service.setDemand(first, active: false)
        XCTAssertNotNil(service.reading())
        service.setDemand(second, active: false)
        XCTAssertNil(service.reading())
        XCTAssertEqual(service.state, .waiting)
        try await wait { await capture.stops == 1 }
    }

    func testSourceReplacementWaitsForOldCaptureAndRejectsLateSnapshots() async throws {
        let first = FakeCapture(holdsStart: true)
        let second = FakeCapture()
        var factories = 0
        let service = AudioSpectrumService(settings: settings, makeCapture: {
            factories += 1
            return factories == 1 ? first : second
        })
        defer { service.stop() }
        settings.sharesThemeAudio = true
        service.setDemand(UUID(), active: true)
        try await wait { await first.starts.count == 1 }
        settings.themeAudioSource = "com.example.music"
        XCTAssertNil(service.reading())
        let premature = await second.starts
        XCTAssertEqual(premature, [])
        await first.releaseStart()
        try await wait { service.spectrum != nil }
        let oldReads = await first.reads
        let oldStops = await first.stops
        let newStarts = await second.starts
        XCTAssertEqual(oldReads, 0)
        XCTAssertEqual(oldStops, 1)
        XCTAssertEqual(newStarts, ["com.example.music"])
    }

    func testFailureDoesNotAutomaticallyRepromptAndRetryIsExplicit() async throws {
        let capture = FakeCapture(fails: true)
        let service = AudioSpectrumService(settings: settings, makeCapture: { capture })
        defer { service.stop() }
        settings.sharesThemeAudio = true
        service.setDemand(UUID(), active: true)
        try await wait { service.state == .failed }
        XCTAssertNil(service.reading())
        let refusedStarts = await capture.starts.count
        XCTAssertEqual(refusedStarts, 1)
        await capture.allow()
        service.retry()
        try await wait { service.spectrum != nil }
        let retryStarts = await capture.starts.count
        XCTAssertEqual(retryStarts, 2)
    }

    func testAnOpenCaptureWithoutDeliveredSamplesIsUnavailable() async throws {
        let capture = FakeCapture(readingsAvailable: false)
        let service = AudioSpectrumService(settings: settings, makeCapture: { capture })
        defer { service.stop() }
        settings.sharesThemeAudio = true
        service.setDemand(UUID(), active: true)
        try await wait { await capture.reads > 0 }
        XCTAssertEqual(service.state, .awaitingSamples)
        XCTAssertNil(service.reading())
        await capture.setReadingsAvailable(true)
        try await wait { service.reading() != nil }
        await capture.setReadingsAvailable(false)
        try await wait { service.reading() == nil }
    }

    func testUnsupportedOSNeverStartsCaptureAndUserConsentUsesItsOwnSuite() {
        let service = AudioSpectrumService(settings: settings, makeCapture: { nil })
        defer { service.stop() }
        settings.sharesThemeAudio = true
        service.setDemand(UUID(), active: true)
        XCTAssertEqual(service.state, .unsupported)
        XCTAssertNil(service.reading())
        XCTAssertEqual(AppSettingDefinitions.sharesThemeAudio.read(from: defaults), true)
    }

    private func wait(_ predicate: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("audio lifecycle did not settle within two seconds")
    }
}

private actor FakeCapture: AudioSpectrumCapturing {
    private(set) var starts: [String] = []
    private(set) var stops = 0
    private(set) var reads = 0
    private var fails: Bool
    private let holdsStart: Bool
    private var readingsAvailable: Bool
    private var continuation: CheckedContinuation<Void, Never>?

    init(holdsStart: Bool = false, fails: Bool = false, readingsAvailable: Bool = true) {
        self.holdsStart = holdsStart
        self.fails = fails
        self.readingsAvailable = readingsAvailable
    }
    func sources() -> [AudioSpectrumSource] { [] }
    func start(sourceID: String) async throws {
        starts.append(sourceID)
        if holdsStart { await withCheckedContinuation { continuation = $0 } }
        if fails { throw AudioSpectrumCaptureError.unsupportedFormat }
    }
    func read(at now: TimeInterval) -> AudioSpectrum? {
        reads += 1
        return readingsAvailable ? AudioSpectrum(level: 0.8, bands: Array(repeating: 0.4, count: 8)) : nil
    }
    func stop() { stops += 1 }
    func releaseStart() { continuation?.resume(); continuation = nil }
    func allow() { fails = false }
    func setReadingsAvailable(_ available: Bool) { readingsAvailable = available }
}
