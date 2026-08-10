import XCTest
@testable import Threading

/// What a launch says about how much the session may do before it asks.
///
/// The mode is not a Threading concept: each CLI has its own, and the whole value of the feature
/// is that the flags come out *right* for the agent being launched. So these assert against the
/// tokenized launch line — the words the CLI actually receives — rather than against the
/// resolver, which could agree with itself while emitting a flag neither CLI takes.
@MainActor
final class AgentPermissionModeTests: XCTestCase {

    private var defaultMode: AgentPermissionMode?

    override func setUp() {
        super.setUp()
        // The app-wide default is one of the inputs under test, and it is real user state.
        defaultMode = AppSettings.shared.defaultPermissionMode
        AppSettings.shared.defaultPermissionMode = nil
    }

    override func tearDown() {
        AppSettings.shared.defaultPermissionMode = defaultMode
        super.tearDown()
    }

    // MARK: - Claude

    /// Every mode reaches Claude as its own `--permission-mode` value.
    ///
    /// The expected strings are written out rather than derived from the enum: `claudeFlagValue`
    /// returning the wrong thing is exactly the bug this exists to catch, and a test that asks
    /// the same property is a second copy of it. These six are the values `claude --help`
    /// documents — note `manual`, which the CLI calls `default` internally.
    func testEachModeReachesClaudeAsItsOwnFlagValue() throws {
        let expected: [AgentPermissionMode: String] = [
            .manual: "manual",
            .plan: "plan",
            .acceptEdits: "acceptEdits",
            .auto: "auto",
            .dontAsk: "dontAsk",
            .bypassPermissions: "bypassPermissions"
        ]

        for (mode, value) in expected {
            let words = try Self.launchWords(kind: .claude, mode: mode)
            let flag = try XCTUnwrap(
                words.firstIndex(of: "--permission-mode"),
                "\(mode) launched without stating a mode"
            )
            XCTAssertEqual(words[flag + 1], value)
        }
    }

    /// The native surface states the mode too. A headless session cannot be Shift+Tabbed into
    /// one, so the launch is the only chance it gets.
    func testTheNativeClaudeTransportStatesTheModeAsWell() throws {
        let session = Self.session(kind: .claude, mode: .plan)
        let words = try Self.tokenizing(
            XCTUnwrap(try AgentLauncher.streamPlan(
                for: session,
                in: Self.project
            ).arguments.last)
        )

        XCTAssertEqual(Self.value(after: "--permission-mode", in: words), "plan")
    }

    /// **Every** native transport states the mode, not just the two that had a test each.
    ///
    /// Grok's did not. The capability was granted, all three UI surfaces offered the control,
    /// and `launchFlags(for: .grok)` returned a real `--permission-mode` — but `grokStreamPlan`
    /// never called `appendPermissionMode`, so choosing Plan on a natively rendered Grok
    /// session recorded the choice, redrew the chip, and left the process on whatever `grok`
    /// defaults to. The ACP handshake carries no mode either, so nothing downstream recovered
    /// it.
    ///
    /// Written over `allCases` rather than per-runtime because that is exactly why it was
    /// missed: the two runtimes with native tests passed, and the third had no test to fail.
    func testEveryNativeTransportStatesTheModeItWasGiven() throws {
        for kind in AgentKind.allCases where kind.supports(.nativeUI)
            && kind.supports(.permissionModes) {
            let session = Self.session(kind: kind, mode: .plan, usesNativeUI: true)
            let words = try Self.tokenizing(
                XCTUnwrap(try AgentLauncher.streamPlan(
                    for: session,
                    in: Self.project
                ).arguments.last)
            )

            // Codex spends the mode on two axes and names neither `--permission-mode`; the
            // shared claim is that *something* on the line carries it.
            let stated = AgentPermissionMode.plan.launchFlags(for: kind)
            XCTAssertFalse(stated.isEmpty, "\(kind) claims the vocabulary but produces no flags")

            for flag in stated {
                XCTAssertEqual(
                    Self.value(after: flag.name, in: words),
                    flag.value,
                    "\(kind)'s native launch dropped \(flag.name)"
                )
            }
        }
    }

    // MARK: - Codex

    /// Codex has no mode flag, so each mode becomes an approval policy *and* a sandbox — and the
    /// six land on six distinct pairs. That distinctness is the claim worth testing: a mapping
    /// where two modes collapse would give the menu two items that do the same thing.
    func testEachModeReachesCodexAsADistinctApprovalAndSandboxPair() throws {
        var seen: Set<String> = []

        for mode in AgentPermissionMode.allCases {
            let words = try Self.launchWords(kind: .codex, mode: mode)

            let approval = try XCTUnwrap(Self.value(after: "--ask-for-approval", in: words))
            let sandbox = try XCTUnwrap(Self.value(after: "--sandbox", in: words))

            XCTAssertTrue(
                ["untrusted", "on-request", "never"].contains(approval),
                "\(mode) asked Codex for an approval policy it does not have: \(approval)"
            )
            XCTAssertTrue(
                ["read-only", "workspace-write", "danger-full-access"].contains(sandbox),
                "\(mode) asked Codex for a sandbox it does not have: \(sandbox)"
            )
            XCTAssertTrue(
                seen.insert("\(approval)/\(sandbox)").inserted,
                "\(mode) produces the same Codex launch as another mode: \(approval)/\(sandbox)"
            )
        }
    }

    /// Manual and Accept edits share an approval policy and differ only in the sandbox, which is
    /// the half of the mapping that carries the meaning: read-only has to ask before changing
    /// anything, workspace-write may edit in place.
    func testManualAndAcceptEditsDifferOnlyInWhatCodexMayWrite() throws {
        let manual = try Self.launchWords(kind: .codex, mode: .manual)
        let accept = try Self.launchWords(kind: .codex, mode: .acceptEdits)

        XCTAssertEqual(
            Self.value(after: "--ask-for-approval", in: manual),
            Self.value(after: "--ask-for-approval", in: accept)
        )
        XCTAssertEqual(Self.value(after: "--sandbox", in: manual), "read-only")
        XCTAssertEqual(Self.value(after: "--sandbox", in: accept), "workspace-write")
    }

    /// The native Codex transport fixes `--sandbox workspace-write` when no mode is stated,
    /// because a natively rendered session that inherited a read-only `config.toml` would stop
    /// being able to edit and would say so only through failing tools. A stated mode *replaces*
    /// that value — it must not arrive as a second `--sandbox`, where the last one silently wins.
    func testTheNativeCodexTransportCarriesExactlyOneSandbox() throws {
        for mode in [nil] + AgentPermissionMode.allCases.map(Optional.init) {
            let session = Self.session(kind: .codex, mode: mode)
            let words = try Self.tokenizing(
                XCTUnwrap(try AgentLauncher.streamPlan(
                    for: session,
                    in: Self.project
                ).arguments.last)
            )

            XCTAssertEqual(
                words.filter { $0 == "--sandbox" }.count,
                1,
                "\(String(describing: mode)) left the native launch with two sandboxes"
            )
            XCTAssertEqual(
                Self.value(after: "--sandbox", in: words),
                mode?.codexSandboxMode ?? "workspace-write"
            )
        }
    }

    // MARK: - Grok

    /// Grok names the same six modes. Only Manual differs on the wire: Grok calls the ordinary
    /// ask-first posture `default`, while Claude's external spelling is `manual`.
    func testEachModeReachesGrokAsItsOwnFlagValue() throws {
        let expected: [AgentPermissionMode: String] = [
            .manual: "default",
            .plan: "plan",
            .acceptEdits: "acceptEdits",
            .auto: "auto",
            .dontAsk: "dontAsk",
            .bypassPermissions: "bypassPermissions"
        ]

        for (mode, value) in expected {
            let words = try Self.launchWords(kind: .grok, mode: mode)
            XCTAssertEqual(Self.value(after: "--permission-mode", in: words), value)
        }
    }

    // MARK: - Resolution

    /// No choice anywhere means **no flag** — not a mode Threading picked. Naming one would
    /// override a `permissions.defaultMode` or `config.toml` the user set themselves, which is
    /// the whole reason the value is optional rather than defaulted.
    func testNoChoiceAnywhereStatesNothing() throws {
        for kind in AgentKind.allCases {
            let words = try Self.launchWords(kind: kind, mode: nil)

            XCTAssertFalse(words.contains("--permission-mode"), "\(kind) invented a permission mode")
            XCTAssertFalse(words.contains("--ask-for-approval"), "\(kind) invented an approval policy")
            XCTAssertFalse(words.contains("--sandbox"), "\(kind) invented a sandbox")
        }
    }

    /// The app-wide default applies to a session that has not chosen.
    func testTheAppDefaultAppliesToASessionThatHasNotChosen() throws {
        AppSettings.shared.defaultPermissionMode = .acceptEdits

        let words = try Self.launchWords(kind: .claude, mode: nil)

        XCTAssertEqual(Self.value(after: "--permission-mode", in: words), "acceptEdits")
    }

    /// And the session's own choice beats it, including when the two disagree about safety —
    /// a conversation deliberately left in Plan is not dragged along by a permissive default.
    func testASessionsOwnChoiceBeatsTheAppDefault() throws {
        AppSettings.shared.defaultPermissionMode = .bypassPermissions

        let words = try Self.launchWords(kind: .claude, mode: .plan)

        XCTAssertEqual(Self.value(after: "--permission-mode", in: words), "plan")
    }

    // MARK: - One vocabulary, three surfaces

    /// The chip names the mode that will actually apply, not merely the one chosen on it: the
    /// session's own answer first, the app-wide default where it has none, and where the
    /// decision goes when there is no default either.
    func testTheChipNamesTheModeThatWillActuallyApply() {
        XCTAssertEqual(
            PermissionModePresentation.chipTitle(selected: .plan, inherited: .dontAsk),
            AgentPermissionMode.plan.displayName
        )
        XCTAssertEqual(
            PermissionModePresentation.chipTitle(selected: nil, inherited: .dontAsk),
            AgentPermissionMode.dontAsk.displayName
        )
        XCTAssertEqual(
            PermissionModePresentation.chipTitle(selected: nil, inherited: nil),
            PermissionModePresentation.agentSettingTitle
        )
    }

    /// One posture, three entrances: the session row's menu, the opening composer's chip and
    /// the reply composer's chip. They must offer the same choices, because three menus for one
    /// setting can otherwise disagree about what the app-wide default is even called — which is
    /// what `PermissionModePresentation` exists to close.
    ///
    /// The closing note is deliberately excluded from the comparison: *when* a choice applies is
    /// the one thing these three genuinely differ about.
    func testTheThreeSurfacesOfferTheSamePermissionModeRows() throws {
        AppSettings.shared.defaultPermissionMode = .dontAsk
        let chipTitle = PermissionModePresentation.chipTitle(
            selected: nil,
            inherited: PermissionModePresentation.appDefault
        )

        let sidebar = ProjectSidebarViewController()
        let sidebarRows = try XCTUnwrap(
            sidebar.sessionActionEntries(
                for: AgentSession(kind: .claude, title: "Row", usesNativeUI: false)
            )
            .compactMap(\.item)
            .first { $0.title == L10n.string("Permission Mode") }?
            .submenu,
            "the session menu offers no Permission Mode item"
        )

        let composer = SessionComposerViewController()
        _ = composer.view
        composer.refreshDerivedState()
        let composerRows = try XCTUnwrap(
            Self.offeredRows(ofChipTitled: chipTitle, in: composer.view),
            "the opening composer offers no permission-mode chip"
        )

        let conversation = Self.conversationController(kind: .claude)
        let replyRows = try XCTUnwrap(
            Self.offeredRows(ofChipTitled: chipTitle, in: conversation.view),
            "the reply composer offers no permission-mode chip"
        )

        let expected = PermissionModePresentation.rows(
            for: .claude,
            selected: nil,
            inherited: .dontAsk,
            timing: .whenTheSessionStarts
        )
        XCTAssertEqual(Self.choices(in: sidebarRows), Self.choices(in: expected))
        XCTAssertEqual(Self.choices(in: composerRows), Self.choices(in: expected))
        XCTAssertEqual(Self.choices(in: replyRows), Self.choices(in: expected))

        // The default is named on the mode it *is*, rather than a second time above the list.
        XCTAssertEqual(
            expected.first?.item?.title,
            AgentPermissionMode.manual.displayName,
            "the list leads with the first mode; the default no longer has a row of its own"
        )
    }

    /// The app-wide default is marked where it already stands, and appears once.
    ///
    /// The menu used to open with "Use Default (Auto)" above a list that then named Auto again:
    /// seven rows for six postures, whose duplicated pair were the two hardest to tell apart and
    /// meant subtly different things — one followed Settings, the other pinned today's value of
    /// it. The marked row is the inherit row, so it answers nil and nothing is pinned by
    /// choosing the mode the app already defaults to.
    func testTheAppDefaultIsMarkedOnItsModeRatherThanRepeatedAboveTheList() throws {
        var chosen: AgentPermissionMode??
        let rows = PermissionModePresentation.rows(
            for: .claude,
            selected: nil,
            inherited: .auto,
            timing: .whenTheSessionStarts,
            onChoose: { chosen = $0 }
        )
        let items = rows.compactMap(\.item)

        XCTAssertEqual(
            items.count,
            AgentPermissionMode.allCases.count,
            "one row per mode, and no row above them repeating one of them"
        )
        XCTAssertEqual(
            items.map(\.title).filter { $0.hasPrefix(AgentPermissionMode.auto.displayName) },
            ["\(AgentPermissionMode.auto.displayName)\(PermissionModePresentation.defaultSuffix)"],
            "the default is marked in place, once"
        )

        let marked = try XCTUnwrap(items.first { $0.isSelected })
        XCTAssertTrue(
            marked.title.hasPrefix(AgentPermissionMode.auto.displayName),
            "a session that has chosen nothing runs the default, so that is the checked row"
        )
        XCTAssertNil(
            marked.representedValue,
            "the marked row is the inherit row: choosing it follows Settings rather than pinning"
        )
        marked.onChoose?()
        XCTAssertEqual(chosen, .some(nil))

        // A session that recorded the mode the default happens to name reads the same, because
        // it runs the same thing — one checked row, not two rows the user must tell apart.
        let pinned = PermissionModePresentation.rows(
            for: .claude,
            selected: .auto,
            inherited: .auto,
            timing: .whenTheSessionStarts
        ).compactMap(\.item).filter(\.isSelected)
        XCTAssertEqual(pinned.count, 1)
        XCTAssertEqual(
            pinned.first?.title,
            "\(AgentPermissionMode.auto.displayName)\(PermissionModePresentation.defaultSuffix)"
        )
    }

    /// With no app-wide default the deferring row comes back, and duplicates nothing: the
    /// agent's own setting is not one of the six, and Threading cannot read it to name it.
    func testWithNoAppDefaultTheMenuStillOffersTheAgentsOwnSetting() throws {
        let items = PermissionModePresentation.rows(
            for: .claude,
            selected: nil,
            inherited: nil,
            timing: .whenTheSessionStarts
        ).compactMap(\.item)

        XCTAssertEqual(items.count, AgentPermissionMode.allCases.count + 1)
        let first = try XCTUnwrap(items.first)
        XCTAssertEqual(first.title, PermissionModePresentation.agentSettingRowTitle)
        XCTAssertTrue(first.isSelected)
        XCTAssertFalse(
            items.dropFirst().contains { $0.title.contains(PermissionModePresentation.defaultSuffix) },
            "nothing is marked as the default when nothing here has set one"
        )
    }

    /// A menu that only writes a record says so. The session row's item has always been
    /// record-only, and the reply composer's chip becomes so on a dormant conversation and on
    /// every transport that cannot be asked mid-conversation.
    func testTheRecordOnlyMenuSaysWhenItApplies() throws {
        XCTAssertNil(PermissionModePresentation.note(for: .whenTheSessionStarts))
        XCTAssertNil(PermissionModePresentation.note(for: .immediately))

        let note = try XCTUnwrap(PermissionModePresentation.note(for: .whenTheChatRestarts))
        let rows = PermissionModePresentation.rows(
            for: .claude,
            selected: nil,
            inherited: nil,
            timing: .whenTheChatRestarts
        )
        let last = try XCTUnwrap(rows.last?.item)
        XCTAssertEqual(last.title, note)
        XCTAssertFalse(last.isEnabled, "the note must not read as a seventh mode to choose")
        XCTAssertNil(last.onChoose)
    }

    /// The chip is withheld where the runtime has no posture Threading can state. OpenCode owns
    /// a richer per-tool policy in `opencode.json` that none of these six describes, so every
    /// surface hides the control rather than offering a mapping it would not honour.
    func testTheSurfacesWithholdTheChoiceWhereTheRuntimeHasNoMode() throws {
        XCTAssertFalse(AgentKind.openCode.supportsPermissionModes)

        let sidebar = ProjectSidebarViewController()
        let titles = sidebar.sessionActionEntries(
            for: AgentSession(kind: .openCode, title: "Row", usesNativeUI: false)
        ).compactMap { $0.item?.title }
        XCTAssertFalse(titles.contains(L10n.string("Permission Mode")))

        let composer = SessionComposerViewController()
        _ = composer.view
        composer.refreshDerivedState()
        // By identifier rather than by title: the identity chip names the login beside the agent
        // wherever the machine running this has more than one, so its title is not something a
        // test can spell.
        let identityChip = try XCTUnwrap(
            Self.chip(identified: "composer.session-start.identity", in: composer.view),
            "the composer offers no identity chip"
        )
        Self.choose(
            titled: AgentKind.openCode.displayName,
            on: identityChip
        )
        XCTAssertNil(
            Self.chip(
                titled: PermissionModePresentation.chipTitle(selected: nil, inherited: nil),
                in: composer.view
            ),
            "a runtime with no permission mode was still offered one"
        )
    }

    /// The mode chip's visibility is not the model catalog's business. Grok publishes no host
    /// model catalog at all — which used to hide every control on the row, this one included,
    /// through the early return the model chip needs.
    func testTheReplyChipSurvivesAnEmptyModelCatalog() throws {
        XCTAssertTrue(AgentKind.grok.supportsPermissionModes)
        XCTAssertTrue(
            AgentModels.options(for: .grok, account: nil).isEmpty,
            "Grok grew a model catalog; this test no longer covers the empty case"
        )

        let conversation = Self.conversationController(kind: .grok, mode: .plan)
        XCTAssertNotNil(
            Self.chip(titled: AgentPermissionMode.plan.displayName, in: conversation.view),
            "the mode chip went with the model catalog"
        )
    }

    // MARK: - Persistence

    /// The mode survives a round-trip, and a record written before this existed decodes to nil
    /// rather than to a mode nobody chose.
    func testTheModeSurvivesARoundTripAndOlderRecordsDecodeToNil() throws {
        var session = AgentSession(kind: .claude, title: "t")
        session.permissionMode = .dontAsk

        let encoded = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(AgentSession.self, from: encoded)
        XCTAssertEqual(decoded.permissionMode, .dontAsk)

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "permissionMode")
        let older = try JSONDecoder().decode(
            AgentSession.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNil(older.permissionMode)
    }

    /// Nil is a value the store can go back to, not merely the state before a first choice —
    /// otherwise "Use Agent's Setting" would be a one-way door once any mode had been picked.
    func testClearingASessionsModeReturnsItToInheriting() throws {
        let store = ProjectStore.shared
        // A path of its own: `addProject` returns the existing project for a folder it already
        // knows, so a shared temp directory would hand this test a sibling's project and then
        // delete it on the way out.
        let project = try XCTUnwrap(store.addProject(
            folderURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("threading-permission-mode-\(UUID().uuidString)")
        ))
        let session = try XCTUnwrap(store.addSession(to: project.id, kind: .claude))
        defer { store.removeProject(id: project.id) }

        store.setPermissionMode(.auto, for: session.id)
        XCTAssertEqual(store.session(withID: session.id)?.permissionMode, .auto)

        store.setPermissionMode(nil, for: session.id)
        XCTAssertNil(store.session(withID: session.id)?.permissionMode)
    }

    // MARK: - The broker

    /// Threading's own permission sheet honours the mode, because the CLI does not honour it for
    /// us: measured against 2.1.220, `PreToolUse` fires under `bypassPermissions` and `dontAsk`
    /// exactly as it does under `manual`. A native session in Bypass that still got stopped by
    /// Threading's sheet would be the app contradicting the mode chosen inside it.
    func testBypassAllowsAndDontAskDeniesWithoutAsking() {
        for tool in [ToolIdentity.bash, .write, .edit] {
            switch PermissionPolicy.standingDecision(for: tool, in: .bypassPermissions) {
            case .allow: break
            default: XCTFail("Bypass Permissions still asked about \(tool)")
            }

            switch PermissionPolicy.standingDecision(for: tool, in: .dontAsk) {
            case .deny: break
            default: XCTFail("Don't Ask did not refuse \(tool)")
            }
        }
    }

    /// Accept Edits is about *edits*. A command is not an edit, and that distinction is the
    /// whole difference between this mode and the ones either side of it.
    func testAcceptEditsAllowsFileChangesAndStillAsksAboutCommands() {
        for tool in [ToolIdentity.write, .edit, .multiEdit, .notebookEdit] {
            switch PermissionPolicy.standingDecision(for: tool, in: .acceptEdits) {
            case .allow: break
            default: XCTFail("Accept Edits asked about \(tool)")
            }
        }

        XCTAssertNil(
            PermissionPolicy.standingDecision(for: .bash, in: .acceptEdits),
            "Accept Edits waved a command through as though it were an edit"
        )
    }

    /// The modes that promise nothing about the sheet still raise it. Being wrong here should
    /// cost an extra question, never an unasked-for action.
    func testTheRemainingModesStillAsk() {
        for mode in [AgentPermissionMode.manual, .plan, .auto] {
            XCTAssertNil(
                PermissionPolicy.standingDecision(for: .bash, in: mode),
                "\(mode) stopped asking"
            )
        }
    }

    // MARK: - Helpers

    private static let project = Project(
        name: "p",
        folderURL: URL(fileURLWithPath: "/tmp/p")
    )

    private static func session(
        kind: AgentKind,
        mode: AgentPermissionMode?,
        usesNativeUI: Bool = false
    ) -> AgentSession {
        var session = AgentSession(kind: kind, title: "t", usesNativeUI: usesNativeUI)
        session.permissionMode = mode
        return session
    }

    /// The words a terminal launch hands the CLI.
    private static func launchWords(
        kind: AgentKind,
        mode: AgentPermissionMode?
    ) throws -> [String] {
        try tokenizing(
            XCTUnwrap(
                AgentLauncher.plan(for: session(kind: kind, mode: mode), in: project).arguments.last
            )
        )
    }

    /// A natively rendered conversation, built but never started: the chips are configured from
    /// the record, so nothing here needs a process.
    private static func conversationController(
        kind: AgentKind,
        mode: AgentPermissionMode? = nil
    ) -> ConversationViewController {
        var session = AgentSession(kind: kind, title: "Reply", usesNativeUI: true)
        session.permissionMode = mode
        let controller = requireConversationViewController(
            agentSession: session,
            project: Project(
                name: "Reply",
                folderURL: URL(fileURLWithPath: NSTemporaryDirectory())
            ),
            customizationLookup: { _ in .empty }
        )
        _ = controller.view
        return controller
    }

    /// The rows a chip would actually drop down, taken through its own presentation seam rather
    /// than by calling the provider a test would have to reach past `private` to find.
    private static func offeredRows(
        ofChipTitled title: String,
        in view: NSView
    ) -> [ThemedMenuEntry]? {
        guard let chip = self.chip(titled: title, in: view) else { return nil }
        var offered: [ThemedMenuEntry]?
        chip.menuPresentationOverride = { presentation in
            offered = presentation.entries
            return nil
        }
        _ = chip.accessibilityPerformShowMenu()
        chip.menuPresentationOverride = nil
        return offered
    }

    /// Presses a row on a chip by name, the way a pointer would.
    private static func choose(titled title: String, on chip: ChipView) {
        chip.menuPresentationOverride = { presentation in
            presentation.entries.compactMap(\.item).first { $0.title == title }
        }
        _ = chip.accessibilityPerformShowMenu()
        chip.menuPresentationOverride = nil
    }

    /// Finding a chip by its title is also how "the control is offered at all" is asserted, so
    /// a hidden branch of the tree is not searched: a stack keeps its hidden arranged views as
    /// subviews, and a chip nobody can see is not a chip on offer.
    private static func chip(titled title: String, in view: NSView) -> ChipView? {
        guard !view.isHidden else { return nil }
        if let chip = view as? ChipView, chip.accessibilityTitle() == title { return chip }
        for subview in view.subviews {
            if let found = chip(titled: title, in: subview) { return found }
        }
        return nil
    }

    /// The same search by identifier, for a chip whose title states something discovered from
    /// the machine rather than something this test chose.
    private static func chip(identified identifier: String, in view: NSView) -> ChipView? {
        guard !view.isHidden else { return nil }
        if let chip = view as? ChipView, chip.accessibilityIdentifier() == identifier {
            return chip
        }
        for subview in view.subviews {
            if let found = chip(identified: identifier, in: subview) { return found }
        }
        return nil
    }

    /// The rows a person can actually pick, which is what has to match across the surfaces —
    /// the closing note is a sentence, not a choice. Flattened to strings so the whole row
    /// reads in a failure message rather than only the first field that differed.
    private static func choices(in rows: [ThemedMenuEntry]) -> [String] {
        rows.compactMap(\.item)
            .filter(\.isEnabled)
            .map { "\($0.isSelected ? "[x]" : "[ ]") \($0.title) | \($0.subtitle ?? "")" }
    }

    private static func value(after flag: String, in words: [String]) -> String? {
        guard let index = words.firstIndex(of: flag), index + 1 < words.count else { return nil }
        return words[index + 1]
    }

    /// Splits a launch line into the words a shell would pass on, without running it. The same
    /// approach as `AgentLaunchQuotingTests`: the fixed `cd … && exec ` prefix is dropped and the
    /// rest goes through `set --`, which is the shell's own tokenizer.
    private static func tokenizing(_ launchLine: String) throws -> [String] {
        let marker = "&& \(ShellCommand(word: "exec").source) "
        let prefix = try XCTUnwrap(
            launchLine.range(of: marker),
            "the launch line stopped being 'cd' … && 'exec' …"
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "set -- \(launchLine[prefix.upperBound...]); printf '%s\u{1}' \"$@\""
        ]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return String(decoding: data, as: UTF8.self)
            .split(separator: "\u{1}", omittingEmptySubsequences: false)
            .dropLast()
            .map(String.init)
    }
}
