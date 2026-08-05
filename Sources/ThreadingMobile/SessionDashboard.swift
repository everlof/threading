import ThreadingRemoteKit
import SwiftUI

private enum SessionOrganization: String, CaseIterable {
    case project
    case recent

    var title: String {
        switch self {
        case .project: return MobileL10n.string("By project")
        case .recent: return MobileL10n.string("Most recent")
        }
    }

    var symbol: String {
        switch self {
        case .project: return "folder"
        case .recent: return "clock.arrow.circlepath"
        }
    }
}

private enum DashboardSessionAction {
    case pin
    case rename
    case archive
    case restore
    case surface(String)
    case share
    case stopSharing
}

private struct SurfaceChangeRequest {
    let session: RemoteSessionSummaryDTO
    let surface: String
}

private struct SharedSessionLink: Identifiable {
    let id = UUID()
    let sessionTitle: String
    let url: URL
    let capability: String
    let canApprovePermissions: Bool
    let expiresAt: Date
}

struct SessionDashboard: View {
    @EnvironmentObject private var model: RemoteAppModel
    @EnvironmentObject private var notifications: RemoteNotificationManager
    @Environment(\.remoteTheme) private var theme
    @AppStorage("sessionDashboardOrganization") private var organizationRaw =
        SessionOrganization.project.rawValue
    @State private var searchText = ""
    @State private var isConfirmingForget = false
    @State private var themeError: String?
    @State private var pendingThemeID: String?
    @State private var showsArchived = false
    @State private var showsNewSession = false
    @State private var renamingSession: RemoteSessionSummaryDTO?
    @State private var renameText = ""
    @State private var actionError: String?
    @State private var pendingActionSessionID: String?
    @State private var surfaceChangeRequest: SurfaceChangeRequest?
    @State private var sharingSession: RemoteSessionSummaryDTO?
    @State private var sharedLink: SharedSessionLink?
    let openSettings: () -> Void

    private var organization: SessionOrganization {
        SessionOrganization(rawValue: organizationRaw) ?? .project
    }

    private var sessions: [RemoteSessionSummaryDTO] {
        let all = showsArchived
            ? model.me?.archivedSessions ?? []
            : model.me?.sessions ?? []
        let filtered = searchText.isEmpty ? all : all.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
                || $0.projectName.localizedCaseInsensitiveContains(searchText)
        }
        return filtered.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return ($0.lastActiveAt ?? 0) > ($1.lastActiveAt ?? 0)
        }
    }

    private var groupedSessions: [(String, [RemoteSessionSummaryDTO])] {
        Dictionary(grouping: sessions, by: \.projectName)
            .map { ($0.key.isEmpty ? MobileL10n.string("Other") : $0.key, $0.value) }
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
    }

    var body: some View {
        dashboardAlerts
            .toolbarBackground(theme.surface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .background(theme.ground)
    }

    private var dashboardContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                deviceSection

                HStack {
                    Text(MobileL10n.string(showsArchived ? "Archived" : "Sessions"))
                        .font(.title3.weight(.medium))
                    Spacer()
                    Text("\(sessions.count)")
                        .font(.subheadline)
                        .foregroundStyle(theme.secondaryLabel)
                    if model.canManageSessions, !showsArchived {
                        Button {
                            showsNewSession = true
                        } label: {
                            Label("New session", systemImage: "plus")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 12)
                                .frame(height: 36)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.ground)
                        .background(theme.accent, in: Capsule())
                        .accessibilityHint("Starts an agent on the selected Mac")
                    }
                }

                if model.me == nil {
                    loadingCard
                } else if sessions.isEmpty {
                    emptyCard
                } else if organization == .project {
                    ForEach(groupedSessions, id: \.0) { project, sessions in
                        ProjectSessionGroup(
                            project: project,
                            sessions: sessions,
                            isArchived: showsArchived,
                            showsActions: model.canManageSessions,
                            pendingActionSessionID: pendingActionSessionID,
                            action: perform
                        )
                    }
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(sessions) { session in
                            SessionListItem(
                                session: session,
                                isArchived: showsArchived,
                                showsActions: model.canManageSessions,
                                pendingActionSessionID: pendingActionSessionID,
                                action: perform
                            )
                        }
                    }
                }

                if notifications.shouldOfferOnboarding {
                    NotificationOnboardingCard()
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 36)
        }
    }

    private var dashboardNavigation: some View {
        dashboardContent
        .refreshable { await model.refresh() }
        .searchable(text: $searchText, prompt: "Search sessions")
        .navigationTitle("Code")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { dashboardToolbar }
        .task(id: model.activeHostID) { await model.poll() }
    }

    private var dashboardSheets: some View {
        dashboardNavigation
        .sheet(isPresented: $showsNewSession) {
            NewRemoteSessionView()
                .environmentObject(model)
                .environment(\.remoteTheme, theme)
        }
        .sheet(item: $sharedLink) { link in
            SharedSessionLinkView(link: link)
                .environment(\.remoteTheme, theme)
        }
    }

    private var dashboardDialogs: some View {
        dashboardSheets
        .themedConfirmationDialog(
            MobileL10n.string(
                "Forget %@?",
                model.activeHost?.name ?? MobileL10n.string("this Mac")
            ),
            message:
                "Its private link will be removed from this iPhone. "
                + "You can pair it again from the Mac.",
            isPresented: $isConfirmingForget,
            actions: [
                ThemedDialogAction(
                    "Forget Mac",
                    systemImage: "trash",
                    role: .destructive
                ) {
                    guard let host = model.activeHost else { return }
                    model.remove(host)
                },
                ThemedDialogAction("Cancel", role: .cancel),
            ]
        )
        .themedConfirmationDialog(
            surfaceChangeRequest.map {
                MobileL10n.string(
                    "Show in %@?",
                    surfaceTitle($0.surface, session: $0.session)
                )
            } ?? "Switch UI?",
            message:
                "The agent restarts in the selected UI and resumes this same session. "
                + "Work currently in progress is interrupted.",
            isPresented: Binding(
                get: { surfaceChangeRequest != nil },
                set: { if !$0 { surfaceChangeRequest = nil } }
            ),
            actions: [
                ThemedDialogAction("Switch UI", systemImage: "rectangle.2.swap") {
                    guard let request = surfaceChangeRequest else { return }
                    surfaceChangeRequest = nil
                    mutate(request.session) {
                        try await model.setSurface(request.surface, for: request.session)
                    }
                },
                ThemedDialogAction("Cancel", role: .cancel) {
                    surfaceChangeRequest = nil
                },
            ]
        )
        .themedConfirmationDialog(
            sharingSession.map {
                MobileL10n.string("Share “%@”", $0.title)
            } ?? "Share session",
            message: sharingDialogMessage,
            isPresented: Binding(
                get: { sharingSession != nil },
                set: { if !$0 { sharingSession = nil } }
            ),
            actions: [
                ThemedDialogAction(
                    "View only",
                    systemImage: "eye",
                    isEnabled: sharingSession?.isAvailable == true
                ) {
                    createShare(capability: "view")
                },
                ThemedDialogAction(
                    "Allow collaboration",
                    systemImage: "person.2"
                ) {
                    createShare(capability: "interact")
                },
                ThemedDialogAction(
                    "Collaboration + approvals",
                    systemImage: "checkmark.shield"
                ) {
                    createShare(capability: "interact", canApprovePermissions: true)
                },
                ThemedDialogAction("Cancel", role: .cancel) {
                    sharingSession = nil
                },
            ]
        )
        .themedAlert(
            "Rename session",
            message: "This name is shared with the Mac.",
            isPresented: Binding(
                get: { renamingSession != nil },
                set: { if !$0 { renamingSession = nil } }
            ),
            textField: ThemedDialogTextField("Session name", text: $renameText),
            actions: [
                ThemedDialogAction("Cancel", role: .cancel) {
                    renamingSession = nil
                },
                ThemedDialogAction("Rename") {
                    guard let session = renamingSession else { return }
                    renamingSession = nil
                    mutate(session) { try await model.renameSession(session, to: renameText) }
                },
            ]
        )
    }

    private var dashboardAlerts: some View {
        dashboardDialogs
        .themedAlert(
            "Couldn’t change appearance",
            message: themeError ?? "",
            isPresented: Binding(
                get: { themeError != nil },
                set: { if !$0 { themeError = nil } }
            ),
            actions: [ThemedDialogAction("OK")]
        )
        .themedAlert(
            "Remote action failed",
            message: actionError ?? "",
            isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            ),
            actions: [ThemedDialogAction("OK")]
        )
    }

    @ToolbarContentBuilder
    private var dashboardToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                ForEach(model.hosts) { host in
                    Button {
                        model.selectHost(host.id)
                    } label: {
                        Label(
                            host.menuTitle,
                            systemImage: host.id == model.activeHostID
                                ? "checkmark"
                                : "laptopcomputer"
                        )
                    }
                }
            } label: {
                Image(systemName: "line.3.horizontal")
                    .frame(width: 34, height: 34)
                    .background(theme.controlResting, in: Circle())
            }
            .accessibilityLabel("Choose Mac")
        }
        ToolbarItem(placement: .principal) {
            Text("Code").font(.headline)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Section("Organize") {
                    ForEach(SessionOrganization.allCases, id: \.rawValue) { option in
                        Button {
                            organizationRaw = option.rawValue
                        } label: {
                            Label(
                                option.title,
                                systemImage: organization == option
                                    ? "checkmark"
                                    : option.symbol
                            )
                        }
                    }
                }

                if model.canManageSessions {
                    Section("Manage") {
                        Button {
                            showsArchived.toggle()
                        } label: {
                            Label(
                                MobileL10n.string(
                                    showsArchived ? "Active sessions" : "Archived sessions"
                                ),
                                systemImage: showsArchived ? "tray" : "archivebox"
                            )
                        }
                    }
                }

                if model.canManageThemes, let catalog = model.me?.themeCatalog {
                    Menu {
                        ForEach(catalog.appThemes, id: \.id) { option in
                            Button {
                                chooseAppTheme(option.id)
                            } label: {
                                if model.me?.theme?.id == option.id {
                                    Label(option.name, systemImage: "checkmark")
                                } else {
                                    Text(option.name)
                                }
                            }
                            .disabled(pendingThemeID != nil)
                        }
                    } label: {
                        Label("Appearance", systemImage: "paintpalette")
                    }
                }

                Button {
                    openSettings()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }

                Divider()
                Button {
                    model.isPairing = true
                } label: {
                    Label("Pair another Mac", systemImage: "qrcode.viewfinder")
                }
                if let host = model.activeHost {
                    Button(role: .destructive) {
                        isConfirmingForget = true
                    } label: {
                        Label("Forget \(host.name)", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 34, height: 34)
                    .background(theme.controlResting, in: Circle())
            }
            .accessibilityLabel("Remote access options")
        }
    }

    private func perform(
        _ action: DashboardSessionAction,
        _ session: RemoteSessionSummaryDTO
    ) {
        switch action {
        case .rename:
            renameText = session.title
            renamingSession = session
        case .pin:
            mutate(session) { try await model.setPinned(!session.isPinned, for: session) }
        case .archive:
            mutate(session) { try await model.setArchived(true, for: session) }
        case .restore:
            mutate(session) { try await model.setArchived(false, for: session) }
        case .surface(let surface):
            guard surface != session.surface else { return }
            surfaceChangeRequest = .init(session: session, surface: surface)
        case .share:
            sharingSession = session
        case .stopSharing:
            mutate(session) { try await model.revokeShares(for: session) }
        }
    }

    private func createShare(
        capability: String,
        canApprovePermissions: Bool = false
    ) {
        guard let session = sharingSession, pendingActionSessionID == nil else { return }
        sharingSession = nil
        pendingActionSessionID = session.id
        Task {
            defer { pendingActionSessionID = nil }
            do {
                let response = try await model.createShare(
                    for: session,
                    capability: capability,
                    canApprovePermissions: canApprovePermissions
                )
                guard let url = URL(string: response.url) else {
                    throw RemoteClientError.invalidResponse
                }
                sharedLink = SharedSessionLink(
                    sessionTitle: session.title,
                    url: url,
                    capability: response.capability,
                    canApprovePermissions: response.canApprovePermissions,
                    expiresAt: Date(timeIntervalSince1970: response.expiresAt)
                )
            } catch is CancellationError {
                return
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func surfaceTitle(_ surface: String, session: RemoteSessionSummaryDTO) -> String {
        if surface == "conversation" {
            return MobileL10n.string("Native (Experimental)")
        }
        return MobileL10n.string(session.agentKind == "claude" ? "Claude Code UI" : "Codex UI")
    }

    private var sharingDialogMessage: String {
        var result = MobileL10n.string(
            "This single-use invitation opens only this chat and expires in 24 hours if unused. "
                + "An accepted member stays until you stop sharing. Permission approval is a "
                + "separate right for people you trust."
        )
        if sharingSession?.isAvailable == false {
            result += MobileL10n.string(
                " Start the chat first to create a view-only link."
            )
        }
        return result
    }

    private func mutate(
        _ session: RemoteSessionSummaryDTO,
        operation: @escaping @MainActor () async throws -> Void
    ) {
        guard pendingActionSessionID == nil else { return }
        pendingActionSessionID = session.id
        Task {
            defer { pendingActionSessionID = nil }
            do {
                try await operation()
            } catch is CancellationError {
                return
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func chooseAppTheme(_ id: String) {
        guard pendingThemeID == nil else { return }
        pendingThemeID = id
        Task {
            defer { pendingThemeID = nil }
            do {
                try await model.selectAppTheme(id)
            } catch is CancellationError {
                return
            } catch {
                themeError = error.localizedDescription
            }
        }
    }

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Macs").font(.title3.weight(.medium))
                Spacer()
                Text("\(model.hosts.count)")
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryLabel)
            }

            HStack(spacing: 16) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 28, weight: .light))
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.activeHost?.name ?? MobileL10n.string("Threading Mac"))
                        .font(.headline)
                    if model.me?.share.scope == "session" {
                        let role = model.me?.share.capability == "interact"
                            ? (model.me?.share.canApprovePermissions == true
                                ? MobileL10n.string("Collaborator + approvals")
                                : MobileL10n.string("Collaborator"))
                            : MobileL10n.string("View only")
                        Text(MobileL10n.string("Shared chat · %@", role))
                            .font(.caption)
                            .foregroundStyle(theme.accent)
                    }
                    HStack(spacing: 6) {
                        Circle().fill(statusColor).frame(width: 7, height: 7)
                        Text(statusText)
                            .font(.subheadline)
                            .foregroundStyle(theme.secondaryLabel)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "iphone")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(theme.secondaryLabel)
            }
            .padding(20)
            .background(theme.panel, in: RoundedRectangle(cornerRadius: theme.panelRadius))
            .overlay(
                RoundedRectangle(cornerRadius: theme.panelRadius)
                    .stroke(theme.border, lineWidth: theme.borderWidth)
            )
            .remoteThemeGlow(theme)

            if !alternateHosts.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(alternateHosts) { host in
                            Button {
                                model.selectHost(host.id)
                            } label: {
                                Label(host.menuTitle, systemImage: "laptopcomputer")
                                    .font(.subheadline)
                                    .lineLimit(1)
                                    .padding(.horizontal, 12)
                                    .frame(height: 38)
                                    .background(theme.panel, in: Capsule())
                                    .overlay(
                                        Capsule().stroke(theme.border, lineWidth: theme.borderWidth)
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint(MobileL10n.string("Choose Mac"))
                        }
                    }
                }
            }
        }
    }

    private var alternateHosts: [PairedRemoteHost] {
        model.hosts.filter { $0.id != model.activeHostID }
    }

    private var statusColor: Color {
        if case .online = model.phase { return theme.positive }
        if case .connecting = model.phase { return theme.warning }
        return theme.tertiaryLabel
    }

    private var statusText: String {
        switch model.phase {
        case .idle: return MobileL10n.string("Not connected")
        case .connecting: return MobileL10n.string("Connecting…")
        case .online:
            return MobileL10n.string(
                "Connected · %@",
                model.activeHost?.connectionLabel ?? MobileL10n.string("Direct")
            )
        case .offline(let message): return message
        }
    }

    private var loadingCard: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text("Loading sessions from your Mac…")
                .foregroundStyle(theme.secondaryLabel)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .background(theme.panel, in: RoundedRectangle(cornerRadius: theme.panelRadius))
        .remoteThemeGlow(theme)
    }

    private var emptyCard: some View {
        ContentUnavailableView(
            MobileL10n.string(showsArchived ? "No archived sessions" : "No sessions yet"),
            systemImage: showsArchived ? "archivebox" : "terminal",
            description: Text(
                MobileL10n.string(showsArchived
                    ? "Sessions you archive from your Mac or iPhone appear here."
                    : model.canManageSessions
                        ? "Start one from this iPhone or your Mac."
                        : "Start a Claude Code or Codex session on your Mac.")
            )
        )
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(theme.panel, in: RoundedRectangle(cornerRadius: theme.panelRadius))
        .remoteThemeGlow(theme)
    }
}

private struct ProjectSessionGroup: View {
    let project: String
    let sessions: [RemoteSessionSummaryDTO]
    let isArchived: Bool
    let showsActions: Bool
    let pendingActionSessionID: String?
    let action: (DashboardSessionAction, RemoteSessionSummaryDTO) -> Void
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(project, systemImage: "folder")
                .font(.headline)
                .foregroundStyle(theme.label)
            VStack(spacing: 10) {
                ForEach(sessions) { session in
                    SessionListItem(
                        session: session,
                        isArchived: isArchived,
                        showsActions: showsActions,
                        pendingActionSessionID: pendingActionSessionID,
                        action: action
                    )
                }
            }
        }
    }
}

private struct SessionListItem: View {
    let session: RemoteSessionSummaryDTO
    let isArchived: Bool
    let showsActions: Bool
    let pendingActionSessionID: String?
    let action: (DashboardSessionAction, RemoteSessionSummaryDTO) -> Void
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            if isArchived {
                SessionRow(session: session, showsChevron: false)
            } else {
                NavigationLink(value: session.id) {
                    SessionRow(session: session, showsChevron: false)
                }
                .buttonStyle(.plain)
            }

            if showsActions {
                Menu {
                if isArchived {
                    Button {
                        action(.restore, session)
                    } label: {
                        Label("Restore", systemImage: "arrow.uturn.backward")
                    }
                } else {
                    Button {
                        action(.pin, session)
                    } label: {
                        Label(
                            MobileL10n.string(session.isPinned ? "Unpin" : "Pin"),
                            systemImage: session.isPinned ? "pin.slash" : "pin"
                        )
                    }
                    Button {
                        action(.rename, session)
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button {
                        action(.share, session)
                    } label: {
                        Label("Share chat", systemImage: "square.and.arrow.up")
                    }
                    if session.isShared {
                        Button(role: .destructive) {
                            action(.stopSharing, session)
                        } label: {
                            Label("Stop sharing", systemImage: "person.crop.circle.badge.xmark")
                        }
                    }
                    Section("Interface") {
                        Button {
                            action(.surface("conversation"), session)
                        } label: {
                            Label(
                                "Native",
                                systemImage: session.surface == "conversation"
                                    ? "checkmark"
                                    : "bubble.left.and.bubble.right"
                            )
                        }
                        .accessibilityLabel("Native, experimental")
                        Button {
                            action(.surface("terminal"), session)
                        } label: {
                            Label(
                                MobileL10n.string(session.agentKind == "claude"
                                    ? "Claude Code UI"
                                    : "Codex UI"),
                                systemImage: session.surface == "terminal"
                                    ? "checkmark"
                                    : "terminal"
                            )
                        }
                    }
                    Button(role: .destructive) {
                        action(.archive, session)
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                }
                } label: {
                    Image(systemName: pendingActionSessionID == session.id
                        ? "ellipsis.circle.fill"
                        : "ellipsis")
                        .frame(width: 38, height: 48)
                        .contentShape(Rectangle())
                }
                .disabled(pendingActionSessionID != nil)
                .foregroundStyle(theme.secondaryLabel)
                .accessibilityLabel("Actions for \(session.title)")
            }
        }
    }
}

private struct SharedSessionLinkView: View {
    let link: SharedSessionLink
    @Environment(\.remoteTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Image(systemName: link.capability == "interact"
                    ? "person.2.badge.gearshape"
                    : "person.2")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(theme.accent)

                VStack(spacing: 7) {
                    Text("Link ready")
                        .font(.title2.bold())
                    Text(link.sessionTitle)
                        .font(.headline)
                    Text(MobileL10n.string(link.capability == "interact"
                        ? (link.canApprovePermissions
                            ? "Can collaborate and approve requests"
                            : "Can collaborate in this chat")
                        : "Can view this chat"))
                        .font(.subheadline)
                        .foregroundStyle(theme.secondaryLabel)
                    Text("Unused invite expires \(link.expiresAt.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(theme.tertiaryLabel)
                }
                .multilineTextAlignment(.center)

                ShareLink(item: link.url) {
                    Label("Share link", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.accent)
                .foregroundStyle(theme.ground)

                Button {
                    UIPasteboard.general.string = link.url.absoluteString
                    copied = true
                } label: {
                    Label(MobileL10n.string(copied ? "Copied" : "Copy link"), systemImage: copied
                        ? "checkmark"
                        : "doc.on.doc")
                }
                .buttonStyle(.bordered)

                Text(
                    "The invite works once. After acceptance, access lasts until you stop "
                        + "sharing and never extends to another chat."
                )
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryLabel)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.ground)
            .navigationTitle("Share chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct SessionRow: View {
    let session: RemoteSessionSummaryDTO
    var showsChevron = true
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 13).fill(theme.controlResting)
                Image(systemName: session.surface == "conversation" ? "text.bubble" : "terminal")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(theme.secondaryLabel)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(session.title)
                        .font(.body.weight(.medium))
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                    if session.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(theme.accent)
                    }
                }
                HStack(spacing: 5) {
                    Image(systemName: session.isAvailable
                        ? "laptopcomputer"
                        : "laptopcomputer.slash")
                    Text("\(availabilityLabel) · \(surfaceLabel)")
                }
                .font(.caption)
                .foregroundStyle(
                    session.isAvailable && !session.isArchived
                        ? theme.positive
                        : theme.secondaryLabel
                )
                .lineLimit(1)
            }
            Spacer()
            if let lastActiveAt = session.lastActiveAt {
                Text(compactAge(since: Date(timeIntervalSince1970: lastActiveAt)))
                    .font(.caption2)
                    .foregroundStyle(theme.tertiaryLabel)
                    .fixedSize()
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.tertiaryLabel)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.panel, in: RoundedRectangle(cornerRadius: theme.panelRadius))
        .overlay(
            RoundedRectangle(cornerRadius: theme.panelRadius)
                .stroke(theme.border, lineWidth: theme.borderWidth)
        )
        .remoteThemeGlow(theme)
        .overlay(alignment: .topLeading) {
            if session.state == "needsAttention" {
                Circle().fill(theme.warning).frame(width: 8, height: 8).offset(x: 42, y: -2)
            }
        }
    }

    private var stateLabel: String {
        switch session.state {
        case "working": return MobileL10n.string("Working")
        case "needsAttention": return MobileL10n.string("Needs attention")
        default: return MobileL10n.string("Connected")
        }
    }

    private var availabilityLabel: String {
        if session.isArchived { return MobileL10n.string("Archived") }
        return session.isAvailable ? stateLabel : MobileL10n.string("Disconnected")
    }

    private var surfaceLabel: String {
        if session.surface == "conversation" { return MobileL10n.string("Native") }
        return MobileL10n.string(session.agentKind == "claude" ? "Claude Code UI" : "Codex UI")
    }

    private func compactAge(since date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        if seconds < 60 { return MobileL10n.string("now") }
        if seconds < 604_800 {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return formatter.localizedString(for: date, relativeTo: Date())
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

struct NewRemoteSessionView: View {
    @EnvironmentObject private var appModel: RemoteAppModel
    @Environment(\.remoteTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var projectID = ""
    @State private var agentID = ""
    @State private var accountID = ""
    @State private var modelID = ""
    @State private var reasoningID = ""
    /// The agent's supported UI is the safe default; Native stays an explicit experimental opt-in.
    @State private var surface = "terminal"
    @State private var prompt = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @FocusState private var promptIsFocused: Bool

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

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                configurationStrip

                Spacer(minLength: 24)

                composer
                hostLabel
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            .background(theme.ground)
            .navigationTitle("New session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSubmitting)
                }
            }
            .onAppear {
                applyCatalogDefaults()
                promptIsFocused = true
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
            .interactiveDismissDisabled(isSubmitting)
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
        .preferredColorScheme(theme.colorScheme)
        .tint(theme.accent)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            promptEditor
            HStack(spacing: 10) {
                modelMenu
                Spacer(minLength: 8)
                sendButton
            }
        }
        .padding(12)
        .background(
            theme.panel,
            in: RoundedRectangle(cornerRadius: theme.panelRadius)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.panelRadius)
                .stroke(theme.border, lineWidth: theme.borderWidth)
        )
        .remoteThemeGlow(theme)
    }

    private var promptEditor: some View {
        TextField("Message the coding agent…", text: $prompt, axis: .vertical)
            .focused($promptIsFocused)
            .textFieldStyle(.plain)
            .font(.body)
            .lineLimit(3...8)
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
    }

    private var sendButton: some View {
        Button {
            submit()
        } label: {
            ZStack {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .opacity(isSubmitting ? 0 : 1)
                ProgressView()
                    .tint(theme.ground)
                    .opacity(isSubmitting ? 1 : 0)
            }
            .frame(width: 38, height: 38)
        }
        .buttonStyle(.plain)
        .foregroundStyle(canSubmit ? theme.ground : theme.tertiaryLabel)
        .background(canSubmit ? theme.accent : theme.controlHover, in: Circle())
        .disabled(!canSubmit)
        .accessibilityLabel("Start session")
    }

    private var hostLabel: some View {
        Label(
            "Runs on \(appModel.activeHost?.name ?? "your Mac")",
            systemImage: "laptopcomputer"
        )
        .font(.caption)
        .foregroundStyle(theme.secondaryLabel)
        .padding(.top, 10)
    }

    private var configurationStrip: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                projectMenu
                    .layoutPriority(1)
                if selectedAgent?.supportsConversation == true {
                    surfaceMenu
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            identityMenu
        }
        .padding(.vertical, 12)
    }

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
            CompactChoiceLabel(
                symbol: "folder",
                title: selectedProject?.name ?? MobileL10n.string("Project"),
                maxWidth: .infinity
            )
        }
        .frame(maxWidth: .infinity)
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
            AccountIdentityLabel(
                symbol: "sparkles",
                title: selectedIdentityLabel,
                usage: selectedAccountUsage,
                usageFraction: selectedAccount?.usageFraction
            )
        }
        .frame(maxWidth: .infinity)
    }

    private var surfaceMenu: some View {
        Menu {
            Button {
                surface = "conversation"
            } label: {
                Label(
                    "Native (Experimental)",
                    systemImage: surface == "conversation"
                        ? "checkmark"
                        : "bubble.left.and.bubble.right"
                )
            }
            Button {
                surface = "terminal"
            } label: {
                Label(
                    originalUISurfaceTitle,
                    systemImage: surface == "terminal" ? "checkmark" : "terminal"
                )
            }
        } label: {
            CompactChoiceLabel(
                symbol: surface == "conversation"
                    ? "bubble.left.and.bubble.right"
                    : "terminal",
                title: selectedSurfaceTitle
            )
        }
    }

    private var originalUISurfaceTitle: String {
        MobileL10n.string(
            "%@ UI",
            selectedAgent?.name ?? MobileL10n.string("Agent")
        )
    }

    private var selectedSurfaceTitle: String {
        surface == "conversation"
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

            if let selectedModel, !selectedModel.reasoning.isEmpty {
                Section("Reasoning") {
                    Button {
                        reasoningID = ""
                    } label: {
                        Label(
                            "Default",
                            systemImage: reasoningID.isEmpty ? "checkmark" : "circle"
                        )
                    }
                    ForEach(selectedModel.reasoning) { effort in
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
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "bolt")
                Text(modelConfigurationTitle)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(theme.tertiaryLabel)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(theme.label)
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(theme.controlResting, in: Capsule())
        }
        .disabled(models.isEmpty)
    }

    private var modelConfigurationTitle: String {
        let modelName = selectedModel?.name ?? MobileL10n.string("Default model")
        guard let selectedModel,
              let reasoning = selectedModel.reasoning.first(where: { $0.id == reasoningID })
        else { return modelName }
        return "\(modelName) · \(reasoning.name)"
    }

    private var selectedIdentityLabel: String {
        guard let selectedAgent else { return MobileL10n.string("Agent") }
        guard let selectedAccount else { return selectedAgent.name }
        return "\(selectedAgent.name) · \(selectedAccount.name)"
    }

    private var selectedAccountUsage: String? {
        guard let selectedAccount else { return nil }
        if let usage = selectedAccount.usageSummary { return usage }
        if selectedAccount.usageError != nil { return MobileL10n.string("Usage unavailable") }
        return MobileL10n.string("Loading usage…")
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

    private var canSubmit: Bool {
        !isSubmitting
            && !projectID.isEmpty
            && !agentID.isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func applyCatalogDefaults() {
        if projectID.isEmpty { projectID = catalog?.projects.first?.id ?? "" }
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
        if !selectedAgent.supportsConversation { surface = "terminal" }
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
            return
        }
        if !selectedModel.reasoning.contains(where: { $0.id == reasoningID }) {
            reasoningID = selectedModel.defaultReasoningID.flatMap { id in
                selectedModel.reasoning.contains(where: { $0.id == id }) ? id : nil
            } ?? ""
        }
    }

    private func submit() {
        guard canSubmit else { return }
        isSubmitting = true
        Task {
            defer { isSubmitting = false }
            do {
                _ = try await appModel.createSession(
                    projectID: projectID,
                    agentKind: agentID,
                    accountHandle: accountID.isEmpty ? nil : accountID,
                    model: modelID.isEmpty ? nil : modelID,
                    reasoningEffort: reasoningID.isEmpty ? nil : reasoningID,
                    surface: surface,
                    prompt: prompt
                )
                dismiss()
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct CompactChoiceLabel: View {
    let symbol: String
    let title: String
    var maxWidth: CGFloat? = nil
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Image(systemName: "chevron.down")
                .font(.caption2)
                .foregroundStyle(theme.tertiaryLabel)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(theme.label)
        .padding(.horizontal, 8)
        .frame(maxWidth: maxWidth, minHeight: 36)
        .background(theme.controlResting, in: Capsule())
    }
}

private struct AccountIdentityLabel: View {
    let symbol: String
    let title: String
    let usage: String?
    let usageFraction: Double?
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .frame(width: 16)

            Text(title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)

            Spacer(minLength: 10)

            if let usage {
                HStack(spacing: 6) {
                    if let usageFraction {
                        UsageProgressRing(
                            fraction: usageFraction,
                            tint: usageTint(for: usageFraction)
                        )
                    }
                    Text(usage)
                        .font(.caption.monospacedDigit())
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .foregroundStyle(
                    usageFraction.map(usageTint(for:)) ?? theme.secondaryLabel
                )
            }

            Image(systemName: "chevron.down")
                .font(.caption2)
                .foregroundStyle(theme.tertiaryLabel)
        }
        .foregroundStyle(theme.label)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 42)
        .background(theme.controlResting, in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private func usageTint(for fraction: Double) -> Color {
        if fraction >= 0.9 { return theme.negative }
        if fraction >= 0.75 { return theme.warning }
        return theme.positive
    }
}

private struct UsageProgressRing: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.2), lineWidth: 2)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 14, height: 14)
    }
}
