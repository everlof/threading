import Foundation

/// What the conversation's status line says while a turn is in flight.
///
/// The word is drawn once, when the turn starts, and kept until the turn ends. That is the
/// whole rule: the status line is how a user knows the session is busy, so a label that
/// rewrote itself mid-turn would read as *something happened* when nothing had. A new turn
/// draws a new word, which is where the variety belongs — between turns, not within one.
///
/// This also settles an asymmetry between the two transports. The status used to be raised by
/// whatever each CLI happened to report: Claude streams reasoning deltas and so flipped to
/// "Thinking…" almost immediately, while `codex exec --json` emits reasoning only as a
/// finished block and so sat on "Working…" for the whole turn. The same wait was described
/// two different ways for no reason a user could see. A word chosen at submit is transport
/// independent by construction — neither CLI is asked.
enum WorkingWords {

    /// Twenty of them, so a working session does not repeat itself within a sitting.
    ///
    /// Each has to read as *busy* first and as fun second: this is the only thing on screen
    /// saying the turn has not stalled. Every one is a present participle or a gerund phrase
    /// for that reason — a noun or an adjective would describe a state rather than an activity.
    static let all: [String] = [
        "Thinking…",
        "Pondering…",
        "Ruminating…",
        "Cogitating…",
        "Mulling it over…",
        "Noodling…",
        "Percolating…",
        "Puzzling…",
        "Untangling…",
        "Deliberating…",
        "Scheming…",
        "Plotting…",
        "Tinkering…",
        "Whirring…",
        "Brewing…",
        "Chewing on it…",
        "Sharpening pencils…",
        "Connecting dots…",
        "Doing the reading…",
        "Consulting the oracle…"
    ]
}

/// Draws working words so that every one is used before any is used twice.
///
/// A plain random pick is the obvious implementation and is the wrong one: independent draws
/// repeat, and two identical words in consecutive turns read as the label having failed to
/// update rather than as chance. This is the shuffle-bag a game would use for the same
/// reason — shuffle the whole list, deal it out, reshuffle when it is empty.
///
/// The one seam between bags is handled explicitly: the last word of one bag can otherwise be
/// the first of the next, which is the exact repeat the bag exists to prevent.
struct WorkingWordCycle {

    // MARK: - Properties

    private let words: [String]

    /// Words not yet dealt from the current bag, in the order they will be dealt.
    private var remaining: [String] = []

    /// The word dealt most recently, kept only to keep it off the top of the next bag.
    private var lastDealt: String?

    // MARK: - Initialization

    init(words: [String] = WorkingWords.all) {
        // An empty list would make `next()` unanswerable, and the caller wants *a* word rather
        // than an optional it has no sensible way to render.
        self.words = words.isEmpty ? WorkingWords.all : words
    }

    // MARK: - Public Methods

    /// The next word, refilling and reshuffling when the bag runs out.
    mutating func next() -> String {
        if remaining.isEmpty { refill() }

        let word = remaining.removeLast()
        lastDealt = word
        return word
    }

    // MARK: - Private Methods

    private mutating func refill() {
        remaining = words.shuffled()

        // Words are dealt off the end, so the bag's first word is the array's last. With only
        // one word there is nothing to swap with and a repeat is not avoidable.
        guard let lastDealt, remaining.count > 1, remaining.last == lastDealt else { return }
        remaining.swapAt(remaining.count - 1, 0)
    }
}
