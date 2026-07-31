import AppKit

// MARK: - Requests

/// One statement, built without being run — `ConfirmationRequest`'s OK-only sibling.
///
/// The copy stays the caller's for the same reason a confirmation's does: that is where the
/// runtime facts are. `notice` is what makes the statement declinable for the future; every
/// error path passes `nil`, so an error cannot be hidden — enforced by what the request can
/// express rather than by anyone remembering to check.
struct NoticeRequest {
    /// The register key, when the statement may be declined. `nil` always shows and offers
    /// no box.
    var notice: AppNotice?
    let title: String
    let message: String
    var style: ThemedAlert.Style = .informational
}

// MARK: - Notice Alert

/// The one way to state something in a modal the user may switch off.
///
/// An OK-only alert asks nothing, which is why the confirmation register deliberately does not
/// cover it — but a *receipt* shown after every invocation of the same command earns the same
/// way out a repeated question does. The box says "Don't show this message again" rather than
/// "Don't ask again", because nothing was asked; the hidden set lives beside the suppressed
/// confirmations in `AppSettings`, and the Settings ▸ General Confirmations card carries the
/// control that brings everything back.
///
/// This file sits in `UI/Alerts` because honouring the box means reading the modal response —
/// the read `scripts/theme_boundary_lint.swift` bans elsewhere, so a raw informational alert
/// cannot quietly grow a suppression box the register never heard of.
@MainActor
enum NoticeAlert {

    /// Shows the statement, or returns at once when its notice was hidden.
    ///
    /// `settings` is injectable so the silent path — the one that returns without putting a
    /// modal up — can be tested at all.
    static func show(_ request: NoticeRequest, in window: NSWindow?) {
        show(request, in: window, settings: .shared)
    }

    static func show(
        _ request: NoticeRequest,
        in window: NSWindow?,
        settings: AppSettings
    ) {
        guard isShown(request, settings: settings) else { return }

        let alert = makeAlert(request)
        let finish: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            guard let notice = request.notice,
                  remembers(
                      acknowledged: response == ThemedAlert.firstButtonResponse,
                      suppressionChecked: alert.suppressionButton?.state == .on
                  ) else { return }
            settings.setShows(false, for: notice)
        }

        if let window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    /// Whether the statement is put up at all. Split from `show` so the guard is assertable
    /// without a modal.
    static func isShown(_ request: NoticeRequest) -> Bool {
        isShown(request, settings: .shared)
    }

    static func isShown(_ request: NoticeRequest, settings: AppSettings) -> Bool {
        guard let notice = request.notice else { return true }
        return settings.shows(notice)
    }

    /// The box is honoured only when OK dismissed the alert. An escaped or sheet-closed
    /// notice recorded no decision — the same rule `ConfirmationAlert.remembers` states for
    /// an answer, kept pure for the same reason: the matrix is testable without a modal.
    static func remembers(acknowledged: Bool, suppressionChecked: Bool) -> Bool {
        acknowledged && suppressionChecked
    }

    /// Built without being run, so a test can read the wording and whether the box is there.
    static func makeAlert(_ request: NoticeRequest) -> ThemedAlert {
        let alert = ThemedAlert()
        alert.messageText = request.title
        alert.informativeText = request.message
        alert.alertStyle = request.style
        alert.addButton(withTitle: L10n.string("OK"))

        if request.notice != nil {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = L10n.string("Don't show this message again")
        }
        return alert
    }
}
