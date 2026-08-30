import AppKit
import ImageIO
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

    /// Bridge timings are the evidence needed after a stall, so they keep a small rolling history
    /// even when the broader network/navigation trace was not armed in advance. The payload is
    /// deliberately phase names and durations only; page content and targets never enter it.
    func recordAgentBridgePhase(
        _ name: String,
        startedAt: Date,
        outcome: String,
        detail: String? = nil
    ) {
        recordAgentTraceEvent(
            category: "bridge",
            name: name,
            outcome: outcome,
            durationMilliseconds: Date().timeIntervalSince(startedAt) * 1_000,
            detail: detail,
            always: true
        )
    }

    /// Let synchronous handlers and a resulting navigation settle without letting an endlessly
    /// streaming page hold the action result forever.
    func settleAfterAgentAction() async {
        let startedAt = Date()
        let deadline = Date().addingTimeInterval(5)
        repeat {
            try? await Task.sleep(nanoseconds: 120_000_000)
        } while webView.isLoading && Date() < deadline
        recordAgentBridgePhase(
            "action.load-settle",
            startedAt: startedAt,
            outcome: webView.isLoading ? "bounded-while-loading" : "settled"
        )
    }

    func recordAgentAuthorizationPhase(startedAt: Date, allowed: Bool) {
        recordAgentBridgePhase(
            "action.origin-authorization",
            startedAt: startedAt,
            outcome: allowed ? "allowed" : "denied"
        )
    }

    func recordAgentActionSnapshotPhase(startedAt: Date, snapshot: BrowserSnapshot?) {
        recordAgentBridgePhase(
            "action.viewport-snapshot",
            startedAt: startedAt,
            outcome: snapshot.map { $0.truncated ? "truncated" : "success" } ?? "error",
            detail: snapshot.map { "\($0.nodes.count) nodes; \($0.visitedElements ?? 0) visited" }
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
        detail: String? = nil,
        always: Bool = false
    ) {
        guard agentTraceRecording || always else { return }
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

/// A rectangle of pixels a comparison is told to ignore, in the capture's own pixel space.
///
/// Phase-1 ignores are explicit rectangles and nothing else. A semantic ignore — "whatever the
/// clock element covers" — needs the *old* capture's element geometry to resolve against, and a
/// PNG baseline does not carry any; see `BrowserAttributionState`, which is what makes the
/// semantic form possible without applying today's rectangle to yesterday's pixels.
struct BrowserIgnoreRect: Equatable, Sendable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    var isEmpty: Bool { width <= 0 || height <= 0 }
}

/// What the comparison was asked to do.
struct BrowserVisualComparisonOptions: Equatable, Sendable {

    /// The perceptual distance, 0…1, below which two pixels are the same pixel.
    ///
    /// Not a channel delta: the units are pixelmatch's normalized YIQ distance, where 1 is the
    /// largest difference two colours can have. `perceptualThreshold(forChannelDelta:)` converts
    /// the old parameter into this one so a caller written against the previous surface keeps
    /// meaning what it meant.
    var threshold: Double

    /// The changed fraction of the compared region that still passes.
    var maximumDifferentRatio: Double

    /// Whether pixels that look like an anti-aliasing edge are excluded from the count.
    ///
    /// On by default, and it is the single largest correctness change in this comparator: WebKit
    /// re-rasterises text at sub-pixel offsets for reasons that have nothing to do with the page,
    /// so a naive comparator reports every line of copy as changed and the ratio threshold gets
    /// raised until it can no longer detect anything.
    var ignoresAntiAliasing: Bool

    /// Rectangles excluded from the count, in the compared region's pixel space.
    var ignoredRects: [BrowserIgnoreRect]

    /// Whether to render the diff PNG. Off for a caller that only wants the numbers and the mask.
    var producesDiffImage: Bool

    init(
        threshold: Double = BrowserVisualComparisonDefaults.threshold,
        maximumDifferentRatio: Double = BrowserVisualComparisonDefaults.maximumDifferentRatio,
        ignoresAntiAliasing: Bool = true,
        ignoredRects: [BrowserIgnoreRect] = [],
        producesDiffImage: Bool = true
    ) {
        self.threshold = threshold
        self.maximumDifferentRatio = maximumDifferentRatio
        self.ignoresAntiAliasing = ignoresAntiAliasing
        self.ignoredRects = ignoredRects
        self.producesDiffImage = producesDiffImage
    }
}

/// The changed-pixel map, kept so region labelling does not have to compare the images again.
///
/// One byte per pixel rather than a bit set: the labelling pass reads it four to eight times per
/// pixel, and the packing arithmetic costs more than the memory it saves at these sizes.
struct BrowserChangedPixelMask: Equatable, Sendable {
    let width: Int
    let height: Int
    let values: [UInt8]

    func isChanged(x: Int, y: Int) -> Bool {
        guard x >= 0, y >= 0, x < width, y < height else { return false }
        return values[y * width + x] != 0
    }
}

struct BrowserVisualComparison: Equatable {
    let matches: Bool
    let dimensionsMatch: Bool
    let width: Int
    let height: Int
    let baselineWidth: Int
    let baselineHeight: Int

    /// Signed, actual minus baseline. A one-pixel height change is the most common real change,
    /// and "the images are different sizes" is not an answer anyone can act on.
    let widthDelta: Int
    let heightDelta: Int

    /// The overlap that was actually compared. Equal to the full image when the two agree.
    let comparedWidth: Int
    let comparedHeight: Int

    /// Pixels the comparison looked at: the common region, minus anything an ignore rectangle
    /// covered. The ratio's denominator, so a large ignore cannot silently make a small change
    /// look smaller than it is.
    let comparedPixels: Int
    let differentPixels: Int
    let differentRatio: Double

    /// Pixels over the threshold that were excluded as anti-aliasing, reported rather than hidden:
    /// a comparison that suppressed most of its differences should say so.
    let antiAliasedPixels: Int
    let ignoredPixels: Int

    /// Retained from the previous comparator because it is the number a human recognises.
    let maximumChannelDelta: Int
    /// The largest normalized YIQ distance found, in the same units as `threshold`.
    let maximumPerceptualDelta: Double
    let diffPNG: Data?
    let changedMask: BrowserChangedPixelMask?
}

enum BrowserVisualComparisonDefaults {
    /// pixelmatch's own default, which is the value its anti-aliasing behaviour was tuned against.
    static let threshold = 0.1
    static let maximumDifferentRatio = 0.001

    /// The largest possible squared YIQ distance, and therefore what normalizes it to 0…1.
    static let maximumYIQDistance = 35_215.0

    /// The previous surface's default channel delta, kept so its mapping is stated once.
    static let legacyChannelThreshold = 16
}

/// Compares two rendered captures the way a person looks at them.
///
/// **YIQ, not per-channel absolute delta.** The old comparator took the largest absolute
/// difference across R, G, B and A, which weights a blue shift the eye barely sees exactly as
/// heavily as a luminance shift it cannot miss. The NTSC YIQ distance pixelmatch and odiff use
/// weights luminance the way vision does, and it is what makes a single threshold mean the same
/// thing on dark chrome and on white copy.
///
/// **Anti-aliasing is detected, not tolerated.** Raising the threshold until re-rasterised text
/// stops reporting also raises it past every change worth catching. The detector is pixelmatch's:
/// a pixel whose 8-neighbourhood contains both a distinctly darker and a distinctly lighter
/// neighbour, at least one of which has many identical siblings in *both* images, is an edge being
/// drawn slightly differently rather than content that changed.
///
/// **Alpha is composited, not compared.** A screenshot's alpha channel is not a fourth colour: two
/// pixels that differ only in transparency look identical over an opaque page. Both sides are
/// blended onto the same white ground before the distance is taken, which is what the pixels
/// actually looked like on screen.
///
/// **A size change is reported, never scaled away.** The common region is compared and the signed
/// dimension deltas are returned, so a page that grew by one row says so and still shows what
/// changed inside the overlap. `matches` is false regardless: a documented scale is still the
/// wrong pixels.
enum BrowserVisualComparator {

    // MARK: Entry points

    /// The parameter shape the first version of this tool shipped with.
    ///
    /// Kept working rather than removed, and translated rather than approximated: a grey step of
    /// `channelThreshold` has a known YIQ distance, so the mapping is a computation instead of a
    /// constant somebody picked.
    static func compare(
        baseline: Data,
        actual: Data,
        channelThreshold: Int,
        maximumDifferentRatio: Double
    ) throws -> BrowserVisualComparison {
        guard (0...255).contains(channelThreshold) else {
            throw BrowserVisualComparisonError.invalidThreshold
        }
        return try compare(
            baseline: baseline,
            actual: actual,
            options: BrowserVisualComparisonOptions(
                threshold: perceptualThreshold(forChannelDelta: channelThreshold),
                maximumDifferentRatio: maximumDifferentRatio
            )
        )
    }

    /// The normalized YIQ threshold equivalent to an old per-channel grey step.
    ///
    /// A grey step of Δ moves luminance by exactly Δ (the three weights sum to 1) and leaves I and
    /// Q alone, so its squared distance is `0.5053 · Δ²` against a maximum of 35215.
    static func perceptualThreshold(forChannelDelta delta: Int) -> Double {
        let squared = 0.5053 * Double(delta) * Double(delta)
        return min(1, (squared / BrowserVisualComparisonDefaults.maximumYIQDistance).squareRoot())
    }

    static func compare(
        baseline: Data,
        actual: Data,
        options: BrowserVisualComparisonOptions
    ) throws -> BrowserVisualComparison {
        guard (0...1).contains(options.threshold) else {
            throw BrowserVisualComparisonError.invalidThreshold
        }
        guard (0...1).contains(options.maximumDifferentRatio) else {
            throw BrowserVisualComparisonError.invalidRatio
        }
        guard baseline.count <= BrowserBaselineDefaults.maximumImageBytes,
              actual.count <= BrowserBaselineDefaults.maximumImageBytes else {
            throw BrowserVisualComparisonError.imageTooLarge
        }
        let baselinePixels = try decodeRGBA(baseline)
        let actualPixels = try decodeRGBA(actual)
        return compare(baseline: baselinePixels, actual: actualPixels, options: options)
    }

    // MARK: The pass

    static func compare(
        baseline: Pixels,
        actual: Pixels,
        options: BrowserVisualComparisonOptions
    ) -> BrowserVisualComparison {
        let dimensionsMatch = baseline.width == actual.width && baseline.height == actual.height
        let common = (
            width: min(baseline.width, actual.width),
            height: min(baseline.height, actual.height)
        )
        let maximumDelta = BrowserVisualComparisonDefaults.maximumYIQDistance
            * options.threshold * options.threshold

        var ignored = [UInt8](repeating: 0, count: max(0, common.width * common.height))
        var ignoredPixels = 0
        for rect in options.ignoredRects where !rect.isEmpty {
            let x0 = max(0, rect.x)
            let y0 = max(0, rect.y)
            let x1 = min(common.width, rect.x + rect.width)
            let y1 = min(common.height, rect.y + rect.height)
            guard x0 < x1, y0 < y1 else { continue }
            for y in y0..<y1 {
                for x in x0..<x1 where ignored[y * common.width + x] == 0 {
                    ignored[y * common.width + x] = 1
                    ignoredPixels += 1
                }
            }
        }

        var changed = [UInt8](repeating: 0, count: max(0, common.width * common.height))
        var antiAliased = [UInt8](repeating: 0, count: max(0, common.width * common.height))
        var differentPixels = 0
        var antiAliasedPixels = 0
        var maximumChannelDelta = 0
        var maximumSquaredDelta = 0.0

        for y in 0..<common.height {
            for x in 0..<common.width {
                let index = y * common.width + x
                guard ignored[index] == 0 else { continue }

                let channelDelta = channelDistance(baseline, actual, x: x, y: y)
                maximumChannelDelta = max(maximumChannelDelta, channelDelta)

                let delta = abs(colorDelta(baseline, actual, x: x, y: y, luminanceOnly: false))
                // The squared distance is what ranks; the root is taken once at the end rather
                // than per pixel, because this loop runs twenty million times on a full-page pair.
                maximumSquaredDelta = max(maximumSquaredDelta, delta)
                guard delta > maximumDelta else { continue }

                if options.ignoresAntiAliasing,
                   isAntiAliased(baseline, other: actual, x: x, y: y, within: common)
                    || isAntiAliased(actual, other: baseline, x: x, y: y, within: common) {
                    antiAliased[index] = 1
                    antiAliasedPixels += 1
                    continue
                }
                changed[index] = 1
                differentPixels += 1
            }
        }

        let comparedPixels = max(0, common.width * common.height - ignoredPixels)
        let ratio = comparedPixels == 0 ? 0 : Double(differentPixels) / Double(comparedPixels)
        let diff = options.producesDiffImage
            ? renderDiff(
                actual: actual,
                baseline: baseline,
                common: common,
                changed: changed,
                antiAliased: antiAliased,
                ignored: ignored
            )
            : nil

        return BrowserVisualComparison(
            // A dimension mismatch always fails, whatever the overlap looked like: the two captures
            // are not of the same thing, and a pass would be the comparator agreeing that they are.
            matches: dimensionsMatch && ratio <= options.maximumDifferentRatio,
            dimensionsMatch: dimensionsMatch,
            width: actual.width,
            height: actual.height,
            baselineWidth: baseline.width,
            baselineHeight: baseline.height,
            widthDelta: actual.width - baseline.width,
            heightDelta: actual.height - baseline.height,
            comparedWidth: common.width,
            comparedHeight: common.height,
            comparedPixels: comparedPixels,
            differentPixels: differentPixels,
            differentRatio: ratio,
            antiAliasedPixels: antiAliasedPixels,
            ignoredPixels: ignoredPixels,
            maximumChannelDelta: maximumChannelDelta,
            maximumPerceptualDelta: min(
                1,
                (maximumSquaredDelta / BrowserVisualComparisonDefaults.maximumYIQDistance)
                    .squareRoot()
            ),
            diffPNG: diff,
            changedMask: BrowserChangedPixelMask(
                width: common.width,
                height: common.height,
                values: changed
            )
        )
    }

    // MARK: Distance

    /// The composited RGB sample at one pixel, as the screen showed it.
    ///
    /// The buffers are **premultiplied** — `CGBitmapContext` offers no straight-alpha 8-bit RGBA
    /// format, so that is what the decode produces — which makes compositing onto white exactly
    /// `channel + 255·(1 − α)` rather than the straight-alpha `255 + (channel − 255)·α`. Getting
    /// this the wrong way round is silent: fully opaque pixels are identical under both, so only
    /// pages with real transparency would have disagreed, and they would have disagreed subtly.
    ///
    /// White is the ground because that is what an unpainted page is, and because the two sides
    /// must be composited onto the *same* one for the difference between them to mean anything.
    private static func composited(
        _ pixels: Pixels,
        x: Int,
        y: Int
    ) -> (r: Double, g: Double, b: Double) {
        let offset = (y * pixels.width + x) * 4
        let clear = 255 * (1 - Double(pixels.bytes[offset + 3]) / 255)
        return (
            Double(pixels.bytes[offset]) + clear,
            Double(pixels.bytes[offset + 1]) + clear,
            Double(pixels.bytes[offset + 2]) + clear
        )
    }

    private static func luminance(_ colour: (r: Double, g: Double, b: Double)) -> Double {
        colour.r * 0.298_895_31 + colour.g * 0.586_622_47 + colour.b * 0.114_482_23
    }

    private static func inPhase(_ colour: (r: Double, g: Double, b: Double)) -> Double {
        colour.r * 0.595_977_99 - colour.g * 0.274_176_10 - colour.b * 0.321_801_89
    }

    private static func quadrature(_ colour: (r: Double, g: Double, b: Double)) -> Double {
        colour.r * 0.211_470_17 - colour.g * 0.522_617_11 + colour.b * 0.311_146_94
    }

    /// The squared YIQ distance between the same pixel in two buffers.
    ///
    /// Signed by which side is brighter, because the anti-aliasing detector needs to know whether a
    /// neighbour is darker or lighter, not merely that it differs.
    static func colorDelta(
        _ first: Pixels,
        _ second: Pixels,
        x: Int,
        y: Int,
        otherX: Int? = nil,
        otherY: Int? = nil,
        luminanceOnly: Bool
    ) -> Double {
        let left = composited(first, x: x, y: y)
        let right = composited(second, x: otherX ?? x, y: otherY ?? y)
        let leftY = luminance(left)
        let rightY = luminance(right)
        if luminanceOnly { return leftY - rightY }

        let deltaY = leftY - rightY
        let deltaI = inPhase(left) - inPhase(right)
        let deltaQ = quadrature(left) - quadrature(right)
        let delta = 0.5053 * deltaY * deltaY + 0.299 * deltaI * deltaI + 0.1957 * deltaQ * deltaQ
        return leftY > rightY ? -delta : delta
    }

    /// The old per-channel measure, retained purely as a reported number.
    private static func channelDistance(_ first: Pixels, _ second: Pixels, x: Int, y: Int) -> Int {
        let offset = (y * first.width + x) * 4
        let otherOffset = (y * second.width + x) * 4
        var delta = 0
        for channel in 0..<4 {
            delta = max(
                delta,
                abs(Int(first.bytes[offset + channel]) - Int(second.bytes[otherOffset + channel]))
            )
        }
        return delta
    }

    // MARK: Anti-aliasing

    /// pixelmatch's detector, ported.
    ///
    /// A pixel sits on an anti-aliased edge when its neighbourhood holds both a distinctly darker
    /// and a distinctly lighter neighbour, and at least one of those two is a flat-region pixel —
    /// it has three or more identical siblings — in *both* images. The "in both" half is what stops
    /// a genuinely new edge from being written off as anti-aliasing: a new edge has flat siblings
    /// on only one side of the comparison.
    static func isAntiAliased(
        _ pixels: Pixels,
        other: Pixels,
        x: Int,
        y: Int,
        within common: (width: Int, height: Int)
    ) -> Bool {
        let x0 = max(x - 1, 0)
        let y0 = max(y - 1, 0)
        let x1 = min(x + 1, common.width - 1)
        let y1 = min(y + 1, common.height - 1)
        var zeroes = (x == x0 || x == x1 || y == y0 || y == y1) ? 1 : 0
        var minimum = 0.0
        var maximum = 0.0
        var minimumPoint: (x: Int, y: Int)?
        var maximumPoint: (x: Int, y: Int)?

        for neighbourY in y0...y1 {
            for neighbourX in x0...x1 {
                if neighbourX == x, neighbourY == y { continue }
                let delta = colorDelta(
                    pixels,
                    pixels,
                    x: x,
                    y: y,
                    otherX: neighbourX,
                    otherY: neighbourY,
                    luminanceOnly: true
                )
                if delta == 0 {
                    zeroes += 1
                    if zeroes > 2 { return false }
                } else if delta < minimum {
                    minimum = delta
                    minimumPoint = (neighbourX, neighbourY)
                } else if delta > maximum {
                    maximum = delta
                    maximumPoint = (neighbourX, neighbourY)
                }
            }
        }

        guard minimum != 0, maximum != 0,
              let darkest = minimumPoint, let lightest = maximumPoint else {
            return false
        }
        return (hasManySiblings(pixels, x: darkest.x, y: darkest.y, within: common)
            && hasManySiblings(other, x: darkest.x, y: darkest.y, within: common))
            || (hasManySiblings(pixels, x: lightest.x, y: lightest.y, within: common)
                && hasManySiblings(other, x: lightest.x, y: lightest.y, within: common))
    }

    /// Whether a pixel is inside a flat region: three or more of its eight neighbours are exactly
    /// it. An image edge counts as one sibling, because the pixels beyond it are not evidence
    /// either way.
    private static func hasManySiblings(
        _ pixels: Pixels,
        x: Int,
        y: Int,
        within common: (width: Int, height: Int)
    ) -> Bool {
        let x0 = max(x - 1, 0)
        let y0 = max(y - 1, 0)
        let x1 = min(x + 1, common.width - 1)
        let y1 = min(y + 1, common.height - 1)
        var zeroes = (x == x0 || x == x1 || y == y0 || y == y1) ? 1 : 0
        let offset = (y * pixels.width + x) * 4

        for neighbourY in y0...y1 {
            for neighbourX in x0...x1 {
                if neighbourX == x, neighbourY == y { continue }
                let neighbourOffset = (neighbourY * pixels.width + neighbourX) * 4
                let identical = pixels.bytes[offset] == pixels.bytes[neighbourOffset]
                    && pixels.bytes[offset + 1] == pixels.bytes[neighbourOffset + 1]
                    && pixels.bytes[offset + 2] == pixels.bytes[neighbourOffset + 2]
                    && pixels.bytes[offset + 3] == pixels.bytes[neighbourOffset + 3]
                if identical {
                    zeroes += 1
                    if zeroes > 2 { return true }
                }
            }
        }
        return false
    }

    // MARK: Evidence

    /// The picture the user is shown.
    ///
    /// Drawn at the union of both extents rather than at the actual's size, so a page that shrank
    /// does not quietly crop the evidence of where it used to end. Red is a difference, amber is a
    /// suppressed anti-aliasing edge, blue is an ignored rectangle, and the band outside the
    /// compared region is drawn in a flat tint that means exactly "nothing was compared here".
    private static func renderDiff(
        actual: Pixels,
        baseline: Pixels,
        common: (width: Int, height: Int),
        changed: [UInt8],
        antiAliased: [UInt8],
        ignored: [UInt8]
    ) -> Data? {
        let width = max(actual.width, baseline.width)
        let height = max(actual.height, baseline.height)
        guard width > 0, height > 0 else { return nil }
        var diff = [UInt8](repeating: 0, count: width * height * 4)

        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                guard x < common.width, y < common.height else {
                    // Outside the overlap: one capture has pixels here and the other does not.
                    diff[offset] = 90
                    diff[offset + 1] = 60
                    diff[offset + 2] = 120
                    diff[offset + 3] = 90
                    continue
                }
                let index = y * common.width + x
                let source = (y * actual.width + x) * 4
                if changed[index] != 0 {
                    diff[offset] = 255
                    diff[offset + 1] = 40
                    diff[offset + 2] = 40
                    diff[offset + 3] = 255
                } else if antiAliased[index] != 0 {
                    diff[offset] = 235
                    diff[offset + 1] = 170
                    diff[offset + 2] = 40
                    diff[offset + 3] = 200
                } else if ignored[index] != 0 {
                    diff[offset] = 60
                    diff[offset + 1] = 130
                    diff[offset + 2] = 220
                    diff[offset + 3] = 110
                } else {
                    let tone = UInt8(
                        (
                            Int(actual.bytes[source])
                                + Int(actual.bytes[source + 1])
                                + Int(actual.bytes[source + 2])
                        ) / 3
                    )
                    diff[offset] = tone
                    diff[offset + 1] = tone
                    diff[offset + 2] = tone
                    diff[offset + 3] = 72
                }
            }
        }
        return encodeRGBA(diff, width: width, height: height)
    }

    // MARK: Decoding

    /// 8-bit sRGB RGBA, premultiplied — the one representation everything above assumes, and the
    /// only one a `CGBitmapContext` will produce at this depth.
    struct Pixels: Equatable {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        init(width: Int, height: Int, bytes: [UInt8]) {
            self.width = width
            self.height = height
            self.bytes = bytes
        }
    }

    static func decodeRGBA(_ data: Data) throws -> Pixels {
        guard data.count <= BrowserBaselineDefaults.maximumImageBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0,
              height > 0 else {
            throw BrowserVisualComparisonError.invalidPNG
        }
        guard BrowserBaselineImage.isWithinComparisonLimits((width, height)) else {
            throw BrowserVisualComparisonError.imageTooLarge
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == width,
              image.height == height else {
            throw BrowserVisualComparisonError.invalidPNG
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
            return L10n.string(
                "threshold must be between 0 and 1, and channel_threshold between 0 and 255."
            )
        case .invalidRatio:
            return L10n.string("maximum_different_ratio must be between 0 and 1.")
        }
    }
}
