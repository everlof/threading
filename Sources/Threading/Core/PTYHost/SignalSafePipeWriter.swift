#if os(Linux)
import CNativeAgentProcess
import Dispatch
import Foundation
import Glibc

/// The hosted transport's bounded output reservation owns admission. This writer owns one
/// nonblocking pipe, per-write SIGPIPE suppression, partial progress and eventual close.
/// Mutable state belongs to its serial queue; pending packets release their bytes immediately.
final class SignalSafePipeWriter: @unchecked Sendable {
    private struct Packet {
        let bytes: Data
        var offset = 0
        let completed: @Sendable () -> Void
    }
    private let descriptor: Int32
    private let queue = DispatchQueue(label: "codes.threading.pipe-write", qos: .userInitiated)
    private let source: DispatchSourceWrite
    private var resumed = false
    private var closed = false
    private var closing = false
    private var packets: [Packet?] = []
    private var head = 0
    private var drainRetainer: SignalSafePipeWriter?

    /// Takes ownership even on failure, so a caller cannot close a recycled descriptor.
    init(descriptor: Int32) throws {
        self.descriptor = descriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            let code = errno
            _ = Glibc.close(descriptor)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        source = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { _ = Glibc.close(descriptor) }
    }

    func write(_ bytes: Data, completed: @escaping @Sendable () -> Void) {
        queue.async {
            guard !self.closed, !self.closing, !bytes.isEmpty else { completed(); return }
            self.packets.append(Packet(bytes: bytes, completed: completed))
            self.drain()
        }
    }

    func close(immediately: Bool) {
        queue.async {
            guard !self.closed else { return }
            self.closing = true
            if immediately || self.head == self.packets.count { self.finishClose(); return }
            self.drainRetainer = self
            // A peer that never reads must not retain a pipe forever after the child ended.
            self.queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.finishClose() }
            self.drain()
        }
    }

    private func drain() {
        guard !closed else { return }
        while head < packets.count {
            guard var packet = packets[head] else { head += 1; continue }
            var written: Int32 = 0
            let code = packet.bytes.withUnsafeBytes {
                threading_pipe_write_some_no_signal(descriptor,
                    $0.baseAddress?.assumingMemoryBound(to: UInt8.self).advanced(by: packet.offset),
                    Int32(min($0.count - packet.offset, Int(Int32.max))), &written)
            }
            if code == EAGAIN || code == EWOULDBLOCK {
                if !resumed { resumed = true; source.resume() }
                return
            }
            guard code == 0, written > 0 else { finishClose(); return }
            packet.offset += Int(written)
            if packet.offset == packet.bytes.count {
                packets[head] = nil
                head += 1
                packet.completed()
            } else { packets[head] = packet }
        }
        packets.removeAll(keepingCapacity: true)
        head = 0
        if closing { finishClose(); return }
        if resumed { resumed = false; source.suspend() }
    }

    private func finishClose() {
        guard !closed else { return }
        closed = true
        for packet in packets[head...] { packet?.completed() }
        packets.removeAll()
        head = 0
        if !resumed { resumed = true; source.resume() }
        source.cancel()
        drainRetainer = nil
    }

    deinit {
        if !resumed { source.resume() }
        source.cancel()
    }
}
#endif
