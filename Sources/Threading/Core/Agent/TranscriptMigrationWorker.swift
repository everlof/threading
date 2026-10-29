import Darwin
import Foundation

/// One admitted migration, one serial worker. Parent/child history is externally sized:
/// copying and recursive cleanup never run on the main actor. Only the store commit hops back.
actor TranscriptMigrationWorker {
    static let shared = TranscriptMigrationWorker()

    private struct Item {
        let destination: URL
        let candidate: URL
        let backup: URL
        let nonce: String
        let hadDestination: Bool

        var recovery: TranscriptCopyRecovery.Record {
            .init(
                version: 1, nonce: nonce, destinationPath: destination.path,
                candidatePath: candidate.path, backupPath: backup.path,
                hadDestination: hadDestination)
        }
    }

    private var busy = false

    func install(
        source: URL,
        destination: URL,
        includesSubagents: Bool,
        waitingForProcess: Int32? = nil,
        journalURL: URL,
        commit: @escaping @MainActor @Sendable () -> Bool
    ) async throws -> Int {
        guard !busy else { throw TranscriptCopyRecovery.RecoveryError.pendingRecovery }
        busy = true
        defer { busy = false }
        let files = FileManager.default
        guard !files.fileExists(atPath: journalURL.path) else {
            throw TranscriptCopyRecovery.RecoveryError.pendingRecovery
        }
        var prepared: [Item] = []
        var promoted: [Item] = []
        var journaled = false
        var byteCount = 0
        do {
            try waitForExit(waitingForProcess)
            let root = try prepare(source, to: destination, directory: false, files: files)
            prepared.append(root)
            guard let copiedBytes = try root.candidate.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                throw CocoaError(.fileReadUnknown)
            }
            byteCount = copiedBytes
            if includesSubagents {
                let children = ClaudeTranscript.subagentsDirectory(forRoot: source)
                if files.fileExists(atPath: children.path) {
                    let targetChildren = ClaudeTranscript.subagentsDirectory(forRoot: destination)
                    let childItem = try prepare(children, to: targetChildren, directory: true, files: files)
                    prepared.append(childItem)
                    try preserveMissingHistory(from: targetChildren, in: childItem.candidate, files: files)
                }
            }
            try TranscriptCopyRecovery.begin(
                destination: root.destination, candidate: root.candidate, backup: root.backup,
                nonce: root.nonce, companions: prepared.dropFirst().map(\.recovery),
                journalURL: journalURL, fileManager: files
            )
            journaled = true
            for item in prepared {
                if item.hadDestination { try files.moveItem(at: item.destination, to: item.backup) }
                // Remember a backed-up destination even if promotion itself fails.
                promoted.append(item)
                try files.moveItem(at: item.candidate, to: item.destination)
            }
            guard await commit() else { throw TranscriptCopyTransactionError.commitRefused }
        } catch {
            var rollbackFailure: (path: String, detail: String)?
            for item in promoted.reversed() {
                do {
                    if files.fileExists(atPath: item.destination.path) {
                        try files.removeItem(at: item.destination)
                    }
                    if item.hadDestination { try files.moveItem(at: item.backup, to: item.destination) }
                } catch {
                    rollbackFailure = (item.backup.path, error.localizedDescription)
                }
            }
            if let rollbackFailure {
                throw TranscriptCopyTransactionError.rollbackFailed(
                    recoveryPath: rollbackFailure.path, detail: rollbackFailure.detail)
            }
            for item in prepared { try? files.removeItem(at: item.candidate) }
            if journaled { TranscriptCopyRecovery.retire(journalURL: journalURL, fileManager: files) }
            throw error
        }
        var retiredBackups = true
        for item in prepared where item.hadDestination {
            do { try files.removeItem(at: item.backup) } catch {
                retiredBackups = false
                ThreadingLogger.agent.error(
                    "Could not retire migrated conversation history: \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
            }
        }
        if retiredBackups { TranscriptCopyRecovery.retire(journalURL: journalURL, fileManager: files) }
        return byteCount
    }

    private enum Defaults {
        static let stopTimeout: TimeInterval = 5
        static let stopPollInterval: TimeInterval = 0.025
    }

    private func waitForExit(_ pid: Int32?) throws {
        guard let pid, pid > 0 else { return }
        let deadline = Date().addingTimeInterval(Defaults.stopTimeout)
        while true {
            if kill(pid, 0) == -1, errno == ESRCH { return }
            guard Date() < deadline else { throw TranscriptCopyTransactionError.sourceStillRunning }
            Thread.sleep(forTimeInterval: Defaults.stopPollInterval)
        }
    }

    func removeScratch(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Moving back to a previously used account must not erase child histories that an older
    /// migration omitted. Source files are current; target-only histories remain available.
    private func preserveMissingHistory(from previous: URL, in candidate: URL, files: FileManager) throws {
        guard files.fileExists(atPath: previous.path) else { return }
        let values = try previous.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw TranscriptCopyTransactionError.sourceNotRegular
        }
        let previousRoot = previous.standardizedFileURL.resolvingSymlinksInPath()
        let rootComponents = previousRoot.pathComponents
        var traversalError: Error?
        guard
            let entries = files.enumerator(
                at: previousRoot, includingPropertiesForKeys: nil,
                errorHandler: { _, error in
                    traversalError = error
                    return false
                })
        else {
            throw CocoaError(.fileReadUnknown)
        }
        for case let old as URL in entries {
            // Foundation enumerates /private/var even when resolving the root returned /var.
            // Normalize each entry too, then enforce containment before deriving its relative path.
            let components = old.standardizedFileURL.resolvingSymlinksInPath().pathComponents
            guard components.count > rootComponents.count,
                components.starts(with: rootComponents)
            else {
                throw TranscriptCopyTransactionError.sourceNotRegular
            }
            let relative = components.dropFirst(rootComponents.count)
            let target = relative.reduce(candidate) { $0.appendingPathComponent($1) }
            if !files.fileExists(atPath: target.path) {
                try files.copyItem(at: old, to: target)
                entries.skipDescendants()
            }
        }
        if let traversalError { throw traversalError }
    }

    private func prepare(_ source: URL, to destination: URL, directory: Bool, files: FileManager) throws
        -> Item
    {
        let values = try source.resourceValues(forKeys: [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
        ])
        guard values.isSymbolicLink != true,
            directory ? values.isDirectory == true : values.isRegularFile == true
        else {
            throw TranscriptCopyTransactionError.sourceNotRegular
        }
        let parent = destination.deletingLastPathComponent()
        try files.createDirectory(at: parent, withIntermediateDirectories: true)
        let nonce = UUID().uuidString.lowercased()
        let item = Item(
            destination: destination,
            candidate: parent.appendingPathComponent(".threading-move-\(nonce).candidate"),
            backup: parent.appendingPathComponent(".threading-move-\(nonce).previous"),
            nonce: nonce, hadDestination: files.fileExists(atPath: destination.path))
        do { try files.copyItem(at: source, to: item.candidate) } catch {
            try? files.removeItem(at: item.candidate)
            throw error
        }
        return item
    }
}
