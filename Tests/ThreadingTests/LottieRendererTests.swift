import AppKit
import XCTest
@testable import Threading
@testable import ThreadingExtensionKit

/// The host-owned Lottie engine: what it draws, and — more importantly — what it refuses.
///
/// The three format hazards each have a test of their own, because each is a way an untrusted
/// document from an agent could reach past the canvas: an expression is a scripting surface, a
/// filesystem asset reference is an arbitrary read, and a `.lottie` is a ZIP.
@MainActor
final class LottieRendererTests: XCTestCase {

    // MARK: - Parsing

    func testParsesAShapeDocumentAndReportsItsMetadata() throws {
        let document = try LottieParser.parse(
            LottieFixture.spinningDot(),
            limits: .default
        )
        XCTAssertEqual(document.frameRate, 30)
        XCTAssertEqual(document.width, 100)
        XCTAssertEqual(document.height, 100)
        XCTAssertEqual(document.duration, 1, accuracy: 0.0001)
        XCTAssertEqual(document.layers.count, 1)
        XCTAssertEqual(document.totalLayerCount, 1)
        XCTAssertTrue(document.notes.isEmpty, "a clean document reported \(document.notes)")
    }

    func testRefusesADocumentThatIsNotLottie() {
        XCTAssertThrowsError(
            try LottieParser.parse(Data("{\"hello\":true}".utf8), limits: .default)
        ) { error in
            guard case MediaDocumentFailure.invalidDocument = error else {
                return XCTFail("expected an invalid-document failure, got \(error)")
            }
        }
    }

    // MARK: - Expressions

    /// Lottie's expression subset is a scripting surface. A document that carries one renders
    /// **without** it and says so, rather than being refused outright or quietly evaluated.
    func testAnExpressionIsDisabledAndReported() throws {
        let document = try LottieParser.parse(
            LottieFixture.spinningDot(withExpression: true),
            limits: .default
        )
        XCTAssertTrue(
            document.notes.contains(LottieDocument.Note.expressionsDisabled),
            "the expression was not reported: \(document.notes)"
        )
        XCTAssertFalse(document.layers.isEmpty, "the document was refused rather than degraded")
    }

    // MARK: - External assets

    /// A bare Lottie may name an image by relative path. Resolving one would turn any animation
    /// an agent just wrote into an arbitrary file read.
    func testAFilesystemAssetReferenceIsDroppedAndReported() throws {
        let document = try LottieParser.parse(
            LottieFixture.withImageAsset(embedded: false),
            limits: .default
        )
        XCTAssertTrue(document.images.isEmpty, "a filesystem asset reference was resolved")
        XCTAssertTrue(
            document.notes.contains(LottieDocument.Note.externalAssetsDropped),
            "the dropped asset was not reported: \(document.notes)"
        )
    }

    func testAnEmbeddedBase64AssetIsAccepted() throws {
        let document = try LottieParser.parse(
            LottieFixture.withImageAsset(embedded: true),
            limits: .default
        )
        XCTAssertEqual(document.images.count, 1)
        XCTAssertFalse(document.notes.contains(LottieDocument.Note.externalAssetsDropped))
    }

    func testTextLayersAreDroppedAndReported() throws {
        let document = try LottieParser.parse(
            LottieFixture.withTextLayer(),
            limits: .default
        )
        XCTAssertTrue(document.notes.contains(LottieDocument.Note.textLayersDropped))
        XCTAssertEqual(document.layers.count, 1, "only the shape layer should survive")
    }

    // MARK: - Ceilings

    /// A document at each stated cap, and one past it. The assertion is that it fails with a
    /// stated reason rather than being partially drawn — a half-rendered animation reads as a
    /// rendering bug, which is the thing a ceiling is supposed to prevent.
    func testACeilingRefusesWithAStatedReasonRatherThanDrawingPartially() {
        var narrow = MediaDocumentLimits.default
        narrow.maximumLayerCount = 0
        XCTAssertThrowsError(
            try LottieParser.parse(LottieFixture.spinningDot(), limits: narrow)
        ) { error in
            guard case MediaDocumentFailure.exceedsLimits(let detail) = error else {
                return XCTFail("expected a limit failure, got \(error)")
            }
            XCTAssertFalse(detail.isEmpty, "the refusal did not say what it refused")
        }

        var tiny = MediaDocumentLimits.default
        tiny.maximumPixelDimension = 10
        XCTAssertThrowsError(
            try LottieParser.parse(LottieFixture.spinningDot(), limits: tiny)
        ) { error in
            guard case MediaDocumentFailure.exceedsLimits = error else {
                return XCTFail("expected a limit failure, got \(error)")
            }
        }

        var brief = MediaDocumentLimits.default
        brief.maximumFrameCount = 2
        XCTAssertThrowsError(
            try LottieParser.parse(LottieFixture.spinningDot(), limits: brief)
        ) { error in
            guard case MediaDocumentFailure.exceedsLimits = error else {
                return XCTFail("expected a limit failure, got \(error)")
            }
        }

        var small = MediaDocumentLimits.default
        small.maximumDocumentBytes = 8
        XCTAssertThrowsError(
            try LottieParser.parse(LottieFixture.spinningDot(), limits: small)
        ) { error in
            guard case MediaDocumentFailure.exceedsLimits = error else {
                return XCTFail("expected a limit failure, got \(error)")
            }
        }

        // At the cap rather than past it, the same document parses.
        var exact = MediaDocumentLimits.default
        exact.maximumLayerCount = 1
        XCTAssertNoThrow(try LottieParser.parse(LottieFixture.spinningDot(), limits: exact))
    }

    // MARK: - Rasterizing

    /// The engine draws something, in the right place, and the picture changes over the timeline.
    /// Sampling both ends is what separates "renders" from "renders the first frame forever" —
    /// the failure mode a still-image player would silently have.
    func testTheRasterizerDrawsTheDocumentAndTheFrameMoves() throws {
        let document = try LottieParser.parse(LottieFixture.spinningDot(), limits: .default)
        let rasterizer = LottieRasterizer(document: document)
        let size = CGSize(width: 100, height: 100)

        let first = try XCTUnwrap(rasterizer.image(atFrame: 0, pixelSize: size))
        let last = try XCTUnwrap(rasterizer.image(atFrame: 29, pixelSize: size))
        XCTAssertEqual(first.width, 100)
        XCTAssertEqual(first.height, 100)

        // The dot starts at the top-left quarter and ends at the bottom-right one.
        XCTAssertTrue(
            isInked(first, atX: 25, y: 25),
            "the first frame did not draw the dot where the document put it"
        )
        XCTAssertFalse(isInked(first, atX: 75, y: 75))
        XCTAssertTrue(
            isInked(last, atX: 75, y: 75),
            "the animation did not move: the last frame looks like the first"
        )
    }

    func testTheRasterizerFitsALargeDocumentIntoASmallCanvas() throws {
        let document = try LottieParser.parse(LottieFixture.spinningDot(), limits: .default)
        let rasterizer = LottieRasterizer(document: document)
        let image = try XCTUnwrap(rasterizer.image(
            atFrame: 0,
            pixelSize: CGSize(width: 40, height: 20)
        ))
        XCTAssertEqual(image.width, 40)
        XCTAssertEqual(image.height, 20)
    }

    // MARK: - What real documents do

    /// Three regressions, each found by running the engine over a corpus of real animations and
    /// each pinned here so the checked-in suite guards them without one.
    func testTheShapesRealDocumentsUseActuallyDraw() throws {
        // Each sample point is where that shape actually puts ink: the middle for a filled
        // rectangle, and a point *on the ring* for a stroked ellipse, whose middle is hollow by
        // construction.
        for (name, data, x, y) in [
            // A gradient whose colours move: bodymovin keyframes the whole flattened ramp, and
            // reading only the first frame of it drew a blank rectangle.
            ("animated gradient", LottieFixture.animatedGradient(), 50, 50),
            // A gradient-painted stroke — the loading-spinner idiom.
            ("gradient stroke", LottieFixture.gradientStroke(), 80, 50),
            // A keyframed property labelled static. Trusting the `a` flag read it as its
            // fallback, so a fill whose opacity keyframes start at zero never drew at all.
            ("mislabelled keyframes", LottieFixture.mislabelledKeyframes(), 50, 50)
        ] as [(String, Data, Int, Int)] {
            let document = try LottieParser.parse(data, limits: .default)
            let rasterizer = LottieRasterizer(document: document)
            let image = try XCTUnwrap(
                rasterizer.image(atFrame: 20, pixelSize: CGSize(width: 100, height: 100)),
                "\(name) produced no frame"
            )
            XCTAssertTrue(isInked(image, atX: x, y: y), "\(name) drew nothing")
        }

        // The hollow middle of that stroked ellipse is itself the assertion that the gradient was
        // clipped to the stroke's outline rather than flooding the shape.
        let stroked = try LottieParser.parse(LottieFixture.gradientStroke(), limits: .default)
        let ring = try XCTUnwrap(LottieRasterizer(document: stroked).image(
            atFrame: 20,
            pixelSize: CGSize(width: 100, height: 100)
        ))
        XCTAssertFalse(
            isInked(ring, atX: 50, y: 50),
            "the gradient filled the ellipse instead of its stroke"
        )
    }

    /// `ip`/`op` are the **composition's** time and `st` shifts only the layer's own clock.
    /// Testing visibility against the shifted clock made every staggered copy of a precomp
    /// invisible forever — which is how a four-burst firework animation renders as an empty
    /// canvas from beginning to end.
    func testAStaggeredPrecompIsVisibleInCompositionTime() throws {
        let document = try LottieParser.parse(
            LottieFixture.staggeredPrecomp(startFrame: 10),
            limits: .default
        )
        let rasterizer = LottieRasterizer(document: document)
        let size = CGSize(width: 100, height: 100)

        let before = try XCTUnwrap(rasterizer.image(atFrame: 5, pixelSize: size))
        XCTAssertFalse(
            isInked(before, atX: 50, y: 50),
            "the layer drew before its own in point"
        )

        let after = try XCTUnwrap(rasterizer.image(atFrame: 20, pixelSize: size))
        XCTAssertTrue(
            isInked(after, atX: 50, y: 50),
            "a layer whose start time equals its in point never became visible"
        )
    }

    // MARK: - Easing

    func testTheEasingCurveIsMonotonicAndPinnedAtBothEnds() {
        let out = CGPoint(x: 0.6, y: 0)
        let inControl = CGPoint(x: 0.4, y: 1)
        XCTAssertEqual(LottieEvaluator.ease(0, out: out, in: inControl), 0, accuracy: 0.001)
        XCTAssertEqual(LottieEvaluator.ease(1, out: out, in: inControl), 1, accuracy: 0.001)

        var previous = -1.0
        for step in 0...20 {
            let value = LottieEvaluator.ease(
                Double(step) / 20,
                out: out,
                in: inControl
            )
            XCTAssertGreaterThanOrEqual(value, previous - 0.0001, "the ease went backwards")
            previous = value
        }
    }

    func testAHoldKeyframeDoesNotInterpolate() {
        let scalar = LottieScalar.keyframes([
            LottieKeyframe(
                time: 0,
                value: 0,
                endValue: nil,
                outControl: nil,
                inControl: nil,
                isHold: true
            ),
            LottieKeyframe(
                time: 10,
                value: 100,
                endValue: nil,
                outControl: nil,
                inControl: nil,
                isHold: false
            )
        ])
        XCTAssertEqual(LottieEvaluator.value(of: scalar, at: 5), 0)
        XCTAssertEqual(LottieEvaluator.value(of: scalar, at: 10), 100)
    }

    // MARK: - Containers

    func testADotLottieContainerPlaysItsAnimationAndItsOwnImages() throws {
        let archive = try LottieFixture.dotLottie()
        let contents = try DotLottieArchive.read(archive, limits: .default)
        XCTAssertFalse(contents.animation.isEmpty)
        XCTAssertNotNil(contents.images["images/dot.png"])

        let document = try LottieDocumentRenderer.parse(archive, limits: .default)
        XCTAssertEqual(document.width, 100)
    }

    /// A `.lottie` is a ZIP, so it gets the archive ceilings — and an entry that tries to leave
    /// the archive is refused rather than normalized away.
    func testAnArchiveEntryCannotEscapeTheArchive() throws {
        XCTAssertEqual(BoundedZipArchive.normalized("../../keys.json"), "")
        XCTAssertEqual(BoundedZipArchive.normalized("/etc/passwd"), "")
        XCTAssertEqual(BoundedZipArchive.normalized("images/./dot.png"), "images/dot.png")

        let archive = try LottieFixture.dotLottie(includeTraversalEntry: true)
        let reader = try BoundedZipArchive(
            data: archive,
            limits: BoundedZipArchive.Limits(
                maximumEntryCount: 256,
                maximumEntryBytes: 1_024 * 1_024,
                maximumExpandedBytes: 4 * 1_024 * 1_024
            )
        )
        XCTAssertNil(
            try reader.data(atPath: "../escape.json"),
            "a traversal path resolved to an entry"
        )
        XCTAssertFalse(
            reader.entries(inDirectory: "images").contains { $0.name.contains("..") },
            "a traversing entry was listed inside a directory"
        )
    }

    func testAnArchiveWithTooManyEntriesIsRefused() throws {
        let archive = try LottieFixture.dotLottie()
        var narrow = MediaDocumentLimits.default
        narrow.maximumArchiveEntries = 1
        XCTAssertThrowsError(try DotLottieArchive.read(archive, limits: narrow)) { error in
            guard case MediaDocumentFailure.exceedsLimits = error else {
                return XCTFail("expected a limit failure, got \(error)")
            }
        }
    }

    // MARK: - The registry

    func testTheRegistryCarriesTheFormatsAndRefusesTheOnesItDoesNot() {
        XCTAssertTrue(MediaDocumentRendererRegistry.supports(.lottie))
        XCTAssertTrue(MediaDocumentRendererRegistry.supports(.dotLottie))
        XCTAssertTrue(MediaDocumentRendererRegistry.supports(.animatedImage))
        XCTAssertFalse(MediaDocumentRendererRegistry.supports(ExtensionMediaFormat(
            rawValue: "usdz"
        )))
    }

    // MARK: - Animated images

    /// The wart this renderer was written to fix: an animated GIF has always shown one frame,
    /// because the bounded still decoder reads index 0.
    func testAnAnimatedGIFReportsEveryFrameAndItsRealDuration() async throws {
        let gif = try XCTUnwrap(LottieFixture.animatedGIF(frames: 4, delay: 0.25))
        let session = try await AnimatedImageDocumentRenderer().open(gif, limits: .default)
        XCTAssertEqual(session.metadata.frameCount, 4)
        XCTAssertEqual(session.metadata.duration, 1, accuracy: 0.01)
        XCTAssertEqual(session.metadata.pixelWidth, 32)
        XCTAssertFalse(session.drivesItsOwnClock)
    }

    func testAnAnimatedImageBeyondTheFrameCeilingIsRefused() async throws {
        let gif = try XCTUnwrap(LottieFixture.animatedGIF(frames: 4, delay: 0.25))
        var narrow = MediaDocumentLimits.default
        narrow.maximumFrameCount = 2
        do {
            _ = try await AnimatedImageDocumentRenderer().open(gif, limits: narrow)
            XCTFail("the ceiling did not refuse the document")
        } catch let failure as MediaDocumentFailure {
            guard case .exceedsLimits = failure else {
                return XCTFail("expected a limit failure, got \(failure)")
            }
        }
    }

    // MARK: - Real documents

    /// Runs the engine over a directory of **real** Lottie documents.
    ///
    /// Opt-in through `THREADING_LOTTIE_CORPUS`, and deliberately not a checked-in corpus: the
    /// public sample collections carry a share-alike licence, and taking that obligation on for a
    /// test fixture is a worse trade than pointing the test at a directory. Hand it a folder — a
    /// LottieFiles download, a designer's export set, whatever the project actually ships — and it
    /// asserts the two things a synthetic fixture cannot:
    ///
    /// - every document either parses or **fails with a stated reason**; nothing crashes, hangs or
    ///   comes back half-built;
    /// - a parsed document draws ink at both ends of its own timeline, so a format feature the
    ///   subset does not carry shows up as a blank frame here rather than as a bug report.
    ///
    /// It prints a coverage summary — the notes and refusals, by frequency — because that summary
    /// is the evidence for whether the in-tree subset is still the right call. See
    /// `docs/architecture/media-documents.md`.
    func testARealLottieCorpusParsesAndDraws() throws {
        guard let path = ProcessInfo.processInfo.environment["THREADING_LOTTIE_CORPUS"] else {
            throw XCTSkip("Set THREADING_LOTTIE_CORPUS to a directory of real Lottie documents.")
        }
        let directory = URL(fileURLWithPath: path)
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        .filter { ["json", "lottie"].contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        try XCTSkipIf(files.isEmpty, "No Lottie documents in \(directory.path).")

        var parsed = 0
        var refused: [String: Int] = [:]
        var notes: [String: Int] = [:]
        var blank: [String] = []

        for file in files {
            let data = try Data(contentsOf: file)
            let document: LottieDocument
            do {
                document = try LottieDocumentRenderer.parse(data, limits: .default)
            } catch let failure as MediaDocumentFailure {
                // A refusal is a pass: the contract is that a document Threading cannot draw says
                // so, rather than being partially drawn.
                refused[Self.describe(failure), default: 0] += 1
                continue
            }
            parsed += 1
            for note in document.notes { notes[note, default: 0] += 1 }

            // Five points across the timeline rather than two. Real animations fade in, and a
            // document sampled only at its in point and its midpoint reads as blank whenever the
            // author put a hold keyframe at zero opacity — which is most fade-ins.
            let rasterizer = LottieRasterizer(document: document)
            let size = CGSize(width: 120, height: 120)
            let span = document.outPoint - document.inPoint
            var inked = false
            for step in 0..<5 {
                let sampled = document.inPoint + span * Double(step) / 4
                let image = try XCTUnwrap(
                    rasterizer.image(atFrame: min(sampled, document.outPoint - 1), pixelSize: size),
                    "\(file.lastPathComponent) produced no frame at \(sampled)"
                )
                if hasInk(image) {
                    inked = true
                    break
                }
            }
            if !inked { blank.append(file.lastPathComponent) }
        }

        if let out = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] {
            // A histogram says what was dropped; only a picture says whether what survived looks
            // like the animation. Written beside the ordinary storybooks so a corpus can be
            // eyeballed the same way every other visual in this repository is.
            try writeFilmstrips(for: files, into: URL(fileURLWithPath: out))
        }

        print("""
        Lottie corpus: \(files.count) documents, \(parsed) parsed, \
        \(files.count - parsed) refused.
        Refusals: \(refused.sorted { $0.value > $1.value })
        Notes: \(notes.sorted { $0.value > $1.value })
        Blank: \(blank.count) — \(blank.prefix(10))
        """)

        // A corpus of real animations that draws nothing is a broken renderer, not a narrow
        // subset. The threshold is deliberately generous: some documents genuinely start empty.
        XCTAssertLessThan(
            Double(blank.count),
            Double(max(parsed, 1)) * 0.25,
            "too many real documents drew nothing: \(blank)"
        )
    }

    /// One row of frames per document, across its own timeline.
    private func writeFilmstrips(for files: [URL], into directory: URL) throws {
        let frameSide = 120
        let columns = 5
        for file in files.prefix(8) {
            guard let data = try? Data(contentsOf: file),
                  let document = try? LottieDocumentRenderer.parse(data, limits: .default) else {
                continue
            }
            let rasterizer = LottieRasterizer(document: document)
            guard let strip = CGContext(
                data: nil,
                width: frameSide * columns,
                height: frameSide,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { continue }

            let span = document.outPoint - document.inPoint
            for step in 0..<columns {
                let frame = min(
                    document.inPoint + span * Double(step) / Double(columns),
                    document.outPoint - 1
                )
                guard let image = rasterizer.image(
                    atFrame: frame,
                    pixelSize: CGSize(width: frameSide, height: frameSide)
                ) else { continue }
                strip.draw(image, in: CGRect(
                    x: CGFloat(step * frameSide),
                    y: 0,
                    width: CGFloat(frameSide),
                    height: CGFloat(frameSide)
                ))
            }
            guard let composed = strip.makeImage() else { continue }
            let rep = NSBitmapImageRep(cgImage: composed)
            guard let png = rep.representation(using: .png, properties: [:]) else { continue }
            let name = file.deletingPathExtension().lastPathComponent
            try png.write(to: directory.appendingPathComponent("lottie-corpus-\(name).png"))
        }
    }

    private static func describe(_ failure: MediaDocumentFailure) -> String {
        switch failure {
        case .unsupportedFormat: "unsupported-format"
        case .unresolvedSource: "unresolved-source"
        case .invalidDocument(let detail): "invalid: \(detail)"
        case .exceedsLimits(let detail): "limit: \(detail)"
        }
    }

    private func hasInk(_ image: CGImage) -> Bool {
        guard let data = image.dataProvider?.data,
              let pointer = CFDataGetBytePtr(data) else { return false }
        let length = CFDataGetLength(data)
        var offset = 3
        while offset < length {
            if pointer[offset] > 8 { return true }
            offset += 4
        }
        return false
    }

    // MARK: - Sampling

    private func isInked(_ image: CGImage, atX x: Int, y: Int) -> Bool {
        guard let data = image.dataProvider?.data,
              let pointer = CFDataGetBytePtr(data) else { return false }
        let offset = y * image.bytesPerRow + x * 4
        guard offset + 3 < CFDataGetLength(data) else { return false }
        // Premultiplied-first little-endian: the alpha byte is the last of the four.
        return pointer[offset + 3] > 8
    }
}
