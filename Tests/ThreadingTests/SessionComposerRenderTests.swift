import AppKit
import XCTest
@testable import Threading

/// The redesigned composer: bottom-flush, a hero floating in the room above, two chips over the
/// box answering where and who, and a location chip that makes "no project yet" a mode rather
/// than a wall. Geometry and legibility are reviewed on the renders; the behavior the layout
/// promises is asserted.
@MainActor
final class SessionComposerRenderTests: XCTestCase {

    private enum Render {
        static let tall = NSSize(width: 900, height: 640)
        static let short = NSSize(width: 720, height: 300)

        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }
    }

    override func tearDown() {
        AppThemePalette.set(.system)
        super.tearDown()
    }

    // MARK: - Behavior

    /// The send is the glyph in the box's own footer now, so "cannot start nowhere" is a
    /// disabled submission with a stated reason rather than a dimmed button beside the box.
    func testNilProjectModeDisablesTheSendAndSaysWhy() throws {
        let composer = SessionComposerViewController()
        _ = composer.view

        composer.show(projectID: nil)
        let prompt = try XCTUnwrap(promptView(in: composer.view))
        XCTAssertFalse(prompt.isSubmissionEnabled, "A session cannot start nowhere")
        XCTAssertEqual(
            prompt.submissionDisabledReason,
            "Choose a project first",
            "a dead control has to say what would make it live"
        )
        XCTAssertEqual(
            try sendGlyph(in: prompt).toolTip,
            "Choose a project first",
            "a glyph has no room for a sentence; its tooltip is where the reason goes"
        )

        let store = ProjectStore.shared
        let project = store.addProject(
            folderURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("threading-composer-start-\(UUID().uuidString)")
        )
        defer { store.removeProject(id: project.id) }

        composer.show(projectID: project.id)
        XCTAssertTrue(prompt.isSubmissionEnabled)
        XCTAssertNil(prompt.submissionDisabledReason, "the reason outlived the reason")
        XCTAssertEqual(
            try sendGlyph(in: prompt).toolTip,
            "Send · ⌘Return",
            "with nothing left to explain, the glyph goes back to naming its chord"
        )
    }

    /// The composer's own reading of the footer contract: the choices lead, what is left to
    /// spend and the surface trail, and the send closes the row.
    ///
    /// Configured by hand rather than by `show`, because which of these a real machine draws
    /// depends on how many logins the agent has and whether it renders natively — and the
    /// arrangement is the same question either way. A stack detaches a hidden arranged view from
    /// the hierarchy outright, so an environment-dependent chip is not merely invisible here, it
    /// is absent.
    func testTheBoxsFooterCarriesTheChoicesThenTheReadingThenTheSend() throws {
        let composer = SessionComposerViewController()
        let host = host(composer, size: Render.tall)

        let prompt = try XCTUnwrap(promptView(in: composer.view))
        let model = try XCTUnwrap(chip(named: "composer.session-start.model", in: composer.view))
        let mode = try XCTUnwrap(chip(named: "composer.session-start.mode", in: composer.view))
        let effort = try XCTUnwrap(chip(named: "composer.session-start.effort", in: composer.view))
        let surface = try XCTUnwrap(chip(named: "composer.session-start.surface", in: composer.view))
        let usage = try XCTUnwrap(usageLabel(in: composer.view))

        model.configure(symbolName: "cpu", title: "Fable 5 · 1M")
        mode.configure(symbolName: "hand.raised", title: "Ask")
        effort.configure(symbolName: "brain", title: "Extra High")
        surface.configure(symbolName: "bubble.left.and.text.bubble.right", title: "Terminal")
        usage.stringValue = "5h 43% · 7d 73%"
        usage.isHidden = false
        host.layoutSubtreeIfNeeded()

        // Every one of them is drawn inside the box rather than on the pane beside it.
        for control in [model, mode, effort, surface, usage] as [NSView] {
            XCTAssertTrue(
                control.isDescendant(of: prompt),
                "\(Swift.type(of: control)) stayed outside the box it belongs to"
            )
        }

        let send = try sendGlyph(in: prompt)
        let inBox = { (view: NSView) in view.convert(view.bounds, to: prompt) }

        XCTAssertLessThan(inBox(model).maxX, inBox(mode).minX, "model leads the row, then mode")
        XCTAssertLessThan(inBox(mode).maxX, inBox(effort).minX, "mode leads effort")
        XCTAssertLessThan(inBox(effort).maxX, inBox(usage).minX)
        XCTAssertLessThan(inBox(usage).maxX, inBox(surface).minX, "the reading precedes the surface")
        XCTAssertLessThan(inBox(surface).maxX, inBox(send).minX, "the send closes the row")

        // The trailing group reaches the box's own edge rather than trailing the leading one.
        XCTAssertGreaterThan(
            inBox(usage).minX - inBox(effort).maxX,
            inBox(mode).minX - inBox(model).maxX,
            "nothing pushed the reading and the send to the trailing edge"
        )
    }

    /// The chip row above the box answers where and who — two questions, two chips. It held
    /// four, and a project and its checkout are one place, an agent and its login one identity;
    /// the reader was assembling each answer out of parts. Everything the session *runs with*
    /// is inside the box, and a chip standing in both places would be two controls for one
    /// decision.
    func testTheChipRowAboveTheBoxHoldsOnlyWhereAndWho() throws {
        let composer = SessionComposerViewController()
        _ = composer.view

        let prompt = try XCTUnwrap(promptView(in: composer.view))
        let names = { (chips: [ChipView]) in
            Set(chips.compactMap { $0.accessibilityIdentifier() })
        }
        let all = descendants(of: composer.view).compactMap { $0 as? ChipView }

        XCTAssertEqual(
            names(all.filter { !$0.isDescendant(of: prompt) }),
            [
                "composer.session-start.location",
                "composer.session-start.identity"
            ],
            "the row above the box is where and who, and nothing else"
        )
        XCTAssertEqual(
            names(all.filter { $0.isDescendant(of: prompt) }),
            [
                "composer.session-start.model",
                "composer.session-start.mode",
                "composer.session-start.effort",
                "composer.session-start.surface"
            ],
            "what the session runs with belongs on the box's own row"
        )
    }

    /// What the two chips say, in the shapes a real machine produces.
    ///
    /// Asserted on the builders as well as through the chips, because the second half of an
    /// identity depends on the machine the test runs on: logins are discovered from the user's
    /// own config directories and there is no seam that hands this one two of them. The rule —
    /// name the login only where there is a choice of one — is the builder's, and the chip's
    /// job is to pass it the count it discovered.
    func testTheTwoChipsNameOnePlaceAndOneIdentity() throws {
        XCTAssertEqual(
            ComposerDefaults.locationTitle(project: "AnotherTerminal", branch: "master"),
            "AnotherTerminal ▸ master",
            "a checkout is inside a project and has to read that way"
        )
        XCTAssertEqual(
            ComposerDefaults.locationTitle(project: "Notes", branch: nil),
            "Notes",
            "a folder outside a repository has no checkout to name"
        )
        XCTAssertEqual(
            ComposerDefaults.locationTitle(project: nil, branch: nil),
            "Choose a project…",
            "with nowhere to run, the chip is the ask"
        )

        XCTAssertEqual(
            ComposerDefaults.identityTitle(agent: "Claude Code", account: "work"),
            "Claude Code · work",
            "an agent and its login are peers, joined the way 'Opus · 1M' is"
        )
        XCTAssertEqual(
            ComposerDefaults.identityTitle(agent: "Codex", account: nil),
            "Codex",
            "a single-login agent must not spend half the chip on an unactionable fact"
        )
    }

    /// The live chip, against a real checkout on disk: the repository leads, the branch
    /// follows, and the tooltip carries the folder the truncated title cannot.
    func testTheLocationChipReadsTheRepositoryThenTheCheckout() throws {
        let repository = try gitFixture(branch: "master")
        defer { try? FileManager.default.removeItem(at: repository.deletingLastPathComponent()) }

        let store = ProjectStore.shared
        let project = store.addProject(folderURL: repository)
        let plain = store.addProject(folderURL: fixtureFolder())
        defer {
            store.removeProject(id: project.id)
            store.removeProject(id: plain.id)
        }

        let composer = SessionComposerViewController()
        _ = composer.view
        let chip = try XCTUnwrap(chip(named: "composer.session-start.location", in: composer.view))

        composer.show(projectID: project.id)
        XCTAssertEqual(chip.accessibilityTitle(), "\(project.name) ▸ master")
        XCTAssertEqual(
            chip.toolTip,
            "\(project.folderPath) ▸ master",
            "the tooltip answers with the folder, which is what a breadcrumb leaves out"
        )

        composer.show(projectID: plain.id)
        XCTAssertEqual(chip.accessibilityTitle(), plain.name)
        XCTAssertEqual(chip.toolTip, plain.folderPath)

        composer.show(projectID: nil)
        XCTAssertEqual(chip.accessibilityTitle(), "Choose a project…")
        XCTAssertNil(chip.toolTip, "there is no folder to name yet")
    }

    /// One menu, two verbs, kept in two sections. Choosing a checkout routes *this* session and
    /// leaves the composer standing; choosing a project navigates away from it and resets every
    /// choice in it — including the words in the box. Flattened into one list of places, the
    /// first mis-click would take a half-written brief with it.
    func testTheLocationMenuKeepsRunningHereApartFromGoingElsewhere() throws {
        let repository = try gitFixture(branch: "master")
        defer { try? FileManager.default.removeItem(at: repository.deletingLastPathComponent()) }

        let store = ProjectStore.shared
        let project = store.addProject(folderURL: repository)
        defer { store.removeProject(id: project.id) }

        let composer = SessionComposerViewController()
        _ = composer.view
        composer.show(projectID: project.id)

        let chip = try XCTUnwrap(chip(named: "composer.session-start.location", in: composer.view))
        let entries = try XCTUnwrap(chip.preparedPresentation()).entries
        let titles = entries.compactMap(\.item).map(\.title)

        let current = try XCTUnwrap(entries.first?.item)
        XCTAssertEqual(current.title, "master  (this checkout)")
        XCTAssertTrue(current.isSelected, "the checkout the session would run in leads, chosen")
        XCTAssertFalse(
            current.title.contains("—"),
            "no em dash in UI copy; the suffix is parenthesised like '(account default)'"
        )
        XCTAssertTrue(titles.contains("New Worktree…"), "making a place is offered where places are")

        let switchProject = try XCTUnwrap(entries.last?.item)
        XCTAssertEqual(switchProject.title, "Switch Project")
        let projects = try XCTUnwrap(switchProject.submenu).compactMap(\.item)
        XCTAssertTrue(
            projects.contains { $0.title == project.name && $0.isSelected },
            "the project the composer is on has to be marked in the list it can leave by"
        )
        XCTAssertEqual(
            projects.suffix(2).map(\.title),
            ["Add Existing Folder…", "Create New Folder…"],
            "the two ways to bring a project in stayed with the projects"
        )
        XCTAssertNil(
            switchProject.representedValue,
            "a parent row is the way in, not an answer of its own"
        )
    }

    /// With no project there is nothing to keep the projects apart from, so they *are* the
    /// menu: choosing one is the ask, and a menu whose only row opens a submenu would be a
    /// hover standing in front of the answer.
    func testWithNoProjectTheLocationMenuIsTheProjectsThemselves() throws {
        let store = ProjectStore.shared
        let project = store.addProject(folderURL: fixtureFolder())
        defer { store.removeProject(id: project.id) }

        let composer = SessionComposerViewController()
        _ = composer.view
        composer.show(projectID: nil)

        let chip = try XCTUnwrap(chip(named: "composer.session-start.location", in: composer.view))
        let entries = try XCTUnwrap(chip.preparedPresentation()).entries
        let items = entries.compactMap(\.item)

        XCTAssertTrue(items.allSatisfy { $0.submenu == nil }, "nothing to nest under")
        XCTAssertTrue(items.contains { $0.title == project.name })
        XCTAssertEqual(
            items.suffix(2).map(\.title),
            ["Add Existing Folder…", "Create New Folder…"]
        )
        XCTAssertFalse(
            items.contains { $0.title == "New Worktree…" },
            "a checkout section needs a checkout"
        )
    }

    /// Who the session runs as: the logins of the agent it is on, then the other runtimes. The
    /// selected agent has no row — the chip is showing it, and it would be the one row in the
    /// section that changed nothing.
    func testTheIdentityMenuOffersTheLoginsThenTheOtherAgents() throws {
        let composer = SessionComposerViewController()
        _ = composer.view
        composer.show(projectID: nil)

        let chip = try XCTUnwrap(chip(named: "composer.session-start.identity", in: composer.view))
        let selected = AppSettings.shared.defaultAgentKind
        let others = AgentKind.allCases.filter { $0 != selected }.map(\.displayName)
        let entries = try XCTUnwrap(chip.preparedPresentation()).entries
        let titles = entries.compactMap(\.item).map(\.title)

        XCTAssertEqual(Array(titles.suffix(others.count)), others, "the runtimes close the menu")
        XCTAssertFalse(titles.contains(selected.displayName), "the chip is already showing it")

        // Whichever this machine has: two or more logins put the accounts first under one
        // separator, and a single login makes the menu the runtimes alone.
        let accounts = AgentAccountDiscovery.accounts(for: selected)
        let separators = entries.filter { !$0.isItem }.count
        if accounts.count >= 2 {
            XCTAssertEqual(titles.count, accounts.count + others.count)
            XCTAssertEqual(separators, 1, "one line between the logins and the runtimes")
        } else {
            XCTAssertEqual(titles, others)
            XCTAssertEqual(separators, 0, "a menu of one login is noise")
        }

        // The deterministic half of the same rule: OpenCode owns its provider login in its own
        // TUI, so it has no accounts on any machine.
        choose(titled: AgentKind.openCode.displayName, on: chip)
        XCTAssertEqual(chip.accessibilityTitle(), AgentKind.openCode.displayName)
        let single = try XCTUnwrap(chip.preparedPresentation()).entries
        XCTAssertEqual(
            single.compactMap(\.item).map(\.title),
            AgentKind.allCases.filter { $0 != .openCode }.map(\.displayName)
        )
        XCTAssertTrue(single.allSatisfy(\.isItem), "nothing to separate the runtimes from")
    }

    func testEffortFollowsTheSelectedModelsCatalogAndCrossesTheStartBoundary() throws {
        let store = ProjectStore.shared
        let project = store.addProject(folderURL: fixtureFolder())
        defer { store.removeProject(id: project.id) }

        let composer = SessionComposerViewController()
        let recorder = StartRecorder()
        composer.delegate = recorder
        _ = composer.view
        composer.show(projectID: project.id)

        let identity = try XCTUnwrap(
            chip(named: "composer.session-start.identity", in: composer.view)
        )
        if AppSettings.shared.defaultAgentKind != .claude {
            choose(titled: AgentKind.claude.displayName, on: identity)
        }

        let model = try XCTUnwrap(chip(named: "composer.session-start.model", in: composer.view))
        choose(titled: "Opus", on: model)

        let effort = try XCTUnwrap(
            chip(named: "composer.session-start.effort", in: composer.view)
        )
        XCTAssertFalse(effort.isHidden)
        XCTAssertEqual(
            try XCTUnwrap(effort.preparedPresentation()).entries
                .compactMap(\.item)
                .compactMap { $0.representedValue as? String },
            ["low", "medium", "high", "xhigh", "max"]
        )

        choose(titled: "Extra High", on: effort)
        let prompt = try XCTUnwrap(promptView(in: composer.view))
        prompt.stringValue = "Think carefully"
        try sendGlyph(in: prompt).performClick()
        XCTAssertEqual(recorder.reasoningEfforts.last!, "xhigh")

        choose(titled: AgentKind.openCode.displayName, on: identity)
        XCTAssertTrue(effort.isHidden, "a provider without a catalog exposed an invented value")
        prompt.stringValue = "Use provider defaults"
        try sendGlyph(in: prompt).performClick()
        XCTAssertNil(recorder.reasoningEfforts.last!)
    }

    func testWordsTypedBeforeChoosingAProjectFollowIntoIt() throws {
        let composer = SessionComposerViewController()
        _ = composer.view

        composer.show(projectID: nil)
        let prompt = try XCTUnwrap(promptView(in: composer.view))
        prompt.stringValue = "Fix the login flow"

        let store = ProjectStore.shared
        let project = store.addProject(
            folderURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("threading-composer-carry-\(UUID().uuidString)")
        )
        defer {
            store.removeProject(id: project.id)
            DraftStore.shared.setDraft("", for: project.id)
        }

        composer.show(projectID: project.id)
        XCTAssertEqual(prompt.stringValue, "Fix the login flow")

        // And leaving again does not drag the adopted draft back into the empty mode.
        composer.show(projectID: nil)
        XCTAssertEqual(prompt.stringValue, "")
    }

    /// Looking at a session and coming back to the composer is a detour, not a change of
    /// project. Only the text is written to `DraftStore`, so everything else the user had set
    /// up — first of all an attached screenshot — survives that trip only if being pointed at
    /// the project it already holds leaves the composer alone. It did not: the image was gone
    /// from the prompt on the way back, with the sentence describing it still sitting there.
    func testReturningToTheProjectItAlreadyHoldsKeepsTheAttachment() throws {
        let composer = SessionComposerViewController()
        _ = composer.view

        let store = ProjectStore.shared
        let project = store.addProject(folderURL: fixtureFolder())
        let elsewhere = store.addProject(folderURL: fixtureFolder())
        defer {
            store.removeProject(id: project.id)
            store.removeProject(id: elsewhere.id)
        }

        let imageURL = try makeImageFile()
        defer { try? FileManager.default.removeItem(at: imageURL) }

        composer.show(projectID: project.id)
        let prompt = try XCTUnwrap(promptView(in: composer.view))
        prompt.stringValue = "Crop the empty space out of this"
        prompt.attachFiles(at: [imageURL.path])

        // The session in between, then the same project selected again.
        composer.show(projectID: project.id)
        XCTAssertEqual(prompt.stringValue, "Crop the empty space out of this")
        XCTAssertEqual(prompt.attachmentPaths, [imageURL.path], "the attachment was dropped")

        // Another project *is* a change of project, and an image attached for one is not an
        // attachment to a session started in another.
        composer.show(projectID: elsewhere.id)
        XCTAssertEqual(prompt.stringValue, "")
        XCTAssertTrue(prompt.attachmentPaths.isEmpty)
    }

    /// The other half of keeping the composer: what has been sent must not still be sitting in
    /// it. Nothing else empties it any more, and a composer returned to after starting a session
    /// would otherwise offer that session's opening prompt, and its images, as though they were
    /// still waiting to be sent. Only once a session exists — a start that failed is the moment
    /// those words matter most, which is why `DraftStore` is cleared on the same answer.
    func testStartingASessionEmptiesTheComposerButAFailedStartDoesNot() throws {
        let composer = SessionComposerViewController()
        _ = composer.view

        let store = ProjectStore.shared
        let project = store.addProject(folderURL: fixtureFolder())
        defer { store.removeProject(id: project.id) }

        let delegate = StartRecorder()
        composer.delegate = delegate
        composer.show(projectID: project.id)

        let imageURL = try makeImageFile()
        defer { try? FileManager.default.removeItem(at: imageURL) }

        let prompt = try XCTUnwrap(promptView(in: composer.view))
        let send = try sendGlyph(in: prompt)
        prompt.stringValue = "Read this screenshot"
        prompt.attachFiles(at: [imageURL.path])

        delegate.starts = false
        send.performClick()
        XCTAssertEqual(prompt.stringValue, "Read this screenshot", "a failed start took the words")
        XCTAssertEqual(prompt.attachmentPaths, [imageURL.path])

        delegate.starts = true
        send.performClick()
        XCTAssertEqual(
            delegate.prompts.last,
            "Read this screenshot \"\(imageURL.path)\"",
            "the image has to reach the agent as a path"
        )
        // The bug this pairs with: the path inside the sentence was the *only* trace the opening
        // prompt's images left, so the one surface that shows a picture before a session exists
        // was also the one that filed nothing. A path parsed back out of prose is a guess.
        XCTAssertEqual(
            delegate.attachmentPaths.last,
            [imageURL.path],
            "the image reached the agent but was never handed over as an attachment"
        )
        XCTAssertEqual(prompt.stringValue, "")
        XCTAssertTrue(prompt.attachmentPaths.isEmpty)

        // And it stays empty when the project is selected again.
        composer.show(projectID: project.id)
        XCTAssertEqual(prompt.stringValue, "")
        XCTAssertTrue(prompt.attachmentPaths.isEmpty)
    }

    func testHeroHidesWhenThePaneIsTooShortToFloatIt() throws {
        let composer = SessionComposerViewController()
        let host = host(composer, size: Render.tall)
        composer.show(projectID: nil)
        host.layoutSubtreeIfNeeded()

        let mark = try XCTUnwrap(threadingMark(in: composer.view))
        XCTAssertFalse(mark.isHiddenOrHasHiddenAncestor, "A tall pane floats the hero")

        host.setFrameSize(Render.short)
        host.layoutSubtreeIfNeeded()
        composer.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(mark.isHiddenOrHasHiddenAncestor, "A short pane shows the composer alone")
    }

    func testComposerSitsFlushWithThePaneBottom() throws {
        let composer = SessionComposerViewController()
        let host = host(composer, size: Render.tall)
        composer.show(projectID: nil)
        host.layoutSubtreeIfNeeded()

        // With nothing to import, the box is the last thing in the column. The handoff view is
        // asked for it by name, since that is the view the pane animates on the way out.
        let box = composer.promptHandoffView
        let frame = composer.view.convert(box.bounds, from: box)
        // Flipped or not, the column's bottom edge lands one pane inset above the pane's.
        let gap = composer.view.isFlipped
            ? composer.view.bounds.height - frame.maxY
            : frame.minY
        XCTAssertEqual(
            gap,
            Design.Spacing.pane,
            accuracy: 1,
            "The composer hangs from the pane's bottom edge"
        )
    }

    /// The import offer is quiet, sits under the box, and is aligned by its **ink**: a plain
    /// button's frame carries the padding its hover surface needs, so aligned by frame its first
    /// letter would sit four points inside every other row in the column.
    func testTheImportOfferSitsQuietlyUnderTheBoxAndOnTheColumnsEdge() throws {
        let composer = SessionComposerViewController()
        let host = host(composer, size: Render.tall)
        composer.show(projectID: nil)

        // The row is what carries the offer's visibility — a hidden view keeps its constraints,
        // so the button alone cannot take its own gap out of the column, and the stack detaches
        // the hidden row from the hierarchy along with everything inside it.
        let importButton = try revealImport(in: composer.view)
        XCTAssertEqual(importButton.emphasis, .tertiary, "the alternative, not the action")
        host.layoutSubtreeIfNeeded()

        let box = composer.promptHandoffView
        let boxFrame = composer.view.convert(box.bounds, from: box)
        let importFrame = composer.view.convert(importButton.bounds, from: importButton)
        XCTAssertLessThan(
            importFrame.maxY,
            boxFrame.minY,
            "the import offer has to sit under the box, in the unflipped pane's smaller y"
        )
        XCTAssertEqual(
            importFrame.minX + importButton.opticalHorizontalInset,
            boxFrame.minX,
            accuracy: 1,
            "the import title is off the column's leading edge by its own hover padding"
        )
    }

    // MARK: - Renders

    func testRendersTallAndShortUnderSystemAndStyledThemes() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // A named checkout rather than a bare temporary folder: the location chip's whole point
        // is the breadcrumb, and a render of it reading `AB3F-…-9E50` said nothing about
        // whether `Voyager ▸ master` fits the row.
        let repository = try gitFixture(named: "Voyager", branch: "master")
        defer { try? FileManager.default.removeItem(at: repository.deletingLastPathComponent()) }

        let store = ProjectStore.shared
        let project = store.addProject(folderURL: repository)
        defer { store.removeProject(id: project.id) }

        // The broad pair catches ordinary adaptive styling; every hard-retro material is kept
        // here because they share the destination-sized bevel interpreter but deliberately do
        // not share Windows' combo-box anatomy. A compositor regression should therefore leave
        // a visual fixture for the whole affected family, not only for the theme that found it.
        let styled = [
            "Cyberpunk",
            "Swiss Minimalist",
            "Windows 98",
            "Mac OS 9 Platinum",
            "BeOS R5",
            "OPENSTEP 4.2",
            "IRIX Indigo Magic",
            "Amiga Workbench 3.1"
        ].map { name in
            AppThemeLibrary.stock.first { $0.name == name }
        }
        let themes = try [AppTheme.system] + styled.map { try XCTUnwrap($0) }

        var written = 0
        for theme in themes {
            AppThemePalette.set(theme)
            for (suffix, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
                for (label, size, projectID) in [
                    ("tall", Render.tall, project.id as ProjectID?),
                    ("short", Render.short, project.id as ProjectID?),
                    ("empty", Render.tall, nil)
                ] {
                    var data: Data?
                    appearance.performAsCurrentDrawingAppearance {
                        data = image(
                            size: size,
                            appearance: appearance,
                            theme: theme,
                            projectID: projectID
                        )
                    }
                    let url = directory.appendingPathComponent(
                        "composer-\(theme.id.rawValue)-\(suffix)-\(label).png"
                    )
                    try XCTUnwrap(data, "Failed to render \(theme.name) \(suffix) \(label)")
                        .write(to: url)
                    written += 1
                }
            }
        }
        print("Rendered \(written) composers to \(directory.path)")
        XCTAssertEqual(written, themes.count * 2 * 3)
    }

    // MARK: - Fixtures

    private func fixtureFolder() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("threading-composer-\(UUID().uuidString)")
    }

    /// A checkout on disk, which is what the chip asks git about: `GitInfo` reads `.git/HEAD`
    /// rather than running a command, so a directory and one line of text is a whole repository
    /// as far as this screen is concerned. Resolved through the real filesystem, because
    /// `ProjectStore` stores the symlink-resolved path and `/var` is `/private/var` here.
    ///
    /// The checkout sits inside a run-unique parent so it can be *named* — a project is named
    /// after its folder, and the chip is worth nothing if the fixture calls itself a UUID.
    /// Delete `deletingLastPathComponent()` to take the whole fixture with it.
    private func gitFixture(named name: String = "checkout", branch: String) throws -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("threading-composer-repo-\(UUID().uuidString)")
            .appendingPathComponent(name)
            .resolvingSymlinksInPath()
        let git = folder.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try "ref: refs/heads/\(branch)\n".write(
            to: git.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )
        return folder
    }

    /// Picks a row by title without putting a menu on screen, the way a click would.
    private func choose(titled title: String, on chip: ChipView) {
        chip.menuPresentationOverride = { presentation in
            presentation.entries.compactMap(\.item).first { $0.title == title }
        }
        _ = chip.accessibilityPerformShowMenu()
        chip.menuPresentationOverride = nil
    }

    /// A real PNG on disk: the prompt only previews a file it can decode, and only a path can
    /// be sent to an agent. The name carries a space so the quoting is the same every run.
    private func makeImageFile() throws -> URL {
        let image = NSImage(size: NSSize(width: 12, height: 8))
        image.lockFocus()
        NSColor.systemTeal.drawSwatch(in: NSRect(x: 0, y: 0, width: 12, height: 8))
        image.unlockFocus()

        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString) composer fixture.png")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func host(_ composer: SessionComposerViewController, size: NSSize) -> NSView {
        let host = NSView(frame: NSRect(origin: .zero, size: size))
        let view = composer.view
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
        return host
    }

    private func image(
        size: NSSize,
        appearance: NSAppearance,
        theme: AppTheme,
        projectID: ProjectID?
    ) -> Data? {
        let composer = SessionComposerViewController()
        let host = host(composer, size: size)
        host.appearance = appearance
        // The box's surface froze its layer colours in whatever appearance the process had
        // when the composer was built; in the app the attach path repaints recorded surfaces,
        // and offscreen the fixture must do the same or the light pass keeps dark colours —
        // which drew white-at-5% on a white ground, and the box vanished from the light PNGs
        // while every non-layer control beside it rendered correctly.
        AppThemeRefresh.repaint(host)
        composer.show(projectID: projectID)
        host.layoutSubtreeIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.wantsLayer = true
        host.layer?.backgroundColor = theme.resolved(.ground, appearance: appearance).cgColor
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - Tree walking

    /// The send that closes the box's control row. The only `ThemedButton` inside a `PromptView`
    /// — the footer's other occupants are chips and a label.
    private func sendGlyph(in prompt: PromptView) throws -> ThemedButton {
        try XCTUnwrap(
            descendants(of: prompt).compactMap { $0 as? ThemedButton }.first,
            "The box has to hold its own send"
        )
    }

    private func promptView(in view: NSView) -> PromptView? {
        descendants(of: view).first { $0 is PromptView } as? PromptView
    }

    /// Puts the import offer into the state discovery gives it — counted title, row shown —
    /// without waiting on a real scan of a real project.
    ///
    /// The row is reached through `arrangedSubviews`, since the column detaches it while there
    /// is nothing to import, and the button through the row rather than the composer: a detached
    /// row takes its contents out of the hierarchy with it.
    @discardableResult
    private func revealImport(in view: NSView) throws -> ThemedButton {
        let row = try XCTUnwrap(
            controls(in: view).first {
                $0.accessibilityIdentifier() == "composer.session-start.import-row"
            }
        )
        let button = try XCTUnwrap(
            descendants(of: row).first {
                $0.accessibilityIdentifier() == "composer.session-start.import"
            } as? ThemedButton
        )
        row.isHidden = false
        button.isHidden = false
        button.title = ComposerDefaults.importTitle(count: 90)
        return button
    }

    private func chip(named identifier: String, in view: NSView) -> ChipView? {
        controls(in: view).first { $0.accessibilityIdentifier() == identifier } as? ChipView
    }

    private func usageLabel(in view: NSView) -> NSTextField? {
        controls(in: view).first {
            $0.accessibilityIdentifier() == "composer.session-start.usage"
        } as? NSTextField
    }

    /// Every control the composer owns, whether or not it is currently drawn.
    ///
    /// An `NSStackView` with `detachesHiddenViews` takes a hidden arranged view **out of the
    /// view hierarchy**, so a plain subview walk cannot find a control that is merely switched
    /// off — the usage line before a reading has arrived, a chip a runtime does not offer. They
    /// stay in `arrangedSubviews`, which is where a test asserting about arrangement should be
    /// looking anyway.
    private func controls(in view: NSView) -> [NSView] {
        let subtree = [view] + descendants(of: view)
        return subtree + subtree
            .compactMap { $0 as? NSStackView }
            .flatMap(\.arrangedSubviews)
    }

    private func threadingMark(in view: NSView) -> ThreadingMarkView? {
        descendants(of: view).first { $0 is ThreadingMarkView } as? ThreadingMarkView
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}

// MARK: - Start Recorder

/// Stands in for `SessionCoordinator`: records what the composer sent, and answers whether a
/// session was made of it — the answer the composer decides on whether to empty itself.
@MainActor
private final class StartRecorder: SessionComposerViewControllerDelegate {

    var starts = true
    private(set) var prompts: [String] = []
    private(set) var reasoningEfforts: [String?] = []

    /// The images sent with each opening prompt, as they crossed the boundary rather than as
    /// they read inside the sentence: the session does not exist yet, so this is the only form
    /// in which the receiver can file them.
    private(set) var attachmentPaths: [[String]] = []

    func sessionComposer(
        _ composer: SessionComposerViewController,
        startSessionIn projectID: ProjectID,
        kind: AgentKind,
        accountHandle: AccountHandle,
        model: String?,
        reasoningEffort: String?,
        branch: String?,
        usesNativeUI: Bool,
        permissionMode: AgentPermissionMode?,
        prompt: String,
        attachmentPaths: [String]
    ) -> Bool {
        prompts.append(prompt)
        reasoningEfforts.append(reasoningEffort)
        self.attachmentPaths.append(attachmentPaths)
        return starts
    }

    func sessionComposer(
        _ composer: SessionComposerViewController,
        didCreateWorktreeAt url: URL,
        branch: String
    ) {}

    func sessionComposer(
        _ composer: SessionComposerViewController,
        importSession session: ImportableSession,
        into projectID: ProjectID
    ) {}

    func sessionComposer(
        _ composer: SessionComposerViewController,
        didSelectProject projectID: ProjectID
    ) {}

    func sessionComposerDidRequestAddFolder(_ composer: SessionComposerViewController) {}
    func sessionComposerDidRequestNewFolder(_ composer: SessionComposerViewController) {}
}
