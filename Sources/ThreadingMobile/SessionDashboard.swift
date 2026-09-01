import SwiftUI
import ThreadingRemoteKit

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
            deadline: now.addingTimeInterval(3600)
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
        case let .chat(session): return "chat:\(session.id)"
        case let .terminal(terminal): return "terminal:\(terminal.id)"
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
        case .idle:
            return MobileL10n.string("Not connected")
        case .offline:
            if case .waitingToRetry = progress {
                return MobileL10n.string("Trying again…")
            }
            return MobileL10n.string("Not connected")
        case .connecting:
            switch progress {
            case let .tryingRoute(kind, _, _, _):
                return MobileL10n.string(
                    "Trying %@",
                    PairedRemoteHost.connectionLabelInSentence(forEndpointKind: kind)
                )
            case .loadingSessions:
                return MobileL10n.string("Loading sessions")
            case .waitingToRetry:
                return MobileL10n.string("Trying again…")
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

/// The dashboard's system menu is a directory, not the full contents of every directory.
///
/// UIKit does not give the app a reliable scrolling contract for an over-height `Menu`: a
/// vertical drag can dismiss the menu and continue into the dashboard underneath it. Keep the
/// root cardinality fixed while capabilities add or remove whole destinations; each destination
/// owns either a short submenu or an existing virtualized surface, so no row depends on that
/// private scroll path.
enum MobileDashboardMenuDestination: CaseIterable, Hashable {
    case organize
    case sessions
    case appearance
    case usage
    case settings
    case macs

    static func available(
        canManageSessions: Bool,
        canManageThemes: Bool,
        canReadUsage: Bool
    ) -> [Self] {
        allCases.filter { destination in
            switch destination {
            case .sessions:
                canManageSessions
            case .appearance:
                canManageThemes
            case .usage:
                canReadUsage
            case .organize, .settings, .macs:
                true
            }
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

        case let .tryingRoute(kind, _, _, _):
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

        case .waitingToRetry:
            return MobileConnectionProgressPresentation(
                currentStep: Step(
                    id: .connection,
                    title: MobileL10n.string("Connection interrupted. Trying again…")
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
        case retrying

        static let defaultStory: Self = .fallback

        var id: String { rawValue }

        var title: String {
            switch self {
            case .checking: return MobileL10n.string("Checking routes")
            case .direct: return MobileL10n.string("Direct · 1/3")
            case .fallback: return MobileL10n.string("LAN · 2/3")
            case .lastRoute: return MobileL10n.string("Tailscale · 3/3")
            case .loadingSessions: return MobileL10n.string("Loading sessions")
            case .retrying: return MobileL10n.string("Trying again…")
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
            case .retrying:
                return .waitingToRetry(attempt: 1)
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

extension MobileConnectionRecoveryPolicy {
    /// Failures with a different next step cannot improve through another route race and are
    /// disclosed immediately. Ordinary reachability/hello misses stay in compact retry chrome
    /// until repeated complete attempts make the full recovery surface truthful.
    static func presentsFullRecovery(
        for failure: RemoteConnectionFailure,
        attempt: Int
    ) -> Bool {
        failure.recovery != .reconnect || attempt >= settledFailureAttempt
    }
}

enum MobileConnectionRecoveryDisplay {
    /// Presentation hysteresis for the page-sized recovery card.
    ///
    /// A disclosed failure survives `.connecting` because that is the automatic attempt already
    /// promised by the status line. Only success (or leaving connection ownership altogether)
    /// removes it; a new settled failure replaces its details in place.
    static func updatedFailure(
        current: RemoteConnectionFailure?,
        phase: RemoteAppModel.Phase,
        attempt: Int
    ) -> RemoteConnectionFailure? {
        switch phase {
        case .online, .idle:
            return nil
        case .connecting:
            return current
        case let .offline(failure):
            return MobileConnectionRecoveryPolicy.presentsFullRecovery(
                for: failure,
                attempt: attempt
            ) ? failure : current
        }
    }
}

private struct DashboardProjectSection {
    let projectName: String
    let title: String
    let sessions: [RemoteSessionSummaryDTO]
    let terminals: [RemoteProjectTerminalSummaryDTO]
}

enum MobileSessionOrdering {
    static func sorted(
        _ sessions: [RemoteSessionSummaryDTO],
        archived: Bool
    ) -> [RemoteSessionSummaryDTO] {
        if archived {
            return sessions.sorted {
                let lhsDate = $0.archivedAt ?? $0.lastActiveAt ?? 0
                let rhsDate = $1.archivedAt ?? $1.lastActiveAt ?? 0
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                return $0.id < $1.id
            }
        }
        return sessions.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return ($0.lastActiveAt ?? 0) > ($1.lastActiveAt ?? 0)
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
    @State private var isConfirmingForget = false
    @State private var showsArchived = false
    @State private var showsSnoozed = false
    @State private var renamingSession: RemoteSessionSummaryDTO?
    @State private var renameText = ""
    @State private var actionError: String?
    /// Per-session rather than global: filing several rows quickly must not make every later
    /// archive press wait behind the first provider command.
    @State private var pendingActionSessionIDs = Set<String>()
    /// Rows removed at the press edge while the Mac stops the process and synchronizes any
    /// provider archive. Failure drops the identity and puts that exact row back.
    @State private var optimisticallyHiddenSessionIDs = Set<String>()
    @State private var surfaceChangeRequest: SurfaceChangeRequest?
    @State private var shareRequest: ShareChatRequest?
    @State private var showsAppearance = false
    @State private var showsUsage = false
    @State private var showsUniversalSearch = false
    /// Once disclosed, recovery stays put while the next automatic attempt runs. Clearing it on
    /// `.connecting` made the full card and the compact progress card replace each other on every
    /// backoff tick — the page-sized flicker this state deliberately prevents.
    @State private var disclosedConnectionFailure: RemoteConnectionFailure?
    private let projectName: String?
    private let projectID: String?
    let openSettings: () -> Void
    let reportConnectionIssue: () -> Void

    init(
        projectName: String? = nil,
        projectID: String? = nil,
        openSettings: @escaping () -> Void,
        reportConnectionIssue: @escaping () -> Void
    ) {
        self.projectName = projectName
        self.projectID = projectID
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
            if let demoMode = ProcessInfo.processInfo.environment[MobileDemoScene.environmentKey],
               ["sessions-offline", "sessions-connecting"].contains(demoMode)
               || MobileDemoFixture.isMarketing(demoMode)
            {
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
        let projectScoped: [RemoteSessionSummaryDTO]
        if let projectID {
            projectScoped = scoped.filter {
                $0.projectID == projectID
                    || ($0.projectID == nil && $0.projectName == projectName)
            }
        } else if let projectName {
            projectScoped = scoped.filter { $0.projectName == projectName }
        } else {
            projectScoped = scoped
        }
        let visible = projectScoped.filter {
            !optimisticallyHiddenSessionIDs.contains($0.id)
                && !model.archiveMutationSessionIDs.contains($0.id)
        }
        return MobileSessionOrdering.sorted(visible, archived: showsArchived)
    }

    private var terminals: [RemoteProjectTerminalSummaryDTO] {
        guard !showsArchived, !showsSnoozed else { return [] }
        let all = model.me?.terminals ?? []
        let scoped: [RemoteProjectTerminalSummaryDTO]
        if let projectID {
            scoped = all.filter {
                $0.projectID == projectID
                    || ($0.projectID == nil && $0.projectName == projectName)
            }
        } else if let projectName {
            scoped = all.filter { $0.projectName == projectName }
        } else {
            scoped = all
        }
        return scoped.sorted { ($0.createdAt ?? 0) > ($1.createdAt ?? 0) }
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
            // Keep visibility automatic. On iOS 26, forcing this background visible makes its
            // scroll-edge plate retain the pull-to-refresh height and cover the session rows.
            .toolbarBackground(theme.surface, for: .navigationBar)
            .background(theme.ground)
    }

    @ViewBuilder
    private var dashboardContent: some View {
        if #available(iOS 26.0, *) {
            dashboardScrollView
                // The automatic top-edge effect can retain the released pull distance after the
                // refresh finishes. The navigation bar already owns this edge's themed surface.
                .scrollEdgeEffectHidden(true, for: .top)
        } else {
            dashboardScrollView
        }
    }

    private var dashboardScrollView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MobileDesign.Spacing.pane) {
                let visibleFailure = visibleConnectionFailure
                let showsConnectionNotice = visibleFailure != nil || model.phase.failure != nil

                if projectName == nil, showsDemoBanner {
                    demoBanner
                }

                if let failure = visibleFailure {
                    connectionRecoveryCard(failure)
                } else if model.phase.failure != nil {
                    // Automatic recovery is already scheduled. Keep the compact progress
                    // anatomy and state that fact rather than flashing the full error card.
                    loadingCard
                }

                if model.me == nil {
                    if !showsConnectionNotice {
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
                            action: perform,
                            startNewSession: model.canManageSessions && !showsArchived
                                ? { startDraft(in: project.projectName) }
                                : nil
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
                        action: perform
                    )
                }

                // Connection recovery owns the page until this Mac has answered. Asking about
                // notifications underneath an unresolved route gives a first-run reader two
                // unrelated setup stories at once, and notifications can be enabled just as
                // safely after the catalogue arrives.
                if projectName == nil, model.me != nil, shouldOfferNotificationOnboarding {
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

    private var shouldOfferNotificationOnboarding: Bool {
        #if DEBUG
            if MobileDemoFixture.isMarketing(
                ProcessInfo.processInfo.environment[MobileDemoScene.environmentKey]
            ) {
                return false
            }
        #endif
        return notifications.shouldOfferOnboarding
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
            .safeAreaInset(edge: .bottom, spacing: 0) { dashboardFloatingBar }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { dashboardToolbar }
            .task(id: model.activeHostID) { await model.activateDashboard() }
            .onChange(of: model.phase) { _, _ in
                updateConnectionFailurePresentation()
            }
            .onChange(of: model.connectionRecoveryAttempt) { _, _ in
                updateConnectionFailurePresentation()
            }
            .onChange(of: model.activeHostID) { _, _ in
                disclosedConnectionFailure = nil
            }
            .onAppear {
                updateConnectionFailurePresentation()
                #if DEBUG
                    if model.isDemo,
                       ProcessInfo.processInfo.environment[MobileDemoScene.environmentKey]?
                       .hasPrefix("usage") == true
                    {
                        showsUsage = true
                    }
                #endif
            }
    }

    private var dashboardSheets: some View {
        dashboardNavigation
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
            .sheet(isPresented: $showsAppearance) {
                NavigationStack {
                    MacAppearanceSettingsView()
                }
                .mobileTheme(theme)
            }
            .sheet(isPresented: $showsUniversalSearch) {
                NavigationStack {
                    MobileUniversalSearchView(
                        initialScope: universalSearchScope
                    ) { route in
                        model.navigationPath.append(route)
                    }
                }
                .mobileTheme(theme)
            }
    }

    private var universalSearchScope: MobileUniversalSearchScope {
        guard let projectName else { return .everywhere }
        if let projectID { return .project(id: projectID, name: projectName) }
        let matches = model.me?.newSessionCatalog?.projects.filter { $0.name == projectName } ?? []
        guard matches.count == 1, let project = matches.first else { return .everywhere }
        return .project(id: project.id, name: project.name)
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
                "Remote action failed",
                message: actionError ?? model.archiveMutationError ?? "",
                isPresented: Binding(
                    get: { actionError != nil || model.archiveMutationError != nil },
                    set: {
                        if !$0 {
                            actionError = nil
                            model.clearArchiveMutationFailure()
                        }
                    }
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
                .accessibilityLabel(MobileL10n.string("Choose Mac"))
            }
        }
        ToolbarItem(placement: .principal) {
            MobileConnectionStatusButton(
                title: navigationTitle,
                status: statusText,
                statusColor: statusColor
            )
        }
        if projectName == nil {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(dashboardMenuDestinations, id: \.self) { destination in
                        dashboardMenuItem(destination)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(
                            width: MobileDesign.Size.compactControl,
                            height: MobileDesign.Size.compactControl
                        )
                        .background(theme.controlResting, in: Circle())
                }
                .accessibilityLabel(MobileL10n.string("Remote access options"))
            }
        }
    }

    /// Search and the chat starter, floating at the page's bottom edge.
    ///
    /// Both lived in the navigation bar for a while, which crowded the Mac's name out of its
    /// own title and put the two most-used actions furthest from the thumb. The bar owns no
    /// plate: each pill stands on the theme's opaque floating surface (the chat starter on the
    /// accent), so rows scroll under them the way content passes under any floating control.
    private var dashboardFloatingBar: some View {
        HStack(spacing: MobileDesign.Spacing.small) {
            if model.canUseUniversalSearch {
                Button {
                    showsUniversalSearch = true
                } label: {
                    HStack(spacing: MobileDesign.Spacing.small) {
                        Image(systemName: "magnifyingglass")
                        Text(MobileL10n.string("Search"))
                        Spacer(minLength: 0)
                    }
                    .font(.body)
                    .foregroundStyle(theme.secondaryLabel)
                    .padding(.horizontal, MobileDesign.Spacing.large)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: MobileDesign.Size.floatingBarControl
                    )
                    .background(theme.floatingSurface, in: Capsule())
                    .overlay(
                        Capsule().strokeBorder(
                            theme.border,
                            lineWidth: max(theme.borderWidth, 1)
                        )
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("f", modifiers: .command)
            } else {
                Spacer(minLength: 0)
            }

            Button {
                startDraft(in: projectName)
            } label: {
                HStack(spacing: MobileDesign.Spacing.small) {
                    Image(systemName: "plus")
                    Text(MobileL10n.string("New"))
                }
                .font(.headline)
                .foregroundStyle(theme.accentForeground)
                .padding(.horizontal, MobileDesign.Spacing.large)
                .frame(minHeight: MobileDesign.Size.floatingBarControl)
                .background(theme.accent, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                projectName.map { MobileL10n.string("New session in %@", $0) }
                    ?? MobileL10n.string("New session")
            )
        }
        .padding(.horizontal, MobileDesign.Spacing.large)
        .padding(.top, MobileDesign.Spacing.small)
        .padding(.bottom, MobileDesign.Spacing.small)
    }

    private var dashboardMenuDestinations: [MobileDashboardMenuDestination] {
        MobileDashboardMenuDestination.available(
            canManageSessions: model.canManageSessions,
            canManageThemes: model.canManageThemes,
            canReadUsage: model.canReadUsage
        )
    }

    @ViewBuilder
    private func dashboardMenuItem(_ destination: MobileDashboardMenuDestination) -> some View {
        switch destination {
        case .organize:
            Menu {
                ForEach(SessionOrganization.allCases, id: \.rawValue) { option in
                    Button {
                        organizationRaw = option.rawValue
                    } label: {
                        Label(
                            option.title,
                            systemImage: organization == option ? "checkmark" : option.symbol
                        )
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
            } label: {
                Label("Organize", systemImage: "arrow.up.arrow.down")
            }

        case .sessions:
            Menu {
                Button {
                    showsArchived = false
                    showsSnoozed.toggle()
                } label: {
                    Label(
                        MobileL10n.string(
                            showsSnoozed ? "Active sessions" : "Snoozed sessions"
                        ),
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
            } label: {
                Label("Sessions", systemImage: "tray.full")
            }

        case .appearance:
            Button {
                showsAppearance = true
            } label: {
                Label("Appearance", systemImage: "paintpalette")
            }

        case .usage:
            Button {
                showsUsage = true
            } label: {
                Label("Usage", systemImage: "chart.bar.xaxis")
            }

        case .settings:
            Button {
                openSettings()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }

        case .macs:
            Menu {
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
                Label("Macs", systemImage: "laptopcomputer")
            }
        }
    }

    private func startDraft(in projectName: String?) {
        MobileSessionNavigationTransition.draft(in: projectName, onto: model)
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
            mutate(session, optimisticallyHides: true) {
                try await model.setArchived(true, for: session)
            }
        case .restore:
            mutate(session, optimisticallyHides: true) {
                try await model.setArchived(false, for: session)
            }
        case let .snooze(deadline):
            mutate(session) { try await model.setSnoozed(until: deadline, for: session) }
        case let .surface(surface):
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
            capability: role.capability,
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
        optimisticallyHides: Bool = false,
        operation: @escaping @MainActor () async throws -> Void
    ) {
        guard pendingActionSessionIDs.insert(session.id).inserted else { return }
        if optimisticallyHides {
            optimisticallyHiddenSessionIDs.insert(session.id)
        }
        Task {
            defer {
                pendingActionSessionIDs.remove(session.id)
                optimisticallyHiddenSessionIDs.remove(session.id)
            }
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

    private var visibleConnectionFailure: RemoteConnectionFailure? {
        if let disclosedConnectionFailure { return disclosedConnectionFailure }
        guard let failure = model.phase.failure,
              MobileConnectionRecoveryPolicy.presentsFullRecovery(
                  for: failure,
                  attempt: model.connectionRecoveryAttempt
              ) else { return nil }
        return failure
    }

    private func updateConnectionFailurePresentation() {
        disclosedConnectionFailure = MobileConnectionRecoveryDisplay.updatedFailure(
            current: disclosedConnectionFailure,
            phase: model.phase,
            attempt: model.connectionRecoveryAttempt
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
        case let .openUpdatePage(url):
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

    func makeUIView(context _: Context) -> MobileMorphingTitleLabel {
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

    static func dismantleUIView(_: MobileMorphingTitleLabel, coordinator: Coordinator) {
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

/// Starts a chat: the plus on each project heading.
///
/// It carries no caption. The word sat next to a plus in a header that already names the
/// project, which said the same thing twice and pushed the folder name into truncation on a
/// phone-width row; the glyph alone says start, at the same size and on the same disc as the
/// toolbar's circles.
struct NewSessionButton: View {
    let accessibilityLabel: String
    let action: () -> Void
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .frame(
                    width: MobileDesign.Size.compactControl,
                    height: MobileDesign.Size.compactControl
                )
                .background(theme.controlResting, in: Circle())
                .contentShape(Circle())
        }
        .accessibilityLabel(accessibilityLabel)
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
    let action: (DashboardSessionAction, RemoteSessionSummaryDTO) -> Void
    /// Starts a chat in this project from its heading. `nil` for a share that may not manage
    /// sessions, and for the archive, where nothing is started.
    var startNewSession: (() -> Void)? = nil
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: MobileDesign.Spacing.small) {
                NavigationLink(value: MobileNavigationRoute.project(projectName)) {
                    HStack(spacing: MobileDesign.Spacing.tight) {
                        // One line, always. A project is a folder on the Mac, and a folder name
                        // can be anything the Mac's filesystem allows - a managed workspace
                        // carries a UUID, so the name ran to three wrapped lines and pushed the
                        // chats it heads down the screen. The header names the group; the full
                        // name is still what VoiceOver reads and what the project's own screen
                        // shows.
                        Label(title, systemImage: "folder")
                            .font(.headline)
                            .foregroundStyle(theme.label)
                            .lineLimit(1)
                        // Beside the name rather than at the far edge: the chevron says the
                        // name opens something, and the far edge is where the plus stands.
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(theme.tertiaryLabel)
                    }
                    .frame(minHeight: MobileDesign.Size.minimumTapTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(MobileL10n.string("Shows this project’s sessions"))
                Spacer(minLength: MobileDesign.Spacing.tight)
                if let startNewSession {
                    NewSessionButton(
                        accessibilityLabel: MobileL10n.string("New session in %@", projectName),
                        action: startNewSession
                    )
                }
            }
            DashboardRowGroup(
                rows: DashboardRowItem.rows(
                    sessions: sessions,
                    terminals: terminals,
                    order: [.chats, .terminals]
                ),
                showsProjectName: false,
                isArchived: isArchived,
                showsActions: showsActions,
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
                        case let .chat(session):
                            SessionListItem(
                                session: session,
                                isArchived: isArchived,
                                showsActions: showsActions,
                                action: action
                            )
                        case let .terminal(terminal):
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

enum MobileSessionNavigationTransition {
    /// The one way a session's screen is opened by id. A row, a notification and a restored
    /// route land here alike. Pushing the session already on top is a no-op rather than a
    /// second copy — including when the top screen is the draft that started it, which the
    /// model resolves to the same id. Terminal layout stability belongs to its UIKit host, so
    /// both terminal and Native destinations retain the ordinary system navigation transition.
    @MainActor
    static func push(_ session: RemoteSessionSummaryDTO, onto model: RemoteAppModel) {
        guard model.openSessionID != session.id else { return }
        model.navigationPath.append(.session(session.id))
    }

    /// Starting a chat is navigation, not presentation. The draft is pushed like any other
    /// screen, and when Start is answered it becomes the session's screen where it stands
    /// (`SessionDraftView`), so nothing is dismissed and nothing is pushed a second time.
    @MainActor
    static func draft(in projectName: String?, onto model: RemoteAppModel) {
        model.navigationPath.append(.draft(MobileSessionDraft(projectName: projectName)))
    }
}

private struct SessionListItem: View {
    let session: RemoteSessionSummaryDTO
    let isArchived: Bool
    let showsActions: Bool
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
                .accessibilityHint(MobileL10n.string("Long press for session actions"))
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

    /// The row is deliberately not a `Button`: a swipeable row's tap belongs to the swipe seam,
    /// which fails it the moment the finger travels. A button would open this chat at the end of
    /// every swipe — see ``View/mobileRowSwipeAction(_:allowsFullSwipe:activate:)``. The traits
    /// the button used to publish are stated here instead, so VoiceOver still reads one row that
    /// opens something.
    private var sessionRow: some View {
        let row: AnyView
        if isArchived {
            row = AnyView(SessionRow(session: session))
        } else {
            row = AnyView(
                SessionRow(session: session)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isLink)
                    .accessibilityAction(.default) { openSession() }
            )
        }
        var activate: (() -> Void)?
        if !isArchived {
            activate = { openSession() }
        }
        return AnyView(
            row.mobileRowSwipeAction(
                swipeAction,
                allowsFullSwipe: !isArchived,
                activate: activate
            )
        )
    }

    /// The one action worth a swipe: the row's own opposite. Archiving is the destructive half
    /// and can be swiped clean through; restoring is not, so it rests open and asks for the tap.
    ///
    /// `nil` for a share that may not manage sessions — the same right the long-press menu is
    /// gated on, because a swipe must not reach past a menu that refuses.
    private var swipeAction: MobileRowSwipeAction? {
        guard showsActions else { return nil }
        if isArchived {
            return MobileRowSwipeAction("Restore", systemImage: "arrow.uturn.backward") {
                action(.restore, session)
            }
        }
        return MobileRowSwipeAction("Archive", systemImage: "archivebox", role: .destructive) {
            action(.archive, session)
        }
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
                .accessibilityLabel(MobileL10n.string("Native, experimental"))
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

    static func resolve(state: RemoteTerminalActivity, isAvailable: Bool) -> Self {
        let isWorking = isAvailable && state == .working
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

/// The terminal row as a tap. Terminal geometry remains stable inside its UIKit host, so this row
/// keeps the ordinary system navigation transition just like session rows do.
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
        model.navigationPath.append(.terminal(terminal.id))
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
                if session.state == .needsAttention {
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
                    .accessibilityLabel(MobileL10n.string("Pinned"))
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
        session.isAvailable && !session.isArchived && session.state == .working
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
        case .working: return MobileL10n.string("Working")
        case .awaitingUser, .needsAttention: return MobileL10n.string("Needs attention")
        // Worth its own word here rather than falling to "Connected": away from the Mac is
        // exactly where a session that stopped hours ago is discovered, and "Connected" is the
        // reading that started this.
        case .limitReached: return MobileL10n.string("Usage limit reached")
        case .dormant, .idle, .unknown: return MobileL10n.string("Connected")
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
        if session.isAvailable, session.state == .limitReached {
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
