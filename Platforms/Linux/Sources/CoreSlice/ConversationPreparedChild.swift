import Foundation

/// A worker-created child handed once to a MainActor transport. The lock owns that transfer;
/// before it, nobody reads the parent pipe handles. Exit can precede UI installation, so its
/// one receipt is retained and delivered when the transport takes ownership.
final class ConversationPreparedChild: @unchecked Sendable {
    private final class ExitRelay: @unchecked Sendable {
        private let lock = NSLock()
        private var handler: (@Sendable (Int32) -> Void)?
        private var status: Int32?
        private var received = false

        func receive(_ status: Int32) {
            lock.lock()
            guard !received else { lock.unlock(); return }
            received = true
            let handler = handler
            if handler == nil { self.status = status }
            lock.unlock()
            handler?(status)
        }

        func install(_ handler: @escaping @Sendable (Int32) -> Void) {
            lock.lock()
            self.handler = handler
            let status = status
            self.status = nil
            lock.unlock()
            if let status { handler(status) }
        }
    }

    private let lock = NSLock()
    private let relay: ExitRelay
    private var child: AgentChildProcess?

    init(plan: AgentLaunchPlan, sessionID: SessionID, host: PTYHostChildPlan?) throws {
        let relay = ExitRelay()
        self.relay = relay
        child = try AgentChildProcess.launch(executable: plan.executable, arguments: plan.arguments,
            environment: plan.launchEnvironment(), sessionID: sessionID, host: host,
            onExit: { relay.receive($0) })
    }

    @MainActor
    func take(onExit: @escaping @Sendable (Int32) -> Void) throws -> AgentChildProcess {
        lock.lock()
        guard let child else {
            lock.unlock()
            throw AlreadyConsumed()
        }
        self.child = nil
        lock.unlock()
        relay.install(onExit)
        return child
    }

    deinit { child?.terminate() }
    private struct AlreadyConsumed: Error {}
}
