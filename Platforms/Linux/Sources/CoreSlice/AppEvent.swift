import Foundation
#if os(Linux)
import Dispatch
#endif

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
        addObserver(forName: Event.name, object: nil, queue: AppEventDelivery.observerQueue) { notification in
            guard let event = notification.object as? Event else { return }
            AppEventDelivery.deliver {
                handler(event)
            }
        }
    }
}

/// Owns block-observer tokens and unregisters them with its own lifetime.
@MainActor
public final class AppEventObservations {
    private let storage: AppEventObservationStorage
    private var generation: UInt64 = 0

    public init(center: NotificationCenter = .default) {
        storage = AppEventObservationStorage(center: center)
    }

    public func observe<Event: AppEvent>(
        _ type: Event.Type,
        using handler: @escaping @MainActor @Sendable (Event) -> Void
    ) {
        let observedGeneration = generation
        storage.tokens.append(storage.center.observe(type) { [weak self] event in
            guard let self, generation == observedGeneration else { return }
            handler(event)
        })
    }

    /// A notification AppKit posts, which carries no `AppEvent` value of ours. Same main-queue
    /// delivery and the same lifetime, so an observer of a platform preference is torn down with
    /// the view that cared about it rather than through a hand-held token.
    public func observe(
        _ name: Notification.Name,
        object: Any? = nil,
        using handler: @escaping @MainActor @Sendable () -> Void
    ) {
        let observedGeneration = generation
        let token = storage.center.addObserver(forName: name, object: object,
                                               queue: AppEventDelivery.observerQueue) { [weak self] _ in
            AppEventDelivery.deliver { [weak self] in
                guard let self, generation == observedGeneration else { return }
                handler()
            }
        }
        storage.tokens.append(token)
    }

    /// Ends one presentation generation while leaving the owner reusable for the next. Popovers
    /// and completion panels observe a particular window only while they are open.
    public func removeAll() {
        generation += 1
        storage.removeAll()
    }
}

private enum AppEventDelivery {
    #if os(Linux)
    // Corelibs OperationQueue.main can wait for an operation while the Linux main actor is
    // already occupying its dispatch executor. Observe inline, then cross to that executor.
    static let observerQueue: OperationQueue? = nil
    private static let mainQueue = MainQueueIdentity()

    static func deliver(_ handler: @escaping @MainActor @Sendable () -> Void) {
        if mainQueue.isCurrent {
            MainActor.assumeIsolated { handler() }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { handler() } }
        }
    }

    // The key is immutable and Dispatch owns its synchronized association with the main queue.
    private final class MainQueueIdentity: @unchecked Sendable {
        private let key = DispatchSpecificKey<Bool>()
        init() { DispatchQueue.main.setSpecific(key: key, value: true) }
        var isCurrent: Bool { DispatchQueue.getSpecific(key: key) == true }
    }
    #else
    static let observerQueue: OperationQueue? = .main
    static func deliver(_ handler: @escaping @MainActor @Sendable () -> Void) {
        MainActor.assumeIsolated { handler() }
    }
    #endif
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
