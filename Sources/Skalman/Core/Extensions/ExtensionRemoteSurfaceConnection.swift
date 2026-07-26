import Darwin
import Foundation
import SkalmanExtensionKit

enum ExtensionRemoteSurfaceConnectionError: LocalizedError {
    case socketCreationFailed(Int32)
    case unexpectedMessage
    case alreadyStarted
    case frameBeforeAcknowledgement(String)
    case nonMonotonicSequence(String)
    case closed

    var errorDescription: String? {
        switch self {
        case .socketCreationFailed(let code):
            return "The remote-surface socket could not be created: "
                + String(cString: strerror(code))
        case .unexpectedMessage:
            return "The companion sent a host-owned remote-surface message."
        case .alreadyStarted:
            return "The companion remote-surface channel was started more than once."
        case .frameBeforeAcknowledgement(let presentationID):
            return "The companion sent another frame before presentation "
                + "\(presentationID) acknowledged the previous one."
        case .nonMonotonicSequence(let presentationID):
            return "The companion reused or reversed a frame sequence for presentation "
                + "\(presentationID)."
        case .closed:
            return "The companion closed its remote-surface channel."
        }
    }
}

/// Dedicated binary data plane for one companion generation.
///
/// The socket itself is the authority: only the supervised companion inherits its child end.
/// One unacknowledged frame per presentation makes backpressure explicit instead of letting
/// pixel buffers accumulate in the app.
final class ExtensionRemoteSurfaceConnection: @unchecked Sendable {
    static let childDescriptorNumber: Int32 = 3

    struct Pair {
        let connection: ExtensionRemoteSurfaceConnection
        let childDescriptor: Int32
    }

    typealias PacketHandler = (ExtensionRemoteSurfacePacket) -> Void

    private let handle: FileHandle
    private let readQueue = DispatchQueue(
        label: "se.mjukis.skalman.extension-remote-surface.read",
        qos: .userInitiated
    )
    private let writeQueue = DispatchQueue(
        label: "se.mjukis.skalman.extension-remote-surface.write",
        qos: .userInitiated
    )
    private let lock = NSLock()
    private var isClosed = false
    private var pendingAcknowledgements: Set<String> = []
    private var lastSequences: [String: UInt64] = [:]
    private var packetHandler: PacketHandler?
    private var failureHandler: ((Error) -> Void)?
    private var hasStarted = false

    private init(descriptor: Int32) {
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    static func makePair() throws -> Pair {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw ExtensionRemoteSurfaceConnectionError.socketCreationFailed(errno)
        }
        for descriptor in descriptors {
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
            var noSignal: Int32 = 1
            _ = setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSignal,
                socklen_t(MemoryLayout<Int32>.size)
            )
            var bufferBytes: Int32 = 512 * 1024
            _ = setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_SNDBUF,
                &bufferBytes,
                socklen_t(MemoryLayout<Int32>.size)
            )
            _ = setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_RCVBUF,
                &bufferBytes,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }
        return Pair(
            connection: ExtensionRemoteSurfaceConnection(descriptor: descriptors[0]),
            childDescriptor: descriptors[1]
        )
    }

    func start(
        onPacket: @escaping PacketHandler,
        onFailure: @escaping (Error) -> Void
    ) {
        lock.lock()
        guard !hasStarted else {
            lock.unlock()
            onFailure(ExtensionRemoteSurfaceConnectionError.alreadyStarted)
            return
        }
        hasStarted = true
        packetHandler = onPacket
        failureHandler = onFailure
        let shouldStart = !isClosed
        lock.unlock()
        guard shouldStart else {
            onFailure(ExtensionRemoteSurfaceConnectionError.closed)
            return
        }
        readQueue.async { [weak self] in
            self?.readLoop()
        }
    }

    func send(_ message: ExtensionRemoteSurfaceMessage) {
        send(.init(message: message))
    }

    func acknowledge(
        presentationID: String,
        sequence: UInt64,
        disposition: ExtensionRemoteSurfaceFrameDisposition
    ) {
        lock.lock()
        let wasPending = pendingAcknowledgements.remove(presentationID) != nil
        lock.unlock()
        guard wasPending else { return }
        send(.init(message: .acknowledgement(.init(
            presentationID: presentationID,
            sequence: sequence,
            disposition: disposition
        ))))
    }

    func close() {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        packetHandler = nil
        failureHandler = nil
        pendingAcknowledgements.removeAll()
        lock.unlock()
        closeTransport()
    }

    private func send(_ packet: ExtensionRemoteSurfacePacket) {
        writeQueue.async { [weak self] in
            guard let self, !self.lockedIsClosed else { return }
            do {
                try ExtensionRemoteSurfaceWire.write(packet, to: self.handle)
            } catch {
                self.fail(error)
            }
        }
    }

    private func readLoop() {
        do {
            while !lockedIsClosed {
                guard let packet = try ExtensionRemoteSurfaceWire.read(from: handle) else {
                    if !lockedIsClosed {
                        fail(ExtensionRemoteSurfaceConnectionError.closed)
                    }
                    return
                }
                guard case .frame(let frame) = packet.message else {
                    throw ExtensionRemoteSurfaceConnectionError.unexpectedMessage
                }

                lock.lock()
                if pendingAcknowledgements.contains(frame.presentationID) {
                    lock.unlock()
                    throw ExtensionRemoteSurfaceConnectionError
                        .frameBeforeAcknowledgement(frame.presentationID)
                }
                if let last = lastSequences[frame.presentationID],
                   frame.sequence <= last {
                    lock.unlock()
                    throw ExtensionRemoteSurfaceConnectionError
                        .nonMonotonicSequence(frame.presentationID)
                }
                lastSequences[frame.presentationID] = frame.sequence
                pendingAcknowledgements.insert(frame.presentationID)
                let handler = packetHandler
                lock.unlock()

                guard let handler else {
                    acknowledge(
                        presentationID: frame.presentationID,
                        sequence: frame.sequence,
                        disposition: .dropped
                    )
                    continue
                }
                handler(packet)
            }
        } catch {
            fail(error)
        }
    }

    private var lockedIsClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isClosed
    }

    private func fail(_ error: Error) {
        let handler: ((Error) -> Void)?
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        handler = failureHandler
        failureHandler = nil
        packetHandler = nil
        pendingAcknowledgements.removeAll()
        lock.unlock()
        closeTransport()
        handler?(error)
    }

    private func closeTransport() {
        // Wake a blocking reader as a clean socket shutdown before closing its FileHandle. A
        // cross-queue close alone surfaces EBADF diagnostics from Foundation during teardown.
        _ = Darwin.shutdown(handle.fileDescriptor, SHUT_RDWR)
        try? handle.close()
    }
}
