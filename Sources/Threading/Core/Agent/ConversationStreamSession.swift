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

    /// Whether the transport will accept a change to *how* the next work is done — model,
    /// reasoning effort, service tier — right now.
    ///
    /// Deliberately not `canSend`, and deliberately not a fact about the runtime. The two
    /// existing answers differ in exactly this: a persistent control channel applies a change
    /// to the next model round-trip of a turn already in flight, so it stays open while the
    /// agent works, while a transport that carries configuration on the turn request itself
    /// needs that turn to have finished first.
    ///
    /// This was a `switch` over `AgentKind` in the conversation view, which meant a new
    /// transport inherited whichever branch its runtime happened to fall into. The default
    /// below is the honest answer for a transport that has not stated one: the chips are
    /// shown disabled rather than offering a change nothing will apply.
    var acceptsConfigurationChange: Bool { get }

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

/// A transport that can expose the provider's execution-bearing wire objects before its
/// conversation adapter flattens them for display.
///
/// This is deliberately separate from `onEvent`: the timeline wants provider-neutral rows,
/// while an audit wants the original tool name, arguments, result object, and lifecycle update.
@MainActor
protocol ProviderExecutionReportingConversation: AnyObject {
    var onProviderExecution: ((ProviderExecutionEvent) -> Void)? { get set }
}

/// A transport whose next turn reads a reasoning-effort choice without restarting.
///
/// The model catalog decides whether levels exist; this protocol answers the separate live-wire
/// question. Codex reads its configuration provider on every `turn/start`. Claude currently
/// accepts effort only at process launch, so its opening composer may offer the choice while its
/// reply composer does not promise a mid-session change the control channel cannot deliver.
@MainActor
protocol ReasoningEffortConfigurableConversation: AnyObject {}

extension ConversationStreamSession {
    var acceptsConfigurationChange: Bool { false }

    /// The shared context boundary. Providers continue to own only their text wire protocol;
    /// every reference and comment reaches Claude, Codex, and ACP in the same durable envelope.
    @discardableResult
    func send(_ prompt: ConversationPrompt) -> Bool {
        send(prompt.transportText)
    }
}

/// Optional provider-owned conversation metadata reported outside the transcript.
///
/// ACP exposes this as `session_info_update`; keeping it separate from the transport contract
/// lets providers that have no live title channel remain honest about that limitation.
@MainActor
protocol SessionTitleReportingConversation: AnyObject {
    var onSessionTitleChange: ((String) -> Void)? { get set }
}
