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

    private var startedSessionID: String? {
        model.startedDrafts[draft.id]
    }

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
                SessionDetailView(session: startedSession)
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

/// The draft before Start: an empty ground and one composer.
///
/// Everything that used to stand on the ground as a box — the project and identity capsules,
/// the icon plate, the two-by-two grid of run settings — is a chip in the composer's own
/// action row now, under the prompt. The composer is the screen's one surface: full-bleed,
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
    @State private var prompt = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var hintAnimated = false
    @State private var promptSuggestion: String
    /// Set the moment the keyboard announces it is leaving. Focus ends only once it has gone,
    /// and a row folding then is a second motion after the first; folding on the announcement
    /// lets the row fold as the keyboard drops.
    @State private var keyboardIsLeaving = false
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
        selectedAccount?.models ?? selectedAgent?.models ?? []
    }

    private var selectedModel: RemoteModelChoiceDTO? {
        models.first { $0.id == modelID }
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
        }
        .onAppear {
            applyCatalogDefaults()
            hintAnimated = true
#if DEBUG
            if ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]
                == "new-session-multiline" {
                prompt = "Review the keyboard lifecycle, compare the open and dismissed layouts, and summarize any remaining spacing regressions before you make changes."
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

    /// What the empty ground says. No plate, no tile: a glyph for the surface being started
    /// and one line, gone as soon as there is a prompt to read instead.
    private var hint: some View {
        VStack(spacing: MobileDesign.Spacing.medium) {
            Image(systemName: surface == .conversation
                ? "bubble.left.and.bubble.right"
                : "terminal")
                .font(.system(size: MobileDesign.Size.draftHintGlyph, weight: .light))
                .foregroundStyle(theme.tertiaryLabel)
                .symbolEffect(
                    .bounce,
                    options: .nonRepeating,
                    value: reduceMotion ? false : hintAnimated
                )
            Text("Ready for a new task")
                .font(.subheadline)
                .foregroundStyle(theme.secondaryLabel)
        }
        .opacity(prompt.isEmpty ? 1 : 0)
        .animation(
            reduceMotion ? nil : .easeOut(duration: SessionDraftMotion.hintDuration),
            value: prompt.isEmpty
        )
        .accessibilityElement(children: .combine)
        .accessibilityHidden(!prompt.isEmpty)
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
        TextField(promptSuggestion, text: $prompt, axis: .vertical)
            .focused($promptIsFocused)
            .mobileUIEvidenceKeyboardFocus($promptIsFocused)
            .textFieldStyle(.plain)
            .font(.body)
            .lineLimit(1...6)
            .frame(minHeight: MobileDesign.Size.compactControl)
            .disabled(isSubmitting)
    }

    /// Every choice that used to be a box on the ground, as one row of chips that scrolls.
    /// Ordered by how often each is changed: where, who, then how.
    private var choiceStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: MobileDesign.Spacing.small) {
                projectMenu
                identityMenu
                modelMenu
                reasoningMenu
                if selectedModel?.supportsFastMode == true {
                    speedMenu
                }
                if !(selectedAgent?.permissionModes ?? []).isEmpty {
                    permissionMenu
                }
                if selectedAgent?.supportsConversation == true {
                    surfaceMenu
                }
            }
        }
        .mask {
            // The row runs off the trailing edge; fading its last points says so.
            HStack(spacing: 0) {
                Rectangle()
                LinearGradient(
                    colors: [.black, .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: MobileDesign.Spacing.large)
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
        .accessibilityLabel("Start session")
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
            DraftChoiceChip(
                symbol: "folder",
                title: selectedProject?.name ?? MobileL10n.string("Project")
            )
        }
        .accessibilityLabel("Project")
        .accessibilityValue(selectedProject?.name ?? "")
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
            DraftChoiceChip(symbol: "sparkles", title: selectedIdentityLabel) {
                if let fraction = selectedAccount?.usageFraction {
                    UsageProgressRing(fraction: fraction, tint: usageTint(for: fraction))
                }
            }
        }
        .accessibilityLabel("Agent")
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
            DraftChoiceChip(
                symbol: surface == .conversation
                    ? "bubble.left.and.bubble.right"
                    : "terminal",
                title: selectedSurfaceTitle
            )
        }
        .accessibilityLabel("Interface")
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

    private var modelMenu: some View {
        Menu {
            if !models.isEmpty {
                Section("Model") {
                    Button {
                        modelID = ""
                    } label: {
                        Label(
                            "Default",
                            systemImage: modelID.isEmpty ? "checkmark" : "circle"
                        )
                    }
                    ForEach(models) { model in
                        Button {
                            modelID = model.id
                        } label: {
                            Label(
                                model.name,
                                systemImage: model.id == modelID ? "checkmark" : "cpu"
                            )
                        }
                    }
                }
            }
        } label: {
            DraftChoiceChip(
                symbol: "cpu",
                title: selectedModel?.name ?? MobileL10n.string("Default")
            )
        }
        .disabled(models.isEmpty)
        .accessibilityLabel("Model")
        .accessibilityValue(selectedModel?.name ?? MobileL10n.string("Default"))
    }

    private var reasoningMenu: some View {
        Menu {
            Button {
                reasoningID = ""
            } label: {
                Label("Default", systemImage: reasoningID.isEmpty ? "checkmark" : "circle")
            }
            ForEach(selectedModel?.reasoning ?? []) { effort in
                Button {
                    reasoningID = effort.id
                } label: {
                    Label(
                        effort.name,
                        systemImage: effort.id == reasoningID
                            ? "checkmark"
                            : "brain.head.profile"
                    )
                }
            }
        } label: {
            DraftChoiceChip(symbol: "brain.head.profile", title: selectedReasoningName)
        }
        .disabled(selectedModel?.reasoning.isEmpty != false)
        .accessibilityLabel("Effort")
        .accessibilityValue(selectedReasoningName)
    }

    private var selectedReasoningName: String {
        selectedModel?.reasoning.first(where: { $0.id == reasoningID })?.name
            ?? MobileL10n.string("Default")
    }

    private var speedMenu: some View {
        Menu {
            Button {
                speedID = ""
            } label: {
                Label("Inherit", systemImage: speedID.isEmpty ? "checkmark" : "circle")
            }
            Button {
                speedID = "standard"
            } label: {
                Label("Standard", systemImage: speedID == "standard" ? "checkmark" : "gauge")
            }
            Button {
                speedID = "fast"
            } label: {
                Label("Fast", systemImage: speedID == "fast" ? "checkmark" : "bolt.fill")
            }
        } label: {
            // The bolt belongs to Fast, not to the control: the menu above already draws it on
            // that one row and a dial on Standard, and a chip wearing it whatever is chosen
            // says Fast while the value beside it says otherwise.
            DraftChoiceChip(
                symbol: speedID == "fast" ? "bolt.fill" : "gauge",
                title: selectedSpeedName
            )
        }
        .accessibilityLabel("Speed")
        .accessibilityValue(selectedSpeedName)
    }

    private var selectedSpeedName: String {
        switch speedID {
        case "fast": return MobileL10n.string("Fast")
        case "standard": return MobileL10n.string("Standard")
        default: return MobileL10n.string("Inherit")
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
            DraftChoiceChip(symbol: "hand.raised", title: selectedPermissionName)
        }
        .accessibilityLabel("Permissions")
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
        guard let selectedAccount else { return selectedIdentityLabel }
        guard let usage = selectedAccount.usageSummary else { return selectedIdentityLabel }
        return "\(selectedIdentityLabel), \(usage)"
    }

    private func usageTint(for fraction: Double) -> Color {
        if fraction >= 0.9 { return theme.negative }
        if fraction >= 0.75 { return theme.warning }
        return theme.positive
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
        if projectID.isEmpty {
            projectID = draft.projectName.flatMap { name in
                catalog?.projects.first {
                    $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
                }?.id
            } ?? catalog?.projects.first?.id ?? ""
        }
        if agentID.isEmpty {
            agentID = catalog?.agents.first(where: { $0.id == "codex" })?.id
                ?? catalog?.agents.first?.id
                ?? ""
        }
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
        let defaultModelID = selectedAccount?.defaultModelID ?? selectedAgent?.defaultModelID
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
                let session = try await appModel.createSession(
                    projectID: projectID,
                    agentKind: agentID,
                    accountHandle: accountID.isEmpty ? nil : accountID,
                    model: modelID.isEmpty ? nil : modelID,
                    reasoningEffort: reasoningID.isEmpty ? nil : reasoningID,
                    fastMode: speedID == "fast" ? true : (speedID == "standard" ? false : nil),
                    permissionMode: permissionID.isEmpty ? nil : permissionID,
                    surface: surface,
                    prompt: prompt
                )
                // Turns this screen into the session's: `SessionDraftView` fades this one
                // out over the chat the model now says the draft became.
                appModel.noteDraftStarted(draft, session: session)
            } catch is CancellationError {
                isSubmitting = false
            } catch {
                MobileDiagnostics.logDegraded(.sessionAction, error: error)
                isSubmitting = false
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// One choice in the composer's action row: a glyph, the chosen value, a chevron. Quiet on
/// purpose — the row holds up to seven of these and the prompt above them is the point.
private struct DraftChoiceChip<Accessory: View>: View {
    @Environment(\.remoteTheme) private var theme
    let symbol: String
    let title: String
    @ViewBuilder let accessory: () -> Accessory

    init(
        symbol: String,
        title: String,
        @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }
    ) {
        self.symbol = symbol
        self.title = title
        self.accessory = accessory
    }

    var body: some View {
        HStack(spacing: MobileDesign.Spacing.tight) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(theme.accent)
            Text(title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            accessory()
            Image(systemName: "chevron.down")
                .font(.system(size: MobileDesign.Size.chipChevron, weight: .semibold))
                .foregroundStyle(theme.tertiaryLabel)
        }
        .foregroundStyle(theme.label)
        .padding(.horizontal, MobileDesign.Spacing.medium)
        .frame(height: MobileDesign.Size.compactControl)
        .background(theme.controlResting, in: Capsule())
        .contentShape(Capsule())
    }
}

private struct UsageProgressRing: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.2), lineWidth: MobileDesign.Size.badgeStroke)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(
                    tint,
                    style: StrokeStyle(lineWidth: MobileDesign.Size.badgeStroke, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .frame(width: MobileDesign.Size.usageRing, height: MobileDesign.Size.usageRing)
    }
}
