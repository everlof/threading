import UIKit
import ThreadingRemoteKit

/// The authenticated session connection calls this only for a live, unexpired request.
/// Never defers a write until foregrounding: that could replace something copied meanwhile.
@MainActor
enum MobileClipboardWriter {
    static func copy(
        _ request: RemoteClipboardWrite,
        isActive: Bool = UIApplication.shared.applicationState == .active,
        now: TimeInterval = Date().timeIntervalSince1970,
        pasteboard: UIPasteboard = .general
    ) -> RemoteClipboardResult {
        guard isActive else { return .inactive }
        guard request.expiresAt.isFinite, request.expiresAt > now else { return .expired }
        guard request.type == RemoteClipboardPolicy.writeType,
              !request.requestID.isEmpty, !request.text.isEmpty,
              request.text.utf8.prefix(RemoteClipboardPolicy.maximumTextBytes + 1).count
                <= RemoteClipboardPolicy.maximumTextBytes else { return .invalid }
        pasteboard.setItems(
            [["public.utf8-plain-text": request.text]],
            options: [.localOnly: true]
        )
        return pasteboard.string == request.text ? .copied : .failed
    }
}
