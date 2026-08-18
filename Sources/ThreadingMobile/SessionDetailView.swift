import ThreadingRemoteKit
import SwiftUI
import UIKit

/// What the session screen's single trailing menu contains, and therefore whether it is shown.
///
/// Workspace, the terminal palette and the session actions were three separate toolbar buttons.
/// They are gathered under one control now, which means each of the three permissions that used
/// to reveal its own button has to keep revealing its entry — a share that may recolour a
/// terminal but not manage the session still needs the menu to appear.
enum MobileSessionChrome {
    static func canOpenWorkspace(canManageSessions: Bool, hasClient: Bool) -> Bool {
        canManageSessions && hasClient
    }

    /// A palette belongs to a terminal. A native conversation is drawn in the app theme, so the
    /// entry is absent there rather than present and inert.
    static func canChooseTerminalTheme(
        canManageThemes: Bool,
        surface: RemoteSessionSurface,
        hasThemeCatalog: Bool
    ) -> Bool {
        canManageThemes && surface == .terminal && hasThemeCatalog
    }

    static func showsSessionMenu(canManageSessions: Bool, canChooseTerminalTheme: Bool) -> Bool {
        canManageSessions || canChooseTerminalTheme
    }
}

struct SessionDetailView: View {
    @EnvironmentObject private var model: RemoteAppModel
    @Environment(\.remoteTheme) private var theme
    let session: RemoteSessionSummaryDTO
    @StateObject private var workspaceActivity: MobileWorkspaceActivity
    @State private var connection: RemoteSessionConnection?
    @State private var launchError: String?
    @State private var themeError: String?
    @State private var isChangingTheme = false
    @State private var renameText = ""
    @State private var isRenaming = false
    @State private var sessionActionError: String?
    @State private var isMutatingSession = false
    @State private var isConfirmingSurfaceSwitch = false
    @State private var pendingSurface = RemoteSessionSurface.terminal
    @State private var isShowingWorkspace = false
    @State private var initialWorkspaceDestination: RemoteNotificationDestinationDTO?
    @State private var initialWorkspaceEventID: String?
    @Environment(\.dismiss) private var dismiss

    private var currentSession: RemoteSessionSummaryDTO {
        model.me?.sessions.first(where: { $0.id == session.id }) ?? session
    }

    init(session: RemoteSessionSummaryDTO) {
        self.session = session
        _workspaceActivity = StateObject(wrappedValue: MobileWorkspaceActivity(
            sessionID: session.id
        ))
    }

    var body: some View {
        Group {
            if let connection {
                if connection.surface == .conversation {
                    ConversationRemoteView(connection: connection)
                } else {
                    TerminalRemoteView(connection: connection)
                }
            } else if let launchError {
                ContentUnavailableView {
                    Label("Couldn’t open session", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(launchError)
                } actions: {
                    Button("Try Again") {
                        self.launchError = nil
                        Task { await open() }
                    }
                }
            } else {
                VStack(spacing: 14) {
                    ProgressView()
                    Text(MobileL10n.string(
                        session.isAvailable ? "Connecting…" : "Resuming on your Mac…"
                    ))
                        .foregroundStyle(theme.secondaryLabel)
                }
            }
        }
        .navigationTitle(connection?.title ?? currentSession.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsSessionMenu {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        sessionMenuContent
                    } label: {
                        SessionActionsToolbarIcon(activity: workspaceActivity)
                    }
                    .accessibilityLabel(
                        MobileL10n.string(
                            workspaceActivity.hasUnseenBrowser
                                ? "Session actions, new browser activity"
                                : "Session actions"
                        )
                    )
                }
            }
        }
        .onScreenEdgeSwipe(from: .right, perform: openWorkspace)
        .toolbarBackground(theme.surface, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .background(theme.ground)
        .sheet(isPresented: $isShowingWorkspace, onDismiss: {
            initialWorkspaceDestination = nil
            initialWorkspaceEventID = nil
        }) {
            if let client = model.client {
                SessionWorkspaceView(
                    session: currentSession,
                    client: client,
                    activity: workspaceActivity,
                    initialDestination: initialWorkspaceDestination
                )
                // A second milestone may be opened while Workspace is already presented. Give
                // each notification its own navigation identity so that tap replaces the old
                // stack with the newly requested attachment or live surface.
                .id(initialWorkspaceEventID ?? "manual-workspace")
                .mobileTheme(theme)
                .presentationDetents([.fraction(0.72), .large])
                .presentationDragIndicator(.visible)
            }
        }
        .task {
            await open()
            openPendingNotificationDestination()
        }
        .onChange(of: model.notificationOpenRequest?.eventID) { _, _ in
            openPendingNotificationDestination()
        }
        .onDisappear {
            connection?.disconnect(markEnded: false)
        }
        .onChange(of: currentSession.surface) { _, newSurface in
            // A surface switch made on the Mac (or another paired phone) arrives through the
            // dashboard event socket. Reattach this detail view to the replacement live surface
            // instead of leaving it on the ended socket until the next polling interval.
            guard !isMutatingSession,
                  let activeConnection = connection,
                  activeConnection.surface != newSurface else { return }
            activeConnection.disconnect(markEnded: false)
            connection = nil
            Task { await open() }
        }
        .themedAlert(
            "Couldn’t change terminal theme",
            message: themeError ?? "",
            isPresented: Binding(
                get: { themeError != nil },
                set: { if !$0 { themeError = nil } }
            ),
            actions: [ThemedDialogAction("OK")]
        )
        .themedAlert(
            "Rename session",
            message: "This name is shared with the Mac.",
            isPresented: $isRenaming,
            textField: ThemedDialogTextField("Session name", text: $renameText),
            actions: [
                ThemedDialogAction("Cancel", role: .cancel),
                ThemedDialogAction("Rename") {
                    mutate {
                        try await model.renameSession(currentSession, to: renameText)
                    }
                },
            ]
        )
        .themedConfirmationDialog(
            MobileL10n.string("Switch to %@?", surfaceTitle(pendingSurface)),
            message:
                "The agent restarts in the other UI and resumes this same session. "
                + "Work currently in progress is interrupted.",
            isPresented: $isConfirmingSurfaceSwitch,
            actions: [
                ThemedDialogAction("Switch UI", systemImage: "rectangle.2.swap") {
                    switchSurface(to: pendingSurface)
                },
                ThemedDialogAction("Cancel", role: .cancel),
            ]
        )
        .themedAlert(
            "Remote action failed",
            message: sessionActionError ?? "",
            isPresented: Binding(
                get: { sessionActionError != nil },
                set: { if !$0 { sessionActionError = nil } }
            ),
            actions: [ThemedDialogAction("OK")]
        )
    }

    /// Everything the session's own chrome can do, gathered under the one trailing control.
    ///
    /// Workspace and the terminal palette used to sit beside it as separate toolbar buttons.
    /// Three glyphs plus a back button left the title a truncated stub on a phone, and neither
    /// of the two is reached often enough to spend a permanent slot on.
    @ViewBuilder
    private var sessionMenuContent: some View {
        if canOpenWorkspace {
            Button(action: openWorkspace) {
                Label("Workspace", systemImage: "square.grid.2x2")
            }
            Divider()
        }
        if model.canManageSessions {
            Group {
                Button {
                    mutate {
                        try await model.setPinned(!currentSession.isPinned, for: currentSession)
                    }
                } label: {
                    Label(
                        MobileL10n.string(currentSession.isPinned ? "Unpin" : "Pin"),
                        systemImage: currentSession.isPinned ? "pin.slash" : "pin"
                    )
                }
                Button {
                    renameText = currentSession.title
                    isRenaming = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                if currentSession.isSnoozed() {
                    Button {
                        mutate {
                            try await model.setSnoozed(until: nil, for: currentSession)
                        }
                    } label: {
                        Label("Unsnooze", systemImage: "sun.max")
                    }
                } else {
                    Menu {
                        ForEach(MobileSnoozePresets.choices()) { choice in
                            Button(choice.title) {
                                mutate {
                                    try await model.setSnoozed(
                                        until: choice.deadline,
                                        for: currentSession
                                    )
                                }
                            }
                        }
                    } label: {
                        Label("Snooze", systemImage: "moon.zzz")
                    }
                }
                Section("Interface") {
                    Button {
                        confirmSurfaceSwitch(to: .conversation)
                    } label: {
                        Label(
                            "Native",
                            systemImage: currentSession.surface == .conversation
                                ? "checkmark"
                                : "bubble.left.and.bubble.right"
                        )
                    }
                    .accessibilityLabel("Native, experimental")
                    Button {
                        confirmSurfaceSwitch(to: .terminal)
                    } label: {
                        Label(
                            originalUISurfaceTitle,
                            systemImage: currentSession.surface == .terminal
                                ? "checkmark"
                                : "terminal"
                        )
                    }
                }
            }
            .disabled(isMutatingSession)
        }
        if let catalog = model.me?.themeCatalog, canChooseTerminalTheme {
            terminalThemeMenu(catalog)
        }
        if model.canManageSessions {
            Button(role: .destructive) {
                mutate(dismissAfterward: true) {
                    try await model.setArchived(true, for: currentSession)
                }
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .disabled(isMutatingSession)
        }
    }

    private func terminalThemeMenu(_ catalog: RemoteThemeCatalogDTO) -> some View {
        Menu {
            Button {
                chooseTerminalTheme(nil)
            } label: {
                let label = MobileL10n.string(
                    "Inherit (%@)",
                    currentSession.inheritedTerminalThemeName ?? MobileL10n.string("Default")
                )
                if currentSession.terminalThemeAssignmentID == nil {
                    Label(label, systemImage: "checkmark")
                } else {
                    Text(label)
                }
            }
            Divider()
            ForEach(catalog.terminalThemes, id: \.id) { option in
                Button {
                    chooseTerminalTheme(option.id)
                } label: {
                    if currentSession.terminalThemeAssignmentID == option.id {
                        Label(option.name, systemImage: "checkmark")
                    } else {
                        Text(option.name)
                    }
                }
            }
        } label: {
            Label("Terminal theme", systemImage: "paintpalette")
        }
        .disabled(isChangingTheme)
    }

    private var showsSessionMenu: Bool {
        MobileSessionChrome.showsSessionMenu(
            canManageSessions: model.canManageSessions,
            canChooseTerminalTheme: canChooseTerminalTheme
        )
    }

    private var canOpenWorkspace: Bool {
        MobileSessionChrome.canOpenWorkspace(
            canManageSessions: model.canManageSessions,
            hasClient: model.client != nil
        )
    }

    private var canChooseTerminalTheme: Bool {
        MobileSessionChrome.canChooseTerminalTheme(
            canManageThemes: model.canManageThemes,
            surface: currentSession.surface,
            hasThemeCatalog: model.me?.themeCatalog != nil
        )
    }

    private func openWorkspace() {
        guard canOpenWorkspace else { return }
        initialWorkspaceDestination = nil
        initialWorkspaceEventID = nil
        isShowingWorkspace = true
    }

    private func openPendingNotificationDestination() {
        guard let request = model.notificationOpenRequest,
              request.sessionID == session.id else { return }
        if request.destination.kind != .session {
            // Keep the request pending until the authenticated client exists. Consuming it while
            // the sheet's `if let client` branch is empty would turn a cold-launch notification
            // into a blank sheet and lose the destination before refresh can finish.
            guard model.client != nil else { return }
            initialWorkspaceDestination = request.destination
            initialWorkspaceEventID = request.eventID
            isShowingWorkspace = true
        }
        model.consumeNotificationOpenRequest(eventID: request.eventID)
    }

    private func open() async {
        do {
            // A UI switch deliberately tears down the old process. Always ask readiness from
            // the newest catalogue row rather than the immutable navigation value, which may
            // still say that the pre-switch surface was available.
            let latest = model.me?.sessions.first(where: { $0.id == session.id }) ?? session
            try await model.makeSessionReady(latest)
            guard let client = model.client else {
                throw RemoteClientError.invalidResponse
            }
            let current = model.me?.sessions.first(where: { $0.id == session.id }) ?? session
            let made = RemoteSessionConnection(
                session: current,
                client: client,
                reconnectClient: {
                    await model.refresh()
                    return model.client
                }
            )
            made.onWorkspaceChanged = { [weak workspaceActivity] event in
                workspaceActivity?.receive(event)
            }
            connection = made
            made.connect()
        } catch is CancellationError {
            return
        } catch {
            MobileDiagnostics.logDegraded(.sessionAction, error: error)
            launchError = error.localizedDescription
        }
    }

    private func chooseTerminalTheme(_ id: String?) {
        guard !isChangingTheme else { return }
        isChangingTheme = true
        let previous = connection?.terminalTheme
        let preview = id.flatMap { selectedID in
            model.me?.themeCatalog?.terminalThemes.first(where: { $0.id == selectedID })
        } ?? (id == nil ? currentSession.inheritedTerminalTheme : nil)
        if let preview {
            connection?.previewTerminalTheme(preview)
        }

        Task {
            defer { isChangingTheme = false }
            do {
                try await model.selectTerminalTheme(sessionID: session.id, themeID: id)
            } catch is CancellationError {
                return
            } catch {
                MobileDiagnostics.logDegraded(.themeSelection, error: error)
                connection?.previewTerminalTheme(previous)
                themeError = error.localizedDescription
            }
        }
    }

    private var originalUISurfaceTitle: String {
        MobileAgentIdentity.resolve(currentSession.agentKind).originalUITitle
    }

    private func surfaceTitle(_ surface: RemoteSessionSurface) -> String {
        surface == .conversation
            ? MobileL10n.string("Native (Experimental)")
            : originalUISurfaceTitle
    }

    private func confirmSurfaceSwitch(to surface: RemoteSessionSurface) {
        guard surface != currentSession.surface else { return }
        pendingSurface = surface
        isConfirmingSurfaceSwitch = true
    }

    private func switchSurface(to surface: RemoteSessionSurface) {
        guard !isMutatingSession else { return }
        isMutatingSession = true
        connection?.disconnect(markEnded: false)
        connection = nil

        Task {
            defer { isMutatingSession = false }
            do {
                try await model.setSurface(surface, for: currentSession)
                launchError = nil
                await open()
            } catch is CancellationError {
                return
            } catch {
                MobileDiagnostics.logDegraded(.sessionAction, error: error)
                sessionActionError = error.localizedDescription
                await open()
            }
        }
    }

    private func mutate(
        dismissAfterward: Bool = false,
        operation: @escaping @MainActor () async throws -> Void
    ) {
        guard !isMutatingSession else { return }
        isMutatingSession = true
        Task {
            defer { isMutatingSession = false }
            do {
                try await operation()
                if dismissAfterward {
                    connection?.disconnect(markEnded: false)
                    dismiss()
                }
            } catch is CancellationError {
                return
            } catch {
                MobileDiagnostics.logDegraded(.sessionAction, error: error)
                sessionActionError = error.localizedDescription
            }
        }
    }
}

/// The session's one trailing toolbar control.
///
/// It carries the workspace's unseen-browser dot, because Workspace now lives inside the menu
/// this opens: a milestone the phone was not watching still has to be visible from the outside.
private struct SessionActionsToolbarIcon: View {
    @ObservedObject var activity: MobileWorkspaceActivity

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        symbol
            .overlay(alignment: .topTrailing) {
                if activity.hasUnseenBrowser {
                    Circle()
                        .fill(theme.accent)
                        .frame(
                            width: MobileDesign.Size.workspaceActivityDot,
                            height: MobileDesign.Size.workspaceActivityDot
                        )
                        .overlay {
                            Circle()
                                .stroke(theme.surface, lineWidth: MobileDesign.Size.badgeStroke)
                        }
                        .offset(
                            x: MobileDesign.Offset.workspaceActivityDot,
                            y: -MobileDesign.Offset.workspaceActivityDot
                        )
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(
                reduceMotion ? .easeOut(duration: 0.15) : .snappy(duration: 0.32),
                value: activity.hasUnseenBrowser
            )
    }

    @ViewBuilder
    private var symbol: some View {
        let image = Image(systemName: "ellipsis")
        if reduceMotion {
            image
        } else {
            image.symbolEffect(
                .pulse,
                options: .nonRepeating,
                value: activity.latestBrowserActivityID
            )
        }
    }
}

private struct RemoteNavigationTitle: View {
    @ObservedObject var connection: RemoteSessionConnection
    @EnvironmentObject private var model: RemoteAppModel
    @Environment(\.remoteTheme) private var theme
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let failure = connection.phase.failure {
            Button {
                recover(from: failure)
            } label: {
                title
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text(failure.recoveryTitle))
        } else {
            title
        }
    }

    /// The failure states that cannot be retried away get the step that actually fixes them,
    /// in the place the person is already looking. Re-scanning a dead address is one tap from
    /// the title that reported it, and so is the Local Network switch.
    private func recover(from failure: RemoteConnectionFailure) {
        switch failure.recovery {
        case .reconnect:
            connection.connect()
        case .pairAgain:
            model.isPairing = true
        case .openLocalNetworkSettings:
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            openURL(url)
        }
    }

    private var title: some View {
        MobileConnectionNavigationTitle(
            title: connection.title,
            status: label,
            statusColor: color
        )
    }

    private var color: Color {
        switch connection.phase {
        case .connected: return theme.positive
        case .connecting: return theme.warning
        case .ended, .failed: return theme.tertiaryLabel
        }
    }

    private var label: String {
        switch connection.phase {
        case .connecting: return MobileL10n.string("Connecting to Mac…")
        case .connected:
            return model.activeHost?.name ?? MobileL10n.string("Connected")
        case .ended(let reason): return reason
        case .failed(let failure): return failure.message
        }
    }
}

struct TerminalRemoteView: View {
    @ObservedObject var connection: RemoteSessionConnection
    @EnvironmentObject private var model: RemoteAppModel
    @EnvironmentObject private var continuity: MobileSessionContinuityStore
    @EnvironmentObject private var keyboards: MobileTerminalKeyboardStore
    @EnvironmentObject private var notifications: RemoteNotificationManager
    @Environment(\.remoteTheme) private var inheritedTheme
    @State private var showsAttentionRequest = false
    @State private var showsKeyboardEditor = false
    @StateObject private var keyBridge = TerminalKeyBridge()

    private var theme: RemoteThemePalette {
        connection.theme.map(RemoteThemePalette.init) ?? inheritedTheme
    }

    private var terminalBackground: Color {
        guard let hex = connection.terminalTheme?.background,
              let color = UIColor(remoteHex: hex) else {
            return theme.ground
        }
        return Color(color)
    }

    private var inputMode: MobileTerminalInputMode {
        connection.terminalInputMode(
            settingEnabled: notifications.independentTerminalDraftsEnabled
        )
    }

    private var usesIndependentComposer: Bool { inputMode == .independentComposer }

    private var allowsDirectInput: Bool { inputMode == .direct }

    var body: some View {
        VStack(spacing: 0) {
            TerminalViewRepresentable(
                connection: connection,
                theme: connection.terminalTheme,
                allowsDirectInput: allowsDirectInput,
                keyBridge: keyBridge,
                initialScrollProgress: terminalContinuity?.terminalViewportProgress,
                onScrollProgress: saveTerminalViewport
            )
            .background(terminalBackground)
            // The terminal owns the padding colour so the inset reads as breathing room rather
            // than a second application panel under every authored chrome.
            .padding(MobileDesign.Spacing.small)
            .background(terminalBackground)
            TerminalCollaborationBar(
                connection: connection,
                askForInput: { showsAttentionRequest = true }
            )
            InputControlBar(connection: connection)
            AttentionActivityBanner(connection: connection)
            if usesIndependentComposer {
                TerminalLineComposer(connection: connection)
            }
            TerminalKeyBar(
                connection: connection,
                bridge: keyBridge,
                agentKind: connection.session.agentKind,
                customize: { showsKeyboardEditor = true }
            )
        }
        .toolbarBackground(theme.surface, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                RemoteNavigationTitle(connection: connection)
            }
        }
        .mobileTheme(theme)
        .sheet(isPresented: $showsAttentionRequest) {
            AttentionRequestSheet(connection: connection)
                .mobileTheme(theme)
        }
        .sheet(isPresented: $showsKeyboardEditor) {
            TerminalKeyboardEditorView(agentKind: connection.session.agentKind)
                .environmentObject(keyboards)
                .mobileTheme(theme)
        }
    }

    private var terminalContinuity: MobileSessionContinuityStore.SessionState? {
        guard let hostID = model.activeHostID else { return nil }
        return continuity.state(hostID: hostID, sessionID: connection.session.id)
    }

    private func saveTerminalViewport(_ progress: Double) {
        guard let hostID = model.activeHostID else { return }
        continuity.setTerminalViewport(
            progress: progress,
            hostID: hostID,
            sessionID: connection.session.id
        )
    }
}

private struct TerminalCollaborationBar: View {
    @ObservedObject var connection: RemoteSessionConnection
    let askForInput: () -> Void
    @EnvironmentObject private var notifications: RemoteNotificationManager
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        let people = Array(connection.presence.values)
        let typing = uniqueNames(people.filter { $0.state == "typing" })
        let viewing = uniqueNames(people)
        let label = notifications.typingIndicatorsEnabled && !typing.isEmpty
            ? label(for: typing, action: "typing")
            : notifications.peoplePresenceEnabled && !viewing.isEmpty
                ? label(for: viewing, action: "viewing")
                : nil
        if label != nil || canAskForInput {
            HStack(spacing: MobileDesign.Spacing.small) {
                if let label {
                    Image(systemName: "person.2")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryLabel)
                        .frame(width: MobileDesign.Size.terminalStatusIconColumn)
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(theme.secondaryLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Spacer(minLength: 0)
                }
                if canAskForInput {
                    AttentionTriggerButton(presentation: .utility, action: askForInput)
                }
            }
            .frame(minHeight: MobileDesign.Size.minimumTapTarget)
            .padding(.horizontal, MobileDesign.Spacing.inset)
            .background(theme.surface)
            .overlay(alignment: .top) {
                Rectangle().fill(theme.divider).frame(height: theme.borderWidth)
            }
        }
    }

    private var canAskForInput: Bool {
        connection.phase == .connected
            && connection.capability == .interact
            && connection.supportsAttentionRequests
            && !connection.attentionRecipients.isEmpty
    }

    private func uniqueNames(_ people: [RemotePresenceDTO]) -> [String] {
        Array(Set(people.map(remotePresenceLabel))).sorted()
    }

    private func label(for names: [String], action: String) -> String {
        if names.count == 1 {
            return action == "typing"
                ? MobileL10n.string("%@ is typing…", names[0])
                : MobileL10n.string("%@ is here", names[0])
        }
        if names.count == 2 {
            let joined = names.joined(separator: MobileL10n.string(" and "))
            return action == "typing"
                ? MobileL10n.string("%@ are typing…", joined)
                : MobileL10n.string("%@ are here", joined)
        }
        return action == "typing"
            ? MobileL10n.string("%lld people are typing…", Int64(names.count))
            : MobileL10n.string("%lld people are here", Int64(names.count))
    }
}

private struct TerminalLineComposer: View {
    @ObservedObject var connection: RemoteSessionConnection
    @EnvironmentObject private var model: RemoteAppModel
    @EnvironmentObject private var continuity: MobileSessionContinuityStore
    @Environment(\.remoteTheme) private var theme
    @State private var draft = ""
    @State private var pendingSubmissionID: String?
    @State private var submissionNotice: String?
    @FocusState private var draftIsFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if connection.isPromptSubmissionPending, pendingSubmissionID != nil {
                statusLabel("Sending once…", showsProgress: true)
            } else if let submissionNotice {
                statusLabel(submissionNotice, isWarning: true)
            }

            HStack(alignment: .center, spacing: MobileDesign.Spacing.small) {
                TextField("Compose on this device…", text: $draft, axis: .vertical)
                    .focused($draftIsFocused)
                    .mobileUIEvidenceKeyboardFocus($draftIsFocused)
                    .lineLimit(1...5)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.send)
                    .onSubmit(submit)

                Button(action: submit) {
                    Image(systemName: "arrow.up")
                        .font(.headline)
                        .frame(
                            width: MobileDesign.Size.minimumTapTarget,
                            height: MobileDesign.Size.minimumTapTarget
                        )
                        .background(
                            canSubmit ? theme.accent : theme.controlResting,
                            in: RoundedRectangle(cornerRadius: theme.controlRadius)
                        )
                        .foregroundStyle(canSubmit ? theme.ground : theme.secondaryLabel)
                }
                .disabled(!canSubmit)
                .accessibilityLabel(MobileL10n.string("Send terminal line"))
            }
            .padding(.horizontal, MobileDesign.Spacing.inset)
            .padding(.vertical, MobileDesign.Spacing.small)
        }
        .background(theme.panel)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.divider).frame(height: theme.borderWidth)
        }
        .onChange(of: draft) { _, value in
            submissionNotice = nil
            connection.reportTyping(!value.isEmpty)
            saveDraft(value)
        }
        .onChange(of: connection.promptSubmissionFeedback) { _, feedback in
            handle(feedback)
        }
        .onAppear(perform: restoreDraft)
    }

    private var canSubmit: Bool {
        connection.phase == .connected
            && connection.capability == .interact
            && connection.inputControl?.canWrite != false
            && !connection.isPromptSubmissionPending
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func statusLabel(
        _ text: String,
        showsProgress: Bool = false,
        isWarning: Bool = false
    ) -> some View {
        HStack(spacing: MobileDesign.Spacing.small) {
            if showsProgress {
                ProgressView().controlSize(.small)
            }
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(isWarning ? theme.warning : theme.secondaryLabel)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, MobileDesign.Spacing.large)
        .padding(.top, MobileDesign.Spacing.small)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func submit() {
        if let requestID = connection.submitTerminalLine(draft) {
            pendingSubmissionID = requestID
        }
    }

    private func restoreDraft() {
        guard draft.isEmpty, let hostID = model.activeHostID else { return }
        draft = continuity.draft(
            surface: .terminal,
            hostID: hostID,
            sessionID: connection.session.id
        )
    }

    private func saveDraft(_ value: String) {
        guard let hostID = model.activeHostID else { return }
        continuity.setDraft(
            value,
            surface: .terminal,
            hostID: hostID,
            sessionID: connection.session.id
        )
    }

    private func handle(_ feedback: RemotePromptSubmissionFeedback?) {
        guard let feedback, feedback.requestID == pendingSubmissionID else { return }
        pendingSubmissionID = nil
        if feedback.status == .accepted {
            if draft.trimmingCharacters(in: .newlines) == feedback.text {
                draft = ""
            }
            submissionNotice = nil
            return
        }
        switch feedback.status {
        case .busy:
            submissionNotice = MobileL10n.string(
                "Another composer sent first. Your draft is still here."
            )
        case .rejected:
            submissionNotice = MobileL10n.string(
                "The Mac rejected this line. Your draft is still here."
            )
        case .unavailable:
            submissionNotice = MobileL10n.string(
                "The session changed before this line could be sent. Your draft is still here."
            )
        case .conflict:
            submissionNotice = MobileL10n.string(
                "This line could not be retried safely. Your draft is still here."
            )
        case .accepted:
            break
        }
    }
}

private struct LegacyConversationRemoteView: View {
    @ObservedObject var connection: RemoteSessionConnection
    @EnvironmentObject private var model: RemoteAppModel
    @EnvironmentObject private var continuity: MobileSessionContinuityStore
    @EnvironmentObject private var notifications: RemoteNotificationManager
    @Environment(\.remoteTheme) private var inheritedTheme
    @State private var draft = ""
    @State private var keyboardOverlap: CGFloat = 0
    @State private var showsCapabilityCatalog = false
    @State private var capabilityKindFilter: String?
    @State private var preservedSkillArguments: String?
    @State private var pendingSubmissionID: String?
    @State private var submissionNotice: String?
    @State private var showsAttentionRequest = false

    private var theme: RemoteThemePalette {
        connection.theme.map(RemoteThemePalette.init) ?? inheritedTheme
    }

    var body: some View {
        RemoteConversationTimelineView(
            connection: connection,
            theme: theme,
            initialViewport: conversationContinuity.map {
                ($0.conversationViewportProgress, $0.conversationFollowsBottom)
            },
            onViewportChange: saveConversationViewport
        )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if !completionItems.isEmpty {
                        ConversationCapabilityList(
                            items: completionItems,
                            onChoose: chooseCapability
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    presenceBanner

                    InputControlBar(connection: connection)

                    AttentionActivityBanner(connection: connection)

                    submissionBanner

                    ConversationComposer(
                        text: $draft,
                        isEnabled: connection.phase == .connected
                            && connection.capability == .interact
                            && connection.inputControl?.canWrite != false
                            && connection.conversationCanSend
                            && !connection.isPromptSubmissionPending,
                        isInitiallyFocused: initiallyFocusesComposer,
                        hasCapabilities: connection.capability == .interact
                            && !connection.composerCapabilities.isEmpty,
                        toggleCapabilities: toggleCapabilityCatalog,
                        canAskForInput: connection.phase == .connected
                            && connection.capability == .interact
                            && connection.supportsAttentionRequests
                            && !connection.attentionRecipients.isEmpty,
                        askForInput: { showsAttentionRequest = true },
                        submit: submitDraft
                    )
                    .onChange(of: draft) { _, value in
                        submissionNotice = nil
                        connection.reportTyping(!value.isEmpty)
                        saveDraft(value)
                        if RemoteComposerCompletionQuery.parse(value) == nil,
                           !value.isEmpty {
                            showsCapabilityCatalog = false
                            capabilityKindFilter = nil
                            preservedSkillArguments = nil
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, keyboardOverlap)
                .background(theme.ground)
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    RemoteNavigationTitle(connection: connection)
                }
            }
            .task {
                if initiallyFocusesComposer, draft.isEmpty {
                    draft = MobileL10n.string(
                        "Check the final layout with the keyboard open and a longer prompt."
                    )
                }
            }
            .mobileTheme(theme)
            .background(theme.ground)
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIResponder.keyboardWillChangeFrameNotification
                )
            ) { notification in
                updateKeyboardOverlap(from: notification)
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIResponder.keyboardWillHideNotification
                )
            ) { notification in
                updateKeyboardOverlap(from: notification, hiding: true)
            }
            .onChange(of: connection.promptSubmissionFeedback) { _, feedback in
                handleSubmissionFeedback(feedback)
            }
            .onAppear(perform: restoreDraft)
            .sheet(isPresented: $showsAttentionRequest) {
                AttentionRequestSheet(connection: connection)
                    .mobileTheme(theme)
            }
    }

    private var completionItems: [RemoteComposerCapabilityDTO] {
        let items: [RemoteComposerCapabilityDTO]
        if let query = RemoteComposerCompletionQuery.parse(draft) {
            items = query.suggestions(
                from: connection.composerCapabilities,
                matchingKind: capabilityKindFilter
            )
        } else if showsCapabilityCatalog {
            items = connection.composerCapabilities.sorted {
                if $0.kind != $1.kind { return $0.kind == "command" }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                    == .orderedAscending
            }
        } else {
            return []
        }
        guard let capabilityKindFilter else { return items }
        if capabilityKindFilter == "skill" {
            return items.filter(\.canBrowseAsSkill)
        }
        return items.filter { $0.kind == capabilityKindFilter }
    }

    private func toggleCapabilityCatalog() {
        capabilityKindFilter = nil
        preservedSkillArguments = nil
        withAnimation(.easeInOut(duration: 0.16)) {
            showsCapabilityCatalog.toggle()
        }
    }

    private func chooseCapability(_ capability: RemoteComposerCapabilityDTO) {
        guard capability.isEnabled else { return }
        if capability.id == RemoteComposerCatalog.skillsCommandID {
            let existing = RemoteComposerCompletionQuery.parse(draft) == nil
                ? draft.trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
            openSkillCatalog(preserving: existing.isEmpty ? nil : existing)
            return
        }

        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let arguments = preservedSkillArguments ?? (
            RemoteComposerCompletionQuery.parse(draft) == nil ? trimmed : ""
        )
        if arguments.isEmpty {
            draft = capability.invocationText + " "
        } else {
            draft = capability.invocationText + " " + arguments
        }
        showsCapabilityCatalog = false
        capabilityKindFilter = nil
        preservedSkillArguments = nil
    }

    private func submitDraft() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.caseInsensitiveCompare("/skills") == .orderedSame,
           connection.composerCapabilities.contains(where: {
               $0.id == RemoteComposerCatalog.skillsCommandID
           }) {
            openSkillCatalog(preserving: nil)
            return
        }
        if let requestID = connection.submit(draft) {
            pendingSubmissionID = requestID
            showsCapabilityCatalog = false
            capabilityKindFilter = nil
            preservedSkillArguments = nil
        }
    }

    private func openSkillCatalog(preserving arguments: String?) {
        guard let skill = connection.composerCapabilities.first(where: \.canBrowseAsSkill)
        else { return }
        preservedSkillArguments = arguments
        draft = skill.trigger == "dollar" ? "$" : "/"
        showsCapabilityCatalog = true
        capabilityKindFilter = "skill"
    }

    @ViewBuilder
    private var presenceBanner: some View {
        let people = Array(connection.presence.values)
        let typingNames = uniqueNames(people.filter { $0.state == "typing" })
        let viewingNames = uniqueNames(people)
        if notifications.typingIndicatorsEnabled, !typingNames.isEmpty {
            let label = presenceLabel(names: typingNames, action: "typing")
            Text(label)
                .font(.caption)
                .foregroundStyle(theme.secondaryLabel)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, MobileDesign.Spacing.large)
                .padding(.vertical, MobileDesign.Spacing.small)
                .background(theme.surface)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(label.replacingOccurrences(of: "…", with: ""))
        } else if notifications.peoplePresenceEnabled, !viewingNames.isEmpty {
            let label = presenceLabel(names: viewingNames, action: "viewing")
            Text(label)
                .font(.caption)
                .foregroundStyle(theme.secondaryLabel)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, MobileDesign.Spacing.large)
                .padding(.vertical, MobileDesign.Spacing.small)
                .background(theme.surface)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(label)
        }
    }

    @ViewBuilder
    private var submissionBanner: some View {
        if connection.isPromptSubmissionPending,
           pendingSubmissionID != nil {
            HStack(spacing: MobileDesign.Spacing.small) {
                ProgressView()
                    .controlSize(.small)
                Text("Sending once…")
            }
            .font(.caption)
            .foregroundStyle(theme.secondaryLabel)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, MobileDesign.Spacing.large)
            .padding(.vertical, MobileDesign.Spacing.small)
            .background(theme.surface)
        } else if let submissionNotice {
            Text(submissionNotice)
                .font(.caption)
                .foregroundStyle(theme.warning)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, MobileDesign.Spacing.large)
                .padding(.vertical, MobileDesign.Spacing.small)
                .background(theme.surface)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func uniqueNames(_ people: [RemotePresenceDTO]) -> [String] {
        Array(Set(people.map(remotePresenceLabel))).sorted()
    }

    private var conversationContinuity: MobileSessionContinuityStore.SessionState? {
        guard let hostID = model.activeHostID else { return nil }
        return continuity.state(hostID: hostID, sessionID: connection.session.id)
    }

    private func restoreDraft() {
        guard draft.isEmpty, let hostID = model.activeHostID else { return }
        draft = continuity.draft(
            surface: .conversation,
            hostID: hostID,
            sessionID: connection.session.id
        )
    }

    private func saveDraft(_ value: String) {
        guard let hostID = model.activeHostID else { return }
        continuity.setDraft(
            value,
            surface: .conversation,
            hostID: hostID,
            sessionID: connection.session.id
        )
    }

    private func saveConversationViewport(_ progress: Double, _ followsBottom: Bool) {
        guard let hostID = model.activeHostID else { return }
        continuity.setConversationViewport(
            progress: progress,
            followsBottom: followsBottom,
            hostID: hostID,
            sessionID: connection.session.id
        )
    }

    private func presenceLabel(names: [String], action: String) -> String {
        if names.count == 1 {
            return action == "typing"
                ? MobileL10n.string("%@ is typing…", names[0])
                : MobileL10n.string("%@ is here", names[0])
        }
        if names.count == 2 {
            let joined = names.joined(separator: MobileL10n.string(" and "))
            return action == "typing"
                ? MobileL10n.string("%@ are typing…", joined)
                : MobileL10n.string("%@ are here", joined)
        }
        return action == "typing"
            ? MobileL10n.string("%lld people are typing…", Int64(names.count))
            : MobileL10n.string("%lld people are here", Int64(names.count))
    }

    private func handleSubmissionFeedback(_ feedback: RemotePromptSubmissionFeedback?) {
        guard let feedback, feedback.requestID == pendingSubmissionID else { return }
        pendingSubmissionID = nil
        if feedback.status == .accepted {
            if draft.trimmingCharacters(in: .whitespacesAndNewlines) == feedback.text {
                draft = ""
            }
            submissionNotice = nil
            return
        }
        switch feedback.status {
        case .busy:
            submissionNotice = MobileL10n.string(
                "Another composer sent first. Your draft is still here."
            )
        case .rejected:
            submissionNotice = MobileL10n.string(
                "The Mac rejected this prompt. Your draft is still here."
            )
        case .unavailable:
            submissionNotice = MobileL10n.string(
                "The session changed before this prompt could be sent. Your draft is still here."
            )
        case .conflict:
            submissionNotice = MobileL10n.string(
                "This prompt could not be retried safely. Your draft is still here."
            )
        case .accepted:
            break
        }
    }

    private var initiallyFocusesComposer: Bool {
#if DEBUG
        ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]
            == "conversation-keyboard"
#else
        false
#endif
    }

    private func updateKeyboardOverlap(
        from notification: Notification,
        hiding: Bool = false
    ) {
        let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey]
            as? Double ?? 0
        let target: CGFloat
        if hiding {
            target = 0
        } else if let frame = notification.userInfo?[
            UIResponder.keyboardFrameEndUserInfoKey
        ] as? CGRect {
            let window = UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                .first
            let screenBottom = window?.screen.bounds.maxY ?? UIScreen.main.bounds.maxY
            let safeBottom = window?.safeAreaInsets.bottom ?? 0
            target = max(0, screenBottom - frame.minY - safeBottom)
        } else {
            target = 0
        }
        withAnimation(.easeOut(duration: duration)) {
            keyboardOverlap = target
        }
    }
}

private func remotePresenceLabel(_ presence: RemotePresenceDTO) -> String {
    guard let deviceName = presence.deviceName,
          !deviceName.isEmpty,
          deviceName != presence.displayName else {
        return presence.displayName
    }
    return MobileL10n.string("%@ on %@", presence.displayName, deviceName)
}

private struct ConversationComposer: View {
    @Binding var text: String
    let isEnabled: Bool
    let isInitiallyFocused: Bool
    let hasCapabilities: Bool
    let toggleCapabilities: () -> Void
    let canAskForInput: Bool
    let askForInput: () -> Void
    let submit: () -> Void
    @Environment(\.remoteTheme) private var theme
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: MobileDesign.Spacing.small) {
            Button(action: toggleCapabilities) {
                Image(systemName: "plus")
                    .frame(
                        width: MobileDesign.Size.minimumTapTarget,
                        height: MobileDesign.Size.minimumTapTarget
                    )
                    .background(
                        theme.controlResting,
                        in: RoundedRectangle(cornerRadius: theme.controlRadius)
                    )
            }
            .disabled(!hasCapabilities)
            .accessibilityLabel(MobileL10n.string("Browse commands and skills"))

            if canAskForInput {
                AttentionTriggerButton(action: askForInput)
            }

            TextField("Add feedback…", text: $text, axis: .vertical)
                .lineLimit(1...6)
                .submitLabel(.send)
                .onSubmit(submit)
                .focused($isFocused)

            Button(action: submit) {
                Image(systemName: "arrow.up")
                    .font(.headline)
                    .frame(
                        width: MobileDesign.Size.minimumTapTarget,
                        height: MobileDesign.Size.minimumTapTarget
                    )
                    .background(
                        isEnabled && !text.isEmpty ? theme.accent : theme.controlResting,
                        in: RoundedRectangle(cornerRadius: theme.controlRadius)
                    )
                    .foregroundStyle(
                        isEnabled && !text.isEmpty ? theme.ground : theme.secondaryLabel
                    )
            }
            .disabled(!isEnabled || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, MobileDesign.Spacing.composerHorizontal)
        .padding(.vertical, MobileDesign.Spacing.composerVertical)
        .background(
            theme.panel,
            in: RoundedRectangle(cornerRadius: theme.panelRadius)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.panelRadius)
                .stroke(theme.border, lineWidth: theme.borderWidth)
        )
        .remoteThemeGlow(theme)
        .padding(.horizontal, MobileDesign.Spacing.inset)
        .padding(.vertical, MobileDesign.Spacing.small)
        .task {
            if isInitiallyFocused {
                isFocused = true
            }
        }
    }
}

private struct AttentionTriggerButton: View {
    enum Presentation: Equatable {
        case contained
        case utility
    }

    var presentation: Presentation = .contained
    let action: () -> Void
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        Button(action: action) {
            // localization-ignore: universal mention/action glyph, not language copy.
            Text("@")
                .font(.headline.weight(.semibold))
                .frame(
                    width: MobileDesign.Size.minimumTapTarget,
                    height: MobileDesign.Size.minimumTapTarget
                )
                .background {
                    if presentation == .contained {
                        RoundedRectangle(cornerRadius: theme.controlRadius)
                            .fill(theme.controlResting)
                    }
                }
        }
        .accessibilityLabel(MobileL10n.string("Ask a person for input"))
        .accessibilityHint(MobileL10n.string("Sends a human-only notification"))
    }
}

private struct InputControlBar: View {
    @ObservedObject var connection: RemoteSessionConnection
    @Environment(\.remoteTheme) private var theme
    @State private var pendingRequestID: String?
    @State private var resultNotice: String?

    var body: some View {
        if connection.shouldPresentInputControl, let state = connection.inputControl {
            VStack(spacing: 0) {
                HStack(spacing: MobileDesign.Spacing.small) {
                    Image(systemName: state.mode == .collaborative ? "person.2" : "hand.raised")
                        .foregroundStyle(state.canWrite ? theme.positive : theme.warning)
                        .frame(width: MobileDesign.Size.terminalStatusIconColumn)
                    Text(status(state))
                        .font(.caption)
                        .foregroundStyle(theme.secondaryLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)

                    if state.mode == .focused, !state.canWrite, !state.canManage {
                        Button(MobileL10n.string("Request control")) {
                            send(action: "request")
                        }
                        .buttonStyle(.borderless)
                        .font(.caption.weight(.semibold))
                        .padding(.trailing, MobileDesign.Spacing.inset)
                    }

                    if state.canManage || state.canHandOff {
                        Menu {
                            if state.canManage, state.mode != .collaborative {
                                Button(MobileL10n.string("Collaborative")) {
                                    send(action: "collaborative")
                                }
                            }
                            if state.canManage, !state.canWrite {
                                Button(MobileL10n.string("Reclaim control")) {
                                    send(action: "reclaim")
                                }
                            }
                            if state.mode == .collaborative, state.canManage {
                                Button(MobileL10n.string("Focus on me")) {
                                    send(
                                        action: "focused",
                                        targetID: state.currentParticipantID
                                    )
                                }
                            }
                            if state.mode == .focused {
                                ForEach(
                                    state.participants.filter {
                                        $0.id != state.controllerID && $0.isOnline
                                    }
                                ) { participant in
                                    Button(
                                        MobileL10n.string("Hand off to %@", participant.displayName)
                                    ) {
                                        send(
                                            action: "handoff",
                                            targetID: participant.id
                                        )
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .frame(
                                    width: MobileDesign.Size.minimumTapTarget,
                                    height: MobileDesign.Size.minimumTapTarget
                                )
                        }
                        .accessibilityLabel(MobileL10n.string("Input control options"))
                    }
                }
                .disabled(pendingRequestID != nil)
                .frame(minHeight: MobileDesign.Size.minimumTapTarget)
                if pendingRequestID != nil {
                    Text(MobileL10n.string("Sending control request…"))
                        .font(.caption)
                        .foregroundStyle(theme.secondaryLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, MobileDesign.Spacing.large)
                        .padding(.bottom, MobileDesign.Spacing.tight)
                } else if let resultNotice {
                    Text(resultNotice)
                        .font(.caption)
                        .foregroundStyle(theme.secondaryLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, MobileDesign.Spacing.large)
                        .padding(.bottom, MobileDesign.Spacing.tight)
                }
            }
            .padding(.horizontal, MobileDesign.Spacing.inset)
            .background(theme.surface)
            .overlay(alignment: .top) {
                Rectangle().fill(theme.divider).frame(height: theme.borderWidth)
            }
            .onChange(of: connection.inputControlResult) { _, result in
                guard let result, result.requestID == pendingRequestID else { return }
                pendingRequestID = nil
                switch result.status {
                case .applied: resultNotice = MobileL10n.string("Input control updated.")
                case .delivered: resultNotice = MobileL10n.string("Control request sent.")
                case .unavailable:
                    resultNotice = MobileL10n.string("That person is not available.")
                case .forbidden, .rejected:
                    resultNotice = MobileL10n.string("The control request was not accepted.")
                }
            }
        }
    }

    private func send(action: String, targetID: String? = nil) {
        resultNotice = nil
        pendingRequestID = connection.changeInputControl(
            action: action,
            targetID: targetID
        )
    }

    private func status(_ state: RemoteInputControlStateDTO) -> String {
        if state.mode == .collaborative {
            return MobileL10n.string("Collaborative · everyone can send")
        }
        if state.canWrite {
            return MobileL10n.string("You are controlling · others are watching")
        }
        return MobileL10n.string(
            "%@ is controlling · your draft stays here",
            state.controllerDisplayName ?? MobileL10n.string("Another participant")
        )
    }
}

private struct AttentionActivityBanner: View {
    @ObservedObject var connection: RemoteSessionConnection
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            if let event = connection.attentionEvents.last,
               context.date.timeIntervalSince1970 - event.createdAt < 90 {
            HStack(alignment: .top, spacing: MobileDesign.Spacing.small) {
                Image(systemName: "person.wave.2")
                    .foregroundStyle(theme.accent)
                    .frame(width: MobileDesign.Size.terminalStatusIconColumn)
                VStack(alignment: .leading, spacing: MobileDesign.Spacing.tight) {
                    Text(MobileL10n.string(
                        "%@ asked %@ for input",
                        event.senderDisplayName,
                        event.recipientDisplayName
                    ))
                    .font(.caption.weight(.medium))
                    if let note = event.note, !note.isEmpty {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(theme.secondaryLabel)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, MobileDesign.Spacing.inset)
            .padding(.vertical, MobileDesign.Spacing.small)
            .background(theme.accentMuted)
            .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct AttentionRequestSheet: View {
    @ObservedObject var connection: RemoteSessionConnection
    @Environment(\.remoteTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var selectedRecipientID: String?
    @State private var note = ""
    @State private var requestID: String?
    @State private var notice: String?
    @FocusState private var noteIsFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                ThemedSettingsSection {
                    ForEach(connection.attentionRecipients) { participant in
                        Button {
                            selectedRecipientID = participant.id
                            notice = nil
                        } label: {
                            HStack(spacing: MobileDesign.Spacing.medium) {
                                Text("@\(participant.displayName)")
                                    .foregroundStyle(theme.label)
                                Spacer()
                                Text(participant.isOnline
                                    ? MobileL10n.string("Here now")
                                    : MobileL10n.string("Away"))
                                    .font(.caption)
                                    .foregroundStyle(participant.isOnline
                                        ? theme.positive
                                        : theme.tertiaryLabel)
                                if selectedRecipientID == participant.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(theme.accent)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Person")
                }

                ThemedSettingsSection {
                    TextField("Optional note…", text: $note, axis: .vertical)
                        .focused($noteIsFocused)
                        .mobileUIEvidenceKeyboardFocus($noteIsFocused)
                        .lineLimit(2...4)
                        .onChange(of: note) { _, value in
                            note = Self.truncatedNote(value)
                            notice = nil
                        }
                } header: {
                    Text("What do you need?")
                } footer: {
                    Text(
                        "This is a human-only notification. Nothing here is sent to Claude, "
                            + "Codex, or the terminal."
                    )
                }

                if connection.isAttentionRequestPending, requestID != nil {
                    ThemedSettingsSection {
                        HStack(spacing: MobileDesign.Spacing.small) {
                            ProgressView().controlSize(.small)
                            Text("Sending attention request…")
                        }
                        .foregroundStyle(theme.secondaryLabel)
                    }
                } else if let notice {
                    ThemedSettingsSection {
                        Label(notice, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(theme.warning)
                    }
                }
            }
            .themedSettingsPage(theme)
            .navigationTitle("Ask for input")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Ask") { send() }
                        .disabled(selectedRecipientID == nil
                            || connection.isAttentionRequestPending)
                }
            }
            .task {
                if selectedRecipientID == nil {
                    selectedRecipientID = connection.attentionRecipients.first?.id
                }
            }
            .onChange(of: connection.attentionRecipients) { _, recipients in
                if !recipients.contains(where: { $0.id == selectedRecipientID }) {
                    selectedRecipientID = recipients.first?.id
                }
            }
            .onChange(of: connection.attentionRequestFeedback) { _, feedback in
                handle(feedback)
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func send() {
        guard let selectedRecipientID else { return }
        requestID = connection.requestAttention(
            recipientID: selectedRecipientID,
            note: note.isEmpty ? nil : note
        )
        if requestID == nil {
            notice = MobileL10n.string("The attention request could not be sent.")
        }
    }

    private func handle(_ feedback: RemoteAttentionRequestFeedback?) {
        guard let feedback, feedback.requestID == requestID else { return }
        requestID = nil
        switch feedback.status {
        case .delivered:
            dismiss()
        case .unavailable:
            notice = MobileL10n.string(
                "That person is away and has input-request notifications turned off."
            )
        case .rateLimited:
            notice = MobileL10n.string("They were just asked. Try again in a moment.")
        case .rejected:
            notice = MobileL10n.string("The attention request could not be sent.")
        }
    }

    private static func truncatedNote(_ value: String) -> String {
        guard value.utf8.count > RemoteAttentionDefaults.maximumNoteUTF8Bytes else {
            return value
        }
        var bytes = value.utf8.prefix(RemoteAttentionDefaults.maximumNoteUTF8Bytes)
        while String(bytes: bytes, encoding: .utf8) == nil, !bytes.isEmpty {
            bytes = bytes.dropLast()
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

private struct ConversationCapabilityList: View {
    let items: [RemoteComposerCapabilityDTO]
    let onChoose: (RemoteComposerCapabilityDTO) -> Void
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        ScrollView {
            LazyVStack(spacing: MobileDesign.Spacing.hairline) {
                ForEach(items) { item in
                    Button {
                        onChoose(item)
                    } label: {
                        HStack(alignment: .top, spacing: MobileDesign.Spacing.medium) {
                            VStack(alignment: .leading, spacing: MobileDesign.Spacing.tight) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(item.invocationText)
                                        .font(.body.monospaced().weight(.semibold))
                                    if !item.argumentHint.isEmpty {
                                        Text(item.argumentHint)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(theme.secondaryLabel)
                                    }
                                    Spacer(minLength: MobileDesign.Spacing.small)
                                    // localization-ignore: `skill` is a wire enum discriminator.
                                    Text(item.kind == "skill"
                                        ? MobileL10n.string("Skill")
                                        : MobileL10n.string("Command"))
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(theme.tertiaryLabel)
                                }

                                let detail = item.presentationDetail
                                if !detail.isEmpty {
                                    Text(detail)
                                        .font(.caption)
                                        .foregroundStyle(theme.secondaryLabel)
                                        .lineLimit(2)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, MobileDesign.Spacing.inset)
                        .padding(.vertical, MobileDesign.Spacing.medium)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!item.isEnabled)
                    .opacity(item.isEnabled ? 1 : 0.55)
                    .accessibilityLabel(
                        [item.invocationText, item.displayName, item.presentationDetail]
                            .filter { !$0.isEmpty }
                            .joined(separator: ", ")
                    )
                }
            }
        }
        .frame(maxHeight: 260)
        .background(
            theme.elevated,
            in: RoundedRectangle(cornerRadius: theme.panelRadius)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.panelRadius)
                .stroke(theme.border, lineWidth: theme.borderWidth)
        )
        .remoteThemeGlow(theme)
        .padding(.horizontal, MobileDesign.Spacing.inset)
        .padding(.top, MobileDesign.Spacing.small)
    }
}
