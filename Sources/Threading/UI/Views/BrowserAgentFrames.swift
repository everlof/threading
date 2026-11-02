import CoreGraphics
import Foundation
import WebKit

// MARK: - Entered frames

/// A frame from another origin that an agent has entered.
///
/// Script in the main frame cannot see inside one, so anything that reaches its content has to run
/// there, through this handle. See "Frames from other origins" in `agent-browser.md`.
struct BrowserAgentFrame {
    /// Never reused within a tab, so a ref from an earlier page cannot name a later frame.
    let id: Int
    /// Which document this entry describes. The handle names the frame and outlives its document,
    /// so `BrowserAgentScripts.frameDocumentGuard` compares this at delivery.
    let documentToken: String
    let handle: WKFrameInfo
    let url: URL
    let origin: BrowserOrigin
    /// The frame holding this one's element, or nil when the main frame does.
    let parentID: Int?
    /// The ref of this frame's `<iframe>` element in its parent.
    let elementRef: String
    let page: ObjectIdentifier

    var refPrefix: String { BrowserAgentFrameRef.prefix(for: id) }
}

/// Whether this tool call may use a frame's origin. With a purpose it may ask the user, naming that
/// purpose; without one it only reports what has already been answered, for a poll that must not
/// raise a prompt.
typealias BrowserAgentFrameAccess = @MainActor (BrowserAgentFrame, String?) async -> Bool

enum BrowserAgentFramePurpose {
    static let read = "read the frame at"
    static let interact = "interact with the frame at"
    static let use = "use the frame at"
}

/// Where a viewport point ended up once it stopped crossing frames.
struct BrowserPointLanding {
    let target: BrowserTargetDescription
    let x: Double
    let y: Double
    let frame: BrowserAgentFrame?
    /// What the agent asked for, which is what the result should report.
    let pageX: Double
    let pageY: Double
}

/// Refs minted inside a frame carry that frame's id, so a ref alone says where it can be used.
enum BrowserAgentFrameRef {
    static func prefix(for id: Int) -> String { "f\(id)" }

    /// The frame id in `f12e3`, and nil for a ref in the main frame.
    static func frameID(of ref: String?) -> Int? {
        guard let ref, ref.first == "f", let separator = ref.firstIndex(of: "e") else { return nil }
        let digits = ref[ref.index(after: ref.startIndex)..<separator]
        let element = ref[ref.index(after: separator)...]
        guard !digits.isEmpty, !element.isEmpty,
              element.allSatisfy(\.isNumber),
              digits.allSatisfy(\.isNumber) else { return nil }
        return Int(digits)
    }
}

enum BrowserAgentFrameError: LocalizedError, Equatable {
    /// Thrown by `frameDocumentGuard` when the frame has navigated since it was entered.
    static let documentChangedMarker = "ThreadingFrameDocumentChanged"

    case gone
    case documentChanged
    case unanswered
    case noOrigin
    case notAllowed(String)
    case tooDeep
    case refused(String)

    var errorDescription: String? {
        switch self {
        case .gone:
            return "That frame is no longer on this page; take a new snapshot."
        case .documentChanged:
            return "That frame has navigated since it was read; take a new snapshot of it."
        case .unanswered:
            return """
                The frame did not answer. It may still be loading, or it may be sandboxed without \
                scripts, which an agent cannot enter. Nothing inside it was read or changed.
                """
        case .noOrigin:
            return """
                The frame has no origin the user could be asked about, such as a sandboxed srcdoc \
                document, so an agent cannot enter it. Nothing inside it was read or changed.
                """
        case .notAllowed(let origin):
            return """
                The user did not allow access to \(origin). Nothing inside that frame was read or \
                changed.
                """
        case .tooDeep:
            return "The target crosses too many nested frames."
        case .refused(let message):
            return message
        }
    }
}

// MARK: - Placement

/// Where a frame's content sits on the page, so its coordinates can be stated in the page's.
struct BrowserFramePlacement: Equatable {
    let x: Double
    let y: Double
    let scaleX: Double
    let scaleY: Double
    /// The part of the frame's content box the page's viewport shows, in page coordinates.
    let clip: CGRect
    /// Whether something the page drew hides the frame at every point `receivesPointerEvents`
    /// samples. Hit-testing inside the frame cannot see this.
    let covered: Bool

    init(x: Double, y: Double, scaleX: Double, scaleY: Double, clip: CGRect, covered: Bool) {
        self.x = x
        self.y = y
        self.scaleX = scaleX
        self.scaleY = scaleY
        self.clip = clip
        self.covered = covered
    }

    init(_ measured: BrowserFramePlacementMeasurement) {
        self.init(
            x: measured.x,
            y: measured.y,
            scaleX: measured.scaleX,
            scaleY: measured.scaleY,
            clip: CGRect(
                x: measured.clipX,
                y: measured.clipY,
                width: measured.clipWidth,
                height: measured.clipHeight
            ),
            covered: measured.covered
        )
    }

    /// `inner`'s placement on the page, when `inner` was measured inside this frame.
    func composing(_ inner: BrowserFramePlacement) -> BrowserFramePlacement {
        BrowserFramePlacement(
            x: x + inner.x * scaleX,
            y: y + inner.y * scaleY,
            scaleX: scaleX * inner.scaleX,
            scaleY: scaleY * inner.scaleY,
            clip: project(inner.clip).intersection(clip),
            covered: covered || inner.covered
        )
    }

    func project(_ rect: CGRect) -> CGRect {
        CGRect(
            x: x + rect.minX * scaleX,
            y: y + rect.minY * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        )
    }

    func project(_ box: BrowserSnapshot.Node.Box) -> BrowserSnapshot.Node.Box {
        let projected = project(CGRect(
            x: box.x,
            y: box.y,
            width: box.width,
            height: box.height
        ))
        return BrowserSnapshot.Node.Box(
            x: Int(projected.minX.rounded()),
            y: Int(projected.minY.rounded()),
            width: Int(projected.width.rounded()),
            height: Int(projected.height.rounded())
        )
    }

    /// The capture rectangle for a target measured inside this frame. A target the frame or the
    /// page's viewport clips reports that, the same way a same-origin frame's target does.
    func project(_ target: BrowserScreenshotTarget) -> BrowserScreenshotTarget {
        let rect = project(CGRect(
            x: target.x,
            y: target.y,
            width: target.width,
            height: target.height
        ))
        let visible = rect.intersection(clip)
        guard !visible.isNull, visible.width >= 1, visible.height >= 1 else {
            return BrowserScreenshotTarget(
                ok: false,
                message: "No visible part of the target remains inside the page viewport.",
                x: 0,
                y: 0,
                width: 0,
                height: 0,
                clipped: true
            )
        }
        return BrowserScreenshotTarget(
            ok: true,
            message: target.message,
            x: Int(visible.minX.rounded(.down)),
            y: Int(visible.minY.rounded(.down)),
            width: Int(visible.maxX.rounded(.up)) - Int(visible.minX.rounded(.down)),
            height: Int(visible.maxY.rounded(.up)) - Int(visible.minY.rounded(.down)),
            clipped: target.clipped || visible.size != rect.size
        )
    }
}

/// One frame's position in the document holding its element, as `framePlacement` reports it.
struct BrowserFramePlacementMeasurement: Decodable, Equatable {
    let ok: Bool
    let message: String
    let x: Double
    let y: Double
    let scaleX: Double
    let scaleY: Double
    let clipX: Double
    let clipY: Double
    let clipWidth: Double
    let clipHeight: Double
    let covered: Bool
}

struct BrowserFrameProbeResult: Decodable, Equatable {
    let ok: Bool
    let message: String
    let ref: String?
}

// MARK: - Registry

/// The frames an agent has entered in one tab, and the probes still waiting for an answer.
///
/// **Scaling contract.** A page may hold hundreds of frames, and nothing here is proportional to
/// them. A frame is only recorded when an agent explicitly enters it, one probe at a time, so an
/// ordinary snapshot posts nothing and waits for nothing. The registry is capped and emptied when
/// the main frame commits a new document.
@MainActor
final class BrowserAgentFrameRegistry {
    struct ProbeReply {
        let handle: WKFrameInfo
        let documentToken: String
        let url: String
    }

    private final class PendingProbe {
        var reply: ProbeReply?
        var continuation: CheckedContinuation<ProbeReply?, Never>?
    }

    private var frames: [Int: BrowserAgentFrame] = [:]
    private var nextID = 1
    private var pendingProbes: [String: PendingProbe] = [:]

    private let maximumFrames: Int

    init(maximumFrames: Int = BrowserAgentDefaults.maximumEnteredFrames) {
        self.maximumFrames = maximumFrames
    }

    // MARK: Lookup

    /// The frame a ref belongs to, and nil for a ref in the main frame. A ref shaped like a frame
    /// ref that names no current frame throws, because falling back to the main frame would act on
    /// the wrong document.
    func frame(forRef ref: String?, page: WKWebView) throws -> BrowserAgentFrame? {
        guard let id = BrowserAgentFrameRef.frameID(of: ref) else { return nil }
        guard let frame = frames[id], frame.page == ObjectIdentifier(page) else {
            throw BrowserAgentFrameError.gone
        }
        return frame
    }

    func frame(id: Int?, page: WKWebView) -> BrowserAgentFrame? {
        guard let id, let frame = frames[id], frame.page == ObjectIdentifier(page) else {
            return nil
        }
        return frame
    }

    func enteredFrames(page: WKWebView) -> [BrowserAgentFrame] {
        frames.values
            .filter { $0.page == ObjectIdentifier(page) }
            .sorted { $0.id < $1.id }
    }

    // MARK: Probes

    func expectProbeReply(nonce: String) {
        pendingProbes[nonce] = PendingProbe()
    }

    /// A reply whose nonce was not issued is dropped: that is the whole of the forgery defence.
    func receiveProbeReply(nonce: String, reply: ProbeReply) {
        guard let pending = pendingProbes[nonce] else { return }
        if let continuation = pending.continuation {
            pendingProbes[nonce] = nil
            continuation.resume(returning: reply)
        } else {
            pending.reply = reply
        }
    }

    func cancelProbe(nonce: String) {
        guard let pending = pendingProbes.removeValue(forKey: nonce) else { return }
        pending.continuation?.resume(returning: nil)
    }

    func waitForProbeReply(nonce: String, timeout: TimeInterval) async -> ProbeReply? {
        guard let pending = pendingProbes[nonce] else { return nil }
        if let reply = pending.reply {
            pendingProbes[nonce] = nil
            return reply
        }
        return await withCheckedContinuation { continuation in
            pending.continuation = continuation
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.cancelProbe(nonce: nonce)
            }
        }
    }

    // MARK: Registration

    /// Records the frame a probe reached, or refuses it when it has no origin to grant.
    ///
    /// The origin decides what the user is asked, so WebKit's answer outranks the document's. A
    /// sandboxed document has an opaque security origin, and is named by its URL only because the
    /// content there still came from that origin; an `about:srcdoc` has neither and is refused.
    func register(
        _ reply: ProbeReply,
        page: WKWebView,
        parentID: Int?,
        elementRef: String
    ) throws -> BrowserAgentFrame {
        guard let url = URL(string: reply.url),
              let origin = BrowserOrigin(url: url),
              !origin.host.isEmpty,
              Self.originAgrees(reply.handle.securityOrigin, with: origin) else {
            throw BrowserAgentFrameError.noOrigin
        }
        let existing = frames.values.first { $0.documentToken == reply.documentToken }
        let id = existing?.id ?? nextID
        if existing == nil { nextID += 1 }
        let frame = BrowserAgentFrame(
            id: id,
            documentToken: reply.documentToken,
            handle: reply.handle,
            url: url,
            origin: origin,
            parentID: parentID,
            elementRef: elementRef,
            page: ObjectIdentifier(page)
        )
        frames[id] = frame
        if frames.count > maximumFrames, let oldest = frames.keys.min() {
            frames[oldest] = nil
        }
        return frame
    }

    private static func originAgrees(_ security: WKSecurityOrigin, with origin: BrowserOrigin) -> Bool {
        guard !security.protocol.isEmpty else { return true }
        let scheme = security.protocol.lowercased()
        return scheme == origin.scheme
            && security.host.lowercased() == origin.host
            && effectivePort(security.port == 0 ? nil : security.port, scheme: scheme)
                == effectivePort(origin.port, scheme: scheme)
    }

    private static func effectivePort(_ port: Int?, scheme: String) -> Int? {
        port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : nil)
    }

    // MARK: Retirement

    func remove(_ frame: BrowserAgentFrame) {
        frames[frame.id] = nil
    }

    func removeAll(page: WKWebView) {
        let identifier = ObjectIdentifier(page)
        frames = frames.filter { $0.value.page != identifier }
    }

    /// WebKit's own errors for a frame that is gone, and the guard's for one that moved on, as the
    /// one thing they mean to an agent: this frame is no longer what it read.
    func translate(_ error: Error, for frame: BrowserAgentFrame) -> Error {
        let nsError = error as NSError
        guard nsError.domain == WKError.errorDomain else { return error }
        if nsError.code == WKError.javaScriptInvalidFrameTarget.rawValue {
            remove(frame)
            return BrowserAgentFrameError.gone
        }
        if nsError.code == WKError.javaScriptExceptionOccurred.rawValue,
           (nsError.userInfo["WKJavaScriptExceptionMessage"] as? String)?
            .contains(BrowserAgentFrameError.documentChangedMarker) == true {
            remove(frame)
            return BrowserAgentFrameError.documentChanged
        }
        return error
    }
}
