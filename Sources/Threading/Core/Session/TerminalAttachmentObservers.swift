import Foundation

// MARK: - Terminal Observation

/// One bounded read of a terminal's recent text, plus where the next read resumes.
///
/// The observer keeps the cursor rather than the terminal, because only the observer knows when a
/// scan was actually consumed. A disabled or restarted observer resets it and reads the whole
/// window again.
struct TerminalScanRead: Sendable {
    let text: String
    /// One past the newest row read, in coordinates that survive scrollback trimming.
    let nextAbsoluteRow: Int

    static let empty = TerminalScanRead(text: "", nextAbsoluteRow: 0)
}

/// Debounces terminal repaints and inspects SwiftTerm's bounded recent logical buffer.
///
/// Reading the emulator buffer avoids treating ANSI cursor commands as path text while retaining
/// recent scrollback that has moved just above the viewport. A path is recorded only when it
/// enters the scanned window, so an unrelated later repaint does not keep moving an old file to
/// the top of the list.
@MainActor
final class TerminalAttachmentObserver {

    struct ScanMetrics: Equatable {
        let bytes: Int
        let workerNanoseconds: UInt64
        let custodyWorkerNanoseconds: UInt64
        let applyNanoseconds: UInt64
        let found: Int
        let recorded: Int
        /// True when the buffer had not moved since the last scan, so no detection ran at all.
        var wasUnchanged = false
    }

    /// Everything a scan's answer depends on.
    ///
    /// A terminal running a TUI rewrites its screen in place, so `noteOutput` fires constantly
    /// while the text under the read window stays exactly what it was — 736 scans in one four
    /// minute trace, most of them over bytes that had already been resolved. Identical inputs
    /// cannot produce a different resolution, so the regex pass is skipped after the worker
    /// reads the mutable screen. Nothing about *what* is detected changes.
    ///
    /// The row position is part of it deliberately: text can repeat while the buffer advances
    /// (a spinner, a progress line), and an advance must always be scanned so the read window
    /// does not stall behind it.
    private struct ScanFingerprint: Equatable, Sendable {
        let textHash: Int
        let byteCount: Int
        let readThrough: Int
        let currentDirectory: String?
        let projectRoot: String
    }

    private struct PreparedScan: Sendable {
        let fingerprint: ScanFingerprint
        let readThrough: Int
        let bytes: Int
        /// Nil means the last applied buffer is unchanged.
        let resolution: AttachmentReferenceDetector.Resolution?
        let workerNanoseconds: UInt64
        let span: PerformanceSpan?
    }

    /// A fleet of live terminals shares one preparation lane. Cancellation retires queued
    /// work before it reads a buffer; a scan already in a synchronous file API finishes before
    /// the next starts, rather than adding another thread competing with the event loop.
    private actor ScanWorker {
        static let shared = ScanWorker()

        func prepare(
            since: Int,
            readText: @Sendable (Int) -> TerminalScanRead,
            projectRoot: URL,
            currentDirectory: URL?,
            previousFingerprint: ScanFingerprint?
        ) -> PreparedScan? {
            guard !Task.isCancelled else { return nil }
            let readSpan = PerformanceRecorder.shared.begin(
                "attachments.read",
                category: "attachments",
                metadata: ["since": String(since)]
            )
            let read = readText(since)
            let scannedBytes = read.text.utf8.count
            readSpan.end(metadata: [
                "bytes": String(scannedBytes),
                "new_rows": String(max(0, read.nextAbsoluteRow - since))
            ])
            guard !Task.isCancelled else { return nil }
            let fingerprint = ScanFingerprint(
                textHash: read.text.hashValue,
                byteCount: scannedBytes,
                readThrough: read.nextAbsoluteRow,
                currentDirectory: currentDirectory?.path,
                projectRoot: projectRoot.path
            )
            guard fingerprint != previousFingerprint else {
                return PreparedScan(
                    fingerprint: fingerprint, readThrough: read.nextAbsoluteRow,
                    bytes: scannedBytes, resolution: nil, workerNanoseconds: 0, span: nil
                )
            }
            let span = PerformanceRecorder.shared.begin(
                "attachments.scan",
                category: "attachments",
                crossesQueues: true,
                metadata: ["bytes": String(scannedBytes)]
            )
            let started = DispatchTime.now().uptimeNanoseconds
            let resolution = AttachmentReferenceDetector.resolve(
                text: read.text,
                projectRoot: projectRoot,
                currentDirectory: currentDirectory
            )
            let elapsed = DispatchTime.now().uptimeNanoseconds - started
            guard !Task.isCancelled else {
                span.end(metadata: ["cancelled": "1"])
                return nil
            }
            return PreparedScan(
                fingerprint: fingerprint, readThrough: read.nextAbsoluteRow,
                bytes: scannedBytes, resolution: resolution, workerNanoseconds: elapsed,
                span: span
            )
        }
    }

    typealias Recorder = @MainActor (
        AttachmentReferenceDetector.Resolution,
        SessionID,
        URL,
        @escaping @MainActor () -> Bool
    ) async -> SessionAttachmentStore.ScannedRecordResult

    private let sessionID: SessionID
    private let projectRoot: () -> URL?
    private let currentDirectory: () -> URL?
    private let text: @Sendable (Int) -> TerminalScanRead
    private let isEnabled: () -> Bool
    private let now: () -> Date
    private let record: Recorder
    private var pendingScan: Task<Void, Never>?
    private var resolutionTask: Task<Void, Never>?
    private var scanRequestedWhileRunning = false
    private var lastScan: Date?
    /// Paths already offered, newest last. Bounded, and deliberately not tied to what is still
    /// on screen: the point is not to re-announce a hint the user has already read, and the read
    /// window is now only as deep as the output since the last scan. This also replaced a set
    /// that grew with every path anywhere in scrollback.
    private var recentlySeenPaths: [String] = []
    private var recentlySeenPathSet: Set<String> = []
    private var lastScannedAbsoluteRow = 0
    private var scanGeneration = 0
    private var lastScanFingerprint: ScanFingerprint?

    private(set) var isScanInFlight = false
    private(set) var lastScanMetrics: ScanMetrics?

    init(
        sessionID: SessionID,
        projectRoot: @escaping () -> URL?,
        currentDirectory: @escaping () -> URL?,
        text: @escaping @Sendable (Int) -> TerminalScanRead,
        isEnabled: @escaping () -> Bool = { true },
        now: @escaping () -> Date = Date.init,
        record: @escaping Recorder = { resolution, sessionID, root, shouldAdmit in
            await SessionAttachmentStore.shared.recordScanned(
                resolved: resolution,
                sessionID: sessionID,
                projectRoot: root,
                shouldAdmit: shouldAdmit
            )
        }
    ) {
        self.sessionID = sessionID
        self.projectRoot = projectRoot
        self.currentDirectory = currentDirectory
        self.text = text
        self.isEnabled = isEnabled
        self.now = now
        self.record = record
    }

    deinit {
        pendingScan?.cancel()
        resolutionTask?.cancel()
    }

    /// Scans now when it may, defers only as long as it must.
    ///
    /// Waiting for quiet alone was the "attachments arrive when the agent pauses" feel: a busy
    /// stretch re-arms the debounce on every repaint, so a path printed early in a long build
    /// surfaced only when the output finally stopped. The first sighting scans immediately and
    /// sustained output re-scans on a cap; the trailing debounce still reads a burst's last
    /// lines after they have settled.
    func noteOutput() {
        pendingScan?.cancel()

        let timestamp = now()
        let dueForScan = lastScan.map {
            timestamp.timeIntervalSince($0) >= SessionAttachmentDefaults.terminalBusyScanInterval
        } ?? true
        if dueForScan {
            scanNow()
            return
        }

        let delay = UInt64(SessionAttachmentDefaults.terminalQuietInterval * 1_000_000_000)
        pendingScan = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.pendingScan = nil
            self.scanNow()
        }
    }

    func scanNow() {
        pendingScan?.cancel()
        pendingScan = nil
        lastScan = now()
        scanGeneration += 1
        let generation = scanGeneration
        resolutionTask?.cancel()
        lastScanMetrics = nil
        guard isEnabled() else {
            scanRequestedWhileRunning = false
            forgetScanHistory()
            return
        }
        guard let root = projectRoot() else {
            scanRequestedWhileRunning = false
            return
        }
        // Cancelling a task does not interrupt regex or filesystem calls already running.
        // Keep its slot until it really exits, and retain only one request for the latest
        // buffer. The generation fence still prevents the retired scan from publishing.
        guard resolutionTask == nil else {
            scanRequestedWhileRunning = true
            return
        }

        let since = lastScannedAbsoluteRow
        let current = currentDirectory()
        let previousFingerprint = lastScanFingerprint
        isScanInFlight = true
        let readText = text
        resolutionTask = Task(priority: .utility) { @MainActor [weak self] in
            defer { self?.resolutionDidFinish() }
            let prepared = await ScanWorker.shared.prepare(
                since: since, readText: readText, projectRoot: root,
                currentDirectory: current, previousFingerprint: previousFingerprint
            )
            guard let prepared else { return }
            guard let self, generation == self.scanGeneration, !Task.isCancelled else {
                prepared.span?.end(metadata: ["superseded": "1"])
                return
            }
            guard let resolution = prepared.resolution, let span = prepared.span else {
                self.lastScanMetrics = ScanMetrics(
                    bytes: prepared.bytes, workerNanoseconds: 0, custodyWorkerNanoseconds: 0,
                    applyNanoseconds: 0, found: 0, recorded: 0, wasUnchanged: true
                )
                return
            }
            await self.finishScan(
                resolution,
                scannedBytes: prepared.bytes,
                workerNanoseconds: prepared.workerNanoseconds,
                generation: generation,
                readThrough: prepared.readThrough,
                fingerprint: prepared.fingerprint,
                projectRoot: root,
                span: span
            )
        }
    }

    private func resolutionDidFinish() {
        resolutionTask = nil
        isScanInFlight = false
        guard scanRequestedWhileRunning else { return }
        scanRequestedWhileRunning = false
        scanNow()
    }

    /// Remembers offered paths, newest wins, bounded.
    private func noteSeen(_ paths: [String]) {
        for path in paths where recentlySeenPathSet.insert(path).inserted {
            recentlySeenPaths.append(path)
        }
        let overflow = recentlySeenPaths.count - SessionAttachmentDefaults.rememberedScannedPaths
        guard overflow > 0 else { return }
        for path in recentlySeenPaths.prefix(overflow) {
            recentlySeenPathSet.remove(path)
        }
        recentlySeenPaths.removeFirst(overflow)
    }

    /// Forgets both what was offered and how far the buffer was read, so the next scan starts
    /// from the whole bounded window again.
    private func forgetScanHistory() {
        recentlySeenPaths.removeAll()
        recentlySeenPathSet.removeAll()
        lastScannedAbsoluteRow = 0
        // The next scan must run for real: what was offered has been forgotten, so identical
        // text is no longer a reason to believe the same answer is already applied.
        lastScanFingerprint = nil
    }

    private func finishScan(
        _ resolution: AttachmentReferenceDetector.Resolution,
        scannedBytes: Int,
        workerNanoseconds: UInt64,
        generation: Int,
        readThrough: Int,
        fingerprint: ScanFingerprint,
        projectRoot root: URL,
        span: PerformanceSpan
    ) async {
        guard generation == scanGeneration else {
            span.end(metadata: ["superseded": "1"])
            return
        }
        guard isEnabled() else {
            forgetScanHistory()
            span.end(metadata: ["disabled": "1"])
            return
        }

        let applyStarted = DispatchTime.now().uptimeNanoseconds
        // Both halves are held to the same "newly visible" rule. A path outside the project is
        // refused rather than listed, but re-offering it on every repaint would still be work,
        // and would keep re-announcing a hint the user has already read.
        let newly = AttachmentReferenceDetector.Resolution(
            insideProject: resolution.insideProject.filter { !recentlySeenPathSet.contains($0.path) },
            outsideProject: resolution.outsideProject.filter { !recentlySeenPathSet.contains($0.path) },
            resolvedProjectRoot: resolution.resolvedProjectRoot
        )
        let filteredEnded = DispatchTime.now().uptimeNanoseconds
        let result = if newly.isEmpty {
            SessionAttachmentStore.ScannedRecordResult.empty
        } else {
            await record(newly, sessionID, root) { [weak self] in
                guard let self else { return false }
                return self.scanGeneration == generation && self.isEnabled()
            }
        }
        guard generation == scanGeneration else {
            span.end(metadata: ["superseded": "1"])
            return
        }
        // Admission can suspend while custody is staged. A newer scan may replace this one in
        // that interval, so neither its cursor nor its deduplication history is committed until
        // the result has actually been applied.
        noteSeen((resolution.insideProject + resolution.outsideProject).map(\.path))
        lastScannedAbsoluteRow = max(lastScannedAbsoluteRow, readThrough)
        lastScanFingerprint = fingerprint
        let found = newly.insideProject.count + newly.outsideProject.count
        lastScanMetrics = ScanMetrics(
            bytes: scannedBytes,
            workerNanoseconds: workerNanoseconds,
            custodyWorkerNanoseconds: result.custodyWorkerNanoseconds,
            applyNanoseconds: (filteredEnded - applyStarted) + result.mainActorNanoseconds,
            found: found,
            recorded: result.attachments.count
        )
        span.end(metadata: [
            "found": String(found),
            "recorded": String(result.attachments.count),
            "custody_worker_ms": String(
                format: "%.3f",
                Double(result.custodyWorkerNanoseconds) / 1_000_000
            )
        ])
    }
}

// MARK: - Terminal Transcript Observation

/// Recovers assistant prose that a full-screen agent TUI painted as already-wrapped grid rows.
///
/// The ordinary terminal observer remains necessary for shell output, providers whose transcript
/// is not readable, and paths printed before a turn ends. It can join emulator-owned soft wraps,
/// but no emulator can infer that two independently painted rows came from one provider message.
/// Claude and Codex transcripts retain that message intact, so their completed terminal turns get
/// one bounded, background tail scan through the same provider normalization Native Chat replays.
///
/// A turn boundary schedules stability retries because the hook and the transcript writer are two
/// processes: the hook can arrive while the final record is still being flushed. Resolutions are
/// deduplicated within the turn before returning to the main actor, so retries neither recopy an
/// outside file nor move an existing row repeatedly.
@MainActor
final class TerminalTranscriptAttachmentObserver {

    typealias TranscriptURLLookup = @Sendable () -> URL?

    private let sessionID: SessionID
    private let kind: AgentKind
    private let projectRoot: () -> URL?
    private let currentDirectory: () -> URL?
    private let transcriptURL: () -> URL?
    private let transcriptLookup: () -> TranscriptURLLookup?
    private let isEnabled: () -> Bool
    private let context: () -> AttachmentReferenceContext
    private let isChild: Bool
    private let store: SessionAttachmentStore
    private var activeScan: Task<Void, Never>?
    private var pendingInput: (
        generation: Int, transcript: URL?, lookup: TranscriptURLLookup?, message: String?, force: Bool
    )?
    private var isInvalidated = false
    private var transcriptSignature: AttachmentDetectionWorker.TranscriptSignature?

    private var generation = 0
    private var pendingScans: [Task<Void, Never>] = []
    private var pathsRecordedThisTurn: Set<String> = []

    init(
        sessionID: SessionID,
        kind: AgentKind,
        projectRoot: @escaping () -> URL?,
        currentDirectory: @escaping () -> URL?,
        transcriptURL: @escaping () -> URL?,
        transcriptLookup: @escaping () -> TranscriptURLLookup? = { nil },
        isEnabled: @escaping () -> Bool = { true },
        context: @escaping () -> AttachmentReferenceContext = { .main },
        isChild: Bool = false,
        store: SessionAttachmentStore? = nil
    ) {
        self.sessionID = sessionID
        self.kind = kind
        self.projectRoot = projectRoot
        self.currentDirectory = currentDirectory
        self.transcriptURL = transcriptURL
        self.transcriptLookup = transcriptLookup
        self.isEnabled = isEnabled
        self.context = context
        self.isChild = isChild
        self.store = store ?? SessionAttachmentStore.shared
    }

    deinit {
        pendingScans.forEach { $0.cancel() }
        activeScan?.cancel()
    }

    /// Starts a new bounded scan generation for the turn that just settled.
    ///
    /// `lastAssistantMessage` is a provider-supplied fast path where a hook carries one. It is
    /// still combined with the transcript rather than treated as complete: a turn may contain
    /// several assistant text blocks around tool calls.
    func noteTurnFinished(lastAssistantMessage: String? = nil) {
        pendingScans.forEach { $0.cancel() }
        pendingScans.removeAll(keepingCapacity: true)
        generation += 1
        pendingInput = nil
        transcriptSignature = nil
        pathsRecordedThisTurn.removeAll(keepingCapacity: true)

        guard !isInvalidated, isEnabled() else { return }
        let thisGeneration = generation
        // Capture the provider identity before a terminating process clears its per-launch
        // caches. The file itself remains live for the delayed stability reads.
        let transcript = transcriptURL()
        // Codex's hook normally supplies the exact immutable rollout path. If hooks are absent,
        // capture a value-only lookup now and perform its account-tree enumeration off-main.
        let lookup = transcript == nil ? transcriptLookup() : nil

        for delay in TranscriptAttachmentDefaults.stabilityDelays {
            let nanoseconds = UInt64(max(delay, 0) * 1_000_000_000)
            let work = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(nanoseconds: nanoseconds)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.scan(
                    generation: thisGeneration,
                    transcript: transcript,
                    transcriptLookup: lookup,
                    lastAssistantMessage: lastAssistantMessage,
                    force: true
                )
            }
            pendingScans.append(work)
        }
    }

    func invalidate() {
        isInvalidated = true
        generation += 1
        pendingInput = nil
        pendingScans.forEach { $0.cancel() }
        activeScan?.cancel()
    }

    /// Reuses the current generation for live child output. One scan can be active, with one
    /// latest rescan request; repeated polling neither accumulates work nor reorders old files.
    func noteTranscriptChanged() {
        scan(generation: generation, transcript: transcriptURL(),
             transcriptLookup: transcriptLookup(), lastAssistantMessage: nil)
    }

    private func scan(
        generation expectedGeneration: Int,
        transcript: URL?,
        transcriptLookup: TranscriptURLLookup?,
        lastAssistantMessage: String?,
        force: Bool = false
    ) {
        guard !isInvalidated, generation == expectedGeneration, isEnabled(),
              let root = projectRoot() else { return }
        guard activeScan == nil else {
            pendingInput = (expectedGeneration, transcript, transcriptLookup,
                            lastAssistantMessage ?? pendingInput?.message, force || pendingInput?.force == true)
            return
        }
        let current = currentDirectory()
        let attribution = context()
        let kind = kind
        let isChild = isChild
        let previousSignature = force ? nil : transcriptSignature
        activeScan = Task { [weak self] in
            let prepared = await AttachmentDetectionWorker.shared.transcriptReferences(
                at: transcript, lookup: transcriptLookup, kind: kind, isChild: isChild,
                lastAssistantMessage: lastAssistantMessage, projectRoot: root,
                currentDirectory: current, previousSignature: previousSignature
            )
            guard let self else { return }
            defer {
                self.activeScan = nil
                if let pending = self.pendingInput {
                    self.pendingInput = nil
                    self.scan(generation: pending.generation, transcript: pending.transcript,
                              transcriptLookup: pending.lookup, lastAssistantMessage: pending.message,
                              force: pending.force)
                }
            }
            guard !Task.isCancelled, self.generation == expectedGeneration, self.isEnabled() else { return }
            self.transcriptSignature = prepared.signature
            let resolution = prepared.resolution
            let fresh = AttachmentReferenceDetector.Resolution(
                insideProject: resolution.insideProject.filter {
                    self.pathsRecordedThisTurn.insert($0.path).inserted
                },
                outsideProject: resolution.outsideProject.filter {
                    self.pathsRecordedThisTurn.insert($0.path).inserted
                },
                resolvedProjectRoot: resolution.resolvedProjectRoot
            )
            if self.pathsRecordedThisTurn.count > SessionAttachmentDefaults.rememberedScannedPaths {
                self.pathsRecordedThisTurn = Set((resolution.insideProject + resolution.outsideProject).map(\.path))
            }
            guard !fresh.isEmpty else { return }
            _ = await self.store.recordScanned(
                resolved: fresh, sessionID: self.sessionID, projectRoot: root,
                context: attribution,
                shouldAdmit: { [weak self] in
                    guard let self else { return false }
                    return self.generation == expectedGeneration && self.isEnabled()
                }
            )
        }
    }

}
