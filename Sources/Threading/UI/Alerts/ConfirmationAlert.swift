import AppKit

// MARK: - Requests

/// One confirmation, built without being run.
///
/// The copy stays the caller's because that is where the runtime facts are — which session,
/// which account, how many directories — while the register owns only the policy. Keeping the
/// two apart is also what lets a test hold an alert's wording to what the action actually does,
/// which is the seam `SessionCoordinator`'s alert builders already offered and which survives
/// the move behind the gate (`SessionLifecycleConfirmationTests`).
struct ConfirmationRequest {
    let prompt: ConfirmationPrompt
    let title: String
    let message: String
    let confirmTitle: String
    var cancelTitle: String = L10n.string("Cancel")
    var style: ThemedAlert.Style = .warning
    /// Shown above the buttons; the permission sheet's edit diff is the only one so far.
    var accessory: NSView?
}

/// One of several affirmative answers.
struct ConfirmationOption {
    let title: String
    /// A choice that does not apply right now is disabled rather than dropped — the same rule
    /// the Settings page's refinement rows follow: a control that vanishes explains less than
    /// one that waits. Sharing a chat that has never run is the case that needs it.
    var isEnabled: Bool = true
}

/// Several affirmative answers plus a way out.
struct ChoiceRequest {
    let prompt: ConfirmationPrompt
    let title: String
    let message: String
    let options: [ConfirmationOption]
    var cancelTitle: String = L10n.string("Cancel")
    var style: ThemedAlert.Style = .warning
    var accessory: NSView?
}

/// Lets another authenticated presentation retire this same question without choosing a button.
@MainActor
final class ConfirmationPresentation {
    fileprivate weak var alert: ThemedAlert?
    func dismiss() { alert?.dismiss() }
}

// MARK: - Confirmation Alert

/// The only supported way to ask the user a question they can answer wrongly.
///
/// Everything a confirmation needs that is easy to get wrong once per call site lives here:
/// which button Return activates, whether a "Don't ask again" box appears at all, when that box
/// is honoured, the sheet-or-modal fork that six call sites had each written by hand, and the
/// index arithmetic behind `alertThirdButtonReturn` — which stops at three, while the share
/// sheet already offers four buttons and reads its fourth through `default:`.
///
/// `scripts/theme_boundary_lint.swift` bans reading `alertNthButtonReturn` outside this
/// directory, so a raw alert cannot quietly grow a second button and become a confirmation the
/// register never heard of.
@MainActor
enum ConfirmationAlert {

    // MARK: - Asking

    /// Two buttons and a decision. Returns whether the action may go ahead.
    ///
    /// `settings` is injectable so the suppressed path — the one that returns without putting a
    /// modal up — can be tested at all.
    static func ask(_ request: ConfirmationRequest) -> Bool {
        ask(request, settings: .shared)
    }

    static func ask(_ request: ConfirmationRequest, settings: AppSettings) -> Bool {
        guard settings.asks(before: request.prompt) else { return true }
        let alert = makeAlert(request)
        return accepted(alert.runModal(), for: request.prompt, in: alert, settings: settings)
    }

    static func ask(
        _ request: ConfirmationRequest,
        in window: NSWindow?,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        ask(request, in: window, settings: .shared, completion: completion)
    }

    static func ask(
        _ request: ConfirmationRequest,
        in window: NSWindow?,
        settings: AppSettings,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        guard settings.asks(before: request.prompt) else {
            completion(true)
            return
        }
        let alert = makeAlert(request)
        present(alert, in: window) { response in
            completion(accepted(response, for: request.prompt, in: alert, settings: settings))
        }
    }

    // MARK: - Choosing

    /// Several affirmative answers plus a way out, and deliberately never suppressible: a
    /// remembered answer has to be *an* answer, and a box beside three of them says nothing
    /// about which one it would repeat. Only an `.alwaysAsks` prompt may arrive here, which is
    /// checkable precisely because the register exists.
    ///
    /// Returns the index of the chosen option, or `nil` for the way out.
    static func choose(_ request: ChoiceRequest) -> Int? {
        chosen(makeAlert(request).runModal(), in: request)
    }

    static func choose(
        _ request: ChoiceRequest,
        in window: NSWindow?,
        presentation: ConfirmationPresentation? = nil,
        completion: @escaping @MainActor (Int?) -> Void
    ) {
        let alert = makeAlert(request)
        presentation?.alert = alert
        present(alert, in: window) { completion(chosen($0, in: request)) }
    }

    // MARK: - Judgement

    /// Whether the box is honoured. Only an accepted prompt may be remembered: ticking it and
    /// then pressing Cancel would silence a prompt for an action the user had just declined,
    /// and the *next* invocation would go straight through in silence. Pure, so the matrix is
    /// testable without a modal — the same split `AttentionAlertPolicy` keeps from its center.
    static func remembers(accepted: Bool, suppressionChecked: Bool) -> Bool {
        accepted && suppressionChecked
    }

    /// The one place in the app that turns a modal response into a button index, and the reason
    /// it is arithmetic rather than `alertFirstButtonReturn`/`Second`/`Third`: the named
    /// constants stop at three, and the share sheet already offers four buttons — its fourth
    /// arrived through a `default:` clause that also catches every unrelated dismissal. `nil`
    /// is the way out. Pure, so the off-by-one is testable without a modal.
    static func chosenIndex(_ response: NSApplication.ModalResponse, optionCount: Int) -> Int? {
        let index = response.rawValue - ThemedAlert.firstButtonResponse.rawValue
        return (0..<optionCount).contains(index) ? index : nil
    }

    // MARK: - Building

    /// Built without being run, so a test can read the wording, the button order, which button
    /// carries Return, and whether the suppression box is there at all.
    static func makeAlert(_ request: ConfirmationRequest) -> ThemedAlert {
        let alert = base(
            title: request.title,
            message: request.message,
            style: request.style,
            accessory: request.accessory
        )
        alert.addButton(withTitle: request.confirmTitle)
        alert.addButton(withTitle: request.cancelTitle)
        applyDefaultButton(request.prompt, to: alert)

        if request.prompt.suppression != nil {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = L10n.string("Don't ask again")
        }
        return alert
    }

    static func makeAlert(_ request: ChoiceRequest) -> ThemedAlert {
        assert(
            request.prompt.suppression == nil,
            "\(request.prompt.rawValue) is suppressible; a remembered answer needs one decision"
        )
        let alert = base(
            title: request.title,
            message: request.message,
            style: request.style,
            accessory: request.accessory
        )
        for option in request.options {
            alert.addButton(withTitle: option.title)
        }
        alert.addButton(withTitle: request.cancelTitle)
        for (index, option) in request.options.enumerated() where !option.isEnabled {
            alert.buttons[index].isEnabled = false
        }
        applyDefaultButton(request.prompt, to: alert)
        return alert
    }

    // MARK: - Private

    private static func base(
        title: String,
        message: String,
        style: ThemedAlert.Style,
        accessory: NSView?
    ) -> ThemedAlert {
        let alert = ThemedAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.accessoryView = accessory
        return alert
    }

    /// The register's one presentational consequence: an irreversible action does not answer to
    /// the chord that dismisses a dialog. Applied here rather than per site, which is how it
    /// came to be true of exactly one alert out of eight.
    private static func applyDefaultButton(_ prompt: ConfirmationPrompt, to alert: ThemedAlert) {
        guard prompt.defaultsToCancel else { return }
        alert.buttons.first?.hasDestructiveAction = true
        alert.buttons.first?.keyEquivalent = ""
        alert.buttons.last?.keyEquivalent = "\r"
    }

    private static func present(
        _ alert: ThemedAlert,
        in window: NSWindow?,
        completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void
    ) {
        if let window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    private static func chosen(
        _ response: NSApplication.ModalResponse,
        in request: ChoiceRequest
    ) -> Int? {
        chosenIndex(response, optionCount: request.options.count)
    }

    private static func accepted(
        _ response: NSApplication.ModalResponse,
        for prompt: ConfirmationPrompt,
        in alert: ThemedAlert,
        settings: AppSettings
    ) -> Bool {
        // A two-button confirmation is a one-option choice: index 0 is the action, anything
        // else — Cancel, Escape, a closed sheet — is not.
        let accepted = chosenIndex(response, optionCount: 1) == 0
        if remembers(accepted: accepted, suppressionChecked: alert.suppressionButton?.state == .on) {
            settings.setAsks(false, before: prompt)
        }
        return accepted
    }
}
