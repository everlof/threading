import Foundation
import ControllerRuntime
import ThreadingController
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum ControllerSupervisorCommand {
    /// `agentSocket`: the resident loop always serves agent tools there (default beside the
    /// store). A one-shot pass serves none, and it takes the same exclusive lock, so it answers
    /// `conflict` while a resident supervisor runs and never reaches that supervisor's broker. On
    /// its own it dispatches with the legacy store path only when the owner opted in; otherwise
    /// a prepared intent stays prepared with `agent_broker_unavailable`.
    static func run(store: ControllerStore, database: String, intervalMilliseconds: Int, once: Bool,
                    agentSocket: String?, agentBinary: String?) async throws {
        guard (100...60_000).contains(intervalMilliseconds), let binary = Bundle.main.executableURL?.path else {
            throw ControllerError.invalidInput("supervisor_interval")
        }
        let lifetime = try SupervisorLifetime(path: database + ".supervisor.lock")
        defer { lifetime.close() }
        let access: ControllerAgentAccess?
        var broker: ControllerAgentBroker?
        if once {
            access = await ControllerAgentAccess.resolve(store: store, database: database,
                                                         allowLegacy: ControllerMain.legacyAgentDatabaseAllowed)
        } else {
            // Its own store connection: broker traffic never queues behind this loop's actor.
            let socket = agentSocket ?? ControllerAgentBroker.defaultSocketPath(database: database)
            let served = try ControllerAgentBroker(socketPath: socket, store: try ControllerStore(path: database))
            served.start()
            broker = served
            do { _ = try await store.advertiseAgentBroker(socket: socket, agentBinary: agentBinary) } catch { served.stop(); throw error }
            access = .broker(socket: socket, agentBinary: agentBinary)
        }
        let supervisor = ControllerSupervisor(store: store, database: database, controllerBinary: binary, agentAccess: access)
        // The broker stops (bounded) and its advertisement is withdrawn on every way out.
        func shutdown() async {
            guard let broker else { return }
            broker.stop()
            try? await store.withdrawAgentBroker(socket: broker.socketPath)
        }
        do {
            repeat {
                if lifetime.shouldStop { break }
                let cycle: SupervisorCycle
                do { cycle = try await supervisor.tick(reportAllHolds: once) } catch {
                    // Only a store this process can no longer trust or write ends the loop. A busy
                    // store or any other whole-pass failure is reported and retried next interval,
                    // so one lock held past the busy timeout cannot exhaust a service restart budget.
                    if let error = error as? ControllerError, error.isFatalStorage { throw error }
                    cycle = SupervisorCycle.failedPass(error)
                }
                // Always return one-shot results; a resident idle loop produces no log flood.
                if once || !cycle.isQuiet {
                    try ControllerMain.output(cycle)
                }
                if once || lifetime.shouldStop { break }
                // Short cancellable waits keep SIGTERM responsive without cancelling a sent spawn.
                var remaining = intervalMilliseconds
                while remaining > 0 && !lifetime.shouldStop {
                    let part = min(remaining, 100)
                    try await Task.sleep(for: .milliseconds(part))
                    remaining -= part
                }
            } while !lifetime.shouldStop
        } catch {
            await shutdown()
            throw error
        }
        await shutdown()
    }
}

/// An OS lock has no expiry that could overlap two supervisors. The lock inode stays in place
/// across restarts. Signal callbacks own only a flag protected by NSLock, never a database or PTY.
private final class SupervisorLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var stopping = false
    private let descriptor: Int32
    private var signals: [DispatchSourceSignal] = []
    var shouldStop: Bool { lock.lock(); defer { lock.unlock() }; return stopping }
    init(path: String) throws {
        descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw ControllerError.invalidInput("supervisor_lock") }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_nlink == 1,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Self.closeDescriptor(descriptor)
            throw ControllerError.conflict
        }
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { [weak self] in self?.requestStop() }
            source.activate()
            signals.append(source)
        }
    }
    private func requestStop() { lock.lock(); stopping = true; lock.unlock() }
    func close() {
        for source in signals { source.cancel() }
        Self.closeDescriptor(descriptor)
    }
    private static func closeDescriptor(_ fd: Int32) {
        #if canImport(Darwin)
        _ = Darwin.close(fd)
        #else
        _ = Glibc.close(fd)
        #endif
    }
}
