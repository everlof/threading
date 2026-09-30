import Dispatch
import Foundation
import ThreadingPTYClient
import ThreadingPTYHostKit

extension PTYHostClient {
    convenience init(
        socketPath: String,
        build: String,
        events: Events,
        eventLog: EventLog = .shared,
        queue: DispatchQueue? = nil,
        connectTimeout: TimeInterval = PTYHostClientDefaults.connectTimeout,
        helloTimeout: TimeInterval = PTYHostClientDefaults.helloTimeout,
        maximumQueuedWriteBytes: Int = PTYHostClientDefaults.maximumQueuedWriteBytes
    ) {
        self.init(socketPath: socketPath, build: build, events: events,
                  journal: { message, detail in eventLog.record(.session, message, detail) },
                  diagnostic: { Self.record($0) },
                  queue: queue, connectTimeout: connectTimeout, helloTimeout: helloTimeout,
                  maximumQueuedWriteBytes: maximumQueuedWriteBytes)
    }

    private static func record(_ diagnostic: PTYHostClientDiagnostic) {
        switch diagnostic {
        case .connected(let version):
            ThreadingLogger.ptyHost.info("PTY host connected, protocol \(version, privacy: .public)")
        case .protocolMismatch(let compatibility, let update):
            ThreadingLogger.ptyHost.warning(
                "PTY host protocol mismatch: \(compatibility.rawValue, privacy: .public), update \(update, privacy: .public)"
            )
        case .framingRefused(let reason, let duringHandshake):
            if duringHandshake {
                ThreadingLogger.ptyHost.error(
                    "PTY host framing refused during handshake: \(reason, privacy: .public)"
                )
            } else {
                ThreadingLogger.ptyHost.error("PTY host framing refused: \(reason, privacy: .public)")
            }
        case .unexpectedInput:
            ThreadingLogger.ptyHost.error("PTY host sent an input frame; ignored")
        case .lostSessions(let count):
            ThreadingLogger.ptyHost.warning(
                "PTY host lost \(count, privacy: .public) session(s) across a restart"
            )
        case .unknownFrameType(let type):
            ThreadingLogger.ptyHost.info(
                "PTY host sent an unknown frame type; ignored: \(type, privacy: .public)"
            )
        case .unreadableControl(let reason):
            ThreadingLogger.ptyHost.error(
                "PTY host sent a control frame this build could not read; ignored: \(reason, privacy: .private(mask: .hash))"
            )
        case .writeQueueOverflow(let queued, let bound):
            ThreadingLogger.ptyHost.error(
                "PTY host stopped reading; \(queued, privacy: .public) bytes queued, over the \(bound, privacy: .public)-byte bound; closing"
            )
        }
    }

    // MARK: - Probing

    /// One connect-`hello`-close round trip, for `PTYHostAvailability`.
    ///
    /// The full client rather than a simplified dialect on purpose: a probe that spoke less than
    /// the link does could admit a daemon the link then refuses, moving the failure from the
    /// decision boundary into the launch itself.
    static func probe(
        socketPath: String,
        build: String,
        eventLog: EventLog = .shared
    ) -> PTYHostProbeOutcome {
        let client = PTYHostClient(
            socketPath: socketPath,
            build: build,
            events: .ignored,
            eventLog: eventLog
        )
        do {
            _ = try client.connect()
            client.close()
            return .ready
        } catch PTYHostClientError.incompatible(let compatibility) {
            return .mismatched(compatibility)
        } catch {
            let cause = (error as? PTYHostClientError)?.token ?? "unknown"
            ThreadingLogger.ptyHost.info(
                "PTY host probe found no usable daemon: \(cause, privacy: .public)"
            )
            return .notRunning
        }
    }

}
