import Foundation

#if os(iOS)
import UIKit

/// What the terminal surface shows while its content is not yet the truth. The three rules the
/// screen once had by accident and then lost, written down so a view change cannot lose them
/// again; `MobileTerminalPresentationTests` holds each row of the table.
///
/// - Opening a chat with a picture of its last screen: the picture, softened, and the loader
///   over it once the wait has lasted a beat.
/// - Opening a chat with no picture: the loader, at once.
/// - Coming back to a live screen (a reconnect, or the lock from leaving the app): the live
///   screen softened, and the loader over it once the wait has lasted a beat.
enum TerminalSurfacePresentation: Equatable {
    case live
    case lockedLive(showsLoader: Bool)
    case snapshot(showsLoader: Bool)
    case loader

    static func resolve(
        isLoading: Bool,
        keepsLiveScreen: Bool,
        hasSnapshot: Bool,
        waitedLongEnough: Bool
    ) -> TerminalSurfacePresentation {
        guard isLoading else { return .live }
        if keepsLiveScreen { return .lockedLive(showsLoader: waitedLongEnough) }
        if hasSnapshot { return .snapshot(showsLoader: waitedLongEnough) }
        return .loader
    }

    var showsLoader: Bool {
        switch self {
        case .live: return false
        case .lockedLive(let showsLoader), .snapshot(let showsLoader): return showsLoader
        case .loader: return true
        }
    }

    /// Whether a loader is owed only after the wait has lasted a beat, rather than at once.
    var delaysLoader: Bool {
        switch self {
        case .lockedLive, .snapshot: return true
        case .live, .loader: return false
        }
    }
}

/// The keyboard comes back if the chat was left while writing, and recently. Half an hour
/// later the moment has passed, and a chat opens with the keyboard down.
enum MobileTerminalKeyboardMemory {
    static var recall: TimeInterval { 30 * 60 }

    static func opensKeyboard(wasUp: Bool?, leftAt: Double?, now: Date = Date()) -> Bool {
        guard wasUp == true, let leftAt else { return false }
        let age = now.timeIntervalSince1970 - leftAt
        return age >= 0 && age <= recall
    }
}

/// The last picture of each chat's terminal, kept as the chat is left and shown softened when
/// it is opened again while its replay is still on the way. Quarter resolution, because it is
/// only ever seen blurred; a handful of chats, dropped under memory pressure, never persisted —
/// a cold launch shows the loader instead.
@MainActor
final class MobileTerminalSnapshotCache {
    static let shared = MobileTerminalSnapshotCache()
    static var captureScale: CGFloat { 0.25 }
    static var capacity: Int { 6 }

    private let images = NSCache<NSString, UIImage>()

    init() {
        images.countLimit = Self.capacity
    }

    func keep(_ view: UIView, for sessionID: String) {
        guard view.bounds.width > 0, view.bounds.height > 0 else { return }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = Self.captureScale
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: false)
        }
        store(image, for: sessionID)
    }

    func store(_ image: UIImage, for sessionID: String) {
        images.setObject(image, forKey: sessionID as NSString)
    }

    func image(for sessionID: String) -> UIImage? {
        images.object(forKey: sessionID as NSString)
    }

    func forget(_ sessionID: String) {
        images.removeObject(forKey: sessionID as NSString)
    }
}
#endif
