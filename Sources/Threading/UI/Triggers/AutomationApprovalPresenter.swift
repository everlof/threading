import AppKit
import ThreadingController

/// The host sheet behind `AutomationApprover`. An agent's request to enable or run an
/// automation waits here until the person answers; the sheet shows the exact revision (or the
/// remote controller's current spec) that the answer applies to.
@MainActor
enum AutomationApprovalPresenter {
    /// The same measure as the Activate sheet's review, so the two read as one family.
    private enum Layout {
        static let accessoryWidth: CGFloat = 520
        static let instructionsHeight: CGFloat = 150
    }

    /// `byAgent` says who is asking. The Remote page uses the same review for its own buttons,
    /// where the person is the one who asked.
    static func ask(_ request: AutomationApprovalRequest, in window: NSWindow, byAgent: Bool = true) async -> Bool {
        let confirmation = confirmationRequest(for: request, byAgent: byAgent)
        return await withCheckedContinuation { continuation in
            ConfirmationAlert.ask(confirmation, in: window) { approved in
                continuation.resume(returning: approved)
            }
        }
    }

    static func confirmationRequest(for request: AutomationApprovalRequest, byAgent: Bool = true) -> ConfirmationRequest {
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
                accessory: TriggerCenterViewController.reviewAccessory(for: revision)
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
        let timing = automation.spec.schedule?.summary ?? L10n.string("Manual or event-driven")
        let facts = NSTextField(wrappingLabelWithString: L10n.format(
            "Worker: %@\nTiming: %@\nRevision: %lld",
            automation.spec.workerID.description,
            timing,
            Int64(automation.revision)
        ))
        facts.applyFont(.detail())
        facts.textColor = Design.Text.secondary

        let instructionsTitle = NSTextField(labelWithString: L10n.string("Agent instructions"))
        instructionsTitle.applyFont(.emphasizedBody)
        instructionsTitle.textColor = Design.Text.label
        let instructions = ThemedTextView.scrolling()
        instructions.textView.string = automation.spec.instruction
        instructions.textView.isEditable = false
        instructions.textView.isSelectable = true
        instructions.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [facts, instructionsTitle, instructions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.small
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: Layout.accessoryWidth),
            instructions.widthAnchor.constraint(equalTo: stack.widthAnchor),
            instructions.heightAnchor.constraint(equalToConstant: Layout.instructionsHeight),
        ])
        return stack
    }
}
