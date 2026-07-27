import SkalmanRemoteKit
import SwiftUI
import UIKit

struct SessionDetailView: View {
    @EnvironmentObject private var model: RemoteAppModel
    @Environment(\.remoteTheme) private var theme
    let session: RemoteSessionSummaryDTO
    @State private var connection: RemoteSessionConnection?
    @State private var launchError: String?
    @State private var themeError: String?
    @State private var isChangingTheme = false
    @State private var renameText = ""
    @State private var isRenaming = false
    @State private var sessionActionError: String?
    @State private var isMutatingSession = false
    @State private var isConfirmingSurfaceSwitch = false
    @State private var pendingSurface = "terminal"
    @State private var isShowingReview = false
    @State private var isShowingAttachments = false
    @Environment(\.dismiss) private var dismiss

    private var currentSession: RemoteSessionSummaryDTO {
        model.me?.sessions.first(where: { $0.id == session.id }) ?? session
    }

    var body: some View {
        Group {
            if let connection {
                if connection.surface == "conversation" {
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
                    Text(session.isAvailable ? "Connecting…" : "Resuming on your Mac…")
                        .foregroundStyle(theme.secondaryLabel)
                }
            }
        }
        .navigationTitle(connection?.title ?? currentSession.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.canManageSessions, let client = model.client {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingReview = true
                    } label: {
                        Image(systemName: "plus.forwardslash.minus")
                    }
                    .accessibilityLabel("Git review")
                    .sheet(isPresented: $isShowingReview) {
                        NavigationStack {
                            RemoteGitReviewView(session: currentSession, client: client)
                        }
                        .environment(\.remoteTheme, theme)
                        .preferredColorScheme(theme.colorScheme)
                        .presentationDetents([.fraction(0.72), .large])
                        .presentationDragIndicator(.visible)
                    }
                }
            }
            if model.canManageThemes,
               currentSession.surface == "terminal",
               let catalog = model.me?.themeCatalog {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            chooseTerminalTheme(nil)
                        } label: {
                            let label = "Inherit (\(currentSession.inheritedTerminalThemeName ?? "Default"))"
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
                        Image(systemName: "paintpalette")
                    }
                    .disabled(isChangingTheme)
                    .accessibilityLabel("Terminal theme")
                }
            }
            if model.canManageSessions {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            isShowingAttachments = true
                        } label: {
                            Label("Attachments", systemImage: "paperclip")
                        }
                        Divider()
                        Button {
                            mutate {
                                try await model.setPinned(
                                    !currentSession.isPinned,
                                    for: currentSession
                                )
                            }
                        } label: {
                            Label(
                                currentSession.isPinned ? "Unpin" : "Pin",
                                systemImage: currentSession.isPinned ? "pin.slash" : "pin"
                            )
                        }
                        Button {
                            renameText = currentSession.title
                            isRenaming = true
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        Section("Interface") {
                            Button {
                                confirmSurfaceSwitch(to: "conversation")
                            } label: {
                                Label(
                                    "Native",
                                    systemImage: currentSession.surface == "conversation"
                                        ? "checkmark"
                                        : "bubble.left.and.bubble.right"
                                )
                            }
                            .accessibilityLabel("Native, experimental")
                            Button {
                                confirmSurfaceSwitch(to: "terminal")
                            } label: {
                                Label(
                                    originalUISurfaceTitle,
                                    systemImage: currentSession.surface == "terminal"
                                        ? "checkmark"
                                        : "terminal"
                                )
                            }
                        }
                        Button(role: .destructive) {
                            mutate(dismissAfterward: true) {
                                try await model.setArchived(true, for: currentSession)
                            }
                        } label: {
                            Label("Archive", systemImage: "archivebox")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .disabled(isMutatingSession)
                    .accessibilityLabel("Session actions")
                }
            }
        }
        .toolbarBackground(theme.surface, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .background(theme.ground)
        .sheet(isPresented: $isShowingAttachments) {
            if let client = model.client {
                NavigationStack {
                    RemoteAttachmentsView(session: currentSession, client: client)
                }
                .environment(\.remoteTheme, theme)
                .preferredColorScheme(theme.colorScheme)
                .presentationDetents([.fraction(0.72), .large])
                .presentationDragIndicator(.visible)
            }
        }
        .task { await open() }
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
            "Switch to \(surfaceTitle(pendingSurface))?",
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
            let made = RemoteSessionConnection(session: current, client: client)
            connection = made
            made.connect()
        } catch is CancellationError {
            return
        } catch {
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
                connection?.previewTerminalTheme(previous)
                themeError = error.localizedDescription
            }
        }
    }

    private var originalUISurfaceTitle: String {
        currentSession.agentKind == "claude" ? "Claude Code UI" : "Codex UI"
    }

    private func surfaceTitle(_ surface: String) -> String {
        surface == "conversation" ? "Native (Experimental)" : originalUISurfaceTitle
    }

    private func confirmSurfaceSwitch(to surface: String) {
        guard surface != currentSession.surface else { return }
        pendingSurface = surface
        isConfirmingSurfaceSwitch = true
    }

    private func switchSurface(to surface: String) {
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
                sessionActionError = error.localizedDescription
            }
        }
    }
}

private struct RemoteNavigationTitle: View {
    @ObservedObject var connection: RemoteSessionConnection
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        VStack(spacing: MobileDesign.Spacing.hairline) {
            Text(connection.title)
                .font(.headline)
                .lineLimit(1)

            if case .failed = connection.phase {
                Button(action: connection.connect) {
                    status
                }
                .buttonStyle(.plain)
                .accessibilityHint("Reconnect")
            } else {
                status
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var status: some View {
        HStack(spacing: MobileDesign.Spacing.tight) {
            Circle()
                .fill(color)
                .frame(
                    width: MobileDesign.Size.navigationStatusIndicator,
                    height: MobileDesign.Size.navigationStatusIndicator
                )
            Text(label)
                .lineLimit(1)
        }
        .font(.caption2)
        .foregroundStyle(theme.secondaryLabel)
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
        case .connecting: return "Connecting to Mac…"
        case .connected:
            return connection.capability == .interact ? "Remote control" : "View only"
        case .ended(let reason): return reason
        case .failed(let reason): return reason
        }
    }
}

private struct TerminalRemoteView: View {
    @ObservedObject var connection: RemoteSessionConnection
    @Environment(\.remoteTheme) private var inheritedTheme

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

    var body: some View {
        VStack(spacing: 0) {
            TerminalViewRepresentable(
                connection: connection,
                theme: connection.terminalTheme
            )
            .background(terminalBackground)
            TerminalKeyBar(connection: connection)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                RemoteNavigationTitle(connection: connection)
            }
        }
        .environment(\.remoteTheme, theme)
        .preferredColorScheme(theme.colorScheme)
    }
}

private struct TerminalKeyBar: View {
    @ObservedObject var connection: RemoteSessionConnection
    @Environment(\.remoteTheme) private var theme

    private let keys: [(String, String)] = [
        ("esc", "\u{1b}"),
        ("⌃C", "\u{3}"),
        ("tab", "\t"),
        ("↑", "\u{1b}[A"),
        ("↓", "\u{1b}[B"),
        ("←", "\u{1b}[D"),
        ("→", "\u{1b}[C"),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(keys, id: \.0) { label, value in
                    Button(label) {
                        connection.sendTerminalKey(value)
                    }
                    .font(.system(.subheadline, design: .monospaced).weight(.medium))
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(
                        theme.controlResting,
                        in: RoundedRectangle(cornerRadius: theme.controlRadius)
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(theme.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.divider).frame(height: theme.borderWidth)
        }
        .disabled(connection.capability != .interact || connection.phase != .connected)
    }
}

struct ConversationRemoteView: View {
    @ObservedObject var connection: RemoteSessionConnection
    @Environment(\.remoteTheme) private var inheritedTheme
    @State private var draft = ""
    @State private var keyboardOverlap: CGFloat = 0

    private var theme: RemoteThemePalette {
        connection.theme.map(RemoteThemePalette.init) ?? inheritedTheme
    }

    var body: some View {
        RemoteConversationTimelineView(connection: connection, theme: theme)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    presenceBanner

                    ConversationComposer(
                        text: $draft,
                        isEnabled: connection.phase == .connected
                            && connection.capability == .interact
                            && connection.conversationCanSend,
                        isInitiallyFocused: initiallyFocusesComposer
                    ) {
                        if connection.submit(draft) { draft = "" }
                    }
                    .onChange(of: draft) { _, value in
                        connection.reportTyping(!value.isEmpty)
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
                    draft = "Check the final layout with the keyboard open and a longer prompt."
                }
            }
            .environment(\.remoteTheme, theme)
            .preferredColorScheme(theme.colorScheme)
            .foregroundStyle(theme.label)
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
    }

    @ViewBuilder
    private var presenceBanner: some View {
        if !connection.presence.isEmpty {
            let names = connection.presence.values
                .map(\.displayName)
                .sorted()
            Text(
                names.count == 1
                    ? "\(names[0]) is typing…"
                    : "\(names.joined(separator: ", ")) are typing…"
            )
            .font(.caption)
            .foregroundStyle(theme.secondaryLabel)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, MobileDesign.Spacing.large)
            .padding(.vertical, MobileDesign.Spacing.small)
            .background(theme.surface)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(
                names.count == 1
                    ? "\(names[0]) is typing"
                    : "\(names.joined(separator: ", ")) are typing"
            )
        }
    }

    private var initiallyFocusesComposer: Bool {
#if DEBUG
        ProcessInfo.processInfo.environment["SKALMAN_MOBILE_DEMO"]
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

private struct ConversationComposer: View {
    @Binding var text: String
    let isEnabled: Bool
    let isInitiallyFocused: Bool
    let submit: () -> Void
    @Environment(\.remoteTheme) private var theme
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: MobileDesign.Spacing.small) {
            Button {} label: {
                Image(systemName: "plus")
                    .frame(
                        width: MobileDesign.Size.minimumTapTarget,
                        height: MobileDesign.Size.minimumTapTarget
                    )
                    .background(theme.controlResting, in: Circle())
            }
            .disabled(true)

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
                        in: Circle()
                    )
                    .foregroundStyle(
                        isEnabled && !text.isEmpty ? theme.ground : theme.secondaryLabel
                    )
            }
            .disabled(!isEnabled || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(MobileDesign.Spacing.medium)
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
