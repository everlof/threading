import Foundation

/// Launch Services may deliver URLs before async application startup has acquired the state
/// lock or created any windows. Keep values only until that owner explicitly becomes ready.
@MainActor
final class ApplicationOpenURLDelivery {
    private var pending: [URL] = []
    private var isReady = false
    private let deliver: ([URL]) -> Void

    init(deliver: @escaping ([URL]) -> Void) {
        self.deliver = deliver
    }

    func receive(_ urls: [URL]) {
        guard isReady else {
            pending.append(contentsOf: urls)
            return
        }
        deliver(urls)
    }

    func becomeReady() {
        guard !isReady else { return }
        isReady = true
        let urls = pending
        pending.removeAll()
        if !urls.isEmpty { deliver(urls) }
    }

    static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        return url.host?.isEmpty == false
    }
}
