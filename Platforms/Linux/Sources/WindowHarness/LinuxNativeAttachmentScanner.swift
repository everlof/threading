#if os(Linux)
import Foundation
@testable import CoreSlice

/// Bridges completed native prose to the shared detector without suspending SDL's UI actor.
/// One fleet-wide worker bounds file probes; only prepared rows cross back into the UI loop.
@MainActor
final class LinuxNativeAttachmentScanner {
    private static let worker = DispatchQueue(label: "threading.linux.native-attachments", qos: .utility)
    private static let maximumPendingScans = 8

    private let sessionID: SessionID
    private let kind: AgentKind
    private let store: SessionAttachmentStore
    private var pendingScans = 0
    private var deferred: (texts: [String], root: URL)?
    private var deferredBytes = 0

    init(sessionID: SessionID, kind: AgentKind, store: SessionAttachmentStore = .shared) {
        self.sessionID = sessionID
        self.kind = kind
        self.store = store
    }

    func note(_ event: StreamEvent, projectRoot: URL) {
        guard LinuxGeneralSettings.detectsAttachmentReferences(for: kind) else { return }
        let texts = AttachmentDetection.assistantTexts(in: event)
        guard !texts.isEmpty else { return }
        scan(texts, projectRoot: projectRoot)
    }

    private func scan(_ texts: [String], projectRoot: URL) {
        guard pendingScans < Self.maximumPendingScans else {
            deferScan(texts, projectRoot: projectRoot)
            return
        }
        pendingScans += 1
        let sessionID = sessionID
        let referencedAt = Date()
        Self.worker.async { [weak self] in
            let resolution = AttachmentDetectionWorker.resolveBounded(
                texts: texts, projectRoot: projectRoot, currentDirectory: nil)
            let root = resolution.resolvedProjectRoot ?? projectRoot
            let rows = SessionAttachmentScannedRowPreparation.insideProject(
                resolution.insideProject, sessionID: sessionID,
                projectRoot: root, context: .main, referencedAt: referencedAt)
            NativeConversationDelivery.callbacks.receive { [weak self] in
                guard let self else { return }
                if LinuxGeneralSettings.detectsAttachmentReferences(for: self.kind) {
                    self.store.recordPreparedScanned(
                        rows, outsideProject: resolution.outsideProject,
                        sessionID: sessionID, delivery: NativeConversationDelivery.callbacks,
                        shouldAdmit: { [weak self] in
                            guard let self else { return false }
                            return LinuxGeneralSettings.detectsAttachmentReferences(for: self.kind)
                        },
                        completion: { [weak self] in self?.finishScan() })
                } else {
                    self.finishScan()
                }
            }
        }
    }

    private func finishScan() {
        pendingScans -= 1
        if let deferred {
            self.deferred = nil
            deferredBytes = 0
            scan(deferred.texts, projectRoot: deferred.root)
        }
    }

    private func deferScan(_ texts: [String], projectRoot: URL) {
        // Codex's turn-finished receipt usually has no prose. Preserve completed messages
        // while the worker is full, within the same transcript-tail budget as the detector.
        if deferred?.root != projectRoot {
            deferred = ([], projectRoot)
            deferredBytes = 0
        }
        let byteLimit = TranscriptAttachmentDefaults.transcriptScanBytes
        for text in texts where !text.isEmpty {
            let prefix = text.utf8.prefix(byteLimit + 1)
            let bounded = prefix.count > byteLimit
                ? String(decoding: prefix.prefix(byteLimit), as: UTF8.self) : text
            deferred?.texts.append(bounded)
            deferredBytes += bounded.utf8.count + 1
            while let count = deferred?.texts.count, count > 1,
                  deferredBytes > byteLimit || count > 64 {
                let removed = deferred!.texts.removeFirst()
                deferredBytes -= removed.utf8.count + 1
            }
        }
    }
}
#endif
