import Foundation
import ControllerRuntime
import ThreadingController
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum ControllerSupervisorCommand {
    static func run(store: ControllerStore, database: String, intervalMilliseconds: Int, once: Bool) async throws {
        guard (100...60_000).contains(intervalMilliseconds), let binary = Bundle.main.executableURL?.path else {
            throw ControllerError.invalidInput("supervisor_interval")
        }
        let lifetime = try SupervisorLifetime(path: database + ".supervisor.lock")
        defer { lifetime.close() }
        let supervisor = ControllerSupervisor(store: store, database: database, controllerBinary: binary)
        repeat {
            if lifetime.shouldStop { break }
            let cycle = try await supervisor.tick()
            // Always return one-shot results; a resident idle loop produces no log flood.
            if once || cycle.scheduled > 0 || !cycle.started.isEmpty || !cycle.stopped.isEmpty || !cycle.issues.isEmpty
                || !cycle.automationIssues.isEmpty || !cycle.woken.isEmpty || cycle.mail != nil {
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
