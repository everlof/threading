import AppKit
import WebKit

typealias BrowserOpenPanelProvider = (
    _ parameters: WKOpenPanelParameters,
    _ suggestedURLs: [URL],
    _ message: String,
    _ completion: @escaping ([URL]?) -> Void
) -> Void

typealias BrowserSavePanelProvider = (
    _ suggestedFilename: String,
    _ agentRequested: Bool,
    _ message: String,
    _ completion: @escaping (URL?) -> Void
) -> Void

// MARK: - Bounded agent trace

struct BrowserTraceEvent: Codable, Equatable {
    let sequence: Int
    let timestamp: Date
    let category: String
    let name: String
    let outcome: String?
    let durationMilliseconds: Double?
    let url: String?
    let detail: String?

    private enum CodingKeys: String, CodingKey {
        case sequence, timestamp, category, name, outcome, url, detail
        case durationMilliseconds = "duration_ms"
    }
}

struct BrowserTraceArtifact: Codable, Equatable {
    let format: String
    let exportedAt: Date
    let context: String
    let recording: Bool
    let startedAt: Date?
    let droppedEvents: Int
    let events: [BrowserTraceEvent]

    private enum CodingKeys: String, CodingKey {
        case format, context, recording, events
        case exportedAt = "exported_at"
        case startedAt = "started_at"
        case droppedEvents = "dropped_events"
    }
}

struct BrowserTraceStatus: Equatable {
    let recording: Bool
    let eventCount: Int
    let droppedEvents: Int
}

extension BrowserViewController {

    @discardableResult
    func startAgentTrace() -> BrowserTraceStatus {
        agentTraceEvents.removeAll(keepingCapacity: true)
        agentTraceDroppedEvents = 0
        agentTraceNextSequence = 1
        agentTraceStartedAt = Date()
        agentTraceRecording = true
        recordAgentTraceEvent(
            category: "trace",
            name: "start",
            detail: "Started bounded metadata-only trace."
        )
        return agentTraceStatus
    }

    @discardableResult
    func stopAgentTrace() -> BrowserTraceStatus {
        if agentTraceRecording {
            recordAgentTraceEvent(
                category: "trace",
                name: "stop",
                detail: "Stopped trace."
            )
        }
        agentTraceRecording = false
        return agentTraceStatus
    }

    @discardableResult
    func clearAgentTrace() -> BrowserTraceStatus {
        agentTraceEvents.removeAll(keepingCapacity: true)
        agentTraceDroppedEvents = 0
        agentTraceNextSequence = 1
        agentTraceStartedAt = agentTraceRecording ? Date() : nil
        return agentTraceStatus
    }

    var agentTraceStatus: BrowserTraceStatus {
        BrowserTraceStatus(
            recording: agentTraceRecording,
            eventCount: agentTraceEvents.count,
            droppedEvents: agentTraceDroppedEvents
        )
    }

    func agentTraceArtifactData() throws -> Data {
        let artifact = BrowserTraceArtifact(
            format: "threading-browser-trace-v1",
            exportedAt: Date(),
            context: contextKind.rawValue,
            recording: agentTraceRecording,
            startedAt: agentTraceStartedAt,
            droppedEvents: agentTraceDroppedEvents,
            events: agentTraceEvents
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(artifact)
    }

    func recordAgentToolTrace(
        name: String,
        detail: String?,
        startedAt: Date,
        succeeded: Bool
    ) {
        recordAgentTraceEvent(
            category: "tool",
            name: name,
            outcome: succeeded ? "success" : "error",
            durationMilliseconds: Date().timeIntervalSince(startedAt) * 1_000,
            detail: detail
        )
    }

    func recordAgentNavigationTrace(_ phase: String, error: Bool = false) {
        recordAgentTraceEvent(
            category: "navigation",
            name: phase,
            outcome: error ? "error" : nil
        )
    }

    func recordAgentNetworkTrace(_ entry: BrowserNetworkEntry) {
        let status = entry.status.map(String.init) ?? (entry.isError ? "ERR" : "—")
        recordAgentTraceEvent(
            category: "network",
            name: entry.kind,
            outcome: entry.isError ? "error" : "success",
            durationMilliseconds: entry.duration,
            detail: "\(entry.method) \(status)"
        )
    }

    private func recordAgentTraceEvent(
        category: String,
        name: String,
        outcome: String? = nil,
        durationMilliseconds: Double? = nil,
        url explicitURL: String? = nil,
        detail: String? = nil
    ) {
        guard agentTraceRecording else { return }
        let url = explicitURL.map(BrowserURLRedactor.redact)
        let event = BrowserTraceEvent(
            sequence: agentTraceNextSequence,
            timestamp: Date(),
            category: String(category.prefix(40)),
            name: String(name.prefix(80)),
            outcome: outcome.map { String($0.prefix(40)) },
            durationMilliseconds: durationMilliseconds.map { max(0, $0) },
            url: url,
            detail: detail.map { String($0.prefix(BrowserDefaults.maximumTraceDetailLength)) }
        )
        agentTraceNextSequence += 1
        agentTraceEvents.append(event)
        if agentTraceEvents.count > BrowserDefaults.maximumTraceEvents {
            let overflow = agentTraceEvents.count - BrowserDefaults.maximumTraceEvents
            agentTraceEvents.removeFirst(overflow)
            agentTraceDroppedEvents += overflow
        }
    }
}

// MARK: - Visual comparison

struct BrowserVisualComparison: Equatable {
    let matches: Bool
    let dimensionsMatch: Bool
    let width: Int
    let height: Int
    let baselineWidth: Int
    let baselineHeight: Int
    let differentPixels: Int
    let differentRatio: Double
    let maximumChannelDelta: Int
    let diffPNG: Data?
}

enum BrowserVisualComparator {
    static func compare(
        baseline: Data,
        actual: Data,
        channelThreshold: Int,
        maximumDifferentRatio: Double
    ) throws -> BrowserVisualComparison {
        guard (0...255).contains(channelThreshold) else {
            throw BrowserVisualComparisonError.invalidThreshold
        }
        guard (0...1).contains(maximumDifferentRatio) else {
            throw BrowserVisualComparisonError.invalidRatio
        }
        let baselinePixels = try decodeRGBA(baseline)
        let actualPixels = try decodeRGBA(actual)
        guard baselinePixels.width == actualPixels.width,
              baselinePixels.height == actualPixels.height else {
            return BrowserVisualComparison(
                matches: false,
                dimensionsMatch: false,
                width: actualPixels.width,
                height: actualPixels.height,
                baselineWidth: baselinePixels.width,
                baselineHeight: baselinePixels.height,
                differentPixels: max(
                    baselinePixels.width * baselinePixels.height,
                    actualPixels.width * actualPixels.height
                ),
                differentRatio: 1,
                maximumChannelDelta: 255,
                diffPNG: nil
            )
        }

        let pixelCount = actualPixels.width * actualPixels.height
        var differentPixels = 0
        var maximumDelta = 0
        var diff = [UInt8](repeating: 0, count: actualPixels.bytes.count)
        for pixel in 0..<pixelCount {
            let offset = pixel * 4
            var pixelDelta = 0
            for channel in 0..<4 {
                pixelDelta = max(
                    pixelDelta,
                    abs(
                        Int(baselinePixels.bytes[offset + channel])
                            - Int(actualPixels.bytes[offset + channel])
                    )
                )
            }
            maximumDelta = max(maximumDelta, pixelDelta)
            if pixelDelta > channelThreshold {
                differentPixels += 1
                diff[offset] = 255
                diff[offset + 1] = UInt8(max(0, 180 - min(180, pixelDelta / 2)))
                diff[offset + 2] = 0
                diff[offset + 3] = 255
            } else {
                let luminance = UInt8(
                    (
                        Int(actualPixels.bytes[offset])
                            + Int(actualPixels.bytes[offset + 1])
                            + Int(actualPixels.bytes[offset + 2])
                    ) / 3
                )
                diff[offset] = luminance
                diff[offset + 1] = luminance
                diff[offset + 2] = luminance
                diff[offset + 3] = 72
            }
        }
        let ratio = pixelCount == 0 ? 0 : Double(differentPixels) / Double(pixelCount)
        return BrowserVisualComparison(
            matches: ratio <= maximumDifferentRatio,
            dimensionsMatch: true,
            width: actualPixels.width,
            height: actualPixels.height,
            baselineWidth: baselinePixels.width,
            baselineHeight: baselinePixels.height,
            differentPixels: differentPixels,
            differentRatio: ratio,
            maximumChannelDelta: maximumDelta,
            diffPNG: encodeRGBA(
                diff,
                width: actualPixels.width,
                height: actualPixels.height
            )
        )
    }

    private struct Pixels {
        let width: Int
        let height: Int
        let bytes: [UInt8]
    }

    private static func decodeRGBA(_ data: Data) throws -> Pixels {
        guard let representation = NSBitmapImageRep(data: data),
              let image = representation.cgImage else {
            throw BrowserVisualComparisonError.invalidPNG
        }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              width <= BrowserDefaults.maximumVisualComparisonDimension,
              height <= BrowserDefaults.maximumVisualComparisonDimension,
              width * height <= BrowserDefaults.maximumVisualComparisonPixels else {
            throw BrowserVisualComparisonError.imageTooLarge
        }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw BrowserVisualComparisonError.invalidPNG
        }
        let rendered = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(
                data: storage.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else {
            throw BrowserVisualComparisonError.invalidPNG
        }
        return Pixels(width: width, height: height, bytes: bytes)
    }

    private static func encodeRGBA(_ bytes: [UInt8], width: Int, height: Int) -> Data? {
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: .alphaNonpremultiplied,
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        ), let destination = representation.bitmapData else { return nil }
        bytes.withUnsafeBytes {
            guard let source = $0.baseAddress else { return }
            UnsafeMutableRawPointer(destination).copyMemory(
                from: source,
                byteCount: bytes.count
            )
        }
        return representation.representation(using: .png, properties: [:])
    }
}

enum BrowserVisualComparisonError: LocalizedError {
    case invalidPNG
    case imageTooLarge
    case invalidThreshold
    case invalidRatio

    var errorDescription: String? {
        switch self {
        case .invalidPNG:
            return L10n.string("The baseline or current capture is not a decodable PNG.")
        case .imageTooLarge:
            return L10n.string("The baseline or current capture exceeds the comparison limit.")
        case .invalidThreshold:
            return L10n.string("channel_threshold must be between 0 and 255.")
        case .invalidRatio:
            return L10n.string("maximum_different_ratio must be between 0 and 1.")
        }
    }
}
