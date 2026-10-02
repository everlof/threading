import AppKit
import ThreadingController

/// The host sheet behind `AutomationApprover`. An agent's request to enable or run an
/// automation waits here until the person answers; the sheet shows the exact revision (or the
/// remote controller's current spec) that the answer applies to.
@MainActor
enum AutomationApprovalPresenter {
    /// `byAgent` says who is asking. The Remote page uses the same review for its own buttons,
    /// where the person is the one who asked.
    static func ask(_ request: AutomationApprovalRequest, in window: NSWindow, byAgent: Bool = true) async -> Bool {
        var sourceName: String?
        if case .local(_, _, let revision) = request, revision.automation?.schedule == nil {
            sourceName = (try? await TriggerStore.shared.source(id: revision.sourceInstallationID))?.displayName
        }
        let confirmation = confirmationRequest(for: request, byAgent: byAgent, context: .live(sourceName: sourceName))
        return await withCheckedContinuation { continuation in
            ConfirmationAlert.ask(confirmation, in: window) { approved in
                continuation.resume(returning: approved)
            }
        }
    }

    static func confirmationRequest(
        for request: AutomationApprovalRequest,
        byAgent: Bool = true,
        context: @autoclosure () -> AutomationReview.Context = .live()
    ) -> ConfirmationRequest {
        let enable = request.operation == .enable
        let origin = byAgent ? L10n.string("An agent asked for this.") + " " : ""
        switch request {
        case .local(_, let name, let revision):
            return ConfirmationRequest(
                prompt: .approveTriggerActivation,
                title: enable ? L10n.format("Enable “%@”?", name) : L10n.format("Run “%@” now?", name),
                message: origin + (enable
                    ? L10n.string("Threading will then start agents with these settings on its schedule or when its event arrives, without asking again.")
                    : L10n.string("Threading will start an agent with these settings once, now.")),
                confirmTitle: enable ? L10n.string("Enable") : L10n.string("Run"),
                accessory: TriggerCenterViewController.reviewAccessory(
                    for: revision, purpose: enable ? .enable : .runNow, context: context()
                )
            )
        case .remote(_, let automation, let hostName):
            return ConfirmationRequest(
                prompt: .approveTriggerActivation,
                title: enable
                    ? L10n.format("Enable “%@” on %@?", automation.spec.name, hostName)
                    : L10n.format("Run “%@” on %@ now?", automation.spec.name, hostName),
                message: origin + (enable
                    ? L10n.string("The host's supervisor will then start its worker on this schedule, even while this Mac is offline.")
                    : L10n.string("The host's worker will start once, now, with these instructions.")),
                confirmTitle: enable ? L10n.string("Enable") : L10n.string("Run"),
                accessory: remoteReviewAccessory(automation)
            )
        }
    }

    /// The remote spec as the controller holds it now. The worker's own recipe decides what the
    /// run may do, so the sheet names the worker rather than implying permissions it cannot see.
    static func remoteReviewAccessory(_ automation: ControllerAutomation) -> NSView {
        let facts: [FactSheetView.Fact] = [
            .init(label: L10n.string("Worker"), value: automation.spec.workerID.description, identifier: "worker"),
            .init(label: L10n.string("When"),
                  value: automation.spec.schedule?.summary ?? L10n.string("Manual or event-driven"),
                  identifier: "when"),
            .init(label: L10n.string("Revision"), value: String(automation.revision), identifier: "revision"),
        ]
        return AutomationReviewView(review: AutomationReview(facts: facts, instructions: automation.spec.instruction))
    }
}
