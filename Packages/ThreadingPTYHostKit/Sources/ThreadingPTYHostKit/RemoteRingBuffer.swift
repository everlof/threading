import Foundation

/// A fixed-size ring of the most recent raw PTY bytes, replayed verbatim into a joining remote
/// client so it sees roughly the current screen.
///
/// Replaying the raw byte stream is the only representation guaranteed to reproduce what
/// SwiftTerm itself rendered — `Terminal.getBufferAsData` is plain text with no SGR, cursor or
/// alt-screen state. The one accepted cost is that a join can land mid escape-sequence and
/// garble the first paint; the ring is sized to hold a full TUI repaint so a well-behaved app
/// repaints past it, and the client offers a reconnect.
///
/// Everything in the ring must therefore be real terminal output. A session that was already
/// running when capture began has no raw bytes to replay, so it is seeded with a synthesised
/// repaint from `RemoteScreenSeed` — never with `getBufferAsData`, whose bare line feeds and
/// NUL-filled blank cells drew the browser a staircase of run-together words.
///
/// A pure value type with no I/O, so wrap-around and truncation are unit-tested directly. It
/// lives in `ThreadingPTYHostKit` rather than beside the remote mirror because the PTY host
/// keeps the same ring for the same reason and must not link the app; the mirror goes on using
/// it through the package, unchanged.
public struct RemoteRingBuffer: Sendable {

    private var storage: [UInt8]
    private let capacity: Int
    /// The index the next byte is written to; also the oldest byte's index once full.
    private var head = 0
    private var filled = 0

    /// Every byte ever appended, including the ones since overwritten. Monotonic and never
    /// reset.
    ///
    /// This one counter is what makes an exact rejoin possible. A watcher records it when it
    /// leaves and sends it back when it returns; the difference is precisely how far behind it
    /// is, so the host can answer "here are the bytes you missed" instead of "here is a tail,
    /// work out the rest". `UInt64` at a terminal's byte rate does not wrap in any life a
    /// machine will have.
    public private(set) var totalBytesWritten: UInt64 = 0

    public init(capacity: Int) {
        precondition(capacity > 0, "A ring buffer needs a positive capacity")
        self.capacity = capacity
        self.storage = [UInt8](repeating: 0, count: capacity)
    }

    public var count: Int { filled }
    public var isEmpty: Bool { filled == 0 }

    public mutating func append(_ data: Data) {
        guard !data.isEmpty else { return }
        let incoming = [UInt8](data)
        let total = incoming.count
        totalBytesWritten &+= UInt64(total)

        // A single write larger than the ring keeps only its own tail; the prior contents are
        // entirely overwritten, so there is no point walking them.
        if total >= capacity {
            let tailStart = total - capacity
            for index in 0..<capacity { storage[index] = incoming[tailStart + index] }
            head = 0
            filled = capacity
            return
        }

        for byte in incoming {
            storage[head] = byte
            head = (head + 1) % capacity
        }
        filled = min(filled + total, capacity)
    }

    /// The buffered bytes, oldest first — what a joining client is sent before live output.
    public func snapshot() -> Data {
        guard filled > 0 else { return Data() }
        return tail(filled)
    }

    /// Exactly the bytes written since `offset`, or nil when the ring can no longer prove it
    /// holds them all.
    ///
    /// The refusal is the point. A rejoining watcher is owed either *every* byte it missed or an
    /// explicit cut — a partial answer that looks complete is a screen the watcher believes and
    /// nobody can reproduce. So this answers only when `totalBytesWritten - offset` still fits
    /// inside the ring, and the caller falls back to `CAN` plus a tail when it does not.
    ///
    /// An offset ahead of `totalBytesWritten` is likewise nil rather than clamped: it means the
    /// watcher and the ring disagree about history, and guessing which is right is how a replay
    /// silently rotates.
    ///
    /// O(bytes returned), not O(ring).
    public func snapshot(from offset: UInt64) -> Data? {
        guard offset <= totalBytesWritten else { return nil }
        let behind = totalBytesWritten - offset
        guard behind <= UInt64(filled) else { return nil }
        guard behind > 0 else { return Data() }
        return tail(Int(behind))
    }

    /// The newest `length` bytes, oldest first. `length` is always `<= filled`.
    private func tail(_ length: Int) -> Data {
        let start = (head - length + capacity) % capacity
        var out = [UInt8]()
        out.reserveCapacity(length)
        for offset in 0..<length { out.append(storage[(start + offset) % capacity]) }
        return Data(out)
    }
}
