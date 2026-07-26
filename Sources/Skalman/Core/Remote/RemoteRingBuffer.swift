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
/// A pure value type with no I/O, so wrap-around and truncation are unit-tested directly.
struct RemoteRingBuffer {

    private var storage: [UInt8]
    private let capacity: Int
    /// The index the next byte is written to; also the oldest byte's index once full.
    private var head = 0
    private var filled = 0

    init(capacity: Int) {
        precondition(capacity > 0, "A ring buffer needs a positive capacity")
        self.capacity = capacity
        self.storage = [UInt8](repeating: 0, count: capacity)
    }

    var count: Int { filled }
    var isEmpty: Bool { filled == 0 }

    mutating func append(_ data: Data) {
        guard !data.isEmpty else { return }
        let incoming = [UInt8](data)
        let total = incoming.count

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
    func snapshot() -> Data {
        guard filled > 0 else { return Data() }
        let start = (head - filled + capacity) % capacity
        var out = [UInt8]()
        out.reserveCapacity(filled)
        for offset in 0..<filled { out.append(storage[(start + offset) % capacity]) }
        return Data(out)
    }
}
