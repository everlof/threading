#if os(Linux)
import Foundation
import Glibc
@testable import CoreSlice

enum LinuxStartupRestoreStoreFixture {
    static func run() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-linux-restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("store", isDirectory: true)
        let folder = root.appendingPathComponent("project", isDirectory: true)
        for directory in [store, folder] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let project = Project(name: "Restore", folderURL: folder)
        guard var selected = AgentSessionCreation.makeRecord(kind: .claude),
              var background = AgentSessionCreation.makeRecord(kind: .claude) else {
            preconditionFailure("restore fixture sessions were not admitted")
        }
        selected.lastTurnAt = Date().addingTimeInterval(-60)
        background.lastTurnAt = Date().addingTimeInterval(-120)
        let databaseURL = store.appendingPathComponent("threading.db")
        do {
            let database = try ProjectDatabase(url: databaseURL)
            defer { database.close() }
            try database.addProject(project, position: 0)
            try database.addSession(selected, to: project.id, position: 0,
                                    selectNewSession: true)
            try database.addSession(background, to: project.id, position: 1)
            try database.saveRunningSessionIDs([selected.id, background.id])
        }
        try verifyWriterCoordination(store: store, otherStore: folder)

        let defaults = PreferenceStore.shared
        let keys = [SessionRestoreDefaults.policyKey,
                    SessionRestoreDefaults.legacyRunningSessionsKey,
                    SessionRestoreDefaults.windowDaysKey,
                    SessionRestoreDefaults.limitKey]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            _ = defaults.synchronize()
        }
        defaults.removeObject(forKey: SessionRestoreDefaults.policyKey)
        defaults.set(false, forKey: SessionRestoreDefaults.legacyRunningSessionsKey)
        precondition(LinuxGeneralSettings.sessionRestorePolicy == .nothing,
                     "legacy disabled restore did not migrate")
        defaults.set(true, forKey: SessionRestoreDefaults.legacyRunningSessionsKey)
        precondition(LinuxGeneralSettings.sessionRestorePolicy == .runningAtLastQuit,
                     "legacy enabled restore did not migrate")
        LinuxGeneralSettings.sessionRestorePolicy = .recentlyUsed
        precondition(LinuxGeneralSettings.sessionRestorePolicy == .recentlyUsed,
                     "Linux did not read the shared policy key")
        defaults.set(999, forKey: SessionRestoreDefaults.windowDaysKey)
        defaults.set(999, forKey: SessionRestoreDefaults.limitKey)
        precondition(LinuxGeneralSettings.sessionRestoreWindowDays == 30
                     && LinuxGeneralSettings.sessionRestoreLimit == 32,
                     "Linux did not apply the shared launch bounds")
        LinuxGeneralSettings.sessionRestorePolicy = .runningAtLastQuit
        defer { LinuxGeneralSettings.finishPendingWrites() }
        let preparation = try LinuxStartupRestoreStore.prepare(
            store: store.path,
            socket: root.appendingPathComponent("missing.sock").path,
            excluding: selected.id
        )
        precondition(!preparation.hostSurveySucceeded,
                     "missing daemon was mistaken for an empty live set")
        precondition(preparation.plan.sessionIDs == [background.id],
                     "selected agent was relaunched twice or background agent was dropped")
        precondition(preparation.launches.map(\.session.id) == [background.id]
                     && preparation.launches.map(\.projectID) == [project.id],
                     "ordered plan lost its exact store owner")
        let unreadRecord = try LinuxStoreMutation.withDatabase(at: store.path) {
            try $0.runningSessionIDs()
        }
        precondition(unreadRecord == [selected.id, background.id],
                     "preparation spent the quit record before launch admission")
        let rejected = try LinuxStartupRestoreStore.consume(store: store.path,
            expected: [background.id])
        precondition(!rejected, "stale preparation consumed another record")
        let racedQuit = try LinuxStartupRestoreStore.recordCleanQuit(
            store: store.path, running: [], consumed: true)
        precondition(!racedQuit, "a refused consume erased a newer quit record")
        let consumed = try LinuxStartupRestoreStore.consume(store: store.path,
            expected: preparation.recorded)
        precondition(consumed, "accepted plan did not consume its record")
        let ignoredEmpty = try LinuxStartupRestoreStore.recordCleanQuit(
            store: store.path, running: [], consumed: false)
        precondition(!ignoredEmpty,
            "an unconsumed empty quit overwrote its predecessor")
        let recordedQuit = try LinuxStartupRestoreStore.recordCleanQuit(
            store: store.path, running: [background.id], consumed: true)
        precondition(recordedQuit,
            "a clean quit did not record its running agent")
        let preservedEmpty = try LinuxStartupRestoreStore.recordCleanQuit(
            store: store.path, running: [], consumed: false)
        precondition(!preservedEmpty,
            "a quick empty quit spent a prior live record")
        let foreignOnly = try LinuxStartupRestoreStore.recordCleanQuit(
            store: store.path, running: [SessionID()], consumed: false)
        precondition(!foreignOnly, "another store's daemon child replaced this store's record")
        let preserved = try LinuxStoreMutation.withDatabase(at: store.path) {
            try $0.runningSessionIDs()
        }
        precondition(preserved == [background.id], "quick quit erased the last live agent")
        let rejectedReceipt = LinuxStartupRestoreStore.consumeLater(store: store.path,
            expected: [selected.id]) {}
        LinuxStartupRestoreStore.recordCleanQuitLater(store: store.path,
            socket: root.appendingPathComponent("missing.sock").path,
            captured: [], consumed: true,
            pendingConsume: .init(receipt: rejectedReceipt, owed: [selected.id]))
        let completed = DispatchSemaphore(value: 0)
        Task.detached {
            await LinuxStartupRestoreStore.finishPendingQuits()
            completed.signal()
        }
        precondition(completed.wait(timeout: .now() + 5) == .success,
                     "pending-consume quit did not finish")
        let afterRefusal = try LinuxStoreMutation.withDatabase(at: store.path) {
            try $0.runningSessionIDs()
        }
        precondition(afterRefusal == [background.id],
                     "a refused consume carried stale launch intent into the next quit record")
        let acceptedReceipt = LinuxStartupRestoreStore.consumeLater(store: store.path,
            expected: [background.id]) {}
        LinuxStartupRestoreStore.recordCleanQuitLater(store: store.path,
            socket: root.appendingPathComponent("missing.sock").path,
            captured: [], consumed: true,
            pendingConsume: .init(receipt: acceptedReceipt, owed: [background.id]))
        let accepted = DispatchSemaphore(value: 0)
        Task.detached {
            await LinuxStartupRestoreStore.finishPendingQuits()
            accepted.signal()
        }
        precondition(accepted.wait(timeout: .now() + 5) == .success,
                     "accepted pending-consume quit did not finish")
        let afterAcceptance = try LinuxStoreMutation.withDatabase(at: store.path) {
            try $0.runningSessionIDs()
        }
        precondition(afterAcceptance == [background.id],
                     "a successful consume lost the queued relaunch on quick quit")
        print("PASS Linux startup restore store: exact consume, selected exclusion and quick-quit preservation")
    }

    private static func verifyWriterCoordination(store: URL, otherStore: URL) throws {
        let owner = try LinuxStoreMutation.acquire(at: store)
        defer { owner.close() }
        let other = try LinuxStoreMutation.acquire(at: otherStore)
        other.close()
        do {
            let unexpected = try LinuxStoreMutation.acquire(at: store, waitForLocalWriter: false)
            unexpected.close()
            preconditionFailure("latency-sensitive metadata waited through a local writer")
        } catch {}

        let entered = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            entered.signal()
            do {
                let count = try NativeWorkspaceSession.withDatabase(store: store.path) {
                    try $0.runningSessionIDs().count
                }
                precondition(count == 2, "native startup lost its record after local contention")
            } catch {
                preconditionFailure("native startup refused a local writer: \(error)")
            }
            finished.signal()
        }
        precondition(entered.wait(timeout: .now() + 2) == .success,
                     "native store worker did not enter")
        precondition(finished.wait(timeout: .now() + 0.1) == .timedOut,
                     "native startup refused an in-process writer instead of waiting")
        owner.close()
        precondition(finished.wait(timeout: .now() + 2) == .success,
                     "native startup did not resume after the writer closed")

        // An OS owner outside the registry represents a separate host. It must still be
        // refused immediately, and the failed acquisition must release the local reservation.
        let external = Glibc.open(store.appendingPathComponent("host.lock").path, O_RDWR | O_CLOEXEC)
        precondition(external >= 0 && flock(external, LOCK_EX | LOCK_NB) == 0)
        do {
            let unexpected = try LinuxStoreMutation.acquire(at: store)
            unexpected.close()
            preconditionFailure("another host's store lock was ignored")
        } catch {}
        Glibc.close(external)
        let recovered = try LinuxStoreMutation.acquire(at: store)
        recovered.close()
        print("PASS Linux store writers: local serialization, independent stores and external exclusion")
    }
}
#endif
