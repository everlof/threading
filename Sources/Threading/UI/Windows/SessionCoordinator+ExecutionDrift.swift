import AppKit

// MARK: - Observed Execution Drift

/// What the window does about a chat found working in a checkout other than the one that owns it.
///
/// `SessionExecutionLocusTracker` notices; this decides. The split matters because the decision
/// is not one thing: it is a policy reading, sometimes a confirmation, always a receipt, and a
/// row that has to keep telling the truth in between. None of that belongs in Core.
@MainActor
extension SessionCoordinator {

    // MARK: - Internal Methods

    /// Reconciles one newly observed drift.
    ///
    /// Only a sibling checkout is actionable. A chat working outside its own repository cannot
    /// be re-filed anywhere — `SessionCheckoutCoordinator.validate` refuses it as
    /// `differentRepository`, correctly — so the row's marker is the whole of the response, and
    /// putting a band on screen offering nothing would be noise.
    func reconcileObservedExecutionDrift(_ sessionID: SessionID) {
        guard case .siblingCheckout(let checkout) =
                SessionExecutionLocusTracker.shared.drift(forSessionID: sessionID),
              let session = environment.projectStore.session(withID: sessionID) else { return }

        let checkoutCoordinator = SessionCheckoutCoordinator.shared

        switch checkoutCoordinator.reconcileObservedExecution(
            sessionID: sessionID,
            checkout: checkout
        ) {
        case .queued(let move):
            // A move already fenced for somewhere else comes back as that move, not this one.
            // Reporting it would name the checkout just observed while the chat is on its way to
            // a different one, which is the same class of lie this whole feature exists to stop.
            // It happens for real: an agent that visits a second worktree and moves on again.
            guard move.worktreeIdentity == checkout.worktreeIdentity else { return }
            toastPresenter(Self.observedMoveToast(
                for: session,
                checkout: checkout
            ))
        case .approvalRequired:
            toastPresenter(Self.observedMoveOfferToast(
                for: session,
                checkout: checkout,
                move: { [weak self] in self?.approveObservedMove(sessionID, to: checkout) }
            ))
        case .denied, .failed:
            // The row keeps its marker and the user keeps the row menu. A refusal here is
            // ordinary — a worktree removed between the report and the reconcile, a detached
            // head, a reading taken before the last commit landed — and none of them are worth
            // a band.
            //
            // Giving up on following a chat entirely is not ordinary: it is the one refusal that
            // changes what Threading will do for the rest of the run, so it gets a band. It
            // carries its **own** replacement key rather than the drift band's — that key exists
            // to collapse repeated drift receipts into one row, and a permanent decision must not
            // be overwritten by the next ordinary reading about the same chat.
            guard checkoutCoordinator.hasAbandonedFollowing(sessionID: sessionID) else { break }
            toastPresenter(Self.abandonedFollowingToast(for: session))
        }
    }

    // MARK: - Private Methods

    /// Spends the confirmation the offer band collected.
    ///
    /// A refusal is reported rather than swallowed. The user pressed a button; a worktree removed
    /// or a head detached since the offer was drawn is an ordinary outcome, and answering it with
    /// nothing at all is indistinguishable from the button not working.
    private func approveObservedMove(_ sessionID: SessionID, to checkout: ObservedCheckout) {
        switch SessionCheckoutCoordinator.shared.requestMove(
            sessionID: sessionID,
            checkoutPath: checkout.root,
            authorityBasis: .observedExecution,
            reason: "Observed running in \(checkout.displayName)",
            approval: true
        ) {
        case .queued:
            break
        case .approvalRequired, .denied:
            break
        case .failed(let message):
            toastPresenter(ToastRequest(
                message: L10n.format("Could not move to %@", checkout.displayName),
                detail: message,
                identifier: "sidebar.toast.execution-drift.failed"
            ))
        }
    }

    /// The receipt for a move Threading made on its own.
    ///
    /// It names the actor and the reason, because a chat that changed checkout while the user
    /// was reading something else is a window rearranging itself, and the first question that
    /// raises is who did it.
    ///
    /// Keyed on the session so one chat holds one band. An agent that visits a worktree, moves on
    /// and comes back reports drift more than once, and a stack of bands about one conversation
    /// reads as several things having happened.
    static func observedMoveToast(
        for session: AgentSession,
        checkout: ObservedCheckout
    ) -> ToastRequest {
        ToastRequest(
            message: L10n.format(
                "“%@” now runs in %@",
                session.displayTitle,
                checkout.displayName
            ),
            detail: L10n.string("The agent has been working there."),
            dwell: ToastDefaults.unattendedDwell,
            identifier: "sidebar.toast.execution-drift.moved",
            replacementID: "execution-drift.\(session.id.uuidString)"
        )
    }

    /// The receipt for a chat Threading has stopped following.
    ///
    /// Said plainly, because the alternative is what actually shipped: ownership moving over and
    /// over while one coalesced band showed a single unremarkable sentence. Nothing is broken and
    /// nothing is lost — the chat keeps running and the row menu still moves it by hand — so this
    /// states the fact and the manual way forward rather than offering a retry that would walk
    /// straight back into the loop.
    static func abandonedFollowingToast(for session: AgentSession) -> ToastRequest {
        ToastRequest(
            message: L10n.format(
                "Stopped following “%@” between checkouts",
                session.displayTitle
            ),
            detail: L10n.string(
                "Its agent kept moving between checkouts. Threading left the chat where it is; "
                    + "move it yourself from the chat's menu."
            ),
            dwell: ToastDefaults.unattendedDwell,
            identifier: "sidebar.toast.execution-drift.abandoned",
            replacementID: "execution-drift-abandoned.\(session.id.uuidString)"
        )
    }

    /// The offer for a move that has not happened.
    ///
    /// Deliberately a band with an action rather than the modal the agent-initiated path raises.
    /// That one interrupts a turn the user started a moment ago and is answering a request some
    /// model made; this one can fire for any of a dozen background chats the moment an agent
    /// runs `cd`, and a stack of modal sheets for something nobody asked for is the wrong trade.
    /// The row's marker is what makes the offer durable once the band has gone.
    static func observedMoveOfferToast(
        for session: AgentSession,
        checkout: ObservedCheckout,
        move: @escaping () -> Void
    ) -> ToastRequest {
        ToastRequest(
            message: L10n.format(
                "“%@” is working in %@",
                session.displayTitle,
                checkout.displayName
            ),
            detail: L10n.string(
                "Threading still resumes it in the checkout it started from. Move it to keep "
                    + "the two together."
            ),
            actionTitle: L10n.string("Move Chat"),
            action: move,
            dwell: ToastDefaults.unattendedDwell,
            identifier: "sidebar.toast.execution-drift.offer",
            replacementID: "execution-drift.\(session.id.uuidString)"
        )
    }
}
