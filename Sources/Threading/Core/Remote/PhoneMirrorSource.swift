import Foundation

/// What can change about a page a phone is mirroring.
enum PhoneMirrorSourceChange: Sendable {
    /// A new document committed: a navigation or a reload.
    case document
    /// The address moved without a new document (`pushState`, a hash, history).
    case address
    /// Only the title changed.
    case title
}

/// A browser a mirror follows. Core names the seam; the browser view controller adopts it, so
/// Remote Access never reaches into a `WKWebView`.
@MainActor
protocol PhoneMirrorObservableSource: AnyObject {
    /// Calls `handler` after every committed document, same-document address change and title
    /// change, until the returned observation is invalidated.
    func observePhoneMirrorChanges(
        _ handler: @escaping @MainActor (PhoneMirrorSourceChange) -> Void
    ) -> PhoneMirrorSourceObservation
}

/// Keeps one observer registered until `invalidate()`.
@MainActor
final class PhoneMirrorSourceObservation {
    private var onInvalidate: (@MainActor () -> Void)?

    init(onInvalidate: @escaping @MainActor () -> Void) {
        self.onInvalidate = onInvalidate
    }

    func invalidate() {
        onInvalidate?()
        onInvalidate = nil
    }
}

/// One shared browser tab, addressed the way Remote Access addresses it.
struct PhoneMirrorSource: Hashable, Sendable {
    let sessionID: SessionID
    let tabID: UUID
}

/// The source as it stands now: what the phone loads and what both sides call it.
@MainActor
struct PhoneMirrorSourceSnapshot {
    /// Exported under `RemoteBrowserLinkPolicy`: shared tabs and http(s) pages only.
    let url: URL
    let title: String
    let browser: PhoneMirrorObservableSource
}
