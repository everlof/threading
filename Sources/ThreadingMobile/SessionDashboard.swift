import ThreadingRemoteKit
import SwiftUI

struct MobileSnoozeChoice: Identifiable {
    let id: String
    let title: String
    let deadline: Date
}

enum MobileSnoozePresets {
    static func choices(now: Date = Date(), calendar: Calendar = .current) -> [MobileSnoozeChoice] {
        var result = [MobileSnoozeChoice(
            id: "hour",
            title: MobileL10n.string("In an hour"),
            deadline: now.addingTimeInterval(3_600)
        )]
        if let tomorrow = calendar.nextDate(
            after: now,
            matching: DateComponents(hour: 9),
            matchingPolicy: .nextTime
        ) {
            result.append(MobileSnoozeChoice(
                id: "tomorrow",
                title: MobileL10n.string("Tomorrow morning"),
                deadline: tomorrow
            ))
        }
        if let nextWeek = calendar.date(byAdding: .day, value: 7, to: now) {
            result.append(MobileSnoozeChoice(
                id: "week",
                title: MobileL10n.string("Next week"),
                deadline: nextWeek
            ))
        }
        return result
    }
}

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
    case snooze(Date?)
    case surface(RemoteSessionSurface)
    case share
    case stopSharing
}

private struct SurfaceChangeRequest {
    let session: RemoteSessionSummaryDTO
    let surface: RemoteSessionSurface
}

struct SharedSessionLink: Identifiable {
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
    @State private var showsSnoozed = false
    @State private var showsNewSession = false
    @State private var newSessionProjectName: String?
    @State private var showsMacPicker = false
    @State private var renamingSession: RemoteSessionSummaryDTO?
    @State private var renameText = ""
    @State private var actionError: String?
    @State private var pendingActionSessionID: String?
    @State private var surfaceChangeRequest: SurfaceChangeRequest?
    @State private var sharingSession: RemoteSessionSummaryDTO?
    @State private var sharedLink: SharedSessionLink?
    @State private var showsUsage = false
    let openSettings: () -> Void

    private var organization: SessionOrganization {
        SessionOrganization(rawValue: organizationRaw) ?? .project
    }

    private var sessions: [RemoteSessionSummaryDTO] {
        let all = showsArchived
            ? model.me?.archivedSessions ?? []
            : model.me?.sessions ?? []
        let scoped = showsArchived ? all : all.filter {
            showsSnoozed ? $0.isSnoozed() : !$0.isSnoozed()
        }
        let filtered = searchText.isEmpty ? scoped : scoped.filter {
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
                if model.isDemo {
                    demoBanner
                }

                deviceSection

                HStack {
                    Text(MobileL10n.string(
                        showsArchived ? "Archived" : (showsSnoozed ? "Snoozed" : "Sessions")
                    ))
                        .font(.title3.weight(.medium))
                    Spacer()
                    Text("\(sessions.count)")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(theme.secondaryLabel)
                    if model.canManageSessions, !showsArchived, organization == .recent {
                        projectNewSessionButton(project: nil)
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
                            action: perform,
                            startNewSession: {
                                newSessionProjectName = project
                                showsNewSession = true
                            }
                        )
                    }
                } else {
                    LazyVStack(spacing: MobileDesign.Spacing.small) {
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

    /// Demo state must say so on every visit — canned sessions that read as a live Mac would
    /// be a lie the moment anything "works". The way out sits in the sentence that admits it.
    private var demoBanner: some View {
        HStack(spacing: MobileDesign.Spacing.small) {
            Image(systemName: "sparkles")
                .foregroundStyle(theme.accent)
            Text("This is the demo. Nothing here is connected.")
                .font(.footnote)
                .foregroundStyle(theme.secondaryLabel)
            Spacer()
            Button("End Demo") {
                model.endDemo()
            }
            .font(.footnote.weight(.semibold))
            .buttonStyle(.plain)
            .foregroundStyle(theme.accent)
        }
        .padding(MobileDesign.Spacing.inset)
        .background(theme.panel, in: RoundedRectangle(cornerRadius: theme.panelRadius))
        .overlay {
            RoundedRectangle(cornerRadius: theme.panelRadius)
                .stroke(theme.border, lineWidth: theme.borderWidth)
        }
    }

    private var dashboardNavigation: some View {
        dashboardContent
        .refreshable { await model.refresh() }
        .searchable(text: $searchText, prompt: "Search sessions")
        .navigationTitle("Code")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { dashboardToolbar }
        .task(id: model.activeHostID) { await model.activateDashboard() }
        .onAppear {
#if DEBUG
            if model.isDemo,
               ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]?
                .hasPrefix("usage") == true {
                showsUsage = true
            }
#endif
        }
    }

    private var dashboardSheets: some View {
        dashboardNavigation
        .sheet(isPresented: $showsNewSession) {
            NewRemoteSessionView(initialProjectName: newSessionProjectName)
                .environmentObject(model)
                .environment(\.remoteTheme, theme)
        }
        .sheet(isPresented: $showsMacPicker) {
            DashboardMacPickerView()
                .environmentObject(model)
                .environment(\.remoteTheme, theme)
        }
        .sheet(item: $sharedLink) { link in
            SharedSessionLinkView(link: link)
                .environment(\.remoteTheme, theme)
        }
        .sheet(isPresented: $showsUsage) {
            if let link = model.activeHost?.link {
                RemoteUsageDashboardView(link: link, isDemo: model.isDemo)
                    .environment(\.remoteTheme, theme)
            }
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
                    .frame(
                        width: MobileDesign.Size.compactControl,
                        height: MobileDesign.Size.compactControl
                    )
                    .background(theme.controlResting, in: Circle())
            }
            .accessibilityLabel("Choose Mac")
        }
        ToolbarItem(placement: .principal) {
            Text("Code").font(.headline)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                newSessionProjectName = nil
                showsNewSession = true
            } label: {
                Image(systemName: "plus")
                    .frame(
                        width: MobileDesign.Size.compactControl,
                        height: MobileDesign.Size.compactControl
                    )
                    .background(theme.controlResting, in: Circle())
            }
            .accessibilityLabel("New session")

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
                            showsArchived = false
                            showsSnoozed.toggle()
                        } label: {
                            Label(
                                MobileL10n.string(showsSnoozed ? "Active sessions" : "Snoozed sessions"),
                                systemImage: showsSnoozed ? "tray" : "moon.zzz"
                            )
                        }
                        Button {
                            showsArchived.toggle()
                            if showsArchived { showsSnoozed = false }
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

                if model.canReadUsage {
                    Button {
                        showsUsage = true
                    } label: {
                        Label("Usage", systemImage: "chart.bar.xaxis")
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
                    .frame(
                        width: MobileDesign.Size.compactControl,
                        height: MobileDesign.Size.compactControl
                    )
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
        case .snooze(let deadline):
            mutate(session) { try await model.setSnoozed(until: deadline, for: session) }
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
                MobileDiagnostics.logDegraded(.sessionAction, error: error)
                actionError = error.localizedDescription
            }
        }
    }

    private func surfaceTitle(
        _ surface: RemoteSessionSurface,
        session: RemoteSessionSummaryDTO
    ) -> String {
        if surface == .conversation {
            return MobileL10n.string("Native (Experimental)")
        }
        return MobileAgentIdentity.resolve(session.agentKind).originalUITitle
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
                MobileDiagnostics.logDegraded(.sessionAction, error: error)
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
                MobileDiagnostics.logDegraded(.themeSelection, error: error)
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

            Button {
                showsMacPicker = true
            } label: {
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
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.tertiaryLabel)
                }
                .padding(20)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(theme.panel, in: RoundedRectangle(cornerRadius: theme.panelRadius))
            .overlay(
                RoundedRectangle(cornerRadius: theme.panelRadius)
                    .stroke(theme.border, lineWidth: theme.borderWidth)
            )
            .remoteThemeGlow(theme)
        }
    }

    private func projectNewSessionButton(project: String?) -> some View {
        NewSessionButton(accessibilityLabel: MobileL10n.string("New session")) {
            newSessionProjectName = project
            showsNewSession = true
        }
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

private struct DashboardMacPickerView: View {
    @EnvironmentObject private var model: RemoteAppModel
    @Environment(\.remoteTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(model.hosts) { host in
                Button {
                    model.selectHost(host.id)
                    dismiss()
                } label: {
                    HStack(spacing: MobileDesign.Spacing.medium) {
                        Image(systemName: "laptopcomputer")
                            .foregroundStyle(theme.secondaryLabel)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: MobileDesign.Spacing.hairline) {
                            Text(host.menuTitle)
                                .font(.body.weight(.medium))
                                .foregroundStyle(theme.label)
                            if host.id == model.activeHostID {
                                Text("Current Mac")
                                    .font(.caption)
                                    .foregroundStyle(theme.positive)
                            }
                        }
                        Spacer()
                        if host.id == model.activeHostID {
                            Image(systemName: "checkmark")
                                .foregroundStyle(theme.accent)
                        }
                    }
                    .frame(minHeight: MobileDesign.Size.minimumTapTarget)
                }
                .buttonStyle(.plain)
                .listRowBackground(theme.surface)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(theme.ground)
            .navigationTitle("Choose Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(theme.surface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// Starts a chat, in a project header or beside the connection card.
///
/// It carries no caption. The word sat next to a plus in a header that already names the
/// project, which said the same thing twice and pushed the folder name into truncation on a
/// phone-width row; the glyph alone is the same control the toolbar shows.
struct NewSessionButton: View {
    let accessibilityLabel: String
    let action: () -> Void
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.subheadline.weight(.semibold))
                .frame(
                    width: MobileDesign.Size.compactControl,
                    height: MobileDesign.Size.compactControl
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.accent)
        .background(
            theme.controlResting,
            in: RoundedRectangle(cornerRadius: theme.controlRadius)
        )
        .overlay {
            RoundedRectangle(cornerRadius: theme.controlRadius)
                .strokeBorder(theme.border, lineWidth: theme.borderWidth)
        }
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct ProjectSessionGroup: View {
    let project: String
    let sessions: [RemoteSessionSummaryDTO]
    let isArchived: Bool
    let showsActions: Bool
    let pendingActionSessionID: String?
    let action: (DashboardSessionAction, RemoteSessionSummaryDTO) -> Void
    let startNewSession: () -> Void
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(project, systemImage: "folder")
                    .font(.headline)
                    .foregroundStyle(theme.label)
                Spacer()
                if showsActions, !isArchived {
                    NewSessionButton(
                        accessibilityLabel: MobileL10n.string("New session in %@", project),
                        action: startNewSession
                    )
                }
            }
            VStack(spacing: MobileDesign.Spacing.small) {
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

enum MobileSessionNavigationTransition: Equatable {
    case standard
    case immediate

    /// A terminal transition cannot manufacture intermediate widths. Every width becomes a
    /// SwiftTerm grid, a remote viewport lease, a PTY resize and a full-screen agent repaint.
    /// Native conversations own width-independent rows and keep the platform transition.
    static func forSurface(_ surface: RemoteSessionSurface) -> Self {
        surface == .terminal ? .immediate : .standard
    }
}

private struct SessionListItem: View {
    let session: RemoteSessionSummaryDTO
    let isArchived: Bool
    let showsActions: Bool
    let pendingActionSessionID: String?
    let action: (DashboardSessionAction, RemoteSessionSummaryDTO) -> Void
    @EnvironmentObject private var model: RemoteAppModel
    @Environment(\.remoteTheme) private var theme

    @ViewBuilder
    var body: some View {
        if showsActions {
            sessionRow
                .contextMenu { sessionActions }
                .accessibilityHint("Long press for session actions")
        } else {
            sessionRow
        }
    }

    @ViewBuilder
    private var sessionRow: some View {
        if isArchived {
            SessionRow(session: session, showsChevron: false)
        } else {
            Button(action: openSession) {
                SessionRow(session: session, showsChevron: false)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isLink)
            .accessibilityRemoveTraits(.isButton)
        }
    }

    private func openSession() {
        switch MobileSessionNavigationTransition.forSurface(session.surface) {
        case .standard:
            model.navigationPath.append(session.id)
        case .immediate:
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                model.navigationPath.append(session.id)
            }
        }
    }

    @ViewBuilder
    private var sessionActions: some View {
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
            if session.isSnoozed() {
                Button {
                    action(.snooze(nil), session)
                } label: {
                    Label("Unsnooze", systemImage: "sun.max")
                }
            } else {
                Menu {
                    ForEach(MobileSnoozePresets.choices()) { choice in
                        Button(choice.title) {
                            action(.snooze(choice.deadline), session)
                        }
                    }
                } label: {
                    Label("Snooze", systemImage: "moon.zzz")
                }
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
                    action(.surface(.conversation), session)
                } label: {
                    Label(
                        "Native",
                        systemImage: session.surface == .conversation
                            ? "checkmark"
                            : "bubble.left.and.bubble.right"
                    )
                }
                .accessibilityLabel("Native, experimental")
                Button {
                    action(.surface(.terminal), session)
                } label: {
                    Label(
                        MobileAgentIdentity.resolve(session.agentKind).originalUITitle,
                        systemImage: session.surface == .terminal
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
    }
}

struct SharedSessionLinkView: View {
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
                        .frame(minHeight: 56)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.accentForeground)
                .background(
                    theme.accent,
                    in: RoundedRectangle(cornerRadius: theme.controlRadius)
                )

                Button {
                    UIPasteboard.general.string = link.url.absoluteString
                    copied = true
                } label: {
                    Label(MobileL10n.string(copied ? "Copied" : "Copy link"), systemImage: copied
                        ? "checkmark"
                        : "doc.on.doc")
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.label)
                .padding(.horizontal, MobileDesign.Spacing.large)
                .frame(minHeight: MobileDesign.Size.minimumTapTarget)
                .background(
                    theme.controlResting,
                    in: RoundedRectangle(cornerRadius: theme.controlRadius)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: theme.controlRadius)
                        .stroke(theme.border, lineWidth: theme.borderWidth)
                }

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

enum MobileSessionAgeFormat {
    private static let relativeCutoff: TimeInterval = 7 * 24 * 60 * 60

    /// A compact age whose direction is stated as language rather than as a signed quantity.
    ///
    /// `RelativeDateTimeFormatter.UnitsStyle.abbreviated` renders yesterday as `−1 d` in
    /// Swedish. That is a valid quantity, but it reads as broken beside the session title and
    /// unlike the rest of Threading's relative-time vocabulary. `.short` retains compact units
    /// while spelling the direction (`för 1 d sedan`, `1 day ago`).
    static func string(
        since date: Date,
        relativeTo now: Date = Date(),
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return MobileL10n.string("now") }
        if seconds < relativeCutoff {
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = locale
            formatter.unitsStyle = .short
            return formatter.localizedString(for: date, relativeTo: now)
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

/// One chat in the dashboard list.
///
/// **The tile identifies the runtime, not the surface.** Every row used to draw `terminal`, because
/// a natively rendered conversation is still the experimental opt-in and everything else is the
/// agent's own TUI mirrored from the Mac — so a list of Claude and Codex chats looked like a list of
/// shells, and said nothing about which provider or which login each one was on. It now carries the
/// same two facts the Mac sidebar carries, the same way: the provider's mark, with an alternate
/// account's chip on its corner. `MobileAgentIdentity` holds that vocabulary.
///
/// **It is two lines high, and stays two lines high.** A three-line title plus a 46-point tile put
/// rows between 74 and 110 points, which is a card, not a list row: five chats filled the screen.
/// The title takes one line and the tile no longer sets the height, so the list is scannable and
/// every row is the same height. The full title is one tap away in the session's own screen.
private struct SessionRow: View {
    let session: RemoteSessionSummaryDTO
    var showsChevron = true
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        HStack(spacing: MobileDesign.Spacing.medium) {
            MobileSessionMark(
                agentKind: session.agentKind,
                account: session.account,
                isDimmed: !session.isAvailable || session.isArchived
            )

            VStack(alignment: .leading, spacing: MobileDesign.Spacing.hairline) {
                Text(session.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(theme.label)
                HStack(spacing: MobileDesign.Spacing.tight) {
                    // Decorative: the state it stands for is spelled in the words beside it, and a
                    // second reading of "Disconnected" is noise in a row VoiceOver already reads.
                    Image(systemName: session.isAvailable
                        ? "laptopcomputer"
                        : "laptopcomputer.slash")
                        .foregroundStyle(stateStyle)
                        .accessibilityHidden(true)
                    // The surface is a glyph and the runtime is the mark, because spelling both in
                    // words cost about ninety points and truncated the one fact the row gained: the
                    // line read "Connected · Claude Code UI · Ver…" while the tile was already
                    // showing Claude's mark. `terminal` here means a terminal — the runtime's own
                    // TUI, mirrored from the Mac — and the mark beside it says whose.
                    Image(systemName: session.surface == .conversation
                        ? "text.bubble"
                        : "terminal")
                        .foregroundStyle(theme.tertiaryLabel)
                        .accessibilityLabel(surfaceLabel)
                    metaText
                }
                .font(.caption2)
                .lineLimit(1)
            }

            Spacer(minLength: MobileDesign.Spacing.tight)

            HStack(spacing: MobileDesign.Spacing.tight) {
                if session.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(theme.accent)
                        .accessibilityLabel("Pinned")
                }
                if let lastActiveAt = session.lastActiveAt {
                    Text(MobileSessionAgeFormat.string(
                        since: Date(timeIntervalSince1970: lastActiveAt)
                    ))
                        .font(.caption2)
                        .foregroundStyle(theme.tertiaryLabel)
                        .fixedSize()
                }
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(theme.tertiaryLabel)
                }
            }
        }
        .padding(.horizontal, MobileDesign.Spacing.medium)
        .padding(.vertical, MobileDesign.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.panel, in: RoundedRectangle(cornerRadius: theme.panelRadius))
        .overlay(
            RoundedRectangle(cornerRadius: theme.panelRadius)
                .stroke(theme.border, lineWidth: theme.borderWidth)
        )
        .remoteThemeGlow(theme)
        .overlay(alignment: .topLeading) {
            if session.state == "needsAttention" {
                Circle()
                    .fill(theme.warning)
                    .frame(
                        width: MobileDesign.Size.rowAttentionDot,
                        height: MobileDesign.Size.rowAttentionDot
                    )
                    // On the mark's top-trailing corner: the account chip owns the other one, and
                    // both facts belong to the tile they are badging.
                    .offset(
                        x: MobileDesign.Spacing.medium
                            + MobileDesign.Size.rowMark
                            - MobileDesign.Size.rowAttentionDot / 2,
                        y: MobileDesign.Spacing.small
                            - MobileDesign.Size.rowAttentionDot / 2
                    )
            }
        }
    }

    /// The state in its own colour, then the login when it is not the CLI's default one. One `Text`,
    /// so a long account name truncates the line rather than pushing the age out of the row.
    private var metaText: Text {
        let state = Text(availabilityLabel).foregroundStyle(stateStyle)
        guard let account = session.account else { return state }
        return state + Text(" · " + account.name).foregroundStyle(theme.secondaryLabel)
    }

    private var stateStyle: Color {
        session.isAvailable && !session.isArchived ? theme.positive : theme.secondaryLabel
    }

    private var stateLabel: String {
        switch session.state {
        case "working": return MobileL10n.string("Working")
        case "needsAttention": return MobileL10n.string("Needs attention")
        // The host spells its activity over the wire with `String(describing:)`, so this is
        // `SessionActivity.limitReached` by its own name. Worth its own word here rather than
        // falling to "Connected": away from the Mac is exactly where a session that stopped
        // hours ago is discovered, and "Connected" is the reading that started this.
        case "limitReached": return MobileL10n.string("Usage limit reached")
        default: return MobileL10n.string("Connected")
        }
    }

    private var availabilityLabel: String {
        if session.isArchived { return MobileL10n.string("Archived") }
        if session.wokeAt != nil { return MobileL10n.string("Woke") }
        if session.isSnoozed() { return MobileL10n.string("Snoozed") }
        return session.isAvailable ? stateLabel : MobileL10n.string("Disconnected")
    }

    /// What you are looking at, not who is talking — the mark already says that. A terminal surface
    /// is named after the runtime's own TUI, so it can never be read as a plain shell.
    private var surfaceLabel: String {
        if session.surface == .conversation { return MobileL10n.string("Native") }
        return MobileAgentIdentity.resolve(session.agentKind).originalUITitle
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
    @State private var speedID = ""
    @State private var permissionID = ""
    /// The agent's supported UI is the safe default; Native stays an explicit experimental opt-in.
    @State private var surface = RemoteSessionSurface.terminal
    @State private var prompt = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @FocusState private var promptIsFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var launchIconAnimated = false
    @State private var promptSuggestion: String
    private let initialProjectName: String?

    private static let promptSuggestions = [
        MobileL10n.string("Hunt down the flaky test…"),
        MobileL10n.string("Make the impossible state impossible…"),
        MobileL10n.string("Polish the rough edges…"),
        MobileL10n.string("Teach this screen a new trick…"),
        MobileL10n.string("Find the bug hiding in plain sight…"),
    ]

    init(initialProjectName: String? = nil) {
        self.initialProjectName = initialProjectName
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

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: MobileDesign.Spacing.large) {
                        configurationStrip

                        if !promptIsFocused {
                            launchOverview
                                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        }

                        launchOptions

                        composer
                            .id("new-session-composer")
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: promptIsFocused) { _, isFocused in
                    guard isFocused else { return }
                    Task { @MainActor in
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
                            proxy.scrollTo("new-session-composer", anchor: .bottom)
                        }
                    }
                }
            }
            .background(theme.ground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(theme.surface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .principal) {
                    MobileCompactConnectionNavigationTitle(
                        title: MobileL10n.string("New session"),
                        status: appModel.activeHost?.name ?? MobileL10n.string("Connected"),
                        statusColor: hostStatusColor
                    )
                }
            }
            .onAppear {
                applyCatalogDefaults()
                launchIconAnimated = true
#if DEBUG
                if ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"]
                    == "new-session-multiline" {
                    prompt = "Review the keyboard lifecycle, compare the open and dismissed layouts, and summarize any remaining spacing regressions before you make changes."
                }
#endif
#if DEBUG
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
        HStack(alignment: .bottom, spacing: MobileDesign.Spacing.small) {
            promptEditor
            sendButton
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
        TextField(promptSuggestion, text: $prompt, axis: .vertical)
            .focused($promptIsFocused)
            .mobileUIEvidenceKeyboardFocus($promptIsFocused)
            .textFieldStyle(.plain)
            .font(.body)
            .lineLimit(2...6)
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
        .foregroundStyle(canSubmit ? theme.accentForeground : theme.tertiaryLabel)
        .background(canSubmit ? theme.accent : theme.controlHover, in: Circle())
        .disabled(!canSubmit)
        .accessibilityLabel("Start session")
    }

    private var launchOverview: some View {
        VStack(spacing: MobileDesign.Spacing.medium) {
            Image(systemName: surface == .conversation
                ? "bubble.left.and.bubble.right.fill"
                : "terminal.fill")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(theme.accent)
                .frame(width: 72, height: 72)
                .background(
                    theme.accentMuted,
                    in: RoundedRectangle(cornerRadius: theme.controlRadius)
                )
                .symbolEffect(
                    .bounce,
                    options: .nonRepeating,
                    value: reduceMotion ? false : launchIconAnimated
                )

            Text("Ready for a new task")
                .font(.title3.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, MobileDesign.Spacing.large)
        .accessibilityElement(children: .combine)
    }

    private var launchOptions: some View {
        VStack(alignment: .leading, spacing: MobileDesign.Spacing.small) {
            Text("Run settings")
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.secondaryLabel)
                .padding(.horizontal, MobileDesign.Spacing.tight)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: MobileDesign.Spacing.small),
                    GridItem(.flexible(), spacing: MobileDesign.Spacing.small),
                ],
                spacing: MobileDesign.Spacing.small
            ) {
                modelMenu
                reasoningMenu
                if selectedModel?.supportsFastMode == true {
                    speedMenu
                }
                if !(selectedAgent?.permissionModes ?? []).isEmpty {
                    permissionMenu
                }
            }
        }
        .padding(.bottom, MobileDesign.Spacing.medium)
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
            CompactChoiceLabel(
                symbol: surface == .conversation
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
            LaunchChoiceLabel(
                symbol: "cpu",
                caption: "Model",
                value: selectedModel?.name ?? MobileL10n.string("Default")
            )
        }
        .disabled(models.isEmpty)
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
            LaunchChoiceLabel(
                symbol: "brain.head.profile",
                caption: "Effort",
                value: selectedReasoningName
            )
        }
        .disabled(selectedModel?.reasoning.isEmpty != false)
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
            // that one row and a dial on Standard, and a label wearing it whatever is chosen
            // says Fast while the value under it says otherwise.
            LaunchChoiceLabel(
                symbol: speedID == "fast" ? "bolt.fill" : "gauge",
                caption: "Speed",
                value: speedID.isEmpty ? MobileL10n.string("Inherit") : speedID.capitalized
            )
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
            LaunchChoiceLabel(
                symbol: "hand.raised",
                caption: "Permissions",
                value: selectedPermissionName
            )
        }
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
        if projectID.isEmpty {
            projectID = initialProjectName.flatMap { name in
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
                    fastMode: speedID == "fast" ? true : (speedID == "standard" ? false : nil),
                    permissionMode: permissionID.isEmpty ? nil : permissionID,
                    surface: surface,
                    prompt: prompt
                )
                dismiss()
            } catch is CancellationError {
                return
            } catch {
                MobileDiagnostics.logDegraded(.sessionAction, error: error)
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct LaunchChoiceLabel: View {
    @Environment(\.remoteTheme) private var theme
    let symbol: String
    let caption: LocalizedStringKey
    let value: String

    var body: some View {
        HStack(spacing: MobileDesign.Spacing.small) {
            Image(systemName: symbol)
                .font(.subheadline)
                .foregroundStyle(theme.accent)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: MobileDesign.Spacing.hairline) {
                Text(caption)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(theme.secondaryLabel)
                Text(value)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            Spacer(minLength: MobileDesign.Spacing.tight)
            Image(systemName: "chevron.down")
                .font(.caption2)
                .foregroundStyle(theme.tertiaryLabel)
        }
        .padding(.horizontal, MobileDesign.Spacing.medium)
        .frame(maxWidth: .infinity, minHeight: 52)
        .background(
            theme.controlResting,
            in: RoundedRectangle(cornerRadius: theme.controlRadius)
        )
        .overlay {
            RoundedRectangle(cornerRadius: theme.controlRadius)
                .stroke(theme.border, lineWidth: theme.borderWidth)
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
