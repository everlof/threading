import AppKit
import ThreadingExtensionKit
import ThreadingRemoteKit

// MARK: - Shared Session Action Presentation

/// The one description of the surface a session can switch *to*.
///
/// The row menu and pane-header button are two entrances to the same relaunch. Keeping the
/// target title here means a native session cannot say "Claude Code UI" in one place and
/// "Terminal" in another, or leave the button pointing at the surface already on screen.
struct SessionSurfaceTogglePresentation: Equatable {
    static var nativeTitle: String { L10n.string("Native UI (Experimental)") }
    static let nativeSymbol = "bubble.left.and.text.bubble.right"
    static let originalSymbol = "terminal"

    let targetUsesNativeUI: Bool
    let title: String
    let symbolName: String

    init(session: AgentSession) {
        targetUsesNativeUI = !session.usesNativeUI
        title = Self.title(usesNativeUI: targetUsesNativeUI, kind: session.kind)
        symbolName = targetUsesNativeUI ? Self.nativeSymbol : Self.originalSymbol
    }

    static func title(usesNativeUI: Bool, kind: AgentKind) -> String {
        usesNativeUI ? nativeTitle : kind.originalUITitle
    }

    /// Whether this runtime has a surface to switch *to*.
    ///
    /// Both halves are required and neither is enough on its own: a runtime Threading cannot
    /// render has nothing to offer, and a runtime whose own terminal shows a *different*
    /// conversation must not be offered it. Cursor is the second case — its TUI and its ACP
    /// server keep separate chats — which is why the answer is a capability pair rather than
    /// `supportsNativeUI` alone. See `AgentCapabilities.terminalUI`.
    static func canSwitchSurface(_ kind: AgentKind) -> Bool {
        kind.supportsNativeUI && kind.supports(.terminalUI)
    }
}

// MARK: - Permission Mode Presentation

/// The one description of how much a conversation may do before it has to ask.
///
/// Three surfaces offer this same choice — the session row's menu, the opening composer's chip
/// and the reply composer's chip — and each had grown its own rows, its own wording for the
/// inherit item and its own copy of the symbol. That is exactly the split
/// `SessionSurfaceTogglePresentation` above exists to prevent: one setting cannot be allowed to
/// name the app-wide default one way in a menu and another way one click along.
///
/// What the three genuinely differ about is `Timing` — when a mode chosen here starts to
/// apply — so that is the only thing they pass in.
enum PermissionModePresentation {
    static let symbol = "hand.raised"

    /// What a chip says when *no* source can name a mode: no choice here, nothing in Settings,
    /// nothing in the agent's own configuration, and no conversation on this login to have
    /// observed one. It names where the decision is made because there is genuinely nothing else
    /// to name — the same last resort, reached the same way, as the model chip's "Agent's
    /// choice". Every other case names the posture and qualifies it below.
    static var agentSettingTitle: String { L10n.string("Agent's Setting") }

    /// The row offered when nothing here and nothing in Settings has chosen. It defers to the
    /// CLI's own configuration, which Threading cannot read, so it names where the decision is
    /// made rather than a mode.
    static var agentSettingRowTitle: String { L10n.string("Use Agent's Setting") }

    /// Marks the mode a session falls back to when it chooses nothing of its own.
    ///
    /// It replaces a row: the menu used to open with "Use Default (Auto)" above a list that
    /// then named Auto again, so the same posture appeared twice and the two rows meant subtly
    /// different things — one followed Settings, the other pinned today's value. Marking the
    /// mode where it already stands says both, in one place, in the same glance that reads what
    /// the mode does.
    static var defaultSuffix: String { L10n.string("  (default)") }

    /// A mode nothing configured, named because this agent ran in it before. Qualified apart
    /// from a configured one for the reason `ClaudeAccountLastRunPermissionMode` states: it is
    /// where the agent got to last time, not a setting anyone wrote. The model menu's
    /// `(last used)` says the same thing about the same kind of evidence.
    static var lastUsedSuffix: String { L10n.string("  (last used)") }

    /// How the marked row qualifies where its mode came from.
    static func suffix(for source: ResolvedPermissionMode.Source) -> String {
        switch source {
        case .appDefault, .agentConfiguration: return defaultSuffix
        case .observedInThisConversation, .rememberedFromEarlierRun: return lastUsedSuffix
        }
    }

    /// The title of the row that carries `mode`, marked where it is the inherited answer.
    static func rowTitle(
        _ mode: AgentPermissionMode,
        inherited: ResolvedPermissionMode
    ) -> String {
        mode == inherited.mode ? "\(mode.displayName)\(suffix(for: inherited.source))" : mode.displayName
    }

    /// Names the mode that will actually apply, not only the one chosen on this surface.
    ///
    /// With no choice of its own the chip shows what the session inherits — the app-wide
    /// default, the agent's own configuration, or failing both what the agent was last observed
    /// in — and names where the decision goes only when no source can answer at all.
    static func chipTitle(
        selected: AgentPermissionMode?,
        inherited: ResolvedPermissionMode
    ) -> String {
        (selected ?? inherited.mode)?.displayName ?? agentSettingTitle
    }

    /// What a chip's tooltip adds: the value is in the chip, and this says whose value it is.
    /// Nil where the chip carries the user's own choice, which needs no explaining.
    static func chipTooltip(
        selected: AgentPermissionMode?,
        inherited: ResolvedPermissionMode
    ) -> String? {
        guard selected == nil, let mode = inherited.mode else { return nil }

        switch inherited.source {
        case .appDefault:
            return L10n.format("%@ — the default for new chats in Settings.", mode.displayName)
        case .agentConfiguration:
            return L10n.format("%@ — this agent's own setting.", mode.displayName)
        case .observedInThisConversation, .rememberedFromEarlierRun:
            return L10n.format(
                "%@ — what this agent last ran in. It decides again each launch.",
                mode.displayName
            )
        }
    }

    /// The app-wide default new conversations inherit, read in one place so three surfaces
    /// cannot each reach for a different setting.
    @MainActor
    static var appDefault: AgentPermissionMode? { AppSettings.shared.defaultPermissionMode }

    /// When a mode chosen on a given surface starts to apply.
    enum Timing {
        /// The conversation does not exist yet, so the choice is simply what it launches with
        /// and there is nothing to say about a delay.
        case whenTheSessionStarts
        /// A live transport carries it to the running agent straight away.
        case immediately
        /// Only the record changes. What the session row's item has always meant: the mode is
        /// stated in the flags of the process this configures at startup.
        case whenTheChatRestarts
    }

    /// The sentence a menu adds under its rows when choosing one changes the record and not the
    /// running agent. Nil where the choice lands where it says it does.
    static func note(for timing: Timing) -> String? {
        switch timing {
        case .whenTheSessionStarts, .immediately:
            nil
        case .whenTheChatRestarts:
            L10n.string("Applies the next time this chat starts.")
        }
    }

    /// What a live conversation is told when inherit is chosen and there is no app-wide default
    /// to resolve it to. The control channel names one mode and has no "return to what you were
    /// configured with", so the record is all that can change, and saying so is what keeps the
    /// chip from reading as a posture the agent never took.
    static var inheritRecordedOnly: String {
        L10n.string(
            "This chat keeps the permission mode it is running with. "
                + "The agent's own setting applies the next time it starts."
        )
    }

    /// The rows every surface offers: each mode once, with what it does and what it costs on
    /// this agent, and the inherited answer marked where it stands in that list.
    ///
    /// The inherited answer is *not* a row of its own. It was, and it named a mode the list
    /// then repeated — a menu of seven items for six postures, in which the pair that named the
    /// same mode were the two rows hardest to tell apart. The marked row answers `nil`, which is
    /// what the row above it used to answer: choosing it leaves the session following whatever
    /// it was following rather than pinning a copy of that value today. Only where *nothing* can
    /// name the inherited mode does a separate row appear, and then it duplicates nothing —
    /// "Agent's Setting" is not one of the six.
    ///
    /// Both `representedValue` and `onChoose` are filled, because the two kinds of caller read
    /// the answer differently — a `ChipView` reads the value back through its own `onSelect`,
    /// a presented menu runs the row's action. Passing no `onChoose` leaves the value the only
    /// answer, which is what the chips want.
    static func rows(
        for kind: AgentKind,
        selected: AgentPermissionMode?,
        inherited: ResolvedPermissionMode,
        timing: Timing,
        onChoose: ((AgentPermissionMode?) -> Void)? = nil
    ) -> [ThemedMenuEntry] {
        var rows: [ThemedMenuEntry] = []

        if inherited.mode == nil {
            rows.append(.item(ThemedMenuItem(
                title: agentSettingRowTitle,
                representedValue: nil,
                isSelected: selected == nil,
                onChoose: onChoose.map { choose in { choose(nil) } }
            )))
        }

        for mode in AgentPermissionMode.allCases {
            // The marked row *is* the inherit row, so it answers nil and takes the checkmark
            // for a session that has chosen nothing as well as for one that chose this mode —
            // both run it, and a menu that marked only one of them would be reporting a
            // difference the session cannot act on.
            let isDefault = mode == inherited.mode
            // The description rides as the subtitle rather than a hover tooltip, so what a
            // mode actually permits is read in the same glance that chooses it.
            rows.append(.item(ThemedMenuItem(
                title: rowTitle(mode, inherited: inherited),
                subtitle: [mode.menuDescription, mode.caveat(for: kind)]
                    .compactMap { $0 }
                    .joined(separator: " "),
                representedValue: isDefault ? nil : mode,
                isSelected: isDefault ? (selected == nil || selected == mode) : mode == selected,
                onChoose: onChoose.map { choose in { choose(isDefault ? nil : mode) } }
            )))
        }

        // A row that answers nothing, because the sentence is about the whole menu rather than
        // about any one mode in it.
        if let note = note(for: timing) {
            rows.append(.separator)
            rows.append(.item(ThemedMenuItem(title: note, isEnabled: false)))
        }

        return rows
    }
}

// MARK: - Conversation Speed Presentation

/// The per-conversation speed choice shared by the opening and reply composers.
///
/// A typed choice rather than a `Bool?` in a menu: nil is a real answer (follow General), and
/// `representedValue` cannot otherwise distinguish that row from one with no value at all.
enum ConversationSpeedChoice: CaseIterable, Equatable {
    case followGeneral
    case standard
    case fast

    var fastMode: Bool? {
        switch self {
        case .followGeneral: nil
        case .standard: false
        case .fast: true
        }
    }
}

/// One vocabulary and one set of rows for speed before and after a conversation exists.
enum ConversationSpeedPresentation {
    static let symbol = "bolt.fill"

    static var followGeneralTitle: String { L10n.string("Follow General Setting") }
    static var followGeneralDetail: String {
        L10n.string("Uses the Conversation Speed choice in General settings.")
    }
    static var standardTitle: String { L10n.string("Standard") }
    static var fastTitle: String { L10n.string("Fast") }
    static var standardDetail: String { L10n.string("Normal speed and usage") }
    static var fastDetail: String { L10n.string("1.5× speed, increased usage") }

    /// Whether choosing inheritance can be applied to the process on this surface.
    enum Timing: Equatable {
        case whenTheSessionStarts
        case whileRunning
    }

    /// What the chip says the session will use.
    ///
    /// The same four sources, in the same order, as `AgentModels.effectiveFastMode` — and it
    /// asks that function rather than restating three of them. The two used to disagree about
    /// the fourth: a Claude conversation whose flag starts off *is* Standard, which
    /// `effectiveFastMode` has always resolved and this chip reported as "Agent's Setting",
    /// naming a place rather than the speed the session was about to run at.
    ///
    /// Nil survives only for a service tier this app cannot read — a Codex account whose
    /// `config.toml` names a tier that is neither Fast nor Standard — where naming either would
    /// be wrong.
    @MainActor
    static func chipTitle(
        selected: Bool?,
        kind: AgentKind,
        model: String?,
        account: AgentAccount?,
        projectDirectory: String? = nil
    ) -> String {
        let effective = AgentModels.effectiveFastMode(
            selected: selected,
            kind: kind,
            model: model,
            account: account,
            projectDirectory: projectDirectory,
            startupSpeed: AppSettings.shared.startupSpeed(for: kind)
        )
        switch effective {
        case true: return fastTitle
        case false: return standardTitle
        case nil: return L10n.string("Agent's Setting")
        }
    }

    /// Three rows because all three answers remain meaningfully different even when General
    /// currently says Standard or Fast: following General should follow a later change, while
    /// an explicit conversation override should not.
    @MainActor
    static func rows(
        selected: Bool?,
        kind: AgentKind,
        timing: Timing
    ) -> [ThemedMenuEntry] {
        var followDetail = followGeneralDetail
        if timing == .whileRunning,
           AppSettings.shared.startupSpeed(for: kind) == .agentSetting {
            followDetail += " " + L10n.string("Applies the next time this chat starts.")
        }

        return [
            .item(ThemedMenuItem(
                title: followGeneralTitle,
                subtitle: followDetail,
                representedValue: ConversationSpeedChoice.followGeneral,
                isSelected: selected == nil
            )),
            .item(ThemedMenuItem(
                title: standardTitle,
                subtitle: standardDetail,
                representedValue: ConversationSpeedChoice.standard,
                isSelected: selected == false
            )),
            .item(ThemedMenuItem(
                title: fastTitle,
                subtitle: fastDetail,
                representedValue: ConversationSpeedChoice.fast,
                isSelected: selected == true
            ))
        ]
    }

    /// A provider-owned setting has no generic live reset request. Record inheritance now and
    /// state when it can become true instead of making the running process appear to change.
    static var inheritRecordedOnly: String {
        L10n.string(
            "This chat keeps the speed it is running with. "
                + "The agent's own setting applies the next time it starts."
        )
    }
}

// MARK: - Share Link Grants

/// The three links Share Chat can put on the clipboard, and what each one hands out.
///
/// They existed only as three button titles and a `switch` on the button *index*, which put the
/// two facts a person actually decides between — what the holder may do, and what they still may
/// not — in no place the dialog could show them. "Collaborator + Approval" is a permission model
/// stated as a button label; nobody reads it as "may let the agent run commands without me".
/// Naming the grant is what lets the sheet print it beside the button that hands it out, and
/// what replaces the index arithmetic with a case.
enum ShareLinkGrant: CaseIterable {
    /// Watch, and nothing else.
    case view
    /// Watch and drive, but permission requests still come back to the owner.
    case collaborate
    /// Watch, drive, and answer permission requests in the owner's place.
    case collaborateAndApprove

    var capability: RemoteCapability {
        switch self {
        case .view: .view
        case .collaborate, .collaborateAndApprove: .interact
        }
    }

    var canApprovePermissions: Bool { self == .collaborateAndApprove }

    /// A chat that has never run has nothing to watch, and a viewer cannot wake it — only a
    /// participant who may act can. So this is the one grant that waits for a running session.
    var requiresRunningSession: Bool { self == .view }

    /// The button, which says what pressing it *does* — it copies a link rather than sharing
    /// there and then, and every one of the three had to admit that or none of them could.
    var buttonTitle: String {
        switch self {
        case .view: L10n.string("Copy View-Only Link")
        case .collaborate: L10n.string("Copy Collaborator Link")
        case .collaborateAndApprove: L10n.string("Copy Collaborator + Approval Link")
        }
    }

    /// The grant's name in the sheet's own words, directly above the button that grants it.
    var name: String {
        switch self {
        case .view: L10n.string("View only")
        case .collaborate: L10n.string("Collaborator")
        case .collaborateAndApprove: L10n.string("Collaborator + approval")
        }
    }

    /// One line, phrased as what the holder can do and then what they still cannot — the second
    /// half being the part a title can never carry.
    var summary: String {
        switch self {
        case .view:
            L10n.string(
                "Follows this chat as it happens. Cannot type, cannot send a prompt, and cannot "
                    + "answer a permission request."
            )
        case .collaborate:
            L10n.string(
                "Everything a viewer can do, and can also type in the terminal and send prompts. "
                    + "Permission requests still come to you."
            )
        case .collaborateAndApprove:
            L10n.string(
                "Everything a collaborator can do, and can also answer permission requests — "
                    + "letting the agent run commands and change files without asking you."
            )
        }
    }

    /// Shown under the grant when this session cannot offer it yet, in place of a button that
    /// is merely dimmed and unexplained.
    static var unavailableUntilRunning: String {
        L10n.string("Start this chat first — watching alone never starts an agent.")
    }
}

enum ShareSheetDefaults {
    /// Matches the permission sheet's diff, so the two alerts that carry an accessory are the
    /// same width rather than each one the width its own content happened to want.
    static let accessoryWidth: CGFloat = PermissionDiffDefaults.width
}

/// The Share Chat sheet, built without being run.
///
/// Separated from the menu handler for the reason `ConfirmationRequest` gives for keeping copy
/// at the call site: a test can then hold the wording, the button order and the disabled state
/// to what the action actually does. The handler is a modal and a pasteboard write, neither of
/// which a test can read through.
@MainActor
enum ShareChatSheet {

    /// Runs the sheet and puts the resulting invitation on the pasteboard.
    ///
    /// Here rather than on the sidebar because two surfaces offer this now — the session's
    /// context menu and the sharing pane's own button — and a link that expires in 24 hours,
    /// grants exactly one chat, and is copied rather than shown is too much behaviour to have
    /// two copies of. The sheet itself stays a value above, so the wording remains testable.
    static func run(for sessionID: SessionID) {
        guard let session = ProjectStore.shared.session(withID: sessionID) else { return }
        let grants = ShareLinkGrant.allCases
        let chosen = ConfirmationAlert.choose(request(
            chatTitle: session.displayTitle,
            isRunning: AgentRuntime.shared.isRunning(sessionID: sessionID)
        ))
        guard let chosen, grants.indices.contains(chosen) else { return }
        let grant = grants[chosen]

        RemoteAccessCoordinator.shared.createSessionShare(
            for: sessionID,
            capability: grant.capability,
            canApprovePermissions: grant.canApprovePermissions
        ) { result in
            switch result {
            case .success(let created):
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(created.url.absoluteString, forType: .string)
            case .failure(let error):
                let unavailable = ThemedAlert()
                unavailable.messageText = L10n.string("Secure relay isn’t ready")
                unavailable.informativeText = error.localizedDescription
                unavailable.alertStyle = .warning
                unavailable.runModal()
            }
        }
    }

    static func request(chatTitle: String, isRunning: Bool) -> ChoiceRequest {
        // Four buttons, and the named modal responses stop at three — so the fourth used to
        // arrive through `default:`, sharing that branch with every unrelated dismissal.
        // `choose` reads it back by index.
        ChoiceRequest(
            prompt: .shareChatLink,
            title: L10n.format("Share “%@”", chatTitle),
            message: L10n.string(
                "A single-use invitation to this one chat. It expires in 24 hours if nobody "
                    + "accepts it; once accepted, that person keeps access until you choose Stop "
                    + "Sharing Chat. No link reaches your other chats, projects, or settings."
            ),
            options: ShareLinkGrant.allCases.map {
                ConfirmationOption(
                    title: $0.buttonTitle,
                    isEnabled: isRunning || !$0.requiresRunningSession
                )
            },
            style: .informational,
            accessory: grantsAccessory(isRunning: isRunning)
        )
    }

    /// Each grant named and described, in the order of the buttons underneath — so the sheet
    /// reads top to bottom as three offers and then three ways to take one.
    ///
    /// A grant the session cannot offer yet keeps its place and says why, rather than leaving a
    /// dimmed button to be guessed at; that is the same rule `ConfirmationOption.isEnabled`
    /// already states for the button itself.
    ///
    /// Sized rather than left to Auto Layout: the alert lays an accessory out by its **frame**,
    /// so the height has to be measured here, against a width the wrapping labels were told
    /// about. A stack left at its natural size arrives one line tall with the rest clipped.
    static func grantsAccessory(isRunning: Bool) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.medium
        stack.translatesAutoresizingMaskIntoConstraints = false

        for grant in ShareLinkGrant.allCases {
            let group = NSStackView()
            group.orientation = .vertical
            group.alignment = .leading
            group.spacing = Design.Spacing.hairline
            group.translatesAutoresizingMaskIntoConstraints = false

            group.addArrangedSubview(label(
                grant.name,
                font: Design.Typography.emphasizedBody(),
                color: Design.Text.label
            ))
            group.addArrangedSubview(label(
                grant.summary,
                font: Design.Typography.subheading(),
                color: Design.Text.secondary
            ))
            if grant.requiresRunningSession, !isRunning {
                group.addArrangedSubview(label(
                    ShareLinkGrant.unavailableUntilRunning,
                    font: Design.Typography.subheading(),
                    color: Design.Text.tertiary
                ))
            }

            stack.addArrangedSubview(group)
            group.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        // Measured *before* the container exists, and the container built at that height. Sizing
        // it afterwards is what an accessory looks like when it renders blank: the stack is laid
        // out against the height the container had at the time, and pinning its top to a box of
        // no height puts every label below the bounds that get drawn. Each label carries a
        // `preferredMaxLayoutWidth`, so the stack can answer for its own height with no ancestor.
        let container = NSView(frame: NSRect(
            x: 0,
            y: 0,
            width: ShareSheetDefaults.accessoryWidth,
            height: stack.fittingSize.height
        ))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor)
        ])
        container.layoutSubtreeIfNeeded()
        return container
    }

    private static func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.textColor = color
        label.isSelectable = false
        label.preferredMaxLayoutWidth = ShareSheetDefaults.accessoryWidth
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }
}

enum SessionActionMenuDefaults {
    static var attachmentsTitle: String { L10n.string("Attachments") }
    static let attachmentsSymbol = "paperclip"

    /// The submenu holding the set-once-and-leave configuration. Named here because the row
    /// menu and its tests must agree on where those items went.
    static var sessionOptionsTitle: String { L10n.string("Session Options") }
}

// MARK: - Session Row Actions

/// The menu behind a session row's `⋯` hover button and its handlers. Split from the main
/// controller file purely for size; the menu targets the session in `actionSessionID`, set as
/// the menu opens.
extension ProjectSidebarViewController {

    /// Shows a row's actions beneath its hover button.
    ///
    /// Archiving is offered rather than deletion, since a session's conversation outlives the
    /// app and filing it away should not destroy anything.
    func showRowActions(for sessionID: SessionID, from anchor: NSView) {
        guard let session = projectStore.session(withID: sessionID) else { return }

        actionSessionID = sessionID
        presentSidebarMenu(sessionActionEntries(for: session), from: anchor)
    }

    /// The full set of session actions, shared by the row's `⋯` hover button, its right-click
    /// context menu, and the pane header's Context button so none can drift — a second entrance
    /// that offered fewer actions is exactly the kind of gap that grows silently.
    ///
    /// The caller sets `actionSessionID` first: every handler here reads it, and it is set as
    /// the menu is built, so whichever surface presents the menu targets the right session.
    func sessionActionEntries(for session: AgentSession) -> [ThemedMenuEntry] {
        let sessionID = session.id
        var entries: [ThemedMenuEntry] = []

        entries.append(action(
            session.isPinned ? L10n.string("Unpin") : L10n.string("Pin"),
            symbol: session.isPinned ? "pin.slash" : "pin"
        ) { [weak self] in self?.togglePinnedClicked() })
        entries.append(snoozeEntry(for: session))
        // The sidebar only ever lists unarchived sessions, so this is always "Archive";
        // restoring one happens from Settings, where the archived sessions live.
        entries.append(action(L10n.string("Archive"), symbol: "archivebox") { [weak self] in
            self?.archiveClicked()
        })

        if AgentRuntime.shared.isRunning(sessionID: sessionID) {
            entries.append(action(L10n.string("Close Session"), symbol: "stop.circle") {
                [weak self] in
                self?.closeSessionClicked()
            })
        }

        // The middle of this menu was once a twelve-item unbroken run, so it now reads in
        // groups: side chats, then the appearance-and-conduct pair plus the folded options,
        // then identity-and-housekeeping. The fold takes what is set once and left alone;
        // Theme and Permission Mode stay top-level because they are reached for repeatedly.
        appendGroupSeparator(&entries)
        entries.append(contentsOf: sideChatEntries(for: session))

        appendGroupSeparator(&entries)
        entries.append(sessionThemeEntry(for: sessionID))
        // Beside Theme rather than beside Mute: both of these are presentation — how this chat
        // looks, how it sounds — while Mute is delivery and lives in the fold below.
        entries.append(sessionSoundEntry(for: sessionID))
        if let permissionMode = permissionModeEntry(for: session) {
            entries.append(permissionMode)
        }
        entries.append(sessionOptionsEntry(for: session))

        appendGroupSeparator(&entries)
        // A session's folder is its project's checkout, so this is the same offer the project
        // row makes, made where the user already is. It leads the identity group because it is
        // the one item here that leaves the app.
        if let project = projectStore.executionProject(forSessionID: sessionID),
           let openIn = OpenInMenu.submenuEntry(for: .folder(project.folderURL)) {
            entries.append(openIn)
        }
        entries.append(action(L10n.string("Rename Session…"), symbol: "pencil") { [weak self] in
            self?.renameSessionClicked()
        })
        // Absent rather than disabled when the agent is mid-turn or has no naming tool: a
        // greyed row here would be one more thing to read in a menu that already reads long,
        // and the reason it is unavailable is not something a disabled item could say.
        if SessionCoordinator.canAskAgentToRename(sessionID) {
            entries.append(action(L10n.string("Rename with Agent"), symbol: "sparkles") {
                [weak self] in
                self?.askAgentToRenameClicked()
            })
        }
        // Everything about this chat that is needed *elsewhere* — an id to resume by, a path
        // to grep — folded behind one Copy item; see `sessionCopyEntry`.
        let copyProject = projectStore.executionProject(forSessionID: sessionID)
        entries.append(sessionCopyEntry(
            for: session,
            project: copyProject,
            transcriptURL: copyProject.flatMap { SessionTranscript.url(for: session, in: $0) }
        ))
        if AppSettings.shared.remoteAccessEnabled {
            entries.append(action(L10n.string("Share Chat…"), symbol: "square.and.arrow.up") {
                [weak self] in
                self?.shareSessionClicked()
            })
            if RemoteAccessCoordinator.shared.hasSessionShares(sessionID) {
                entries.append(action(L10n.string("Stop Sharing Chat"), symbol: "eye.slash") {
                    [weak self] in
                    self?.stopSharingSessionClicked()
                })
            }
        }
        if let move = moveToAccountEntry(for: session) { entries.append(move) }
        if let cont = continueWithProviderEntry(for: session) { entries.append(cont) }

        appendGroupSeparator(&entries)
        entries.append(action(L10n.string("Delete Session"), symbol: "trash") { [weak self] in
            self?.deleteSessionClicked()
        })

        // The row's own identity, lowercased to match the sanitized snapshot IDs extensions
        // already hold.
        entries.append(contentsOf: extensionCommandEntries(
            placement: .sessionRow,
            context: ExtensionCommandContext(
                projectID: projectStore.project(forSessionID: sessionID)?
                    .id.uuidString.lowercased(),
                sessionID: sessionID.uuidString.lowercased()
            )
        ))
        return entries
    }

    /// One plain action row, with the mark that names it.
    ///
    /// **The marks are not decoration here.** This menu is the longest in the app — past thirty
    /// rows on a shared, running session — and read as an unbroken wall of words in which the
    /// only way to find Archive was to read every title above it. A glyph column is what a menu
    /// this long is scanned by: the eye lands on the shape and reads one title, rather than
    /// reading eight. Grouping by separator was the first half of that fix; this is the second.
    ///
    /// Nil is allowed and means *this row has no honest mark*, which is better than a vaguely
    /// related one — a column where two rows share a glyph they do not share a meaning with is
    /// worse than a column with a gap in it.
    private func action(
        _ title: String,
        symbol: String? = nil,
        _ body: @escaping () -> Void
    ) -> ThemedMenuEntry {
        .item(ThemedMenuItem(
            title: title,
            image: symbol.flatMap(ThemedMenuIcon.symbol),
            onChoose: body
        ))
    }

    /// Snooze sits beside Pin and Archive because all three change how a row is found, while
    /// only Archive files or closes anything. The shared builder gives row, context, and pane
    /// header the same Snooze/Unsnooze contract.
    private func snoozeEntry(for session: AgentSession) -> ThemedMenuEntry {
        if session.isSnoozed(at: Date()) {
            return action(L10n.string("Unsnooze"), symbol: "bell") {
                SessionSnoozeCenter.shared.unsnooze(session.id)
            }
        }

        var submenu = ScheduledTimePresets.wallClock(now: Date()).map { preset in
            ThemedMenuEntry.item(ThemedMenuItem(
                title: preset.title,
                subtitle: preset.detail,
                onChoose: {
                    SessionSnoozeCenter.shared.snooze(session.id, until: preset.date)
                }
            ))
        }
        submenu.append(.separator)
        submenu.append(action(L10n.string("Custom time…"), symbol: "calendar") { [weak self] in
            guard let self else { return }
            ScheduleMessageAlert.present(
                over: view.window,
                title: L10n.string("Snooze session"),
                informativeText: L10n.string("The session keeps running while snoozed."),
                confirmTitle: L10n.string("Snooze")
            ) { deadline in
                guard let deadline else { return }
                SessionSnoozeCenter.shared.snooze(session.id, until: deadline)
            }
        })
        return .item(ThemedMenuItem(
            title: L10n.string("Snooze"),
            image: ThemedMenuIcon.symbol("moon.zzz"),
            submenu: submenu
        ))
    }

    /// Everything about a chat that is needed *elsewhere*, folded behind one Copy item: the
    /// ids that name it (to the agent and to the app), the checkout it runs in, and the
    /// transcript on disk. One fold rather than a run of "Copy …" rows — they share one verb,
    /// none is reached for often, and an unbroken run is half of how this menu once outgrew
    /// its panel.
    ///
    /// Two identifiers, not one with a fallback: the agent's names the conversation to the
    /// CLI (`--resume`, the transcript filename), Threading's names it to the app and its
    /// extensions. The retired single item silently copied whichever existed, which made the
    /// string on the pasteboard mean different things on different rows. The agent's id and
    /// the transcript are absent rather than disabled before the agent has named the
    /// conversation — there is nothing true to copy under those titles yet.
    ///
    /// `project` and `transcriptURL` arrive resolved so this stays a pure builder a test can
    /// call. The transcript is resolved at build rather than on the click — the same cost
    /// `moveToAccountEntry` already pays through `SessionMigration.canMigrate` — because
    /// presence is the decision: a row that resolves nothing when chosen fails silently.
    func sessionCopyEntry(
        for session: AgentSession,
        project: Project?,
        transcriptURL: URL?
    ) -> ThemedMenuEntry {
        var submenu: [ThemedMenuEntry] = []
        // Two glyphs across four rows, and that is the point: the pair that are *identifiers*
        // share one mark and the pair that are *paths on disk* share the other, so the fold's
        // two kinds are told apart before any of the four titles is read.
        if session.resumeState.transcriptID != nil {
            submenu.append(action(L10n.string("Agent Session ID"), symbol: "number") {
                [weak self] in
                self?.copyAgentSessionIDClicked()
            })
        }
        submenu.append(action(L10n.string("Threading ID"), symbol: "number") { [weak self] in
            self?.copyThreadingIDClicked()
        })
        if let project {
            let path = project.folderPath
            submenu.append(action(L10n.string("Worktree Path"), symbol: "folder") {
                Self.copyToPasteboard(path)
            })
        }
        if let transcriptURL {
            submenu.append(action(L10n.string("Transcript Path"), symbol: "folder") {
                Self.copyToPasteboard(transcriptURL.path)
            })
        }
        return .item(ThemedMenuItem(
            title: L10n.string("Copy"),
            image: ThemedMenuIcon.symbol("doc.on.doc"),
            submenu: submenu
        ))
    }

    /// The one pasteboard write every Copy row shares — cleared first, so a failed set never
    /// leaves the previous clipboard posing as the copied value.
    static func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    /// Starts a new group. Skips where the previous group contributed nothing — most of the
    /// middle items are conditional, and two separators in a row read as a missing item rather
    /// than an empty group.
    private func appendGroupSeparator(_ entries: inout [ThemedMenuEntry]) {
        guard let last = entries.last, last.isItem else { return }
        entries.append(.separator)
    }

    /// The set-once configuration, folded behind one item: Interface, Claude Remote Control,
    /// Mute Notifications and Attachments. Everything in here keeps its own condition — the
    /// fold never shows an item the flat menu would have hidden — and the submenu is never
    /// empty, because the mute and attachments items are unconditional.
    private func sessionOptionsEntry(for session: AgentSession) -> ThemedMenuEntry {
        var submenu: [ThemedMenuEntry] = []
        if let interface = interfaceEntry(for: session) { submenu.append(interface) }
        if let remote = remoteControlEntry(for: session) { submenu.append(remote) }
        submenu.append(muteEntry(for: session))
        submenu.append(attachmentsEntry())
        return .item(ThemedMenuItem(
            title: SessionActionMenuDefaults.sessionOptionsTitle,
            image: ThemedMenuIcon.symbol("slider.horizontal.3"),
            submenu: submenu
        ))
    }

    /// Silences one conversation, or lets it speak again.
    ///
    /// The title reads the *resolved* answer rather than the session's own field, so a session
    /// inside a muted project offers Unmute — the alternative is a Mute item on something that
    /// is already silent, which says the state is the opposite of what it is.
    private func muteEntry(for session: AgentSession) -> ThemedMenuEntry {
        action(
            AttentionAlertScope.isMuted(sessionID: session.id)
                ? L10n.string("Unmute Notifications")
                : L10n.string("Mute Notifications"),
            symbol: AttentionAlertScope.isMuted(sessionID: session.id)
                ? "bell"
                : "bell.slash"
        ) { [weak self] in self?.toggleMutedClicked() }
    }

    private func attachmentsEntry() -> ThemedMenuEntry {
        // Through `ThemedMenuIcon` rather than a raw `NSImage`: an unconfigured symbol arrives
        // at whatever size the system hands out, which is how this one row's paperclip came out
        // a size off every mark beside it once the rest of the menu grew a column.
        .item(ThemedMenuItem(
            title: SessionActionMenuDefaults.attachmentsTitle,
            image: ThemedMenuIcon.symbol(SessionActionMenuDefaults.attachmentsSymbol),
            onChoose: { [weak self] in self?.attachmentsClicked() }
        ))
    }

    @objc private func toggleMutedClicked() {
        guard let sessionID = actionSessionID else { return }

        let wanted = !AttentionAlertScope.isMuted(sessionID: sessionID)
        let inherited = projectStore.project(forSessionID: sessionID)?
            .notificationsMuted ?? false

        // Storing nil where the answer already matches the project keeps this session
        // *following* it, so muting the project later still reaches here. An explicit value is
        // written only where it actually differs — which is the whole point of the field being
        // optional rather than a plain flag.
        guard projectStore.setNotificationsMuted(
            wanted == inherited ? nil : wanted,
            forSessionID: sessionID
        ).succeeded else {
            reload()
            presentProjectNotice(L10n.string("The project data could not be saved."))
            return
        }
        // The store knows nothing about notifications, so anything already on screen for this
        // session is still there until the alert center is asked to look again.
        AttentionAlertCenter.shared.preferencesChanged()
    }

    /// The side-chat rows: fork this conversation into one that starts with its context but
    /// keeps its own record.
    ///
    /// Both are hidden until there is something to fork — an agent that supports it, and a
    /// conversation that has actually started. A fork of nothing is an ordinary new session,
    /// which the composer already offers.
    private func sideChatEntries(for session: AgentSession) -> [ThemedMenuEntry] {
        var entries: [ThemedMenuEntry] = []

        // The other end of the fork: a side chat that has done its work sends the conclusion
        // to the session it was forked from. Absent rather than disabled when it cannot —
        // not a side chat, parent archived, agent mid-turn or dormant, workspace tools off —
        // for the same reason Rename with Agent is: none of those reasons fits a greyed row.
        if SessionCoordinator.canAskForReportBack(session.id) {
            entries.append(action(
                L10n.string("Send Result to Parent"),
                symbol: "arrowshape.turn.up.left"
            ) { [weak self] in
                self?.sendResultToParentClicked()
            })
        }

        guard session.kind.supportsForking, session.resumeState.isResumable else {
            return entries
        }

        entries.append(action(L10n.string("New Side Chat"), symbol: "bubble.left.and.bubble.right") {
            [weak self] in
            self?.newSideChatClicked()
        })
        entries.append(action(L10n.string("Ask on the Side…"), symbol: "questionmark.bubble") {
            [weak self] in
            self?.askOnTheSideClicked()
        })
        return entries
    }

    /// The surface switch for an agent that has both — Threading's own conversation view or
    /// the agent's terminal.
    ///
    /// Offered as an ordinary item rather than a warning, because it is not destructive: the
    /// two surfaces drive one conversation, resumed by the session's own id, so switching
    /// relaunches where it left off rather than starting over. What it does cost is the live
    /// process, which is why a working session confirms first.
    private func interfaceEntry(for session: AgentSession) -> ThemedMenuEntry? {
        guard SessionSurfaceTogglePresentation.canSwitchSurface(session.kind) else { return nil }

        let rows: [ThemedMenuEntry] = [true, false].map { usesNativeUI in
            .item(ThemedMenuItem(
                title: SessionSurfaceTogglePresentation.title(
                    usesNativeUI: usesNativeUI,
                    kind: session.kind
                ),
                isSelected: session.usesNativeUI == usesNativeUI,
                onChoose: { [weak self] in self?.setSurface(usesNativeUI: usesNativeUI) }
            ))
        }
        return .item(ThemedMenuItem(
            title: L10n.string("Interface"),
            image: ThemedMenuIcon.symbol("macwindow"),
            submenu: rows
        ))
    }

    /// Adds a "Move to Account" submenu when the conversation can move — it resumes by id, has
    /// a transcript recorded, and there is another account of the same agent to move it to.
    /// This conversation's answer about **Claude's own** Remote Control bridge, which is what
    /// lets claude.ai and the Claude mobile app drive it. Threading's Remote Access is the
    /// separate "Share Chat…" block below.
    ///
    /// Claude-only, since Codex has no equivalent. The inherit item names the app-wide default
    /// where it can and defers where it cannot: when that default is "follow", the answer lives
    /// in the account's own `/config` and resolves server-side when unset, so claiming a value
    /// here would be a guess shown as a fact.
    private func remoteControlEntry(for session: AgentSession) -> ThemedMenuEntry? {
        guard session.kind.supports(.remoteControl) else { return nil }

        let rows: [ThemedMenuEntry] = RemoteControlChoice.allCases.map { choice in
            .item(ThemedMenuItem(
                title: choice.menuTitle,
                isSelected: choice.sessionValue == session.remoteControl,
                onChoose: { [weak self] in self?.setRemoteControl(choice) }
            ))
        }
        return .item(ThemedMenuItem(
            title: L10n.string("Claude Remote Control"),
            image: ThemedMenuIcon.symbol("antenna.radiowaves.left.and.right"),
            submenu: rows
        ))
    }

    /// How much this conversation may do before it has to ask.
    ///
    /// Both agents, unlike Remote Control above: Claude names one mode and Codex reaches the
    /// same six postures through its approval policy and sandbox, so the item means something
    /// either way. Each mode names what it does, and where the session's agent expresses it
    /// imperfectly the row says so rather than implying parity.
    ///
    /// The inherited mode is marked where it stands in the list, named from whichever source can
    /// answer: Settings, then the agent's own configuration — `permissions.defaultMode` across
    /// Claude's settings layers, or Codex's `approval_policy` and `sandbox_mode` pair, both of
    /// which this app does read — then what this session's transcript recorded, and then what
    /// this login last ran in. A row naming where the decision lives appears only when none of
    /// them can, which is a login that has never run this agent at all.
    ///
    /// Record-only from here whichever agent it is, which is why the rows carry the
    /// restart note: unlike the reply composer's chip, this menu never touches the running
    /// process. See `setPermissionMode` below.
    private func permissionModeEntry(for session: AgentSession) -> ThemedMenuEntry? {
        guard session.kind.supportsPermissionModes else { return nil }

        let project = projectStore.executionProject(forSessionID: session.id)

        return .item(ThemedMenuItem(
            title: L10n.string("Permission Mode"),
            image: ThemedMenuIcon.symbol(PermissionModePresentation.symbol),
            submenu: PermissionModePresentation.rows(
                for: session.kind,
                selected: session.permissionMode,
                inherited: ResolvedPermissionMode.inherited(
                    for: session.kind,
                    account: AgentAccountDiscovery.account(
                        for: session.kind,
                        handle: session.accountHandle
                    ),
                    projectDirectory: project.map { session.workingDirectory(in: $0) },
                    observed: project.flatMap {
                        ObservedPermissionMode.known(for: session, in: $0)
                    }
                ),
                timing: .whenTheChatRestarts,
                onChoose: { [weak self] mode in self?.setPermissionMode(mode) }
            )
        ))
    }

    private func moveToAccountEntry(for session: AgentSession) -> ThemedMenuEntry? {
        guard let project = projectStore.executionProject(forSessionID: session.id),
              SessionMigration.canMigrate(session, in: project) else { return nil }

        let rows: [ThemedMenuEntry] = SessionMigration.destinations(for: session).map { account in
            .item(ThemedMenuItem(
                title: accountMenuLabel(account),
                onChoose: { [weak self] in self?.moveToAccount(account) }
            ))
        }
        return .item(ThemedMenuItem(
            title: L10n.string("Move to Account"),
            image: ThemedMenuIcon.symbol("person.crop.circle"),
            submenu: rows
        ))
    }

    /// Cross-provider is deliberately a different verb from Move. Move preserves one native
    /// transcript and can be reversed; Continue creates a new session whose first turn reads a
    /// provider-neutral handoff snapshot through MCP, while the original stays where it is.
    private func continueWithProviderEntry(for session: AgentSession) -> ThemedMenuEntry? {
        guard let project = projectStore.executionProject(forSessionID: session.id),
              ConversationContinuation.canContinue(session, in: project) else { return nil }

        let destinations = ConversationContinuation.destinations(for: session)
        guard !destinations.isEmpty else { return nil }

        let rows: [ThemedMenuEntry] = destinations.map { account in
            .item(ThemedMenuItem(
                title: continuationMenuLabel(account),
                onChoose: { [weak self] in self?.continueWith(account) }
            ))
        }
        return .item(ThemedMenuItem(
            title: L10n.string("Continue with…"),
            image: ThemedMenuIcon.symbol("arrow.triangle.branch"),
            submenu: rows
        ))
    }

    private func continuationMenuLabel(_ account: AgentAccount) -> String {
        let provider = account.provider.displayName
        guard account.provider.supportsAccounts, !account.isDefault else { return provider }
        return "\(provider) · \(accountMenuLabel(account))"
    }

    private func accountMenuLabel(_ account: AgentAccount) -> String {
        let name = AccountName.display(for: account)
        return account.emoji.map { "\($0)  \(name)" } ?? name
    }

    // MARK: - Handlers

    /// The move itself belongs to the coordinator, not here: it stops the session's process, so
    /// the pane showing that session has to reopen it under the new account. A sidebar reload
    /// alone leaves the terminal blank until the session is selected again.
    private func moveToAccount(_ account: AgentAccount) {
        guard let sessionID = actionSessionID else { return }
        delegate?.projectSidebar(self, moveSession: sessionID, toAccount: account)
    }

    private func continueWith(_ account: AgentAccount) {
        guard let sessionID = actionSessionID else { return }
        delegate?.projectSidebar(
            self,
            continueSession: sessionID,
            withAccount: account
        )
    }

    /// Records the choice only. A conversation already connected stays connected until it is
    /// relaunched, because the bridge is established by the process this setting configures at
    /// startup — silently killing a live one from a sidebar menu would be a second, hidden
    /// meaning for the same item.
    private func setRemoteControl(_ choice: RemoteControlChoice) {
        guard let sessionID = actionSessionID else { return }
        guard projectStore.setRemoteControl(choice.sessionValue, for: sessionID).succeeded else {
            reload()
            presentProjectNotice(L10n.string("The project data could not be saved."))
            return
        }
    }

    /// Records the choice only, for the same reason Remote Control does: the mode is stated in
    /// the flags of the process this configures at startup. A running session keeps the posture
    /// it launched with until it is relaunched — and Claude's own Shift+Tab, which Threading
    /// cannot see, may already have moved it somewhere else.
    ///
    /// Nil is the inherit row, not a missing value.
    private func setPermissionMode(_ mode: AgentPermissionMode?) {
        guard let sessionID = actionSessionID else { return }
        guard projectStore.setPermissionMode(mode, for: sessionID).succeeded else {
            reload()
            presentProjectNotice(L10n.string("The project data could not be saved."))
            return
        }
    }

    @objc private func newSideChatClicked() {
        guard let sessionID = actionSessionID else { return }
        delegate?.projectSidebar(self, createSideChatOf: sessionID, prompt: nil)
    }

    /// The same fork, opened with its question already asked — the composer's own
    /// "start it with an opening message" shape, reached from a session instead of a project.
    @objc private func askOnTheSideClicked() {
        guard let sessionID = actionSessionID,
              let session = projectStore.session(withID: sessionID) else { return }

        promptForText(
            title: L10n.string("Ask on the Side"),
            message: L10n.format(
                "Starts a side chat from “%@”, carrying everything it knows so far. "
                    + "Nothing you ask here joins that conversation.",
                session.displayTitle
            ),
            confirmTitle: L10n.string("Ask"),
            placeholder: L10n.string("What would you like to ask?")
        ) { [weak self] question in
            guard let self, !question.isEmpty else { return }
            self.delegate?.projectSidebar(self, createSideChatOf: sessionID, prompt: question)
        }
    }

    private func setSurface(usesNativeUI: Bool) {
        guard let sessionID = actionSessionID,
              let session = projectStore.session(withID: sessionID),
              usesNativeUI != session.usesNativeUI else { return }

        delegate?.projectSidebar(self, setUsesNativeUI: usesNativeUI, for: sessionID)
    }

    @objc private func attachmentsClicked() {
        guard let sessionID = actionSessionID else { return }
        delegate?.projectSidebar(self, showAttachmentsFor: sessionID)
    }

    @objc private func archiveClicked() {
        guard let sessionID = actionSessionID else { return }
        archiveSession(sessionID)
    }

    /// The one archive path, shared by the menu item and the row's hover button so the two
    /// cannot drift — the same reason `sessionActionEntries` is shared with the context menu.
    func archiveSession(_ sessionID: SessionID) {
        delegate?.projectSidebar(self, setArchived: true, for: sessionID)
    }

    @objc private func togglePinnedClicked() {
        guard let sessionID = actionSessionID,
              let session = projectStore.session(withID: sessionID) else { return }
        guard projectStore.setPinned(!session.isPinned, for: sessionID).succeeded else {
            reload()
            presentProjectNotice(L10n.string("The project data could not be saved."))
            return
        }
        reload()
    }

    /// Through the delegate rather than the runtime, so the row menu shares Cmd+W's
    /// confirmation instead of skipping it.
    @objc private func closeSessionClicked() {
        guard let sessionID = actionSessionID else { return }
        delegate?.projectSidebar(self, closeSession: sessionID)
    }

    /// Hands the naming back to the one thing that already knows what this chat is about.
    @objc private func askAgentToRenameClicked() {
        guard let sessionID = actionSessionID else { return }
        delegate?.projectSidebar(self, askAgentToRename: sessionID)
    }

    /// Hands the summarizing to the one thing that already holds the side chat's answer.
    @objc private func sendResultToParentClicked() {
        guard let sessionID = actionSessionID else { return }
        delegate?.projectSidebar(self, sendResultToParentOf: sessionID)
    }

    @objc private func renameSessionClicked() {
        guard let sessionID = actionSessionID,
              let session = projectStore.session(withID: sessionID) else { return }

        promptRename(
            title: L10n.string("Rename Session"),
            current: session.customTitle ?? "",
            placeholder: session.displayTitle,
            allowsEmpty: true
        ) { newTitle in
            guard self.projectStore.renameSession(id: sessionID, to: newTitle).succeeded else {
                self.reload()
                self.presentProjectNotice(L10n.string("The project data could not be saved."))
                return
            }
            self.reload()
        }
    }

    /// Copies the identifier that names this conversation outside Threading.
    ///
    /// It is the one fact about a chat that is needed *elsewhere* — grepping a transcript,
    /// resuming from a terminal, quoting a session in a bug report — and the only way to read
    /// it before this was to ask the agent running inside it. Guarded rather than falling back
    /// to Threading's id: the item is only offered while the agent has named the conversation,
    /// and if that stopped being true between the menu opening and the click, copying a
    /// different identifier under this title is worse than copying nothing.
    @objc private func copyAgentSessionIDClicked() {
        guard let sessionID = actionSessionID,
              let session = projectStore.session(withID: sessionID),
              let transcriptID = session.resumeState.transcriptID else { return }

        Self.copyToPasteboard(transcriptID.rawValue)
    }

    /// Copies Threading's own identifier for the chat — the one that stays constant across
    /// resumes, account moves and `Continue with…`, and the one extensions, support files and
    /// the diagnostics journal key by.
    @objc private func copyThreadingIDClicked() {
        guard let sessionID = actionSessionID,
              let session = projectStore.session(withID: sessionID) else { return }

        Self.copyToPasteboard(session.threadingIdentifier)
    }

    /// A copied link is a single-use invitation for this chat only. Collaboration and permission
    /// approval are separate rights, so a trusted participant can handle requests caused by
    /// their work without gaining theme, lifecycle, project, or other-chat access.
    ///
    /// The mechanics of the invitation — one use, one chat, 24 hours, revocable — belong in the
    /// message, but the *grants* do not: three sentences about three buttons in one paragraph is
    /// how "Collaborator + Approval" came to be a phrase the sheet never explained. Each grant
    /// now prints above its own button, in `shareGrantsAccessory`.
    @objc private func shareSessionClicked() {
        guard let sessionID = actionSessionID else { return }
        ShareChatSheet.run(for: sessionID)
    }

    @objc private func stopSharingSessionClicked() {
        guard let sessionID = actionSessionID else { return }
        RemoteAccessCoordinator.shared.revokeSessionShares(sessionID)
    }

    @objc private func deleteSessionClicked() {
        guard let sessionID = actionSessionID else { return }
        removeSession(sessionID)
    }
}

// MARK: - Remote Control Choice

/// The three items in a session's Claude Remote Control submenu.
///
/// It carries the *session's* stored value, which is why inherit is nil rather than a third
/// boolean: a conversation that never chose has to keep following the app default as that
/// default changes, and only an absent value can do that.
private enum RemoteControlChoice: CaseIterable {
    case inherit
    case on
    case off

    var sessionValue: Bool? {
        switch self {
        case .inherit: nil
        case .on: true
        case .off: false
        }
    }

    /// The inherit item names what it defers to, which depends on the app-wide setting: an
    /// answer when there is one to name, and Claude's own configuration when there is not.
    @MainActor
    var menuTitle: String {
        switch self {
        case .inherit: AppSettings.shared.claudeRemoteControl.inheritedMenuTitle
        case .on: L10n.string("Always On")
        case .off: L10n.string("Always Off")
        }
    }
}
