import AppKit
import ImageIO
import UniformTypeIdentifiers

/// One serial worker per explicit capture. The pane admits at most one append in flight and
/// drops frames while it is busy; neither the actor mailbox nor AVFoundation accumulates frames.
actor DevicePreviewCapture {
    private var writer: DeviceMovieWriter?

    func start(url: URL, image: CGImage, indicators: SimulatorTouchIndicators?,
               style: SimulatorTouchStyle, ink: SimulatorTouchMarks.Ink) -> Bool {
        guard writer == nil,
              let writer = DeviceMovieWriter(url: url, width: image.width, height: image.height) else {
            return false
        }
        self.writer = writer
        autoreleasepool {
            writer.append(image: image, indicators: indicators, style: style, ink: ink)
        }
        return true
    }

    func append(image: CGImage, indicators: SimulatorTouchIndicators?,
                style: SimulatorTouchStyle, ink: SimulatorTouchMarks.Ink) {
        autoreleasepool {
            writer?.append(image: image, indicators: indicators, style: style, ink: ink)
        }
    }

    func finish() async -> URL? {
        guard let writer else { return nil }
        self.writer = nil
        let saved: URL? = await withCheckedContinuation { continuation in
            writer.finish { continuation.resume(returning: $0) }
        }
        if saved == nil { try? FileManager.default.removeItem(at: writer.outputURL) }
        return saved
    }

    static func destination(deviceName: String, video: Bool, directory: URL?) -> URL {
        let directory = directory ?? SimulatorCaptureSaver.defaultDirectory(video: video)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss.SSS"
        let name = deviceName.replacingOccurrences(of: "/", with: "-")
        return directory.appendingPathComponent(
            "\(name) \(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8)).\(video ? "mov" : "png")"
        )
    }

    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    static func save(_ image: CGImage, deviceName: String, directory: URL?) -> URL? {
        guard let png = png(image) else { return nil }
        let url = destination(deviceName: deviceName, video: false, directory: directory)
        return SimulatorCaptureSaver.writeData(png, to: url) ? url : nil
    }
}
