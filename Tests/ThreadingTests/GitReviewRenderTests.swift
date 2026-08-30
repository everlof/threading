import AppKit
import Darwin
@testable import SwiftTerm
import XCTest
@testable import Threading

/// Draws review-pane file rows through the real views and writes them out as images.
///
/// `ConversationRenderTests`' reason applies here twice over: syntax highlighting is a claim
/// about *colour on a coloured wash*, and no assertion about token ranges can say whether an
/// orange string is legible on a green added line, in both appearances. The layout assertions
/// come along for free.
@MainActor
final class GitReviewRenderTests: HostedStoreTestCase {

    // MARK: - Configuration

    private enum Render {
        /// The display pane's real working width, the same measure the conversation renders use.
        static let width: CGFloat = 720

        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
               !override.isEmpty {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }
    }

    /// A diff carrying one of everything the highlighter has an opinion about: keywords, a
    /// type, a string with an escape, numbers, both comment shapes, and a line that is only
    /// context — plus a second file in a language whose comment marker is `#`.
    private let fixture = """
    diff --git a/Sources/Threading/Core/Agent/Runner.swift b/Sources/Threading/Core/Agent/Runner.swift
    index 1111111..2222222 100644
    --- a/Sources/Threading/Core/Agent/Runner.swift
    +++ b/Sources/Threading/Core/Agent/Runner.swift
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

    /// The website capture's repository is real: Git Review reads these committed files through
    /// its shipping git process, then the test rewrites them into the state pictured on screen.
    private let productRenderTestBefore = """
    import AppKit
    import XCTest
    @testable import Threading

    @MainActor
    final class GitReviewRenderTests: XCTestCase {
        func productCapture() {
            let session = AgentSession(kind: .codex, usesNativeUI: true)
            let split = SidebarSplitViewController()
            let conversation = ConversationViewController(agentSession: session)
            split.addSplitViewItem(NSSplitViewItem(viewController: conversation))
        }
    }
    """

    private let productRenderTestAfter = """
    import AppKit
    import XCTest
    @testable import Threading

    @MainActor
    final class GitReviewRenderTests: HostedStoreTestCase {
        func productCapture() {
            let session = AgentSession(kind: .codex, usesNativeUI: false)
            let window = makeMainWindowController(initialFramePlan: .useDefaultFrame)
            let terminal = AgentSessionViewController(agentSession: session)
            window.sidebarViewController.select(sessionID: session.id)
        }
    }
    """

    private let productThemeBefore = """
    const captures = [{
      slug: "threading",
      image: productImage("mac-threading-chat-review.png"),
    }];
    """

    private let productThemeAfter = """
    const captures = [{
      slug: "threading",
      image: productImage("mac-threading-tui-review.png"),
    }];
    """

    /// A change whose lines run far past any pane. This is the only shape that tells the two
    /// wrap modes apart — anything that fits draws identically either way.
    private let longLineFixture = """
    diff --git a/Sources/Threading/Core/Agent/AgentLauncher.swift b/Sources/Threading/Core/Agent/AgentLauncher.swift
    index 5555555..6666666 100644
    --- a/Sources/Threading/Core/Agent/AgentLauncher.swift
    +++ b/Sources/Threading/Core/Agent/AgentLauncher.swift
    @@ -3,3 +3,3 @@ enum AgentLauncher {
         static func claudeCommand(for session: AgentSession) -> [String] {
    -        return ["claude", "--session-id", session.identifier, "--allowedTools", "mcp__threading__*", "--mcp-config", configurationPath, "--settings", settingsPath, "--append-system-prompt", promptPath]
    +        return ["claude", "--session-id", session.identifier, "--allowedTools", "mcp__threading__*", "--mcp-config", configurationPath, "--settings", settingsPath, "--append-system-prompt", promptPath, "--fork-session", "--include-hook-events", "--permission-prompt-tool", brokerPath]
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

    func testSingleHunkDoesNotRepeatTheFileDiffStat() throws {
        let file = try XCTUnwrap(GitDiffParser.files(fromUnifiedDiff: fixture).first)
        XCTAssertEqual(file.hunks.count, 1, "the regression fixture must remain a single hunk")

        let host = laidOut([file])
        XCTAssertEqual(
            descendants(in: host).filter {
                $0.accessibilityIdentifier() == "git-review.file.stats"
            }.count,
            1
        )
        XCTAssertTrue(
            descendants(in: host).allSatisfy {
                $0.accessibilityIdentifier() != "git-review.hunk.stats"
            },
            "a one-hunk file already states +/− in its file header"
        )
    }

    func testMultiHunkFileKeepsPerHunkDiffStats() throws {
        let source = """
        diff --git a/Example.swift b/Example.swift
        index 1111111..2222222 100644
        --- a/Example.swift
        +++ b/Example.swift
        @@ -1,2 +1,2 @@
        -let first = 1
        +let first = 2
         let middle = true
        @@ -20,2 +20,2 @@
        -let last = 1
        +let last = 2
         let end = true
        """
        let file = try XCTUnwrap(GitDiffParser.files(fromUnifiedDiff: source).first)
        XCTAssertEqual(file.hunks.count, 2)

        let host = laidOut([file])
        XCTAssertEqual(
            descendants(in: host).filter {
                $0.accessibilityIdentifier() == "git-review.hunk.stats"
            }.count,
            2,
            "each hunk needs its own +/− once there is more than one"
        )
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

    /// Virtualized rows are built before they join the pane's window. Their opaque washes must
    /// resolve in that window's appearance, not in whichever drawing appearance was ambient
    /// while AppKit asked the table for a row.
    func testTextKitDiffRepairsAmbientAppearanceWhenItJoinsAWindow() throws {
        let previousTheme = AppThemePalette.current
        let previousAppearance = NSApp.appearance
        defer {
            AppThemePalette.set(previousTheme)
            NSApp.appearance = previousAppearance
        }

        AppThemePalette.set(.system)
        let lightAppearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let darkAppearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        NSApp.appearance = lightAppearance

        var constructedDiff: GitReviewDiffTextView?
        darkAppearance.performAsCurrentDrawingAppearance {
            constructedDiff = GitReviewDiffTextView(
                gitLines: [
                    GitDiffLine(
                        kind: .removed,
                        text: "let oldValue = 1",
                        oldNumber: 1,
                        newNumber: nil
                    ),
                    GitDiffLine(
                        kind: .added,
                        text: "let newValue = 2",
                        oldNumber: nil,
                        newNumber: 1
                    )
                ],
                displayCap: 2,
                path: "Appearance.swift",
                initialLayoutWidth: 320
            )
        }
        let diff = try XCTUnwrap(constructedDiff)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.appearance = lightAppearance
        window.backgroundColor = .white
        let content = try XCTUnwrap(window.contentView)
        diff.frame = content.bounds
        content.addSubview(diff)
        window.layoutIfNeeded()

        var expectedInk: Design.DiffInk?
        lightAppearance.performAsCurrentDrawingAppearance {
            expectedInk = Design.Diff.on(.white)
        }
        let expected = try XCTUnwrap(expectedInk)
        let actual = diff.washColorsForTesting

        assertColor(actual.added, equals: expected.addedWash)
        assertColor(actual.removed, equals: expected.removedWash)
    }

    /// The TextKit body is not the only frozen surface in a virtualized row: the card and each
    /// hunk header are layer-backed too. Construct the row under dark ambient state, attach it
    /// to a light pane, and require the entire recorded surface tree to adopt that pane.
    func testAFileRowRepairsAmbientAppearanceWhenItJoinsAWindow() throws {
        let previousTheme = AppThemePalette.current
        let previousAppearance = NSApp.appearance
        defer {
            AppThemePalette.set(previousTheme)
            NSApp.appearance = previousAppearance
        }

        AppThemePalette.set(.system)
        NSApp.appearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let lightAppearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let files = GitDiffParser.files(fromUnifiedDiff: fixture)
        let pane = laidOutPane(files, appearance: lightAppearance)
        let fileRow = try XCTUnwrap(
            descendants(in: pane.view).compactMap { $0 as? GitReviewFileRow }.first
        )

        var expectedCard: NSColor?
        var expectedHunk: NSColor?
        lightAppearance.performAsCurrentDrawingAppearance {
            // Freeze the dynamic system colours while light is current. Resolving these after
            // the closure would merely re-read the deliberately dark ambient application.
            expectedCard = NSColor(cgColor: Design.Surface.controlResting.cgColor)
            expectedHunk = NSColor(cgColor: Design.Surface.background.cgColor)
        }
        let expectedCardColor = try XCTUnwrap(expectedCard)
        let expectedHunkColor = try XCTUnwrap(expectedHunk)
        let cardCGColor = try XCTUnwrap(fileRow.layer?.backgroundColor)
        let cardColor = try XCTUnwrap(NSColor(cgColor: cardCGColor))
        assertColor(cardColor, equals: expectedCardColor)
        let childSurfaces = descendants(in: fileRow)
            .compactMap { $0.layer?.backgroundColor }
            .compactMap(NSColor.init(cgColor:))
        XCTAssertTrue(
            childSurfaces.contains { colorsEqual($0, expectedHunkColor) },
            "the detached hunk header kept the ambient dark surface in its light window"
        )
    }

    /// Highlighting must not change what a diff *is*: same row count, same order.
    func testHighlightingDoesNotChangeRowCount() {
        let lines = GitDiffParser.files(fromUnifiedDiff: fixture)[0].hunks.flatMap(\.lines)

        let plain = DiffView(gitLines: lines, displayCap: 500)
        let highlighted = DiffView(gitLines: lines, displayCap: 500, path: "Runner.swift")

        XCTAssertEqual(plain.arrangedSubviews.count, highlighted.arrangedSubviews.count)
    }

    // MARK: - Contested Attribution

    /// On a contested turn the pane can prove a file was this chat's, never that it was not — so
    /// an unclaimed file says only that, after the counts it already shows, and a claimed file is
    /// left exactly as it renders on any other turn.
    func testUnclaimedFileRowMarksItsSummaryWithoutDisturbingClaimedRows() throws {
        let file = try XCTUnwrap(GitDiffParser.files(fromUnifiedDiff: fixture).first)

        let unclaimed = GitReviewFileRow(file: file, expanded: false, attribution: .unclaimed)
        let claimed = GitReviewFileRow(file: file, expanded: false)

        let mark = L10n.string("not claimed")
        XCTAssertTrue(statsText(in: unclaimed).hasSuffix(mark))
        XCTAssertTrue(
            statsText(in: unclaimed).hasPrefix("+"),
            "the file's own counts still lead its summary"
        )
        XCTAssertEqual(
            statsText(in: unclaimed).replacingOccurrences(
                of: GitReviewUIDefaults.subtitleSeparator + mark,
                with: ""
            ),
            statsText(in: claimed),
            "the mark is appended to the ordinary summary, not a replacement for it"
        )
        XCTAssertFalse(statsText(in: claimed).contains(mark))
    }

    /// The other two answers a contested turn can give. Each names the other chat rather than
    /// implying the file is a problem, and both sit in the same tertiary caption as the counts.
    func testRowsNameAnotherChatsClaimAndASharedOne() throws {
        let file = try XCTUnwrap(GitDiffParser.files(fromUnifiedDiff: fixture).first)

        let other = GitReviewFileRow(file: file, expanded: false, attribution: .otherChat)
        let shared = GitReviewFileRow(file: file, expanded: false, attribution: .shared)
        let plain = GitReviewFileRow(file: file, expanded: false)

        let summary = statsText(in: plain)
        XCTAssertEqual(
            statsText(in: other),
            summary + GitReviewUIDefaults.subtitleSeparator + L10n.string("claimed by another chat")
        )
        XCTAssertEqual(
            statsText(in: shared),
            summary + GitReviewUIDefaults.subtitleSeparator
                + L10n.string("also claimed by another chat")
        )
        for row in [other, shared] {
            XCTAssertFalse(
                statsText(in: row).contains(L10n.string("not claimed")),
                "a file somebody claimed is never also called unclaimed"
            )
        }
    }

    private func statsText(in row: NSView) -> String {
        descendants(in: row)
            .compactMap { $0 as? NSTextField }
            .first { $0.accessibilityIdentifier() == "git-review.file.stats" }?
            .stringValue ?? ""
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
            AppThemeRefresh.repaint(host)
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
            AppThemeRefresh.repaint(host)
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

    // MARK: - The Whole Pane

    /// **Draws the pane itself, not a stack of rows built by hand.**
    ///
    /// Every other render here assembles `GitReviewFileRow`s into an `NSStackView`, which is not
    /// the surface the app shows: file comparisons go through a virtualized `NSTableView`, and
    /// the fault this test exists for lived entirely in the table. Its sole column kept
    /// `NSTableColumn`'s 100pt default, so cards came out 76pt wide in a pane hundreds of points
    /// wider and every changed line wrapped to three characters — for a whole window, with no
    /// assertion anywhere failing and no broken constraint logged. A picture of the real pane is
    /// what shows that instantly; the width assertion below is what fails when it recurs.
    func testRendersTheFilePaneItselfInBothAppearances() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { AppThemePalette.set(.system) }

        let files = GitDiffParser.files(fromUnifiedDiff: fixture)
        let fixtures: [(String, AppTheme, NSAppearance.Name)] = [
            ("light", .system, .aqua),
            ("dark", .system, .darkAqua),
            ("threading-dark", AppThemeStyles.threading, .darkAqua),
        ]
        for (name, theme, appearanceName) in fixtures {
            AppThemePalette.set(theme)
            let appearance = NSAppearance(named: appearanceName)
            var data: Data?
            var cardWidth: CGFloat = 0
            let render = {
                let pane = self.laidOutPane(files, appearance: appearance)
                cardWidth = pane.cardWidth
                data = self.png(of: pane.view)
            }
            if #available(macOS 11.0, *) {
                appearance?.performAsCurrentDrawingAppearance(render)
            } else {
                render()
            }

            try XCTUnwrap(data, "failed to render \(name)")
                .write(to: directory.appendingPathComponent("git-review-pane-\(name).png"))
            XCTAssertEqual(
                cardWidth, Render.width - Design.Spacing.inset * 2, accuracy: 0.5,
                "\(name): a file card did not span the pane"
            )

            // The reported state: the resting chip is ink-only, so only the hovered render can
            // prove its latent plate stays on the same margin as the cards below it.
            var chipHoverData: Data?
            let renderChipHover = {
                let pane = self.laidOutPane(files, appearance: appearance)
                let chip = pane.controller.modeChip
                guard let event = NSEvent.enterExitEvent(
                    with: .mouseEntered,
                    location: chip.convert(
                        NSPoint(x: chip.bounds.midX, y: chip.bounds.midY),
                        to: nil
                    ),
                    modifierFlags: [],
                    timestamp: 0,
                    windowNumber: chip.window?.windowNumber ?? 0,
                    context: nil,
                    eventNumber: 0,
                    trackingNumber: 0,
                    userData: nil
                ) else { return }
                chip.mouseEntered(with: event)
                pane.view.layoutSubtreeIfNeeded()
                chipHoverData = self.png(of: pane.view)
            }
            appearance?.performAsCurrentDrawingAppearance(renderChipHover)
            try XCTUnwrap(chipHoverData, "failed to render \(name) mode-chip hover")
                .write(to: directory.appendingPathComponent(
                    "git-review-pane-toolbar-hover-\(name).png"
                ))
        }

        AppThemePalette.set(.system)
        for (name, appearanceName) in [
            ("find-light", NSAppearance.Name.aqua),
            ("find-dark", NSAppearance.Name.darkAqua)
        ] {
            let appearance = NSAppearance(named: appearanceName)
            var data: Data?
            let render = {
                let pane = self.laidOutPane(files, appearance: appearance)
                pane.controller.showFind()
                pane.view.layoutSubtreeIfNeeded()
                data = self.png(of: pane.view)
            }
            appearance?.performAsCurrentDrawingAppearance(render)
            try XCTUnwrap(data, "failed to render \(name)")
                .write(to: directory.appendingPathComponent("git-review-pane-\(name).png"))
        }

        // These interaction states prove both halves of sticky-heading composition: semantic
        // diff ink cannot leak through its rounded top, and the retained overlay moves away
        // before the next real file heading reaches it.
        let stickyAppearance = NSAppearance(named: .darkAqua)
        let stickyEvidenceFiles = stickyTransitionFiles()
        for (suffix, theme, evidenceFiles, pushesIntoNextHeader) in [
            ("dark", AppTheme.system, files, false),
            ("threading-dark", AppThemeStyles.threading, stickyEvidenceFiles, false),
            ("push-threading-dark", AppThemeStyles.threading, stickyEvidenceFiles, true),
        ] {
            AppThemePalette.set(theme)
            var stickyData: Data?
            let renderSticky = {
                let pane = self.laidOutPane(evidenceFiles, appearance: stickyAppearance)
                pane.controller.renderedFileRoot = URL(fileURLWithPath: "/tmp")
                pane.controller.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 100))
                pane.controller.scrollView.reflectScrolledClipView(
                    pane.controller.scrollView.contentView
                )
                pane.controller.updateScrollControls()
                pane.view.layoutSubtreeIfNeeded()

                let stickyHeight = pane.controller.stickyFileHeaderHeightForTesting
                XCTAssertGreaterThan(stickyHeight, 30)
                if pushesIntoNextHeader {
                    let firstRowRect = pane.controller.fileTableView.rect(ofRow: 0)
                    let requestedNextHeaderY = stickyHeight / 2 + Design.Spacing.small
                    pane.controller.scrollView.contentView.scroll(to: NSPoint(
                        x: 0,
                        y: firstRowRect.maxY - requestedNextHeaderY
                    ))
                    pane.controller.scrollView.reflectScrolledClipView(
                        pane.controller.scrollView.contentView
                    )
                    pane.controller.updateScrollControls()
                    pane.view.layoutSubtreeIfNeeded()

                    let nextHeaderY = firstRowRect.maxY
                        - pane.controller.scrollView.documentVisibleRect.minY
                    let retainedHeaderBottom = pane.controller.stickyFileHeaderTopForTesting
                        + stickyHeight
                    XCTAssertLessThan(pane.controller.stickyFileHeaderTopForTesting, 0)
                    XCTAssertEqual(
                        nextHeaderY - retainedHeaderBottom,
                        Design.Spacing.small,
                        accuracy: 0.5
                    )
                }

                guard let header = pane.controller.stickyFileHeaderRowForTesting,
                      let event = NSEvent.enterExitEvent(
                        with: .mouseEntered,
                        location: header.convert(
                            NSPoint(x: header.bounds.midX, y: header.bounds.midY),
                            to: nil
                        ),
                        modifierFlags: [],
                        timestamp: 0,
                        windowNumber: header.window?.windowNumber ?? 0,
                        context: nil,
                        eventNumber: 0,
                        trackingNumber: 0,
                        userData: nil
                      ) else { return }
                header.mouseEntered(with: event)
                pane.view.layoutSubtreeIfNeeded()
                let visibleActions = header.subviews.compactMap { $0 as? ThemedIconButton }.filter {
                    !$0.isHidden && $0.alphaValue > 0.99
                }
                XCTAssertEqual(visibleActions.count, 2)
                stickyData = self.png(of: pane.view)
            }
            stickyAppearance?.performAsCurrentDrawingAppearance(renderSticky)
            try XCTUnwrap(stickyData, "failed to render \(suffix) sticky heading")
                .write(to: directory.appendingPathComponent(
                    "git-review-pane-sticky-\(suffix).png"
                ))
        }

        for (suffix, theme) in [
            ("dark", AppTheme.system),
            ("threading-dark", AppThemeStyles.threading),
        ] {
            AppThemePalette.set(theme)
            var lineHoverData: Data?
            let renderLineHover = {
                let pane = self.laidOutPane(files, appearance: stickyAppearance)
                guard let diff = self.descendants(in: pane.view)
                    .compactMap({ $0 as? GitReviewDiffTextView })
                    .first,
                      let action = diff.lineActionRectForTesting(atDisplayedLine: 2),
                      let event = NSEvent.mouseEvent(
                        with: .mouseMoved,
                        location: diff.convert(
                            NSPoint(x: action.midX, y: action.midY),
                            to: nil
                        ),
                        modifierFlags: [],
                        timestamp: 0,
                        windowNumber: diff.window?.windowNumber ?? 0,
                        context: nil,
                        eventNumber: 0,
                        clickCount: 0,
                        pressure: 0
                      ) else { return }
                diff.onAddContextAttachment = { _ in }
                diff.mouseMoved(with: event)
                XCTAssertEqual(diff.hoveredLineIndex, 2)
                lineHoverData = self.png(of: pane.view)
            }
            stickyAppearance?.performAsCurrentDrawingAppearance(renderLineHover)
            try XCTUnwrap(lineHoverData, "failed to render \(suffix) source-line hover")
                .write(to: directory.appendingPathComponent(
                    "git-review-pane-line-hover-\(suffix).png"
                ))

            var hunkHoverData: Data?
            let renderHunkHover = {
                let pane = self.laidOutPane(files, appearance: stickyAppearance)
                guard let disclosure = self.descendants(in: pane.view)
                    .compactMap({ $0 as? ThemedDisclosureRow })
                    .first,
                      let event = NSEvent.enterExitEvent(
                        with: .mouseEntered,
                        location: disclosure.convert(
                            NSPoint(x: disclosure.bounds.midX, y: disclosure.bounds.midY),
                            to: nil
                        ),
                        modifierFlags: [],
                        timestamp: 0,
                        windowNumber: disclosure.window?.windowNumber ?? 0,
                        context: nil,
                        eventNumber: 0,
                        trackingNumber: 0,
                        userData: nil
                      ) else { return }
                disclosure.mouseEntered(with: event)
                hunkHoverData = self.png(of: pane.view)
            }
            stickyAppearance?.performAsCurrentDrawingAppearance(renderHunkHover)
            try XCTUnwrap(hunkHoverData, "failed to render \(suffix) hunk-heading hover")
                .write(to: directory.appendingPathComponent(
                    "git-review-pane-hunk-hover-\(suffix).png"
                ))
        }

        print("Rendered the review pane to \(directory.path)")
    }

    private func stickyTransitionFiles() -> [GitFileDiff] {
        (0..<2).map { fileIndex in
            let lines = (0..<48).map { lineIndex in
                let number = lineIndex + 1
                let kind: GitDiffLine.Kind = switch lineIndex % 5 {
                case 0: .removed
                case 1: .added
                default: .context
                }
                return GitDiffLine(
                    kind: kind,
                    text: "let reviewValue\(lineIndex) = StickyHeader\(fileIndex).value + \(lineIndex)",
                    oldNumber: kind == .added ? nil : number,
                    newNumber: kind == .removed ? nil : number
                )
            }
            return GitFileDiff(
                path: "Sources/Threading/Review/StickyHeader\(fileIndex).swift",
                change: .modified,
                hunks: [GitHunk(header: "@@ -1,48 +1,48 @@", lines: lines)],
                added: lines.lazy.filter { $0.kind == .added }.count,
                removed: lines.lazy.filter { $0.kind == .removed }.count
            )
        }
    }

    /// The product capture is the complete shipping window: project sidebar, selected session,
    /// provider terminal, pane headers, display panel, and Git Review. The repository is a
    /// disposable fixture, but the TUI is not: Threading launches the installed Codex provider
    /// and the same live terminal stays attached while every website theme is captured.
    ///
    /// This is deliberately opt-in. A normal test run must never spend a provider turn merely
    /// because somebody ran the suite; the website capture command states that cost explicitly.
    func testRendersFullThreadingShellWithTUIAndGitReview() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["THREADING_LIVE_MARKETING_CAPTURE"] == "1",
            "Run the website capture explicitly; it launches a real Codex TUI and spends one turn."
        )
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let originalTheme = AppThemeLibrary.current
        let originalBackdrop = WindowBackdrop.ground
        let originalAppearance = NSApp.appearance
        let product = try makeProductShellFixture()
        XCTAssertTrue(
            AgentRuntime.shared.installFixtureLaunchPlan(for: product.session.id) {
                [weak self] session, project, initialPrompt in
                guard let self else { throw LiveMarketingCaptureError.ownerReleased }
                return self.liveCodexPlan(
                    for: session,
                    in: project,
                    initialPrompt: initialPrompt
                )
            },
            "the live marketing process must be installed before its terminal is materialized"
        )
        defer {
            AgentRuntime.shared.discard(sessionID: product.session.id)
            ProjectStore.shared.removeProject(id: product.project.id)
            try? FileManager.default.removeItem(at: product.containerURL)
            AppThemeLibrary.apply(originalTheme)
            AppThemePalette.set(originalTheme)
            WindowBackdrop.set(originalBackdrop)
            NSApp.appearance = originalAppearance
        }

        let fixtures: [(filename: String, theme: AppTheme, appearance: NSAppearance.Name)] = [
            ("threading-tui-git-review.png", AppThemeStyles.threading, .darkAqua),
            ("theme-tui-system-dark.png", .system, .darkAqua),
            ("theme-tui-cyberpunk-dark.png", AppThemeStyles.cyberpunk, .darkAqua),
            ("theme-tui-swiss-light.png", AppThemeStyles.swissMinimalist, .aqua),
            ("theme-tui-neo-brutalism-light.png", AppThemeStyles.neoBrutalism, .aqua),
            ("theme-tui-claymorphism-light.png", AppThemeStyles.claymorphism, .aqua),
            ("theme-tui-vaporwave-dark.png", AppThemeStyles.vaporwave, .darkAqua)
        ]

        for fixture in fixtures {
            // Repaint the same live provider terminal under each selected theme. Keeping one
            // process is what makes the comparison honest: only the app-and-terminal dress moves.
            AppThemeLibrary.apply(fixture.theme)
            AppThemePalette.set(fixture.theme)
            let appearance = try XCTUnwrap(NSAppearance(named: fixture.appearance))
            // Dynamic System colours are application-scoped when AppKit services a nested run
            // loop. Match the product's selected appearance instead of inheriting the test
            // process's ambient Aqua while the dark window is rendered.
            NSApp.appearance = appearance
            var result: ProductShellRender?
            appearance.performAsCurrentDrawingAppearance {
                result = self.fullThreadingShellWithTUIAndGitReview(
                    theme: fixture.theme,
                    appearance: appearance,
                    product: product
                )
            }

            let rendered = try XCTUnwrap(result)
            if fixture.theme.id == AppThemeStyles.threading.id {
                XCTAssertFalse(
                    rendered.showsAppIcon,
                    "Threading's title band should not repeat the app mark"
                )
            }
            let data = try XCTUnwrap(rendered.data, "failed to render \(fixture.filename)")
            try assertTerminalBackground(
                in: data,
                at: rendered.terminalSample,
                contentSize: rendered.contentSize,
                equals: fixture.theme.terminalPalette(for: appearance).background,
                filename: fixture.filename
            )
            try data.write(to: directory.appendingPathComponent(fixture.filename))
        }
        print("Rendered the full-window theme TUI and review captures to \(directory.path)")
    }

    private struct ProductShellFixture {
        let containerURL: URL
        let project: Project
        let session: AgentSession
        let reviewFiles: [GitFileDiff]
    }

    private struct ProductShellRender {
        let data: Data?
        let showsAppIcon: Bool
        let terminalSample: NSPoint
        let contentSize: NSSize
    }

    private enum LiveMarketingCaptureError: Error {
        case ownerReleased
    }

    private func fullThreadingShellWithTUIAndGitReview(
        theme: AppTheme,
        appearance: NSAppearance,
        product: ProductShellFixture
    ) -> ProductShellRender? {
        let size = NSSize(width: 1_280, height: 760)
        let terminal = AgentRuntime.shared.makeController(for: product.session)
        _ = terminal.view
        var profile = TerminalProfile.default
        profile.theme = theme.terminalPalette(for: appearance)
        profile.cursorBlink = false
        terminal.session.updateProfile(profile)
        WindowBackdrop.set(.terminal(profile.theme.background))
        XCTAssertEqual(
            terminal.session.terminalView.terminalStateSnapshot().backgroundColor,
            swiftTermColor(profile.theme.background),
            "the theme capture terminal must use the selected app theme's paired palette"
        )

        let controller = makeMainWindowController(initialFramePlan: .useDefaultFrame)
        guard let window = controller.window else {
            XCTFail("the shipping main window was not created")
            return nil
        }
        window.appearance = appearance
        window.setContentSize(size)
        // SwiftTerm's Metal-backed renderer does not produce its first frame while its window
        // has never been ordered. Keep the real product window far offscreen, but give AppKit
        // the same ordered-window lifecycle it has in the running application.
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.animationBehavior = .none
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.delegate = nil
            window.contentViewController = nil
            controller.window = nil
        }

        guard let content = window.contentView else {
            XCTFail("the shipping main window had no content view")
            return nil
        }
        content.appearance = appearance
        // Sidebar rows read key-window state when they are configured. Pin the deterministic
        // capture state before mounting the real tree so the selected System row keeps its ink.
        applyKeyFixtureState(in: content)
        controller.sidebarViewController.mountInitialTreeIfNeeded()
        controller.displayPaneController.showSession(product.session.id)
        guard let review = controller.displayPaneController.activateReview(
            for: product.session.id
        ) else {
            XCTFail("the shipping display pane did not create Git Review")
            return nil
        }

        // Select through the real sidebar. Its one event-loop handoff paints the selected row
        // before attaching the already-cached terminal, exactly as a user click does.
        controller.sidebarViewController.select(sessionID: product.session.id)
        let selectionDeadline = Date().addingTimeInterval(2)
        while controller.containerViewController.currentSessionID != product.session.id,
              Date() < selectionDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(controller.sidebarViewController.selectedSessionID, product.session.id)
        XCTAssertEqual(controller.containerViewController.currentSessionID, product.session.id)
        XCTAssertTrue(controller.containerViewController.activeTerminalSession === terminal.session)

        controller.setDisplayPaneVisible(true, animated: false)
        let split = controller.splitViewController.splitView
        content.layoutSubtreeIfNeeded()
        split.setPosition(230, ofDividerAt: 0)
        split.setPosition(825, ofDividerAt: 1)
        content.layoutSubtreeIfNeeded()

        let visiblePanes = split.arrangedSubviews.filter {
            !$0.isHidden && $0.bounds.width > 1 && $0.bounds.height > 1
        }
        XCTAssertEqual(visiblePanes.count, 3, "the website capture must show the full three-pane app")
        XCTAssertTrue(controller.displayPaneController.currentReview === review)

        let terminalView = terminal.session.terminalView
        terminalView.suspendsRenderingWhenNotVisible = false
        if !terminal.isRunning {
            terminal.launch(initialPrompt: liveProductPrompt)
            let providerDeadline = Date().addingTimeInterval(180)
            var markerCount = 0
            var providerSettled = false
            repeat {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                markerCount = terminalView.recentLogicalBufferText(
                    maximumUTF8Bytes: 256 * 1_024
                ).text.components(separatedBy: liveProductMarker).count - 1
                providerSettled = markerCount >= 2 && !terminal.activity.hasTurnInFlight
            } while !providerSettled && Date() < providerDeadline
            XCTAssertGreaterThanOrEqual(
                markerCount,
                2,
                "the installed Codex TUI did not finish the disposable screenshot task"
            )
            XCTAssertTrue(
                providerSettled,
                "the installed Codex TUI response did not reach a completed turn boundary"
            )
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        let providerBuffer = terminalView.recentLogicalBufferText(
            maximumUTF8Bytes: 256 * 1_024
        ).text
        XCTAssertGreaterThanOrEqual(
            providerBuffer.components(separatedBy: liveProductMarker).count - 1,
            2,
            "the marketing capture must retain the real provider's completed response"
        )

        // The disposable checkout's patch was read before launching the provider. Cancel the
        // pane's redundant background read and present those exact Git-parsed models through the
        // shipping review controller; this keeps the capture deterministic without inventing a
        // review or waiting behind provider-owned Git commands.
        review.activeDiffCancellation?.cancel()
        review.generation += 1
        review.isLoading = false
        review.loadedDiffRoot = review.repositoryRoot
        review.show(.files(product.reviewFiles), forceRebuild: true)
        review.setChangeRequestBarVisible(false)
        XCTAssertEqual(
            review.renderedFiles.map(\.path).sorted(),
            [
                "Tests/ThreadingTests/GitReviewRenderTests.swift",
                "web/app/ThemePlayground.tsx"
            ],
            "the full-window capture must show the real repository fixture in Git Review"
        )

        applyKeyFixtureState(in: content)
        AppThemeRefresh.repaint(content)
        content.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        // The first SwiftTerm surface in a process also has to compile its Metal pipeline.
        // Advance the real render loop long enough for that first frame instead of relying on
        // later theme captures to warm it incidentally.
        let terminalRenderDeadline = Date().addingTimeInterval(0.35)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            terminalView.needsDisplay = true
            terminalView.frameTick()
            window.displayIfNeeded()
        } while Date() < terminalRenderDeadline

        // Both operations above may rebuild asynchronously-owned chrome: theme repaint can
        // replace sidebar rows, while change-request discovery can restore its contextual bar.
        // Pin the intended real-window state at the final pixel boundary.
        review.setChangeRequestBarVisible(false)
        var resolvedSystemSelectionFill: NSColor?
        if theme.isSystem {
            appearance.performAsCurrentDrawingAppearance {
                resolvedSystemSelectionFill = NSColor.selectedContentBackgroundColor
                    .usingColorSpace(.sRGB)
            }
        }
        applyKeyFixtureState(
            in: content,
            systemSelectionFill: resolvedSystemSelectionFill
        )
        let selectedSidebarRows = descendants(in: content)
            .compactMap { $0 as? SidebarHoverRowView }
            .filter(\.isSelected)
        XCTAssertEqual(selectedSidebarRows.count, 1)
        XCTAssertTrue(selectedSidebarRows.allSatisfy(\.isEmphasized))
        XCTAssertTrue(selectedSidebarRows.allSatisfy { row in
            descendants(in: row).compactMap { $0 as? SessionRowView }.allSatisfy {
                $0.backgroundStyle == .emphasized
            }
        })
        content.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        _ = window.makeFirstResponder(terminalView)

        guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            return ProductShellRender(
                data: nil,
                showsAppIcon: false,
                terminalSample: .zero,
                contentSize: content.bounds.size
            )
        }
        content.cacheDisplay(in: content.bounds, to: rep)
        let terminalSample = terminalView.convert(
            NSPoint(x: terminalView.bounds.width * 0.90, y: terminalView.bounds.height * 0.50),
            to: content
        )
        let titleBand = descendants(in: content).compactMap { $0 as? WindowTitleBandView }.first
        return ProductShellRender(
            data: compositedPNG(
                representation: rep,
                ground: profile.theme.background
            ),
            showsAppIcon: titleBand?.showsApplicationIcon ?? false,
            terminalSample: terminalSample,
            contentSize: content.bounds.size
        )
    }

    private func makeProductShellFixture() throws -> ProductShellFixture {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-product-shell-\(UUID().uuidString)", isDirectory: true)
        let repository = container.appendingPathComponent("AnotherTerminal", isDirectory: true)
        let renderTest = repository.appendingPathComponent(
            "Tests/ThreadingTests/GitReviewRenderTests.swift"
        )
        let themePlayground = repository.appendingPathComponent("web/app/ThemePlayground.tsx")
        try FileManager.default.createDirectory(
            at: renderTest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: themePlayground.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try productRenderTestBefore.write(to: renderTest, atomically: true, encoding: .utf8)
        try productThemeBefore.write(to: themePlayground, atomically: true, encoding: .utf8)
        try runGit(["init", "--quiet", "--initial-branch=main"], in: repository)
        try runGit(["config", "user.email", "evidence@threading.local"], in: repository)
        try runGit(["config", "user.name", "Threading Evidence"], in: repository)
        try runGit(["add", "."], in: repository)
        try runGit(["commit", "--quiet", "-m", "Seed full-window capture"], in: repository)
        try productRenderTestAfter.write(to: renderTest, atomically: true, encoding: .utf8)
        try productThemeAfter.write(to: themePlayground, atomically: true, encoding: .utf8)
        let reviewFiles = GitDiffParser.files(fromUnifiedDiff: GitDiffParser.decode(
            try runGitOutput(["diff", "--no-ext-diff", "--unified=3"], in: repository)
        ))
        XCTAssertEqual(
            reviewFiles.map(\.path).sorted(),
            [
                "Tests/ThreadingTests/GitReviewRenderTests.swift",
                "web/app/ThemePlayground.tsx"
            ]
        )

        let store = ProjectStore.shared
        let project = try XCTUnwrap(store.addProject(folderURL: repository))
        XCTAssertTrue(store.renameProject(id: project.id, to: "AnotherTerminal").succeeded)
        _ = try XCTUnwrap(store.addSession(
            to: project.id,
            kind: .claude,
            usesNativeUI: false,
            title: "Release readiness"
        ))
        let session = try XCTUnwrap(store.addSession(
            to: project.id,
            kind: .codex,
            usesNativeUI: false,
            permissionMode: .plan,
            title: "TUI theme screenshots"
        ))
        _ = try XCTUnwrap(store.addSession(
            to: project.id,
            kind: .codex,
            usesNativeUI: false,
            title: "Landing page"
        ))

        return ProductShellFixture(
            containerURL: container,
            project: try XCTUnwrap(store.project(withID: project.id)),
            session: try XCTUnwrap(store.session(withID: session.id)),
            reviewFiles: reviewFiles
        )
    }

    private func runGitOutput(_ arguments: [String], in directory: URL) throws -> Data {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        process.environment = environment
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "GitReviewRenderTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed"]
            )
        }
        return data
    }

    private func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "GitReviewRenderTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed"]
            )
        }
    }

    private func applyKeyFixtureState(
        in view: NSView,
        systemSelectionFill: NSColor? = nil
    ) {
        (view as? WindowTitleBandView)?.fixtureIsKey = true
        (view as? ThemedTableView)?.fixtureIsKey = true
        (view as? ThemedOutlineView)?.fixtureIsKey = true
        if let row = view as? SidebarHoverRowView, row.isSelected {
            // AppKit can rebuild a source-list cell after the list has applied its fixture key
            // state. Pin both participants in the selection contract at the final pixel boundary:
            // the row owns the fill, while SessionRowView owns the ink over that fill.
            row.isEmphasized = true
            row.fixtureSelectionFill = systemSelectionFill
            row.needsDisplay = true
            descendants(in: row).compactMap { $0 as? SessionRowView }.forEach {
                $0.backgroundStyle = .emphasized
            }
        }
        view.subviews.forEach {
            applyKeyFixtureState(in: $0, systemSelectionFill: systemSelectionFill)
        }
    }

    /// `cacheDisplay` preserves the transparent terminal backing that the real window compositor
    /// normally places over `WindowBackdrop`. Flatten that real product render over the same
    /// terminal ground so exported PNGs do not turn the transparent cells black in browsers.
    private func compositedPNG(
        representation: NSBitmapImageRep,
        ground: NSColor
    ) -> Data? {
        guard let cachedImage = representation.cgImage,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: representation.pixelsWide,
                  height: representation.pixelsHigh,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let resolvedGround = ground.usingColorSpace(.sRGB) else { return nil }
        let bounds = CGRect(
            x: 0,
            y: 0,
            width: representation.pixelsWide,
            height: representation.pixelsHigh
        )
        context.setFillColor(resolvedGround.cgColor)
        context.fill(bounds)
        context.draw(cachedImage, in: bounds)
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    private let liveProductMarker = "LIVE PROVIDER RESULT:"

    private var liveProductPrompt: String {
        """
        Inspect the two uncommitted files and describe how the capture flow changes. Do not modify
        files and do not run tests. Summarize the implementation in two concise sentences. Start
        the final response with exactly:
        \(liveProductMarker)
        """
    }

    /// Starts the installed provider without persisting trust for the throwaway repository.
    /// The override belongs to this one invocation; ordinary live-session history remains owned
    /// by the provider rather than copied into or synthesized by the capture harness.
    private func liveCodexPlan(
        for session: AgentSession,
        in project: Project,
        initialPrompt: String?
    ) -> AgentLaunchPlan {
        precondition(session.kind == .codex && !session.usesNativeUI)

        // Codex canonicalizes its working directory before matching project trust.
        // NSTemporaryDirectory() uses /var on macOS, whose canonical path is /private/var.
        let trustedProjectPath = canonicalFilesystemPath(project.folderPath)

        var command = ShellCommand(word: "env")
        if let accountKey = AgentKind.codex.accountEnvironmentKey {
            command.append(flag: "-u", value: accountKey)
        }
        command.append(word: AgentDefaults.codexExecutable)
        command.append(
            flag: AgentDefaults.codexConfigFlag,
            value: "check_for_update_on_startup=false"
        )
        command.append(
            flag: AgentDefaults.codexConfigFlag,
            // The CLI's dotted override parser does not address quoted path keys. Replace the
            // projects table for this invocation with a TOML inline table instead.
            value: "projects={\"\(trustedProjectPath)\"={trust_level=\"trusted\"}}"
        )
        command.append(flag: AgentDefaults.codexNoAlternateScreenFlag)
        command.append(flag: AgentDefaults.codexApprovalFlag, value: "never")
        command.append(flag: AgentDefaults.codexSandboxFlag, value: "read-only")
        command.append(flag: "--disable", value: "plugins")
        command.append(flag: "--disable", value: "apps")
        command.append(
            flag: AgentDefaults.codexConfigFlag,
            value: "mcp_servers.xcode.enabled=false"
        )
        command.append(
            flag: AgentDefaults.codexConfigFlag,
            value: "mcp_servers.node_repl.enabled=false"
        )
        command.append(
            flag: AgentDefaults.codexConfigFlag,
            value: "mcp_servers.openaiDeveloperDocs.enabled=false"
        )
        command.append(
            flag: AgentDefaults.codexConfigFlag,
            value: "approvals_reviewer=\"user\""
        )
        if let prompt = initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !prompt.isEmpty {
            command.append(operand: prompt)
        }
        let source = ShellCommand.executing(command, in: project.folderPath)
        return AgentLaunchPlan(
            executable: AgentLauncher.loginShellPath,
            arguments: ["-l", "-c", source.source],
            resumeState: .awaitingIdentifier
        )
    }

    private func canonicalFilesystemPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func swiftTermColor(_ color: NSColor) -> Color {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        return Color(
            red: UInt16(srgb.redComponent * 65_535),
            green: UInt16(srgb.greenComponent * 65_535),
            blue: UInt16(srgb.blueComponent * 65_535)
        )
    }

    /// Pins the screenshot pixels, not only the terminal model. The marketing capture once
    /// reported a light palette while the already-created blank cells still rendered black.
    private func assertTerminalBackground(
        in data: Data,
        at point: NSPoint,
        contentSize: NSSize,
        equals expected: NSColor,
        filename: String
    ) throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        let x = min(
            max(Int(point.x / contentSize.width * CGFloat(bitmap.pixelsWide)), 0),
            bitmap.pixelsWide - 1
        )
        let y = min(
            max(Int(point.y / contentSize.height * CGFloat(bitmap.pixelsHigh)), 0),
            bitmap.pixelsHigh - 1
        )
        let sampled = try XCTUnwrap(bitmap.colorAt(
            x: x,
            y: y
        )?.usingColorSpace(.sRGB))
        let reference = try XCTUnwrap(expected.usingColorSpace(.sRGB))
        let distance = max(
            abs(sampled.redComponent - reference.redComponent),
            abs(sampled.greenComponent - reference.greenComponent),
            abs(sampled.blueComponent - reference.blueComponent)
        )
        XCTAssertLessThan(
            distance,
            0.04,
            "\(filename) rendered the terminal over \(sampled), expected \(reference)"
        )
    }

    /// The real controller, laid out the way the app lays it out: the pane is sized and settled
    /// first, and the diff arrives afterwards from what would be a background git read.
    private func laidOutPane(
        _ files: [GitFileDiff],
        appearance: NSAppearance?
    ) -> (view: NSView, cardWidth: CGFloat, controller: GitReviewViewController) {
        let controller = GitReviewViewController(
            sessionID: SessionID(),
            folderPath: NSTemporaryDirectory(),
            mode: .uncommitted
        )
        // Unshown: an ordered-in window would make this an `all`-only test, and nothing here
        // needs one — see "Test levels" in CLAUDE.md.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Render.width, height: 520),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.appearance = appearance
        let content = window.contentView!
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: content.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            controller.view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: content.trailingAnchor)
        ])
        window.layoutIfNeeded()

        controller.show(.files(files))
        AppThemeRefresh.repaint(controller.view)
        window.layoutIfNeeded()

        let card = controller.fileTableView
            .view(atColumn: 0, row: 0, makeIfNecessary: true)?
            .subviews.first
        return (controller.view, card?.bounds.width ?? 0, controller)
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

    private func assertColor(
        _ actual: NSColor,
        equals expected: NSColor,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actual = actual.usingColorSpace(.sRGB),
              let expected = expected.usingColorSpace(.sRGB) else {
            XCTFail("Could not resolve diff wash colours into sRGB", file: file, line: line)
            return
        }
        XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.alphaComponent, expected.alphaComponent, accuracy: 0.001, file: file, line: line)
    }

    private func colorsEqual(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        guard let lhs = lhs.usingColorSpace(.sRGB),
              let rhs = rhs.usingColorSpace(.sRGB) else { return false }
        return abs(lhs.redComponent - rhs.redComponent) < 0.001
            && abs(lhs.greenComponent - rhs.greenComponent) < 0.001
            && abs(lhs.blueComponent - rhs.blueComponent) < 0.001
            && abs(lhs.alphaComponent - rhs.alphaComponent) < 0.001
    }

    private func descendants(in root: NSView) -> [NSView] {
        root.subviews + root.subviews.flatMap { descendants(in: $0) }
    }
}
