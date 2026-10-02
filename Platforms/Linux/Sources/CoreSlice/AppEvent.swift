import Foundation

/// A notification whose concrete value is also its payload. Callers can no longer pair a name
/// with the wrong `object` type, and observers receive the value they asked for without casts.
public protocol AppEvent: Sendable {
    static var name: Notification.Name { get }
}

extension NotificationCenter {
    public func post<Event: AppEvent>(_ event: Event) {
        post(name: Event.name, object: event)
    }

    @discardableResult
    @MainActor
    public func observe<Event: AppEvent>(
        _ type: Event.Type,
        using handler: @escaping @MainActor @Sendable (Event) -> Void
    ) -> NSObjectProtocol {
        addObserver(forName: Event.name, object: nil, queue: .main) { notification in
            guard let event = notification.object as? Event else { return }
            MainActor.assumeIsolated {
                handler(event)
            }
        }
    }
}

/// Owns block-observer tokens and unregisters them with its own lifetime.
@MainActor
public final class AppEventObservations {
    private let storage: AppEventObservationStorage

    public init(center: NotificationCenter = .default) {
        storage = AppEventObservationStorage(center: center)
    }

    public func observe<Event: AppEvent>(
        _ type: Event.Type,
        using handler: @escaping @MainActor @Sendable (Event) -> Void
    ) {
        storage.tokens.append(storage.center.observe(type, using: handler))
    }

    /// A notification AppKit posts, which carries no `AppEvent` value of ours. Same main-queue
    /// delivery and the same lifetime, so an observer of a platform preference is torn down with
    /// the view that cared about it rather than through a hand-held token.
    public func observe(
        _ name: Notification.Name,
        object: Any? = nil,
        using handler: @escaping @MainActor @Sendable () -> Void
    ) {
        let token = storage.center.addObserver(forName: name, object: object, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
        storage.tokens.append(token)
    }

    /// Ends one presentation generation while leaving the owner reusable for the next. Popovers
    /// and completion panels observe a particular window only while they are open.
    public func removeAll() {
        storage.removeAll()
    }
}

/// NotificationCenter's token protocol predates Sendable. Mutation is main-actor confined by
/// `AppEventObservations`; teardown may run from a nonisolated deinitializer, where the object
/// is uniquely owned and only removes its immutable snapshot of tokens.
private final class AppEventObservationStorage: @unchecked Sendable {
    let center: NotificationCenter
    var tokens: [NSObjectProtocol] = []

    init(center: NotificationCenter) {
        self.center = center
    }

    func removeAll() {
        let removed = tokens
        tokens.removeAll()
        removed.forEach(center.removeObserver)
    }

    deinit {
        tokens.forEach(center.removeObserver)
    }
}
