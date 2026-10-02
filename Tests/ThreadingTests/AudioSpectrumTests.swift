import CoreAudio
import XCTest
@testable import Threading

final class AudioSpectrumTests: XCTestCase {
    func testSineWavesLandInTheirMeasuredFrequencyBands() throws {
        for (expected, frequency) in [50.0, 120, 320, 800, 2_000, 4_200, 9_000, 16_000].enumerated() {
            let analyzer = try XCTUnwrap(AudioSpectrumAnalyzer())
            let samples = tone(frequency: frequency)
            let result = analyzer.analyze(samples: samples, sampleRate: 48_000, at: 10)
            XCTAssertEqual(result.bands.firstIndex(of: result.bands.max()!), expected,
                           "\(frequency) Hz was assigned to the wrong band")
            XCTAssertGreaterThan(result.bands[expected], 0.35)
            XCTAssertGreaterThan(result.level, 0)
        }
    }

    func testSilenceInvalidInputAndReleaseNeverLeaveNonfiniteOrStuckBands() throws {
        let analyzer = try XCTUnwrap(AudioSpectrumAnalyzer())
        let silence = [Float](repeating: 0, count: AudioSpectrumAnalyzer.sampleCount)
        XCTAssertEqual(analyzer.analyze(samples: silence, sampleRate: 48_000, at: 0), .silence)
        let peak = analyzer.analyze(samples: tone(frequency: 800), sampleRate: 48_000, at: 1)
        let releasing = analyzer.analyze(samples: silence, sampleRate: 48_000, at: 1.03)
        XCTAssertLessThan(releasing.level, peak.level)
        XCTAssertGreaterThan(releasing.level, 0)
        let settled = analyzer.analyze(samples: silence, sampleRate: 48_000, at: 5)
        XCTAssertLessThan(settled.level, 0.005)
        XCTAssertEqual(analyzer.analyze(samples: [], sampleRate: .nan, at: 6), .silence)
        let invalid = analyzer.analyze(samples: [Float](repeating: .nan, count: silence.count),
                                      sampleRate: 48_000, at: 7)
        XCTAssertEqual(invalid, .silence)
    }

    func testAbsoluteNormalizationDoesNotTurnQuietNoiseIntoMusic() throws {
        let analyzer = try XCTUnwrap(AudioSpectrumAnalyzer())
        let quiet = tone(frequency: 800, amplitude: 0.000001)
        XCTAssertEqual(analyzer.analyze(samples: quiet, sampleRate: 48_000, at: 10), .silence)
        let result = analyzer.analyze(samples: tone(frequency: 800), sampleRate: 22_050, at: 11)
        XCTAssertEqual(result.bands[7], 0, "a band above Nyquist has no energy")
    }

    func testMailboxDownmixesAndRetainsOnlyOneWindow() throws {
        let mailbox = AudioSpectrumMailbox()
        var stereo = (0..<4_096).flatMap { index -> [Float] in [Float(index), Float(index) + 2] }
        stereo.withUnsafeMutableBytes { bytes in
            var input = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 2, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
            withUnsafePointer(to: &input) { mailbox.receive($0) }
        }
        let result = try XCTUnwrap(mailbox.latest(after: 0))
        XCTAssertEqual(result.samples.count, AudioSpectrumAnalyzer.sampleCount)
        XCTAssertEqual(result.samples.first, 2_049)
        XCTAssertEqual(result.samples.last, 4_096)
        XCTAssertNil(mailbox.latest(after: result.revision))
    }

    func testSnapshotBoundsEveryReadingAndHasExactlyEightBands() {
        let reading = AudioSpectrum(level: .infinity, bands: [-1, 2, .nan])
        XCTAssertEqual(reading.level, 0)
        XCTAssertEqual(reading.bands, [0, 1, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(reading.bass, 0.5)
        XCTAssertEqual(reading.mids, 0)
    }

    func testAnalysisBudgetForThirtySecondsOfAudio() throws {
        let analyzer = try XCTUnwrap(AudioSpectrumAnalyzer())
        let samples = tone(frequency: 320)
        let began = ContinuousClock.now
        for frame in 0..<900 {
            _ = analyzer.analyze(samples: samples, sampleRate: 48_000, at: Double(frame) / 30)
        }
        let seconds = began.duration(to: .now).components
        let elapsed = Double(seconds.seconds) + Double(seconds.attoseconds) / 1e18
        print("Audio spectrum: 900 FFT snapshots in \(elapsed)s")
        XCTAssertLessThan(elapsed, 3, "analysis should use far less than one core at 30 Hz")
    }

    private func tone(frequency: Double, amplitude: Double = 0.5) -> [Float] {
        (0..<AudioSpectrumAnalyzer.sampleCount).map {
            Float(amplitude * sin(2 * Double.pi * frequency * Double($0) / 48_000))
        }
    }
}
