import AppKit
import XCTest
@testable import Threading

/// Draws review-pane file rows through the real views and writes them out as images.
///
/// `ConversationRenderTests`' reason applies here twice over: syntax highlighting is a claim
/// about *colour on a coloured wash*, and no assertion about token ranges can say whether an
/// orange string is legible on a green added line, in both appearances. The layout assertions
/// come along for free.
@MainActor
final class GitReviewRenderTests: XCTestCase {

    // MARK: - Configuration

    private enum Render {
        /// The display pane's real working width, the same measure the conversation renders use.
        static let width: CGFloat = 720

        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] {
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

    /// The website's Threading-theme product capture. It names the same two decisions the
    /// fixture demonstrates: the title band keeps one clean identity, and the theme page points
    /// at a named capture rather than an unrelated audit surface.
    private let productFixture = """
    diff --git a/Sources/Threading/Core/Theme/AppThemeStyles.swift b/Sources/Threading/Core/Theme/AppThemeStyles.swift
    index 1111111..2222222 100644
    --- a/Sources/Threading/Core/Theme/AppThemeStyles.swift
    +++ b/Sources/Threading/Core/Theme/AppThemeStyles.swift
    @@ -170,7 +170,7 @@ enum AppThemeStyles {
                         buttonGlyphStyle: .plain,
                         buttonPlacement: .trailing,
    -                    showsAppIcon: true,
    +                    showsAppIcon: false,
                         activeTexture: .init(kind: .rule, color: hex("#FF9A3D")),
                         inactiveTexture: .init(kind: .rule, color: hex("#2B4B65"))
                     ),
    diff --git a/web/app/ThemePlayground.tsx b/web/app/ThemePlayground.tsx
    index 3333333..4444444 100644
    --- a/web/app/ThemePlayground.tsx
    +++ b/web/app/ThemePlayground.tsx
    @@ -30,7 +30,7 @@ const captures: Capture[] = [
         slug: "threading",
         name: "Threading",
         detail: "A navy frame, warm text, and Threading orange.",
    -    image: "/product/mac-browser-audit.png",
    +    image: "/product/mac-threading-chat-review.png",
         ground: "#040a12",
         surface: "#0a1c2f",
         ink: "#f7efe6",
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

        print("Rendered the review pane to \(directory.path)")
    }

    /// The product capture is the real native conversation beside the real Git Review pane.
    /// The same fixture is rendered through every theme used by the website scroll story, so
    /// its mask changes only the app's dress and never swaps the product story underneath it.
    func testRendersThreadingConversationWithGitReviewPane() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { AppThemePalette.set(.system) }

        let fixtures: [(filename: String, theme: AppTheme, appearance: NSAppearance.Name)] = [
            ("threading-chat-git-review.png", AppThemeStyles.threading, .darkAqua),
            ("theme-chat-review-system-dark.png", .system, .darkAqua),
            ("theme-chat-review-cyberpunk-dark.png", AppThemeStyles.cyberpunk, .darkAqua),
            ("theme-chat-review-swiss-light.png", AppThemeStyles.swissMinimalist, .aqua),
            ("theme-chat-review-neo-brutalism-light.png", AppThemeStyles.neoBrutalism, .aqua),
            ("theme-chat-review-claymorphism-light.png", AppThemeStyles.claymorphism, .aqua),
            ("theme-chat-review-vaporwave-dark.png", AppThemeStyles.vaporwave, .darkAqua)
        ]

        for fixture in fixtures {
            AppThemePalette.set(fixture.theme)
            let appearance = try XCTUnwrap(NSAppearance(named: fixture.appearance))
            var result: (data: Data?, showsAppIcon: Bool)?
            appearance.performAsCurrentDrawingAppearance {
                result = self.threadingConversationWithGitReview(appearance: appearance)
            }

            let rendered = try XCTUnwrap(result)
            if fixture.theme.id == AppThemeStyles.threading.id {
                XCTAssertFalse(
                    rendered.showsAppIcon,
                    "Threading's title band should not repeat the app mark"
                )
            }
            try XCTUnwrap(rendered.data, "failed to render \(fixture.filename)")
                .write(to: directory.appendingPathComponent(fixture.filename))
        }
        print("Rendered the theme chat and review captures to \(directory.path)")
    }

    private func threadingConversationWithGitReview(
        appearance: NSAppearance
    ) -> (data: Data?, showsAppIcon: Bool) {
        let size = NSSize(width: 1_280, height: 760)
        let project = Project(
            name: "Threading",
            folderURL: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        )
        let session = AgentSession(
            kind: .claude,
            title: "Theme showcase",
            usesNativeUI: true
        )
        let conversation = requireConversationViewController(
            agentSession: session,
            project: project,
            customizationLookup: { _ in .empty }
        )
        let review = GitReviewViewController(
            sessionID: session.id,
            folderPath: project.folderPath,
            mode: .uncommitted
        )

        let split = SidebarSplitViewController()
        let conversationItem = NSSplitViewItem(viewController: conversation)
        conversationItem.minimumThickness = 560
        let reviewItem = NSSplitViewItem(viewController: review)
        reviewItem.minimumThickness = 420
        split.addSplitViewItem(conversationItem)
        split.addSplitViewItem(reviewItem)

        let host = WindowChromeHostViewController(workspace: split)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentViewController = host
        window.setContentSize(size)
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFront(nil)
        defer { window.close() }

        host.setTitle("Threading")
        host.setTakeoverActive(true)
        host.bandView.fixtureIsKey = true
        host.commandBandView.setLeadingControls(makeProductWindowControls())
        host.view.frame = NSRect(origin: .zero, size: size)
        host.view.appearance = appearance
        host.view.layoutSubtreeIfNeeded()
        split.splitView.setPosition(720, ofDividerAt: 0)
        host.view.layoutSubtreeIfNeeded()

        applyProductConversation(to: conversation)
        review.show(.files(GitDiffParser.files(fromUnifiedDiff: productFixture)))
        conversation.scrollToConversationEnd()
        AppThemeRefresh.repaint(host.view)
        host.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        conversation.scrollToConversationEnd()
        host.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        window.makeFirstResponder(nil)

        guard let content = window.contentView,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            return (nil, host.bandView.showsApplicationIcon)
        }
        content.cacheDisplay(in: content.bounds, to: rep)
        return (
            rep.representation(using: .png, properties: [:]),
            host.bandView.showsApplicationIcon
        )
    }

    private func applyProductConversation(to conversation: ConversationViewController) {
        let patch = """
        *** Begin Patch
        *** Update File: Sources/Threading/Core/Theme/AppThemeStyles.swift
        @@
        -                    showsAppIcon: true,
        +                    showsAppIcon: false,
        *** End Patch
        """
        let events: [StreamEvent] = [
            .userMessage(
                "The theme page should show the app people actually use, not Execution Audit."
            ),
            .assistantMessage(blocks: [
                .text("I will use a populated native conversation with Git Review open beside it. The website will read the image through a named screenshot reference.")
            ]),
            .turnFinished(
                text: nil,
                outcome: .completed,
                metrics: TurnMetrics(
                    duration: 8.7,
                    outputTokens: 132,
                    effort: "high",
                    contextTokens: 37_600,
                    contextWindow: 200_000
                )
            ),
            .userMessage(
                "Give the Threading theme a cleaner title bar, then show the real change beside this chat."
            ),
            .assistantMessage(blocks: [
                .thinking("I will keep the title and window controls, remove the repeated mark, and verify the diff in the app."),
                .toolUse(
                    id: "edit-threading-chrome",
                    tool: .edit,
                    input: ["patch": .string(patch)]
                )
            ]),
            .toolResults([
                ToolResult(
                    toolUseID: "edit-threading-chrome",
                    text: "Applied the title-bar change.",
                    isError: false
                )
            ]),
            .assistantMessage(blocks: [
                .text("The repeated app mark is gone. Git Review is open on the right with the exact files changed.")
            ]),
            .turnFinished(
                text: nil,
                outcome: .completed,
                metrics: TurnMetrics(
                    duration: 12.4,
                    outputTokens: 214,
                    effort: "high",
                    contextTokens: 38_400,
                    contextWindow: 200_000
                )
            )
        ]

        for event in events {
            for change in conversation.timeline.apply(event) {
                conversation.apply(change)
            }
        }
    }

    /// Uses the same app-owned command controls the main window installs in this band.
    private func makeProductWindowControls() -> [NSView] {
        let sidebar = ThemedIconButton(
            symbolName: "sidebar.leading",
            accessibility: L10n.string("Show or hide sidebar"),
            inkSource: .chrome
        )
        let back = ThemedIconButton(
            symbolName: "chevron.left",
            accessibility: L10n.string("Go back"),
            inkSource: .chrome
        )
        back.isEnabled = false
        let forward = ThemedIconButton(
            symbolName: "chevron.right",
            accessibility: L10n.string("Go forward"),
            inkSource: .chrome
        )
        forward.isEnabled = false
        return [sidebar, back, forward]
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
