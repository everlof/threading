import Foundation

/// The page as it was just before an agent changed it.
///
/// The named action is the *tool that was about to run*, not a guess at what it did. That is the
/// whole honesty of this feature: the ring covers agent-originated mutations and nothing else, so
/// a user's own click, a timer, a websocket push and a late-arriving network response are all
/// changes it cannot see and does not claim to.
struct BrowserAutoCapture: Equatable, Sendable {
    let id: UUID
    let capturedAt: Date
    /// The MCP tool name the capture was taken in front of, e.g. `browser_click`.
    let action: String
    let pngData: Data
    let conditions: BrowserBaselineConditions

    var byteCount: Int { pngData.count }
}

/// A small, bounded, in-memory history of what the page looked like before each agent mutation.
///
/// **Not the baseline library, and the separation is the point.** A baseline is an approved claim
/// about intent, made by a person, kept until they remove it. These are automatic, unapproved and
/// disposable — "what did my click change?" rather than "is this page still correct?". Mixing them
/// would mean an agent's own before-shot could be mistaken for something a user had signed off.
///
/// **In memory, and per session.** Nothing here is written to disk: the ring answers a question
/// that only makes sense within one live conversation, and persisting page pixels captured without
/// anyone asking is a cost the feature has not earned. It dies with the session, the app, or the
/// budget below, whichever comes first.
///
/// **Off unless the user turns it on.** Every agent mutation would otherwise pay for a screenshot
/// it may never be asked for, on the main actor, in a hot path.
@MainActor
final class BrowserAutoCaptureRing {

    static let shared = BrowserAutoCaptureRing()

    private var entriesBySession: [SessionID: [BrowserAutoCapture]] = [:]

    init() {}

    // MARK: - Recording

    /// Records one before-shot, evicting oldest-first to stay inside both budgets.
    ///
    /// Two budgets rather than one because they bound different mistakes: a count keeps the ring a
    /// *history* rather than a log, and a byte ceiling keeps one full-page capture of a very long
    /// document from being the whole history on its own.
    @discardableResult
    func record(
        action: String,
        pngData: Data,
        conditions: BrowserBaselineConditions,
        for sessionID: SessionID,
        at date: Date = Date()
    ) -> BrowserAutoCapture? {
        guard pngData.count <= BrowserAutoCaptureDefaults.maximumEntryBytes else { return nil }

        let entry = BrowserAutoCapture(
            id: UUID(),
            capturedAt: date,
            action: String(action.prefix(BrowserAutoCaptureDefaults.maximumActionLength)),
            pngData: pngData,
            conditions: conditions
        )
        var current = entriesBySession[sessionID] ?? []
        current.append(entry)

        while current.count > BrowserAutoCaptureDefaults.maximumEntriesPerSession {
            current.removeFirst()
        }
        while current.count > 1,
              current.reduce(0, { $0 + $1.byteCount }) > BrowserAutoCaptureDefaults.maximumSessionBytes {
            current.removeFirst()
        }
        entriesBySession[sessionID] = current
        return entry
    }

    // MARK: - Reading

    /// The most recent before-shot, which is what "compare with the page's own past" means.
    func latest(for sessionID: SessionID) -> BrowserAutoCapture? {
        entriesBySession[sessionID]?.last
    }

    /// Oldest first.
    func entries(for sessionID: SessionID) -> [BrowserAutoCapture] {
        entriesBySession[sessionID] ?? []
    }

    func entry(id: UUID, for sessionID: SessionID) -> BrowserAutoCapture? {
        entriesBySession[sessionID]?.first { $0.id == id }
    }

    func byteCount(for sessionID: SessionID) -> Int {
        entries(for: sessionID).reduce(0) { $0 + $1.byteCount }
    }

    // MARK: - Lifecycle

    func clear(for sessionID: SessionID) {
        entriesBySession[sessionID] = nil
    }

    func retainOnly(sessionIDs: Set<SessionID>) {
        entriesBySession = entriesBySession.filter { sessionIDs.contains($0.key) }
    }
}

// MARK: - Defaults

enum BrowserAutoCaptureDefaults {
    /// Enough to look back over a short exchange of actions, not enough to be a log.
    static let maximumEntriesPerSession = 8

    /// One capture. Smaller than a baseline's ceiling: this one is taken without anybody asking,
    /// so it is held to a tighter budget than a picture somebody chose to keep.
    static let maximumEntryBytes = 16 * 1_024 * 1_024
    static let maximumSessionBytes = 64 * 1_024 * 1_024
    static let maximumActionLength = 60

    /// The tools a before-shot is taken in front of: the ones that change what the page looks
    /// like. Navigation is deliberately absent — a new document is not a change to the old one,
    /// and the comparison it would invite ("this page differs from a different page") is exactly
    /// the false claim the dimension rules elsewhere refuse to make.
    static let mutatingTools: Set<MCPBuiltInTool> = [
        .browserClick,
        .browserType,
        .browserFillForm,
        .browserFillCredentials,
        .browserSelect,
        .browserSetChecked,
        .browserPressKey,
        .browserDrag,
        .browserScroll,
        .browserResize,
        .browserEmulate
    ]
}
