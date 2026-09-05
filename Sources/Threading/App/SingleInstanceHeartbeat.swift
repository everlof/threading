import AppKit
import Foundation

// MARK: - Single Instance Heartbeat

/// Says that the lock owner's main thread is still turning.
///
/// The lock cannot answer this. `flock` is released by the kernel when a process *dies*, and a
/// wedged process is very much alive: it holds the lock, shows nothing, answers nothing, and
/// every fresh launch loses to it. Liveness is therefore a separate, cheap signal, and the file
/// is judged by its modification time rather than by anything written into it.
///
/// **On the main queue, deliberately**, for the reason `LaunchLedger.armStabilityCheckpoint`
/// gives: a timer on a utility queue keeps ticking straight through a hang and would certify an
/// app nobody can use. A wedged main thread stops producing this, which is the whole signal.
///
/// It runs in recovery mode too. A wedged recovery instance locks the user out exactly as a
/// wedged normal one does, and this observes rather than acts.
@MainActor
final class SingleInstanceHeartbeat {

    // MARK: - Properties

    static let shared = SingleInstanceHeartbeat()

    private let url: URL
    private let writer: SingleInstanceHeartbeatWriter
    private var timer: DispatchSourceTimer?
    private var wakeObservations: AppEventObservations?

    // MARK: - Initialization

    init(
        url: URL = SingleInstanceHeartbeat.defaultURL,
        writer: SingleInstanceHeartbeatWriter = SingleInstanceHeartbeatWriter()
    ) {
        self.url = url
        self.writer = writer
    }

    /// Nonisolated with the lock's own path accessors: both are pure path arithmetic, and the
    /// launch that is being locked out reads them before there is an application.
    nonisolated static var defaultURL: URL {
        SingleInstanceLock.directoryURL
            .appendingPathComponent(SingleInstanceDefaults.heartbeatFileName)
    }

    // MARK: - Public Methods

    /// Starts beating. Called immediately after the lock is taken, and only by the process that
    /// took it.
    func start() {
        guard timer == nil else { return }

        touch()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + SingleInstanceDefaults.heartbeatInterval,
            repeating: SingleInstanceDefaults.heartbeatInterval,
            leeway: .seconds(SingleInstanceDefaults.heartbeatLeewaySeconds)
        )
        timer.setEventHandler { [weak self] in self?.touch() }
        self.timer = timer
        timer.resume()

        // A Mac that slept for an hour wakes with an hour-old heartbeat, and a launch probing
        // before the next tick would read a perfectly live owner as wedged. Waking is the one
        // moment worth an unscheduled beat.
        let observations = AppEventObservations(center: NSWorkspace.shared.notificationCenter)
        observations.observe(NSWorkspace.didWakeNotification) { [weak self] in
            self?.touch()
        }
        wakeObservations = observations
    }

    func stop() {
        timer?.cancel()
        timer = nil
        wakeObservations = nil
    }

    /// How long ago the owner last beat, or `nil` where there is no heartbeat to read.
    ///
    /// Nonisolated and pure but for the one `stat`: the launch that is being locked out asks
    /// this before it has an application, and a test asks it of a file it wrote itself.
    ///
    /// Through `FileManager` rather than `URL.resourceValues`, because the latter is backed by a
    /// per-URL cache and this is asked twice about the same path, seconds apart, expecting the
    /// second answer to have moved.
    nonisolated static func age(
        of url: URL = SingleInstanceHeartbeat.defaultURL,
        now: Date = Date()
    ) -> TimeInterval? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return now.timeIntervalSince(modified)
    }

    /// Whether an owner has stopped answering.
    ///
    /// `nil` — no heartbeat file at all — is deliberately **not** stale. An owner that never
    /// wrote one is an owner nothing can be said about, and the answer to that is the alert,
    /// never a signal. A negative age is a clock that moved, and reads as fresh for the same
    /// fail-closed reason.
    nonisolated static func isStale(age: TimeInterval?) -> Bool {
        guard let age else { return false }
        return age > SingleInstanceDefaults.staleThreshold
    }

    // MARK: - Private Methods

    /// Rewrites the file with a short stamp. Nothing reads the contents — the stamp is there so
    /// a person looking at the directory can see what the file is — and a failure is silent
    /// beyond the log: a heartbeat that cannot be written must not be able to end a launch.
    private func touch() {
        // The main-queue timer remains the liveness signal. Only the filesystem write crosses
        // the boundary, so a wedged UI still stops admitting fresh heartbeats.
        writer.write(Date(), to: url)
    }
}

/// Coalesces heartbeat writes on one utility lane. A slow disk can delay a stamp, but it cannot
/// build an unbounded queue or make the main actor wait behind an atomic replacement.
final class SingleInstanceHeartbeatWriter: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "codes.threading.single-instance-heartbeat",
        qos: .utility
    )
    private let lock = NSLock()
    private var pending: (Date, URL)?
    private var isWriting = false

    func write(_ date: Date, to url: URL) {
        lock.lock()
        pending = (date, url)
        let shouldStart = !isWriting
        if shouldStart { isWriting = true }
        lock.unlock()
        guard shouldStart else { return }
        queue.async { [self] in drain() }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let next = pending else {
                isWriting = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()

            do {
                try FileManager.default.createDirectory(
                    at: next.1.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data(String(next.0.timeIntervalSince1970).utf8)
                    .write(to: next.1, options: .atomic)
            } catch {
                ThreadingLogger.app.error(
                    "Single-instance heartbeat could not be written: \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
            }
        }
    }
}
