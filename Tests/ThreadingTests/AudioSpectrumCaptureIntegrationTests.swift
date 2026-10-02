import XCTest
@testable import Threading

/// Explicitly opted-in HAL coverage. Captures only a synthesized tone from a
/// controlled fixture app; it never selects system audio or changes a user preference.
@MainActor
final class AudioSpectrumCaptureIntegrationTests: XCTestCase {
    func testPrivateProcessTapMeasuresTheControlledToneSource() async throws {
        guard ProcessInfo.processInfo.environment["THREADING_TEST_LIVE_AUDIO"] == "1" else {
            throw XCTSkip("Set THREADING_TEST_LIVE_AUDIO=1 to exercise Core Audio and system audio permission.")
        }
        guard #available(macOS 14.2, *) else { throw XCTSkip("Process taps require macOS 14.2") }
        guard let path = ProcessInfo.processInfo.environment["THREADING_TEST_AUDIO_TONE_APP"],
              let bundle = Bundle(path: path), let bundleID = bundle.bundleIdentifier,
              bundleID == "codes.threading.tests.audio-tone", let executable = bundle.executableURL else {
            throw XCTSkip("Use scripts/test_theme_audio_capture.sh to build the controlled audio source.")
        }
        let playback = Process()
        let input = Pipe()
        playback.executableURL = executable
        playback.standardInput = input
        playback.standardOutput = FileHandle.nullDevice
        playback.standardError = FileHandle.nullDevice
        try playback.run()
        defer {
            try? input.fileHandleForWriting.close()
            if playback.isRunning { playback.terminate() }
        }
        print("LIVE_AUDIO controlled source launched; preparing private process tap")
        try await Task.sleep(nanoseconds: 500_000_000)
        let capture = AudioSpectrumCapture()
        do {
            for attempt in 0..<30 {
                do {
                    try await capture.start(sourceID: bundleID)
                    break
                } catch AudioSpectrumCaptureError.sourceUnavailable where attempt < 29 {
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            print("LIVE_AUDIO private tap started")
            var peak = AudioSpectrum.silence
            for _ in 0..<90 {
                if let reading = try await capture.read(at: ProcessInfo.processInfo.systemUptime),
                   reading.level > peak.level { peak = reading }
                try await Task.sleep(nanoseconds: 33_333_333)
            }
            print("LIVE_AUDIO readings complete: level=\(peak.level); stopping tap while source still plays")
            print("LIVE_AUDIO capture counts: \(await capture.diagnosticCountsForTesting())")
            await capture.stop()
            XCTAssertGreaterThan(peak.level, 0.1, "a valid tap must deliver samples, not just start successfully")
            XCTAssertEqual(peak.bands.firstIndex(of: peak.bands.max()!), 3, "1 kHz should land in band 3")
            print("LIVE_AUDIO controlled-source 1kHz level=\(peak.level) bands=\(peak.bands)")
        } catch {
            await capture.stop()
            throw error
        }
    }
}
