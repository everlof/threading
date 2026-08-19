import Darwin
import Dispatch
import Foundation

/// One bounded read of whatever a descriptor already has.
///
/// This is separate from the stream that uses it because the obvious way to read a child is wrong
/// in a way that looks right. `FileHandle.read(upToCount:)` reads as "give me at most this much",
/// but Foundation treats the count as a length to **fill**: the call stays inside `read(2)` until
/// that many bytes arrive or the writer closes the pipe. A child that prints a few kilobytes and
/// then keeps running therefore delivers *nothing* — the reader blocks on its very first callback
/// and never returns.
///
/// That is not hypothetical. It is how the retired HTTPS relay came up, published its address,
/// served real traffic, and left the iPhone pairing card spinning on "Preparing your pairing code"
/// for the life of the app: it printed roughly 3 KB of banner, including the URL, and then went
/// quiet, so a 16 KB request never came back and the address was never parsed. Nothing timed out,
/// because a blocked read is not a failure. `tailscale serve` reads the same way, which is why
/// this outlived the transport it was written for.
///
/// `FileHandle.availableData` has the right blocking semantics and the wrong failure semantics: it
/// reports errors by raising an Objective-C exception Swift cannot catch. So does `fileDescriptor`
/// itself, on a handle closed underneath it. Trading a hang for a crash is not a fix, so this works
/// on the descriptor and returns an outcome.
enum ChildOutputReader {

    enum Outcome: Equatable {
        case read(Data)
        case endOfFile
        case wouldBlock
        case failed(errno: Int32)
    }

    static func read(
        descriptor: Int32,
        maximumBytes: Int = ChildOutputReaderDefaults.readChunkBytes
    ) -> Outcome {
        guard descriptor >= 0 else { return .failed(errno: EBADF) }
        var buffer = [UInt8](repeating: 0, count: max(1, maximumBytes))
        while true {
            let count = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(descriptor, raw.baseAddress, raw.count)
            }
            if count > 0 {
                return .read(Data(buffer[0..<count]))
            }
            if count == 0 {
                return .endOfFile
            }
            let code = errno
            switch code {
            case EINTR:
                // A signal arrived before anything was consumed. Ask again.
                continue
            case EAGAIN, EWOULDBLOCK:
                return .wouldBlock
            default:
                return .failed(errno: code)
            }
        }
    }
}

/// Delivers a running child's pipe output burst by burst, and owns the descriptor's lifetime.
///
/// The ownership is the point, and it is why this is a dispatch source rather than
/// `FileHandle.readabilityHandler`. Clearing that handler cancels its source *asynchronously*, so
/// a caller that then closes the handle can be closing it while the reader is inside a callback —
/// which either crashes on `fileDescriptor` or, if the caller kept the raw descriptor instead,
/// reads whatever unrelated file the kernel has since given that number to. GCD's cancel handler
/// is the guarantee neither of those has: it runs after the event handler has finished and can
/// never run twice, so closing there is closing exactly once, with nobody reading.
///
/// The descriptor is also made non-blocking. A read source can wake spuriously, and a blocking
/// `read(2)` on a quiet child would park the reader with no way to end it.
final class ChildOutputStream: @unchecked Sendable {

    private let source: DispatchSourceRead
    private let cancelled = NSLock()
    private var isCancelled = false

    /// - Parameters:
    ///   - readEnd: an open descriptor whose ownership transfers here. It is closed exactly once,
    ///     when this stream ends, and must not be closed by the caller.
    ///   - receive: called with each burst, on this stream's own queue. It must not block: the
    ///     descriptor stays unread until it returns.
    init(readEnd descriptor: Int32, receive: @escaping @Sendable (Data) -> Void) {
        let flags = fcntl(descriptor, F_GETFL)
        if flags >= 0 {
            _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        }
        let queue = DispatchQueue(label: ChildOutputReaderDefaults.queueLabel, qos: .utility)
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setCancelHandler {
            Darwin.close(descriptor)
        }
        source.setEventHandler { [weak self] in
            guard let self else { return }
            switch ChildOutputReader.read(descriptor: descriptor) {
            case .read(let data):
                receive(data)
            case .wouldBlock:
                // Nothing to hand over and nothing wrong: stay armed.
                return
            case .endOfFile:
                self.cancel()
            case .failed(let code):
                ThreadingLogger.agent.error(
                    "Child output read failed errno=\(code, privacy: .public)"
                )
                self.cancel()
            }
        }
        source.resume()
    }

    deinit {
        cancel()
    }

    /// Ends delivery and closes the descriptor. Safe to call more than once, and from any thread.
    func cancel() {
        cancelled.lock()
        let alreadyCancelled = isCancelled
        isCancelled = true
        cancelled.unlock()
        guard !alreadyCancelled else { return }
        source.cancel()
    }
}

enum ChildOutputReaderDefaults {
    static let readChunkBytes = 16 * 1024
    static let queueLabel = "codes.threading.child-output"
}
