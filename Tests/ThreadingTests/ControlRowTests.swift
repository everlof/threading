import AppKit
import XCTest
@testable import Threading

/// The row of controls that belongs to content: one height across every member, the two runs at
/// opposite edges, and the outer two aligned by ink.
///
/// The bug behind it was reported on the Compare tab — *the buttons next to Wipe feel unbalanced
/// and too small* — and every claim here is one half of that sentence. "Too small" is the height
/// tests: a chip stands at the theme's `choiceHeight` and an icon button used to stand at a fixed
/// 20, so the pair were out of level by six points under System and by four the other way under
/// Platinum. "Unbalanced" is the edge tests: the actions were held out by an empty label set to
/// hug loosely, which is not a spring, so they collapsed against the chip instead of reaching
/// the pane's trailing edge.
final class ControlRowTests: XCTestCase {

    private enum Fixture {
        static let width: CGFloat = 460
        /// Comfortably taller and shorter than anything a theme authors, so a member standing at
        /// its own height rather than the row's is a visible failure rather than a rounding one.
        static let tallChoiceHeight: CGFloat = 40
        static let shortChoiceHeight: CGFloat = 16
        /// The display pane's protected minimum — see `BrowserBaselineUITests`.
        static let narrowWidth: CGFloat = 260
    }

    @MainActor
    override func tearDown() {
        AppThemePalette.set(.system)
        super.tearDown()
    }

    // MARK: - One Height

    @MainActor
    func testEveryControlInARowStandsAtTheRowsHeight() {
        let chip = makeChip()
        let picker = makeSegments()
        let accept = ThemedButton(title: "Accept", target: nil, action: nil)
        let export = makeAction("square.and.arrow.up")
        let expand = makeAction("arrow.up.left.and.arrow.down.right")

        let row = ControlRowView(leading: [chip, picker], trailing: [accept, export, expand])
        let host = laidOut(row)
        _ = host

        XCTAssertEqual(row.frame.height, Design.Size.choiceHeight, accuracy: 0.5)
        for member in [chip, picker, accept, export, expand] as [NSView] {
            XCTAssertEqual(
                member.frame.height, row.frame.height, accuracy: 0.5,
                "\(type(of: member)) stood at \(member.frame.height) in a "
                    + "\(row.frame.height)pt row"
            )
        }
    }

    /// The one the screenshot was of: an icon button beside a chip is a *peer* of it, and
    /// `Target.inline` — "nested inside another control" — is a different claim that happened to
    /// be the only one available.
    @MainActor
    func testAnInlineIconButtonIsPromotedRatherThanLeftAtItsNestedSize() {
        // The role's own size, read rather than laid out: a lone button in a fixture pinned to
        // both edges would be stretched by the fixture, which measures the fixture.
        let nested = makeAction("square.and.arrow.up").intrinsicContentSize.height

        let promoted = makeAction("square.and.arrow.up")
        let row = ControlRowView(leading: [makeChip()], trailing: [promoted])
        _ = laidOut(row)

        XCTAssertEqual(nested, Design.Size.inlineButtonTarget, accuracy: 0.5)
        XCTAssertEqual(promoted.frame.height, row.frame.height, accuracy: 0.5)
        XCTAssertGreaterThan(
            promoted.frame.height, nested,
            "the row left its action at the size a nested control uses"
        )
    }

    /// Growing the button without growing its mark is more padding, not more button.
    @MainActor
    func testAPromotedButtonsGlyphGrowsWithIt() {
        let loose = makeAction("square.and.arrow.up")
        let nestedGlyph = loose.intrinsicContentSize.width - loose.opticalHorizontalInset * 2

        let promoted = makeAction("square.and.arrow.up")
        _ = laidOut(ControlRowView(leading: [makeChip()], trailing: [promoted]))
        let promotedGlyph = promoted.frame.width - promoted.opticalHorizontalInset * 2

        XCTAssertGreaterThan(
            promotedGlyph, nestedGlyph,
            "the button grew to \(promoted.frame.width) around a \(promotedGlyph)pt mark"
        )
        XCTAssertEqual(
            promotedGlyph,
            Design.Symbol.slot(inControlOfHeight: Design.Size.choiceHeight),
            accuracy: 0.5
        )
    }

    // MARK: - The Height Is The Theme's

    @MainActor
    func testTheRowAndItsMembersFollowTheThemesChooserHeight() {
        for theme in [
            AppThemeStyles.platinum,
            Self.themed(choiceHeight: Fixture.tallChoiceHeight),
            Self.themed(choiceHeight: Fixture.shortChoiceHeight)
        ] {
            AppThemePalette.set(theme)

            let chip = makeChip()
            let picker = makeSegments()
            let accept = ThemedButton(title: "Accept", target: nil, action: nil)
            let action = makeAction("square.and.arrow.up")
            let row = ControlRowView(leading: [chip, picker], trailing: [accept, action])
            _ = laidOut(row)

            XCTAssertEqual(
                row.frame.height, Design.Size.choiceHeight, accuracy: 0.5,
                "\(theme.name): the row did not take the material's chooser height"
            )
            // Every kind of member, not just the two the report named. A titled button under
            // Platinum falls back to Geneva, whose reported bounding rect is half again its
            // line — a floor taken from that measure stands the button proud of a short row.
            for member in [chip, picker, accept, action] as [NSView] {
                XCTAssertEqual(
                    member.frame.height, row.frame.height, accuracy: 0.5,
                    "\(theme.name): \(type(of: member)) stood at \(member.frame.height) in a "
                        + "\(row.frame.height)pt row"
                )
            }
        }
    }

    /// A row already on screen when the style changes. The material owns the height, so a row
    /// that read it once keeps the geometry of a theme the user has left.
    @MainActor
    func testALiveThemeSwitchRelevelsARowAlreadyLaidOut() {
        let chip = makeChip()
        let action = makeAction("square.and.arrow.up")
        let row = ControlRowView(leading: [chip], trailing: [action])
        let host = laidOut(row)
        let before = row.frame.height

        AppThemePalette.set(Self.themed(choiceHeight: Fixture.tallChoiceHeight))
        row.needsLayout = true
        host.layoutSubtreeIfNeeded()

        XCTAssertNotEqual(row.frame.height, before, accuracy: 0.5)
        XCTAssertEqual(row.frame.height, Fixture.tallChoiceHeight, accuracy: 0.5)
        XCTAssertEqual(
            action.frame.height, row.frame.height, accuracy: 0.5,
            "the row grew and left its action behind at \(action.frame.height)"
        )
        XCTAssertEqual(chip.frame.height, row.frame.height, accuracy: 0.5)
    }

    // MARK: - The Two Edges

    @MainActor
    func testTheActionsReachTheTrailingEdgeRatherThanHuddlingAgainstTheChip() {
        let chip = makeChip()
        let caption = makeCaption("")
        let export = makeAction("square.and.arrow.up")
        let expand = makeAction("arrow.up.left.and.arrow.down.right")

        let row = ControlRowView(leading: [chip, caption], trailing: [export, expand])
        _ = laidOut(row)

        // The ink, not the frame: an icon button's frame carries the padding its hover surface
        // needs, and the row pulls that back out so the mark lands on the margin.
        let trailingInk = placed(expand, in: row).maxX - expand.opticalHorizontalInset
        XCTAssertEqual(
            trailingInk, row.bounds.maxX, accuracy: 0.5,
            "the last action's mark sits \(row.bounds.maxX - trailingInk)pt off the row's edge"
        )
        XCTAssertEqual(placed(chip, in: row).minX, row.bounds.minX, accuracy: 0.5)
        XCTAssertGreaterThan(
            placed(export, in: row).minX - placed(chip, in: row).maxX, Fixture.width / 2,
            "the actions collapsed back against the chip instead of holding the far edge"
        )
    }

    @MainActor
    func testALongCaptionTruncatesRatherThanRunningUnderTheActions() {
        let caption = makeCaption(String(repeating: "a very long comparison name ", count: 12))
        let action = makeAction("square.and.arrow.up")

        let row = ControlRowView(leading: [caption], trailing: [action])
        _ = laidOut(row)

        XCTAssertLessThanOrEqual(
            placed(caption, in: row).maxX, placed(action, in: row).minX,
            "the caption ran under the actions instead of compressing"
        )
        XCTAssertGreaterThan(caption.frame.width, 0)
    }

    /// The display pane's protected minimum, where more controls are asked for than fit.
    ///
    /// `NSStackView` resists clipping at required priority, which outranks the inequality that
    /// holds the two runs apart — so the run kept its full width and drew past the pane rather
    /// than compressing. Caught by `BrowserBaselineUITests`' narrow-pane rule, whose whole
    /// claim is that nothing but scrolled content may be wider than the pane it is in.
    @MainActor
    func testAFullRowCompressesIntoTheNarrowestPaneRatherThanOverflowingIt() {
        let picker = makeSegments()
        let row = ControlRowView(
            leading: [picker, makeChip(), makeCaption("MATCH · 0 of 120000 pixels changed")],
            trailing: [
                ThemedButton(title: "Accept", target: nil, action: nil),
                makeAction("arrow.up.left.and.arrow.down.right")
            ]
        )
        let host = laidOut(row, width: Fixture.narrowWidth)

        var overflowing: [NSView] = []
        func walk(_ view: NSView) {
            if view.frame.width > Fixture.narrowWidth + 1 { overflowing.append(view) }
            view.subviews.forEach(walk)
        }
        walk(host)

        XCTAssertEqual(
            overflowing.map { "\(type(of: $0)) \(Int($0.frame.width))pt" }, [],
            "the row drew past a \(Int(Fixture.narrowWidth))pt pane"
        )
    }

    // MARK: - Membership

    @MainActor
    func testAHiddenMemberLeavesTheRowRatherThanHoldingItsPlace() {
        let back = makeAction("chevron.left")
        let chip = makeChip()
        let row = ControlRowView(leading: [back, chip], trailing: [])
        let host = laidOut(row)

        let indented = placed(chip, in: row).minX
        XCTAssertGreaterThan(indented, row.bounds.minX)

        back.isHidden = true
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            placed(chip, in: row).minX, row.bounds.minX, accuracy: 0.5,
            "the chip stayed indented past a button that is not on screen"
        )
    }

    @MainActor
    func testReconfiguringTakesAwayWhatTheRowNoLongerHolds() {
        let chip = makeChip()
        let caption = makeCaption("one.png → two.png")
        let export = makeAction("square.and.arrow.up")

        let row = ControlRowView(leading: [chip, caption], trailing: [export])
        let host = laidOut(row)
        XCTAssertTrue(chip.isDescendant(of: row))

        row.configure(leading: [caption], trailing: [export])
        host.layoutSubtreeIfNeeded()

        XCTAssertNil(chip.superview, "the row kept a view it no longer lists")
        XCTAssertFalse(chip.isDescendant(of: row))
        XCTAssertTrue(caption.isDescendant(of: row))
        XCTAssertEqual(placed(caption, in: row).minX, row.bounds.minX, accuracy: 0.5)
    }

    // MARK: - The Reported Surface

    /// The Compare tab itself, which is where this was seen. The mode chip, the export and the
    /// expand are the three controls in the screenshot.
    @MainActor
    func testTheCompareTabsHeaderStandsLevelAndHoldsBothEdges() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let old = root.appendingPathComponent("one.png")
        let new = root.appendingPathComponent("two.png")
        try Self.png(.systemRed).write(to: old)
        try Self.png(.systemBlue).write(to: new)

        let controller = CompareViewController(
            sessionID: SessionID(),
            oldPath: old.path,
            newPath: new.path,
            oldTitle: nil,
            newTitle: nil,
            mode: .wipeHorizontal
        )
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 420))
        host.addSubview(controller.view)
        controller.view.frame = host.bounds
        controller.view.autoresizingMask = [.width, .height]
        controller.refresh(force: true)

        let loaded = expectation(description: "compare read both files")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { loaded.fulfill() }
        wait(for: [loaded], timeout: 5)
        host.layoutSubtreeIfNeeded()

        let row = try XCTUnwrap(
            descendants(of: controller.view, type: ControlRowView.self).first,
            "the Compare tab no longer builds its header as a control row"
        )
        let chip = try XCTUnwrap(descendants(of: row, type: ChipView.self).first)
        let actions = descendants(of: row, type: ThemedIconButton.self)
        XCTAssertEqual(actions.count, 2, "expected the export and the expand")

        for action in actions {
            XCTAssertEqual(
                action.frame.height, chip.frame.height, accuracy: 0.5,
                "an action stood at \(action.frame.height) beside a \(chip.frame.height)pt chip"
            )
        }

        let last = try XCTUnwrap(
            actions.max { placed($0, in: row).maxX < placed($1, in: row).maxX }
        )
        let inkRight = placed(last, in: row).maxX - last.opticalHorizontalInset
        XCTAssertEqual(
            inkRight, row.bounds.maxX, accuracy: 0.5,
            "the actions do not reach the header's trailing edge"
        )
    }

    /// The publish strip was the same defect as the Compare header: a chooser and a button in
    /// a plain stack, with each control choosing its own geometry. Bauhaus made the disagreement
    /// unmistakable because both interactive faces also carry a hard four-point shadow.
    @MainActor
    func testTheChangeRequestBarLevelsItsChooserAndAction() throws {
        AppThemePalette.set(AppThemeStyles.bauhaus)

        let bar = GitReviewChangeRequestBar()
        bar.configure(
            title: "Publish feature/control-row",
            detail: "feature/control-row → master",
            status: "No checks",
            statusColor: Design.Text.tertiary,
            actionTitle: "Create pull request",
            actionEnabled: true,
            showsOpen: false,
            policy: .reviewBeforePublishing
        )
        _ = laidOut(
            bar,
            height: 80,
            width: 720,
            viewHeight: GitReviewChangeRequestDefaults.barHeight
        )

        let row = try XCTUnwrap(
            descendants(of: bar, type: ControlRowView.self).first,
            "the publish strip bypassed the control-row geometry"
        )
        let chooser = try XCTUnwrap(descendants(of: row, type: ChipView.self).first)
        let action = try XCTUnwrap(
            descendants(of: row, type: ThemedButton.self).first {
                $0.title == "Create pull request"
            }
        )

        XCTAssertEqual(chooser.frame.height, row.frame.height, accuracy: 0.5)
        XCTAssertEqual(action.frame.height, row.frame.height, accuracy: 0.5)
        XCTAssertEqual(
            placed(chooser, in: row).midY,
            placed(action, in: row).midY,
            accuracy: 0.5,
            "the publish chooser and action do not share one visual centreline"
        )
    }

    /// The compact policy title can sound like an instruction to the coding agent. Its menu
    /// carries the scope quietly, on the second line of each choice, where it is visible at the
    /// moment somebody is comparing the policies without adding permanent chrome to the bar.
    @MainActor
    func testChangeRequestPolicyMenuExplainsEachChoice() throws {
        let bar = GitReviewChangeRequestBar()
        bar.configure(
            title: "Publish feature/policy-copy",
            detail: "feature/policy-copy → master",
            status: "No checks",
            statusColor: Design.Text.tertiary,
            actionTitle: "Create pull request…",
            actionEnabled: true,
            showsOpen: false,
            policy: .pushOnly
        )

        let chip = try XCTUnwrap(descendants(of: bar, type: ChipView.self).first)
        let entries = try XCTUnwrap(chip.itemsProvider?())
        let items: [ThemedMenuItem] = entries.compactMap { entry in
            guard case .item(let item) = entry else { return nil }
            return item
        }

        XCTAssertEqual(items.count, ChangeRequestPublishPolicy.allCases.count)
        for policy in ChangeRequestPublishPolicy.allCases {
            let item = try XCTUnwrap(items.first { $0.title == policy.title })
            XCTAssertEqual(item.subtitle, policy.explanation)
            XCTAssertTrue(
                try XCTUnwrap(item.subtitle).hasPrefix("Git Review"),
                "the explanation must name the surface whose behavior this policy controls"
            )
        }
        XCTAssertEqual(chip.toolTip, ChangeRequestPublishPolicy.pushOnly.explanation)
        XCTAssertEqual(
            chip.accessibilityHelp(),
            ChangeRequestPublishPolicy.pushOnly.explanation
        )
    }

    /// "Default branch" describes the repository; it does not do anything. Presenting it as a
    /// disabled primary button made Bauhaus correctly remove its action depth while the live
    /// policy chooser kept its shadow, leaving two neighbouring surfaces with different rules.
    @MainActor
    func testDefaultBranchIsCopyRatherThanADisabledPrimaryAction() throws {
        let repository = ChangeRequestRepository(
            provider: .github,
            host: "github.com",
            namespace: "threading",
            name: "threading"
        )
        let controller = GitReviewViewController(
            sessionID: SessionID(),
            folderPath: NSTemporaryDirectory(),
            mode: .uncommitted,
            changeRequestProviders: .githubFixture(GitHubPullRequestClient(resolver: nil))
        )
        _ = controller.view
        controller.changeRequestLocalState = ChangeRequestLocalState(
            root: URL(fileURLWithPath: NSTemporaryDirectory()),
            branch: "master",
            headRevision: "0123456789abcdef",
            remote: "https://github.com/threading/threading.git",
            upstream: "origin/master",
            ahead: 0,
            behind: 0,
            hasUncommittedChanges: true
        )
        controller.changeRequestRepositoryStatus = ChangeRequestRepositoryStatus(
            repository: repository,
            defaultBranch: "master",
            branch: "master",
            changeRequest: nil,
            checks: .unavailable
        )

        controller.renderChangeRequestBar()

        let labels = descendants(of: controller.changeRequestBar, type: NSTextField.self)
        XCTAssertTrue(
            labels.contains { $0.stringValue.contains("Default branch") },
            "the static repository state disappeared with the fake action"
        )
        XCTAssertFalse(
            descendants(of: controller.changeRequestBar, type: ThemedButton.self)
                .contains { !$0.isHidden },
            "a non-action is still presented as a disabled button"
        )
    }

    // MARK: - Rendered

    @MainActor
    func testRendersAControlRowAcrossThemes() throws {
        let directory = renderDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fixtures: [(name: String, theme: AppTheme, appearance: NSAppearance.Name)] = [
            ("system-light", .system, .aqua),
            ("system-dark", .system, .darkAqua),
            ("platinum", AppThemeStyles.platinum, .aqua),
            ("tall", Self.themed(choiceHeight: Fixture.tallChoiceHeight), .darkAqua)
        ]

        for fixture in fixtures {
            AppThemePalette.set(fixture.theme)

            let row = ControlRowView(
                leading: [makeChip(), makeCaption("one.png → two.png")],
                trailing: [
                    ThemedButton(title: "Accept", target: nil, action: nil),
                    makeAction("square.and.arrow.up"),
                    makeAction("arrow.up.left.and.arrow.down.right")
                ]
            )
            let host = laidOut(row, height: 80)
            let appearance = try XCTUnwrap(NSAppearance(named: fixture.appearance))
            host.appearance = appearance
            row.appearance = appearance
            AppThemeRefresh.repaint(host)
            host.layoutSubtreeIfNeeded()

            var data: Data?
            appearance.performAsCurrentDrawingAppearance {
                data = self.png(of: host)
            }
            let url = directory.appendingPathComponent("control-row-\(fixture.name).png")
            try XCTUnwrap(data, "no render for \(fixture.name)").write(to: url)
        }

        print("Rendered control rows to \(directory.path)")
    }

    /// The exact state from the report: the checkout is already on its default branch, so the
    /// policy remains a chooser and the repository state is copy rather than a counterfeit CTA.
    @MainActor
    func testRendersTheDefaultBranchPublishStripUnderBauhaus() throws {
        let directory = renderDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        AppThemePalette.set(AppThemeStyles.bauhaus)

        let bar = GitReviewChangeRequestBar()
        bar.configure(
            title: "Publish master",
            detail: "master → master · uncommitted changes stay local · Default branch",
            status: "",
            statusColor: Design.Text.tertiary,
            actionTitle: nil,
            actionEnabled: false,
            showsOpen: false,
            policy: .reviewBeforePublishing
        )
        let host = laidOut(
            bar,
            height: 80,
            width: 720,
            viewHeight: GitReviewChangeRequestDefaults.barHeight
        )
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        host.appearance = appearance
        bar.appearance = appearance
        AppThemeRefresh.repaint(host)
        host.layoutSubtreeIfNeeded()

        var data: Data?
        appearance.performAsCurrentDrawingAppearance {
            data = self.png(of: host)
        }
        let url = directory.appendingPathComponent("change-request-bar-bauhaus-default.png")
        try XCTUnwrap(data, "no Bauhaus publish-strip render").write(to: url)
        print("Rendered the Bauhaus publish strip to \(url.path)")
    }

    /// The Compare tab itself, drawn. The synthetic row above proves the component; this proves
    /// the surface the report was about, which is a different claim — the tab assembles its row
    /// from the compare surface's own controls plus two of its own.
    @MainActor
    func testRendersTheCompareTabsHeader() throws {
        let directory = renderDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("Screenshot 2026-08-05.png")
        let new = root.appendingPathComponent("composer-system-light-short.png")
        try Self.png(.systemTeal).write(to: old)
        try Self.png(.systemPurple).write(to: new)

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            AppThemePalette.set(.system)
            let controller = CompareViewController(
                sessionID: SessionID(),
                oldPath: old.path,
                newPath: new.path,
                oldTitle: nil,
                newTitle: nil,
                mode: .wipeHorizontal
            )
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: 260))
            host.addSubview(controller.view)
            controller.view.frame = host.bounds
            controller.view.autoresizingMask = [.width, .height]
            controller.refresh(force: true)

            let loaded = expectation(description: "compare read both files")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { loaded.fulfill() }
            wait(for: [loaded], timeout: 5)

            let resolved = try XCTUnwrap(NSAppearance(named: appearance))
            host.appearance = resolved
            controller.view.appearance = resolved
            AppThemeRefresh.repaint(host)
            host.layoutSubtreeIfNeeded()

            var data: Data?
            resolved.performAsCurrentDrawingAppearance {
                data = self.png(of: host)
            }
            let url = directory.appendingPathComponent("compare-tab-\(name).png")
            try XCTUnwrap(data, "no render for \(name)").write(to: url)
        }

        print("Rendered the Compare tab to \(directory.path)")
    }

    // MARK: - Helpers

    @MainActor
    private func makeChip() -> ChipView {
        let chip = ChipView()
        chip.configure(symbolName: "rectangle.split.2x1", title: "Wipe ↔")
        return chip
    }

    @MainActor
    private func makeAction(_ symbol: String) -> ThemedIconButton {
        ThemedIconButton(
            symbolName: symbol,
            accessibility: symbol,
            target: .inline,
            inkSource: .chrome
        )
    }

    @MainActor
    private func makeSegments() -> ThemedSegmentedControl {
        let control = ThemedSegmentedControl()
        control.configure(titles: ["Baseline", "Difference"], selectedIndex: 0)
        return control
    }

    @MainActor
    private func makeCaption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.applyFont(.caption)
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    /// A theme whose only interesting property is the height it authors for a chooser.
    @MainActor
    private static func themed(choiceHeight: CGFloat) -> AppTheme {
        var material = AppTheme.Material.system
        material.choiceHeight = choiceHeight
        let variant = AppTheme.Variant(
            roles: AppThemeStyles.platinum.variants[.light]?.roles ?? [:],
            terminalPalette: .basic,
            material: material
        )
        return AppTheme(
            id: AppThemeID("control-row-fixture-\(Int(choiceHeight))"),
            name: "Fixture \(Int(choiceHeight))",
            mode: .system,
            summary: nil,
            variants: [.light: variant, .dark: variant]
        )
    }

    private var renderDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ThreadingRenders", isDirectory: true)
    }

    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ControlRowTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func png(_ color: NSColor) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 24, pixelsHigh: 24, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(x: 0, y: 0, width: 24, height: 24).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    /// An unshown host, which is all any of this needs — see CLAUDE.md on fixture windows.
    ///
    /// **The host states its own size as a constraint, not only as a frame.** A detached view
    /// with a frame and no width constraint pins nothing: the engine is free to lay a subtree
    /// out wider than its container, and it does. A fixture built that way reports a row
    /// "overflowing" a pane that was never asking it to fit, which is a test failing at its own
    /// scaffolding — this one did, and the compression it was accusing the row of skipping was
    /// working the whole time.
    ///
    /// The row is inset like a pane's content, for the same reason: a control aligned by ink has
    /// its hover surface reaching past the margin its glyph sits on, and flush against the host
    /// there is nowhere for that overhang to go.
    @MainActor
    @discardableResult
    private func laidOut(
        _ view: NSView,
        height: CGFloat = 60,
        width: CGFloat = Fixture.width,
        viewHeight: CGFloat? = nil
    ) -> NSView {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        var constraints = [
            host.widthAnchor.constraint(equalToConstant: width),
            host.heightAnchor.constraint(equalToConstant: height),
            view.leadingAnchor.constraint(
                equalTo: host.leadingAnchor, constant: Design.Spacing.inset
            ),
            view.trailingAnchor.constraint(
                equalTo: host.trailingAnchor, constant: -Design.Spacing.inset
            ),
            view.centerYAnchor.constraint(equalTo: host.centerYAnchor)
        ]
        if let viewHeight {
            constraints.append(view.heightAnchor.constraint(equalToConstant: viewHeight))
        }
        NSLayoutConstraint.activate(constraints)
        host.layoutSubtreeIfNeeded()
        return host
    }

    /// Where a member sits *in the row*, by its alignment rect.
    ///
    /// Two conversions in one, and both are load-bearing. A member lives inside one of the row's
    /// two runs, so its own `frame` is that run's coordinate space and reads as though every
    /// control were at the leading edge. And a label's frame is a couple of points wider than the
    /// letters in it — layout aligns the *alignment rect*, which is what the row's edges are
    /// measured against.
    @MainActor
    private func placed(_ view: NSView, in row: ControlRowView) -> NSRect {
        let aligned = view.alignmentRect(forFrame: view.frame)
        guard let parent = view.superview else { return aligned }
        return parent.convert(aligned, to: row)
    }

    @MainActor
    private func descendants<T: NSView>(of root: NSView, type: T.Type) -> [T] {
        var found: [T] = []
        for view in root.subviews {
            if let match = view as? T { found.append(match) }
            found += descendants(of: view, type: type)
        }
        return found
    }

    @MainActor
    private func png(of host: NSView) -> Data? {
        guard host.bounds.height > 1,
              let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.wantsLayer = true
        host.layer?.backgroundColor = AppThemePalette.current.resolved(.ground).cgColor
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
