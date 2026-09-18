import Foundation

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
