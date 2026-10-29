@testable import CoreSlice
import Foundation

/// The production observer must resolve terminal rows off the main actor and publish once.
@MainActor
func runAttachmentObserverContracts() async throws {
    let project = FileManager.default.temporaryDirectory
        .appendingPathComponent("threading-attachment-observer-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: project) }
    let image = project.appendingPathComponent("observer.png")
    try Data([0x89, 0x50, 0x4e, 0x47]).write(to: image)

    let store = SessionAttachmentStore(referenceRoot: { _ in project })
    let session = SessionID()
    let output = "saved \(image.path)"
    let observer = TerminalAttachmentObserver(
        sessionID: session,
        projectRoot: { project },
        currentDirectory: { project },
        text: { _ in TerminalScanRead(text: output, nextAbsoluteRow: 1) },
        record: { resolution, sessionID, root, shouldAdmit in
            await store.recordScanned(
                resolved: resolution, sessionID: sessionID,
                projectRoot: root, shouldAdmit: shouldAdmit
            )
        }
    )

    func waitForScan() async throws {
        let deadline = Date().addingTimeInterval(3)
        while observer.isScanInFlight && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(!observer.isScanInFlight, "terminal observer did not finish")
    }

    observer.scanNow()
    try await waitForScan()
    try require(store.attachments(for: session).map(\.name) == ["observer.png"],
                "terminal observer publishes the in-project file")
    try require(observer.lastScanMetrics?.recorded == 1,
                "terminal observer reports the recorded file")

    observer.scanNow()
    try await waitForScan()
    try require(observer.lastScanMetrics?.wasUnchanged == true,
                "identical terminal rows skip another filesystem resolution")
    print("PASS shared terminal attachment observer and unchanged-buffer gate")
}
