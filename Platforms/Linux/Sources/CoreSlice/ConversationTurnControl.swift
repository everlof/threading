import Foundation

/// Controlling a turn that is already running: stopping it, adding to it, and following the fate
/// of one submitted message.
///
/// These are three *separate* optional protocols beside `ConversationStreamSession`, in the same
/// style as `ModelSwitchableConversation` and `SubagentReportingConversation`, because the three
/// providers Threading renders natively support different subsets of them and the difference is
/// not a hierarchy:
///
/// | | Stop | Steer | Lifecycle |
/// |---|---|---|---|
/// | Claude `stream-json` | `control_request` `interrupt` | at the next model boundary | `command_lifecycle` keyed by our `uuid` |
/// | Codex app-server | `turn/interrupt` | `turn/steer` + `expectedTurnId` | `clientUserMessageId` |
/// | Grok / ACP | `session/cancel` | — | — |
///
/// A transport conforming to none of them still gets a working composer: the conversation queues
/// locally, sends on settle, and simply draws no Stop and offers no steer. Nothing here is
/// allowed to become a `switch` over `AgentKind` at a call site — the whole point of the split is
/// that the *view* asks "can you do this", never "who are you".

// MARK: - Message Identity

/// A message Threading has minted an identifier for, so its fate can be followed after it leaves.
///
/// Threading mints these rather than adopting a provider's, because the queue exists before any
/// provider has seen the message: an item can be written, reordered, edited and removed without a
/// transport ever being told it exists. Providers that have message identity of their own are
/// handed this value to echo back (Claude's `uuid`, Codex's `clientUserMessageId`); providers
/// that do not simply never mention it.
struct ConversationMessageID: Hashable, Sendable, Codable, CustomStringConvertible {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    init?(uuidString: String) {
        guard let value = UUID(uuidString: uuidString) else { return nil }
        self.rawValue = value
    }

    /// The spelling handed to a provider and matched when it echoes back.
    var wireValue: String { rawValue.uuidString }
    var description: String { wireValue }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Where one submitted message has got to.
///
/// Deliberately the *provider's* answer rather than Threading's assumption. A queue that infers
/// "it must have started, an assistant block arrived" is wrong exactly when it matters: two
/// messages handed over together, a steer landing inside a turn another message opened, or a
/// provider that reorders. Transports that cannot report this leave the outbox's own
/// `.handedOver` standing, which claims nothing more than it knows.
enum MessageLifecycleState: Equatable, Sendable {
    /// Written by the user and held by Threading. Reorderable, editable, removable.
    case queued

    /// Given to the transport. No longer ours to reorder, and not yet known to have begun.
    case handedOver

    /// The provider says this message is being worked on.
    case started

    /// The provider says this message is done with.
    case completed

    /// Dropped before it was worked on, by the user or by an interrupt that cancelled the
    /// provider's queue.
    case cancelled

    /// Whether the outbox still owns this item — the only state in which reordering, editing and
    /// plain removal are honest offers.
    var isPending: Bool { self == .queued }

    /// Whether the item has reached its end, either way.
    var isSettled: Bool { self == .completed || self == .cancelled }
}

// MARK: - Interrupting

/// What a provider said when asked to stop.
///
/// Two cases rather than an array plus a "did it answer" flag, because the difference is real and
/// a caller must not read an empty list as "nothing survived". Claude advertises
/// `interrupt_receipt_v1` on `system/init` and answers with `still_queued`; the same CLI a version
/// earlier answers success and names nothing, and ACP's `session/cancel` is a notification that
/// answers nothing at all. This is the same "one value, not a flag beside an optional" rule
/// `ComposerCapability.Availability` follows.
enum InterruptReceipt: Equatable, Sendable {
    /// The provider named which of the messages we had handed it are still waiting.
    case reported(stillQueued: [ConversationMessageID])

    /// The provider stopped, and said nothing about anything queued behind the turn.
    case acknowledged

    /// The provider refused or could not be reached. The turn may still be running.
    case failed(reason: String)

    /// Whether the stop is believed to have taken effect.
    var didStop: Bool {
        if case .failed = self { return false }
        return true
    }
}

/// A transport that can abort the turn in flight without ending the conversation.
///
/// The distinction from `terminate()` is the whole point: Stop leaves the process alive and the
/// thread resumable. Measured against Claude 2.1.223, the CLI answers an interrupt in ~10ms,
/// settles the turn, and re-emits `system/init` for the next one.
@MainActor
protocol InterruptibleConversation: AnyObject {
    /// Whether there is something to stop *right now*. Deliberately not the inverse of `canSend`:
    /// a transport can be mid-handshake, which is neither sendable nor interruptible.
    var canInterrupt: Bool { get }

    /// Stops the running turn and everything it started.
    ///
    /// Implementations own the "stop the fleet, not just the parent" rule: an interrupt that ends
    /// only the parent turn leaves background subagents and shells running, and burning tokens,
    /// which is precisely the situation Stop is reached for. Children are stopped first,
    /// best-effort and individually bounded, so one wedged child cannot delay the parent.
    ///
    /// The completion fires once, on the main queue, whatever happens.
    func interrupt(completion: @escaping @MainActor (InterruptReceipt) -> Void)
}

// MARK: - Steering

/// Why a transport will not accept a steer right now.
enum SteerRefusal: Equatable, Sendable {
    /// This transport has no steering primitive at all.
    case unsupported

    /// Nothing is running to steer.
    case noActiveTurn

    /// The turn in flight is not of a kind that accepts additions — Codex refuses `review` and
    /// `compact` turns by name.
    case turnKindRefusesSteering
}

/// Whether a steer may be offered, and if not, why.
enum SteerAvailability: Equatable, Sendable {
    case available
    case unavailable(SteerRefusal)

    var isAvailable: Bool { self == .available }
}

/// A transport that can append user input to the turn already running.
///
/// **Steering is not "queueing, but sooner."** A steered message joins the running turn: it
/// shares that turn's context and tool results, settles under the same terminal event, and never
/// becomes a turn of its own. Measured against Claude 2.1.223, a message written mid-turn goes
/// `queued` → `started` at the instant the next tool result lands, and its instruction is honoured
/// inside the same turn.
///
/// One constraint is worth restating wherever this is used: on Claude the steered text arrives
/// through the **function-results channel**, which the model is trained to distrust. Additive
/// instruction lands; override-shaped phrasing is classified as a prompt-injection attempt and
/// discarded. Steer is not an override channel, and a user who wants to countermand the running
/// turn wants `InterruptibleConversation` instead.
@MainActor
protocol SteerableConversation: AnyObject {
    /// Whether the turn in flight will take an addition, and why not when it will not.
    var steerAvailability: SteerAvailability { get }

    /// Adds `prompt` to the running turn. False means the transport declined, in which case the
    /// caller's fallback is to queue the message rather than to retry — the two refusals that
    /// matter (no active turn, non-steerable turn kind) are both answered by waiting.
    @discardableResult
    func steer(_ prompt: ConversationPrompt, identifiedBy id: ConversationMessageID) -> Bool
}

// MARK: - Message Lifecycle

/// A transport that can carry a client-minted identifier with a turn and report that exact
/// message's progress back.
///
/// Without this a queue has to guess, and the guess is wrong in the cases that matter. With it,
/// each flushed row states what the provider says about it and nothing more.
@MainActor
protocol MessageLifecycleReportingConversation: AnyObject {
    var onMessageLifecycle: ((ConversationMessageID, MessageLifecycleState) -> Void)? { get set }

    /// Sends a turn under an identifier the caller chose.
    @discardableResult
    func send(_ prompt: ConversationPrompt, identifiedBy id: ConversationMessageID) -> Bool
}

// MARK: - One Surface For Every Transport

extension ConversationStreamSession {
    /// The composer's whole question about stopping, answered the same way for every provider.
    var canInterrupt: Bool {
        (self as? InterruptibleConversation)?.canInterrupt ?? false
    }

    /// The composer's whole question about steering. A transport that cannot steer answers
    /// `.unavailable(.unsupported)` rather than `false`, so the reason can be said out loud
    /// instead of the affordance silently doing something else — the "Chat… button that did
    /// nothing" failure this codebase has already fixed once.
    var steerAvailability: SteerAvailability {
        (self as? SteerableConversation)?.steerAvailability ?? .unavailable(.unsupported)
    }

    /// Stops the running turn, answering `.failed` for a transport that cannot.
    func interrupt(completion: @escaping @MainActor (InterruptReceipt) -> Void) {
        guard let interruptible = self as? InterruptibleConversation else {
            completion(.failed(reason: L10n.string("This agent cannot stop a turn in progress.")))
            return
        }
        interruptible.interrupt(completion: completion)
    }

    /// Adds to the running turn where the transport allows it.
    @discardableResult
    func steer(_ prompt: ConversationPrompt, identifiedBy id: ConversationMessageID) -> Bool {
        guard let steerable = self as? SteerableConversation,
              steerable.steerAvailability.isAvailable else { return false }
        return steerable.steer(prompt, identifiedBy: id)
    }

    /// Sends under an identifier, which is carried by providers that have message identity of
    /// their own and dropped by those that do not.
    ///
    /// One call site for every transport. The cast lives here rather than in the conversation so
    /// that adding a fourth provider changes this file and nothing in the view.
    @discardableResult
    func send(_ prompt: ConversationPrompt, identifiedBy id: ConversationMessageID) -> Bool {
        guard let reporting = self as? MessageLifecycleReportingConversation else {
            return send(prompt)
        }
        return reporting.send(prompt, identifiedBy: id)
    }

    /// Whether this transport reports what became of a message it was handed.
    var reportsMessageLifecycle: Bool {
        self is MessageLifecycleReportingConversation
    }
}
