import AppKit
import WebKit

// MARK: - Capture Result

/// A capture and everything about the browser that decided it.
///
/// One value rather than a pair, because the pixels are worth very little without the conditions:
/// a PNG whose viewport, zoom, colour scheme and user-agent override are unknown cannot be compared
/// honestly later, and by the time anyone asks, the browser has moved on.
struct BrowserBaselineCapture {
    let pngData: Data
    let conditions: BrowserBaselineConditions
    /// The page identity both halves were read against, so a caller can prove nothing replaced the
    /// document between the screenshot and the state beside it.
    let page: BrowserPageIdentity
    /// The bounded semantic state, when the caller asked for it.
    let attribution: BrowserAttributionState?
    /// True when an element or full-page capture had to stop at a frame or viewport edge.
    let clipped: Bool
}

enum BrowserBaselineCaptureError: LocalizedError {
    case noPage
    case targetFailed(String)
    case captureFailed
    case documentChanged

    var errorDescription: String? {
        switch self {
        case .noPage:
            return L10n.string("No page is loaded in this browser.")
        case .targetFailed(let message):
            return message
        case .captureFailed:
            return L10n.string("WebKit did not return pixels for the capture.")
        case .documentChanged:
            return L10n.string("The page changed during capture; take the baseline again.")
        }
    }
}

// MARK: - Capture

extension BrowserViewController {

    /// The one capture path for both parties.
    ///
    /// The user's **Save as Baseline…** and the agent's `browser_baselines capture` come through
    /// here, and that is the point: the manual screenshot exporter uses a bare
    /// `WKWebView.takeSnapshot`, which produces backing-store pixels rather than the CSS-pixel
    /// normalized ones `browser_screenshot` and `browser_click` agree about. Two capture paths mean
    /// a user baseline and an agent comparison quietly disagree about what a coordinate is.
    ///
    /// **Both halves describe one moment.** The screenshot, the page's own metrics and the
    /// attribution state are three WebKit calls; they cannot be made atomic through the public API,
    /// so they are taken back to back against one `BrowserPageIdentity` and the whole capture is
    /// refused if the document was replaced in between. A page animating through the sequence can
    /// still drift, which is why attribution is described as best-effort wherever it is returned.
    @MainActor
    func captureBaseline(
        kind: BrowserBaselineCaptureKind,
        ref: String? = nil,
        selector: String? = nil,
        locator: BrowserSemanticLocator? = nil,
        includesAttribution: Bool = false,
        commitSHA: String? = nil
    ) async throws -> BrowserBaselineCapture {
        guard let page = agentPageIdentity, currentURL != nil else {
            throw BrowserBaselineCaptureError.noPage
        }

        let context = try await captureContext()
        guard agentPageIdentity == page else {
            throw BrowserBaselineCaptureError.documentChanged
        }

        var clipped = false
        var scope: BrowserBaselineElementScope?
        let capture: BrowserScreenshotCapture

        switch kind {
        case .element:
            let result = try await screenshot(ref: ref, selector: selector, locator: locator)
            guard result.target.ok else {
                throw BrowserBaselineCaptureError.targetFailed(result.target.message)
            }
            guard let elementCapture = result.capture else {
                throw BrowserBaselineCaptureError.captureFailed
            }
            capture = elementCapture
            clipped = result.target.clipped
            scope = try? await elementScope(
                ref: ref,
                selector: selector,
                locator: locator,
                target: result.target
            )
        case .fullPage, .viewport:
            guard let pageCapture = await screenshot(fullPage: kind == .fullPage) else {
                throw BrowserBaselineCaptureError.captureFailed
            }
            capture = pageCapture
            // A full-page capture is bounded by `maximumSnapshotHeight`; a document taller than
            // that is captured down to the cap and says so rather than pretending to be complete.
            clipped = kind == .fullPage
                && context.documentHeight > Double(pageCapture.height) + 1
        }

        var attribution: BrowserAttributionState?
        if includesAttribution {
            attribution = try? await attributionState(
                maximumNodes: BrowserAgentDefaults.maximumAttributionNodes
            )
        }

        guard agentPageIdentity == page else {
            throw BrowserBaselineCaptureError.documentChanged
        }

        return BrowserBaselineCapture(
            pngData: capture.data,
            conditions: BrowserBaselineConditions(
                url: Self.fragmentStripped(context.url),
                origin: URL(string: context.url).flatMap(BrowserOrigin.init(url:))?.key ?? "",
                captureKind: kind,
                pixelWidth: capture.width,
                pixelHeight: capture.height,
                viewportWidth: context.viewportWidth,
                viewportHeight: context.viewportHeight,
                documentWidth: context.documentWidth,
                documentHeight: context.documentHeight,
                scrollX: context.scrollX,
                scrollY: context.scrollY,
                pageZoom: browserPageZoom,
                // What the page's media query actually resolved to, not the emulation setting: an
                // `auto` baseline captured on a dark system is a dark baseline, and recording
                // "auto" would make it compare cleanly against a light one months later.
                colorScheme: context.resolvedColorScheme,
                mediaType: agentMediaType.rawValue,
                userAgent: agentUserAgent.value,
                browserContext: contextKind.rawValue,
                clipped: clipped,
                elementScope: scope,
                commitSHA: commitSHA
            ),
            page: page,
            attribution: attribution,
            clipped: clipped
        )
    }

    /// A durable description of the element a scoped capture covers.
    ///
    /// The current ref is recorded as a hint and nothing more. `eN` refs are stable only inside one
    /// live document — the bridge restarts numbering for a new document and assigns as it walks —
    /// so equal refs across two captures do not prove equal nodes. What survives a rerender is the
    /// test id, the role and accessible name, and the geometry beside them.
    @MainActor
    private func elementScope(
        ref: String?,
        selector: String?,
        locator: BrowserSemanticLocator?,
        target: BrowserScreenshotTarget
    ) async throws -> BrowserBaselineElementScope? {
        let description = try await describeTarget(
            ref: ref,
            selector: selector,
            locator: locator
        )
        guard description.ok else { return nil }
        return BrowserBaselineElementScope(
            testID: nil,
            role: description.role,
            name: description.name,
            selector: selector,
            capturedRef: description.ref ?? ref,
            x: Double(target.x),
            y: Double(target.y),
            width: Double(target.width),
            height: Double(target.height)
        )
    }

    // MARK: - Live overlay

    /// Holds an approved picture over the live page.
    ///
    /// The page stays live underneath: the overlay declines every click but its own handle, so the
    /// user and the agent can go on working while watching the seam. Nothing here touches the DOM,
    /// so a screenshot taken while it is up contains the page and not the overlay.
    @MainActor
    func showBaselineOverlay(
        image: NSImage,
        name: String,
        captureKind: BrowserBaselineCaptureKind,
        capturedScroll: CGPoint,
        captureSize: CGSize,
        scale: CGFloat = 1
    ) {
        baselineOverlayView.content = BrowserBaselineOverlayContent(
            image: image,
            name: name,
            captureKind: captureKind,
            capturedScroll: capturedScroll,
            captureSize: captureSize,
            scale: scale
        )
        baselineOverlayView.isHidden = false
        baselineOverlayView.needsDisplay = true
    }

    /// Draws where the page moved during this document's load, and answers how much moved.
    ///
    /// Nil means WebKit did not implement the entry type for this document, which is a different
    /// answer from "nothing moved" and is passed back as one.
    @MainActor
    @discardableResult
    func showLayoutShiftOverlay() async -> Double? {
        guard let report = try? await layoutShiftReport(), report.supported else {
            return nil
        }
        baselineOverlayView.layoutShifts = report.rects.map {
            BrowserLayoutShiftRegion(
                x: $0.x,
                y: $0.y,
                width: $0.width,
                height: $0.height,
                value: $0.value
            )
        }
        baselineOverlayView.isHidden = report.rects.isEmpty
        return report.total
    }

    @MainActor
    func hideLayoutShiftOverlay() {
        baselineOverlayView.layoutShifts = []
        if baselineOverlayView.content == nil { baselineOverlayView.isHidden = true }
    }

    @MainActor
    var isShowingLayoutShiftOverlay: Bool {
        !baselineOverlayView.isHidden && !baselineOverlayView.layoutShifts.isEmpty
    }

    @MainActor
    func hideBaselineOverlay() {
        baselineOverlayView.content = nil
        if baselineOverlayView.layoutShifts.isEmpty { baselineOverlayView.isHidden = true }
    }

    @MainActor
    var isShowingBaselineOverlay: Bool {
        !baselineOverlayView.isHidden && baselineOverlayView.content != nil
    }

    /// Wipe or fade. The scrub position is shared between them, so switching keeps the seam where
    /// the user left it.
    @MainActor
    var baselineOverlayMode: BrowserBaselineOverlayMode {
        get { baselineOverlayView.mode }
        set { baselineOverlayView.mode = newValue }
    }

    /// Captures at one exact CSS viewport, putting the browser back however it was.
    ///
    /// The restore is in a `defer`, because a capture that throws must not leave the user looking
    /// at a 375-point phone viewport they never asked for. Comparing across device presets is the
    /// reason this exists: each preset gets its own baseline, and none of them is ever a scaled
    /// stand-in for another.
    @MainActor
    func captureBaseline(
        kind: BrowserBaselineCaptureKind,
        atViewport viewport: CGSize,
        ref: String? = nil,
        selector: String? = nil,
        locator: BrowserSemanticLocator? = nil,
        includesAttribution: Bool = false,
        commitSHA: String? = nil
    ) async throws -> BrowserBaselineCapture {
        let previous = agentViewportSize
        let resized = await agentSetResponsiveViewport(
            width: Int(viewport.width.rounded()),
            height: Int(viewport.height.rounded())
        )
        guard resized.ok else {
            throw BrowserBaselineCaptureError.targetFailed(resized.message)
        }
        defer {
            Task { @MainActor [weak self] in
                guard let self else { return }
                _ = await self.agentSetResponsiveViewport(
                    width: previous.map { Int($0.width.rounded()) },
                    height: previous.map { Int($0.height.rounded()) }
                )
            }
        }
        // Layout and paint after a viewport change are asynchronous; capturing in the same turn
        // photographs the page mid-reflow.
        try? await Task.sleep(nanoseconds: BrowserBaselineCaptureDefaults.viewportSettleNanoseconds)
        return try await captureBaseline(
            kind: kind,
            ref: ref,
            selector: selector,
            locator: locator,
            includesAttribution: includesAttribution,
            commitSHA: commitSHA
        )
    }

    /// Anchors and query-strings are different questions. A fragment is not: two anchors into one
    /// document render the same pixels, so keying a baseline on one would file the same page twice.
    static func fragmentStripped(_ url: String) -> String {
        guard var components = URLComponents(string: url) else { return url }
        components.fragment = nil
        return components.string ?? url
    }
}


// MARK: - Defaults

enum BrowserBaselineCaptureDefaults {
    /// How long a resized viewport is given to reflow and repaint before it is photographed.
    static let viewportSettleNanoseconds: UInt64 = 120_000_000
}

// MARK: - Git

/// The checkout's commit, for a baseline that wants to say which build it is a picture of.
///
/// Read, never acted on. Nothing here checks anything out: reproducing a baseline's commit would
/// mean stashing and restoring the user's working tree behind their back, which the plan this comes
/// from rules out explicitly.
enum BrowserBaselineGit {

    static func commitSHA(forProjectAt root: URL?) -> String? {
        guard let root else { return nil }
        guard let data = try? GitProcess.run(
            ["rev-parse", "HEAD"],
            in: root,
            reportsRejectedExit: false
        ) else { return nil }
        let sha = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.count == 40 ? sha : nil
    }
}
