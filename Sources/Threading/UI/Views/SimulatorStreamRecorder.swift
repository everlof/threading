import AppKit

/// Simulator's main-actor facade. The physical preview uses the same encoder on its bounded worker.
@MainActor
final class SimulatorStreamRecorder {
    private let writer: DeviceMovieWriter
    var outputURL: URL { writer.outputURL }

    init?(url: URL, width: Int, height: Int) {
        guard let writer = DeviceMovieWriter(url: url, width: width, height: height) else { return nil }
        self.writer = writer
    }

    func append(
        image: CGImage,
        indicators: SimulatorTouchIndicators?,
        style: SimulatorTouchStyle = .standard
    ) {
        writer.append(image: image, indicators: indicators, style: style, ink: .init(style: style))
    }

    func finish(completion: @escaping @MainActor @Sendable (URL?) -> Void) {
        writer.finish { url in Task { @MainActor in completion(url) } }
    }
}
