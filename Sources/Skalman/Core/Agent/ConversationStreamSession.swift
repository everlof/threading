import Foundation

/// The transport behind Skalman's native conversation surface.
///
/// Claude and Codex expose different process lifecycles — Claude keeps one JSON stream open,
/// while `codex exec --json` runs one turn per process — but the view only needs this common
/// conversation-shaped surface.
protocol ConversationStreamSession: AnyObject {
    var onEvent: ((StreamEvent) -> Void)? { get set }
    var onExit: ((Int32) -> Void)? { get set }

    /// Fired whenever `canSend` may have changed without a stream event carrying that fact.
    ///
    /// In particular, Codex emits `turn.completed` before its one-shot child exits. The child
    /// exit — not that event — is the point at which another `exec resume` may be launched.
    var onSendAvailabilityChange: (() -> Void)? { get set }

    /// Whether the logical conversation is open, not merely whether a turn subprocess exists.
    var isRunning: Bool { get }
    var canSend: Bool { get }

    /// The live transport process, when one exists — the root of the tree the info panel walks
    /// to find what a natively rendered session is running.
    ///
    /// This is the *subprocess*, so it is deliberately not `isRunning`: Claude keeps one process
    /// open for the whole conversation and reports it throughout, while `codex exec` spawns one
    /// per turn and reports nil between them, because between turns there is genuinely no
    /// process to describe.
    var rootProcessIdentifier: pid_t? { get }

    func start()

    /// Sends a turn, returning false when the transport cannot accept one yet.
    @discardableResult
    func send(_ text: String) -> Bool

    func finish()
    func terminate()
}
