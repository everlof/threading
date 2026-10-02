import Foundation
import os

/// FSEvents registration is a synchronous RPC to fseventsd, even when event delivery uses a
/// dispatch queue. Keep registration and teardown on one utility lane shared by all streams.
/// Admission is O(1); a blocked daemon cannot spawn a worker for every rapid checkout switch.
final class FileSystemEventStream: Sendable {
    private let worker: Worker

    init(
        paths: [String],
        latency: CFTimeInterval,
        coalesce: TimeInterval,
        isRelevant: @escaping @Sendable ([String], [FSEventStreamEventFlags]) -> Bool,
        onChange: @escaping @MainActor @Sendable () -> Void,
        backend: (any FileSystemEventStreamBackend)? = nil
    ) {
        worker = Worker(
            backend: backend ?? NativeFileSystemEventStreamBackend(paths: paths, latency: latency),
            coalesce: coalesce,
            isRelevant: isRelevant,
            onChange: onChange
        )
    }

    deinit { worker.stop() }

    func start() { worker.start() }

    /// Revokes delivery immediately; daemon unregistration may finish later on the worker.
    func stop() { worker.stop() }

    private final class Worker: @unchecked Sendable {
        private struct Request {
            var generation: UUID?
            var isScheduled = false
            var pendingDelivery: UUID?
        }

        private static let lifecycleQueue = DispatchQueue(
            label: "codes.threading.fs-events.lifecycle", qos: .utility
        )
        private static let deliveryQueue = DispatchQueue(
            label: "codes.threading.fs-events.delivery", qos: .utility
        )

        private let request = OSAllocatedUnfairLock(initialState: Request())
        private let backend: any FileSystemEventStreamBackend
        private let coalesce: TimeInterval
        private let isRelevant: @Sendable ([String], [FSEventStreamEventFlags]) -> Bool
        private let onChange: @MainActor @Sendable () -> Void

        // Owned by lifecycleQueue. The callback retains only a weak reference to this worker.
        private var armedGeneration: UUID?
        // Owned by deliveryQueue; at most one coalesced notification per stream.
        private var notification: DispatchWorkItem?

        init(
            backend: any FileSystemEventStreamBackend,
            coalesce: TimeInterval,
            isRelevant: @escaping @Sendable ([String], [FSEventStreamEventFlags]) -> Bool,
            onChange: @escaping @MainActor @Sendable () -> Void
        ) {
            self.backend = backend
            self.coalesce = coalesce
            self.isRelevant = isRelevant
            self.onChange = onChange
        }

        func start() {
            let schedule = request.withLock { state in
                guard state.generation == nil else { return false }
                state.generation = UUID()
                guard !state.isScheduled else { return false }
                state.isScheduled = true
                return true
            }
            if schedule { Self.lifecycleQueue.async { self.reconcile() } }
        }

        func stop() {
            let schedule = request.withLock { state in
                guard state.generation != nil else { return false }
                state.generation = nil
                guard !state.isScheduled else { return false }
                state.isScheduled = true
                return true
            }
            if schedule { Self.lifecycleQueue.async { self.reconcile() } }
        }

        private func isCurrent(_ generation: UUID) -> Bool {
            request.withLock { $0.generation == generation }
        }

        private func reconcile() {
            dispatchPrecondition(condition: .onQueue(Self.lifecycleQueue))
            while true {
                let desired = request.withLock { $0.generation }
                if armedGeneration != desired {
                    if armedGeneration != nil {
                        PerformanceRecorder.shared.measure("filesystem.watch.stop", category: "filesystem") {
                            backend.stop()
                        }
                        armedGeneration = nil
                    }
                    if let desired, isCurrent(desired) {
                        let started = PerformanceRecorder.shared.measure(
                            "filesystem.watch.start", category: "filesystem"
                        ) {
                            backend.start(deliveryQueue: Self.deliveryQueue) { [weak self] paths, flags in
                                self?.receive(paths: paths, flags: flags, generation: desired)
                            }
                        }
                        if started {
                            armedGeneration = desired
                            // Registration can lag the caller's initial read. Read once after
                            // arming so writes made in that gap are never silently missed.
                            publish(generation: desired)
                        } else {
                            request.withLock { state in
                                if state.generation == desired { state.generation = nil }
                            }
                        }
                    }
                }

                let settled = request.withLock { state in
                    guard state.generation == armedGeneration else { return false }
                    state.isScheduled = false
                    return true
                }
                if settled { return }
            }
        }

        private func receive(paths: [String], flags: [FSEventStreamEventFlags], generation: UUID) {
            dispatchPrecondition(condition: .onQueue(Self.deliveryQueue))
            guard isCurrent(generation), isRelevant(paths, flags) else { return }
            guard coalesce > 0 else {
                publish(generation: generation)
                return
            }
            notification?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.publish(generation: generation) }
            notification = item
            Self.deliveryQueue.asyncAfter(deadline: .now() + coalesce, execute: item)
        }

        private func publish(generation: UUID) {
            let admitted = request.withLock { state in
                guard state.generation == generation, state.pendingDelivery != generation else {
                    return false
                }
                state.pendingDelivery = generation
                return true
            }
            guard admitted else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let current = self.request.withLock { state in
                    if state.pendingDelivery == generation { state.pendingDelivery = nil }
                    return state.generation == generation
                }
                guard current else { return }
                MainActor.assumeIsolated { self.onChange() }
            }
        }
    }
}

/// The backend is exclusively owned by the lifecycle lane. The seam lets regression tests
/// block registration/unregistration without depending on a sick system daemon.
protocol FileSystemEventStreamBackend: AnyObject, Sendable {
    func start(
        deliveryQueue: DispatchQueue,
        onEvent: @escaping @Sendable ([String], [FSEventStreamEventFlags]) -> Void
    ) -> Bool
    func stop()
}

private final class NativeFileSystemEventStreamBackend: FileSystemEventStreamBackend, @unchecked Sendable {
    private final class Callback {
        let receive: @Sendable ([String], [FSEventStreamEventFlags]) -> Void
        init(receive: @escaping @Sendable ([String], [FSEventStreamEventFlags]) -> Void) {
            self.receive = receive
        }
    }

    private let paths: [String]
    private let latency: CFTimeInterval
    private var stream: FSEventStreamRef?

    init(paths: [String], latency: CFTimeInterval) {
        self.paths = paths
        self.latency = latency
    }

    func start(
        deliveryQueue: DispatchQueue,
        onEvent: @escaping @Sendable ([String], [FSEventStreamEventFlags]) -> Void
    ) -> Bool {
        guard !paths.isEmpty else { return false }
        let callback = Callback(receive: onEvent)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(callback).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                return UnsafeRawPointer(Unmanaged<Callback>.fromOpaque(pointer).retain().toOpaque())
            },
            release: { pointer in
                guard let pointer else { return }
                Unmanaged<Callback>.fromOpaque(pointer).release()
            },
            copyDescription: nil
        )
        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, count, rawPaths, rawFlags, _ in
                guard let info else { return }
                let callback = Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue()
                let paths = unsafeBitCast(rawPaths, to: NSArray.self) as? [String] ?? []
                callback.receive(paths, (0..<count).map { rawFlags[$0] })
            },
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            ThreadingLogger.git.error("FSEvents stream could not be created")
            return false
        }
        FSEventStreamSetDispatchQueue(stream, deliveryQueue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            ThreadingLogger.git.error("FSEvents stream could not be started")
            return false
        }
        self.stream = stream
        return true
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        // Invalidate removes the dispatch schedule. Clearing the queue first is an error.
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
