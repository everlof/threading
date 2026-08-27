import AppKit
import XCTest
@testable import Threading
@testable import ThreadingExtensionKit

/// Deterministic scale regressions for the media path.
///
/// The player is the only high-frequency surface in this feature — everything else in it is an
/// action round-trip — so the numbers that matter are per-frame ones, and a renderer without them
/// is a liability rather than a feature. Default sizes are large enough to catch accidental
/// quadratic work on every fast run; `THREADING_MEDIA_STRESS=1` raises them for a profiling pass.
///
/// The ceilings here are deliberately generous. They exist to fail on a *change in shape* — a
/// per-frame allocation, a walk that became quadratic, a queue that grew — not to pin a number to
/// this machine. Measured figures live in `docs/architecture/performance.md`.
@MainActor
final class MediaDocumentPerformanceTests: XCTestCase {

    private var isStressRun: Bool {
        ProcessInfo.processInfo.environment["THREADING_MEDIA_STRESS"] == "1"
    }

    private func stressValue(key: String, normal: Int, stressed: Int) -> Int {
        if let value = ProcessInfo.processInfo.environment[key].flatMap(Int.init), value > 0 {
            return value
        }
        return isStressRun ? stressed : normal
    }

    // MARK: - Parsing

    /// Parsing is off the main actor by construction, but it still has to be *linear* in layers:
    /// the ceiling exists to catch a per-layer pass over every other layer.
    func testAManyLayerDocumentParsesLinearly() throws {
        let small = LottieFixture.manyLayers(count: 50)
        let large = LottieFixture.manyLayers(
            count: stressValue(key: "THREADING_MEDIA_STRESS_LAYERS", normal: 200, stressed: 500)
        )
        var limits = MediaDocumentLimits.default
        limits.maximumLayerCount = 2_000
        limits.maximumDocumentBytes = 64 * 1_024 * 1_024

        let smallElapsed = try time { _ = try LottieParser.parse(small, limits: limits) }
        let largeElapsed = try time { _ = try LottieParser.parse(large, limits: limits) }

        let document = try LottieParser.parse(large, limits: limits)
        XCTAssertEqual(document.totalLayerCount, document.layers.count)
        XCTAssertGreaterThan(document.layers.count, 100)

        // Four times the layers must not cost sixteen times the work. Compared as a ratio rather
        // than an absolute so the assertion survives a slower machine.
        let ratio = largeElapsed / max(smallElapsed, 0.0001)
        XCTAssertLessThan(
            ratio,
            Double(document.layers.count) / 50 * 4,
            "parsing scaled worse than linearly: \(smallElapsed)s → \(largeElapsed)s"
        )
        print("PERF parse 50 layers=\(ms(smallElapsed)) \(document.layers.count) layers=\(ms(largeElapsed))")
    }

    // MARK: - Rasterizing

    /// One frame of a 200-layer document at each canvas size the contract names.
    ///
    /// This is the number the whole design rests on: it happens off the main actor, but it still
    /// decides whether a document can hold 60fps and how much of a core the player spends.
    func testRasterizingOneFrameStaysWithinItsBudgetAtEveryCanvasSize() throws {
        var limits = MediaDocumentLimits.default
        limits.maximumLayerCount = 2_000
        limits.maximumDocumentBytes = 64 * 1_024 * 1_024
        let layers = stressValue(
            key: "THREADING_MEDIA_STRESS_LAYERS",
            normal: 200,
            stressed: 500
        )
        let document = try LottieParser.parse(
            LottieFixture.manyLayers(count: layers),
            limits: limits
        )
        let rasterizer = LottieRasterizer(document: document)

        // The three sizes the performance contract names: a pane, a full-screen canvas, and the
        // backing-pixel cap the canvas clamps to.
        let cap = Double(MediaDocumentLimits.default.maximumBackingPixels).squareRoot()
        let sizes: [(String, CGSize)] = [
            ("800x600", CGSize(width: 800, height: 600)),
            ("1920x1080", CGSize(width: 1_920, height: 1_080)),
            ("backing-cap", CGSize(width: cap, height: cap))
        ]

        for (name, size) in sizes {
            // Warm once: the first frame pays for font/colour-space setup the rest do not.
            _ = rasterizer.image(atFrame: 0, pixelSize: size)

            let iterations = isStressRun ? 20 : 5
            let elapsed = try time {
                for step in 0..<iterations {
                    let frame = Double(step) / Double(iterations) * document.outPoint
                    XCTAssertNotNil(rasterizer.image(atFrame: frame, pixelSize: size))
                }
            } / Double(iterations)

            print("PERF rasterize \(layers) layers \(name)=\(ms(elapsed))/frame")
            XCTAssertLessThan(
                elapsed,
                1.0,
                "one \(name) frame of \(layers) layers took \(ms(elapsed))"
            )
        }
    }

    // MARK: - The main thread

    /// The player's own per-tick cost. `present(atProgress:)` hands the work to a detached task
    /// and returns, so what runs on the main actor per frame is bookkeeping — and if that ever
    /// stops being true, the number here is what says so.
    func testPresentingAFrameCostsTheMainActorAlmostNothing() async throws {
        var limits = MediaDocumentLimits.default
        limits.maximumLayerCount = 2_000
        limits.maximumDocumentBytes = 64 * 1_024 * 1_024
        let session = try await LottieDocumentRenderer().open(
            LottieFixture.manyLayers(count: 200),
            limits: limits
        )
        let host = CountingRenderHost(pixelSize: CGSize(width: 1_920, height: 1_080))
        session.attach(to: host)

        let ticks = 60
        let elapsed = try time {
            for step in 0..<ticks {
                session.present(atProgress: Double(step) / Double(ticks))
            }
        } / Double(ticks)

        print("PERF main-actor present=\(ms(elapsed))/tick")
        XCTAssertLessThan(
            elapsed,
            0.002,
            "the main actor spent \(ms(elapsed)) per tick — the rasterization is no longer off it"
        )
    }

    /// **Frames are superseded, never queued.** Sixty positions arriving while one frame is still
    /// rasterizing must not become sixty rasterizations: a player that queues drifts further
    /// behind real time the longer it runs, which is the failure this design exists to avoid.
    func testARunOfPositionsSupersedesRatherThanQueues() async throws {
        var limits = MediaDocumentLimits.default
        limits.maximumLayerCount = 2_000
        limits.maximumDocumentBytes = 64 * 1_024 * 1_024
        let session = try await LottieDocumentRenderer().open(
            LottieFixture.manyLayers(count: 200),
            limits: limits
        )
        let host = CountingRenderHost(pixelSize: CGSize(width: 1_024, height: 1_024))
        session.attach(to: host)

        for step in 0..<60 {
            session.present(atProgress: Double(step) / 60)
        }
        // Awaited rather than pumped. `RunLoop.run(until:)` blocks the main *thread*, and the
        // session's render continuation is enqueued on the main actor — so pumping never lets it
        // run and the count comes back zero, which reads exactly like a player that drew nothing.
        for _ in 0..<40 where host.presentedFrames < 2 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try await Task.sleep(nanoseconds: 300_000_000)

        print("PERF frames presented for 60 positions=\(host.presentedFrames)")
        XCTAssertGreaterThan(host.presentedFrames, 0, "the player drew nothing at all")
        XCTAssertLessThanOrEqual(
            host.presentedFrames,
            4,
            "60 positions produced \(host.presentedFrames) rasterizations — the player is queueing"
        )
    }

    // MARK: - The canvas

    /// The backing store is capped before anything is drawn, so a full-screen player on a Retina
    /// display cannot quietly ask for a 33-megapixel buffer.
    func testTheCanvasNeverExceedsItsBackingBudget() {
        let canvas = MediaDocumentCanvasView()
        for size in [
            NSSize(width: 1_920, height: 1_080),
            NSSize(width: 3_840, height: 2_160),
            NSSize(width: 8_000, height: 8_000)
        ] {
            canvas.frame = NSRect(origin: .zero, size: size)
            let pixels = canvas.renderPixelSize
            let total = Int(pixels.width * pixels.height)
            print("PERF canvas \(Int(size.width))x\(Int(size.height)) → \(Int(pixels.width))x\(Int(pixels.height)) (\(total) px)")
            XCTAssertLessThanOrEqual(total, MediaDocumentLimits.default.maximumBackingPixels)
            XCTAssertLessThanOrEqual(
                Int(max(pixels.width, pixels.height)),
                MediaDocumentLimits.default.maximumPixelDimension
            )
        }
    }

    // MARK: - Animated images

    func testDecodingAnAnimatedImageFrameStaysCheap() async throws {
        let gif = try XCTUnwrap(LottieFixture.animatedGIF(frames: 24, delay: 0.04, side: 512))
        let session = try await AnimatedImageDocumentRenderer().open(gif, limits: .default)
        let host = CountingRenderHost(pixelSize: CGSize(width: 512, height: 512))
        session.attach(to: host)

        let ticks = 24
        let elapsed = try time {
            for step in 0..<ticks {
                session.present(atProgress: Double(step) / Double(ticks))
            }
        } / Double(ticks)

        print("PERF gif decode+present=\(ms(elapsed))/frame")
        XCTAssertEqual(host.presentedFrames, ticks, "a frame was skipped or repeated")
        XCTAssertLessThan(elapsed, 0.05, "one GIF frame took \(ms(elapsed))")
    }

    // MARK: - Enumeration

    /// A five-thousand-file project, walked off the main actor and paged.
    func testEnumeratingALargeProjectIsBoundedAndPaged() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ThreadingMediaPerf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let fileCount = stressValue(
            key: "THREADING_MEDIA_STRESS_FILES",
            normal: 5_000,
            stressed: 20_000
        )
        let animation = LottieFixture.spinningDot()
        let filler = Data("{\"name\":\"filler\"}".utf8)
        for index in 0..<fileCount {
            let directory = root.appendingPathComponent("pkg-\(index / 100)")
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            // One in ten is an animation; the rest are the configuration files the probe has to
            // read and decline, which is the work a real checkout actually costs.
            try (index % 10 == 0 ? animation : filler)
                .write(to: directory.appendingPathComponent("file-\(index).json"))
        }

        let broker = ExtensionProjectFileBroker.shared
        let provider = PerfRootProvider(root: root)
        broker.rootProvider = provider
        defer {
            broker.revoke(generation: "perf")
            broker.rootProvider = nil
        }

        var cursor: String?
        var pages = 0
        var handles = 0
        let started = CFAbsoluteTimeGetCurrent()
        repeat {
            let page = try await broker.page(
                for: ExtensionFileQuery(
                    // The broker parses this into a `ProjectID`, so the fixture has to spell a
                    // real UUID even though `PerfRootProvider` answers every project alike.
                    projectID: "3f2a6c10-0000-4000-8000-000000000001",
                    fileExtensions: ["json"],
                    maximumResults: 200,
                    cursor: cursor
                ),
                extensionIdentifier: "codes.threading.perf",
                generation: "perf"
            )
            handles += page.handles.count
            cursor = page.nextCursor
            pages += 1
            XCTAssertLessThanOrEqual(page.handles.count, 200, "a page exceeded its own limit")
        } while cursor != nil && pages < 200
        let elapsed = CFAbsoluteTimeGetCurrent() - started

        print("PERF enumerate \(fileCount) files → \(handles) handles in \(pages) pages, \(ms(elapsed))")
        XCTAssertGreaterThan(handles, 0)
        XCTAssertLessThan(
            elapsed,
            isStressRun ? 60 : 20,
            "walking \(fileCount) files took \(ms(elapsed))"
        )
    }

    // MARK: - The probe

    /// The content probe's stated ceiling, as time rather than as a count. Thirty-two bounded
    /// prefix reads is the *whole* budget one scan may spend on ambiguous candidates.
    func testTheContentProbeCeilingIsCheapEnoughForAScan() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ThreadingProbePerf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Each candidate is far larger than the prefix, so the measurement is of the *bounded*
        // read rather than of reading the files.
        var bulky = Data("{\"layers\":[".utf8)
        bulky.append(Data(repeating: UInt8(ascii: "0"), count: 2 * 1_024 * 1_024))
        bulky.append(Data("]}".utf8))
        var urls: [URL] = []
        for index in 0..<MediaContentProbe.maximumCandidatesPerScan {
            let url = root.appendingPathComponent("candidate-\(index).json")
            try bulky.write(to: url)
            urls.append(url)
        }

        // Split, because "the probe is slow" is not actionable and "the read is slow" is. The
        // bounded prefix read and the signature scan are separate costs with separate fixes.
        var prefixes: [Data] = []
        let readElapsed = try time {
            prefixes = urls.compactMap { MediaContentProbe.prefix(of: $0) }
        }
        let scanElapsed = try time {
            for prefix in prefixes {
                _ = MediaContentProbe.hint(forPrefix: prefix, fileExtension: "json")
            }
        }
        let elapsed = try time {
            for url in urls {
                _ = MediaContentProbe.hint(for: url)
            }
        }
        XCTAssertEqual(prefixes.count, urls.count)
        print("""
        PERF probe \(urls.count) ambiguous candidates=\(ms(elapsed)) \
        (read \(ms(readElapsed)), scan \(ms(scanElapsed)))
        """)
        XCTAssertLessThan(
            elapsed,
            1.0,
            "a scan's whole probe budget cost \(ms(elapsed)) — it is reading past its prefix"
        )
    }

    // MARK: - Helpers

    private func time(_ body: () throws -> Void) rethrows -> Double {
        let started = CFAbsoluteTimeGetCurrent()
        try body()
        return CFAbsoluteTimeGetCurrent() - started
    }

    private func ms(_ seconds: Double) -> String {
        String(format: "%.2fms", seconds * 1_000)
    }
}

/// A render host that counts what it was handed, so "never queues" is a number rather than a hope.
@MainActor
private final class CountingRenderHost: MediaDocumentRenderHost {
    let contentLayer = CALayer()
    let backingScale: CGFloat = 2
    let renderPixelSize: CGSize
    private(set) var presentedFrames = 0

    init(pixelSize: CGSize) {
        renderPixelSize = pixelSize
    }

    func present(frame: CGImage) {
        presentedFrames += 1
    }
}

@MainActor
private final class PerfRootProvider: ExtensionProjectFileRootProviding {
    private let root: URL

    init(root: URL) {
        self.root = root
    }

    func projectCheckoutRoot(projectID: ProjectID) -> URL? { root }
    func sessionWorkspaceRoot(projectID: ProjectID, sessionID: SessionID) -> URL? { nil }
}
