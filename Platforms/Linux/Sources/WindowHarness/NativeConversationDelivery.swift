#if os(Linux)
import AppKit
@testable import CoreSlice

/// The eight-runtime workspace shares a 64-slot UI mailbox. Transport reads and deadline
/// workers wait for receipts; launch/permission callbacks defer without blocking the UI owner.
enum NativeConversationDelivery {
    static let callbacks = ConversationCallbackDelivery(
        enqueue: { operation in
            if !NSWindowWorkerDelivery.shared.enqueue(operation) {
                NSWindowWorkerDelivery.shared.deliver(operation)
            }
        },
        receive: { NSWindowWorkerDelivery.shared.deliver($0) })
}
#endif
