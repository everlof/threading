#if os(Linux)
import Foundation
@testable import CoreSlice
@testable import TerminalRuntime

@MainActor
enum LinuxAttachmentPersistenceFixture {
    static func run() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-attachment-persistence-\(UUID().uuidString)",
                                    isDirectory: true)
        let projectRoot = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let checkoutRoot = root.appendingPathComponent("automation-checkout", isDirectory: true)
        let workspace = AutomationWorkspace(automationID: "fixture", checkoutPath: checkoutRoot.path)
        let executionRoot = URL(fileURLWithPath: workspace.executionPath, isDirectory: true)
        try FileManager.default.createDirectory(at: executionRoot,
                                                withIntermediateDirectories: true)
        let image = executionRoot.appendingPathComponent("figure.png")
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: image)
        var session = AgentSession(kind: .codex, title: "Attachment persistence")
        session.automationWorkspace = workspace
        var project = Project(name: "project", folderURL: projectRoot)
        precondition(session.workingDirectory(in: project) == executionRoot.path,
                     "fixture did not create a separate execution root")
        project.sessions = [session]
        let databaseURL = root.appendingPathComponent("threading.db")
        let database = try ProjectDatabase(url: databaseURL)
        try database.save(ProjectsState(projects: [project], selectedSessionID: session.id))
        database.close()

        let persistence = LinuxAttachmentPersistence(storePath: root.path)
        let initial = try await persistence.load(sessionID: session.id)
        precondition(initial.isEmpty, "new session has a persisted attachment")
        let store = persistence.makeStore()
        persistence.markPreparedInstalled(for: session.id)
        precondition(store.installPrepared(initial, for: session.id),
                     "prepared attachment snapshot was refused")
        let recorded = store.record(urls: [image], sessionID: session.id,
                                    projectRoot: executionRoot)
        precondition(recorded.count == 1, "shared store did not admit the project file")
        await persistence.finishPendingWrites()

        let restoredPersistence = LinuxAttachmentPersistence(storePath: root.path)
        let restoredStore = restoredPersistence.makeStore()
        let detectionKey = AttachmentDetectionPreferences.disabledAgentKindsKey
        let outsideKey = AttachmentDetectionPreferences.includesOutsideProjectKey
        let priorDetectionValue = PreferenceStore.shared.object(forKey: detectionKey)
        let priorOutsideValue = PreferenceStore.shared.object(forKey: outsideKey)
        LinuxGeneralSettings.setAttachmentReferenceDetection(for: session.kind, enabled: true)
        LinuxGeneralSettings.includesAttachmentsOutsideProject = false
        defer {
            LinuxGeneralSettings.finishPendingWrites()
            if let priorDetectionValue {
                PreferenceStore.shared.set(priorDetectionValue, forKey: detectionKey)
            } else {
                PreferenceStore.shared.removeObject(forKey: detectionKey)
            }
            if let priorOutsideValue {
                PreferenceStore.shared.set(priorOutsideValue, forKey: outsideKey)
            } else {
                PreferenceStore.shared.removeObject(forKey: outsideKey)
            }
            _ = PreferenceStore.shared.synchronize()
        }
        precondition(restoredStore.attachments(for: session.id).isEmpty,
                     "an early read must wait for the worker snapshot")
        let secondImage = executionRoot.appendingPathComponent("second.png")
        try Data([0x89, 0x50, 0x4e, 0x47, 0x01]).write(to: secondImage)
        let live = restoredStore.record(urls: [secondImage], sessionID: session.id,
                                        projectRoot: executionRoot)
        precondition(live.count == 1, "early live attachment was not admitted")
        let restored = try await restoredPersistence.load(sessionID: session.id)
        precondition(restored.count == 1 && restored[0].id == recorded[0].id,
                     "attachment identity did not survive SQLite reload")
        restoredPersistence.markPreparedInstalled(for: session.id)
        precondition(restoredStore.installPrepared(restored, for: session.id)
                     && restoredStore.attachments(for: session.id).count == 2,
                     "prepared rows did not merge with the early live attachment")
        let scannedImage = executionRoot.appendingPathComponent("from-agent.png")
        try Data([0x89, 0x50, 0x4e, 0x47, 0x02]).write(to: scannedImage)
        let scanner = LinuxNativeAttachmentScanner(
            sessionID: session.id, kind: session.kind, store: restoredStore)
        scanner.note(.textDelta(scannedImage.path), projectRoot: executionRoot)
        precondition(restoredStore.attachments(for: session.id).count == 2,
                     "unfinished assistant prose entered the attachment list")
        scanner.note(.turnFinished(text: "Saved \(scannedImage.path)", outcome: .completed,
                                   metrics: .empty), projectRoot: executionRoot)
        for _ in 0..<200 where restoredStore.attachments(for: session.id).count < 3 {
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(restoredStore.attachments(for: session.id).count == 3,
                     "completed native output did not reach the shared attachment store")
        let burst = try (0..<10).map { index -> URL in
            let url = executionRoot.appendingPathComponent("burst-\(index).png")
            try Data([0x89, 0x50, 0x4e, 0x47, UInt8(index)]).write(to: url)
            return url
        }
        for url in burst {
            scanner.note(.assistantMessage(blocks: [.text("Saved \(url.path)")]),
                         projectRoot: executionRoot)
        }
        for _ in 0..<400 where restoredStore.attachments(for: session.id).count < 13 {
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(restoredStore.attachments(for: session.id).count == 13,
                     "completed assistant messages were dropped when the scan worker filled")
        let terminalImage = executionRoot.appendingPathComponent("from-terminal.png")
        try Data([0x89, 0x50, 0x4e, 0x47, 0x03]).write(to: terminalImage)
        let emulator = try PTYEmulator(columns: 40, rows: 8, send: { _ in })
        emulator.feed(Data("Saved \(terminalImage.path)\r\n".utf8))
        let logical = emulator.recentLogicalBufferText(
            maximumUTF8Bytes: SessionAttachmentDefaults.maximumTerminalScanBytes,
            sinceAbsoluteRow: 0)
        precondition(logical.text.contains(terminalImage.path),
                     "SwiftTerm did not rejoin the wrapped terminal path")
        let logicalText = logical.text
        let nextAbsoluteRow = logical.nextAbsoluteRow
        let terminal = GraphicalTerminal()
        let terminalScanner = LinuxTerminalAttachmentScanner(
            sessionID: session.id, store: restoredStore,
            readText: { _, since in
                GraphicalTerminal.AttachmentRead(
                    buffer: TerminalScanRead(text: logicalText,
                                             nextAbsoluteRow: since + nextAbsoluteRow),
                    currentDirectory: executionRoot)
            })
        terminalScanner.noteOutput(from: terminal, projectRoot: executionRoot)
        for _ in 0..<200 where restoredStore.attachments(for: session.id).count < 14 {
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(restoredStore.attachments(for: session.id).count == 14,
                     "terminal logical output did not reach the shared attachment store")
        let beforeRepeatedTerminalText = restoredStore.attachments(for: session.id).map(\.id)
        terminalScanner.noteOutput(from: terminal, projectRoot: executionRoot)
        try await Task.sleep(for: .seconds(1))
        precondition(restoredStore.attachments(for: session.id).map(\.id)
                     == beforeRepeatedTerminalText,
                     "repeated terminal text reordered an already listed attachment")
        let toggledImage = executionRoot.appendingPathComponent("after-toggle.png")
        try Data([0x89, 0x50, 0x4e, 0x47, 0x04]).write(to: toggledImage)
        let toggledEvent = StreamEvent.assistantMessage(
            blocks: [.text("Saved \(toggledImage.path)")])
        LinuxGeneralSettings.setAttachmentReferenceDetection(for: session.kind, enabled: false)
        scanner.note(toggledEvent, projectRoot: executionRoot)
        precondition(restoredStore.attachments(for: session.id).count == 14,
                     "disabled native detection still admitted output")
        LinuxGeneralSettings.setAttachmentReferenceDetection(for: session.kind, enabled: true)
        scanner.note(toggledEvent, projectRoot: executionRoot)
        for _ in 0..<200 where restoredStore.attachments(for: session.id).count < 15 {
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(restoredStore.attachments(for: session.id).count == 15,
                     "re-enabled native detection did not admit output")
        let outsideImage = root.appendingPathComponent("outside-native.png")
        let outsideBytes = Data([0x89, 0x50, 0x4e, 0x47, 0x45])
        try outsideBytes.write(to: outsideImage)
        scanner.note(.assistantMessage(blocks: [.text("Saved \(outsideImage.path)")]),
                     projectRoot: executionRoot)
        for _ in 0..<200 where restoredStore.withheldReferences(for: session.id).isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(restoredStore.withheldReferences(for: session.id).map(\.path)
                     .contains(outsideImage.path)
                     && restoredStore.attachments(for: session.id).count == 15,
                     "narrow scan admitted or forgot the outside file")
        let scopeCoordinator = LinuxOutsideProjectAdmissionCoordinator(store: restoredStore)
        LinuxGeneralSettings.includesAttachmentsOutsideProject = true
        scopeCoordinator.settingChanged(enabled: true)
        for _ in 0..<200 where restoredStore.attachments(for: session.id).count < 16 {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let outsideRow = restoredStore.attachments(for: session.id)
            .first(where: { $0.sourcePath == outsideImage.path }) else {
            preconditionFailure("widening did not admit withheld outside file")
        }
        let copiedBytes = try Data(contentsOf: outsideRow.url)
        precondition(outsideRow.isOutsideProject && outsideRow.url != outsideImage
                     && copiedBytes == outsideBytes,
                     "outside file was not copied into shared store custody")
        LinuxGeneralSettings.includesAttachmentsOutsideProject = false
        scopeCoordinator.settingChanged(enabled: false)
        precondition(restoredStore.attachments(for: session.id).count == 15,
                     "narrowing did not close the shared read gate")
        LinuxGeneralSettings.includesAttachmentsOutsideProject = true
        scopeCoordinator.settingChanged(enabled: true)
        precondition(restoredStore.attachments(for: session.id).count == 16,
                     "widening did not reveal the already copied row")
        let terminalOutside = root.appendingPathComponent("outside-terminal.png")
        try Data([0x89, 0x50, 0x4e, 0x47, 0x46]).write(to: terminalOutside)
        let terminalOutsideText = "Saved \(terminalOutside.path)"
        let terminalOutsideScanner = LinuxTerminalAttachmentScanner(
            sessionID: session.id, store: restoredStore,
            readText: { _, since in
                GraphicalTerminal.AttachmentRead(
                    buffer: TerminalScanRead(text: terminalOutsideText,
                                             nextAbsoluteRow: since + 1),
                    currentDirectory: executionRoot)
            })
        let outsideTerminal = GraphicalTerminal()
        terminalOutsideScanner.noteOutput(from: outsideTerminal, projectRoot: executionRoot)
        for _ in 0..<200 where restoredStore.attachments(for: session.id).count < 17 {
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(restoredStore.attachments(for: session.id).contains {
            $0.sourcePath == terminalOutside.path && $0.isOutsideProject
        }, "terminal scan did not admit outside file through custody")
        await restoredPersistence.finishPendingWrites()
        let merged = try await LinuxAttachmentPersistence(storePath: root.path).load(
            sessionID: session.id)
        precondition(merged.count == 17 && merged.contains(where: { $0.id == live[0].id })
                     && merged.contains(where: { $0.sourcePath == scannedImage.path })
                     && merged.contains(where: { $0.sourcePath == terminalImage.path })
                     && merged.contains(where: { $0.sourcePath == toggledImage.path })
                     && merged.contains(where: { $0.sourcePath == outsideImage.path })
                     && merged.contains(where: { $0.sourcePath == terminalOutside.path }),
                     "merged and scanned attachment list was not persisted")
        let reopenedStore = LinuxAttachmentPersistence(storePath: root.path).makeStore()
        precondition(reopenedStore.installPrepared(merged, for: session.id),
                     "reopened outside attachment snapshot was refused")
        LinuxGeneralSettings.includesAttachmentsOutsideProject = false
        precondition(reopenedStore.attachments(for: session.id).count == 15,
                     "reopened store bypassed the narrow read gate")
        LinuxGeneralSettings.includesAttachmentsOutsideProject = true
        precondition(reopenedStore.attachments(for: session.id).count == 17,
                     "reopened store did not reveal persisted copied rows")

        let future = "{\"formatVersion\":999,\"entries\":[]}"
        let update = try ProjectDatabase(url: databaseURL)
        try update.saveAttachmentsPayload(future, for: session.id)
        update.close()
        let refusing = LinuxAttachmentPersistence(storePath: root.path)
        do {
            _ = try await refusing.load(sessionID: session.id)
            preconditionFailure("future attachment document was accepted")
        } catch { }
        refusing.setProjectRoot(executionRoot, for: session.id)
        // Exercise the writer's independent corruption fence even if a caller were to mark a
        // failed load ready by mistake.
        refusing.markPreparedInstalled(for: session.id)
        let refusingStore = refusing.makeStore()
        _ = refusingStore.record(urls: [image], sessionID: session.id,
                                 projectRoot: executionRoot)
        await refusing.finishPendingWrites()
        let check = try ProjectDatabase(url: databaseURL)
        let remaining = try check.attachmentsPayload(for: session.id)
        check.close()
        precondition(remaining == future, "a new attachment overwrote a future document")
        print("PASS Linux attachment worker, native scan and future-document refusal")
    }
}
#endif
