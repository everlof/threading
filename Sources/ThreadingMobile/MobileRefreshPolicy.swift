import Foundation

/// Why a catalogue refresh was asked for. Recorded on `hostRefreshStarted` so an audit can say
/// which callers produced the refreshes it counts, rather than inferring from their spacing.
enum MobileRefreshReason: String, Sendable {
    /// The app's first foreground, or a host chosen or paired since the last catalogue.
    case launch
    case hostChanged
    /// The scene became active again after a background or an inactive spell.
    case foreground
    /// A dashboard came on screen — the root, or a project list pushed over it.
    case dashboardAppeared
    case pullToRefresh
    /// The event socket has been lost and its bounded backoff has run.
    case socketRecovery
    /// The event socket said something structural changed and offered no row delta.
    case structuralChange
    /// A delta named a catalogue edition this phone cannot be holding.
    case revisionGap
    case notificationOpen
    /// Opening a chat or terminal whose row the phone cannot find in its catalogue.
    case openTarget
    /// A mutation was refused for a reason a fresh catalogue may resolve.
    case mutationFollowUp
    /// A person pressed a button whose whole point is to try again.
    case userCheck
}

/// What one refresh request should cost.
enum MobileRefreshDecision: String, Sendable, Equatable {
    /// Nothing: the event socket is delivering, and the catalogue in hand is authoritative.
    case skip
    /// One request on the route that answered last, carrying the catalogue edition the phone
    /// holds. The Mac answers `304` when nothing changed, or the whole catalogue when it did.
    /// A transport failure on that one route falls back to the full race.
    case conditional
    /// The constant-size route race and a complete catalogue.
    case full
}

/// Decides how much a refresh should cost from what the phone already knows.
///
/// The audit of 4–5 Sep 2026 counted 384 full refreshes in a day, 158 of them within ten seconds
/// of the previous one, against an event socket that was healthy nearly all of that time and
/// already delivering every row change. Two callers produced most of them: a dashboard coming
/// back on screen, and the scene activating — each of which ran the whole route race and pulled
/// a complete 78-row catalogue over whatever link the phone was on. The catalogue was not wrong
/// at any of those moments; the phone simply had no way to say so.
///
/// Pure and unit-tested. Every input is a fact the model holds; nothing here reads the network.
enum MobileRefreshPolicy {
    static func decide(
        reason: MobileRefreshReason,
        hasCatalogue: Bool,
        eventSocketHealthy: Bool,
        canRefreshConditionally: Bool
    ) -> MobileRefreshDecision {
        // Without a catalogue there is nothing to validate, whatever the reason.
        guard hasCatalogue else { return .full }
        switch reason {
        case .dashboardAppeared:
            // A healthy socket has kept this catalogue current row by row; coming back on screen
            // is not new information about the Mac. Without the socket, ask cheaply first.
            if eventSocketHealthy { return .skip }
            return canRefreshConditionally ? .conditional : .full
        case .foreground, .socketRecovery, .openTarget, .notificationOpen:
            // One round trip on the known route re-validates both the route and the catalogue,
            // and re-establishes the socket afterwards. The connectivity lanes wait for a
            // `hostRefreshSucceeded` after a resume, and a `304` records one.
            return canRefreshConditionally ? .conditional : .full
        case .launch, .hostChanged, .pullToRefresh, .structuralChange, .revisionGap,
             .mutationFollowUp, .userCheck:
            return .full
        }
    }
}
