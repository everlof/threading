import SwiftUI
import ThreadingRemoteKit

/// The screen a chat is written on before it exists, and the screen it is read on after.
///
/// Starting a chat used to be a sheet: Start created the session, the sheet dismissed, and the
/// dashboard pushed the new chat once the dismissal had finished — two motions, with the list
/// flashing between them. The draft is now a route on the navigation stack. When the Mac
/// answers Start, the model records which session the draft became and this view crossfades
/// into `SessionDetailView` where it stands: the composer that took the prompt is replaced by
/// the composer that will take the next one, at the same edge, without the screen moving.
///
/// The route keeps its draft identity for the life of the stack entry. `RemoteAppModel` resolves
/// it to the session for continuity and for the push dedup, so the chat is the same navigation
/// subject it would have been opened from its row — the alternative, rewriting the path entry
/// to `.session`, rebuilds the detail screen and shows its loading placeholder for a frame.
struct SessionDraftView: View {
    @EnvironmentObject private var model: RemoteAppModel
    @Environment(\.remoteTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let draft: MobileSessionDraft
    /// Whether the drafting screen is still mounted. It outlives Start by the length of its
    /// fade, so the chat underneath is revealed rather than cut to.
    @State private var draftIsMounted = true

    private var startedDraft: MobileStartedDraft? {
        model.startedDrafts[draft.id]
    }

    private var startedSessionID: String? { startedDraft?.sessionID }

    private var startedSession: RemoteSessionSummaryDTO? {
        guard let startedSessionID else { return nil }
        return model.me?.sessions.first { $0.id == startedSessionID }
    }

    private var isDrafting: Bool {
        startedSessionID == nil
    }

    var body: some View {
        // The session's screen is placed underneath at full strength and the draft fades out
        // over it. The other way round — fading the session in — does nothing visible: the
        // surfaces are UIKit-hosted and do not take SwiftUI's opacity ramp, so the chat would
        // cut in over a draft still fading. The draft's own opacity is SwiftUI's to animate.
        ZStack {
            if let startedSession {
                SessionDetailView(
                    session: startedSession,
                    openingStrategy: startedDraft?.openingStrategy ?? .resumeIfNeeded
                )
            } else if startedSessionID != nil {
                ContentUnavailableView(
                    "Session unavailable",
                    systemImage: "bubble.left.and.exclamationmark.bubble.right",
                    description: Text("The link may have expired or the Mac may be offline.")
                )
            }
            if draftIsMounted {
                SessionDraftComposerScreen(draft: draft)
                    .opacity(isDrafting ? 1 : 0)
                    .scaleEffect(
                        isDrafting || reduceMotion ? 1 : SessionDraftMotion.recedeScale
                    )
                    .allowsHitTesting(isDrafting)
                    .zIndex(1)
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: SessionDraftMotion.startDuration),
                        value: isDrafting
                    )
            }
        }
        .background(theme.ground)
        .onChange(of: isDrafting) { _, isDrafting in
            guard !isDrafting else { return }
            retireDraft()
        }
        .onAppear {
            // Reached with the draft already started — a screen rebuilt on the stack — so
            // there is nothing to fade from.
            if !isDrafting { draftIsMounted = false }
        }
    }

    /// Unmounts the drafting screen once its fade has finished.
    private func retireDraft() {
        let duration = reduceMotion ? 0 : SessionDraftMotion.startDuration
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            draftIsMounted = false
        }
    }
}

/// The one motion from draft to chat.
enum SessionDraftMotion {
    /// How long the drafting screen takes to become the session's screen.
    static let startDuration: TimeInterval = 0.35
    /// The draft recedes a touch as the chat arrives over it; a plain crossfade read as a
    /// reload rather than as the same screen changing state.
    static let recedeScale: CGFloat = 0.98
    /// The hint in the empty ground comes and goes with the first character typed.
    static let hintDuration: TimeInterval = 0.2
    /// The action row unfolds under the prompt as the keyboard rises and folds as it goes —
    /// the keyboard's own duration, so the two read as one motion.
    static let foldDuration: TimeInterval = 0.25
}

/// The draft before Start: a quiet ground and one composer.
///
/// Three kinds of choice, at three weights. *What and where* — "Agent in AnotherTerminal" —
/// stands in the middle of the ground as one sentence of two dropdowns under the role's glyph,
/// with the branch beneath. *Who* — agent and account — is the disc at the navigation bar's
/// trailing edge, the runtime's mark ringed by the account's usage, the way a profile control
/// sits in a bar. *How* — model and effort as one line, speed as its own compact choice,
/// permissions and the interface as one glyph each — is the composer's action row under the
/// prompt, and it fits every phone width without scrolling. None of them is a box on the ground. The
/// composer is the screen's one surface: full-bleed,
/// no corner, a hairline above it and nothing else. It rides in the bottom safe-area inset, so
/// it sits on the keyboard's top edge while typing and follows the keyboard's interactive
/// dismissal. The action row comes and goes with the keyboard: while the prompt has focus the
/// chips are unfolded under it, and when the keyboard is down the composer is one thin line —
/// the prompt and Start — resting on the home indicator.
private struct SessionDraftComposerScreen: View {
    @EnvironmentObject private var appModel: RemoteAppModel
    @Environment(\.remoteTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let draft: MobileSessionDraft

    @State private var projectID = ""
    @State private var agentID = ""
    @State private var accountID = ""
    @State private var modelID = ""
    @State private var reasoningID = ""
    @State private var speedID = ""
    @State private var permissionID = ""
    /// The agent's supported UI is the safe default; Native stays an explicit experimental opt-in.
    @State private var surface = RemoteSessionSurface.terminal
    @State private var role = SessionDraftRole.agent
    @State private var prompt = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var hintAnimated = false
    @State private var promptSuggestion: String
    /// Set the moment the keyboard announces it is leaving. Focus ends only once it has gone,
    /// and a row folding then is a second motion after the first; folding on the announcement
    /// lets the row fold as the keyboard drops.
    @State private var keyboardIsLeaving = false
    @State private var runPickerIsPresented = false
    @FocusState private var promptIsFocused: Bool

    private static let promptSuggestions = [
        MobileL10n.string("Hunt down the flaky test…"),
        MobileL10n.string("Make the impossible state impossible…"),
        MobileL10n.string("Polish the rough edges…"),
        MobileL10n.string("Teach this screen a new trick…"),
        MobileL10n.string("Find the bug hiding in plain sight…"),
    ]

    init(draft: MobileSessionDraft) {
        self.draft = draft
        let evidenceID = ProcessInfo.processInfo.environment["THREADING_MOBILE_UI_EVIDENCE_ID"]
        let suggestion: String
        if let evidenceID {
            let index = evidenceID.unicodeScalars.reduce(0) { $0 + Int($1.value) }
                % Self.promptSuggestions.count
            suggestion = Self.promptSuggestions[index]
        } else {
            suggestion = Self.promptSuggestions.randomElement() ?? Self.promptSuggestions[0]
        }
        _promptSuggestion = State(initialValue: suggestion)
    }

    // MARK: - Catalogue

    private var catalog: RemoteNewSessionCatalogDTO? {
        appModel.me?.newSessionCatalog
    }

    private var selectedProject: RemoteProjectChoiceDTO? {
        catalog?.projects.first { $0.id == projectID }
    }

    /// A Mac that can confer the manager grant on a remotely started session says so in its
    /// catalogue; one that cannot gets no role to choose, rather than a request it would ignore.
    private var offersManager: Bool {
        catalog?.supportsManagerRole == true
    }

    private var selectedAgent: RemoteAgentChoiceDTO? {
        catalog?.agents.first { $0.id == agentID }
    }

    private var accounts: [RemoteAccountChoiceDTO] {
        selectedAgent?.accounts ?? []
    }

    private var selectedAccount: RemoteAccountChoiceDTO? {
        accounts.first { $0.id == accountID }
    }

    private var models: [RemoteModelChoiceDTO] {
        let resolved = selectedAccount?.models ?? selectedAgent?.models ?? []
#if DEBUG
        // The picker evidence state carries one bounded overflow page so the real shipping
        // popover proves both its no-scroll geometry and the pager's full-size touch targets.
        if ProcessInfo.processInfo.environment[MobileDemoScene.environmentKey]
            == "new-session-model-effort-picker" {
            return resolved + Self.pickerEvidenceOverflowModels
        }
#endif
        return resolved
    }

#if DEBUG
    private static let pickerEvidenceOverflowModels: [RemoteModelChoiceDTO] = [
        .init(
            id: "evidence-gpt-5.5",
            name: "GPT-5.5",
            reasoning: [
                .init(id: "low", name: "Light"),
                .init(id: "medium", name: "Medium"),
                .init(id: "high", name: "High"),
                .init(id: "xhigh", name: "Extra High"),
                .init(id: "max", name: "Max"),
                .init(id: "ultra", name: "Ultra"),
            ],
            defaultReasoningID: "high",
            supportsFastMode: true
        ),
        .init(
            id: "evidence-gpt-5.4",
            name: "GPT-5.4",
            reasoning: [
                .init(id: "low", name: "Light"),
                .init(id: "medium", name: "Medium"),
                .init(id: "high", name: "High"),
                .init(id: "xhigh", name: "Extra High"),
                .init(id: "max", name: "Max"),
            ],
            defaultReasoningID: "medium",
            supportsFastMode: true
        ),
        .init(
            id: "evidence-gpt-5.3",
            name: "GPT-5.3",
            reasoning: [
                .init(id: "low", name: "Light"),
                .init(id: "medium", name: "Medium"),
                .init(id: "high", name: "High"),
            ],
            defaultReasoningID: "medium",
            supportsFastMode: false
        ),
        .init(
            id: "evidence-gpt-5.2",
            name: "GPT-5.2",
            reasoning: [
                .init(id: "low", name: "Light"),
                .init(id: "medium", name: "Medium"),
                .init(id: "high", name: "High"),
            ],
            defaultReasoningID: "medium",
            supportsFastMode: false
        ),
    ]
#endif

    private var defaultModelID: String? {
        selectedAccount?.defaultModelID ?? selectedAgent?.defaultModelID
    }

    private var selectedModel: RemoteModelChoiceDTO? {
        let effectiveID = modelID.isEmpty ? defaultModelID : modelID
        return models.first { $0.id == effectiveID }
    }

    /// The disc's rings follow the model the draft will start, so picking Fable rings its window
    /// before the chat exists.
    private var selectedUsageReading: MobileAccountUsageReading? {
        MobileAccountUsageReading.resolve(
            account: selectedAccount,
            model: modelID.isEmpty ? defaultModelID : modelID
        )
    }

    private var hostStatusColor: Color {
        switch appModel.phase {
        case .online: return theme.positive
        case .connecting: return theme.warning
        case .idle, .offline: return theme.tertiaryLabel
        }
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { proxy in
            // The ground fills what the composer and the keyboard leave, so the hint centres in
            // the space that is actually empty and a drag anywhere on it reaches the keyboard.
            ScrollView {
                hint
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            composer
        }
        .background(theme.ground)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(theme.surface, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                MobileConnectionNavigationTitle(
                    title: MobileL10n.string("New session"),
                    status: appModel.activeHost?.name ?? MobileL10n.string("Connected"),
                    statusColor: hostStatusColor
                )
            }
            ToolbarItem(placement: .topBarTrailing) {
                identityMenu
            }
        }
        .onAppear {
            applyCatalogDefaults()
            hintAnimated = true
#if DEBUG
            if ProcessInfo.processInfo.environment[MobileDemoScene.environmentKey]
                == "new-session-multiline" {
                prompt = "Review the keyboard lifecycle, compare the open and dismissed layouts, and summarize any remaining spacing regressions before you make changes."
            }
            if ProcessInfo.processInfo.environment[MobileDemoScene.environmentKey]
                == "new-session-model-effort-picker" {
                if selectedModel?.reasoning.contains(where: { $0.id == "ultra" }) == true {
                    reasoningID = "ultra"
                }
                runPickerIsPresented = true
            }
            if ProcessInfo.processInfo.environment[MobileDemoScene.environmentKey]
                == "new-session-structured-error" {
                errorMessage = RemoteClientError.server(
                    status: 422,
                    code: RemoteRESTErrorCode.unknownModel.rawValue
                ).localizedDescription
            }
            if ProcessInfo.processInfo.environment[
                "THREADING_MOBILE_UI_EVIDENCE_KEYBOARD_STATE"
            ] == nil {
                promptIsFocused = true
            }
#else
            promptIsFocused = true
#endif
        }
        .onChange(of: agentID) { _, _ in
            applyAgentDefaults()
        }
        .onChange(of: accountID) { _, _ in
            applyAccountDefaults()
        }
        .onChange(of: modelID) { _, _ in
            applyModelDefaults()
        }
        .onChange(of: catalog) { _, _ in
            // Discovery and settings can change while this screen is open. Keep every still-valid
            // choice, but do not submit an identifier the current Mac catalogue has withdrawn.
            applyCatalogDefaults()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)
        ) { _ in
            keyboardIsLeaving = true
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)
        ) { _ in
            keyboardIsLeaving = false
        }
        .themedAlert(
            "Couldn’t start session",
            message: errorMessage ?? "",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            ),
            actions: [ThemedDialogAction("OK")]
        )
    }

    /// The middle of the ground: the surface's glyph, the project as a plain dropdown, and its
    /// branch. No plate and no tile — the glyph is a symbol in the tertiary ink, and the project
    /// is a line of text with a chevron, which is as quiet as a menu can be and still be found.
    private var hint: some View {
        VStack(spacing: MobileDesign.Spacing.small) {
            Image(systemName: hintSymbol)
                .font(.system(size: MobileDesign.Size.draftHintGlyph, weight: .light))
                .foregroundStyle(theme.tertiaryLabel)
                .symbolEffect(
                    .bounce,
                    options: .nonRepeating,
                    value: reduceMotion ? false : hintAnimated
                )
                .padding(.bottom, MobileDesign.Spacing.tight)
            // "Agent in AnotherTerminal": the role and the project as one sentence, each word a
            // menu. Two menus rather than one format string, so each stays its own control; the
            // joining word is the only piece that is not.
            HStack(spacing: MobileDesign.Spacing.small) {
                if offersManager {
                    roleMenu
                    Text("in")
                        .font(.subheadline)
                        .foregroundStyle(theme.secondaryLabel)
                }
                projectMenu
            }
            if let branch = selectedProject?.branch, !branch.isEmpty {
                Text(branch)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryLabel)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, MobileDesign.Spacing.pane)
    }

    /// A manager's glyph is the Mac's for the role; an agent's is its surface's.
    private var hintSymbol: String {
        switch role {
        case .manager: return "person.3"
        case .agent:
            return surface == .conversation ? "bubble.left.and.bubble.right" : "terminal"
        }
    }

    // MARK: - Composer

    /// Whether the action row is unfolded. Focus decides, because focus is what the evidence
    /// harness drives and what a tap on the prompt changes; the keyboard's own announcement
    /// only brings the fold forward to the moment the keyboard starts to go.
    private var showsChoices: Bool {
        promptIsFocused && !keyboardIsLeaving && !isSubmitting
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: MobileDesign.Spacing.small) {
                promptEditor
                sendButton
            }
            // Folded to nothing rather than removed: the chips are menus, and a menu that is
            // unmounted under a finger cannot finish what it was asked. Clipping keeps the
            // folded row from painting over the prompt's last line.
            choiceStrip
                .frame(height: showsChoices ? MobileDesign.Size.compactControl : 0)
                .padding(.top, showsChoices ? MobileDesign.Spacing.small : 0)
                .opacity(showsChoices ? 1 : 0)
                .clipped()
                .allowsHitTesting(showsChoices)
                .accessibilityHidden(!showsChoices)
        }
        .padding(.horizontal, MobileDesign.Spacing.composerHorizontal)
        .padding(.top, MobileDesign.Spacing.small)
        .padding(.bottom, MobileDesign.Spacing.small)
        .frame(maxWidth: .infinity)
        .background(theme.panel)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme.border)
                .frame(height: theme.borderWidth)
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: SessionDraftMotion.foldDuration),
            value: showsChoices
        )
    }

    /// The prompt shares its first line with Start, so the composer folded to that one line is
    /// still the whole composer. Top-aligned: a longer prompt grows down from a stable first
    /// row instead of carrying the button away with every line.
    private var promptEditor: some View {
        TextField(promptPlaceholder, text: $prompt, axis: .vertical)
            .focused($promptIsFocused)
            .mobileUIEvidenceKeyboardFocus($promptIsFocused)
            .textFieldStyle(.plain)
            .font(.body)
            .lineLimit(1...6)
            .frame(minHeight: MobileDesign.Size.compactControl)
            .disabled(isSubmitting)
    }

    /// The run settings — how the chat will run — as one compact, non-scrolling row. Where and
    /// who are not here: the project stands in the ground and the account in the bar.
    private var choiceStrip: some View {
        HStack(spacing: MobileDesign.Spacing.small) {
            runMenu
                .layoutPriority(1)
            if selectedModel?.supportsFastMode == true {
                speedMenu
            }
            Spacer(minLength: MobileDesign.Spacing.small)
            if !(selectedAgent?.permissionModes ?? []).isEmpty {
                permissionMenu
            }
            if selectedAgent?.supportsConversation == true {
                surfaceMenu
            }
        }
    }

    private var sendButton: some View {
        Button {
            submit()
        } label: {
            ZStack {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .opacity(isSubmitting ? 0 : 1)
                ProgressView()
                    .tint(theme.ground)
                    .opacity(isSubmitting ? 1 : 0)
            }
            .frame(
                width: MobileDesign.Size.compactControl,
                height: MobileDesign.Size.compactControl
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(canSubmit || isSubmitting ? theme.accentForeground : theme.tertiaryLabel)
        .background(
            canSubmit || isSubmitting ? theme.accent : theme.controlResting,
            in: Circle()
        )
        .disabled(!canSubmit)
        .accessibilityLabel(MobileL10n.string("Start session"))
    }

    /// A chat gets one of the task suggestions; a manager is briefed, not tasked.
    private var promptPlaceholder: String {
        role == .manager ? MobileL10n.string("Brief the manager…") : promptSuggestion
    }

    // MARK: - Choices

    private var projectMenu: some View {
        Menu {
            ForEach(catalog?.projects ?? []) { project in
                Button {
                    projectID = project.id
                } label: {
                    Label(
                        projectLabel(project),
                        systemImage: project.id == projectID ? "checkmark" : "folder"
                    )
                }
            }
        } label: {
            DraftMenuLabel(title: selectedProject?.name ?? MobileL10n.string("Project"))
        }
        // A menu's button keeps the width it was first measured at, so a label that changes
        // length — "Agent" to "Manager", one project to another — is clipped inside the old
        // frame. A fresh identity per value is a fresh button, measured for what it says.
        .id(projectID)
        .disabled(isSubmitting)
        .accessibilityLabel(MobileL10n.string("Project"))
        .accessibilityValue(selectedProject?.name ?? "")
    }

    private var roleMenu: some View {
        Menu {
            ForEach(SessionDraftRole.allCases, id: \.self) { candidate in
                Button {
                    role = candidate
                } label: {
                    Label(
                        candidate.title,
                        systemImage: candidate == role ? "checkmark" : candidate.symbol
                    )
                }
            }
        } label: {
            DraftMenuLabel(title: role.title)
        }
        .id(role)
        .disabled(isSubmitting)
        .accessibilityLabel(MobileL10n.string("Role"))
        .accessibilityValue(role.title)
    }

    private var identityMenu: some View {
        Menu {
            Section("Agent") {
                ForEach(catalog?.agents ?? []) { agent in
                    Button {
                        agentID = agent.id
                    } label: {
                        Label(
                            agent.name,
                            systemImage: agent.id == agentID ? "checkmark" : "sparkles"
                        )
                    }
                }
            }
            if !accounts.isEmpty {
                Section("Account · Usage") {
                    ForEach(accounts) { account in
                        Button {
                            accountID = account.id
                        } label: {
                            Label(
                                accountMenuTitle(account),
                                systemImage: account.id == accountID
                                    ? "checkmark"
                                    : "person.crop.circle"
                            )
                        }
                    }
                }
            }
        } label: {
            MobileAccountDisc(
                identity: .resolve(agentID),
                reading: selectedUsageReading
            )
        }
        .disabled(isSubmitting)
        .accessibilityLabel(MobileL10n.string("Agent"))
        .accessibilityValue(selectedIdentityAccessibilityValue)
    }

    private var surfaceMenu: some View {
        Menu {
            Button {
                surface = .conversation
            } label: {
                Label(
                    "Native (Experimental)",
                    systemImage: surface == .conversation
                        ? "checkmark"
                        : "bubble.left.and.bubble.right"
                )
            }
            Button {
                surface = .terminal
            } label: {
                Label(
                    originalUISurfaceTitle,
                    systemImage: surface == .terminal ? "checkmark" : "terminal"
                )
            }
        } label: {
            // The icon is the value: a terminal for the agent's own UI, a bubble for Native.
            DraftIconMenuLabel(
                symbol: surface == .conversation ? "bubble.left.and.bubble.right" : "terminal",
                isSet: surface == .conversation
            )
        }
        .disabled(isSubmitting)
        .accessibilityLabel(MobileL10n.string("Interface"))
        .accessibilityValue(selectedSurfaceTitle)
    }

    private var originalUISurfaceTitle: String {
        MobileL10n.string(
            "%@ UI",
            selectedAgent?.name ?? MobileL10n.string("Agent")
        )
    }

    private var selectedSurfaceTitle: String {
        surface == .conversation
            ? MobileL10n.string("Native · Experimental")
            : originalUISurfaceTitle
    }

    /// Model and effort keep one unchanged one-line trigger. Only its presented choice surface
    /// is custom: the popover shows the two as the relationship they actually are, while speed
    /// remains the simpler independent three-way choice beside it.
    private var runMenu: some View {
        Button {
            runPickerIsPresented = true
        } label: {
            DraftMenuLabel(symbol: "cpu", title: runSummary)
        }
        .buttonStyle(.plain)
        .id(runSummary)
        .disabled(models.isEmpty && selectedModel == nil)
        .accessibilityLabel(MobileL10n.string("Model and effort"))
        .accessibilityValue(runSummary)
        .popover(
            isPresented: $runPickerIsPresented,
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .bottom
        ) {
            MobileModelEffortPicker(
                models: models,
                defaultModelID: defaultModelID,
                selectedModelID: modelID,
                selectedEffortID: reasoningID,
                onChoose: { model, effort in
                    modelID = model ?? ""
                    reasoningID = effort ?? ""
                    runPickerIsPresented = false
                }
            )
            .mobileTheme(theme)
            .presentationBackground(theme.floatingSurface)
            .presentationCornerRadius(theme.panelRadius)
            .presentationCompactAdaptation(.popover)
        }
    }

    private var runSummary: String {
        SessionDraftRunSummary.text(
            model: selectedModel?.name,
            effort: selectedModel?.reasoning.first(where: { $0.id == reasoningID })?.name
        )
    }

    private var speedMenu: some View {
        Menu {
            Button {
                speedID = ""
            } label: {
                Label(
                    "Inherit",
                    systemImage: speedID.isEmpty ? "checkmark" : "arrow.triangle.branch"
                )
            }
            Button {
                speedID = "standard"
            } label: {
                Label(
                    "Standard",
                    systemImage: speedID == "standard" ? "checkmark" : "gauge.with.dots.needle.50percent"
                )
            }
            Button {
                speedID = "fast"
            } label: {
                Label(
                    "Fast",
                    systemImage: speedID == "fast" ? "checkmark" : "bolt.fill"
                )
            }
        } label: {
            DraftMenuLabel(
                symbol: selectedSpeedSymbol,
                title: selectedSpeedName,
                isSet: !speedID.isEmpty
            )
        }
        .id("speed-\(speedID)")
        .disabled(isSubmitting)
        .accessibilityLabel(MobileL10n.string("Speed"))
        .accessibilityValue(selectedSpeedName)
    }

    private var selectedSpeedName: String {
        switch speedID {
        case "fast": return MobileL10n.string("Fast")
        case "standard": return MobileL10n.string("Standard")
        default: return MobileL10n.string("Inherit")
        }
    }

    /// The bolt is the meaning of Fast, not of the speed control itself. Keep the trigger's
    /// glyph aligned with the value so an inherited or standard run never looks accelerated.
    private var selectedSpeedSymbol: String {
        switch speedID {
        case "fast": return "bolt.fill"
        case "standard": return "gauge.with.dots.needle.50percent"
        default: return "arrow.triangle.branch"
        }
    }

    private var permissionMenu: some View {
        Menu {
            Button {
                permissionID = ""
            } label: {
                Label("Inherit", systemImage: permissionID.isEmpty ? "checkmark" : "circle")
            }
            ForEach(selectedAgent?.permissionModes ?? []) { mode in
                Button {
                    permissionID = mode.id
                } label: {
                    Label(
                        mode.name,
                        systemImage: mode.id == permissionID ? "checkmark" : "hand.raised"
                    )
                }
            }
        } label: {
            DraftIconMenuLabel(symbol: "hand.raised", isSet: !permissionID.isEmpty)
        }
        .disabled(isSubmitting)
        .accessibilityLabel(MobileL10n.string("Permissions"))
        .accessibilityValue(selectedPermissionName)
    }

    private var selectedPermissionName: String {
        selectedAgent?.permissionModes?.first(where: { $0.id == permissionID })?.name
            ?? MobileL10n.string("Inherit")
    }

    private var selectedIdentityLabel: String {
        guard let selectedAgent else { return MobileL10n.string("Agent") }
        guard let selectedAccount else { return selectedAgent.name }
        return "\(selectedAgent.name) · \(selectedAccount.name)"
    }

    /// The chip carries the usage as a ring; VoiceOver gets the words the ring stands for.
    private var selectedIdentityAccessibilityValue: String {
        guard selectedAccount != nil else { return selectedIdentityLabel }
        guard let usage = selectedUsageReading?.summary else { return selectedIdentityLabel }
        return "\(selectedIdentityLabel), \(usage)"
    }

    private func accountMenuTitle(_ account: RemoteAccountChoiceDTO) -> String {
        let name = account.emoji.map { "\($0) \(account.name)" } ?? account.name
        if let usage = account.usageSummary { return "\(name)   \(usage)" }
        if account.usageError != nil {
            return MobileL10n.string("%@   Usage unavailable", name)
        }
        return MobileL10n.string("%@   Loading usage…", name)
    }

    private func projectLabel(_ project: RemoteProjectChoiceDTO) -> String {
        guard let branch = project.branch, !branch.isEmpty else { return project.name }
        return "\(project.name) · \(branch)"
    }

    // MARK: - Defaults

    private var canSubmit: Bool {
        !isSubmitting
            && !projectID.isEmpty
            && !agentID.isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func applyCatalogDefaults() {
        projectID = SessionDraftCatalogReconciliation.projectID(
            current: projectID,
            draftProjectName: draft.projectName,
            catalog: catalog
        )
        agentID = SessionDraftCatalogReconciliation.agentID(
            current: agentID,
            catalog: catalog
        )
        if role == .manager, !offersManager { role = .agent }
        applyAgentDefaults()
    }

    private func applyAgentDefaults() {
        guard let selectedAgent else { return }
        if !accounts.contains(where: { $0.id == accountID }) {
            accountID = accounts.first(where: { $0.id == "default" })?.id
                ?? accounts.first?.id
                ?? ""
        }
        if !selectedAgent.supportsConversation { surface = .terminal }
        if !(selectedAgent.permissionModes ?? []).contains(where: { $0.id == permissionID }) {
            permissionID = ""
        }
        applyAccountDefaults()
    }

    private func applyAccountDefaults() {
        if !models.contains(where: { $0.id == modelID }) {
            modelID = defaultModelID.flatMap { id in
                models.contains(where: { $0.id == id }) ? id : nil
            } ?? ""
        }
        applyModelDefaults()
    }

    private func applyModelDefaults() {
        guard let selectedModel else {
            reasoningID = ""
            speedID = ""
            return
        }
        if !selectedModel.reasoning.contains(where: { $0.id == reasoningID }) {
            reasoningID = selectedModel.defaultReasoningID.flatMap { id in
                selectedModel.reasoning.contains(where: { $0.id == id }) ? id : nil
            } ?? ""
        }
        if selectedModel.supportsFastMode != true { speedID = "" }
    }

    // MARK: - Start

    /// Start is the first half of the motion: the keyboard goes and the composer rides down
    /// with it, so by the time the Mac answers the screen is already the shape the chat will
    /// take. The second half — this screen becoming the session's — is `SessionDraftView`'s,
    /// triggered by the model learning which session the draft became.
    private func submit() {
        guard canSubmit else { return }
        isSubmitting = true
        promptIsFocused = false
        Task {
            do {
                let creation = try await appModel.createSession(
                    projectID: projectID,
                    agentKind: agentID,
                    accountHandle: accountID.isEmpty ? nil : accountID,
                    model: modelID.isEmpty ? nil : modelID,
                    reasoningEffort: reasoningID.isEmpty ? nil : reasoningID,
                    fastMode: speedID == "fast" ? true : (speedID == "standard" ? false : nil),
                    permissionMode: permissionID.isEmpty ? nil : permissionID,
                    surface: surface,
                    role: role.wireValue,
                    prompt: prompt
                )
                // Turns this screen into the session's: `SessionDraftView` fades this one
                // out over the chat the model now says the draft became.
                appModel.noteDraftStarted(draft, creation: creation)
            } catch is CancellationError {
                isSubmitting = false
            } catch {
                MobileDiagnostics.logDegraded(.sessionAction, error: error)
                isSubmitting = false
                errorMessage = error.localizedDescription
                if let remote = error as? RemoteClientError,
                   remote.requiresLaunchCatalogRefresh {
                    // The refusal is authoritative, while this draft's catalogue may be an old
                    // snapshot. Refresh behind the alert and reconcile only invalid selections;
                    // the prompt and every still-valid choice remain untouched.
                    await appModel.refresh()
                    applyCatalogDefaults()
                }
            }
        }
    }
}

/// Pure catalogue repair for an already-mounted draft. Selection state lives in SwiftUI, but
/// the rule is transport-facing: preserve a value while the current Mac still advertises it and
/// choose a deterministic fallback once it does not.
enum SessionDraftCatalogReconciliation {
    static func projectID(
        current: String,
        draftProjectName: String?,
        catalog: RemoteNewSessionCatalogDTO?
    ) -> String {
        guard catalog?.projects.contains(where: { $0.id == current }) != true else {
            return current
        }
        return draftProjectName.flatMap { name in
            catalog?.projects.first {
                $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
            }?.id
        } ?? catalog?.projects.first?.id ?? ""
    }

    static func agentID(
        current: String,
        catalog: RemoteNewSessionCatalogDTO?
    ) -> String {
        guard catalog?.agents.contains(where: { $0.id == current }) != true else {
            return current
        }
        return catalog?.agents.first(where: { $0.id == "codex" })?.id
            ?? catalog?.agents.first?.id
            ?? ""
    }
}

/// What the draft will start: an agent on a task, or a manager coordinating the project.
///
/// A manager is the Mac's role, not a runtime: the same session with its project's control
/// grant. The phone only names it; `RemoteSessionRole` carries the word and the Mac confers
/// the authority.
enum SessionDraftRole: CaseIterable {
    case agent
    case manager

    var title: String {
        switch self {
        case .agent: return MobileL10n.string("Agent")
        case .manager: return MobileL10n.string("Manager")
        }
    }

    /// The Mac's own glyph for each role, as its composer's role chip draws them.
    var symbol: String {
        switch self {
        case .agent: return "bubble.left"
        case .manager: return "person.3"
        }
    }

    /// Nil for an agent: a chat is what an older Mac starts for a request with no role, and
    /// what every request meant before the field existed.
    var wireValue: RemoteSessionRole? {
        switch self {
        case .agent: return nil
        case .manager: return RemoteSessionRole.manager
        }
    }
}

/// The run menu's one line: the model, then only the choices that depart from its defaults.
enum SessionDraftRunSummary {
    static let separator = " · "

    /// `model` nil is the catalogue's default model and `effort` nil means inherited, which the
    /// line leaves unsaid — "GPT-5.6 Sol" says more than "GPT-5.6 Sol · Default". Speed owns
    /// the neighbouring control instead of making this relationship read as a three-axis grid.
    static func text(model: String?, effort: String?) -> String {
        [model ?? MobileL10n.string("Default model"), effort]
            .compactMap { $0 }
            .joined(separator: separator)
    }
}

/// A menu that is a line of text: an optional glyph, the chosen value, a chevron. No plate —
/// the project in the middle of the ground and the run settings in the composer are the same
/// kind of control and read as the same kind of thing. An explicit, non-inherited choice
/// promotes only its value glyph to the accent; otherwise the glyph stays secondary.
private struct DraftMenuLabel: View {
    @Environment(\.remoteTheme) private var theme
    var symbol: String? = nil
    let title: String
    var isSet = false

    var body: some View {
        HStack(spacing: MobileDesign.Spacing.tight) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.caption)
                    .foregroundStyle(isSet ? theme.accent : theme.secondaryLabel)
            }
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(theme.label)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: MobileDesign.Size.chipChevron, weight: .semibold))
                .foregroundStyle(theme.tertiaryLabel)
        }
        // The toolbar control's height rather than the full 44: in the ground the branch sits
        // under this line, and a taller hit area pushed it off the name it belongs to.
        .frame(minHeight: MobileDesign.Size.compactControl)
        .contentShape(Rectangle())
    }
}

/// A menu that is one glyph, for the choices almost always left alone — permissions, the
/// interface. The glyph takes the accent when the choice departs from the default, so a row
/// of quiet icons still says which one has been touched.
private struct DraftIconMenuLabel: View {
    @Environment(\.remoteTheme) private var theme
    let symbol: String
    let isSet: Bool

    var body: some View {
        Image(systemName: symbol)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(isSet ? theme.accent : theme.secondaryLabel)
            .frame(
                width: MobileDesign.Size.compactControl,
                height: MobileDesign.Size.compactControl
            )
            .contentShape(Rectangle())
    }
}
