import Foundation

// MARK: - Quit Answer

/// What the user said when Threading asked about quitting.
///
/// Three answers rather than two, because with a background host running there are two different
/// quits. Today's question — "everything closes, only work in flight is lost" — is a
/// *confirmation*: there is one way to go ahead and the only other answer is not to. Once
/// `threading-ptyd` is holding somebody's agents that stops being true, and a confirmation that
/// silently picked one of the two would be deciding the fate of work the user can no longer see.
///
/// `.leaveRunning` is deliberately the same shape as today's yes: host-backed sessions are handed
/// over and everything else closes, which is exactly what `applicationShouldTerminate` has done
/// since detach landed. `.stopEverything` is the answer that costs something, and it is the one
/// that has to be asked for.
enum QuitAnswer: Equatable {

    /// Quit, handing the host-backed sessions to the daemon. The recoverable answer.
    case leaveRunning

    /// Quit, and end the host-backed children too.
    case stopEverything

    /// Do not quit.
    case cancel

    /// Whether the quit goes ahead at all.
    var quits: Bool { self != .cancel }
}

// MARK: - Quit Question

/// The quit question, built without being asked.
///
/// Two shapes rather than one type with an unused third button, because the two-answer case is
/// not a degenerate three-answer case — it is the question this app has always asked, and it has
/// to stay exactly that. `AppDelegate.quitConfirmation(runningSessionCount:inFlightTurnCount:)`
/// keeps building it, and the three-answer builder *calls* that one when nothing is host-backed,
/// so "the wording did not change for a launch with no background host" is true by construction
/// rather than by two copies being kept in step.
///
/// The seam is `ConfirmationRequest`'s: built here, asked elsewhere, so a test can hold the
/// wording to what quitting does without a modal.
enum QuitQuestion {

    /// Today's question: one way to go ahead, and Cancel.
    case confirms(ConfirmationRequest)

    /// Leave them running, stop them, or cancel.
    case chooses(ChoiceRequest)

    // MARK: - Reading

    var title: String {
        switch self {
        case .confirms(let request): return request.title
        case .chooses(let request): return request.title
        }
    }

    var message: String {
        switch self {
        case .confirms(let request): return request.message
        case .chooses(let request): return request.message
        }
    }

    /// The affirmative answers in button order, before Cancel. One for a confirmation, two for a
    /// choice — readable so a test asserts the buttons the user sees rather than the branch that
    /// produced them.
    var answers: [String] {
        switch self {
        case .confirms(let request): return [request.confirmTitle]
        case .chooses(let request): return request.options.map(\.title)
        }
    }

    /// Which prompt in the register this question is, so a test can hold it to its policy.
    var prompt: ConfirmationPrompt {
        switch self {
        case .confirms(let request): return request.prompt
        case .chooses(let request): return request.prompt
        }
    }

    /// The answer an index into `answers` means. `nil` — Cancel, Escape, a dismissed sheet — is
    /// `.cancel` on both shapes.
    func answer(atIndex index: Int?) -> QuitAnswer {
        guard let index else { return .cancel }
        switch self {
        case .confirms:
            return index == 0 ? .leaveRunning : .cancel
        case .chooses:
            switch index {
            case 0: return .leaveRunning
            case 1: return .stopEverything
            default: return .cancel
            }
        }
    }
}

// MARK: - The three-answer wording

/// The copy for a quit that has two different kinds of session to account for.
///
/// Separate from `AppDelegate` because it is a pure function of three counts and nothing else,
/// and because the counts are the whole difficulty: a session the daemon keeps is not closing, a
/// session it cannot keep is, and a turn being written is lost only for the second kind. Saying
/// "3 sessions close" over a set where two of them keep working is the exact overstatement the
/// quit sheet already learned not to make once, with agents that were merely idle.
enum QuitChoiceCopy {

    /// - Parameters:
    ///   - backgroundSessionCount: sessions `threading-ptyd` will keep running.
    ///   - closingSessionCount: sessions that close with the app — the daemon cannot host them,
    ///     or the session opted out, or there is no daemon.
    ///   - inFlightTurnCount: turns being written among the *closing* ones. A host-backed session
    ///     mid-turn loses nothing, so counting it here would name a loss that does not happen.
    static func request(
        backgroundSessionCount: Int,
        closingSessionCount: Int,
        inFlightTurnCount: Int
    ) -> ChoiceRequest {
        ChoiceRequest(
            prompt: .quitWithBackgroundSessions,
            title: title(backgroundSessionCount: backgroundSessionCount),
            message: message(
                backgroundSessionCount: backgroundSessionCount,
                closingSessionCount: closingSessionCount,
                inFlightTurnCount: inFlightTurnCount
            ),
            options: [
                ConfirmationOption(title: leaveTitle(count: backgroundSessionCount)),
                ConfirmationOption(title: stopTitle(count: backgroundSessionCount))
            ]
        )
    }

    // MARK: - Private

    /// Leads with the sessions that keep working, because that is what changed: the user pressed
    /// the same Cmd+Q and is being offered a different thing.
    private static func title(backgroundSessionCount: Int) -> String {
        backgroundSessionCount == 1
            ? L10n.string("Quit and leave one session running?")
            : L10n.format("Quit and leave %lld sessions running?", Int64(backgroundSessionCount))
    }

    private static func message(
        backgroundSessionCount: Int,
        closingSessionCount: Int,
        inFlightTurnCount: Int
    ) -> String {
        var clauses = [background(count: backgroundSessionCount)]
        if closingSessionCount > 0 { clauses.append(closing(count: closingSessionCount)) }
        if inFlightTurnCount > 0 { clauses.append(inFlight(count: inFlightTurnCount)) }
        return clauses.joined(separator: " ")
    }

    private static func background(count: Int) -> String {
        count == 1
            ? L10n.string(
                "One session keeps working in the background and is taken back on the next launch."
            )
            : L10n.format(
                "%lld sessions keep working in the background and are taken back on the next "
                    + "launch.",
                Int64(count)
            )
    }

    /// The sessions the daemon cannot keep. Described as closing, because that is what happens to
    /// them — the same sentence the two-answer question makes about all of them.
    private static func closing(count: Int) -> String {
        count == 1
            ? L10n.string(
                "One other session closes; its conversation is kept and can be resumed."
            )
            : L10n.format(
                "%lld other sessions close; their conversations are kept and can be resumed.",
                Int64(count)
            )
    }

    private static func inFlight(count: Int) -> String {
        count == 1
            ? L10n.string("The turn in flight is lost.")
            : L10n.format("%lld turns in flight are lost.", Int64(count))
    }

    private static func leaveTitle(count: Int) -> String {
        count == 1
            ? L10n.string("Leave One Running")
            : L10n.format("Leave %lld Running", Int64(count))
    }

    private static func stopTitle(count: Int) -> String {
        count == 1
            ? L10n.string("Stop It and Quit")
            : L10n.string("Stop Them and Quit")
    }
}
