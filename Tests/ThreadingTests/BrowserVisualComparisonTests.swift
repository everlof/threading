import XCTest

@testable import Threading

/// The comparator, the region labeller and the structural matcher.
///
/// All three are pure, and all three are where a wrong answer is most expensive: a comparator that
/// reports re-rasterized text as a change gets its threshold raised until it can no longer detect
/// anything, and a matcher that pairs the wrong nodes produces a confident sentence about a change
/// that did not happen.
final class BrowserVisualComparisonTests: XCTestCase {

    // MARK: - Perceptual distance

    func testIdenticalImagesMatchAndAnObviousChangeDoesNot() throws {
        let black = try Self.png(width: 4, height: 4) { _, _ in .black }
        let oneRed = try Self.png(width: 4, height: 4) { x, y in
            x == 0 && y == 0 ? .red : .black
        }

        let identical = try BrowserVisualComparator.compare(
            baseline: black,
            actual: black,
            options: BrowserVisualComparisonOptions(maximumDifferentRatio: 0)
        )
        XCTAssertTrue(identical.matches)
        XCTAssertEqual(identical.differentPixels, 0)
        XCTAssertEqual(identical.comparedPixels, 16)

        let changed = try BrowserVisualComparator.compare(
            baseline: black,
            actual: oneRed,
            options: BrowserVisualComparisonOptions(maximumDifferentRatio: 0)
        )
        XCTAssertFalse(changed.matches)
        XCTAssertEqual(changed.differentPixels, 1)
        XCTAssertEqual(changed.differentRatio, 1.0 / 16, accuracy: 0.000_001)
        XCTAssertGreaterThan(changed.maximumPerceptualDelta, 0)
    }

    /// The reason YIQ replaced the per-channel maximum: the eye is far more sensitive to a
    /// luminance step than to the same numeric step in blue.
    func testLuminanceIsWeightedAboveChroma() throws {
        let base = try Self.png(width: 2, height: 2) { _, _ in
            NSColor(deviceRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        }
        let brighter = try Self.png(width: 2, height: 2) { _, _ in
            NSColor(deviceRed: 0.62, green: 0.62, blue: 0.62, alpha: 1)
        }
        let bluer = try Self.png(width: 2, height: 2) { _, _ in
            NSColor(deviceRed: 0.5, green: 0.5, blue: 0.62, alpha: 1)
        }
        let options = BrowserVisualComparisonOptions(
            threshold: 0,
            maximumDifferentRatio: 1,
            ignoresAntiAliasing: false
        )
        let luminance = try BrowserVisualComparator.compare(
            baseline: base, actual: brighter, options: options
        )
        let chroma = try BrowserVisualComparator.compare(
            baseline: base, actual: bluer, options: options
        )
        // The same per-channel delta, and the comparator says one is much further away.
        XCTAssertEqual(luminance.maximumChannelDelta, chroma.maximumChannelDelta)
        XCTAssertGreaterThan(luminance.maximumPerceptualDelta, chroma.maximumPerceptualDelta)
    }

    func testTheLegacyChannelThresholdTranslatesToAPerceptualOne() {
        // A grey step of Δ moves luminance by exactly Δ, so the mapping is a computation rather
        // than a constant somebody picked.
        XCTAssertEqual(BrowserVisualComparator.perceptualThreshold(forChannelDelta: 0), 0)
        let sixteen = BrowserVisualComparator.perceptualThreshold(forChannelDelta: 16)
        XCTAssertEqual(sixteen, 0.0606, accuracy: 0.001)
        XCTAssertGreaterThan(
            BrowserVisualComparator.perceptualThreshold(forChannelDelta: 32),
            sixteen
        )
    }

    /// Alpha is composited, not compared. Two pixels that differ only in transparency over an
    /// opaque page looked identical on screen.
    func testTransparencyIsCompositedRatherThanTreatedAsAFourthChannel() throws {
        let opaqueWhite = try Self.png(width: 2, height: 2) { _, _ in
            NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1)
        }
        let clear = try Self.png(width: 2, height: 2) { _, _ in
            NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 0)
        }
        let comparison = try BrowserVisualComparator.compare(
            baseline: opaqueWhite,
            actual: clear,
            options: BrowserVisualComparisonOptions(
                threshold: 0,
                maximumDifferentRatio: 0,
                ignoresAntiAliasing: false
            )
        )
        // Fully transparent over white *is* white. A comparator treating alpha as a channel would
        // report every pixel changed here.
        XCTAssertEqual(comparison.differentPixels, 0)
        XCTAssertTrue(comparison.matches)
    }

    // MARK: - Anti-aliasing

    /// A one-pixel shift of an edge is what WebKit does to text for reasons that have nothing to do
    /// with the page. With suppression on it is not a change; with it off it is.
    func testAnAntiAliasedEdgeIsSuppressedAndCanStillBeSeenWhenAsked() throws {
        let baseline = try Self.png(width: 12, height: 12) { x, _ in
            x < 5 ? .black : (x == 5 ? .gray : .white)
        }
        let shifted = try Self.png(width: 12, height: 12) { x, _ in
            x < 5 ? .black : (x == 5 ? .lightGray : .white)
        }
        let suppressed = try BrowserVisualComparator.compare(
            baseline: baseline,
            actual: shifted,
            options: BrowserVisualComparisonOptions(
                threshold: 0.05,
                maximumDifferentRatio: 0,
                ignoresAntiAliasing: true
            )
        )
        let raw = try BrowserVisualComparator.compare(
            baseline: baseline,
            actual: shifted,
            options: BrowserVisualComparisonOptions(
                threshold: 0.05,
                maximumDifferentRatio: 0,
                ignoresAntiAliasing: false
            )
        )
        XCTAssertGreaterThan(raw.differentPixels, 0)
        XCTAssertLessThan(suppressed.differentPixels, raw.differentPixels)
        XCTAssertGreaterThan(suppressed.antiAliasedPixels, 0)
    }

    // MARK: - Dimensions

    func testASizeChangeFailsAndStillReportsTheOverlap() throws {
        let small = try Self.png(width: 4, height: 4) { _, _ in .black }
        let taller = try Self.png(width: 4, height: 6) { _, y in y < 4 ? .black : .red }

        let comparison = try BrowserVisualComparator.compare(
            baseline: small,
            actual: taller,
            options: BrowserVisualComparisonOptions(maximumDifferentRatio: 1)
        )
        XCTAssertFalse(comparison.matches, "A dimension mismatch always fails")
        XCTAssertFalse(comparison.dimensionsMatch)
        XCTAssertEqual(comparison.widthDelta, 0)
        XCTAssertEqual(comparison.heightDelta, 2)
        XCTAssertEqual(comparison.comparedWidth, 4)
        XCTAssertEqual(comparison.comparedHeight, 4)
        // The overlap was identical, so the old "differentRatio 1.0, no diff" answer is gone.
        XCTAssertEqual(comparison.differentPixels, 0)
        XCTAssertNotNil(comparison.diffPNG, "A size change still produces evidence")
    }

    // MARK: - Ignore rectangles

    func testAnIgnoredRectangleLeavesBothHalvesOfTheRatio() throws {
        let baseline = try Self.png(width: 4, height: 4) { _, _ in .black }
        let clockChanged = try Self.png(width: 4, height: 4) { x, y in
            x < 2 && y < 2 ? .red : .black
        }
        let comparison = try BrowserVisualComparator.compare(
            baseline: baseline,
            actual: clockChanged,
            options: BrowserVisualComparisonOptions(
                maximumDifferentRatio: 0,
                ignoresAntiAliasing: false,
                ignoredRects: [BrowserIgnoreRect(x: 0, y: 0, width: 2, height: 2)]
            )
        )
        XCTAssertTrue(comparison.matches)
        XCTAssertEqual(comparison.differentPixels, 0)
        XCTAssertEqual(comparison.ignoredPixels, 4)
        // The denominator shrank too: an ignore must not make a small change look smaller.
        XCTAssertEqual(comparison.comparedPixels, 12)
    }

    // MARK: - Regions

    func testNearbyChangedPixelsBecomeOneRegionRatherThanManyLetters() throws {
        // Two clusters, far enough apart to stay separate: what a changed word and a changed badge
        // on the other side of a page look like to the mask.
        var values = [UInt8](repeating: 0, count: 100 * 40)
        for y in 10..<14 {
            for x in stride(from: 5, to: 25, by: 3) {
                values[y * 100 + x] = 1
            }
        }
        for y in 30..<34 {
            for x in 80..<86 {
                values[y * 100 + x] = 1
            }
        }
        let mask = BrowserChangedPixelMask(width: 100, height: 40, values: values)
        let regions = BrowserRegionLabeller.regions(in: mask)

        XCTAssertEqual(regions.count, 2, "Glyph-sized components coalesce; distant ones do not")
        // Largest first, and the box never claims more area than the mask actually covered.
        XCTAssertGreaterThanOrEqual(regions[0].changedPixels, regions[1].changedPixels)
        for region in regions {
            XCTAssertGreaterThan(region.width, 0)
            XCTAssertGreaterThan(region.height, 0)
            XCTAssertLessThanOrEqual(region.x + region.width, mask.width)
            XCTAssertLessThanOrEqual(region.y + region.height, mask.height)
        }
    }

    func testRegionsAreAttributedToTheMostSpecificElementTheyOverlap() throws {
        let state = BrowserAttributionState(
            schemaVersion: 1,
            scrollX: 0,
            scrollY: 0,
            nodes: [
                Self.node(id: 1, depth: 0, tag: "body", role: nil, name: nil, box: (0, 0, 200, 200)),
                Self.node(
                    id: 2, depth: 3, tag: "button", role: "button", name: "Sign in",
                    box: (10, 10, 60, 24)
                )
            ],
            truncated: false,
            visitedElements: 2
        )
        let region = BrowserChangedRegion(x: 12, y: 12, width: 20, height: 10, changedPixels: 100)
        let attributed = BrowserRegionAttributor.attribute(
            [region],
            using: state,
            space: BrowserCaptureSpace(offsetX: 0, offsetY: 0, scale: 1)
        )
        let first = try XCTUnwrap(attributed.first?.overlaps.first)
        XCTAssertEqual(first.nodeID, 2, "The button, not the body that covers everything")
        XCTAssertTrue(first.label.contains("Sign in"))
    }

    func testARegionOverNothingSaysSoRatherThanClaimingAnAncestor() {
        let state = BrowserAttributionState(
            schemaVersion: 1,
            scrollX: 0,
            scrollY: 0,
            nodes: [
                Self.node(id: 1, depth: 2, tag: "div", role: nil, name: nil, box: (0, 0, 10, 10))
            ],
            truncated: false,
            visitedElements: 1
        )
        let region = BrowserChangedRegion(x: 50, y: 50, width: 10, height: 10, changedPixels: 40)
        let attributed = BrowserRegionAttributor.attribute(
            [region],
            using: state,
            space: BrowserCaptureSpace(offsetX: 0, offsetY: 0, scale: 1)
        )
        XCTAssertEqual(attributed.first?.overlaps.count, 0)
    }

    // MARK: - Capture space

    /// The three capture kinds do not share an origin, and getting this wrong silently attributes
    /// every region to whatever is near the top of the page.
    @MainActor
    func testCaptureSpaceDiffersByCaptureKind() {
        let viewport = BrowserCaptureSpace.forCapture(
            BrowserBaselineStoreTests.conditions(width: 100, height: 100, kind: .viewport),
            attributionScrollX: 0,
            attributionScrollY: 400
        )
        XCTAssertEqual(viewport.offsetY, 0)

        let fullPage = BrowserCaptureSpace.forCapture(
            BrowserBaselineStoreTests.conditions(width: 100, height: 100, kind: .fullPage),
            attributionScrollX: 0,
            attributionScrollY: 400
        )
        XCTAssertEqual(fullPage.offsetY, 400, "A document capture starts at the document origin")
    }

    // MARK: - Structure

    func testMatchingUsesSemanticEvidenceAndNeverRefEquality() throws {
        // Same refs on both sides, different elements: refs restart at 1 for each document, so
        // matching on them would pair the button with the heading.
        let baseline = BrowserAttributionState(
            schemaVersion: 1,
            scrollX: 0,
            scrollY: 0,
            nodes: [
                Self.node(
                    id: 1, depth: 2, tag: "button", role: "button", name: "Sign in",
                    box: (10, 10, 80, 30), ref: "e1", testID: "signin"
                )
            ],
            truncated: false,
            visitedElements: 1
        )
        let actual = BrowserAttributionState(
            schemaVersion: 1,
            scrollX: 0,
            scrollY: 0,
            nodes: [
                Self.node(
                    id: 1, depth: 2, tag: "h1", role: "heading", name: "Welcome",
                    box: (0, 0, 200, 40), ref: "e1", testID: "title"
                ),
                Self.node(
                    id: 2, depth: 2, tag: "button", role: "button", name: "Sign in",
                    box: (10, 22, 80, 30), ref: "e2", testID: "signin"
                )
            ],
            truncated: false,
            visitedElements: 2
        )
        let regions = [
            BrowserChangedRegion(x: 0, y: 0, width: 200, height: 60, changedPixels: 900)
        ]
        let findings = BrowserStructuralDiff.compare(
            baseline: baseline,
            actual: actual,
            baselineSpace: BrowserCaptureSpace(offsetX: 0, offsetY: 0, scale: 1),
            actualSpace: BrowserCaptureSpace(offsetX: 0, offsetY: 0, scale: 1),
            regions: regions
        )

        XCTAssertTrue(
            findings.contains { $0.kind == .added && $0.label.contains("Welcome") },
            "The heading is new"
        )
        let moved = try XCTUnwrap(findings.first { $0.kind == .moved })
        XCTAssertTrue(moved.label.contains("Sign in"))
        XCTAssertTrue(moved.detail.contains("+12"), "12 pixels down, signed")
        XCTAssertFalse(
            findings.contains { $0.kind == .removed },
            "Nothing was removed; the button matched by its test id, not by its ref"
        )
    }

    func testAnAmbiguousMatchIsReportedRatherThanGuessed() {
        let twins = (1...2).map { index in
            Self.node(
                id: index, depth: 2, tag: "li", role: nil, name: nil,
                box: (0, Double(index) * 20, 100, 18)
            )
        }
        let state = BrowserAttributionState(
            schemaVersion: 1, scrollX: 0, scrollY: 0,
            nodes: twins, truncated: false, visitedElements: 2
        )
        // Both sides hold two identically-keyed rows, so no pairing is defensible.
        let findings = BrowserStructuralDiff.compare(
            baseline: state,
            actual: state,
            baselineSpace: BrowserCaptureSpace(offsetX: 0, offsetY: 0, scale: 1),
            actualSpace: BrowserCaptureSpace(offsetX: 0, offsetY: 0, scale: 1),
            regions: []
        )
        XCTAssertTrue(findings.allSatisfy { $0.kind == .ambiguous })
    }

    // MARK: - Fixtures

    static func node(
        id: Int,
        depth: Int,
        tag: String,
        role: String?,
        name: String?,
        box: (Double, Double, Double, Double),
        ref: String? = nil,
        testID: String? = nil,
        styles: [String: String] = [:]
    ) -> BrowserAttributionState.Node {
        BrowserAttributionState.Node(
            id: id,
            parent: nil,
            depth: depth,
            ref: ref,
            tag: tag,
            role: role,
            name: name,
            testID: testID,
            siblingIndex: id,
            ancestors: "body",
            pseudo: nil,
            x: box.0,
            y: box.1,
            width: box.2,
            height: box.3,
            styles: styles
        )
    }

    static func png(
        width: Int,
        height: Int,
        color: (Int, Int) -> NSColor
    ) throws -> Data {
        let representation = try XCTUnwrap(NSBitmapImageRep(
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
        ))
        let bytes = try XCTUnwrap(representation.bitmapData)
        for y in 0..<height {
            for x in 0..<width {
                let resolved = try XCTUnwrap(color(x, y).usingColorSpace(.deviceRGB))
                let offset = y * representation.bytesPerRow + x * 4
                bytes[offset] = UInt8((resolved.redComponent * 255).rounded())
                bytes[offset + 1] = UInt8((resolved.greenComponent * 255).rounded())
                bytes[offset + 2] = UInt8((resolved.blueComponent * 255).rounded())
                bytes[offset + 3] = UInt8((resolved.alphaComponent * 255).rounded())
            }
        }
        return try XCTUnwrap(representation.representation(using: .png, properties: [:]))
    }
}
