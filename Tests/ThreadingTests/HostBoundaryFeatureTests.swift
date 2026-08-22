import AppKit
import ThreadingExtensionKit
import XCTest

@testable import Threading

@MainActor
final class HostCommandPlaneTests: XCTestCase {
    private func descriptor(
        id: String,
        title: String,
        shortcut: String? = nil,
        availability: HostCommandDescriptor.Availability = .available
    ) -> HostCommandDescriptor {
        HostCommandDescriptor(
            id: id,
            title: title,
            detail: nil,
            group: "View",
            shortcut: shortcut,
            origin: .builtIn,
            scope: .application,
            risk: .ordinary,
            availability: availability
        )
    }

    func testInvocationUsesStableIdentityAndRechecksAvailability() {
        var available = true
        var invoked: [String] = []
        let plane = HostCommandPlane(
            catalog: {
                [self.descriptor(
                    id: "view.files",
                    title: "Activity",
                    availability: available
                        ? .available
                        : .unavailable(reason: "Select a session first.")
                )]
            },
            invoke: { id in
                invoked.append(id)
                return .invoked(commandID: id)
            }
        )

        XCTAssertEqual(
            plane.invoke(commandID: "view.files"),
            .invoked(commandID: "view.files")
        )
        XCTAssertEqual(invoked, ["view.files"])

        available = false
        XCTAssertEqual(
            plane.invoke(commandID: "view.files"),
            .refused(commandID: "view.files", reason: "Select a session first.")
        )
        XCTAssertEqual(invoked, ["view.files"], "a disabled command must not reach its implementation")
    }

    func testInvocationRefusesACommandRemovedAfterEnumeration() {
        var catalog = [descriptor(id: "extension.example.refresh", title: "Refresh")]
        var invocations = 0
        let plane = HostCommandPlane(
            catalog: { catalog },
            invoke: { id in
                invocations += 1
                return .invoked(commandID: id)
            }
        )

        XCTAssertEqual(plane.commands().map(\.id), ["extension.example.refresh"])
        catalog.removeAll()

        guard case .refused(let id, let reason) = plane.invoke(
            commandID: "extension.example.refresh"
        ) else { return XCTFail("a stale extension command was invoked") }
        XCTAssertEqual(id, "extension.example.refresh")
        XCTAssertFalse(reason.isEmpty)
        XCTAssertEqual(invocations, 0)
    }

    func testHostProjectionRetainsRegistryIdentityMetadataAndResolvedShortcut() throws {
        let registry = CommandRegistry(builtInCommands: [])
        registry.replaceExtensionCommands(
            extensionIdentifier: "com.example.ci",
            extensionName: "CI",
            commands: [
                .init(
                    id: "reset",
                    title: "Reset Build",
                    description: "Drops the current build.",
                    scope: .project,
                    risk: .destructive,
                    defaultShortcut: .init(key: "r", modifiers: [.option, .command])
                )
            ]
        )
        let command = try XCTUnwrap(registry.extensionCommands.first)
        let host = command.hostDescriptor(
            shortcut: command.defaultShortcut?.displayString,
            availability: .available
        )

        XCTAssertEqual(host.id, command.id)
        XCTAssertEqual(host.title, command.title)
        XCTAssertEqual(host.shortcut, command.defaultShortcut?.displayString)
        XCTAssertEqual(host.scope, .project)
        XCTAssertEqual(host.risk, .destructive)
        XCTAssertEqual(
            host.origin,
            .extensionCommand(identifier: "com.example.ci", name: "CI", localID: "reset")
        )
    }

    func testLargeCatalogFilteringIsCappedAndRanked() {
        let commands = (0..<25_000).map { index in
            descriptor(id: "command.\(index)", title: "Command \(index)")
        } + [descriptor(id: "exact", title: "Needle")]

        let results = HostCommandSearch.results(in: commands, matching: "needle")
        XCTAssertEqual(results.map(\.id), ["exact"])
        XCTAssertEqual(
            HostCommandSearch.results(in: commands, matching: "").count,
            HostCommandSearch.maximumResults
        )
    }

    func testPaletteKeyboardSelectionInvokesTheSelectedStableID() {
        var invoked: [String] = []
        let controller = CommandPaletteViewController(
            catalog: {
                [
                    self.descriptor(
                        id: "disabled",
                        title: "Unavailable",
                        availability: .unavailable(reason: "Select a project first.")
                    ),
                    self.descriptor(id: "enabled", title: "Enabled", shortcut: "⇧⌘P")
                ]
            },
            invoke: { id in
                invoked.append(id)
                return .invoked(commandID: id)
            }
        )
        _ = controller.view
        drainMainRunLoop(until: { controller.visibleCommandIDsForTesting.count == 2 })

        XCTAssertEqual(controller.selectedCommandIDForTesting, "disabled")
        controller.moveSelectionForTesting(by: 1)
        XCTAssertEqual(controller.selectedCommandIDForTesting, "enabled")
        controller.confirmSelectionForTesting()
        XCTAssertEqual(invoked, ["enabled"])
    }

    func testPaletteRemovesItsPresentationBeforeInvokingACommand() {
        var isPresentedDuringInvocation: Bool?
        var presentationCheck: (() -> Bool)?
        var dismissalCount = 0
        let controller = CommandPaletteViewController(
            catalog: { [self] in [descriptor(id: "rename", title: "Rename Session")] },
            invoke: { id in
                isPresentedDuringInvocation = presentationCheck?()
                return .invoked(commandID: id)
            }
        )
        presentationCheck = { [weak controller] in
            controller?.isPresentedForTesting == true
        }
        controller.onDismiss = { dismissalCount += 1 }
        let window = makePaletteWindow()
        defer { window.contentView = nil }

        controller.present(in: window)
        drainMainRunLoop(until: { controller.visibleCommandIDsForTesting == ["rename"] })
        XCTAssertTrue(controller.isPresentedForTesting)

        controller.confirmSelectionForTesting()

        XCTAssertEqual(isPresentedDuringInvocation, false)
        XCTAssertFalse(controller.isPresentedForTesting)
        XCTAssertEqual(dismissalCount, 1)
    }

    func testPaletteRestoresItsPresentationAfterDynamicRefusal() {
        var isPresentedDuringInvocation: Bool?
        var presentationCheck: (() -> Bool)?
        var dismissalCount = 0
        let controller = CommandPaletteViewController(
            catalog: { [self] in [descriptor(id: "rename", title: "Rename Session")] },
            invoke: { id in
                isPresentedDuringInvocation = presentationCheck?()
                return .refused(commandID: id, reason: "The session changed.")
            }
        )
        presentationCheck = { [weak controller] in
            controller?.isPresentedForTesting == true
        }
        controller.onDismiss = { dismissalCount += 1 }
        let window = makePaletteWindow()
        defer { window.contentView = nil }

        controller.present(in: window)
        drainMainRunLoop(until: { controller.visibleCommandIDsForTesting == ["rename"] })
        controller.confirmSelectionForTesting()

        XCTAssertEqual(isPresentedDuringInvocation, false)
        XCTAssertTrue(controller.isPresentedForTesting)
        XCTAssertEqual(dismissalCount, 0)

        controller.dismiss()
        XCTAssertEqual(dismissalCount, 1)
    }

    func testOpenPaletteDropsExtensionRowsImmediatelyWhenRegistryRemovesThem() {
        let registry = CommandRegistry(builtInCommands: [])
        registry.replaceExtensionCommands(
            extensionIdentifier: "com.example.live",
            extensionName: "Live",
            commands: [.init(id: "refresh", title: "Refresh")]
        )
        let controller = CommandPaletteViewController(
            catalog: {
                registry.all.map {
                    $0.hostDescriptor(shortcut: nil, availability: .available)
                }
            },
            invoke: { .invoked(commandID: $0) }
        )
        _ = controller.view
        drainMainRunLoop(until: { controller.visibleCommandIDsForTesting.count == 1 })

        registry.removeExtensionCommands(extensionIdentifier: "com.example.live")
        drainMainRunLoop(until: { controller.visibleCommandIDsForTesting.isEmpty })
        XCTAssertTrue(controller.visibleCommandIDsForTesting.isEmpty)
    }

    private func drainMainRunLoop(
        until condition: () -> Bool,
        timeout: TimeInterval = 2
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "asynchronous UI state did not settle")
    }

    private func makePaletteWindow() -> NSWindow {
        let frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSView(frame: frame)
        return window
    }
}

final class WorkspaceFileIndexTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-workspace-files-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        try super.tearDownWithError()
    }

    func testMentionParserCoexistsWithSlashSkillAndOrdinaryAtProse() {
        XCTAssertEqual(
            WorkspaceFileMentionQuery.parse(text: "Review @Sources/App.swift", caretUTF16Offset: 25),
            WorkspaceFileMentionQuery(term: "Sources/App.swift", replacementRange: NSRange(location: 7, length: 18))
        )
        XCTAssertNotNil(WorkspaceFileMentionQuery.parse(text: "@", caretUTF16Offset: 1))
        XCTAssertNil(WorkspaceFileMentionQuery.parse(text: "mail@example.com", caretUTF16Offset: 16))
        XCTAssertNil(WorkspaceFileMentionQuery.parse(text: "/review", caretUTF16Offset: 7))
    }

    func testRankingPrefersExactNameThenNamePrefixAndCapsResults() {
        let paths = [
            "Sources/PromptView.swift",
            "Tests/PromptViewTests.swift",
            "PromptView.swift",
            "docs/promptview-notes.md"
        ] + (0..<200).map { "Generated/PromptView-\($0).swift" }
        let results = WorkspaceFileIndex.rank(paths: paths, query: "PromptView")

        XCTAssertEqual(results.first?.path, "PromptView.swift")
        XCTAssertLessThanOrEqual(results.count, WorkspaceFileSearchDefaults.maximumResults)
        XCTAssertTrue(results.allSatisfy { !$0.path.hasPrefix("/") })
    }

    func testGitRosterIncludesTrackedAndVisibleUntrackedButRespectsIgnores() throws {
        _ = try GitProcess.run(["init", "-q"], in: root)
        try write("Sources/Tracked.swift")
        try write("Notes.txt")
        try write("ignored.log")
        try Data("*.log\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        _ = try GitProcess.run(["add", "Sources/Tracked.swift"], in: root)

        let result = try search(WorkspaceFileIndex(), query: "")
        let paths = Set(result.map(\.path))
        XCTAssertTrue(paths.contains("Sources/Tracked.swift"))
        XCTAssertTrue(paths.contains("Notes.txt"))
        XCTAssertFalse(paths.contains("ignored.log"))
    }

    func testSymlinkEscapingCheckoutIsRefused() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-outside-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("private".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape.txt"),
            withDestinationURL: outside
        )
        let index = WorkspaceFileIndex(loader: { _ in ["escape.txt"] })

        XCTAssertTrue(try search(index, query: "escape").isEmpty)
    }

    func testLargeRepositoryFailsBeforePerPathWorkAndLargeMatchesStayBounded() throws {
        let tooMany = WorkspaceFileIndex(loader: { _ in
            (0...WorkspaceFileSearchDefaults.maximumIndexedPaths).map { "file-\($0)" }
        })
        XCTAssertEqual(
            try searchResult(tooMany, query: ""),
            .failure(.indexTooLarge(limit: WorkspaceFileSearchDefaults.maximumIndexedPaths))
        )

        let ranked = WorkspaceFileIndex.rank(
            paths: (0..<50_000).map { "Sources/Feature-\($0).swift" },
            query: "Feature"
        )
        XCTAssertEqual(ranked.count, WorkspaceFileSearchDefaults.maximumResults)
    }

    func testValidationRefreshesRosterAndReportsADeletedSavedReference() throws {
        _ = try GitProcess.run(["init", "-q"], in: root)
        try write("Sources/Transient.swift")
        let index = WorkspaceFileIndex()
        XCTAssertEqual(try search(index, query: "Transient").map(\.path), ["Sources/Transient.swift"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/Transient.swift"))

        let result = try validate(
            index,
            references: [WorkspaceFileReference(path: "Sources/Transient.swift")]
        )
        guard case .failure(let failure) = result else {
            return XCTFail("a deleted saved reference validated")
        }
        XCTAssertEqual(failure, .fileUnavailable(path: "Sources/Transient.swift"))
    }

    private func write(_ path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(path.utf8).write(to: url)
    }

    private func search(
        _ index: WorkspaceFileIndex,
        query: String
    ) throws -> [WorkspaceFileReference] {
        try searchResult(index, query: query).get()
    }

    private func searchResult(
        _ index: WorkspaceFileIndex,
        query: String
    ) throws -> Result<[WorkspaceFileReference], WorkspaceFileSearchFailure> {
        let done = expectation(description: "workspace file search")
        nonisolated(unsafe) var received: Result<
            [WorkspaceFileReference], WorkspaceFileSearchFailure
        >?
        index.search(root: root, query: query) {
            received = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return try XCTUnwrap(received)
    }

    private func validate(
        _ index: WorkspaceFileIndex,
        references: [WorkspaceFileReference]
    ) throws -> Result<Void, WorkspaceFileSearchFailure> {
        let done = expectation(description: "workspace file validation")
        nonisolated(unsafe) var received: Result<Void, WorkspaceFileSearchFailure>?
        index.validate(root: root, references: references) {
            received = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return try XCTUnwrap(received)
    }
}

@MainActor
final class WorkspaceFileRoutingTests: XCTestCase {
    func testManagedSessionSearchRootIsItsExecutionCheckout() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-routing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let logical = directory.appendingPathComponent("logical", isDirectory: true)
        let execution = directory.appendingPathComponent("managed", isDirectory: true)
        try FileManager.default.createDirectory(at: logical, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: execution, withIntermediateDirectories: true)

        let store = ProjectStore(
            stateManager: StateManager(appSupportDirectory: directory.appendingPathComponent("state")),
            refusesWrites: false
        )
        // `addProject` answers Optional since the store began refusing writes it cannot persist.
        let project = try XCTUnwrap(store.addProject(folderURL: logical))
        let sessionID = SessionID()
        let workspace = ManagedWorkspace(
            repositoryRoot: logical.path,
            sourceCheckoutPath: logical.path,
            worktreeRoot: execution.path,
            executionPath: execution.path,
            targetBranch: "main",
            baseCommit: "0123456789abcdef",
            delivery: .keepForReview,
            publication: nil,
            remoteBranch: nil,
            finalCommit: nil,
            changeRequest: nil,
            remoteBranchState: nil,
            state: .active,
            lastError: nil
        )
        XCTAssertNotNil(store.addSession(
            to: project.id,
            kind: .codex,
            managedWorkspace: workspace,
            id: sessionID
        ))

        XCTAssertEqual(
            store.executionProject(forSessionID: sessionID)?.folderURL.standardizedFileURL,
            execution.standardizedFileURL
        )
        XCTAssertNotEqual(
            store.executionProject(forSessionID: sessionID)?.folderURL.standardizedFileURL,
            logical.standardizedFileURL
        )

        _ = try GitProcess.run(["init", "-q"], in: execution)
        try Data("managed".utf8).write(
            to: execution.appendingPathComponent("ManagedCheckoutOnly.swift")
        )
        try Data("logical".utf8).write(
            to: logical.appendingPathComponent("LogicalCheckoutOnly.swift")
        )

        let plane = WorkspaceFileSearchPlane(rootResolver: { requestedSessionID in
            store.executionProject(forSessionID: requestedSessionID)?.folderURL
        })
        let result: Result<[WorkspaceFileReference], WorkspaceFileSearchFailure> =
            await withCheckedContinuation { continuation in
                plane.search(sessionID: sessionID, query: "CheckoutOnly") {
                    continuation.resume(returning: $0)
                }
            }

        XCTAssertEqual(try result.get().map(\.path), ["ManagedCheckoutOnly.swift"])
    }
}
