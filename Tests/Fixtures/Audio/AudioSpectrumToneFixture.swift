import AppKit
import AVFoundation

/// A separate, controlled source exercises the shipping case: tapping another application.
/// No input device, user files, saved settings or captured audio belong to this fixture.
@main
struct AudioSpectrumToneFixture {
    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
        buffer.frameLength = buffer.frameCapacity
        let channel = buffer.floatChannelData![0]
        for sample in 0..<Int(buffer.frameLength) {
            channel[sample] = Float(0.02 * sin(2 * Double.pi * 1_000 * Double(sample) / 48_000))
        }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
        try engine.start()
        player.play()
        defer { player.stop(); engine.stop() }
        while readLine() != nil {}
    }
}
