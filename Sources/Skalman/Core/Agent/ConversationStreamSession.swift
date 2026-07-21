import Foundation

/// The transport behind Skalman's native conversation surface.
///
/// Claude and Codex expose different process lifecycles — Claude keeps one JSON stream open,
/// while `codex exec --json` runs one turn per process — but the view only needs this common
/// conversation-shaped surface.
protocol ConversationStreamSession: AnyObject {
    var onEvent: ((StreamEvent) -> Void)? { get set }
    var onExit: ((Int32) -> Void)? { get set }

    /// Whether the logical conversation is open, not merely whether a turn subprocess exists.
    var isRunning: Bool { get }
    var canSend: Bool { get }

    func start()

    /// Sends a turn, returning false when the transport cannot accept one yet.
    @discardableResult
    func send(_ text: String) -> Bool

    func finish()
    func terminate()
}
