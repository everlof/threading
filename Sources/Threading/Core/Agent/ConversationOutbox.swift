import Foundation

/// The messages a user has written while the agent was busy, in the order they will be sent.
///
/// **Threading owns this queue even where the provider has one.** Claude's CLI keeps a command
/// queue of its own and will remove an entry by uuid, and it is still the wrong place to keep
/// the user's list:
///
/// - **Reorder and edit need it here.** A provider queue can be appended to and removed from;
///   none of them can be reordered, and none can be edited. Implementing a drag as
///   cancel-everything-and-resend races with delivery on every gesture.
/// - **Two of the three providers have no queue at all.** Codex and ACP hold nothing between
///   turns. One shared model or three divergent ones, and this repository has already made that
///   choice for context attachments and for tool identity.
/// - **It has to cross RemoteKit.** The iOS mirror and the browser snapshot show the
///   conversation; a queue living inside `ClaudeStreamSession` is invisible to both.
///
/// The provider's queue is therefore used only as the *delivery* mechanism at flush time, and
/// `MessageLifecycleReportingConversation` is the receipt that a flushed item was accepted — not
/// the queue itself.
///
/// A pure value type with no transport, no view and no clock of its own, so every ordering rule
/// below is directly testable.
struct ConversationOutbox: Equatable, Sendable {

    // MARK: - Item

    /// One message waiting its turn.
    struct Item: Equatable, Sendable, Identifiable {

        /// Who put this in the queue.
        ///
        /// Everything here is the user's until a curfew has something to say. A curfew's
        /// wrap-up is the one item a held outbox still hands over: the hold is there to stop
        /// the session spending itself, and this message is what buys back the single turn an
        /// interrupted agent needs to commit what is safe and write its handoff note. Draining
        /// anything else while held would be the hold not holding.
        ///
        /// Carried on the item rather than kept in a queue beside this one, because order is
        /// what this type is for: a wrap-up in a separate lane could not be reordered, edited or
        /// removed like the row the user sees, and would arrive out of the sequence they wrote.
        enum Origin: Equatable, Sendable {
            case user
            case curfewWindDown
        }

        let id: ConversationMessageID
        var prompt: ConversationPrompt
        var state: MessageLifecycleState
        var origin: Origin = .user

        /// What the row shows. Empty prose with staged context still reads as something, because
        /// `ConversationPrompt.visibleText` supplies the sentence a person would have typed.
        var summary: String { prompt.visibleText }
    }

    // MARK: - Storage

    private(set) var items: [Item] = []

    init() {}

    // MARK: - Reading

    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }

    /// The items the user can still act on. Anything handed to a transport is history as far as
    /// the queue's own gestures are concerned.
    var pending: [Item] { items.filter { $0.state.isPending } }

    /// Whether another message may be written. A refusal is stated rather than silently dropping
    /// the oldest: a queue that quietly forgets what somebody typed is worse than one that says
    /// it is full.
    var acceptsMore: Bool { count < ConversationOutboxDefaults.maximumItems }

    subscript(id: ConversationMessageID) -> Item? {
        items.first { $0.id == id }
    }

    func index(of id: ConversationMessageID) -> Int? {
        items.firstIndex { $0.id == id }
    }

    // MARK: - Writing

    /// Adds a message to the end of the queue, answering with its identity.
    ///
    /// Nil means the queue is full. Empty prompts are refused here rather than at the composer,
    /// so no caller can put an unsendable row in front of the user.
    ///
    /// `origin` defaults to the user because that is who almost always typed it; the drain reads
    /// it back off the item to decide what a held session may still hand over.
    @discardableResult
    mutating func append(
        _ prompt: ConversationPrompt,
        origin: Item.Origin = .user
    ) -> ConversationMessageID? {
        guard acceptsMore, !prompt.isEmpty else { return nil }
        let id = ConversationMessageID()
        items.append(Item(id: id, prompt: prompt, state: .queued, origin: origin))
        return id
    }

    /// Removes a message the user has not yet handed over.
    ///
    /// Deliberately refuses anything past `.queued`. A row the transport already has is not the
    /// outbox's to withdraw, and offering removal for it would be the queue claiming a power it
    /// does not have — cancelling a message a provider is already working on is `interrupt`.
    @discardableResult
    mutating func remove(_ id: ConversationMessageID) -> Bool {
        guard let index = index(of: id), items[index].state.isPending else { return false }
        items.remove(at: index)
        return true
    }

    /// Rewrites a pending message in place, keeping its identity and its position.
    @discardableResult
    mutating func replace(_ id: ConversationMessageID, with prompt: ConversationPrompt) -> Bool {
        guard let index = index(of: id), items[index].state.isPending else { return false }
        guard !prompt.isEmpty else { return remove(id) }
        items[index].prompt = prompt
        return true
    }

    /// Moves a pending message to a new position among the pending ones.
    ///
    /// Stated in terms of `pending` indices rather than storage indices, because that is what the
    /// user is dragging: rows already handed over are drawn as history and cannot be jumped over
    /// or landed on. A destination past the end clamps rather than throwing — a drag released
    /// below the last row means "last", not "error".
    @discardableResult
    mutating func movePending(from source: Int, to destination: Int) -> Bool {
        let pendingIndices = items.indices.filter { items[$0].state.isPending }
        guard pendingIndices.indices.contains(source) else { return false }

        let clamped = max(0, min(destination, pendingIndices.count - 1))
        guard clamped != source else { return false }

        let moved = items.remove(at: pendingIndices[source])
        // Recomputed after the removal: every pending index at or past the source has shifted
        // down by one, and reusing the stale list is how a drag lands one row off.
        let afterRemoval = items.indices.filter { items[$0].state.isPending }
        let insertion = clamped < afterRemoval.count
            ? afterRemoval[clamped]
            : (afterRemoval.last.map { $0 + 1 } ?? items.count)
        items.insert(moved, at: insertion)
        return true
    }

    /// Takes the next message to send, marking it handed over.
    ///
    /// One at a time, never concatenated. Two messages somebody wrote separately are two turns,
    /// and merging them is a decision the user did not make.
    mutating func handOverNext() -> Item? {
        guard let index = items.firstIndex(where: { $0.state.isPending }) else { return nil }
        items[index].state = .handedOver
        return items[index]
    }

    /// Records what a transport says became of a message.
    ///
    /// Settled items leave the queue: the conversation itself is the record of a message that was
    /// worked on, and leaving a completed row under the composer would be a second copy of it.
    mutating func mark(_ id: ConversationMessageID, as state: MessageLifecycleState) {
        guard let index = index(of: id) else { return }
        if state.isSettled {
            items.remove(at: index)
        } else {
            items[index].state = state
        }
    }

    /// Puts a handed-over message back at the front of the queue.
    ///
    /// The transport refused it, or an interrupt cancelled the provider's copy before it ran. It
    /// returns to `.queued` because it is the user's again: editable, movable, removable.
    mutating func reclaim(_ id: ConversationMessageID) {
        guard let index = index(of: id), !items[index].state.isPending else { return }
        var item = items.remove(at: index)
        item.state = .queued
        let insertion = items.firstIndex { $0.state.isPending } ?? items.count
        items.insert(item, at: insertion)
    }

    /// Empties the queue, answering with what was thrown away so the caller can say so.
    @discardableResult
    mutating func removeAll() -> [Item] {
        defer { items.removeAll() }
        return items
    }
}

// MARK: - Defaults

enum ConversationOutboxDefaults {
    /// How many messages may wait at once.
    ///
    /// A ceiling rather than a target. Past a screenful the list stops being something a person
    /// reads before it sends and becomes a script they have lost track of — and the failure mode
    /// of an unbounded queue is a stuck agent quietly accumulating an afternoon of instructions
    /// that all fire at once when it wakes.
    static let maximumItems = 20
}

// MARK: - Prompt Emptiness

extension ConversationPrompt {
    /// Whether there is nothing here to send. Context alone is not empty: a staged reference with
    /// no prose still becomes a readable instruction through `visibleText`.
    var isEmpty: Bool { text.isEmpty && context.isEmpty }
}
