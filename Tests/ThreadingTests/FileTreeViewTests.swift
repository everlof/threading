import AppKit
import XCTest
@testable import Threading

@MainActor
final class FileTreeViewTests: XCTestCase {

    func testSemanticFileKindsCoverTheTreeWithoutReadingTheirContents() {
        let root = URL(fileURLWithPath: "/tmp/project")
        let cases: [(String, ThemedFileIconView.Kind)] = [
            ("Feature.swift", .source),
            ("README", .text),
            ("theme.json", .data),
            ("preview.png", .image),
            ("episode.mp3", .audio),
            ("demo.mov", .video),
            ("sources.zip", .archive),
            ("Threading.app", .package),
            ("release.sh", .executable),
            ("unknown.thing", .generic)
        ]

        for (name, expected) in cases {
            XCTAssertEqual(
                ThemedFileIconView.kind(for: root.appendingPathComponent(name), isDirectory: false),
                expected,
                name
            )
        }
        XCTAssertEqual(ThemedFileIconView.kind(for: root, isDirectory: true), .directory)
    }

    func testSystemKeepsFinderArtworkAndAuthoredThemesAvoidLoadingIt() {
        let previous = AppThemeLibrary.current
        defer { AppThemeLibrary.apply(previous) }
        let url = URL(fileURLWithPath: "/tmp/Example.swift")

        AppThemeLibrary.apply(.system)
        let system = ThemedFileIconView(url: url, isDirectory: false)
        XCTAssertEqual(system.renderingMode, .native)
        XCTAssertTrue(system.hasLoadedNativeArtwork)

        AppThemeLibrary.apply(AppThemeStyles.neoBrutalism)
        let authored = ThemedFileIconView(url: url, isDirectory: false)
        XCTAssertEqual(system.renderingMode, .themed, "a live theme switch kept Finder artwork")
        XCTAssertEqual(authored.renderingMode, .themed)
        XCTAssertFalse(
            authored.hasLoadedNativeArtwork,
            "an authored theme paid LaunchServices for artwork it does not draw"
        )

        AppThemeLibrary.apply(.system)
        XCTAssertEqual(authored.renderingMode, .native)
        XCTAssertTrue(authored.hasLoadedNativeArtwork, "returning to System had no native icon")
    }

    func testRefreshPreservesNestedDisclosureByStablePathIdentity() throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-file-refresh-\(UUID().uuidString)", isDirectory: true)
        let sources = fixture.appendingPathComponent("Sources", isDirectory: true)
        let feature = sources.appendingPathComponent("Feature", isDirectory: true)
        try FileManager.default.createDirectory(at: feature, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try makeFile(named: "One.swift", in: feature)

        let controller = FileTreeViewController(folderPath: fixture.path)
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 420, height: 300)
        controller.refresh()
        controller.view.layoutSubtreeIfNeeded()

        let outline = try XCTUnwrap(Self.firstDescendant(NSOutlineView.self, in: controller.view))
        let sourcesBefore = try XCTUnwrap(Self.node(at: sources, in: outline))
        outline.expandItem(sourcesBefore)
        let featureBefore = try XCTUnwrap(Self.node(at: feature, in: outline))
        outline.expandItem(featureBefore)
        XCTAssertEqual(outline.numberOfRows, 3)

        try makeFile(named: "Two.swift", in: feature)
        controller.refresh()
        controller.view.layoutSubtreeIfNeeded()

        let sourcesAfter = try XCTUnwrap(Self.node(at: sources, in: outline))
        let featureAfter = try XCTUnwrap(Self.node(at: feature, in: outline))
        XCTAssertTrue(sourcesAfter === sourcesBefore)
        XCTAssertTrue(featureAfter === featureBefore)
        XCTAssertTrue(outline.isItemExpanded(sourcesAfter))
        XCTAssertTrue(outline.isItemExpanded(featureAfter))
        XCTAssertEqual(outline.numberOfRows, 4)
        XCTAssertNotNil(Self.node(at: feature.appendingPathComponent("Two.swift"), in: outline))
    }

    func testActivityTreeShowsFolderAndFileReadEditCounts() throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-activity-tree-\(UUID().uuidString)", isDirectory: true)
        let sources = fixture.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try makeFile(named: "One.swift", in: sources)
        try makeFile(named: "Two.swift", in: sources)

        let projectID = ProjectID()
        let sessionID = SessionID()
        let target = AgentWorkTarget.session(
            projectID: projectID,
            sessionID: sessionID,
            rootPath: fixture.path,
            detailed: true
        )
        let items = [
            "Sources": treeItem("Sources", directory: true, reads: 3, edits: 1, files: 2),
            "Sources/One.swift": treeItem(
                "Sources/One.swift", directory: false, reads: 2, edits: 1, files: 1
            ),
            "Sources/Two.swift": treeItem(
                "Sources/Two.swift", directory: false, reads: 1, edits: 0, files: 1
            )
        ]
        var requestedPaths: Set<String> = []
        let controller = FileTreeViewController(
            folderPath: fixture.path,
            workTarget: target,
            activityLookup: { _, paths, completion in
                requestedPaths.formUnion(paths.map(\.relativePath))
                completion(Dictionary(uniqueKeysWithValues: paths.compactMap { path in
                    items[path.relativePath].map { (path.relativePath, $0) }
                }))
            }
        )
        _ = controller.view
        let host = ThemedSurfaceView()
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 420)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: host.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            controller.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
        let window = NSWindow(
            contentRect: host.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        let summary = try XCTUnwrap(Self.firstDescendant(AgentWorkSummaryView.self, in: host))
        summary.setPresentation(activityPresentation(sessionID: sessionID))
        controller.refresh()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))

        let outline = try XCTUnwrap(Self.firstDescendant(NSOutlineView.self, in: host))
        outline.expandItem(try XCTUnwrap(Self.node(at: sources, in: outline)))
        host.layoutSubtreeIfNeeded()
        for row in 0..<outline.numberOfRows {
            _ = outline.view(atColumn: 0, row: row, makeIfNecessary: true)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        host.layoutSubtreeIfNeeded()

        let labels = Set(
            Self.descendants(NSTextField.self, in: host).map(\.stringValue)
        )
        XCTAssertEqual(
            requestedPaths,
            ["Sources", "Sources/One.swift", "Sources/Two.swift"]
        )
        XCTAssertTrue(labels.contains("2 files · R 3 · E 1"), "\(labels.sorted())")
        XCTAssertTrue(labels.contains("R 2 · E 1"), "\(labels.sorted())")
        XCTAssertTrue(labels.contains("R 1 · E 0"), "\(labels.sorted())")
        let spokenActivity = Set(
            Self.descendants(NSTextField.self, in: host)
                .filter { $0.accessibilityIdentifier() == "activity.file-status" }
                .compactMap { $0.accessibilityLabel() }
        )
        XCTAssertTrue(spokenActivity.contains("2 files, 3 reads, 1 edits"))
        XCTAssertTrue(spokenActivity.contains("2 reads, 1 edits"))
        XCTAssertTrue(spokenActivity.contains("1 reads, 0 edits"))
        XCTAssertEqual(summary.accessibilityIdentifier(), "activity.summary")
        try writeActivityRender(host)
    }

    /// The same ordinary tree under the platform identity and three deliberately different
    /// authored materials. `THREADING_RENDER_OUT` redirects the PNGs for visual review.
    func testRendersFileIconsAcrossContrastingThemes() throws {
        let previous = AppThemeLibrary.current
        defer { AppThemeLibrary.apply(previous) }
        let fixture = try makeVisualFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let output = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("ThreadingRenders", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        for theme in [
            AppTheme.system,
            AppThemeStyles.neoBrutalism,
            AppThemeStyles.cyberpunk,
            AppThemeStyles.claymorphism
        ] {
            AppThemeLibrary.apply(theme)
            let image = try XCTUnwrap(renderedTree(at: fixture, theme: theme))
            XCTAssertGreaterThan(image.count, 1_000, "\(theme.name) rendered an empty fixture")
            try image.write(
                to: output.appendingPathComponent("file-tree-icons-\(theme.id.rawValue).png")
            )
        }
    }

    /// Opt-in production-controller workload. The fixture is created before the clock starts,
    /// so the measurements cover Threading's enumeration, model, outline and row-rendering path
    /// rather than the cost of manufacturing thousands of files for the test.
    func testStressFileTreeWhenEnabled() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["THREADING_FILE_TREE_STRESS"] == "1",
            "Set THREADING_FILE_TREE_STRESS=1 to run the file-tree sweep."
        )

        let environment = ProcessInfo.processInfo.environment
        let entryCount = environment["THREADING_FILE_TREE_STRESS_ENTRIES"]
            .flatMap(Int.init)
            .flatMap { $0 > 0 ? $0 : nil }
            ?? 5_000
        let shape = StressShape(
            rawValue: environment["THREADING_FILE_TREE_STRESS_SHAPE"] ?? "flat"
        ) ?? .flat
        let themeID = AppThemeID(environment["THREADING_FILE_TREE_STRESS_THEME"] ?? "system")
        let theme = try XCTUnwrap(
            AppThemeLibrary.theme(withID: themeID),
            "Unknown stress theme \(themeID.rawValue)"
        )
        _ = NSApplication.shared
        let previousTheme = AppThemeLibrary.current
        AppThemeLibrary.apply(theme)
        defer { AppThemeLibrary.apply(previousTheme) }
        let fixture = try makeFixture(shape: shape, entryCount: entryCount)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let baselineMemory = Self.physicalFootprintBytes()
        let controller = FileTreeViewController(folderPath: fixture.path)
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 420, height: 700)

        let refreshStarted = DispatchTime.now().uptimeNanoseconds
        controller.refresh()
        let refreshEnded = DispatchTime.now().uptimeNanoseconds
        controller.view.layoutSubtreeIfNeeded()
        let layoutEnded = DispatchTime.now().uptimeNanoseconds

        let outline = try XCTUnwrap(Self.firstDescendant(NSOutlineView.self, in: controller.view))
        let rootRows = outline.numberOfRows
        let disclosureStarted = DispatchTime.now().uptimeNanoseconds
        if shape == .expanded {
            let directories = (0..<rootRows).compactMap { outline.item(atRow: $0) }
            directories.forEach { outline.expandItem($0) }
            controller.view.layoutSubtreeIfNeeded()
        }
        let disclosureEnded = DispatchTime.now().uptimeNanoseconds

        let expandedRows = outline.numberOfRows
        let lastRow = expandedRows - 1
        XCTAssertGreaterThanOrEqual(lastRow, 0)
        let jumpStarted = DispatchTime.now().uptimeNanoseconds
        outline.scrollRowToVisible(lastRow)
        controller.view.layoutSubtreeIfNeeded()
        let jumpEnded = DispatchTime.now().uptimeNanoseconds
        let lastNodeBeforeRefresh = try XCTUnwrap(outline.item(atRow: lastRow) as? FileNode)

        let hotRefreshStarted = DispatchTime.now().uptimeNanoseconds
        controller.refresh()
        controller.view.layoutSubtreeIfNeeded()
        let hotRefreshEnded = DispatchTime.now().uptimeNanoseconds
        let rowsAfterRefresh = outline.numberOfRows
        let lastNodeAfterRefresh = try XCTUnwrap(outline.item(atRow: lastRow) as? FileNode)
        XCTAssertTrue(
            lastNodeAfterRefresh === lastNodeBeforeRefresh,
            "hot refresh replaced the exact final file"
        )
        XCTAssertTrue(
            NSLocationInRange(lastRow, outline.rows(in: outline.visibleRect)),
            "hot refresh moved the viewport away from the exact final file"
        )
        if shape == .expanded {
            XCTAssertEqual(
                rowsAfterRefresh,
                expandedRows,
                "hot refresh lost disclosure state or an addressable row"
            )
        }

        let visible = outline.rows(in: outline.visibleRect)
        let visibleCells = visible.location == NSNotFound ? 0 : visible.length
        let memoryDelta = Self.physicalFootprintBytes().saturatingSubtract(baselineMemory)
        print(
            "THREADING_PERF file-tree "
                + "theme=\(theme.id.rawValue) shape=\(shape.rawValue) "
                + "entries=\(entryCount) root_rows=\(rootRows) "
                + "expanded_rows=\(expandedRows) rows_after_refresh=\(rowsAfterRefresh) "
                + "visible_cells=\(visibleCells) "
                + "refresh_ms=\(Self.milliseconds(refreshEnded - refreshStarted)) "
                + "layout_ms=\(Self.milliseconds(layoutEnded - refreshEnded)) "
                + "disclosure_ms=\(Self.milliseconds(disclosureEnded - disclosureStarted)) "
                + "jump_ms=\(Self.milliseconds(jumpEnded - jumpStarted)) "
                + "hot_refresh_ms=\(Self.milliseconds(hotRefreshEnded - hotRefreshStarted)) "
                + "footprint_delta_mb=\(Self.megabytes(memoryDelta))"
        )
    }

    private enum StressShape: String {
        case flat
        case expanded
    }

    private func makeFixture(shape: StressShape, entryCount: Int) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-file-tree-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        switch shape {
        case .flat:
            for index in 0..<entryCount {
                try makeFile(index: index, in: root)
            }
        case .expanded:
            let directoryCount = min(100, max(1, Int(Double(entryCount).squareRoot())))
            var made = 0
            for directoryIndex in 0..<directoryCount where made < entryCount {
                let directory = root.appendingPathComponent(
                    String(format: "directory-%04d", directoryIndex),
                    isDirectory: true
                )
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: false
                )
                let remainingDirectories = directoryCount - directoryIndex
                let inDirectory = Int(ceil(Double(entryCount - made) / Double(remainingDirectories)))
                for _ in 0..<inDirectory where made < entryCount {
                    try makeFile(index: made, in: directory)
                    made += 1
                }
            }
        }
        return root
    }

    private func makeVisualFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-file-icons-\(UUID().uuidString)", isDirectory: true)
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        for name in [
            "Application.swift", "README", "theme.json", "preview.png", "episode.mp3",
            "demo.mov", "sources.zip", "Threading.app", "release.sh", "unknown.thing"
        ] {
            let parent = name == "Application.swift" ? sources : root
            guard FileManager.default.createFile(
                atPath: parent.appendingPathComponent(name).path,
                contents: nil
            ) else { throw CocoaError(.fileWriteUnknown) }
        }
        return root
    }

    private func renderedTree(at fixture: URL, theme: AppTheme) throws -> Data? {
        let controller = FileTreeViewController(folderPath: fixture.path)
        _ = controller.view
        let host = ThemedSurfaceView()
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 260)
        host.applySurface(fill: Design.Surface.background, radius: .fixed(0))
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: host.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            controller.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])

        let window = NSWindow(
            contentRect: host.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = theme.mode.appearance ?? NSAppearance(named: .aqua)
        window.contentView = host
        controller.refresh()
        host.layoutSubtreeIfNeeded()

        let outline = try XCTUnwrap(Self.firstDescendant(NSOutlineView.self, in: host))
        outline.expandItem(outline.item(atRow: 0))
        host.layoutSubtreeIfNeeded()

        let icons = Self.descendants(ThemedFileIconView.self, in: host)
        XCTAssertGreaterThanOrEqual(icons.count, 11)
        let expected: ThemedFileIconView.RenderingMode = theme.id == .system ? .native : .themed
        XCTAssertTrue(icons.allSatisfy { $0.renderingMode == expected })
        if expected == .themed {
            XCTAssertTrue(icons.allSatisfy { !$0.hasLoadedNativeArtwork })
        }

        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }

    private func makeFile(index: Int, in directory: URL) throws {
        let extensions = ["swift", "md", "json", "png", "zip", "txt"]
        let name = String(format: "file-%06d.%@", index, extensions[index % extensions.count])
        try makeFile(named: name, in: directory)
    }

    private func makeFile(named name: String, in directory: URL) throws {
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func treeItem(
        _ path: String,
        directory: Bool,
        reads: Int,
        edits: Int,
        files: Int
    ) -> AgentWorkTreeItem {
        var work = AgentFileWork()
        for _ in 0..<reads { work.record(.read, at: .distantPast) }
        for _ in 0..<edits { work.record(.edit, at: .distantPast) }
        return AgentWorkTreeItem(
            relativePath: path,
            isDirectory: directory,
            work: work,
            touchedFileCount: files,
            contributorCount: 1
        )
    }

    private func activityPresentation(sessionID: SessionID) -> AgentWorkPresentation {
        let files = ["Sources/One.swift", "Sources/Two.swift"]
        var trace = AgentSessionWorkTrace()
        trace.sessionTitle = "Build Activity pane"
        trace.agentLabel = "Codex"
        _ = trace.recordFile(.read, path: files[0], root: nil, at: Date())
        _ = trace.recordFile(.read, path: files[0], root: nil, at: Date())
        _ = trace.recordFile(.edit, path: files[0], root: nil, at: Date())
        _ = trace.recordFile(.read, path: files[1], root: nil, at: Date())
        trace.recordAction(
            category: .shell,
            operation: "test",
            at: Date(),
            sessionID: sessionID
        )
        return AgentWorkPresentation.session(
            trace,
            sessionID: sessionID,
            atlas: RepositoryFileAtlas(files: files),
            detailed: true
        )
    }

    private func writeActivityRender(_ view: NSView) throws {
        let directory = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("ThreadingRenders", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent("activity-filesystem-tree.png"))
        print("Rendered Activity tree to \(directory.path)")
    }

    private static func firstDescendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { firstDescendant(type, in: $0) }.first
    }

    private static func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
    }

    private static func node(at url: URL, in outline: NSOutlineView) -> FileNode? {
        (0..<outline.numberOfRows)
            .compactMap { outline.item(atRow: $0) as? FileNode }
            .first { $0.url.standardizedFileURL == url.standardizedFileURL }
    }

    private static func physicalFootprintBytes() -> UInt64 {
        let pid = Int32(ProcessInfo.processInfo.processIdentifier)
        return ProcessUtility.getResourceUsage(forPid: pid)?.memoryBytes ?? 0
    }

    private static func milliseconds(_ nanoseconds: UInt64) -> String {
        String(format: "%.3f", Double(nanoseconds) / 1_000_000)
    }

    private static func megabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_048_576)
    }
}

private extension UInt64 {
    func saturatingSubtract(_ other: UInt64) -> UInt64 {
        self >= other ? self - other : 0
    }
}
