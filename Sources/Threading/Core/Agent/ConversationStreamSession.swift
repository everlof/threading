import Foundation

/// The transport behind Threading's native conversation surface.
///
/// Claude and Codex expose different wire protocols, but the view only needs this common
/// conversation-shaped surface. Provider capabilities that do not belong in the parent
/// transcript, such as child-agent reporting, are separate optional protocols.
@MainActor
protocol ConversationStreamSession: AnyObject {
    var onEvent: ((StreamEvent) -> Void)? { get set }
    var onExit: ((Int32) -> Void)? { get set }

    /// Fired whenever `canSend` may have changed without a stream event carrying that fact.
    ///
    /// A transport may finish establishing a thread, complete a turn, or lose its process
    /// without a parent transcript event carrying that state.
    var onSendAvailabilityChange: (() -> Void)? { get set }

    /// Whether the logical conversation is open, not merely whether a turn subprocess exists.
    var isRunning: Bool { get }
    var canSend: Bool { get }

    /// The live transport process, when one exists — the root of the tree the info panel walks
    /// to find what a natively rendered session is running.
    ///
    /// This is the *subprocess*, so it is deliberately not `isRunning`: logical session state
    /// and transport lifetime are related but are not the same fact.
    var rootProcessIdentifier: pid_t? { get }

    func start()

    /// Sends a turn, returning false when the transport cannot accept one yet.
    @discardableResult
    func send(_ text: String) -> Bool

    func finish()
    func terminate()
}
