import Foundation

// MARK: - Regions

/// One coalesced area of the capture that changed, and what it sits on top of.
struct BrowserChangedRegion: Equatable, Sendable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    /// Changed pixels inside the box, which is what ranks it. The box is a bound, not a fill: a
    /// diagonal line and a filled square can share a rectangle and mean very different things.
    let changedPixels: Int
    /// The nearest addressable elements the box overlaps, most-covered first. Empty is a real
    /// answer, and it is stated as one: canvas, images, backgrounds and pseudo content are all
    /// pixels no element box explains.
    var overlaps: [BrowserRegionOverlap] = []

    var area: Int { width * height }

    /// How much of the box the changed pixels actually fill, which is the difference between "this
    /// paragraph moved" and "these four words changed".
    var density: Double {
        area == 0 ? 0 : Double(changedPixels) / Double(area)
    }
}

/// An element a region falls on.
struct BrowserRegionOverlap: Equatable, Sendable {
    let nodeID: Int
    let label: String
    let ref: String?
    /// The fraction of the region's box covered by this element's box.
    let coverage: Double
}

/// Turns a changed-pixel mask into rectangles worth naming.
///
/// **Raw connected-component labelling is not the answer.** Run over a changed sentence it returns
/// one component per letter — dozens of three-by-five rectangles that say nothing a ratio did not
/// already say. The mask is therefore dilated first, so glyph- and edge-sized components in the same
/// neighbourhood become one region, then the boxes are merged, ranked by how many pixels actually
/// changed inside them, and capped.
///
/// The dilation is deliberately not applied to the *reported* boxes: a component's bounds are
/// recomputed from the original changed pixels it contains, so a region never claims more area than
/// really changed.
enum BrowserRegionLabeller {

    struct Options: Equatable, Sendable {
        /// How far apart two changed pixels may be and still belong to one region. Roughly a
        /// character's width at ordinary body sizes, which is the gap inside a word.
        var dilation: Int
        /// Boxes closer than this are merged after labelling, which is what joins the words of one
        /// changed line without joining two unrelated components across a panel.
        var mergeGap: Int
        /// Regions smaller than this are dropped as noise rather than reported.
        var minimumChangedPixels: Int
        var maximumRegions: Int

        init(
            dilation: Int = 6,
            mergeGap: Int = 12,
            minimumChangedPixels: Int = 4,
            maximumRegions: Int = 24
        ) {
            self.dilation = dilation
            self.mergeGap = mergeGap
            self.minimumChangedPixels = minimumChangedPixels
            self.maximumRegions = maximumRegions
        }
    }

    static func regions(
        in mask: BrowserChangedPixelMask,
        options: Options = Options()
    ) -> [BrowserChangedRegion] {
        guard mask.width > 0, mask.height > 0 else { return [] }
        let dilated = dilate(mask, by: options.dilation)
        var boxes = components(of: dilated, changed: mask)
        boxes = merge(boxes, gap: options.mergeGap)
        return boxes
            .filter { $0.changedPixels >= options.minimumChangedPixels }
            .sorted { $0.changedPixels > $1.changedPixels }
            .prefix(options.maximumRegions)
            .map { $0 }
    }

    // MARK: Dilation

    /// A separable box dilation: one horizontal pass, one vertical pass.
    ///
    /// Separable because the square-kernel form is O(width · height · radius²) and this is
    /// O(width · height · radius) for the same result — at a 6-pixel radius over a full-page
    /// capture that is the difference between a comparison feeling instant and feeling stuck.
    private static func dilate(_ mask: BrowserChangedPixelMask, by radius: Int) -> [UInt8] {
        guard radius > 0 else { return mask.values }
        var horizontal = [UInt8](repeating: 0, count: mask.width * mask.height)
        for y in 0..<mask.height {
            let row = y * mask.width
            var run = 0
            // Left to right: how far back the last changed pixel was.
            for x in 0..<mask.width {
                run = mask.values[row + x] != 0 ? radius + 1 : max(0, run - 1)
                if run > 0 { horizontal[row + x] = 1 }
            }
            run = 0
            for x in stride(from: mask.width - 1, through: 0, by: -1) {
                run = mask.values[row + x] != 0 ? radius + 1 : max(0, run - 1)
                if run > 0 { horizontal[row + x] = 1 }
            }
        }

        var result = [UInt8](repeating: 0, count: mask.width * mask.height)
        for x in 0..<mask.width {
            var run = 0
            for y in 0..<mask.height {
                run = horizontal[y * mask.width + x] != 0 ? radius + 1 : max(0, run - 1)
                if run > 0 { result[y * mask.width + x] = 1 }
            }
            run = 0
            for y in stride(from: mask.height - 1, through: 0, by: -1) {
                run = horizontal[y * mask.width + x] != 0 ? radius + 1 : max(0, run - 1)
                if run > 0 { result[y * mask.width + x] = 1 }
            }
        }
        return result
    }

    // MARK: Labelling

    /// Four-connected flood fill over the dilated mask, bounded by an explicit stack rather than
    /// recursion — a full-page capture's largest component can be most of the image, and that is
    /// far past what the call stack will take.
    private static func components(
        of dilated: [UInt8],
        changed mask: BrowserChangedPixelMask
    ) -> [BrowserChangedRegion] {
        var visited = [Bool](repeating: false, count: dilated.count)
        var regions: [BrowserChangedRegion] = []
        var stack: [Int] = []

        for start in 0..<dilated.count where dilated[start] != 0 && !visited[start] {
            visited[start] = true
            stack.removeAll(keepingCapacity: true)
            stack.append(start)

            var minX = mask.width
            var minY = mask.height
            var maxX = -1
            var maxY = -1
            var changedPixels = 0

            while let index = stack.popLast() {
                let x = index % mask.width
                let y = index / mask.width
                // Bounds come from the *original* mask, so a region never reports the dilation's
                // padding as area that changed.
                if mask.values[index] != 0 {
                    changedPixels += 1
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
                if x > 0, dilated[index - 1] != 0, !visited[index - 1] {
                    visited[index - 1] = true
                    stack.append(index - 1)
                }
                if x + 1 < mask.width, dilated[index + 1] != 0, !visited[index + 1] {
                    visited[index + 1] = true
                    stack.append(index + 1)
                }
                if y > 0, dilated[index - mask.width] != 0, !visited[index - mask.width] {
                    visited[index - mask.width] = true
                    stack.append(index - mask.width)
                }
                if y + 1 < mask.height,
                   dilated[index + mask.width] != 0,
                   !visited[index + mask.width] {
                    visited[index + mask.width] = true
                    stack.append(index + mask.width)
                }
            }

            guard changedPixels > 0, maxX >= minX, maxY >= minY else { continue }
            regions.append(BrowserChangedRegion(
                x: minX,
                y: minY,
                width: maxX - minX + 1,
                height: maxY - minY + 1,
                changedPixels: changedPixels
            ))
        }
        return regions
    }

    /// Merges boxes that touch or nearly touch, repeatedly, until nothing more merges.
    private static func merge(
        _ regions: [BrowserChangedRegion],
        gap: Int
    ) -> [BrowserChangedRegion] {
        var current = regions
        var merged = true
        // Bounded so a pathological mask cannot spin here; each pass strictly reduces the count,
        // so the bound is only ever reached by a mask with thousands of components.
        var passes = 0
        while merged, passes < 8 {
            merged = false
            passes += 1
            var next: [BrowserChangedRegion] = []
            for region in current {
                if let index = next.firstIndex(where: { overlaps($0, region, gap: gap) }) {
                    next[index] = union(next[index], region)
                    merged = true
                } else {
                    next.append(region)
                }
            }
            current = next
        }
        return current
    }

    private static func overlaps(
        _ first: BrowserChangedRegion,
        _ second: BrowserChangedRegion,
        gap: Int
    ) -> Bool {
        first.x - gap <= second.x + second.width
            && second.x - gap <= first.x + first.width
            && first.y - gap <= second.y + second.height
            && second.y - gap <= first.y + first.height
    }

    private static func union(
        _ first: BrowserChangedRegion,
        _ second: BrowserChangedRegion
    ) -> BrowserChangedRegion {
        let x = min(first.x, second.x)
        let y = min(first.y, second.y)
        let maxX = max(first.x + first.width, second.x + second.width)
        let maxY = max(first.y + first.height, second.y + second.height)
        return BrowserChangedRegion(
            x: x,
            y: y,
            width: maxX - x,
            height: maxY - y,
            changedPixels: first.changedPixels + second.changedPixels
        )
    }
}

// MARK: - Capture space

/// How to read one capture's pixel coordinates as page coordinates.
///
/// Stated rather than assumed, because the three capture kinds do not share an origin: a viewport
/// capture starts at the viewport's top-left, a full-page capture at the document's, and an element
/// capture at that element's box. Getting this wrong does not fail — it silently attributes every
/// region to whatever happens to be near the top of the page.
struct BrowserCaptureSpace: Equatable, Sendable {

    /// Added to a node's viewport-relative box to put it in capture pixels.
    let offsetX: Double
    let offsetY: Double

    /// Capture pixels per CSS pixel. One today for every capture Threading takes; named so that a
    /// future device-pixel-ratio capture cannot be introduced by accident.
    let scale: Double

    static func forCapture(
        _ conditions: BrowserBaselineConditions,
        attributionScrollX: Double,
        attributionScrollY: Double
    ) -> BrowserCaptureSpace {
        switch conditions.captureKind {
        case .viewport:
            // Node boxes are already viewport-relative, which is exactly the capture's own space.
            return BrowserCaptureSpace(offsetX: 0, offsetY: 0, scale: 1)
        case .fullPage:
            // The capture starts at the document origin, so a viewport-relative box has to travel
            // back down by the page's scroll.
            return BrowserCaptureSpace(
                offsetX: attributionScrollX,
                offsetY: attributionScrollY,
                scale: 1
            )
        case .element:
            let scope = conditions.elementScope
            return BrowserCaptureSpace(
                offsetX: -(scope?.x ?? 0),
                offsetY: -(scope?.y ?? 0),
                scale: 1
            )
        }
    }

    func box(for node: BrowserAttributionState.Node) -> (x: Double, y: Double, width: Double, height: Double) {
        (
            (node.x + offsetX) * scale,
            (node.y + offsetY) * scale,
            node.width * scale,
            node.height * scale
        )
    }
}

// MARK: - Attribution

/// Says what each changed region sits on, without claiming why it changed.
///
/// The line is deliberate. Overlap is evidence that a region and an element occupy the same pixels;
/// it is not proof that the element caused the change. A region that overlaps nothing is reported as
/// exactly that rather than being attributed to its nearest ancestor, because canvas, images,
/// background painting and pseudo content are all real answers to "what is drawn here".
enum BrowserRegionAttributor {

    static func attribute(
        _ regions: [BrowserChangedRegion],
        using state: BrowserAttributionState,
        space: BrowserCaptureSpace,
        maximumOverlapsPerRegion: Int = 3
    ) -> [BrowserChangedRegion] {
        let boxes = state.nodes.map { (node: $0, box: space.box(for: $0)) }
        return regions.map { region in
            var attributed = region
            let regionArea = Double(max(1, region.area))
            var candidates: [BrowserRegionOverlap] = []

            for entry in boxes {
                let intersectionWidth = min(
                    Double(region.x + region.width),
                    entry.box.x + entry.box.width
                ) - max(Double(region.x), entry.box.x)
                let intersectionHeight = min(
                    Double(region.y + region.height),
                    entry.box.y + entry.box.height
                ) - max(Double(region.y), entry.box.y)
                guard intersectionWidth > 0, intersectionHeight > 0 else { continue }

                candidates.append(BrowserRegionOverlap(
                    nodeID: entry.node.id,
                    label: entry.node.label,
                    ref: entry.node.ref,
                    coverage: min(1, intersectionWidth * intersectionHeight / regionArea)
                ))
            }

            // The most specific element wins, not the largest: `html` and `body` overlap every
            // region completely and explain none of them. Depth is the tie-break that makes the
            // answer "the Sign in button" rather than "the document".
            let nodeDepth = Dictionary(
                state.nodes.map { ($0.id, $0.depth) },
                uniquingKeysWith: { first, _ in first }
            )
            attributed.overlaps = candidates
                .sorted {
                    let leftDepth = nodeDepth[$0.nodeID] ?? 0
                    let rightDepth = nodeDepth[$1.nodeID] ?? 0
                    if leftDepth != rightDepth { return leftDepth > rightDepth }
                    return $0.coverage > $1.coverage
                }
                .prefix(maximumOverlapsPerRegion)
                .map { $0 }
            return attributed
        }
    }
}

// MARK: - Structural comparison

/// One statement about how the two captured trees differ.
struct BrowserStructuralFinding: Equatable, Sendable {
    enum Kind: String, Sendable {
        case added
        case removed
        case moved
        case resized
        case styleChanged = "style_changed"
        case renamed
        /// Matched to more than one candidate. Returned rather than guessed away.
        case ambiguous
    }

    let kind: Kind
    let label: String
    let ref: String?
    let detail: String
    /// The index of the region this finding sits inside, when it sits inside one. Ordering by this
    /// is what puts a property that might explain a visible change ahead of one that cannot.
    let regionIndex: Int?
    /// Changed pixels in the region it overlaps, which is how findings are ranked against each
    /// other. Zero for a finding with no visible region.
    let regionChangedPixels: Int
}

/// Matches two captured trees and says what moved.
///
/// **Never on ref equality.** The bridge numbers refs from 1 for each new document and assigns them
/// as elements are encountered, so `e12` in two captures is not evidence of anything. Matching uses
/// the bounded semantic evidence beside each node — test id, then role and accessible name, then
/// structural position — and a key that appears more than once on either side produces an
/// `ambiguous` finding instead of an invented pairing.
///
/// **Overlap is association, not cause.** A finding ordered first because it sits inside the largest
/// changed region is the most likely explanation, and the wording throughout says "associated with"
/// rather than asserting the property produced the pixels.
enum BrowserStructuralDiff {

    /// Movement smaller than this is sub-pixel layout noise, not a change worth a sentence.
    static let minimumMovement = 1.0

    static func compare(
        baseline: BrowserAttributionState,
        actual: BrowserAttributionState,
        baselineSpace: BrowserCaptureSpace,
        actualSpace: BrowserCaptureSpace,
        regions: [BrowserChangedRegion],
        maximumFindings: Int = 24
    ) -> [BrowserStructuralFinding] {
        let baselineByKey = Dictionary(grouping: baseline.nodes) { $0.matchKey }
        let actualByKey = Dictionary(grouping: actual.nodes) { $0.matchKey }
        var findings: [BrowserStructuralFinding] = []

        for (key, actualNodes) in actualByKey {
            let baselineNodes = baselineByKey[key] ?? []
            if baselineNodes.isEmpty {
                for node in actualNodes.prefix(2) {
                    findings.append(finding(
                        .added,
                        node: node,
                        detail: L10n.string("present now and absent in the baseline"),
                        space: actualSpace,
                        regions: regions
                    ))
                }
                continue
            }
            guard baselineNodes.count == 1, actualNodes.count == 1 else {
                findings.append(finding(
                    .ambiguous,
                    node: actualNodes[0],
                    detail: L10n.format(
                        "matches %lld baseline candidates and %lld current ones, so nothing is claimed about it",
                        Int64(baselineNodes.count),
                        Int64(actualNodes.count)
                    ),
                    space: actualSpace,
                    regions: regions
                ))
                continue
            }

            let before = baselineSpace.box(for: baselineNodes[0])
            let after = actualSpace.box(for: actualNodes[0])
            let dx = after.x - before.x
            let dy = after.y - before.y
            if abs(dx) >= minimumMovement || abs(dy) >= minimumMovement {
                findings.append(finding(
                    .moved,
                    node: actualNodes[0],
                    detail: L10n.format(
                        "moved %@%lld, %@%lld pixels",
                        dx < 0 ? "" : "+",
                        Int64(dx.rounded()),
                        dy < 0 ? "" : "+",
                        Int64(dy.rounded())
                    ),
                    space: actualSpace,
                    regions: regions
                ))
            }
            let dw = after.width - before.width
            let dh = after.height - before.height
            if abs(dw) >= minimumMovement || abs(dh) >= minimumMovement {
                findings.append(finding(
                    .resized,
                    node: actualNodes[0],
                    detail: L10n.format(
                        "resized %@%lld×%@%lld pixels",
                        dw < 0 ? "" : "+",
                        Int64(dw.rounded()),
                        dh < 0 ? "" : "+",
                        Int64(dh.rounded())
                    ),
                    space: actualSpace,
                    regions: regions
                ))
            }

            let changedStyles = styleChanges(
                from: baselineNodes[0].styles,
                to: actualNodes[0].styles
            )
            if !changedStyles.isEmpty {
                findings.append(finding(
                    .styleChanged,
                    node: actualNodes[0],
                    detail: changedStyles.joined(separator: "; "),
                    space: actualSpace,
                    regions: regions
                ))
            }
        }

        for (key, baselineNodes) in baselineByKey where actualByKey[key] == nil {
            for node in baselineNodes.prefix(2) {
                findings.append(finding(
                    .removed,
                    node: node,
                    detail: L10n.string("present in the baseline and absent now"),
                    space: baselineSpace,
                    regions: regions
                ))
            }
        }

        return findings
            .sorted {
                if $0.regionChangedPixels != $1.regionChangedPixels {
                    return $0.regionChangedPixels > $1.regionChangedPixels
                }
                return $0.label < $1.label
            }
            .prefix(maximumFindings)
            .map { $0 }
    }

    /// The curated properties that differ, bounded so one restyled element cannot fill the answer.
    private static func styleChanges(
        from before: [String: String],
        to after: [String: String]
    ) -> [String] {
        var changes: [String] = []
        for property in Set(before.keys).union(after.keys).sorted() {
            let old = before[property]
            let new = after[property]
            guard old != new else { continue }
            changes.append(
                L10n.format(
                    "%@ %@ → %@",
                    property,
                    old ?? L10n.string("unset"),
                    new ?? L10n.string("unset")
                )
            )
            if changes.count >= 6 { break }
        }
        return changes
    }

    private static func finding(
        _ kind: BrowserStructuralFinding.Kind,
        node: BrowserAttributionState.Node,
        detail: String,
        space: BrowserCaptureSpace,
        regions: [BrowserChangedRegion]
    ) -> BrowserStructuralFinding {
        let box = space.box(for: node)
        var bestIndex: Int?
        var bestPixels = 0
        for (index, region) in regions.enumerated() {
            let overlapWidth = min(Double(region.x + region.width), box.x + box.width)
                - max(Double(region.x), box.x)
            let overlapHeight = min(Double(region.y + region.height), box.y + box.height)
                - max(Double(region.y), box.y)
            guard overlapWidth > 0, overlapHeight > 0 else { continue }
            if region.changedPixels > bestPixels {
                bestPixels = region.changedPixels
                bestIndex = index
            }
        }
        return BrowserStructuralFinding(
            kind: kind,
            label: node.label,
            ref: node.ref,
            detail: detail,
            regionIndex: bestIndex,
            regionChangedPixels: bestPixels
        )
    }
}
