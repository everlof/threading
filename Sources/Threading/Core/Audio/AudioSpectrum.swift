import Accelerate
import Foundation

/// One bounded, local presentation reading. No audio bytes or source identity leave the host.
struct AudioSpectrum: Equatable, Sendable {
    static let bandEdges: [Double] = [20, 80, 200, 500, 1_200, 3_000, 6_000, 12_000, 20_000]
    static let bandCount = 8
    static let silence = AudioSpectrum(level: 0, bands: Array(repeating: 0, count: bandCount))

    let level: Double
    let bands: [Double]

    init(level: Double, bands: [Double]) {
        self.level = Self.normalized(level)
        self.bands = (0..<Self.bandCount).map { index in
            index < bands.count ? Self.normalized(bands[index]) : 0
        }
    }

    var bass: Double { mean(0..<2) }
    var mids: Double { mean(2..<5) }
    var treble: Double { mean(5..<8) }

    private func mean(_ range: Range<Int>) -> Double {
        range.reduce(0) { $0 + bands[$1] } / Double(range.count)
    }

    private static func normalized(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0
    }
}

/// Queue-owned FFT state: one 2,048-sample Hann window, eight frequency bands, fixed scratch.
/// Analysis runs at most 30 times/s, regardless of callback cadence or the number of views.
/// Levels use an absolute -60…0 dBFS display range; silence is never amplified into movement.
final class AudioSpectrumAnalyzer {
    static let sampleCount = 2_048
    private let transform: vDSP_DFT_Setup
    private var window = [Float](repeating: 0, count: sampleCount)
    private var real = [Float](repeating: 0, count: sampleCount)
    private var imaginary = [Float](repeating: 0, count: sampleCount)
    private var outputReal = [Float](repeating: 0, count: sampleCount)
    private var outputImaginary = [Float](repeating: 0, count: sampleCount)
    private var smoothed = AudioSpectrum.silence
    private var lastTime: TimeInterval?

    init?() {
        guard let transform = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(Self.sampleCount), .FORWARD)
        else { return nil }
        self.transform = transform
        vDSP_hann_window(&window, vDSP_Length(Self.sampleCount), Int32(vDSP_HANN_NORM))
    }

    deinit { vDSP_DFT_DestroySetup(transform) }

    func analyze(samples: [Float], sampleRate: Double, at now: TimeInterval) -> AudioSpectrum {
        guard samples.count == Self.sampleCount, sampleRate.isFinite, sampleRate > 0 else {
            return settle(toward: .silence, at: now)
        }
        var squaredSum: Double = 0
        for index in 0..<Self.sampleCount {
            let value = samples[index].isFinite ? min(max(samples[index], -1), 1) : 0
            squaredSum += Double(value) * Double(value)
            real[index] = value * window[index]
        }
        let rms = sqrt(squaredSum / Double(Self.sampleCount))
        guard rms > 0.00001 else { return settle(toward: .silence, at: now) }

        vDSP_DFT_Execute(transform, real, imaginary, &outputReal, &outputImaginary)
        let binWidth = sampleRate / Double(Self.sampleCount)
        let scale = 2 / Double(window.reduce(0, +))
        let bands = (0..<AudioSpectrum.bandCount).map { band -> Double in
            let lower = max(1, Int(ceil(AudioSpectrum.bandEdges[band] / binWidth)))
            let upper = min(Self.sampleCount / 2, Int(ceil(AudioSpectrum.bandEdges[band + 1] / binWidth)))
            guard lower < upper else { return 0 }
            var energy: Double = 0
            for bin in lower..<upper {
                let r = Double(outputReal[bin])
                let i = Double(outputImaginary[bin])
                energy += r * r + i * i
            }
            return Self.displayLevel(sqrt(energy) * scale)
        }
        return settle(toward: AudioSpectrum(level: Self.displayLevel(rms), bands: bands), at: now)
    }

    private static func displayLevel(_ amplitude: Double) -> Double {
        guard amplitude.isFinite, amplitude > 0.001 else { return 0 }
        return min(max((20 * log10(amplitude) + 60) / 60, 0), 1)
    }

    private func settle(toward target: AudioSpectrum, at now: TimeInterval) -> AudioSpectrum {
        let elapsed = min(max(now - (lastTime ?? now - 1.0 / 30), 0), 1)
        lastTime = now
        func smooth(_ old: Double, _ new: Double) -> Double {
            let duration = new > old ? 0.04 : 0.18
            let value = old + (new - old) * (1 - exp(-elapsed / duration))
            return value < 0.001 ? 0 : value
        }
        smoothed = AudioSpectrum(
            level: smooth(smoothed.level, target.level),
            bands: (0..<AudioSpectrum.bandCount).map { smooth(smoothed.bands[$0], target.bands[$0]) }
        )
        return smoothed
    }
}
