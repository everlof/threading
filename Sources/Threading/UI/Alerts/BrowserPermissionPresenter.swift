import AppKit
import ThreadingRemoteKit

@MainActor
enum BrowserPermissionPresenter {
    /// Every app-owned browser decision has one identity across the Mac and owner phone.
    static func choose(
        _ request: ChoiceRequest,
        for sessionID: SessionID,
        in window: NSWindow?,
        completion: @escaping (Int?) -> Void
    ) {
        guard (1...2).contains(request.options.count),
              request.options.allSatisfy(\.isEnabled) else {
            completion(nil)
            return
        }
        let presentation = ConfirmationPresentation()
        guard let requestID = BrowserPermissionRequests.shared.enqueue(
            sessionID: sessionID,
            title: request.title,
            message: request.message,
            allowTitle: request.options[0].title,
            rememberTitle: request.options.count > 1 ? request.options[1].title : nil,
            denyTitle: request.cancelTitle,
            dismiss: { presentation.dismiss() },
            settle: { decision in
                switch decision {
                case .allowOnce: completion(0)
                case .allowRemembered: completion(1)
                case .deny: completion(nil)
                }
            }
        ) else { return }
        ConfirmationAlert.choose(
            request,
            in: window,
            presentation: presentation
        ) { chosen in
            let decision: RemoteBrowserPermissionDecision
            switch chosen {
            case 0: decision = .allowOnce
            case 1: decision = .allowRemembered
            default: decision = .deny
            }
            BrowserPermissionRequests.shared.resolve(
                sessionID: sessionID, id: requestID, decision: decision
            )
        }
    }

    static func confirm(
        _ request: ConfirmationRequest,
        for sessionID: SessionID,
        in window: NSWindow?,
        completion: @escaping (Bool) -> Void
    ) {
        choose(ChoiceRequest(
            prompt: request.prompt, title: request.title, message: request.message,
            options: [ConfirmationOption(title: request.confirmTitle)],
            cancelTitle: request.cancelTitle, style: request.style, accessory: request.accessory
        ), for: sessionID, in: window) { completion($0 == 0) }
    }
}
