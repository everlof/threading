import AppKit
import XCTest
@testable import Skalman

/// Draws review-pane file rows through the real views and writes them out as images.
///
/// `ConversationRenderTests`' reason applies here twice over: syntax highlighting is a claim
/// about *colour on a coloured wash*, and no assertion about token ranges can say whether an
/// orange string is legible on a green added line, in both appearances. The layout assertions
/// come along for free.
final class GitReviewRenderTests: XCTestCase {

    // MARK: - Configuration

    private enum Render {
        /// The display pane's real working width, the same measure the conversation renders use.
        static let width: CGFloat = 720

        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["SKALMAN_RENDER_OUT"] {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("SkalmanRenders", isDirectory: true)
        }
    }

    /// A diff carrying one of everything the highlighter has an opinion about: keywords, a
    /// type, a string with an escape, numbers, both comment shapes, and a line that is only
    /// context — plus a second file in a language whose comment marker is `#`.
    private let fixture = """
    diff --git a/Sources/Skalman/Core/Agent/Runner.swift b/Sources/Skalman/Core/Agent/Runner.swift
    index 1111111..2222222 100644
    --- a/Sources/Skalman/Core/Agent/Runner.swift
    +++ b/Sources/Skalman/Core/Agent/Runner.swift
    @@ -12,9 +12,11 @@ extension Runner {
         /// Runs the agent and returns its exit code.
         @discardableResult
    -    func run(_ arguments: [String], timeout: Double = 15) throws -> Int32 {
    -        let process = Process()
    -        process.arguments = arguments
    +    func run(_ arguments: [String], timeout: Double = 30.5) throws -> Int32 {
    +        let process = Process()  /* one child per turn */
    +        process.arguments = ["--no-optional-locks"] + arguments
    +        process.environment["LC_ALL"] = "C"
             guard timeout > 0 else { throw Failure.timedOut }
    -        return 0
    +        return try withExtendedLifetime(process) { 0x1F }
         }
     }
    diff --git a/scripts/release.py b/scripts/release.py
    index 3333333..4444444 100644
    --- a/scripts/release.py
    +++ b/scripts/release.py
    @@ -1,4 +1,4 @@
     # Cuts a release.
    -def bump(version: str) -> str:
    -    return f"{version}-rc1"
    +def bump(version: str, channel: str = "beta") -> str:
    +    return f"{version}-{channel}.2"
    """

    /// A change whose lines run far past any pane. This is the only shape that tells the two
    /// wrap modes apart — anything that fits draws identically either way.
    private let longLineFixture = """
    diff --git a/Sources/Skalman/Core/Agent/AgentLauncher.swift b/Sources/Skalman/Core/Agent/AgentLauncher.swift
    index 5555555..6666666 100644
    --- a/Sources/Skalman/Core/Agent/AgentLauncher.swift
    +++ b/Sources/Skalman/Core/Agent/AgentLauncher.swift
    @@ -3,3 +3,3 @@ enum AgentLauncher {
         static func claudeCommand(for session: AgentSession) -> [String] {
    -        return ["claude", "--session-id", session.identifier, "--allowedTools", "mcp__skalman__*", "--mcp-config", configurationPath, "--settings", settingsPath, "--append-system-prompt", promptPath]
    +        return ["claude", "--session-id", session.identifier, "--allowedTools", "mcp__skalman__*", "--mcp-config", configurationPath, "--settings", settingsPath, "--append-system-prompt", promptPath, "--fork-session", "--include-hook-events", "--permission-prompt-tool", brokerPath]
         }
     }
    """

    // MARK: - Images

    func testRendersHighlightedFileRowsInBothAppearances() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let files = GitDiffParser.files(fromUnifiedDiff: fixture)
        XCTAssertEqual(files.count, 2, "fixture should parse into two files")

        var written: [String] = []
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let data = try XCTUnwrap(image(of: files, appearance: appearanceName), "failed to render \(name)")
            let url = directory.appendingPathComponent("git-review-highlight-\(name).png")
            try data.write(to: url)
            written.append(url.lastPathComponent)
        }

        print("Rendered \(written.count) review diffs to \(directory.path)")
        XCTAssertEqual(written.count, 2)
    }

    func testRendersTheCommitGraphInBothAppearances() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let data = try XCTUnwrap(
                image(ofCommits: Self.history, appearance: appearanceName),
                "failed to render \(name)"
            )
            try data.write(to: directory.appendingPathComponent("git-review-graph-\(name).png"))
        }

        print("Rendered the commit graph to \(directory.path)")
    }

    /// A history with the shapes a rail exists to show: a merge fanning out, a side branch
    /// running beside the trunk, a converging pair, and refs on the tip.
    private static let history: [GitCommitSummary] = {
        func commit(
            _ hash: String,
            _ subject: String,
            parents: [String],
            refs: [String] = [],
            added: Int = 0,
            removed: Int = 0
        ) -> GitCommitSummary {
            GitCommitSummary(
                hash: hash,
                shortHash: String(hash.prefix(7)),
                subject: subject,
                author: "David Everlöf",
                date: Date(timeIntervalSinceNow: -3600 * Double(hash.count)),
                added: added,
                removed: removed,
                parents: parents,
                refs: refs
            )
        }

        return [
            commit("a11111111", "Merge branch 'review-graph'", parents: ["b22222222", "c33333333"],
                   refs: ["HEAD", "main", "origin/main"], added: 0, removed: 0),
            commit("b22222222", "Give the history list a rail", parents: ["d44444444"], added: 210, removed: 18),
            commit("c33333333", "Lane assignment for merges", parents: ["e55555555"], added: 96, removed: 4),
            commit("d44444444", "Watch the checkout with FSEvents", parents: ["e55555555"],
                   refs: ["tag: v0.4"], added: 148, removed: 6),
            commit("e55555555", "Highlight diff syntax", parents: ["f66666666"], added: 402, removed: 31),
            commit("f66666666", "Initial commit", parents: [], added: 1204, removed: 0)
        ]
    }()

    /// The counters draw at all — a regression that hid every `+N −M` in the pane.
    func testCountsLabelsAreMeasured() throws {
        let host = laidOutCommits(Self.history)
        let row = try XCTUnwrap(host.subviews.first?.subviews.first)
        let counts = try XCTUnwrap(
            row.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue.hasPrefix("+") }
        )
        XCTAssertGreaterThan(counts.frame.width, 20, "the +N −M counter laid out to nothing")
    }

    // MARK: - Layout

    func testExpandedRowsHaveHeight() throws {
        let files = GitDiffParser.files(fromUnifiedDiff: fixture)
        let host = laidOut(files)

        for row in host.subviews.first?.subviews ?? [] {
            XCTAssertGreaterThan(row.frame.height, 1, "a file row measured no height")
            XCTAssertLessThanOrEqual(
                row.frame.maxX, Render.width + 1,
                "a file row overflowed the pane"
            )
        }
    }

    /// The nested horizontal scroller is the one piece of this that a compile says nothing
    /// about: get its height binding wrong and every unwrapped diff measures zero, which looks
    /// exactly like a collapsed row. Both halves are asserted — the row still has a height, and
    /// the long line is contained rather than pushing the pane sideways.
    func testDisablingWordWrapShortensRowsAndKeepsThemInThePane() throws {
        let files = GitDiffParser.files(fromUnifiedDiff: longLineFixture)
        XCTAssertEqual(files.count, 1, "fixture should parse into one file")

        let wrapped = laidOut(files)
        let unwrapped = laidOut(files, wraps: false)

        for (name, host) in [("wrapped", wrapped), ("unwrapped", unwrapped)] {
            for row in host.subviews.first?.subviews ?? [] {
                XCTAssertGreaterThan(row.frame.height, 1, "\(name): a file row measured no height")
                XCTAssertLessThanOrEqual(
                    row.frame.maxX, Render.width + 1,
                    "\(name): a file row overflowed the pane"
                )
            }
        }

        // A long line on one row is shorter than the same line wrapped over several. This is the
        // whole observable difference, and it only holds if the scroller took the overflow.
        XCTAssertLessThan(
            unwrapped.frame.height, wrapped.frame.height,
            "disabling word wrap should shorten the diff rather than re-wrap it"
        )
    }

    func testRendersBothWrapModes() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let files = GitDiffParser.files(fromUnifiedDiff: longLineFixture)
        for (name, wraps) in [("wrapped", true), ("unwrapped", false)] {
            let data = try XCTUnwrap(
                image(of: files, appearance: .darkAqua, wraps: wraps),
                "failed to render \(name)"
            )
            try data.write(to: directory.appendingPathComponent("git-review-\(name)-dark.png"))
        }

        print("Rendered the wrap comparison to \(directory.path)")
    }

    /// Highlighting must not change what a diff *is*: same row count, same order.
    func testHighlightingDoesNotChangeRowCount() {
        let lines = GitDiffParser.files(fromUnifiedDiff: fixture)[0].hunks.flatMap(\.lines)

        let plain = DiffView(gitLines: lines, displayCap: 500)
        let highlighted = DiffView(gitLines: lines, displayCap: 500, path: "Runner.swift")

        XCTAssertEqual(plain.arrangedSubviews.count, highlighted.arrangedSubviews.count)
    }

    // MARK: - Building

    private func laidOut(_ files: [GitFileDiff], wraps: Bool = true) -> NSView {
        laidOut(files, staging: GitStaging.capability(for: .unstaged), wraps: wraps)
    }

    private func laidOut(_ files: [GitFileDiff], staging: GitStaging?, wraps: Bool = true) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.small
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(
            top: Design.Spacing.inset,
            left: Design.Spacing.inset,
            bottom: Design.Spacing.inset,
            right: Design.Spacing.inset
        )

        for file in files {
            let row = GitReviewFileRow(file: file, expanded: true, staging: staging, wraps: wraps)
            stack.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: Design.Spacing.inset),
                row.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -Design.Spacing.inset)
            ])
        }

        let host = NSView(frame: NSRect(x: 0, y: 0, width: Render.width, height: 1))
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: host.topAnchor),
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            stack.widthAnchor.constraint(equalToConstant: Render.width)
        ])

        host.layoutSubtreeIfNeeded()
        host.frame.size.height = stack.fittingSize.height
        host.layoutSubtreeIfNeeded()
        return host
    }

    /// Builds *and* draws inside the appearance: a diff row fills its layer with a resolved
    /// `CGColor`, so the wash is decided when the row is built, not when it is drawn.
    private func image(of files: [GitFileDiff], appearance name: NSAppearance.Name, wraps: Bool = true) -> Data? {
        let appearance = NSAppearance(named: name)

        var data: Data?
        let render = {
            let host = self.laidOut(files, wraps: wraps)
            host.appearance = appearance
            host.subviews.first?.appearance = appearance
            host.layoutSubtreeIfNeeded()
            data = self.png(of: host)
        }

        if #available(macOS 11.0, *) {
            appearance?.performAsCurrentDrawingAppearance(render)
        } else {
            render()
        }
        return data
    }

    private func image(ofCommits commits: [GitCommitSummary], appearance name: NSAppearance.Name) -> Data? {
        let appearance = NSAppearance(named: name)

        var data: Data?
        let render = {
            let host = self.laidOutCommits(commits)
            host.appearance = appearance
            host.subviews.first?.appearance = appearance
            host.layoutSubtreeIfNeeded()
            data = self.png(of: host)
        }

        if #available(macOS 11.0, *) {
            appearance?.performAsCurrentDrawingAppearance(render)
        } else {
            render()
        }
        return data
    }

    /// The history list's own arrangement: no gap between rows, which is what lets the rail
    /// run unbroken from one to the next.
    private func laidOutCommits(_ commits: [GitCommitSummary]) -> NSView {
        let graph = GitCommitGraph.rows(for: commits)
        let laneCount = GitCommitGraph.laneCount(of: graph)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(
            top: Design.Spacing.small,
            left: Design.Spacing.inset,
            bottom: Design.Spacing.inset,
            right: Design.Spacing.inset
        )

        for (index, commit) in commits.enumerated() {
            let row = GitReviewCommitRow(commit: commit, graph: graph[index], laneCount: laneCount)
            stack.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: Design.Spacing.inset),
                row.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -Design.Spacing.inset)
            ])
        }

        let host = NSView(frame: NSRect(x: 0, y: 0, width: Render.width, height: 1))
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: host.topAnchor),
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            stack.widthAnchor.constraint(equalToConstant: Render.width)
        ])

        host.layoutSubtreeIfNeeded()
        host.frame.size.height = stack.fittingSize.height
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func png(of host: NSView) -> Data? {
        guard host.bounds.height > 1,
              let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }

        // The pane sits on the window's material, so a background is painted here or every
        // label draws onto transparency.
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
