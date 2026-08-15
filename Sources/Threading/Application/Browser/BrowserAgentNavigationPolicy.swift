import Foundation

/// Owns the form-submission boundary for one bounded agent browser action.
///
/// WebKit reports navigation types through the UI adapter. Whether a submission belongs to the
/// active agent action, whether its one approved submission was already consumed, and whether a
/// stale action may clear newer policy state are application decisions kept here so they can be
/// verified without constructing a web view.
@MainActor
final class BrowserAgentNavigationPolicy {
    struct ActionID: Equatable, Sendable {
        fileprivate let rawValue: Int
    }

    enum FormSubmissionDecision: Equatable {
        case allow
        case cancel
    }

    private struct ActiveAction {
        let id: ActionID
        let allowsFormSubmission: Bool
        var consumedFormSubmission = false
        var blockedFormSubmission = false
    }

    private var nextID = 0
    private var activeAction: ActiveAction?

    @discardableResult
    func beginAction(allowsFormSubmission: Bool) -> ActionID {
        nextID += 1
        let id = ActionID(rawValue: nextID)
        activeAction = ActiveAction(id: id, allowsFormSubmission: allowsFormSubmission)
        return id
    }

    /// Clears policy state only when the caller still owns the active action. An older async
    /// action finishing after a newer one began must not disable the newer action's guard.
    func endAction(_ id: ActionID) {
        guard activeAction?.id == id else { return }
        activeAction = nil
    }

    /// User-initiated submissions remain ordinary browser navigation. An active agent action may
    /// submit at most once, and only when its caller explicitly enabled that capability.
    func decideFormSubmission() -> FormSubmissionDecision {
        guard var action = activeAction else { return .allow }
        guard action.allowsFormSubmission, !action.consumedFormSubmission else {
            action.blockedFormSubmission = true
            activeAction = action
            return .cancel
        }
        action.consumedFormSubmission = true
        activeAction = action
        return .allow
    }

    func wasFormSubmissionBlocked(during id: ActionID) -> Bool {
        guard let action = activeAction, action.id == id else { return false }
        return action.blockedFormSubmission
    }
}
