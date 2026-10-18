import ThreadingRemoteKit
import XCTest
@testable import Threading

/// `display_compare_files` on two text files keeps the diff in the session's attachments, which
/// is how the comparison reaches a paired phone. The Compare tab itself is `CompareToolTests`.
@MainActor
final class CompareAttachmentTests: HostedStoreTestCase {

    private var root: URL!
    private var attachments: SessionAttachmentStore!
    private var pane: DisplayPaneController!
    private var coordinator: AgentToolCoordinator!

    /// Built per test rather than in `setUp`, and torn down through a teardown block, so the
    /// hosted base class keeps sole ownership of the async lifecycle hooks.
    private func makeFixture() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThreadingCompareKeep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Scratch", isDirectory: true),
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        self.root = root
        let copies = root.appendingPathComponent("Copies", isDirectory: true)
        attachments = SessionAttachmentStore(copiesDirectory: { copies })
        pane = DisplayPaneController()

        let live = AgentToolDependencies.live
        let dependencies = AgentToolDependencies(
            projects: live.projects, attachments: attachments, displayStore: live.displayStore,
            extensions: live.extensions, externalTools: live.externalTools,
            remoteMirror: live.remoteMirror, settings: live.settings,
            notifications: live.notifications, notificationTargets: live.notificationTargets,
            archiveScheduler: live.archiveScheduler, sessionCommands: live.sessionCommands,
            extensionInstallation: live.extensionInstallation,
            extensionAuthoring: live.extensionAuthoring, browserStorage: live.browserStorage,
            settingsCatalogue: live.settingsCatalogue, control: live.control,
            mobileDiagnosticsInspection: live.mobileDiagnosticsInspection,
            baselines: live.baselines
        )
        coordinator = AgentToolCoordinator(
            displayPaneController: pane,
            visibleSessionID: { nil }, setPaneVisible: { _ in }, windowProvider: { nil },
            browserAccessDecisionProvider: nil, browserSiteDataDecisionProvider: nil,
            playwrightRunner: PlaywrightAutomationRunner(), dependencies: dependencies
        )
    }

    func testATextComparisonIsKeptAsADiffTheResultCanTarget() async throws {
        try makeFixture()
        let session = try makeSession()
        defer { closeTabs(for: session) }
        // The usual shape: a scratch "before" outside the checkout, the edited file inside it.
        let old = try write("Scratch/notes.md", "one\ntwo\nthree\n")
        let new = try write("notes.md", "one\n2\nthree\n")

        let result = await compare(old, new, in: session)

        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("paired iPhone"), result.text)
        // The Mac's Compare tab still opens and stays in front; the kept diff only makes sure an
        // Attachments tab exists beside it, as any new attachment does.
        let compareTabs = pane.tabs(for: session).filter { $0.compare != nil }
        XCTAssertEqual(compareTabs.count, 1)
        XCTAssertEqual(pane.activeTabID(for: session), compareTabs.first?.id)
        XCTAssertEqual(pane.tabs(for: session).filter { $0.attachments != nil }.count, 1)

        let kept = try XCTUnwrap(attachments.attachments(for: session).first)
        XCTAssertEqual(kept.kind, .diff)
        XCTAssertEqual(kept.name, "notes.md.diff")
        XCTAssertEqual(kept.origin, .agent)
        let files = GitDiffParser.files(
            fromUnifiedDiff: String(decoding: try Data(contentsOf: kept.url), as: UTF8.self)
        )
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.added, 1)
        XCTAssertEqual(files.first?.removed, 1)

        let structured = try structuredContent(of: result)
        XCTAssertEqual(structured["target_kind"] as? String, "attachment")
        XCTAssertNotNil(structured["target_ref"] as? String)

        // Deleting the scratch side does not take the kept comparison with it.
        try FileManager.default.removeItem(at: old)
        XCTAssertEqual(attachments.attachments(for: session).map(\.id), [kept.id])
    }

    func testIdenticalTextFilesKeepNothing() async throws {
        try makeFixture()
        let session = try makeSession()
        defer { closeTabs(for: session) }
        let old = try write("Scratch/same.txt", "unchanged\n")
        let new = try write("same.txt", "unchanged\n")

        let result = await compare(old, new, in: session)

        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("identical"), result.text)
        XCTAssertTrue(attachments.attachments(for: session).isEmpty)
    }

    func testAPictureComparisonIsKeptAsOneRowNamingBothPictures() async throws {
        try makeFixture()
        let session = try makeSession()
        defer { closeTabs(for: session) }
        let old = try writePNG("Scratch/composer.png", color: .systemRed)
        let new = try writePNG("composer.png", color: .systemBlue)

        let first = await compare(old, new, in: session, oldTitle: "Before")
        XCTAssertFalse(first.isError, first.text)
        XCTAssertTrue(first.text.contains("paired iPhone"), first.text)

        let rows = attachments.attachments(for: session)
        let kept = try XCTUnwrap(rows.first { $0.kind == .comparison })
        XCTAssertEqual(kept.name, "composer.png.comparison")
        let pictures = rows.filter { $0.kind == .image }
        XCTAssertEqual(pictures.count, 2, "both pictures join the list beside the comparison")

        let record = try JSONDecoder().decode(
            RemoteImageComparisonDTO.self,
            from: try Data(contentsOf: kept.url)
        )
        XCTAssertEqual(record.old.title, "Before")
        XCTAssertEqual(record.new.title, "composer.png", "an untitled side is named by its file")
        let oldRow = try XCTUnwrap(rows.first { $0.id == record.old.attachmentID })
        let newRow = try XCTUnwrap(rows.first { $0.id == record.new.attachmentID })
        XCTAssertTrue(oldRow.url.path.hasSuffix("Scratch/composer.png"), oldRow.url.path)
        XCTAssertEqual(newRow.url.lastPathComponent, "composer.png")
        XCTAssertEqual(kept.comparedAttachmentIDs?.old, oldRow.id)
        XCTAssertEqual(kept.comparedAttachmentIDs?.new, newRow.id)
        XCTAssertEqual(try structuredContent(of: first)["target_kind"] as? String, "attachment")

        // The same pair again refreshes its one row rather than stacking a second.
        let again = await compare(old, new, in: session, oldTitle: "Baseline")
        XCTAssertFalse(again.isError, again.text)
        let comparisons = attachments.attachments(for: session).filter { $0.kind == .comparison }
        XCTAssertEqual(comparisons.map(\.id), [kept.id])
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteImageComparisonDTO.self,
                from: try Data(contentsOf: try XCTUnwrap(comparisons.first).url)
            ).old.title,
            "Baseline"
        )
    }

    func testDifferentlyNamedSidesNameBoth() {
        XCTAssertEqual(
            ComparisonKeepingService.name(
                old: URL(fileURLWithPath: "/tmp/a/Icon.swift"),
                new: URL(fileURLWithPath: "/repo/Icon.swift")
            ),
            "Icon.swift"
        )
        XCTAssertEqual(
            ComparisonKeepingService.name(
                old: URL(fileURLWithPath: "/tmp/old.json"),
                new: URL(fileURLWithPath: "/repo/new.json")
            ),
            "old.json → new.json"
        )
    }

    // MARK: - Helpers

    private func makeSession() throws -> SessionID {
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: root))
        return try XCTUnwrap(ProjectStore.shared.addSession(to: project.id, kind: .codex)).id
    }

    private func write(_ relativePath: String, _ text: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func compare(
        _ old: URL,
        _ new: URL,
        in session: SessionID,
        oldTitle: String? = nil
    ) async -> MCPToolResult {
        await withCheckedContinuation { continuation in
            coordinator.handle(
                .displayCompareFiles(.init(oldPath: old.path, newPath: new.path, oldTitle: oldTitle)),
                for: session
            ) { continuation.resume(returning: $0) }
        }
    }

    /// A small solid picture, drawn through a context so the bitmap really holds the colour.
    private func writePNG(_ relativePath: String, color: NSColor) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        NSGraphicsContext.restoreGraphicsState()
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    private func structuredContent(of result: MCPToolResult) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result))
        let envelope = try XCTUnwrap(object as? [String: Any])
        return try XCTUnwrap(envelope["structuredContent"] as? [String: Any])
    }

    private func closeTabs(for session: SessionID) {
        for tab in pane.tabs(for: session) {
            _ = pane.closeTab(id: tab.id, for: session)
        }
    }
}
