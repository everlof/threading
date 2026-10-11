import AppKit

@MainActor
enum ProxyClientApprovalPresenter {
    private enum Defaults {
        static let inlineHostCharacters = 200
        static let sessionTitleCharacters = 128
        static let disclosureWidth: CGFloat = 500
        static let disclosureHeight: CGFloat = 120
    }
    static func request(address: String, scope: ProxyLaunchScope, sessionTitle: String) -> ChoiceRequest {
        let inspection = scope.hosts.isEmpty ? L10n.string("No HTTPS hosts selected") : scope.hosts.joined(separator: ", ")
        let usesDisclosure = inspection.count > Defaults.inlineHostCharacters
        let visibleInspection = usesDisclosure ? L10n.string("Selected hosts shown below") : inspection
        let title = String(sessionTitle.replacingOccurrences(of: "\n", with: " ").prefix(Defaults.sessionTitleCharacters))
        return ChoiceRequest(
            prompt: .approveProxyClient,
            title: L10n.format("Allow %@ to use this proxy?", address),
            message: L10n.format("Chat: %@\nProxy address: %@\nInspect HTTPS: %@\n\nAllow Once admits the connections waiting now. This Capture lasts until capture stops. Always Allow remembers this IP, proxy address and HTTPS scope. An IP can belong to a different device later. Forget saved IPs in Settings → Tools. Deny blocks retries until capture stops.", title, scope.listenAddress, visibleInspection),
            options: [
                ConfirmationOption(title: L10n.string("Allow Once")),
                ConfirmationOption(title: L10n.string("This Capture")),
                ConfirmationOption(title: L10n.string("Always Allow This IP"))
            ],
            cancelTitle: L10n.string("Deny"),
            accessory: usesDisclosure ? hostDisclosure(scope.hosts) : nil
        )
    }

    private static func hostDisclosure(_ hosts: [String]) -> NSView {
        let scroll = ThemedTextView.scrolling()
        scroll.frame = NSRect(x: 0, y: 0, width: Defaults.disclosureWidth, height: Defaults.disclosureHeight)
        scroll.textView.string = hosts.joined(separator: "\n")
        scroll.textView.isEditable = false
        scroll.textView.isSelectable = true
        scroll.textView.isRichText = false
        scroll.textView.applyFont(.body)
        scroll.textView.setAccessibilityLabel(L10n.string("HTTPS inspection hosts"))
        return scroll
    }

    static func present(_ client: ProxyClientRequest, scope: ProxyLaunchScope, sessionID: SessionID,
                        in window: NSWindow?, completion: @escaping @MainActor (ProxyClientDecision) -> Void) -> (@MainActor () -> Void)? {
        guard let window else { return nil }
        let presentation = ConfirmationPresentation()
        let title = ProjectStore.shared.session(withID: sessionID)?.displayTitle ?? L10n.string("Traffic capture")
        ConfirmationAlert.choose(request(address: client.address, scope: scope, sessionTitle: title),
                                 in: window, presentation: presentation) { index in
            let decision: ProxyClientDecision
            switch index {
            case 0: decision = .once
            case 1: decision = .capture
            case 2: decision = .always
            default: decision = .deny
            }
            completion(decision)
        }
        return { presentation.dismiss() }
    }
}
