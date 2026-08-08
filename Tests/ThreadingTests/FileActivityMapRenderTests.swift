import AppKit
import XCTest
@testable import Threading

/// Draws the file-activity map through the real view and writes each state out as an image —
/// the storybook. The idea stands or falls on whether the picture *reads*: whether a burst of
/// edits in one subsystem is visible as a flare in a region, whether reads and edits tell
/// apart, whether 5,000 files still say anything. None of that is assertable; all of it is
/// visible in a PNG.
///
/// Every story renders in both appearances, and every date is fixed — heat is a function of
/// the clock, so a render against `Date()` would be a picture of when the test ran.
@MainActor
final class FileActivityMapRenderTests: XCTestCase {

    // MARK: - Configuration

    private enum Render {
        /// A display-pane tab's plausible size, and the narrow gutter-strip alternative.
        static let paneSize = CGSize(width: 300, height: 1000)
        static let stripSize = CGSize(width: 56, height: 900)

        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }
    }

    /// One moment, shared by every story. Heat is measured backwards from here.
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private var threadingFiles: [String] {
        get throws {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/FileLists/threading-files.txt")
            try XCTSkipUnless(
                FileManager.default.fileExists(atPath: url.path),
                "Missing file-list fixture. Regenerate with: git ls-files > \(url.path)"
            )
            return try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n").map(String.init)
        }
    }

    // MARK: - Stories

    func testRendersTheStorybook() throws {
        let files = try threadingFiles
        var written = 0

        // At rest: the whole repo as quiet marks, directory runs told apart by shade.
        written += try write(story: "01-resting", size: Render.paneSize, map: FileActivityMap(files: files))

        // Context gathering: the agent has been reading its way through one subsystem.
        var gathering = FileActivityMap(files: files)
        for (offset, path) in files.filter({ $0.hasPrefix("Sources/Threading/UI/Design/") }).enumerated() {
            gathering.record(.read, path: path, at: seconds(2 + offset * 2))
        }
        gathering.record(.read, path: "CLAUDE.md", at: seconds(70))
        gathering.record(.read, path: "docs/THEME_BOUNDARY.md", at: seconds(65))
        written += try write(story: "02-context-gathering", size: Render.paneSize, map: gathering)

        // An edit burst: older reads scattered across the repo, fresh edits concentrated in
        // one region, one file created mid-session. The story the map exists to tell.
        var burst = FileActivityMap(files: files)
        for (offset, path) in files.enumerated() where offset.isMultiple(of: 17) {
            burst.record(.read, path: path, at: seconds(40 + offset % 50))
        }
        for (offset, path) in files.filter({ $0.hasPrefix("Sources/Threading/Core/Agent/") }).enumerated() {
            burst.record(.read, path: path, at: seconds(25 + offset))
            if offset.isMultiple(of: 2) {
                burst.record(.edit, path: path, at: seconds(1 + offset))
            }
        }
        burst.record(.edit, path: "Sources/Threading/Core/Agent/BrandNewFile.swift", at: seconds(3))
        written += try write(story: "03-edit-burst", size: Render.paneSize, map: burst)

        // The decay ladder: one directory touched at increasing ages, so the fade itself is
        // reviewable — the difference between fresh, cooling, and residual.
        var decay = FileActivityMap(files: files)
        let ladder = files.filter { $0.hasPrefix("Sources/Threading/UI/Preferences/") }
        for (offset, path) in ladder.enumerated() {
            decay.record(.edit, path: path, at: seconds(offset * 15))
        }
        written += try write(story: "04-decay-ladder", size: Render.paneSize, map: decay)

        // The gutter shape: the same edit burst in the 56pt strip a right sidebar would get.
        written += try write(story: "05-gutter-strip", size: Render.stripSize, map: burst)

        // Hover: the one interaction, naming the file under the pointer.
        let hovered = files.firstIndex { $0.hasPrefix("Sources/Threading/Core/Agent/") } ?? 0
        written += try write(
            story: "06-hover", size: Render.paneSize, map: burst,
            configure: { $0.hover(at: hovered) }
        )

        XCTAssertEqual(written, 12, "Every story should render in both appearances")
        print("Rendered file-activity storybook to \(Render.directory.path)")
    }

    func testRendersALargeRepoWithoutDroppingTheTail() throws {
        // inristo-scale: 4,966 files. The promise is the whole project, so the layout tightens
        // rather than truncating — this render is where "does 1pt per file still read" is
        // answered.
        var files: [String] = []
        let tops = ["app", "core", "docs", "lib", "modules", "pkg", "services", "tests", "tools", "web"]
        for top in tops {
            for sub in ["alpha", "bravo", "charlie", "delta", "echo"] {
                for index in 0..<100 {
                    files.append("\(top)/\(sub)/file-\(String(format: "%03d", index)).swift")
                }
            }
        }
        files.removeLast(34)

        var map = FileActivityMap(files: files)
        for (offset, path) in files.enumerated() {
            if path.hasPrefix("modules/charlie/") {
                map.record(.edit, path: path, at: seconds(1 + offset % 30))
            } else if path.hasPrefix("web/alpha/") {
                map.record(.read, path: path, at: seconds(10 + offset % 60))
            } else if offset.isMultiple(of: 231) {
                map.record(.read, path: path, at: seconds(30 + offset % 80))
            }
        }

        let written = try write(story: "07-large-repo", size: Render.paneSize, map: map)
        XCTAssertEqual(written, 2)
    }

    func testRendersARealConversationsTouches() throws {
        // The fixture story: a real (scrubbed) edit-heavy Claude conversation, classified by
        // the same code the live wiring would use, its touches replayed at a steady cadence
        // ending at the shared clock. Filler files pad the universe so the touched ones sit
        // in a repo rather than alone.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Transcripts/claude-edit-heavy.jsonl")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path))

        let (events, _) = TranscriptReplay.read(at: url, kind: .claude)
        var touches: [(kind: FileActivityMap.Kind, path: String)] = []
        for event in events {
            guard case .assistantMessage(let blocks) = event else { continue }
            for block in blocks {
                guard case .toolUse(_, let tool, let input) = block else { continue }
                touches.append(contentsOf: FileActivityMap.touches(tool: tool, input: input))
            }
        }
        try XCTSkipUnless(!touches.isEmpty, "Fixture no longer carries file touches")

        let root = commonRoot(of: touches.map(\.path))
        var universe = Set(touches.map { relative($0.path, root: root) })
        for path in universe {
            let directory = path.split(separator: "/").dropLast().joined(separator: "/")
            for index in 0..<18 {
                universe.insert("\(directory)/\(directory.isEmpty ? "" : "")pad-\(String(format: "%02d", index)).md")
            }
        }
        for top in ["assets", "notes", "spec"] {
            for index in 0..<25 { universe.insert("\(top)/pad-\(String(format: "%02d", index)).md") }
        }

        var map = FileActivityMap(files: Array(universe), root: root)
        for (offset, touch) in touches.enumerated() {
            map.record(touch.kind, path: touch.path, at: seconds((touches.count - offset) * 4))
        }

        let written = try write(story: "08-fixture-conversation", size: Render.paneSize, map: map)
        XCTAssertEqual(written, 2)
    }

    func testRendersAgentAndProjectWorkSummariesAcrossThemeFamilies() throws {
        let files = (0..<12_000).map {
            "Sources/Area\($0 / 300)/Feature\($0 / 30)/file-\($0).swift"
        }
        let atlas = RepositoryFileAtlas(files: files)
        let firstID = SessionID()
        let secondID = SessionID()
        var first = AgentSessionWorkTrace()
        first.sessionTitle = "Refactor sidebar"
        first.agentLabel = "Codex"
        var second = AgentSessionWorkTrace()
        second.sessionTitle = "Harden tests"
        second.agentLabel = "Claude"

        for (offset, index) in stride(from: 900, through: 2_700, by: 17).enumerated() {
            _ = first.recordFile(.read, path: files[index], root: nil, at: seconds(index % 80))
            if offset.isMultiple(of: 4) {
                _ = first.recordFile(.edit, path: files[index], root: nil, at: seconds(index % 40))
            }
        }
        for index in stride(from: 2_100, through: 4_500, by: 23) {
            _ = second.recordFile(.edit, path: files[index], root: nil, at: seconds(index % 75))
        }
        for index in 0..<18 {
            first.recordAction(
                category: index.isMultiple(of: 3) ? .shell : .filesystem,
                operation: index.isMultiple(of: 3) ? "exec" : "Read",
                at: seconds(18 - index),
                sessionID: firstID
            )
            second.recordAction(
                category: index.isMultiple(of: 4) ? .subagent : .network,
                operation: index.isMultiple(of: 4) ? "Agent" : "WebSearch",
                at: seconds(20 - index),
                sessionID: secondID
            )
        }

        let traces = [firstID: first, secondID: second]
        let session = AgentWorkPresentation.session(
            first, sessionID: firstID, atlas: atlas, detailed: true
        )
        let project = AgentWorkPresentation.project(
            AgentProjectWorkAggregate(traces: traces),
            traces: traces,
            projectID: ProjectID(),
            atlas: atlas,
            detailed: true
        )

        let previous = AppThemeLibrary.current
        defer { AppThemeLibrary.apply(previous) }
        let variants: [(String, AppTheme, NSAppearance.Name)] = [
            ("system-light", .system, .aqua),
            ("system-dark", .system, .darkAqua),
            ("cyberpunk", AppThemeStyles.cyberpunk, .darkAqua),
            ("swiss", AppThemeStyles.swissMinimalist, .aqua)
        ]
        var written = 0
        for (name, theme, appearance) in variants {
            AppThemeLibrary.apply(theme)
            written += try writeSummary(
                story: "09-session-summary-\(name)",
                presentation: session,
                appearanceName: appearance
            )
            written += try writeSummary(
                story: "10-project-summary-\(name)",
                presentation: project,
                appearanceName: appearance
            )
        }
        XCTAssertEqual(written, 8)
    }

    // MARK: - Harness

    private func seconds(_ age: Int) -> Date {
        now.addingTimeInterval(-TimeInterval(age))
    }

    private func commonRoot(of paths: [String]) -> String? {
        let absolute = paths.filter { $0.hasPrefix("/") }
        guard var components = absolute.first.map({ $0.split(separator: "/").dropLast() }) else {
            return nil
        }
        for path in absolute.dropFirst() {
            let other = path.split(separator: "/")
            while !components.isEmpty, !other.starts(with: components) {
                components = components.dropLast()
            }
        }
        return components.isEmpty ? nil : "/" + components.joined(separator: "/")
    }

    private func relative(_ path: String, root: String?) -> String {
        guard let root, path.hasPrefix(root + "/") else { return path }
        return String(path.dropFirst(root.count + 1))
    }

    /// Renders one story in both appearances; returns how many images were written.
    private func write(
        story: String,
        size: CGSize,
        map: FileActivityMap,
        configure: ((FileActivityMapView) -> Void)? = nil
    ) throws -> Int {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var written = 0
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = NSAppearance(named: appearanceName)

            var data: Data?
            let render = {
                let view = FileActivityMapView(
                    frame: NSRect(origin: .zero, size: size)
                )
                view.appearance = appearance
                view.clock = { self.now }
                view.setMap(map)
                configure?(view)
                AppThemeRefresh.repaint(view)

                view.wantsLayer = true
                view.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                data = rep.representation(using: .png, properties: [:])
            }

            if #available(macOS 11.0, *) {
                appearance?.performAsCurrentDrawingAppearance(render)
            } else {
                render()
            }

            let image = try XCTUnwrap(data, "Failed to render \(story) in \(name)")
            try image.write(to: directory.appendingPathComponent("activity-\(story)-\(name).png"))
            written += 1
        }
        return written
    }

    private func writeSummary(
        story: String,
        presentation: AgentWorkPresentation,
        appearanceName: NSAppearance.Name
    ) throws -> Int {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
        var data: Data?
        appearance.performAsCurrentDrawingAppearance {
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
            host.appearance = appearance
            host.wantsLayer = true
            host.layer?.backgroundColor = Design.Surface.elevated.cgColor

            let summary = AgentWorkSummaryView()
            summary.setClock { self.now }
            summary.setPresentation(presentation)
            host.addSubview(summary)
            NSLayoutConstraint.activate([
                summary.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: Design.Spacing.inset),
                summary.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -Design.Spacing.inset),
                summary.topAnchor.constraint(equalTo: host.topAnchor, constant: Design.Spacing.inset)
            ])
            AppThemeRefresh.repaint(host)
            host.layoutSubtreeIfNeeded()

            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            data = rep.representation(using: .png, properties: [:])
        }
        let image = try XCTUnwrap(data)
        try image.write(to: directory.appendingPathComponent("activity-\(story).png"))
        return 1
    }
}
