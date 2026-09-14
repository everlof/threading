import Foundation

/// Which shared-memory buffers the app still holds, so the helper only writes into a free one.
///
/// The helper `claim()`s a free buffer, copies the captured surface into it, and sends
/// `sharedFrameReady(bufferIndex:)`; the app answers `releaseSharedFrame(bufferIndex:)` once it has
/// presented that frame, which `release()`s the buffer back. With more than one buffer the helper
/// always has somewhere to write while the app reads the previous frame; when the app falls behind
/// and every buffer is in flight, `claim()` returns nil and that capture is simply dropped — the
/// same latest-frame-wins behaviour the codec path's frame window gives.
public struct SimulatorSharedFrameRing: Equatable, Sendable {
    public let bufferCount: Int
    private var inFlight: Set<UInt32>

    public init(bufferCount: Int) {
        precondition(bufferCount > 0, "A shared-frame ring needs at least one buffer.")
        self.bufferCount = bufferCount
        self.inFlight = []
    }

    public var freeCount: Int { bufferCount - inFlight.count }
    public var hasFreeBuffer: Bool { inFlight.count < bufferCount }
    public func isInFlight(_ index: UInt32) -> Bool { inFlight.contains(index) }

    /// Reserve the lowest free buffer to write the next frame into, or nil when the app still
    /// holds every buffer.
    public mutating func claim() -> UInt32? {
        for index in 0..<UInt32(bufferCount) where !inFlight.contains(index) {
            inFlight.insert(index)
            return index
        }
        return nil
    }

    /// The app released this buffer, or the helper is discarding a claim it never sent. Releasing
    /// a buffer that is already free is a no-op, so a duplicate or stale release cannot corrupt the
    /// free set.
    public mutating func release(_ index: UInt32) {
        inFlight.remove(index)
    }
}

public enum SimulatorSharedSurfaceNaming {
    /// A short, random name prefix sized for a real `shm_open` object. **Not yet used:** the
    /// current provider backs buffers with owner-only (`0600`) `mmap`ed temp files under a random
    /// per-stream directory and puts that path in the descriptor, so it confers no protection
    /// today. It is kept for the planned move to true POSIX shared memory / inherited descriptors,
    /// where the 64-bit nonce keeps the same-user object name unguessable for one stream's lifetime.
    /// Darwin caps shm names near 31 bytes; `"/tsim-" + 16 hex + "-"` is 23 characters, leaving room
    /// for the buffer index. Do not describe the shipping transport's security in terms of this.
    public static func randomNamePrefix() -> String {
        var generator = SystemRandomNumberGenerator()
        let nonce = UInt64.random(in: .min ... .max, using: &generator)
        return "/tsim-" + String(format: "%016llx", nonce) + "-"
    }
}
