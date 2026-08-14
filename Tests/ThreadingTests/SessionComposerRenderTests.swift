import AppKit
import XCTest
@testable import Threading

/// The redesigned composer: bottom-flush, a hero floating in the room above, two chips over the
/// box answering where and who, and a location chip that makes "no project yet" a mode rather
/// than a wall. Geometry and legibility are reviewed on the renders; the behavior the layout
/// promises is asserted.
@MainActor
final class SessionComposerRenderTests: HostedStoreTestCase {

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

    /// Which runtime a new session starts on is a *user's* choice, and `AppSettings` is a
    /// behavioural store — under a hosted test bundle that is the developer's own
    /// `UserDefaults.standard`. A test that picks an agent to assert what its chips offer has to
    /// put the old one back, or the app they run next opens on a runtime they never chose.
    private var savedAgentKind: AgentKind?

    override func setUp() {
        super.setUp()
        savedAgentKind = AppSettings.shared.defaultAgentKind
    }

    override func tearDown() {
        AppThemePalette.set(.system)
        if let savedAgentKind {
            AppSettings.shared.defaultAgentKind = savedAgentKind
        }
        savedAgentKind = nil
        super.tearDown()
    }

    // MARK: - Behavior

    /// "A session cannot start nowhere" is a disabled send with a stated reason, on the button
    /// and in the box alike — the chord reaches the box directly, so disabling only the button
    /// would leave ⌘Return starting a session the button says it cannot start.
    func testNilProjectModeDisablesTheSendAndSaysWhy() throws {
        let composer = SessionComposerViewController()
        _ = composer.view

        composer.show(projectID: nil)
        let prompt = try XCTUnwrap(promptView(in: composer.view))
        let start = try startButton(in: composer.view)
        XCTAssertFalse(prompt.isSubmissionEnabled, "A session cannot start nowhere")
        XCTAssertFalse(start.isEnabled)
        XCTAssertEqual(
            prompt.submissionDisabledReason,
            "Choose a project first",
            "a dead control has to say what would make it live"
        )
        XCTAssertEqual(
            start.toolTip,
            "Choose a project first",
            "a dimmed button with nothing to explain itself is the state this replaced"
        )
        XCTAssertEqual(
            prompt.placeholder,
            "Choose a project first",
            "the refusal must be visible without discovering the disabled button's tooltip"
        )

        let store = ProjectStore.shared
        let project = try XCTUnwrap(store.addProject(
            folderURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("threading-composer-start-\(UUID().uuidString)")
        ))
        defer { store.removeProject(id: project.id) }

        composer.show(projectID: project.id)
        XCTAssertTrue(prompt.isSubmissionEnabled)
        XCTAssertNil(prompt.submissionDisabledReason, "the reason outlived the reason")
        XCTAssertEqual(prompt.placeholder, "Describe a task or ask a question")
        XCTAssertTrue(start.isEnabled)
        XCTAssertNil(start.toolTip, "with nothing left to explain, the button says its own title")
        XCTAssertEqual(
            start.shortcut,
            ComposerDefaults.startShortcut,
            "the chord is on the button's face, which is the only place it is findable"
        )
    }

    /// The composer's own reading of the footer contract: the choices lead, what is left to
    /// spend and the surface trail. The send is not on this row — a brief sends from the button
    /// under the box — and the row is the box's all the same, which is the point: it comes from
    /// `setFooterControls`, not from where the send happens to sit.
    ///
    /// Configured by hand rather than by `show`, because which of these a real machine draws
    /// depends on how many logins the agent has and whether it renders natively — and the
    /// arrangement is the same question either way. A stack detaches a hidden arranged view from
    /// the hierarchy outright, so an environment-dependent chip is not merely invisible here, it
    /// is absent.
    func testTheBoxsFooterCarriesTheChoicesThenTheReading() throws {
        let composer = SessionComposerViewController()
        let host = host(composer, size: Render.tall)

        let prompt = try XCTUnwrap(promptView(in: composer.view))
        let model = try XCTUnwrap(chip(named: "composer.session-start.model", in: composer.view))
        let mode = try XCTUnwrap(chip(named: "composer.session-start.mode", in: composer.view))
        let effort = try XCTUnwrap(chip(named: "composer.session-start.effort", in: composer.view))
        let speed = try XCTUnwrap(chip(named: "composer.session-start.speed", in: composer.view))
        let surface = try XCTUnwrap(chip(named: "composer.session-start.surface", in: composer.view))
        let usage = try XCTUnwrap(usageLabel(in: composer.view))

        model.configure(symbolName: "cpu", title: "Fable 5 · 1M")
        mode.configure(symbolName: "hand.raised", title: "Ask")
        effort.configure(symbolName: "brain", title: "Extra High")
        speed.configure(symbolName: "bolt.fill", title: "Standard")
        speed.isHidden = false
        surface.configure(symbolName: "bubble.left.and.text.bubble.right", title: "Terminal")
        usage.readings = [reading("5h", "43%"), reading("7d", "73%")]
        usage.isHidden = false
        host.layoutSubtreeIfNeeded()

        // Every one of them is drawn inside the box rather than on the pane beside it.
        for control in [model, mode, effort, speed, surface, usage] as [NSView] {
            XCTAssertTrue(
                control.isDescendant(of: prompt),
                "\(Swift.type(of: control)) stayed outside the box it belongs to"
            )
        }

        XCTAssertTrue(
            try sendGlyph(in: prompt).isHidden,
            "the brief's send is the button under the box, not a glyph on this row"
        )
        let inBox = { (view: NSView) in view.convert(view.bounds, to: prompt) }

        XCTAssertLessThan(inBox(model).maxX, inBox(mode).minX, "model leads the row, then mode")
        XCTAssertLessThan(inBox(mode).maxX, inBox(effort).minX, "mode leads effort")
        XCTAssertLessThan(inBox(effort).maxX, inBox(speed).minX, "effort leads speed")
        XCTAssertLessThan(inBox(speed).maxX, inBox(usage).minX)
        XCTAssertLessThan(inBox(usage).maxX, inBox(surface).minX, "the reading precedes the surface")

        // The trailing group reaches the box's own edge rather than trailing the leading one.
        XCTAssertGreaterThan(
            inBox(usage).minX - inBox(speed).maxX,
            inBox(mode).minX - inBox(model).maxX,
            "nothing pushed the reading and the surface to the trailing edge"
        )
        XCTAssertLessThan(
            prompt.bounds.maxX - inBox(surface).maxX,
            Design.Spacing.large,
            "the row has to finish on the box's own edge"
        )
    }

    /// A classic theme gives its popup a separate arrow well. The composer's flexible footer
    /// must spend its empty middle before it shortens the small posture choices at the leading
    /// edge; otherwise "Auto" and "Extra High" become ellipses despite hundreds of free points.
    func testClassicComposerFooterKeepsPostureChoicesReadableWhenTheSpacerHasRoom() throws {
        let store = ProjectStore.shared
        let project = try XCTUnwrap(store.addProject(folderURL: fixtureFolder()))
        defer { store.removeProject(id: project.id) }

        for theme in [AppThemeStyles.openStep, AppThemeStyles.irix] {
            AppThemePalette.set(theme)
            let composer = SessionComposerViewController()
            let host = host(composer, size: Render.short)
            composer.show(projectID: project.id)

            let mode = try XCTUnwrap(
                chip(named: "composer.session-start.mode", in: composer.view)
            )
            let effort = try XCTUnwrap(
                chip(named: "composer.session-start.effort", in: composer.view)
            )
            mode.configure(icon: nil, title: PermissionModePresentation.agentSettingTitle)
            effort.configure(icon: nil, title: "Extra High")
            mode.isHidden = false
            effort.isHidden = false
            host.layoutSubtreeIfNeeded()

            for chip in [mode, effort] {
                let label = try XCTUnwrap(
                    descendants(of: chip).compactMap { $0 as? NSTextField }.first
                )
                let font = try XCTUnwrap(label.font)
                let drawnTitleWidth = label.stringValue.size(withAttributes: [.font: font]).width
                let cell = try XCTUnwrap(label.cell)
                let titleRect = cell.titleRect(forBounds: label.bounds)
                XCTAssertGreaterThanOrEqual(
                    titleRect.width,
                    drawnTitleWidth - 0.5,
                    "\(theme.name) compressed \(label.stringValue) in a roomy footer "
                        + "(chip frame=\(chip.frame.width), intrinsic=\(chip.intrinsicContentSize.width), "
                        + "label=\(label.frame.width), titleRect=\(titleRect.width), "
                        + "drawn=\(drawnTitleWidth), cell=\(cell.cellSize.width))"
                )
                XCTAssertTrue(
                    cell.expansionFrame(withFrame: label.bounds, in: label).isEmpty,
                    "\(theme.name) still rendered \(label.stringValue) as truncated"
                )
                let labelFrame = chip.convert(label.bounds, from: label)
                let arrow = ClassicChoiceDrawing.arrowRect(
                    in: chip.bounds,
                    style: theme.material(for: chip.effectiveAppearance).choiceStyle
                )
                XCTAssertLessThanOrEqual(
                    labelFrame.maxX,
                    arrow.minX - ClassicChoiceDrawing.textInset + 0.5,
                    "\(theme.name) let \(label.stringValue) run under its arrow well "
                        + "(chip frame=\(chip.frame.width), intrinsic=\(chip.intrinsicContentSize.width), "
                        + "label=\(labelFrame), insets=\(label.alignmentRectInsets), arrow=\(arrow))"
                )
            }
        }
    }

    /// The row the composer *configures* is the row the user *sees*.
    ///
    /// The test above hands the chips their titles and then asks where they sit, which is a
    /// question about arrangement and answers nothing about whether the arrangement is on screen:
    /// for one commit (`d58252e`, which moved the send out of the box and back onto a button
    /// under it) the whole row was hidden, and every assertion up there went on passing against
    /// five controls nobody could see. This one goes through `show`, the way the pane reaches
    /// this screen, and asks the one thing that was false.
    ///
    /// Mode and surface only. What the machine can offer of the other three depends on which
    /// logins exist and which models a provider publishes; these two are decided by
    /// `AgentKind.capabilities` and nothing else, so they are the pair a fixture can state.
    func testTheChoicesTheRuntimeOffersAreDrawnAndNotMerelyConfigured() throws {
        let offered = ["composer.session-start.mode", "composer.session-start.surface"]

        AppSettings.shared.defaultAgentKind = .claude
        let composer = SessionComposerViewController()
        let offering = host(composer, size: Render.tall)
        composer.show(projectID: nil)
        offering.layoutSubtreeIfNeeded()

        let prompt = try XCTUnwrap(promptView(in: composer.view))
        for identifier in offered {
            let control = try XCTUnwrap(
                chip(named: identifier, in: composer.view),
                "\(identifier) is not in the composer at all"
            )
            XCTAssertFalse(
                control.isHiddenOrHasHiddenAncestor,
                "\(identifier) names a choice this runtime offers and was never drawn"
            )
            // A stack that detaches hidden views takes the row out of the hierarchy along with
            // everything on it, so the box loses the chip as an ancestor too.
            XCTAssertTrue(
                control.isDescendant(of: prompt),
                "\(identifier) was detached from the box it belongs in"
            )

            let frame = control.convert(control.bounds, to: prompt)
            XCTAssertGreaterThan(frame.width, 0, "\(identifier) was laid out with nothing to draw")
            XCTAssertTrue(
                prompt.bounds.insetBy(dx: -1, dy: -1).contains(frame),
                "\(identifier) was placed outside the box's own bounds"
            )
        }

        // And the same question of a runtime that offers neither, or the assertion above would
        // hold just as well for a row that shows everything unconditionally — which is the other
        // way for this screen to be wrong. A fresh composer, because `show` re-reads the default
        // agent only when it is being pointed somewhere new.
        AppSettings.shared.defaultAgentKind = .openCode
        let plain = SessionComposerViewController()
        let plainHost = host(plain, size: Render.tall)
        plain.show(projectID: nil)
        plainHost.layoutSubtreeIfNeeded()

        for identifier in offered {
            let control = try XCTUnwrap(chip(named: identifier, in: plain.view))
            XCTAssertTrue(
                control.isHiddenOrHasHiddenAncestor,
                "\(identifier) offered a choice this runtime does not have"
            )
        }
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
                "composer.session-start.speed",
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

    /// One list, one decision. The identity menu was the selected runtime's logins, a separator,
    /// then the other runtimes — so reaching another runtime's login cost two passes through the
    /// menu with a wrong-account moment in between. Every login of every runtime is now one row
    /// deep, and choosing one answers both halves at once.
    ///
    /// Asserted on the menu's shape rather than on named rows: logins are discovered from the
    /// developer's own config directories, so which accounts exist is the machine's business.
    /// What must hold on any machine is that every runtime is reachable, no row is a section
    /// heading, and each one carries a mark saying which runtime it belongs to.
    func testTheIdentityMenuIsOneFlatListOfEveryRuntimesLogins() throws {
        let composer = SessionComposerViewController()
        _ = composer.view
        composer.show(projectID: nil)

        let chip = try XCTUnwrap(chip(named: "composer.session-start.identity", in: composer.view))
        let presentation = try XCTUnwrap(chip.preparedPresentation())

        let items = presentation.entries.compactMap(\.item)

        // One press deep, which is the property collapsing the two sections bought: what it
        // removed was a runtime chooser standing between the pointer and a login, and no row
        // here reopens one.
        XCTAssertTrue(
            items.allSatisfy { $0.submenu == nil },
            "a submenu would restore the two trips this menu exists to collapse"
        )
        XCTAssertGreaterThanOrEqual(
            items.count,
            AgentKind.allCases.count,
            "every runtime contributes at least one row — its logins, or itself"
        )
        XCTAssertTrue(
            items.allSatisfy { $0.image != nil },
            "a row in a cross-runtime list with no mark is a login with no provider"
        )
        // The runtime is still named in words as well as drawn — the same person's logins on
        // two runtimes are frequently named the same thing, and a 14pt silhouette is a coin
        // toss. It is said once, by the head over the group, rather than written into every
        // row's own line: that segment was the longest on the line and the reason the reading
        // overran the panel's width cap.
        let heads = presentation.entries.compactMap { entry -> String? in
            if case .header(let title) = entry { return title } else { return nil }
        }
        for kind in AgentKind.allCases {
            let accounts = kind.supportsAccounts ? AgentAccountDiscovery.accounts(for: kind) : []
            if accounts.isEmpty {
                XCTAssertFalse(
                    heads.contains(kind.displayName),
                    "a head over one row repeating its own name is furniture"
                )
            } else {
                XCTAssertTrue(
                    heads.contains(kind.displayName),
                    "\(kind.displayName)'s logins are filed under nothing that names them"
                )
            }
        }
        XCTAssertFalse(
            items.contains { $0.subtitle?.hasPrefix(AgentKind.claude.displayName) == true },
            "the head names the runtime, so a row must not spend its line saying it again"
        )
        XCTAssertEqual(
            items.filter(\.isSelected).count,
            1,
            "exactly one row is who this session runs as"
        )

        // A runtime that offers no login is still reachable, by name.
        for kind in AgentKind.allCases {
            let accounts = kind.supportsAccounts ? AgentAccountDiscovery.accounts(for: kind) : []
            guard accounts.isEmpty else { continue }
            XCTAssertTrue(
                items.contains { $0.title == kind.displayName },
                "\(kind.displayName) has no logins and no row of its own — it is unreachable"
            )
        }
    }

    /// The live chip, against a real checkout on disk: the repository leads, the branch
    /// follows, and the tooltip carries the folder the truncated title cannot.
    func testTheLocationChipReadsTheRepositoryThenTheCheckout() throws {
        let repository = try gitFixture(branch: "master")
        defer { try? FileManager.default.removeItem(at: repository.deletingLastPathComponent()) }

        let store = ProjectStore.shared
        let project = try XCTUnwrap(store.addProject(folderURL: repository))
        let plain = try XCTUnwrap(store.addProject(folderURL: fixtureFolder()))
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

    /// Isolation is one explicit decision. Until it is made, none of the choices beneath it
    /// exist in the draft hierarchy; turning it back off removes them again and sends nil over
    /// the start boundary.
    func testManagedWorkspaceSettingsExistOnlyWhileOptedIn() throws {
        let sessionToolsWereEnabled = AppSettings.shared.isToolGroupEnabled(
            MCPToolCatalog.session.id
        )
        AppSettings.shared.setToolGroup(MCPToolCatalog.session.id, enabled: true)
        AppSettings.shared.defaultAgentKind = .claude
        defer {
            AppSettings.shared.setToolGroup(
                MCPToolCatalog.session.id,
                enabled: sessionToolsWereEnabled
            )
        }

        let repository = try gitFixture(branch: "master")
        defer { try? FileManager.default.removeItem(at: repository.deletingLastPathComponent()) }

        let store = ProjectStore.shared
        let project = try XCTUnwrap(store.addProject(folderURL: repository))
        defer { store.removeProject(id: project.id) }

        let composer = SessionComposerViewController()
        let recorder = StartRecorder()
        composer.delegate = recorder
        let host = host(composer, size: Render.short)
        composer.show(projectID: project.id)

        let checkbox = try XCTUnwrap(
            controls(in: composer.view).first {
                $0.accessibilityIdentifier() == "composer.session-start.managed-workspace"
            } as? ThemedCheckbox
        )
        XCTAssertEqual(checkbox.state, .off)
        XCTAssertNil(
            chip(named: "composer.session-start.managed-workspace.delivery", in: composer.view),
            "dependent settings must not remain in an ordinary draft's hierarchy"
        )

        XCTAssertTrue(checkbox.accessibilityPerformPress())
        let delivery = try XCTUnwrap(
            chip(named: "composer.session-start.managed-workspace.delivery", in: composer.view)
        )
        XCTAssertEqual(delivery.accessibilityTitle(), "Finish: Merge and clean up")
        XCTAssertNil(
            controls(in: composer.view).first {
                $0.accessibilityIdentifier() == "composer.session-start.managed-workspace.publish"
            },
            "a repository without a supported forge should not offer publication settings"
        )

        composer.promptView.stringValue = "Build the isolated feature"
        composer.startTapped()
        XCTAssertEqual(recorder.managedWorkspacePlans.last!, ManagedWorkspacePlan())

        // A failed start keeps the composer around, which is also the useful state for proving
        // that switching the opt-in off removes the subordinate row again.
        recorder.starts = false
        XCTAssertTrue(checkbox.accessibilityPerformPress())
        XCTAssertNil(
            chip(named: "composer.session-start.managed-workspace.delivery", in: composer.view)
        )
        composer.promptView.stringValue = "Use the normal checkout"
        composer.startTapped()
        XCTAssertNil(recorder.managedWorkspacePlans.last!)
    }

    /// Review publication is a second, nested decision. Its mode replaces the incompatible
    /// local-delivery choice only while selected, and neither control exists before isolation.
    func testManagedWorkspacePublicationIsNestedAndOptIn() throws {
        let sessionToolsWereEnabled = AppSettings.shared.isToolGroupEnabled(
            MCPToolCatalog.session.id
        )
        AppSettings.shared.setToolGroup(MCPToolCatalog.session.id, enabled: true)
        AppSettings.shared.defaultAgentKind = .claude
        defer {
            AppSettings.shared.setToolGroup(
                MCPToolCatalog.session.id,
                enabled: sessionToolsWereEnabled
            )
        }

        let repository = try gitFixture(branch: "main")
        defer { try? FileManager.default.removeItem(at: repository.deletingLastPathComponent()) }
        try """
        [remote "origin"]
            url = git@github.com:team/app.git

        """.write(
            to: repository.appendingPathComponent(".git/config"),
            atomically: true,
            encoding: .utf8
        )

        let store = ProjectStore.shared
        let project = try XCTUnwrap(store.addProject(folderURL: repository))
        defer { store.removeProject(id: project.id) }

        let composer = SessionComposerViewController()
        let recorder = StartRecorder()
        composer.delegate = recorder
        _ = composer.view
        composer.show(projectID: project.id)

        let workspace = try XCTUnwrap(
            controls(in: composer.view).first {
                $0.accessibilityIdentifier() == "composer.session-start.managed-workspace"
            } as? ThemedCheckbox
        )
        XCTAssertNil(
            controls(in: composer.view).first {
                $0.accessibilityIdentifier() == "composer.session-start.managed-workspace.publish"
            }
        )
        XCTAssertTrue(workspace.accessibilityPerformPress())

        let publish = try XCTUnwrap(
            controls(in: composer.view).first {
                $0.accessibilityIdentifier() == "composer.session-start.managed-workspace.publish"
            } as? ThemedCheckbox
        )
        XCTAssertNil(
            chip(named: "composer.session-start.managed-workspace.publication", in: composer.view)
        )
        XCTAssertNotNil(
            chip(named: "composer.session-start.managed-workspace.delivery", in: composer.view)
        )

        XCTAssertTrue(publish.accessibilityPerformPress())
        XCTAssertNil(
            chip(named: "composer.session-start.managed-workspace.delivery", in: composer.view),
            "remote publication and local merge are mutually exclusive outcomes"
        )
        let publication = try XCTUnwrap(
            chip(named: "composer.session-start.managed-workspace.publication", in: composer.view)
        )
        XCTAssertEqual(publication.accessibilityTitle(), "Review: Draft pull request")
        choose(titled: "Review: Ready pull request", on: publication)

        composer.promptView.stringValue = "Publish the isolated feature"
        composer.startTapped()
        XCTAssertEqual(
            recorder.managedWorkspacePlans.last!,
            ManagedWorkspacePlan(publication: .ready)
        )

        XCTAssertTrue(publish.accessibilityPerformPress())
        XCTAssertNil(
            chip(named: "composer.session-start.managed-workspace.publication", in: composer.view)
        )
        XCTAssertNotNil(
            chip(named: "composer.session-start.managed-workspace.delivery", in: composer.view)
        )
    }

    func testManagedWorkspaceOptInIsDisabledOutsideGit() throws {
        let store = ProjectStore.shared
        let project = try XCTUnwrap(store.addProject(folderURL: fixtureFolder()))
        defer { store.removeProject(id: project.id) }

        let composer = SessionComposerViewController()
        _ = composer.view
        composer.show(projectID: project.id)

        let checkbox = try XCTUnwrap(
            controls(in: composer.view).first {
                $0.accessibilityIdentifier() == "composer.session-start.managed-workspace"
            } as? ThemedCheckbox
        )
        XCTAssertFalse(checkbox.isEnabled)
        XCTAssertEqual(checkbox.state, .off)
        XCTAssertNil(
            chip(named: "composer.session-start.managed-workspace.delivery", in: composer.view)
        )
    }

    func testManagedWorkspaceOptInIsDisabledWithoutTheFinishHandshake() throws {
        let sessionToolsWereEnabled = AppSettings.shared.isToolGroupEnabled(
            MCPToolCatalog.session.id
        )
        AppSettings.shared.setToolGroup(MCPToolCatalog.session.id, enabled: true)
        AppSettings.shared.defaultAgentKind = .openCode
        defer {
            AppSettings.shared.setToolGroup(
                MCPToolCatalog.session.id,
                enabled: sessionToolsWereEnabled
            )
        }

        let repository = try gitFixture(branch: "master")
        defer { try? FileManager.default.removeItem(at: repository.deletingLastPathComponent()) }

        let store = ProjectStore.shared
        let project = try XCTUnwrap(store.addProject(folderURL: repository))
        defer { store.removeProject(id: project.id) }

        let composer = SessionComposerViewController()
        _ = composer.view
        composer.show(projectID: project.id)

        let checkbox = try XCTUnwrap(
            controls(in: composer.view).first {
                $0.accessibilityIdentifier() == "composer.session-start.managed-workspace"
            } as? ThemedCheckbox
        )
        XCTAssertFalse(checkbox.isEnabled)
        XCTAssertEqual(checkbox.state, .off)
        XCTAssertNil(
            chip(named: "composer.session-start.managed-workspace.delivery", in: composer.view)
        )
    }

    /// One menu, two verbs, kept in two sections. Choosing a checkout routes *this* session and
    /// leaves the composer standing; choosing a project navigates away from it and resets every
    /// choice in it — including the words in the box. Flattened into one list of places, the
    /// first mis-click would take a half-written brief with it.
    func testTheLocationMenuKeepsRunningHereApartFromGoingElsewhere() throws {
        let repository = try gitFixture(branch: "master")
        defer { try? FileManager.default.removeItem(at: repository.deletingLastPathComponent()) }

        let store = ProjectStore.shared
        let project = try XCTUnwrap(store.addProject(folderURL: repository))
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
        let project = try XCTUnwrap(store.addProject(folderURL: fixtureFolder()))
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
    /// One row, both halves. The win this menu was flattened for: from a runtime with no logins
    /// of its own, a single click lands on another runtime *and* the login inside it — where the
    /// two-section menu needed one pass to change runtime and a second to pick the account, and
    /// pointed the composer at the wrong one in between.
    ///
    /// Driven by row position rather than by title, since which logins exist is the machine's
    /// business: the first row is the first runtime's first offer, whether that is a login or the
    /// runtime itself.
    func testChoosingOneRowSetsBothTheRuntimeAndTheLogin() throws {
        let composer = SessionComposerViewController()
        _ = composer.view
        composer.show(projectID: nil)

        let chip = try XCTUnwrap(chip(named: "composer.session-start.identity", in: composer.view))

        // OpenCode owns its provider login in its own TUI, so it has no accounts on any machine
        // — the deterministic runtime row to start from.
        choose(titled: AgentKind.openCode.displayName, on: chip)
        XCTAssertEqual(chip.accessibilityTitle(), AgentKind.openCode.displayName)

        let first = try XCTUnwrap(AgentKind.allCases.first)
        chooseItem(at: 0, on: chip)
        XCTAssertEqual(
            chip.accessibilityTitle()?.hasPrefix(first.displayName),
            true,
            """
            one click from OpenCode to \(first.displayName) — the chip names the runtime the \
            chosen row belongs to, and its login where there is a choice of one
            """
        )
    }

    func testEffortFollowsTheSelectedModelsCatalogAndCrossesTheStartBoundary() throws {
        let store = ProjectStore.shared
        let project = try XCTUnwrap(store.addProject(folderURL: fixtureFolder()))
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
        try startButton(in: composer.view).performClick()
        XCTAssertEqual(recorder.reasoningEfforts.last!, "xhigh")

        choose(titled: AgentKind.openCode.displayName, on: identity)
        XCTAssertTrue(effort.isHidden, "a provider without a catalog exposed an invented value")
        prompt.stringValue = "Use provider defaults"
        try startButton(in: composer.view).performClick()
        XCTAssertNil(recorder.reasoningEfforts.last!)
    }

    func testSpeedOffersInheritanceStandardAndFastAndCrossesTheStartBoundary() throws {
        let oldKind = AppSettings.shared.defaultAgentKind
        let oldSpeed = AppSettings.shared.startupSpeed(for: .claude)
        defer {
            AppSettings.shared.defaultAgentKind = oldKind
            AppSettings.shared.setStartupSpeed(oldSpeed, for: .claude)
        }
        AppSettings.shared.defaultAgentKind = .claude
        AppSettings.shared.setStartupSpeed(.standard, for: .claude)

        let store = ProjectStore.shared
        let project = try XCTUnwrap(store.addProject(folderURL: fixtureFolder()))
        defer { store.removeProject(id: project.id) }

        let composer = SessionComposerViewController()
        let recorder = StartRecorder()
        composer.delegate = recorder
        let speedRenderHost = host(composer, size: Render.short)
        composer.show(projectID: project.id)

        let model = try XCTUnwrap(chip(named: "composer.session-start.model", in: composer.view))
        choose(titled: "Opus", on: model)

        let speed = try XCTUnwrap(chip(named: "composer.session-start.speed", in: composer.view))
        XCTAssertFalse(speed.isHidden)
        XCTAssertEqual(
            try XCTUnwrap(speed.preparedPresentation()).entries
                .compactMap(\.item)
                .compactMap { $0.representedValue as? ConversationSpeedChoice },
            ConversationSpeedChoice.allCases
        )

        // The narrow supported composer still draws the fourth leading chip wholly inside the
        // box. Keep one literal render too: the broad theme matrix follows the account's current
        // default model, which may not support Fast and therefore cannot prove this state exists.
        speedRenderHost.layoutSubtreeIfNeeded()
        let prompt = try XCTUnwrap(promptView(in: composer.view))
        let speedFrame = speed.convert(speed.bounds, to: prompt)
        XCTAssertTrue(prompt.bounds.insetBy(dx: -1, dy: -1).contains(speedFrame))
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rep = try XCTUnwrap(
            speedRenderHost.bitmapImageRepForCachingDisplay(in: speedRenderHost.bounds)
        )
        speedRenderHost.cacheDisplay(in: speedRenderHost.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(
            to: directory.appendingPathComponent("composer-system-light-speed.png")
        )

        choose(titled: "Fast", on: speed)
        prompt.stringValue = "Start quickly"
        try startButton(in: composer.view).performClick()
        XCTAssertEqual(recorder.fastModes, [true])

        choose(titled: "Follow General Setting", on: speed)
        prompt.stringValue = "Follow my default"
        try startButton(in: composer.view).performClick()
        XCTAssertEqual(recorder.fastModes.count, 2)
        XCTAssertNil(recorder.fastModes[1])
    }

    /// The row the screenshot showed: five posture choices and a reading, in a 720-point
    /// column. It does not all fit, and what the reader got was `5h 86…` — a percentage with
    /// its `%` truncated off. Whatever the row can spare, the reading spends on **whole**
    /// windows, so what is left standing is a number that can be read.
    func testTheReadingKeepsWholeWindowsInTheRowThatCouldNotHoldItAll() throws {
        let composer = SessionComposerViewController()
        let host = host(composer, size: Render.tall)

        let model = try XCTUnwrap(chip(named: "composer.session-start.model", in: composer.view))
        let mode = try XCTUnwrap(chip(named: "composer.session-start.mode", in: composer.view))
        let effort = try XCTUnwrap(chip(named: "composer.session-start.effort", in: composer.view))
        let speed = try XCTUnwrap(chip(named: "composer.session-start.speed", in: composer.view))
        let surface = try XCTUnwrap(chip(named: "composer.session-start.surface", in: composer.view))
        let usage = try XCTUnwrap(usageLabel(in: composer.view))

        model.configure(symbolName: "cpu", title: "Opus · 1M")
        mode.configure(symbolName: "hand.raised", title: "Manual")
        effort.configure(symbolName: "brain", title: "Extra High")
        speed.configure(symbolName: "bolt.fill", title: "Standard")
        surface.configure(symbolName: "bubble.left.and.text.bubble.right", title: "Native (Experimental)")
        for chip in [model, mode, effort, speed, surface] { chip.isHidden = false }
        usage.readings = [reading("5h", "86%"), reading("7d", "41%")]
        usage.isHidden = false
        host.layoutSubtreeIfNeeded()

        XCTAssertGreaterThanOrEqual(
            usage.drawableReadingCount(in: usage.bounds.width),
            1,
            "the reading was left with room for no complete window "
                + "(frame=\(usage.bounds.width), whole line=\(usage.intrinsicContentSize.width))"
        )

        // Whatever it drew, the whole of it is still what a tooltip and VoiceOver carry.
        XCTAssertEqual(usage.plainValue, "5h 86% · 7d 41%")
    }

    /// With room to spare, every window is stated: the empty middle of the row is what stretches,
    /// not the gap in the reading.
    ///
    /// The spacer used to hold `defaultLow` — the reading's own compression resistance — so the
    /// two bid for the same slack at the same priority and an ambiguous layout handed it to the
    /// gap. The row then sat with points to spare beside a truncated number.
    func testARoomyFooterSpendsItsSlackOnTheGapRatherThanOnTheReading() throws {
        let composer = SessionComposerViewController()
        let host = host(composer, size: Render.tall)
        let usage = try XCTUnwrap(usageLabel(in: composer.view))

        usage.readings = [reading("5h", "43%"), reading("7d", "73%")]
        usage.isHidden = false
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            usage.bounds.width,
            usage.intrinsicContentSize.width,
            accuracy: 0.5,
            "a footer with slack still squeezed the reading"
        )
        XCTAssertEqual(usage.drawableReadingCount(in: usage.bounds.width), 2)
    }

    /// The identity is the row's stable answer and is not the chip that yields: the location
    /// breadcrumb is (`locationChipCompressionPriority`, plus its own cap). So in a pane with
    /// room to spare, `Claude Code · Everlof` is what the chip draws — not `Claude Code · Everl…`.
    func testTheIdentityChipDrawsItsWholeAnswerInARoomyPane() throws {
        let composer = SessionComposerViewController()
        let host = host(composer, size: Render.tall)
        let identity = try XCTUnwrap(
            chip(named: "composer.session-start.identity", in: composer.view)
        )

        identity.configure(symbolName: "sparkle", title: "Claude Code · Everlof")
        host.layoutSubtreeIfNeeded()

        let label = try XCTUnwrap(
            descendants(of: identity).compactMap { $0 as? NSTextField }.first
        )
        let cell = try XCTUnwrap(label.cell)
        XCTAssertTrue(
            cell.expansionFrame(withFrame: label.bounds, in: label).isEmpty,
            "the identity truncated in a pane with room to spare "
                + "(chip=\(identity.frame.width), intrinsic=\(identity.intrinsicContentSize.width), "
                + "label=\(label.frame.width), cell=\(cell.cellSize.width))"
        )
    }

    // MARK: - Starting It Later

    /// **The offer that cannot be taken still answers.**
    ///
    /// `scheduleEntries` was written to answer a press with the sentence saying why — and the
    /// button was disabled whenever there was one, so the press never arrived and the sentence
    /// lived only on a tooltip. What reached the user was a dim glyph and no reason, reported as
    /// "why is this disabled for me?". The reason has to be one press away, on the surface the
    /// press already opens.
    func testTheScheduleOfferStaysPressableAndSaysWhyItCannotBeUsed() throws {
        let composer = SessionComposerViewController()
        _ = composer.view

        func refusal() throws -> String? {
            let entries = composer.scheduleEntries()
            guard entries.count == 1, case .item(let item) = try XCTUnwrap(entries.first) else {
                return nil
            }
            XCTAssertFalse(item.isEnabled, "the reason was offered as something to choose")
            return item.title
        }

        // No project: the same sentence the send and the placeholder are already using, rather
        // than the empty menu this case used to answer with.
        composer.show(projectID: nil)
        XCTAssertTrue(composer.scheduleButton.isEnabled)
        XCTAssertEqual(composer.scheduleButton.toolTip, ComposerDefaults.chooseProjectFirstReason)
        XCTAssertEqual(try refusal(), ComposerDefaults.chooseProjectFirstReason)

        let store = ProjectStore.shared
        let project = try XCTUnwrap(store.addProject(folderURL: fixtureFolder()))
        defer {
            store.removeProject(id: project.id)
            DraftStore.shared.setDraft("", for: project.id)
        }
        composer.show(projectID: project.id)

        // A project but nothing written.
        let prompt = try XCTUnwrap(promptView(in: composer.view))
        XCTAssertTrue(composer.scheduleButton.isEnabled)
        XCTAssertEqual(try refusal(), "Write the brief first.")

        // Something written and an image beside it: a pasted screenshot is a file in a temporary
        // directory, and a path recorded now can name nothing by Monday.
        let imageURL = try makeImageFile()
        defer { try? FileManager.default.removeItem(at: imageURL) }
        prompt.stringValue = "Crop the empty space out of this"
        prompt.attachFiles(at: [imageURL.path])
        composer.refreshScheduleChip()
        XCTAssertTrue(composer.scheduleButton.isEnabled)
        XCTAssertEqual(
            composer.scheduleButton.toolTip,
            "Images can't be scheduled — they are temporary files."
        )
        XCTAssertEqual(try refusal(), "Images can't be scheduled — they are temporary files.")

        // Nothing in the way: the menu is the offers, and every one of them can be chosen.
        prompt.clear()
        prompt.stringValue = "Crop the empty space out of this"
        composer.refreshScheduleChip()
        let offers = composer.scheduleEntries()
        XCTAssertGreaterThan(offers.count, 1, "a usable schedule offered one row")
        XCTAssertTrue(
            offers.contains { entry in
                if case .item(let item) = entry { return item.isEnabled }
                return false
            },
            "nothing on the menu could be chosen"
        )
        XCTAssertEqual(composer.scheduleButton.toolTip, "Start this session later")
    }

    func testWordsTypedBeforeChoosingAProjectFollowIntoIt() throws {
        let composer = SessionComposerViewController()
        _ = composer.view

        composer.show(projectID: nil)
        let prompt = try XCTUnwrap(promptView(in: composer.view))
        prompt.stringValue = "Fix the login flow"

        let store = ProjectStore.shared
        let project = try XCTUnwrap(store.addProject(
            folderURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("threading-composer-carry-\(UUID().uuidString)")
        ))
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
        let project = try XCTUnwrap(store.addProject(folderURL: fixtureFolder()))
        let elsewhere = try XCTUnwrap(store.addProject(folderURL: fixtureFolder()))
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
        let project = try XCTUnwrap(store.addProject(folderURL: fixtureFolder()))
        defer { store.removeProject(id: project.id) }

        let delegate = StartRecorder()
        composer.delegate = delegate
        composer.show(projectID: project.id)

        let imageURL = try makeImageFile()
        defer { try? FileManager.default.removeItem(at: imageURL) }

        let prompt = try XCTUnwrap(promptView(in: composer.view))
        let send = try startButton(in: composer.view)
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

        // The action row is the last thing in the column, with nothing to import or without:
        // it carries the send, so it stands whatever discovery answers.
        let row = try XCTUnwrap(
            controls(in: composer.view).first {
                $0.accessibilityIdentifier() == "composer.session-start.actions"
            }
        )
        let frame = composer.view.convert(row.bounds, from: row)
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

        // And the box the pane animates on the way out is above it rather than flush itself —
        // asked for by name, since that is the view the handoff moves.
        let box = composer.promptHandoffView
        let boxFrame = composer.view.convert(box.bounds, from: box)
        XCTAssertLessThan(frame.maxY, boxFrame.minY, "the row has to sit under the box")
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

    /// The two buttons in the action row stand at one height.
    ///
    /// A plain button's intrinsic height is what its mark and padding need — four points short of
    /// a bordered one — and at rest that reads as nothing, because it draws no surface. Under the
    /// pointer it raises one, and a hover pill shorter than the primary opposite it makes the row
    /// look like two rows. The row states the height; the ink stays on its own margin, which the
    /// test above asserts.
    func testTheImportOfferStandsAtTheSameHeightAsTheAction() throws {
        let composer = SessionComposerViewController()
        let host = host(composer, size: Render.tall)
        composer.show(projectID: nil)

        let importButton = try revealImport(in: composer.view)
        let start = try startButton(in: composer.view)
        host.layoutSubtreeIfNeeded()

        XCTAssertLessThan(
            importButton.intrinsicContentSize.height,
            start.intrinsicContentSize.height,
            "the tiers ask for different heights — this is the row overruling them, not a no-op"
        )
        XCTAssertEqual(
            importButton.frame.height,
            start.frame.height,
            accuracy: 0.5,
            "the offer's hover surface has to be as tall as the action beside it"
        )
        XCTAssertEqual(
            importButton.frame.midY,
            start.frame.midY,
            accuracy: 0.5,
            "and centred on the same line, so equal heights mean equal edges"
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
        let project = try XCTUnwrap(store.addProject(folderURL: repository))
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
        var expected = 0
        for theme in themes {
            AppThemePalette.set(theme)
            let appearances: [(String, NSAppearance.Name)]
            switch theme.mode {
            case .system:
                appearances = [("light", .aqua), ("dark", .darkAqua)]
            case .light:
                appearances = [("light", .aqua)]
            case .dark:
                appearances = [("dark", .darkAqua)]
            }
            // A fixed theme is one authored appearance. Calling Swiss's paper-white palette
            // “dark” produced a byte-for-byte duplicate in the catalogue and implied a state the
            // product cannot enter; adaptive themes alone owe the reviewer both appearances.
            expected += appearances.count * 3
            for (suffix, appearanceName) in appearances {
                let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
                for (label, size, projectID, promptText) in [
                    (
                        "tall",
                        Render.tall,
                        project.id as ProjectID?,
                        "Review the session restoration path and preserve every changed-file card.\n"
                            + "Add a regression test for relaunching after an interrupted turn."
                    ),
                    ("short", Render.short, project.id as ProjectID?, "Audit session restoration."),
                    ("empty", Render.tall, nil, nil)
                ] {
                    var data: Data?
                    appearance.performAsCurrentDrawingAppearance {
                        data = image(
                            size: size,
                            appearance: appearance,
                            theme: theme,
                            projectID: projectID,
                            promptText: promptText
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
        XCTAssertEqual(written, expected)
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

    /// Picks a row by position, for a menu whose titles depend on the machine's own logins.
    private func chooseItem(at index: Int, on chip: ChipView) {
        chip.menuPresentationOverride = { presentation in
            let items = presentation.entries.compactMap(\.item)
            return items.indices.contains(index) ? items[index] : nil
        }
        _ = chip.accessibilityPerformShowMenu()
        chip.menuPresentationOverride = nil
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
        projectID: ProjectID?,
        promptText: String?
    ) -> Data? {
        let composer = SessionComposerViewController()
        let renderHost = host(composer, size: size)
        renderHost.appearance = appearance
        // The box's surface froze its layer colours in whatever appearance the process had
        // when the composer was built; in the app the attach path repaints recorded surfaces,
        // and offscreen the fixture must do the same or the light pass keeps dark colours —
        // which drew white-at-5% on a white ground, and the box vanished from the light PNGs
        // while every non-layer control beside it rendered correctly.
        AppThemeRefresh.repaint(renderHost)
        composer.show(projectID: projectID)
        if let promptText, let prompt = promptView(in: composer.view) {
            prompt.stringValue = promptText
        }
        renderHost.layoutSubtreeIfNeeded()

        // Assert in the exact lifecycle that writes the catalogue image. A standalone chip and
        // even a normally hosted composer can both measure correctly while a scoped appearance
        // repaint leaves the saved PNG with a stale natural width. The rendered image is the
        // acceptance artifact, so it owns this last line of defence.
        if theme.id == AppThemeStyles.openStep.id || theme.id == AppThemeStyles.irix.id {
            for identifier in [
                "composer.session-start.mode",
                "composer.session-start.effort"
            ] {
                guard let chip = chip(named: identifier, in: composer.view), !chip.isHidden,
                      let label = descendants(of: chip).compactMap({ $0 as? NSTextField }).first,
                      let font = label.font else { continue }
                let drawnTitleWidth = label.stringValue.size(withAttributes: [.font: font]).width
                let titleRect = label.cell?.titleRect(forBounds: label.bounds) ?? .zero
                XCTAssertGreaterThanOrEqual(
                    titleRect.width,
                    drawnTitleWidth - 0.5,
                    "\(theme.name) catalogue render compressed \(label.stringValue) "
                        + "(chip frame=\(chip.frame.width), intrinsic=\(chip.intrinsicContentSize.width), "
                        + "label=\(label.frame.width), titleRect=\(titleRect.width), "
                        + "drawn=\(drawnTitleWidth), cell=\(label.cell?.cellSize.width ?? 0))"
                )
                XCTAssertTrue(
                    label.cell?.expansionFrame(withFrame: label.bounds, in: label).isEmpty ?? false,
                    "\(theme.name) catalogue render still truncated \(label.stringValue) "
                        + "(chip=\(chip.frame.width), intrinsic=\(chip.intrinsicContentSize.width), "
                        + "compression=\(chip.contentCompressionResistancePriority(for: .horizontal).rawValue), "
                        + "label=\(label.frame.width), titleRect=\(titleRect.width), "
                        + "cell=\(label.cell?.cellSize.width ?? 0), fitting=\(label.fittingSize.width))"
                )
                let labelFrame = chip.convert(label.bounds, from: label)
                let arrow = ClassicChoiceDrawing.arrowRect(
                    in: chip.bounds,
                    style: theme.material(for: chip.effectiveAppearance).choiceStyle
                )
                XCTAssertLessThanOrEqual(
                    labelFrame.maxX,
                    arrow.minX - ClassicChoiceDrawing.textInset + 0.5,
                    "\(theme.name) catalogue render let \(label.stringValue) run under its "
                        + "arrow well (chip frame=\(chip.frame.width), "
                        + "intrinsic=\(chip.intrinsicContentSize.width), label=\(labelFrame), "
                        + "insets=\(label.alignmentRectInsets), arrow=\(arrow))"
                )
            }
        }

        guard let rep = renderHost.bitmapImageRepForCachingDisplay(in: renderHost.bounds) else {
            return nil
        }
        renderHost.wantsLayer = true
        renderHost.layer?.backgroundColor = theme.resolved(.ground, appearance: appearance).cgColor
        renderHost.cacheDisplay(in: renderHost.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - Tree walking

    /// The composer's send: the primary under the box, which is what a brief is sent from.
    private func startButton(in view: NSView) throws -> ThemedButton {
        try XCTUnwrap(
            controls(in: view).first {
                $0.accessibilityIdentifier() == "composer.session-start.submit"
            } as? ThemedButton,
            "The composer has to hold its start button"
        )
    }

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

    /// Puts the import offer into the state discovery gives it — counted title, button shown —
    /// without waiting on a real scan of a real project.
    ///
    /// The row is reached through `arrangedSubviews` and the button through the row rather than
    /// through the composer, since a stack that detaches a hidden view takes its contents out of
    /// the hierarchy with it.
    @discardableResult
    private func revealImport(in view: NSView) throws -> ThemedButton {
        let row = try XCTUnwrap(
            controls(in: view).first {
                $0.accessibilityIdentifier() == "composer.session-start.actions"
            }
        )
        let button = try XCTUnwrap(
            descendants(of: row).first {
                $0.accessibilityIdentifier() == "composer.session-start.import"
            } as? ThemedButton
        )
        button.isHidden = false
        button.title = ComposerDefaults.importTitle(count: 90)
        return button
    }

    private func chip(named identifier: String, in view: NSView) -> ChipView? {
        controls(in: view).first { $0.accessibilityIdentifier() == identifier } as? ChipView
    }

    private func usageLabel(in view: NSView) -> UsageReadingLabel? {
        controls(in: view).first {
            $0.accessibilityIdentifier() == "composer.session-start.usage"
        } as? UsageReadingLabel
    }

    /// A window as the line receives it: named, valued, and comfortable.
    private func reading(_ name: String, _ value: String) -> AccountUsage.Reading {
        AccountUsage.Reading(name: name, value: value, severity: .normal, fraction: 0.4)
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
    private(set) var fastModes: [Bool?] = []
    private(set) var managedWorkspacePlans: [ManagedWorkspacePlan?] = []

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
        fastMode: Bool?,
        branch: String?,
        usesNativeUI: Bool,
        permissionMode: AgentPermissionMode?,
        managedWorkspacePlan: ManagedWorkspacePlan?,
        prompt: String,
        attachmentPaths: [String]
    ) -> Bool {
        prompts.append(prompt)
        reasoningEfforts.append(reasoningEffort)
        fastModes.append(fastMode)
        managedWorkspacePlans.append(managedWorkspacePlan)
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
        importSessions sessions: [ImportableSession],
        into projectID: ProjectID
    ) {}

    func sessionComposer(
        _ composer: SessionComposerViewController,
        didSelectProject projectID: ProjectID
    ) {}

    func sessionComposerDidRequestAddFolder(_ composer: SessionComposerViewController) {}
    func sessionComposerDidRequestNewFolder(_ composer: SessionComposerViewController) {}
}
