#if os(Linux)
import Foundation
@testable import CoreSlice

@MainActor
final class LinuxTerminalAttachmentCoordinator {
    private let persistence: LinuxAttachmentPersistence
    private let store: SessionAttachmentStore
    private var scanners: [SessionID: LinuxTerminalAttachmentScanner] = [:]

    init(persistence: LinuxAttachmentPersistence, store: SessionAttachmentStore) {
        self.persistence = persistence
        self.store = store
    }

    func noteOutput(from terminal: GraphicalTerminal, sessionID: SessionID) {
        guard let root = persistence.executionRoot(for: sessionID),
              let kind = persistence.agentKind(for: sessionID),
              LinuxGeneralSettings.detectsAttachmentReferences(for: kind) else { return }
        let scanner = scanners[sessionID]
            ?? LinuxTerminalAttachmentScanner(sessionID: sessionID, store: store,
                isEnabled: { LinuxGeneralSettings.detectsAttachmentReferences(for: kind) })
        scanners[sessionID] = scanner
        scanner.noteOutput(from: terminal, projectRoot: root)
    }

    func forget(_ sessionID: SessionID) {
        scanners.removeValue(forKey: sessionID)
    }
}

/// SDL's synchronous owner loop cannot resume the Mac observer's main-actor task. This host
/// adapter reads the same SwiftTerm logical suffix and uses the shared detector and row store.
@MainActor
final class LinuxTerminalAttachmentScanner {
    private static let worker = DispatchQueue(label: "threading.linux.terminal-attachments",
                                              qos: .utility)

    private struct Fingerprint: Equatable, Sendable {
        let textHash: Int
        let byteCount: Int
        let readThrough: Int
        let currentDirectory: String?
        let projectRoot: String
    }

    private struct PreparedScan: Sendable {
        let fingerprint: Fingerprint
        let rows: [SessionAttachment]
        let outsideProject: [URL]
    }

    private let sessionID: SessionID
    private let store: SessionAttachmentStore
    private let isEnabled: @MainActor () -> Bool
    private let readText: @Sendable (GraphicalTerminal, Int) -> GraphicalTerminal.AttachmentRead
    private weak var terminal: GraphicalTerminal?
    private var projectRoot: URL?
    private var lastScannedAbsoluteRow = 0
    private var lastFingerprint: Fingerprint?
    private var nextBusyScanAt = Date.distantPast
    private var lastOutputAt = Date.distantPast
    private var scanInFlight = false
    private var scanPending = false
    private var timerScheduled = false
    private var generation = 0
    private var recentlySeenPaths: [String] = []
    private var recentlySeenPathSet: Set<String> = []

    init(sessionID: SessionID, store: SessionAttachmentStore = .shared,
         isEnabled: @escaping @MainActor () -> Bool = { true },
         readText: @escaping @Sendable (GraphicalTerminal, Int) -> GraphicalTerminal.AttachmentRead
            = { $0.attachmentScanRead(sinceAbsoluteRow: $1) }) {
        self.sessionID = sessionID
        self.store = store
        self.isEnabled = isEnabled
        self.readText = readText
    }

    func noteOutput(from terminal: GraphicalTerminal, projectRoot: URL) {
        if self.projectRoot != projectRoot || self.terminal !== terminal {
            generation += 1
            lastScannedAbsoluteRow = 0
            lastFingerprint = nil
            nextBusyScanAt = .distantPast
            recentlySeenPaths.removeAll()
            recentlySeenPathSet.removeAll()
        }
        self.terminal = terminal
        self.projectRoot = projectRoot
        lastOutputAt = Date()
        scanPending = true
        scheduleScan()
    }

    private func scheduleScan() {
        guard scanPending, !scanInFlight, isEnabled(),
              let terminal, let projectRoot else { return }
        let now = Date()
        let quietAt = lastOutputAt.addingTimeInterval(
            SessionAttachmentDefaults.terminalQuietInterval)
        if now >= nextBusyScanAt || now >= quietAt {
            scanPending = false
            scanInFlight = true
            nextBusyScanAt = now.addingTimeInterval(
                SessionAttachmentDefaults.terminalBusyScanInterval)
            let since = lastScannedAbsoluteRow
            let previous = lastFingerprint
            let generation = generation
            let sessionID = sessionID
            let readText = readText
            Self.worker.async { [weak self] in
                let read = readText(terminal, since)
                let directory = read.currentDirectory ?? projectRoot
                let fingerprint = Fingerprint(
                    textHash: read.buffer.text.hashValue,
                    byteCount: read.buffer.text.utf8.count,
                    readThrough: read.buffer.nextAbsoluteRow,
                    currentDirectory: directory.path,
                    projectRoot: projectRoot.path)
                let rows: [SessionAttachment]
                let outsideProject: [URL]
                if fingerprint == previous {
                    rows = []
                    outsideProject = []
                } else {
                    let resolution = AttachmentReferenceDetector.resolve(
                        text: read.buffer.text, projectRoot: projectRoot,
                        currentDirectory: directory)
                    let root = resolution.resolvedProjectRoot ?? projectRoot
                    rows = SessionAttachmentScannedRowPreparation.insideProject(
                        resolution.insideProject, sessionID: sessionID,
                        projectRoot: root, context: .main, referencedAt: now)
                    outsideProject = resolution.outsideProject
                }
                let prepared = PreparedScan(
                    fingerprint: fingerprint, rows: rows, outsideProject: outsideProject)
                NativeConversationDelivery.callbacks.receive { [weak self] in
                    guard let self else { return }
                    if generation == self.generation, self.isEnabled() {
                        self.lastScannedAbsoluteRow = prepared.fingerprint.readThrough
                        self.lastFingerprint = prepared.fingerprint
                        let newRows = prepared.rows.filter {
                            !self.recentlySeenPathSet.contains($0.sourcePath)
                        }
                        let outside = prepared.outsideProject.filter {
                            !self.recentlySeenPathSet.contains($0.path)
                        }
                        self.store.recordPreparedScanned(
                            newRows, outsideProject: outside, sessionID: sessionID,
                            delivery: NativeConversationDelivery.callbacks,
                            shouldAdmit: { [weak self] in
                                guard let self else { return false }
                                return generation == self.generation && self.isEnabled()
                            },
                            completion: { [weak self] in
                                guard let self else { return }
                                if generation == self.generation && self.isEnabled() {
                                    self.noteSeen(prepared.rows.map(\.sourcePath)
                                        + prepared.outsideProject.map(\.path))
                                } else {
                                    self.lastFingerprint = nil
                                }
                                self.scanInFlight = false
                                self.scheduleScan()
                            })
                    } else {
                        self.scanInFlight = false
                        self.scheduleScan()
                    }
                }
            }
            return
        }
        guard !timerScheduled else { return }
        timerScheduled = true
        let deadline = min(nextBusyScanAt, quietAt)
        let delay = max(0, deadline.timeIntervalSince(now))
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
            NativeConversationDelivery.callbacks.receive { [weak self] in
                guard let self else { return }
                self.timerScheduled = false
                self.scheduleScan()
            }
        }
    }

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
}
#endif
