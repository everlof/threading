import Dispatch
import Foundation
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
                  queue: queue, connectTimeout: connectTimeout, helloTimeout: helloTimeout,
                  maximumQueuedWriteBytes: maximumQueuedWriteBytes)
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
