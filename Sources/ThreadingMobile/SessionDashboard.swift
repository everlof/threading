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

enum SessionOrganization: String, CaseIterable {
    case project
    case recent
    case type

    var title: String {
        switch self {
        case .project: return MobileL10n.string("By project")
        case .recent: return MobileL10n.string("Most recent")
        case .type: return MobileL10n.string("By type")
        }
    }

    var symbol: String {
        switch self {
        case .project: return "folder"
        case .recent: return "clock.arrow.circlepath"
        case .type: return "square.grid.2x2"
        }
    }
}

enum DashboardContentType: String, Hashable {
    case chats
    case terminals

    /// The heading over a plate that holds only this kind, when the list is arranged by type.
    var title: String {
        switch self {
        case .chats: return MobileL10n.string("Chats")
        case .terminals: return MobileL10n.string("Terminals")
        }
    }

    var symbol: String {
        switch self {
        case .chats: return "bubble.left.and.bubble.right"
        case .terminals: return MobileTerminalMark.symbolName
        }
    }
}

/// One row of the dashboard list, whichever kind it is.
///
/// Chats and terminals stand in one list the way they do in the Mac sidebar, told apart by their
/// mark rather than by separate plates and a heading over one of them. The dashboard builds the
/// list as values in the order the arrangement asks for, and the plate draws each row lazily.
enum DashboardRowItem: Identifiable, Equatable {
    case chat(RemoteSessionSummaryDTO)
    case terminal(RemoteProjectTerminalSummaryDTO)

    /// Distinct across kinds: a chat and a terminal never share a row identity even if the Mac
    /// ever handed both the same UUID.
    var id: String {
        switch self {
        case .chat(let session): return "chat:\(session.id)"
        case .terminal(let terminal): return "terminal:\(terminal.id)"
        }
    }

    /// The rows of a plate, each kind in its own run, runs in the order given.
    static func rows(
        sessions: [RemoteSessionSummaryDTO],
        terminals: [RemoteProjectTerminalSummaryDTO],
        order: [DashboardContentType]
    ) -> [DashboardRowItem] {
        order.flatMap { type -> [DashboardRowItem] in
            switch type {
            case .chats: return sessions.map(DashboardRowItem.chat)
            case .terminals: return terminals.map(DashboardRowItem.terminal)
            }
        }
    }
}

enum SessionTypeDirection: String, CaseIterable {
    case chatsFirst
    case terminalsFirst

    var title: String {
        switch self {
        case .chatsFirst: return MobileL10n.string("Chats first")
        case .terminalsFirst: return MobileL10n.string("Terminals first")
        }
    }

    var symbol: String {
        switch self {
        case .chatsFirst: return "bubble.left.and.bubble.right"
        case .terminalsFirst: return "terminal"
        }
    }

    var contentTypes: [DashboardContentType] {
        switch self {
        case .chatsFirst: return [.chats, .terminals]
        case .terminalsFirst: return [.terminals, .chats]
        }
    }
}

enum MobileDashboardChrome {
    static func title(projectName: String?, activeHostName: String?) -> String {
        if let projectName {
            return projectName.isEmpty ? MobileL10n.string("Other") : projectName
        }
        return activeHostName ?? MobileL10n.string("Threading Mac")
    }

    static func connectionStatus(
        phase: RemoteAppModel.Phase,
        connectionLabel: String?,
        progress: RemoteAppModel.ConnectionProgress? = nil
    ) -> String {
        switch phase {
        case .idle, .offline:
            return MobileL10n.string("Not connected")
        case .connecting:
            switch progress {
            case .tryingRoute(let kind, _, _, _):
                return MobileL10n.string(
                    "Trying %@",
                    PairedRemoteHost.connectionLabelInSentence(forEndpointKind: kind)
                )
            case .loadingSessions:
                return MobileL10n.string("Loading sessions")
            case .preparingRoutes, .none:
                return MobileL10n.string("Checking saved connections")
            }
        case .online:
            return MobileL10n.string(
                "Connected · %@",
                connectionLabel ?? MobileL10n.string("Direct")
            )
        }
    }
}

struct MobileConnectionProgressPresentation: Equatable {
    enum StepID: Equatable, Hashable {
        case routes
        case connection
        case sessions
    }

    struct Step: Equatable {
        let id: StepID
        let title: String
    }

    let currentStep: Step

    static func resolve(progress: RemoteAppModel.ConnectionProgress?) -> Self {
        switch progress ?? .preparingRoutes {
        case .preparingRoutes:
            return MobileConnectionProgressPresentation(
                currentStep: Step(
                    id: .routes,
                    title: MobileL10n.string("Checking saved connections")
                )
            )

        case .tryingRoute(let kind, _, _, _):
            let label = PairedRemoteHost.connectionLabelInSentence(forEndpointKind: kind)
            return MobileConnectionProgressPresentation(
                currentStep: Step(
                    id: .connection,
                    title: MobileL10n.string("Trying %@", label)
                )
            )

        case .loadingSessions:
            return MobileConnectionProgressPresentation(
                currentStep: Step(
                    id: .sessions,
                    title: MobileL10n.string("Loading sessions")
                )
            )
        }
    }
}

/// The production dashboard card for the current operation in the bounded connection sequence.
///
/// Keeping the card independent of `SessionDashboard` lets the DEBUG component lab render the
/// exact shipping hierarchy. The lab supplies a fixture value; the dashboard supplies the live
/// transport value.
struct MobileConnectionProgressCard: View {
    let progress: RemoteAppModel.ConnectionProgress?
    let freezesMotion: Bool

    init(
        progress: RemoteAppModel.ConnectionProgress?,
        freezesMotion: Bool = false
    ) {
        self.progress = progress
        self.freezesMotion = freezesMotion
    }

    var body: some View {
        let presentation = MobileConnectionProgressPresentation.resolve(progress: progress)
        ThemedRowGroup {
            MobileConnectionProgressStepRow(
                step: presentation.currentStep,
                freezesMotion: freezesMotion
            )
            .padding(MobileDesign.Spacing.inset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#if DEBUG
/// One authored transport checkpoint shared by the lab's body and navigation previews.
/// The list is deliberately fixed: adding a real progress case makes the lab and its test ask how
/// that case should look, without building a view for every endpoint or retry.
enum MobileConnectionProgressLabStory: String, CaseIterable, Identifiable {
    case checking
    case direct
    case fallback
    case lastRoute
    case loadingSessions

    static let defaultStory: Self = .fallback

    var id: String { rawValue }

    var title: String {
        switch self {
        case .checking: return MobileL10n.string("Checking routes")
        case .direct: return MobileL10n.string("Direct · 1/3")
        case .fallback: return MobileL10n.string("LAN · 2/3")
        case .lastRoute: return MobileL10n.string("Tailscale · 3/3")
        case .loadingSessions: return MobileL10n.string("Loading sessions")
        }
    }

    var progress: RemoteAppModel.ConnectionProgress {
        switch self {
        case .checking:
            return .preparingRoutes
        case .direct:
            return .tryingRoute(
                kind: RemoteHostEndpointKind.hosted,
                previousKind: nil,
                number: 1,
                total: 3
            )
        case .fallback:
            return .tryingRoute(
                kind: RemoteHostEndpointKind.lan,
                previousKind: RemoteHostEndpointKind.hosted,
                number: 2,
                total: 3
            )
        case .lastRoute:
            return .tryingRoute(
                kind: RemoteHostEndpointKind.tailscale,
                previousKind: RemoteHostEndpointKind.lan,
                number: 3,
                total: 3
            )
        case .loadingSessions:
            return .loadingSessions(routeKind: RemoteHostEndpointKind.lan)
        }
    }

    var navigationStatus: String {
        MobileDashboardChrome.connectionStatus(
            phase: .connecting,
            connectionLabel: nil,
            progress: progress
        )
    }
}

/// An interactive, DEBUG-only host for the two production connection-progress components.
/// It is reachable from Settings > Developer and through the `connection-progress-lab` demo scene.
struct MobileConnectionProgressLab: View {
    private enum Surface: String, CaseIterable, Identifiable {
        case both
        case navigation
        case body

        var id: String { rawValue }

        var title: String {
            switch self {
            case .both: return MobileL10n.string("Both")
            case .navigation: return MobileL10n.string("Navigation bar")
            case .body: return MobileL10n.string("Body")
            }
        }
    }

    private static let hostName = "David’s MacBook Pro"

    @Environment(\.remoteTheme) private var theme
    @State private var story = MobileConnectionProgressLabStory.defaultStory
    @State private var surface = Surface.both

    private var freezesAnimatedComponents: Bool {
        ProcessInfo.processInfo.environment["THREADING_MOBILE_UI_EVIDENCE_ID"] != nil
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MobileDesign.Spacing.pane) {
                VStack(alignment: .leading, spacing: MobileDesign.Spacing.tight) {
                    Text("Connection progress")
                        .font(.title2.bold())
                        .foregroundStyle(theme.label)
                    Text("Choose a connection step and see it in the dashboard card, the navigation bar, or both.")
                        .font(.subheadline)
                        .foregroundStyle(theme.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ThemedRowGroup {
                    pickerRow("State") {
                        Picker("State", selection: $story) {
                            ForEach(MobileConnectionProgressLabStory.allCases) { story in
                                Text(story.title).tag(story)
                            }
                        }
                    }
                    ThemedRowDivider()
                    pickerRow("Surface") {
                        Picker("Surface", selection: $surface) {
                            ForEach(Surface.allCases) { surface in
                                Text(surface.title).tag(surface)
                            }
                        }
                    }
                }

                if surface != .navigation {
                    VStack(alignment: .leading, spacing: MobileDesign.Spacing.small) {
                        Text("Dashboard body")
                            .font(.headline)
                            .foregroundStyle(theme.label)
                            .padding(.horizontal, MobileDesign.Spacing.inset)
                        MobileConnectionProgressCard(
                            progress: story.progress,
                            freezesMotion: freezesAnimatedComponents
                        )
                    }
                } else {
                    Text("The navigation component is shown above. Choose another state to check its wording and transition.")
                        .font(.footnote)
                        .foregroundStyle(theme.secondaryLabel)
                        .padding(.horizontal, MobileDesign.Spacing.inset)
                }
            }
            .padding(MobileDesign.Spacing.inset)
        }
        .background(theme.ground)
        .navigationTitle(surface == .body ? "Component Lab" : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(theme.surface, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            if surface != .body {
                ToolbarItem(placement: .principal) {
                    MobileConnectionNavigationTitle(
                        title: Self.hostName,
                        status: story.navigationStatus,
                        statusColor: theme.warning
                    )
                }
            }
        }
    }

    private func pickerRow<Control: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: MobileDesign.Spacing.medium) {
            Text(title)
                .foregroundStyle(theme.label)
            Spacer(minLength: MobileDesign.Spacing.small)
            control()
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(theme.accent)
        }
        .padding(.horizontal, MobileDesign.Spacing.inset)
        .padding(.vertical, MobileDesign.Spacing.small)
    }
}
#endif

/// The bounded, user-facing explanation for an owner dashboard that could not reach its Mac.
///
/// The transport keeps the structural cause and this value turns it into the few facts useful at
/// recovery time: what happened, the human names of the doors that were tried, and the identity
/// the phone is already paired to. Addresses, ports and Foundation error prose stay in diagnostics.
struct MobileConnectionRecoveryPresentation: Equatable {
    let title: String
    let message: String
    let lastConnection: String?
    let routesTried: [String]
    let identityCode: String?
    let primaryRecovery: RemoteConnectionFailure.Recovery
    let offersPairAgain: Bool

    static func resolve(
        failure: RemoteConnectionFailure,
        host: PairedRemoteHost?
    ) -> MobileConnectionRecoveryPresentation {
        let title: String
        switch failure.cause {
        case .addressChanged:
            title = MobileL10n.string("Pair this Mac again")
        case .pinnedIdentityMismatch:
            title = MobileL10n.string("Check this Mac’s identity")
        case .localNetworkDenied:
            title = MobileL10n.string("Allow Local Network access")
        case .upgradeRequired:
            title = MobileL10n.string("Update Threading")
        case .helloTimeout:
            title = MobileL10n.string("This Mac didn’t answer")
        case .remoteAction:
            title = MobileL10n.string("The Mac refused the request")
        case .transport:
            title = MobileL10n.string("Can’t reach this Mac")
        }

        let message = failure.cause == .transport
            ? MobileL10n.string(
                "Threading tried every saved way to reach this Mac. Make sure the Mac app is open, then try again. If it still fails, scan its current QR code."
            )
            : failure.message

        return MobileConnectionRecoveryPresentation(
            title: title,
            message: message,
            lastConnection: host?.connectionLabel,
            routesTried: host?.connectionOptionLabels ?? [],
            identityCode: host?.pinnedFingerprintCode,
            primaryRecovery: failure.recovery,
            offersPairAgain: failure.cause == .transport || failure.cause == .helloTimeout
        )
    }
}

private struct DashboardProjectSection {
    let projectName: String
    let title: String
    let sessions: [RemoteSessionSummaryDTO]
    let terminals: [RemoteProjectTerminalSummaryDTO]
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

/// The chat Share Chat was asked about, held for as long as its sheet is up.
///
/// Identified by the chat rather than by a fresh `UUID`, so re-asking about the same chat
/// reuses the presentation instead of stacking a second one on it.
struct ShareChatRequest: Identifiable {
    let session: RemoteSessionSummaryDTO

    var id: String { session.id }
}

struct SessionDashboard: View {
    @EnvironmentObject private var model: RemoteAppModel
    @EnvironmentObject private var notifications: RemoteNotificationManager
    @Environment(\.remoteTheme) private var theme
    @Environment(\.openURL) private var openURL
    @AppStorage("sessionDashboardOrganization") private var organizationRaw =
        SessionOrganization.project.rawValue
    @AppStorage("sessionDashboardTypeDirection") private var typeDirectionRaw =
        SessionTypeDirection.chatsFirst.rawValue
    @State private var searchText = ""
    @State private var isConfirmingForget = false
    @State private var themeError: String?
    @State private var pendingThemeID: String?
    @State private var showsArchived = false
    @State private var showsSnoozed = false
    @State private var showsNewSession = false
    @State private var newSessionProjectName: String?
    /// The session Start just created, held until its sheet has finished dismissing. A push
    /// ordered while the sheet is still on screen is dropped by the navigation stack, so the
    /// new chat has to open from `onDismiss` rather than from the submit that made it.
    @State private var sessionToOpenAfterStart: RemoteSessionSummaryDTO?
    @State private var renamingSession: RemoteSessionSummaryDTO?
    @State private var renameText = ""
    @State private var actionError: String?
    @State private var pendingActionSessionID: String?
    @State private var surfaceChangeRequest: SurfaceChangeRequest?
    @State private var shareRequest: ShareChatRequest?
    @State private var showsUsage = false
    private let projectName: String?
    let openSettings: () -> Void
    let reportConnectionIssue: () -> Void

    init(
        projectName: String? = nil,
        openSettings: @escaping () -> Void,
        reportConnectionIssue: @escaping () -> Void
    ) {
        self.projectName = projectName
        self.openSettings = openSettings
        self.reportConnectionIssue = reportConnectionIssue
    }

    private var organization: SessionOrganization {
        SessionOrganization(rawValue: organizationRaw) ?? .project
    }

    private var typeDirection: SessionTypeDirection {
        SessionTypeDirection(rawValue: typeDirectionRaw) ?? .chatsFirst
    }

    private var showsDemoBanner: Bool {
#if DEBUG
        // This evidence fixture borrows demo data plumbing, but represents a real failed owner
        // connection. Suppressing the demo disclaimer keeps the captured state truthful.
        if let demoMode = ProcessInfo.processInfo.environment["THREADING_MOBILE_DEMO"],
           ["sessions-offline", "sessions-connecting"].contains(demoMode) {
            return false
        }
#endif
        return model.isDemo
    }

    private var sessions: [RemoteSessionSummaryDTO] {
        let all = showsArchived
            ? model.me?.archivedSessions ?? []
            : model.me?.sessions ?? []
        let scoped = showsArchived ? all : all.filter {
            showsSnoozed ? $0.isSnoozed() : !$0.isSnoozed()
        }
        let projectScoped = projectName.map { projectName in
            scoped.filter { $0.projectName == projectName }
        } ?? scoped
        let filtered = searchText.isEmpty ? projectScoped : projectScoped.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
                || $0.projectName.localizedCaseInsensitiveContains(searchText)
        }
        return filtered.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return ($0.lastActiveAt ?? 0) > ($1.lastActiveAt ?? 0)
        }
    }

    private var terminals: [RemoteProjectTerminalSummaryDTO] {
        guard !showsArchived, !showsSnoozed else { return [] }
        let all = model.me?.terminals ?? []
        let scoped = projectName.map { name in
            all.filter { $0.projectName == name }
        } ?? all
        let filtered = searchText.isEmpty ? scoped : scoped.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
                || $0.projectName.localizedCaseInsensitiveContains(searchText)
        }
        return filtered.sorted { ($0.createdAt ?? 0) > ($1.createdAt ?? 0) }
    }

    private var groupedProjects: [DashboardProjectSection] {
        let sessionsByProject = Dictionary(grouping: sessions, by: \.projectName)
        let terminalsByProject = Dictionary(grouping: terminals, by: \.projectName)
        return Set(sessionsByProject.keys).union(terminalsByProject.keys)
            .map { name in
                DashboardProjectSection(
                    projectName: name,
                    title: name.isEmpty ? MobileL10n.string("Other") : name,
                    sessions: sessionsByProject[name] ?? [],
                    terminals: terminalsByProject[name] ?? []
                )
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        dashboardAlerts
            .toolbarBackground(theme.surface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .background(theme.ground)
    }

    private var dashboardContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MobileDesign.Spacing.pane) {
                if projectName == nil, showsDemoBanner {
                    demoBanner
                }

                if let failure = model.phase.failure {
                    connectionRecoveryCard(failure)
                }

                if model.me == nil {
                    if model.phase.failure == nil {
                        loadingCard
                    }
                } else if sessions.isEmpty, terminals.isEmpty {
                    emptyCard
                } else if organization == .type {
                    // By type is the one arrangement that separates the kinds, so it is the one
                    // that names them: a plate per kind, each under its heading, in the chosen
                    // direction. Every other arrangement stands chats and terminals in one list.
                    ForEach(typeDirection.contentTypes, id: \.self) { type in
                        typeGroup(for: type)
                    }
                } else if projectName == nil, organization == .project {
                    ForEach(groupedProjects, id: \.projectName) { project in
                        ProjectWorkGroup(
                            projectName: project.projectName,
                            title: project.title,
                            sessions: project.sessions,
                            terminals: project.terminals,
                            isArchived: showsArchived,
                            showsActions: model.canManageSessions,
                            pendingActionSessionID: pendingActionSessionID,
                            action: perform
                        )
                    }
                } else {
                    // One list, a project's chats and then its terminals — the Mac's order.
                    DashboardRowGroup(
                        rows: DashboardRowItem.rows(
                            sessions: sessions,
                            terminals: terminals,
                            order: [.chats, .terminals]
                        ),
                        showsProjectName: projectName == nil,
                        isArchived: showsArchived,
                        showsActions: model.canManageSessions,
                        pendingActionSessionID: pendingActionSessionID,
                        action: perform
                    )
                }

                // Connection recovery owns the page until this Mac has answered. Asking about
                // notifications underneath an unresolved route gives a first-run reader two
                // unrelated setup stories at once, and notifications can be enabled just as
                // safely after the catalogue arrives.
                if projectName == nil, model.me != nil, notifications.shouldOfferOnboarding {
                    NotificationOnboardingCard()
                }
            }
            // The first plate belongs to the scrolling page, not to the navigation bar. The
            // breathing room also keeps a material glow inside the viewport instead of clipping
            // it against the bar's edge.
            .padding(.top, MobileDesign.Spacing.large)
            .padding(.horizontal, MobileDesign.Spacing.large)
            .padding(.bottom, 36)
        }
    }

    /// One kind's plate under its heading, for the by-type arrangement. Nothing is drawn for a
    /// kind with no rows: a heading over an empty plate would announce an absence.
    @ViewBuilder
    private func typeGroup(for type: DashboardContentType) -> some View {
        let rows = DashboardRowItem.rows(sessions: sessions, terminals: terminals, order: [type])
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: MobileDesign.Spacing.small) {
                Label(type.title, systemImage: type.symbol)
                    .font(.headline)
                    .foregroundStyle(theme.label)
                DashboardRowGroup(
                    rows: rows,
                    showsProjectName: projectName == nil,
                    isArchived: showsArchived,
                    showsActions: model.canManageSessions,
                    pendingActionSessionID: pendingActionSessionID,
                    action: perform
                )
            }
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
        .searchable(text: $searchText, prompt: "Search sessions and terminals")
        .navigationTitle(navigationTitle)
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
        .sheet(isPresented: $showsNewSession, onDismiss: openSessionStartedFromTheSheet) {
            NewRemoteSessionView(
                initialProjectName: newSessionProjectName,
                onStarted: { sessionToOpenAfterStart = $0 }
            )
                .environmentObject(model)
                .mobileTheme(theme)
        }
        .sheet(item: $shareRequest) { request in
            ShareChatSheet(
                chatTitle: request.session.title,
                isChatRunning: request.session.isAvailable,
                mint: { role in try await mintShareLink(for: request.session, role: role) }
            )
            .mobileTheme(theme)
        }
        .sheet(isPresented: $showsUsage) {
            if let link = model.activeHost?.link {
                RemoteUsageDashboardView(link: link, isDemo: model.isDemo)
                    .mobileTheme(theme)
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
            actions: surfaceChangeActions(for: surfaceChangeRequest)
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
        if projectName == nil {
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
                    Image(systemName: "laptopcomputer")
                        .frame(
                            width: MobileDesign.Size.compactControl,
                            height: MobileDesign.Size.compactControl
                        )
                        .background(theme.controlResting, in: Circle())
                }
                .accessibilityLabel("Choose Mac")
            }
        }
        ToolbarItem(placement: .principal) {
            MobileConnectionNavigationTitle(
                title: navigationTitle,
                status: statusText,
                statusColor: statusColor
            )
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                newSessionProjectName = projectName
                showsNewSession = true
            } label: {
                Image(systemName: "plus")
                    .frame(
                        width: MobileDesign.Size.compactControl,
                        height: MobileDesign.Size.compactControl
                    )
                    .background(theme.controlResting, in: Circle())
            }
            .accessibilityLabel(
                projectName.map { MobileL10n.string("New session in %@", $0) }
                    ?? MobileL10n.string("New session")
            )

            if projectName == nil {
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

                    if organization == .type {
                        Section("Direction") {
                            ForEach(SessionTypeDirection.allCases, id: \.rawValue) { option in
                                Button {
                                    typeDirectionRaw = option.rawValue
                                } label: {
                                    Label(
                                        option.title,
                                        systemImage: typeDirection == option
                                            ? "checkmark"
                                            : option.symbol
                                    )
                                }
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
    }

    /// Opens the chat Start just created, once its sheet has gone. The Mac answers the create
    /// with the whole catalogue, so the row the stack resolves the pushed id against is already
    /// published by the time this runs; the session's own screen owns the wait for the agent.
    private func openSessionStartedFromTheSheet() {
        guard let session = sessionToOpenAfterStart else { return }
        sessionToOpenAfterStart = nil
        MobileSessionNavigationTransition.push(session, onto: model)
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
            shareRequest = .init(session: session)
        case .stopSharing:
            mutate(session) { try await model.revokeShares(for: session) }
        }
    }

    /// The same capture, for the same reason, on the surface switch.
    private func surfaceChangeActions(
        for request: SurfaceChangeRequest?
    ) -> [ThemedDialogAction] {
        guard let request else { return [] }
        return [
            ThemedDialogAction("Switch UI") {
                surfaceChangeRequest = nil
                mutate(request.session) {
                    try await model.setSurface(request.surface, for: request.session)
                }
            },
            ThemedDialogAction("Cancel", role: .cancel) { surfaceChangeRequest = nil },
        ]
    }

    /// Mints one invitation for the sheet's chosen grant.
    ///
    /// It throws rather than posting an error of its own: the sheet is the surface that asked,
    /// so the sheet is where the failure has to appear. Reporting it on the dashboard behind an
    /// open sheet is a message nobody can see.
    private func mintShareLink(
        for session: RemoteSessionSummaryDTO,
        role: ShareChatRole
    ) async throws -> SharedSessionLink {
        let response = try await model.createShare(
            for: session,
            capability: role.capability.rawValue,
            canApprovePermissions: role.canApprovePermissions
        )
        guard let url = URL(string: response.url) else {
            throw RemoteClientError.invalidResponse
        }
        return SharedSessionLink(
            sessionTitle: session.title,
            url: url,
            capability: response.capability,
            canApprovePermissions: response.canApprovePermissions,
            expiresAt: Date(timeIntervalSince1970: response.expiresAt)
        )
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

    private var navigationTitle: String {
        MobileDashboardChrome.title(
            projectName: projectName,
            activeHostName: model.activeHost?.name
        )
    }

    private var statusColor: Color {
        if case .online = model.phase { return theme.positive }
        if case .connecting = model.phase { return theme.warning }
        return theme.tertiaryLabel
    }

    private var statusText: String {
        MobileDashboardChrome.connectionStatus(
            phase: model.phase,
            connectionLabel: model.activeHost?.connectionLabel,
            progress: model.connectionProgress
        )
    }

    private var loadingCard: some View {
        MobileConnectionProgressCard(
            progress: model.connectionProgress
        )
    }

    private func connectionRecoveryCard(_ failure: RemoteConnectionFailure) -> some View {
        let presentation = MobileConnectionRecoveryPresentation.resolve(
            failure: failure,
            host: model.activeHost
        )
        return ThemedRowGroup {
            HStack(alignment: .top, spacing: MobileDesign.Spacing.medium) {
                Image(systemName: recoveryCardSymbol(for: failure.cause))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(theme.warning)
                    .frame(width: MobileDesign.Size.minimumTapTarget)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: MobileDesign.Spacing.tight) {
                    Text(presentation.title)
                        .font(.headline)
                        .foregroundStyle(theme.label)
                    Text(presentation.message)
                        .font(.subheadline)
                        .foregroundStyle(theme.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(MobileDesign.Spacing.inset)
            .frame(maxWidth: .infinity, alignment: .leading)

            if presentation.lastConnection != nil || !presentation.routesTried.isEmpty {
                ThemedRowDivider()
                VStack(alignment: .leading, spacing: MobileDesign.Spacing.small) {
                    if let lastConnection = presentation.lastConnection {
                        connectionFact(
                            MobileL10n.string("Last connected"),
                            value: lastConnection
                        )
                    }
                    if !presentation.routesTried.isEmpty {
                        connectionFact(
                            MobileL10n.string("Tried now"),
                            value: presentation.routesTried.joined(separator: " · ")
                        )
                    }
                }
                .padding(MobileDesign.Spacing.inset)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let identityCode = presentation.identityCode {
                ThemedRowDivider()
                VStack(alignment: .leading, spacing: MobileDesign.Spacing.tight) {
                    Text(MobileL10n.string("Saved identity"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.secondaryLabel)
                    Text(identityCode)
                        .font(.footnote.monospaced())
                        .foregroundStyle(theme.label)
                        .textSelection(.enabled)
                        .accessibilityLabel(
                            MobileL10n.string("Identity code %@", identityCode)
                        )
                    Text(MobileL10n.string(
                        "Compare this code with Identity Code in Threading → Settings → Remote Access on the Mac before scanning again."
                    ))
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(MobileDesign.Spacing.inset)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            ThemedRowDivider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: MobileDesign.Spacing.small) {
                    recoveryButton(
                        title: failure.recoveryTitle,
                        systemImage: recoveryButtonSymbol(for: presentation.primaryRecovery),
                        isPrimary: true
                    ) {
                        recover(from: presentation.primaryRecovery)
                    }
                    if presentation.offersPairAgain {
                        recoveryButton(
                            title: MobileL10n.string("Scan the QR code again"),
                            systemImage: "qrcode.viewfinder",
                            isPrimary: false
                        ) {
                            model.isPairing = true
                        }
                    }
                }
                VStack(spacing: MobileDesign.Spacing.small) {
                    recoveryButton(
                        title: failure.recoveryTitle,
                        systemImage: recoveryButtonSymbol(for: presentation.primaryRecovery),
                        isPrimary: true
                    ) {
                        recover(from: presentation.primaryRecovery)
                    }
                    if presentation.offersPairAgain {
                        recoveryButton(
                            title: MobileL10n.string("Scan the QR code again"),
                            systemImage: "qrcode.viewfinder",
                            isPrimary: false
                        ) {
                            model.isPairing = true
                        }
                    }
                }
            }
            .padding(MobileDesign.Spacing.inset)
            .frame(maxWidth: .infinity, alignment: .leading)

            ThemedRowDivider()
            Button(action: reportConnectionIssue) {
                Label(MobileL10n.string("Report a problem"), systemImage: "exclamationmark.bubble")
                    .font(.subheadline.weight(.semibold))
                    .frame(
                        maxWidth: .infinity,
                        minHeight: MobileDesign.Size.minimumTapTarget
                    )
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.accent)
            .padding(.horizontal, MobileDesign.Spacing.inset)
            .padding(.vertical, MobileDesign.Spacing.tight)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(MobileL10n.string("Connection recovery"))
    }

    private func connectionFact(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: MobileDesign.Spacing.hairline) {
            Text(title)
                .font(.caption)
                .foregroundStyle(theme.tertiaryLabel)
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(theme.label)
        }
        .accessibilityElement(children: .combine)
    }

    private func recoveryButton(
        title: String,
        systemImage: String,
        isPrimary: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(MobileThemedActionButtonStyle(
            kind: isPrimary ? .primary : .secondary,
            theme: theme
        ))
    }

    private func recover(from recovery: RemoteConnectionFailure.Recovery) {
        switch recovery {
        case .reconnect:
            Task { await model.refresh() }
        case .pairAgain:
            model.isPairing = true
        case .openLocalNetworkSettings:
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            openURL(url)
        case .openUpdatePage(let url):
            openURL(url)
        }
    }

    private func recoveryCardSymbol(for cause: RemoteConnectionFailure.Cause) -> String {
        switch cause {
        case .pinnedIdentityMismatch: return "exclamationmark.shield"
        case .localNetworkDenied: return "network.slash"
        case .upgradeRequired: return "arrow.down.circle"
        case .addressChanged: return "qrcode.viewfinder"
        case .helloTimeout, .remoteAction, .transport: return "wifi.exclamationmark"
        }
    }

    private func recoveryButtonSymbol(
        for recovery: RemoteConnectionFailure.Recovery
    ) -> String {
        switch recovery {
        case .reconnect: return "arrow.clockwise"
        case .pairAgain: return "qrcode.viewfinder"
        case .openLocalNetworkSettings: return "gearshape"
        case .openUpdatePage: return "arrow.down.circle"
        }
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

private struct MobileConnectionProgressStepRow: View {
    let step: MobileConnectionProgressPresentation.Step
    let freezesMotion: Bool
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        MobileConnectionProgressStepTitle(
            title: step.title,
            textColor: theme.uiLabel,
            groundColor: theme.uiPanel,
            weight: .semibold,
            freezesMotion: freezesMotion
        )
        .accessibilityElement(children: .combine)
        .accessibilityValue(MobileL10n.string("In progress"))
    }
}

/// The active step keeps its words still and lets LabelMorph's fade wave carry activity.
/// There is one bounded row and one timer while a connection is active.
private struct MobileConnectionProgressStepTitle: UIViewRepresentable {
    let title: String
    let textColor: UIColor
    let groundColor: UIColor
    let weight: UIFont.Weight
    let freezesMotion: Bool
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MobileMorphingTitleLabel {
        MobileMorphingTitleLabel()
    }

    func updateUIView(_ view: MobileMorphingTitleLabel, context: Context) {
        view.configure(
            title: title,
            textStyle: .subheadline,
            weight: weight,
            textColor: textColor,
            groundColor: groundColor,
            alignment: .left,
            // This label never morphs its words. Motion here is the separately scheduled fade.
            reducesMotion: true,
            role: .connectionProgress
        )
        context.coordinator.update(
            view: view,
            playsFade: !reducesMotion && !freezesMotion
        )
    }

    static func dismantleUIView(_ view: MobileMorphingTitleLabel, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        private weak var view: MobileMorphingTitleLabel?
        private var timer: Timer?

        func update(view: MobileMorphingTitleLabel, playsFade: Bool) {
            self.view = view
            guard playsFade else {
                stop()
                return
            }
            guard timer == nil else { return }

            let timer = Timer(
                timeInterval: MobileDesign.Motion.connectionProgressFadeCadence,
                repeats: true
            ) { [weak view] _ in
                Task { @MainActor in
                    view?.playFade()
                }
            }
            timer.tolerance = 0.1
            timer.fireDate = Date(timeIntervalSinceNow: 0.1)
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        func stop() {
            timer?.invalidate()
            timer = nil
            view?.stopFade()
        }
    }
}

/// A project's heading and, under it, its chats and terminals on one plate — the Mac sidebar's
/// arrangement, where a project's terminals stand in the same list as its chats and are told
/// apart by their mark. A "Terminals" heading used to sit over the terminals alone, so one kind
/// was labelled inside the project and the other was not.
private struct ProjectWorkGroup: View {
    let projectName: String
    let title: String
    let sessions: [RemoteSessionSummaryDTO]
    let terminals: [RemoteProjectTerminalSummaryDTO]
    let isArchived: Bool
    let showsActions: Bool
    let pendingActionSessionID: String?
    let action: (DashboardSessionAction, RemoteSessionSummaryDTO) -> Void
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink(value: MobileNavigationRoute.project(projectName)) {
                HStack(spacing: MobileDesign.Spacing.small) {
                    // One line, always. A project is a folder on the Mac, and a folder name can be
                    // anything the Mac's filesystem allows - a managed workspace carries a UUID, so
                    // the name ran to three wrapped lines and pushed the chats it heads down the
                    // screen. The header names the group; the full name is still what VoiceOver
                    // reads and what the project's own screen shows.
                    Label(title, systemImage: "folder")
                        .font(.headline)
                        .foregroundStyle(theme.label)
                        .lineLimit(1)
                    Spacer(minLength: MobileDesign.Spacing.tight)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.tertiaryLabel)
                }
                .frame(minHeight: MobileDesign.Size.minimumTapTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows this project’s sessions")
            DashboardRowGroup(
                rows: DashboardRowItem.rows(
                    sessions: sessions,
                    terminals: terminals,
                    order: [.chats, .terminals]
                ),
                showsProjectName: false,
                isArchived: isArchived,
                showsActions: showsActions,
                pendingActionSessionID: pendingActionSessionID,
                action: action
            )
        }
    }
}

/// The dashboard's rows — a project's, one kind's, or every one on the Mac — on one plate.
///
/// Every chat used to be its own card: a border, a corner radius and eight points of air per row,
/// which is a stack of panels rather than a list, and on a phone five of them filled the screen.
/// The rows now sit on one `ThemedRowGroup` and are told apart by a hairline, the way iOS's own
/// grouped tables are; the rule starts where the row's text starts, so it reads as belonging to
/// the words rather than to the card, and runs to the card's trailing edge. Chats and terminals
/// share the plate and the hairline, because they share the row.
///
/// The rows are built lazily inside the plate. A project holds a handful of rows, but the flat
/// list holds every chat and terminal on the Mac, and that list was lazy before it had a plate;
/// the plate does not take that away. An empty list draws no plate.
private struct DashboardRowGroup: View {
    let rows: [DashboardRowItem]
    let showsProjectName: Bool
    let isArchived: Bool
    let showsActions: Bool
    let pendingActionSessionID: String?
    let action: (DashboardSessionAction, RemoteSessionSummaryDTO) -> Void

    var body: some View {
        if !rows.isEmpty {
            ThemedRowGroup {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { offset, row in
                        if offset > 0 {
                            ThemedRowDivider(
                                leadingInset: DashboardRowMetrics.textLeadingEdge,
                                trailingInset: 0
                            )
                        }
                        switch row {
                        case .chat(let session):
                            SessionListItem(
                                session: session,
                                isArchived: isArchived,
                                showsActions: showsActions,
                                pendingActionSessionID: pendingActionSessionID,
                                action: action
                            )
                        case .terminal(let terminal):
                            TerminalListItem(
                                terminal: terminal,
                                showsProjectName: showsProjectName
                            )
                        }
                    }
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

    /// The one way a session's screen is opened. Tapping a row and starting a chat land here
    /// alike, so a new session is pushed with the same transition its surface would have got
    /// from the list. Pushing an id already on top is a no-op rather than a second copy.
    @MainActor
    static func push(_ session: RemoteSessionSummaryDTO, onto model: RemoteAppModel) {
        guard model.navigationPath.last != .session(session.id) else { return }
        switch forSurface(session.surface) {
        case .standard:
            model.navigationPath.append(.session(session.id))
        case .immediate:
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                model.navigationPath.append(.session(session.id))
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
    @EnvironmentObject private var model: RemoteAppModel
    @Environment(\.remoteTheme) private var theme
    /// The width the row was laid out at, so the lifted preview is the row and not a guess.
    @State private var rowWidth: CGFloat?

    @ViewBuilder
    var body: some View {
        if showsActions {
            sessionRow
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { width in
                    rowWidth = width
                }
                .contextMenu {
                    sessionActions
                } preview: {
                    liftedRow
                }
                .accessibilityHint("Long press for session actions")
        } else {
            sessionRow
        }
    }

    /// The row as the long press lifts it. A row on the shared plate paints no plate of its own,
    /// and the system's default preview would stand a transparent row on `systemBackground` — a
    /// white or black platter under an authored theme, the slab this app keeps off its screens.
    /// So the preview restates the panel the row came from, at the width it was drawn at.
    private var liftedRow: some View {
        SessionRow(session: session)
            .frame(width: rowWidth)
            .background(theme.panel, in: RoundedRectangle(cornerRadius: theme.panelRadius))
    }

    private var sessionRow: some View {
        let row: AnyView
        if isArchived {
            row = AnyView(SessionRow(session: session))
        } else {
            row = AnyView(Button(action: openSession) {
                SessionRow(session: session)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isLink)
            .accessibilityRemoveTraits(.isButton))
        }
        return AnyView(
            row
                .swipeActions(edge: .trailing, allowsFullSwipe: !isArchived) {
                    if isArchived {
                        Button {
                            action(.restore, session)
                        } label: {
                            Label("Restore", systemImage: "arrow.uturn.backward")
                        }
                        .tint(theme.accent)
                    } else if showsActions {
                        Button(role: .destructive) {
                            action(.archive, session)
                        } label: {
                            Label("Archive", systemImage: "archivebox")
                        }
                    }
                }
        )
    }

    private func openSession() {
        MobileSessionNavigationTransition.push(session, onto: model)
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

enum MobileSessionAgeFormat {
    private static let relativeCutoff: TimeInterval = 7 * 24 * 60 * 60

    /// A compact age: `6m`, `3h`, `1d`, then the date once a week has passed.
    ///
    /// The age is a column read down a list, and every row's used to end in "ago".
    /// `RelativeDateTimeFormatter` has no shorter register: its `.abbreviated` writes yesterday as
    /// a signed quantity in Swedish (`−1 d`), and `.short` spells the direction (`för 1 d sedan`,
    /// `1 day ago`), which is the verbosity being removed. So the age is set as a duration in the
    /// locale's narrowest unit — unsigned by construction, one word wide in every language — and
    /// the direction is left to the column: nothing in this list is in the future, and a clock
    /// skewed the other way reads as `now` rather than as a negative age.
    static func string(
        since date: Date,
        relativeTo now: Date = Date(),
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return MobileL10n.string("now") }
        if seconds < relativeCutoff {
            return Duration.seconds(seconds).formatted(
                .units(allowed: [.days, .hours, .minutes], width: .narrow, maximumUnitCount: 1)
                    .locale(locale)
            )
        }
        return date.formatted(.dateTime.day().month(.abbreviated).locale(locale))
    }
}

// MARK: - Dashboard Row

enum DashboardRowMetrics {
    /// Where a row's text begins: the leading inset, the mark and the gap after it. The hairline
    /// between two rows starts here, so it underlines the words rather than the tile — and it is
    /// the same edge for a chat and a terminal, because they are the same row.
    static let textLeadingEdge = MobileDesign.Spacing.medium
        + MobileDesign.Size.rowMark
        + MobileDesign.Spacing.medium
}

/// The one shape every row in the dashboard list has: a mark, a one-line title over a caption of
/// glyphs and words, and a trailing column.
///
/// A chat and a terminal are built from this rather than each drawing its own row. The terminal
/// row used to be a separate view — a circle tile with an accent glyph, a `body`-weight semibold
/// title beside the chats' `subheadline` medium, sixteen points of inset beside their twelve, a
/// spelled state word and a disclosure chevron that no chat row had. Down one list that read as
/// two products: the titles sat at two different x positions and two different ink weights, and
/// one kind of row promised a push the other kind did not. The Mac sidebar draws both kinds
/// through one row vocabulary; sharing the shape here is what keeps the phone from drifting
/// back.
///
/// **No chevron, on either kind.** Every row on the plate opens something, so a disclosure arrow
/// would say the same thing on every line; the Mac's rows do not carry one either. A chevron
/// belongs to a row that navigates *away* from a list of peers — the project heading above.
///
/// **Two lines, always.** The title takes one line and the mark does not set the height, so the
/// list is scannable and every row is the same height. The full title is one tap away.
///
/// **No plate.** The row sits on the plate its group paints, so its background is clear and its
/// whole rectangle is still the tap: without a fill of its own, the air between the caption and
/// the trailing column would otherwise fall through to nothing.
private struct DashboardRow<Mark: View, Caption: View, Trailing: View>: View {
    let title: String
    @ViewBuilder let mark: () -> Mark
    @ViewBuilder let caption: () -> Caption
    @ViewBuilder let trailing: () -> Trailing
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        HStack(spacing: MobileDesign.Spacing.medium) {
            mark()

            VStack(alignment: .leading, spacing: MobileDesign.Spacing.hairline) {
                MobileMorphingTitle(
                    title: title,
                    textStyle: .subheadline,
                    weight: .medium,
                    textColor: theme.uiLabel,
                    groundColor: theme.uiPanel,
                    alignment: .left
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: MobileDesign.Spacing.tight) {
                    caption()
                }
                .font(.caption2)
                .lineLimit(1)
            }

            Spacer(minLength: MobileDesign.Spacing.tight)

            HStack(spacing: MobileDesign.Spacing.tight) {
                trailing()
            }
        }
        .padding(.horizontal, MobileDesign.Spacing.medium)
        .padding(.vertical, MobileDesign.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// The caption's first glyph on every row: the laptop, green when the thing is running on the Mac
/// and slashed when it is not. Green means connected and the slash means not; the glyph is the
/// state, so it speaks the whole state for VoiceOver rather than hiding.
private struct DashboardAvailabilityGlyph: View {
    let isAvailable: Bool
    let label: String
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        Image(systemName: isAvailable ? "laptopcomputer" : "laptopcomputer.slash")
            .foregroundStyle(isAvailable ? theme.positive : theme.secondaryLabel)
            .accessibilityLabel(label)
    }
}

/// The trailing column's working mark. Matches the Mac sidebar's compact working spinner: the
/// orb remains available for the conversation title, but a list status mark should be quiet and
/// scannable rather than a second, more expressive animation. Hidden from VoiceOver because the
/// availability glyph already says "Working".
private struct DashboardWorkingIndicator: View {
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        Group {
            if ProcessInfo.processInfo.environment["THREADING_MOBILE_UI_EVIDENCE_ID"] != nil {
                Circle()
                    .trim(from: 0, to: 0.72)
                    .stroke(theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(theme.accent)
            }
        }
        .frame(
            width: MobileDesign.Size.rowWorkingOrb,
            height: MobileDesign.Size.rowWorkingOrb
        )
        .accessibilityHidden(true)
    }
}

/// The trailing column's age, set the way `MobileSessionAgeFormat` sets it.
private struct DashboardAge: View {
    let date: Date
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        Text(MobileSessionAgeFormat.string(since: date))
            .font(.caption2)
            .foregroundStyle(theme.tertiaryLabel)
            .fixedSize()
    }
}

// MARK: - Terminal Row

/// What a terminal row shows for the state the wire sends, resolved once so the row and its tests
/// read the same answer.
///
/// The state is shown the way a chat's is, not spelled: the laptop glyph says running or not, the
/// tile dims for a shell that is not running, and a busy shell shows the working mark in the
/// trailing column. The words "Ready" and "Stopped" that used to sit in that column said what the
/// glyph beside them already said; they survive as the whole state for VoiceOver.
struct MobileTerminalRowPresentation: Equatable {
    /// Foreground work in a running shell: the trailing column shows the working mark.
    let isWorking: Bool
    /// Not running on the Mac: the tile dims and the laptop is slashed.
    let isDimmed: Bool
    /// The whole state in words, for VoiceOver.
    let availabilityLabel: String

    static func resolve(state: String, isAvailable: Bool) -> Self {
        let isWorking = isAvailable && state == "working"
        let label: String
        if isWorking {
            label = MobileL10n.string("Working")
        } else if isAvailable {
            label = MobileL10n.string("Ready")
        } else {
            label = MobileL10n.string("Stopped")
        }
        return Self(isWorking: isWorking, isDimmed: !isAvailable, availabilityLabel: label)
    }
}

/// One standalone terminal in the dashboard list: the same row as a chat, with the terminal mark
/// where a chat shows its runtime's, and its project's name in the caption when the list spans
/// projects. It has no login, no surface choice and no last-active time of its own, so its caption
/// and trailing column carry only what it has.
private struct TerminalRow: View {
    let terminal: RemoteProjectTerminalSummaryDTO
    let showsProjectName: Bool
    @Environment(\.remoteTheme) private var theme

    private var presentation: MobileTerminalRowPresentation {
        .resolve(state: terminal.state, isAvailable: terminal.isAvailable)
    }

    var body: some View {
        DashboardRow(title: terminal.title) {
            MobileTerminalMark(isDimmed: presentation.isDimmed)
        } caption: {
            DashboardAvailabilityGlyph(
                isAvailable: !presentation.isDimmed,
                label: presentation.availabilityLabel
            )
            if showsProjectName {
                Text(terminal.projectName)
                    .foregroundStyle(theme.secondaryLabel)
            }
        } trailing: {
            if presentation.isWorking {
                DashboardWorkingIndicator()
            }
        }
    }
}

/// The terminal row as a tap. A terminal transition cannot manufacture intermediate widths, so the
/// push is immediate — the same answer `MobileSessionNavigationTransition` gives a chat on its
/// terminal surface.
private struct TerminalListItem: View {
    let terminal: RemoteProjectTerminalSummaryDTO
    let showsProjectName: Bool
    @EnvironmentObject private var model: RemoteAppModel

    var body: some View {
        Button(action: openTerminal) {
            TerminalRow(terminal: terminal, showsProjectName: showsProjectName)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isLink)
        .accessibilityRemoveTraits(.isButton)
        .accessibilityHint(MobileL10n.string("Opens this terminal on your Mac"))
    }

    private func openTerminal() {
        guard model.navigationPath.last != .terminal(terminal.id) else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            model.navigationPath.append(.terminal(terminal.id))
        }
    }
}

// MARK: - Session Row

/// One chat in the dashboard list.
///
/// **The tile identifies the runtime, not the surface.** Every row used to draw `terminal`, because
/// a natively rendered conversation is still the experimental opt-in and everything else is the
/// agent's own TUI mirrored from the Mac — so a list of Claude and Codex chats looked like a list of
/// shells, and said nothing about which provider or which login each one was on. It now carries the
/// same two facts the Mac sidebar carries, the same way: the provider's mark, with an alternate
/// account's chip on its corner. `MobileAgentIdentity` holds that vocabulary. The row's shape —
/// two lines, no plate, no chevron — is `DashboardRow`'s, shared with the terminal row.
///
/// **State is shown, not spelled.** The caption used to read "Working", "Connected",
/// "Disconnected" beside a laptop that was already green or slashed, so every row said its state
/// twice and the words crowded out the one fact the caption has that nothing else carries: the
/// login. Now the laptop alone says connected (green) or not (slashed), the amber dot on the tile
/// says attention, and a chat that is working shows the orb at its trailing edge, in the age's
/// place — motion reads from across the room, and a working chat's age is "now" by definition.
/// The two states no glyph carries — a session that woke from its snooze, and one stopped at a
/// usage limit — keep their word, in the warning colour, because each is a reason to look. The
/// laptop carries the whole state for VoiceOver, so nothing a sighted reader sees is unsaid.
private struct SessionRow: View {
    let session: RemoteSessionSummaryDTO
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        DashboardRow(title: session.title) {
            MobileSessionMark(
                agentKind: session.agentKind,
                account: session.account,
                isDimmed: !session.isAvailable || session.isArchived
            )
            // On the tile's top-trailing corner, centred on its edge: the account chip owns the
            // other corner, and both facts belong to the tile they are badging. Hung on the tile
            // rather than on the row so the row's height never moves it.
            .overlay(alignment: .topTrailing) {
                if session.state == "needsAttention" {
                    Circle()
                        .fill(theme.warning)
                        .frame(
                            width: MobileDesign.Size.rowAttentionDot,
                            height: MobileDesign.Size.rowAttentionDot
                        )
                        .offset(
                            x: MobileDesign.Offset.rowAttentionDotOverhang,
                            y: -MobileDesign.Offset.rowAttentionDotOverhang
                        )
                }
            }
        } caption: {
            DashboardAvailabilityGlyph(
                isAvailable: session.isAvailable && !session.isArchived,
                label: availabilityLabel
            )
            // The surface is a glyph and the runtime is the mark, because spelling both in
            // words cost about ninety points and truncated the one fact the row gained: the
            // line read "Connected · Claude Code UI · Ver…" while the tile was already
            // showing Claude's mark. `terminal` here means a terminal — the runtime's own
            // TUI, mirrored from the Mac — and the mark beside it says whose.
            Image(systemName: session.surface == .conversation
                ? "text.bubble"
                : MobileTerminalMark.symbolName)
                .foregroundStyle(theme.tertiaryLabel)
                .accessibilityLabel(surfaceLabel)
            if let metaText {
                metaText
            }
        } trailing: {
            if session.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(theme.accent)
                    .accessibilityLabel("Pinned")
            }
            if isWorking {
                DashboardWorkingIndicator()
            } else if let lastActiveAt = session.lastActiveAt {
                DashboardAge(date: Date(timeIntervalSince1970: lastActiveAt))
            }
        }
    }

    /// Mid-turn on a live surface. The Mac reports activity only for a session it is running, but
    /// an animation claims "moving right now", so it also asks that there is somewhere to attach.
    private var isWorking: Bool {
        session.isAvailable && !session.isArchived && session.state == "working"
    }

    /// The caption's words: the state only when no glyph carries it, then the login when it is
    /// not the CLI's default one. One `Text`, so a long account name truncates the line rather
    /// than pushing the age out of the row; nil when there is nothing to say.
    private var metaText: Text? {
        var parts: [Text] = []
        if let word = spelledStateLabel {
            parts.append(Text(word).foregroundStyle(theme.warning))
        }
        if let account = session.account {
            parts.append(Text(account.name).foregroundStyle(theme.secondaryLabel))
        }
        guard let first = parts.first else { return nil }
        return parts.dropFirst().reduce(first) { line, part in
            // localization-ignore: punctuation between already-localized metadata fragments
            line + Text(verbatim: " · ").foregroundStyle(theme.secondaryLabel) + part
        }
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

    /// The whole state in words, for VoiceOver: what the laptop's colour, the dot and the orb
    /// show a sighted reader.
    private var availabilityLabel: String {
        if session.isArchived { return MobileL10n.string("Archived") }
        if session.wokeAt != nil { return MobileL10n.string("Woke") }
        if session.isSnoozed() { return MobileL10n.string("Snoozed") }
        return session.isAvailable ? stateLabel : MobileL10n.string("Disconnected")
    }

    /// The states worth a word in the caption: the ones no glyph on the row carries. Archived and
    /// snoozed rows live in lists whose header already says so.
    private var spelledStateLabel: String? {
        if session.isArchived { return nil }
        if session.wokeAt != nil { return MobileL10n.string("Woke") }
        if session.isAvailable, session.state == "limitReached" {
            return MobileL10n.string("Usage limit reached")
        }
        return nil
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
    /// Handed the session Start created, for the presenter to open once this sheet is gone.
    private let onStarted: (RemoteSessionSummaryDTO) -> Void

    private static let promptSuggestions = [
        MobileL10n.string("Hunt down the flaky test…"),
        MobileL10n.string("Make the impossible state impossible…"),
        MobileL10n.string("Polish the rough edges…"),
        MobileL10n.string("Teach this screen a new trick…"),
        MobileL10n.string("Find the bug hiding in plain sight…"),
    ]

    init(
        initialProjectName: String? = nil,
        onStarted: @escaping (RemoteSessionSummaryDTO) -> Void = { _ in }
    ) {
        self.initialProjectName = initialProjectName
        self.onStarted = onStarted
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
                    MobileConnectionNavigationTitle(
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
                // Starting a chat is a request to be in it. The push waits for the sheet to
                // finish dismissing; see the presenter's `onDismiss`.
                onStarted(session)
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
