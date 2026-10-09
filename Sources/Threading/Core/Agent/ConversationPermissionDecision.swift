import Foundation

/// Native transports ask their host's decision boundary. The Mac uses its complete broker;
/// a portable host supplies its presenter/policy and remains fail-closed until it does.
@MainActor
enum ConversationPermissionDecision {
#if os(Linux)
    static var decide: (PermissionRequest, @escaping @MainActor @Sendable (PermissionDecision) -> Void) -> Void = { _, completion in
        completion(.deny(reason: "Threading has no window available to ask for permission."))
    }
#else
    static func decide(_ request: PermissionRequest, completion: @escaping @MainActor @Sendable (PermissionDecision) -> Void) {
        PermissionBroker.decide(request, completion: completion)
    }
#endif
}
