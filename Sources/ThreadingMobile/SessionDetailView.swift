import PhotosUI
import SwiftUI
import ThreadingRemoteKit
import UIKit
import UniformTypeIdentifiers

#if DEBUG
    /// The session screen's opening states, held still for the iOS evidence catalogue.
    ///
    /// Against a real Mac this screen passes through connecting, waking and failure in a moment,
    /// which is how a placeholder that painted the theme's ground as a plate the width of its own
    /// sentence reached a phone unnoticed. A fixture holds each one so it can be captured.
    enum MobileSessionOpeningFixture: String {
        case connecting = "session-opening-connecting"
        case resuming = "session-opening-resuming"
        case failed = "session-opening-failed"

        static var current: MobileSessionOpeningFixture? {
            ProcessInfo.processInfo.environment[MobileDemoScene.environmentKey]
                .flatMap(MobileSessionOpeningFixture.init(rawValue:))
        }

        var session: RemoteSessionSummaryDTO {
            RemoteSessionSummaryDTO(
                id: "session-opening-demo",
                title: "Remote access review",
                agentKind: "claude",
                surface: .conversation,
                state: self == .resuming ? .dormant : .idle,
                projectName: "Threading",
                isAvailable: self != .resuming
            )
        }

        /// The failure the screen reports is a real client error's own sentence, so the fixture
        /// carries no copy of its own.
        var launchError: String? {
            self == .failed ? RemoteClientError.invalidResponse.localizedDescription : nil
        }
    }
#endif

/// What the session screen's single trailing menu contains, and therefore whether it is shown.
///
/// Workspace, the terminal palette and the session actions were three separate toolbar buttons.
/// They are gathered under one control now, which means each of the three permissions that used
/// to reveal its own button has to keep revealing its entry — a share that may recolour a
/// terminal but not manage the session still needs the menu to appear.
enum MobileSessionChrome {
    /// The catalogue carries `AgentSession.displayTitle`, including an explicit rename. The
    /// live socket title is a transient surface caption and may still hold the value from when
    /// the detail connection opened, so it is only a bootstrap fallback for an empty catalogue
    /// value rather than an authority over session chrome.
    static func navigationTitle(catalogTitle: String, liveTitle: String?) -> String {
        catalogTitle.isEmpty ? (liveTitle ?? catalogTitle) : catalogTitle
    }

    /// What the screen says while a chat is being opened.
    ///
    /// Ordinarily "Opening chat…", because ordinarily the first route answers and a route name
    /// flashed for two hundred milliseconds is a stutter rather than information. Once something
    /// has failed the walk is going to take a while, and then the route it is on is the only
    /// honest thing to say: the 2026-08-21 incident's phone showed this placeholder and nothing
    /// else for ninety seconds while a dead LAN was worked through, which is why the person
    /// watching it filed a support report about a frozen app.
    ///
    /// The words are the connection status's own — "Trying LAN", "Trying Tailscale" — so a route
    /// is named the same way here as on the dashboard.
    static func openingStatus(
        isAvailable: Bool,
        routeWalk: RemoteAppModel.RouteWalkStatus?
    ) -> String {
        guard isAvailable else { return MobileL10n.string("Resuming on your Mac…") }
        guard let routeWalk, routeWalk.followsFailure else {
            return MobileL10n.string("Opening chat…")
        }
        return MobileL10n.string(
            "Trying %@",
            PairedRemoteHost.connectionLabelInSentence(forEndpointKind: routeWalk.kind)
        )
    }

    /// The same rule, resolved against the catalogue as it stands now rather than against the
    /// summary a screen was opened with.
    ///
    /// **Every title surface a session screen has asks this one function.** The rule above was
    /// applied only to the SwiftUI `navigationTitle`, which nothing on a session screen draws:
    /// the terminal supplies a principal toolbar item and the conversation installs its own
    /// `titleView`, and both read the socket's caption directly. So a chat answered to two
    /// names — its own in the list, and whatever the mirrored surface last called itself in the
    /// screen the list opens. A terminal's caption is the agent's OSC title as it was sent,
    /// before the Mac strips its decoration, ignores the ones that name the product or the
    /// working directory, and applies the user's choice about agent titles at all; the phone
    /// carries none of that, so it must not be the name.
    static func navigationTitle(
        for session: RemoteSessionSummaryDTO,
        in catalog: RemoteMeDTO?,
        liveTitle: String?
    ) -> String {
        navigationTitle(
            catalogTitle: currentSession(session, in: catalog).title,
            liveTitle: liveTitle
        )
    }

    /// The catalogue's own row for a session, falling back to the summary the screen was opened
    /// with while the catalogue is still loading or no longer lists the row. Archived rows are
    /// searched too, because the archive list opens the same screen.
    static func currentSession(
        _ session: RemoteSessionSummaryDTO,
        in catalog: RemoteMeDTO?
    ) -> RemoteSessionSummaryDTO {
        catalog?.sessions.first(where: { $0.id == session.id })
            ?? catalog?.archivedSessions?.first(where: { $0.id == session.id })
            ?? session
    }

    static func canOpenWorkspace(canManageSessions: Bool, hasClient: Bool) -> Bool {
        canManageSessions && hasClient
    }

    /// Activity is a badge, not part of the action's name. Keeping this title stable prevents a
    /// transient state from turning the menu's shortest destination into a wrapped sentence.
    static func workspaceMenuTitle() -> String {
        MobileL10n.string("Workspace")
    }

    static func workspaceMenuSystemImage() -> String {
        "square.grid.2x2"
    }

    /// The visible row stays compact, while VoiceOver receives the same unseen-activity state as
    /// the toolbar control that opened the menu.
    static func workspaceMenuAccessibilityLabel(hasUnseenBrowser: Bool) -> String {
        MobileL10n.string(
            hasUnseenBrowser ? "Workspace · New browser activity" : "Workspace"
        )
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

    /// The login's address, when it is worth a second line.
    ///
    /// Nil when the catalogue sends none, and nil when it *is* the name: `AccountName` derives
    /// the person from the address and falls back to the address itself when two logins derive
    /// the same person, so a row can be handed "everlof@gmail.com" as both. Printing it twice
    /// would look like a bug in the app rather than a fact about the account.
    static func usageMenuAddress(for account: RemoteAccountChoiceDTO) -> String? {
        guard let email = account.email?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty,
              email.compare(account.name, options: .caseInsensitive) != .orderedSame
        else {
            return nil
        }
        return email
    }

    /// The chat menu leads with the account's usage when there is either a gauge to draw or a
    /// reading to spell out. A login with neither is left to Chat Settings rather than given a
    /// row that says only its own name.
    static func showsUsageMenuRow(reading: MobileAccountUsageReading?) -> Bool {
        guard let reading else { return false }
        return !reading.rings.isEmpty || reading.summary != nil
    }

    /// What that row says under the login's name.
    ///
    /// The row keeps the exact percentages beside its glanceable gauge, then names when the
    /// first model-relevant window comes back. The reset was once selected independently from
    /// every account window, which let an unrelated Spark limit replace the reset for the model
    /// this chat actually runs; `MobileAccountUsageReading` now owns both facts.
    static func usageMenuDetail(
        reading: MobileAccountUsageReading,
        now: Date = Date()
    ) -> String {
        var parts = reading.summary.map { [$0] } ?? []
        if let nextReset = reading.nextReset {
            // Relative to the same instant the window ahead was chosen against, and in the
            // usage dashboard's own words for the same fact. `Date.formatted(.relative:)` is
            // always relative to the real clock instead, which is a second reading of "now" in
            // one line.
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            parts.append(MobileL10n.string(
                "Next reset %@",
                formatter.localizedString(for: nextReset, relativeTo: now)
            ))
        }
        return parts.isEmpty
            ? MobileUsageDefaults.unknownValue
            : parts.joined(separator: MobileUsageDefaults.segmentSeparator)
    }
}

/// **Scaffolding.** The shapes the chat menu's account block is being tried in, so all four can
/// be photographed from one build. Ships as `.reset`; a DEBUG run names another through
/// `THREADING_MOBILE_USAGE_MENU`. Delete with the three shapes that are not chosen.
enum MobileUsageMenuShape: String {
    /// What ships today: the login, its exact usage, and the next relevant reset.
    case reset
    /// The address joined onto the same line.
    case address
    /// The login and its address as their own row, then usage as a second.
    case split
    /// The address as the section's heading, over the usage row.
    case header

    static var current: MobileUsageMenuShape {
        #if DEBUG
            ProcessInfo.processInfo.environment["THREADING_MOBILE_USAGE_MENU"]
                .flatMap(MobileUsageMenuShape.init(rawValue:)) ?? .reset
        #else
            .reset
        #endif
    }
}

enum SessionDetailMetrics {
    /// How the last terminal screen stands under the reconnect loader.
    static var reconnectDim: Double { 0.55 }
    static var reconnectBlurRadius: CGFloat { 6 }
    static var reconnectRevealDuration: TimeInterval { 0.25 }
    /// How long a reconnect may take before its plate says so. A quick one never shows a
    /// spinner: the dim is the lock, the plate is "this is taking a moment".
    static var reconnectPlateDelay: Duration { .milliseconds(500) }
}

struct SessionDetailView: View {
    @EnvironmentObject private var model: RemoteAppModel
    @Environment(\.remoteTheme) private var theme
    /// The menu's usage glyph is a rendered picture rather than a symbol, so it is rendered for
    /// the screen it will be shown on.
    @Environment(\.displayScale) private var displayScale
    let session: RemoteSessionSummaryDTO
    let openingStrategy: MobileSessionOpeningStrategy
    /// Whether the terminal surface installs the principal two-line navigation title.
    /// The draft that started this chat keeps its own title mounted while it fades out over
    /// this screen — that is what lets "New session" morph into the chat's name — and hands
    /// the slot over only once it has retired. Two principal items must never stand at once.
    /// The conversation surface is not gated: its title is a UIKit `titleView` the controller
    /// re-installs on appearance, and the draft hands off to it immediately instead — see
    /// `SessionDraftView`'s principal item.
    let installsPrincipalTitle: Bool
    @StateObject private var workspaceActivity: MobileWorkspaceActivity
    @State private var connection: RemoteSessionConnection?
    @State private var isShowingUsage = false
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
    @State private var isShowingSessionSettings = false
    @State private var isShowingUniversalSearch = false
    @State private var isShowingTerminalFind = false
    @State private var initialWorkspaceDestination: RemoteNotificationDestinationDTO?
    @State private var initialWorkspaceEventID: String?
    @Environment(\.dismiss) private var dismiss

    private var currentSession: RemoteSessionSummaryDTO {
        MobileSessionChrome.currentSession(session, in: model.me)
    }

    init(
        session: RemoteSessionSummaryDTO,
        openingStrategy: MobileSessionOpeningStrategy = .resumeIfNeeded,
        installsPrincipalTitle: Bool = true,
        initialWorkspaceDestination: RemoteNotificationDestinationDTO? = nil
    ) {
        self.session = session
        self.openingStrategy = openingStrategy
        self.installsPrincipalTitle = installsPrincipalTitle
        _workspaceActivity = StateObject(wrappedValue: MobileWorkspaceActivity(
            sessionID: session.id
        ))
        _initialWorkspaceDestination = State(initialValue: initialWorkspaceDestination)
    }

    #if DEBUG
        /// Installs an already-connected, local PTY fixture behind the shipping session chrome.
        /// Evidence can therefore exercise the real toolbar/menu without opening a socket.
        init(evidenceConnection: RemoteSessionConnection) {
            session = evidenceConnection.session
            openingStrategy = .resumeIfNeeded
            installsPrincipalTitle = true
            _workspaceActivity = StateObject(wrappedValue: MobileWorkspaceActivity(
                sessionID: evidenceConnection.session.id
            ))
            _connection = State(initialValue: evidenceConnection)
        }
    #endif

    var body: some View {
        Group {
            if let connection {
                if connection.surface == .conversation {
                    ConversationRemoteView(connection: connection)
                } else {
                    TerminalRemoteView(
                        connection: connection,
                        installsPrincipalTitle: installsPrincipalTitle,
                        isShowingFind: $isShowingTerminalFind
                    )
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
                MobileLoadingPlaceholder(MobileSessionChrome.openingStatus(
                    isAvailable: openingStrategy == .awaitCreatedSession
                        || session.isAvailable,
                    routeWalk: model.routeWalkStatus
                ))
            }
        }
        .navigationTitle(MobileSessionChrome.navigationTitle(
            catalogTitle: currentSession.title,
            liveTitle: connection?.mirroredCaption
        ))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsSessionMenu {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        sessionMenuContent
                    } label: {
                        // The same disc the draft wore while this chat was being written — its
                        // runtime's mark ringed by its account's usage — now the handle on the
                        // chat's actions, so starting a chat keeps the control where it was and
                        // the bar says which login is paying for the turn.
                        SessionActionsToolbarIcon(
                            activity: workspaceActivity,
                            identity: .resolve(currentSession.agentKind),
                            reading: sessionUsageReading,
                            account: currentSession.account
                        )
                    }
                    .accessibilityLabel(
                        MobileL10n.string(
                            workspaceActivity.hasUnseenBrowser
                                ? "Session actions, new browser activity"
                                : "Session actions"
                        )
                    )
                    .accessibilityValue(sessionUsageReading?.summary ?? "")
                }
            }
        }
        .toolbarBackground(theme.surface, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .background(theme.ground)
        // The workspace is a drawer from the right edge — where the edge swipe that opens it
        // comes from, and where a sheet rising from the bottom never matched. The swipe pulls
        // it in by as far as the finger travels, and a rightward drag on it pushes it back.
        .sessionWorkspaceDrawer(isPresented: $isShowingWorkspace, isEnabled: canOpenWorkspace) {
            if let client = model.client {
                SessionWorkspaceView(
                    session: currentSession,
                    client: client,
                    activity: workspaceActivity,
                    initialDestination: initialWorkspaceDestination,
                    offersAttachmentThumbnails: model.me?.features?.contains(
                        RemoteRESTFeature.attachmentThumbnails.rawValue
                    ) == true
                )
                // A second milestone may be opened while Workspace is already presented. Give
                // each notification its own navigation identity so that tap replaces the old
                // stack with the newly requested attachment or live surface.
                .id(initialWorkspaceEventID ?? "manual-workspace")
                .mobileTheme(theme)
            }
        }
        .onChange(of: isShowingWorkspace) { _, isShowing in
            guard !isShowing else { return }
            initialWorkspaceDestination = nil
            initialWorkspaceEventID = nil
        }
        .sheet(isPresented: $isShowingSessionSettings) {
            MobileSessionSettingsView(
                sessionID: session.id,
                onAccountMoved: reopenAfterAccountMove
            )
            .environmentObject(model)
            .mobileTheme(theme)
        }
        .sheet(isPresented: $isShowingUsage) {
            if let link = model.activeHost?.link {
                RemoteUsageDashboardView(link: link, isDemo: model.isDemo, focus: usageFocus)
                    .mobileTheme(theme)
            }
        }
        .sheet(isPresented: $isShowingUniversalSearch) {
            NavigationStack {
                MobileUniversalSearchView(initialScope: universalSearchScope) { route in
                    model.navigationPath.append(route)
                }
            }
            .mobileTheme(theme)
        }
        .task {
            await open()
            if initialWorkspaceDestination != nil, canOpenWorkspace {
                initialWorkspaceEventID = "search-result"
                isShowingWorkspace = true
            }
            openPendingNotificationDestination()
        }
        .onChange(of: model.notificationOpenRequest?.eventID) { _, _ in
            openPendingNotificationDestination()
        }
        .onDisappear {
            guard let connection else { return }
            guard let hostID = model.activeHostID else {
                connection.disconnect(markEnded: false)
                return
            }
            MobileSessionConnectionPool.shared.park(
                connection,
                for: MobileConnectionPoolKey(hostID: hostID, sessionID: session.id)
            )
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

    private var universalSearchScope: MobileUniversalSearchScope {
        let projectID = currentSession.projectID ?? uniqueCatalogProjectID(
            named: currentSession.projectName
        )
        return .session(
            id: currentSession.id,
            projectID: projectID,
            projectName: currentSession.projectName
        )
    }

    private func uniqueCatalogProjectID(named name: String) -> String? {
        let matches = model.me?.newSessionCatalog?.projects.filter { $0.name == name } ?? []
        guard matches.count == 1 else { return nil }
        return matches[0].id
    }

    /// Everything the session's own chrome can do, gathered under the one trailing control.
    ///
    /// Workspace and the terminal palette used to sit beside it as separate toolbar buttons.
    /// Three glyphs plus a back button left the title a truncated stub on a phone, and neither
    /// of the two is reached often enough to spend a permanent slot on.
    @ViewBuilder
    private var sessionMenuContent: some View {
        if connection?.surface == .terminal {
            Button {
                isShowingTerminalFind = true
            } label: {
                Label("Find in terminal", systemImage: "text.magnifyingglass")
            }
            .keyboardShortcut("f", modifiers: .command)
        }
        if model.canUseUniversalSearch {
            Button {
                isShowingUniversalSearch = true
            } label: {
                Label(
                    MobileL10n.string(
                        connection?.surface == .terminal ? "Search session" : "Search conversation"
                    ),
                    systemImage: "magnifyingglass"
                )
            }
            .keyboardShortcut(
                "f",
                modifiers: connection?.surface == .terminal ? [.command, .shift] : .command
            )
            Divider()
        }
        // The disc that opens this menu is ringed by the account's usage; the row leads with
        // that same drawing at glyph size, states its exact values and relevant reset, and takes
        // the reader to the dashboard for the rest.
        if let account = sessionAccount,
           let reading = sessionUsageReading,
           MobileSessionChrome.showsUsageMenuRow(reading: reading)
        {
            usageMenuRows(account: account, reading: reading)
            Divider()
        }
        if canOpenWorkspace {
            SessionWorkspaceMenuButton(
                hasUnseenBrowser: workspaceActivity.hasUnseenBrowser,
                action: openWorkspace
            )
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
                if canOpenSessionSettings {
                    Button {
                        isShowingSessionSettings = true
                    } label: {
                        Label("Chat Settings", systemImage: "gearshape")
                    }
                }
                Menu {
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
                    .accessibilityLabel(MobileL10n.string("Native, experimental"))
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
                } label: {
                    Label("Interface", systemImage: "rectangle.2.swap")
                }
            }
            .disabled(isMutatingSession)
        }
        if let catalog = model.me?.themeCatalog, canChooseTerminalTheme {
            terminalThemeMenu(catalog)
        }
        if model.canManageSessions {
            Button(role: .destructive) {
                mutate(dismissImmediately: true) {
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
        model.canUseUniversalSearch || MobileSessionChrome.showsSessionMenu(
            canManageSessions: model.canManageSessions,
            canChooseTerminalTheme: canChooseTerminalTheme
        )
    }

    /// The disc's rings, for the model this chat runs rather than the login's default: a Fable
    /// window rings a Fable chat and no other.
    private var sessionUsageReading: MobileAccountUsageReading? {
        MobileAccountUsageReading.resolve(account: sessionAccount, model: currentSession.model)
    }

    /// The usage screen opens on this chat's login.
    private var usageFocus: MobileUsageAccountFocus? {
        guard let account = sessionAccount,
              let agent = model.me?.newSessionCatalog?.agents.first(where: {
                  $0.id == currentSession.agentKind
              }) else { return nil }
        return MobileUsageAccountFocus(runtimeName: agent.name, accountName: account.name)
    }

    /// The menu's account block, in whichever shape is being tried.
    ///
    /// **Scaffolding.** Four shapes are kept side by side only long enough to photograph them
    /// and choose one; `MobileUsageMenuShape.current` is `.reset` — what ships — unless a DEBUG
    /// run names another. Collapse this to the chosen shape before it goes anywhere.
    @ViewBuilder
    private func usageMenuRows(
        account: RemoteAccountChoiceDTO,
        reading: MobileAccountUsageReading
    ) -> some View {
        let detail = MobileSessionChrome.usageMenuDetail(reading: reading)
        let address = MobileSessionChrome.usageMenuAddress(for: account)
        switch MobileUsageMenuShape.current {
        case .reset:
            usageRow(title: account.name, detail: detail, reading: reading)
        case .address:
            usageRow(
                title: account.name,
                detail: [address, detail]
                    .compactMap { $0 }
                    .joined(separator: MobileUsageDefaults.segmentSeparator),
                reading: reading
            )
        case .split:
            Button {
                isShowingSessionSettings = true
            } label: {
                Text(account.name)
                Text(address ?? MobileL10n.string("Account"))
                Image(systemName: "person.crop.circle")
            }
            .disabled(!canOpenSessionSettings)
            usageRow(title: MobileL10n.string("Usage"), detail: detail, reading: reading)
        case .header:
            Section(address ?? account.name) {
                usageRow(title: account.name, detail: detail, reading: reading)
            }
        }
    }

    /// One row: the login, its exact reading and relevant reset, and the glanceable gauge.
    private func usageRow(
        title: String,
        detail: String,
        reading: MobileAccountUsageReading
    ) -> some View {
        Button {
            isShowingUsage = true
        } label: {
            // Title, subtitle, glyph: the menu's own two-line item, which a `Label`
            // does not become.
            Text(title)
            Text(detail)
            usageMenuGlyph(for: reading)
        }
        // The visible detail and VoiceOver value stay identical: both include the exact
        // percentages and the relevant reset, while the rings remain the glanceable path.
        .accessibilityLabel(title)
        .accessibilityValue(detail)
    }

    /// The reading as the menu row's glyph: its rings, or the gauge symbol when a host reports
    /// usage in words alone and there is nothing to ring.
    private func usageMenuGlyph(for reading: MobileAccountUsageReading) -> Image {
        guard let gauge = MobileAccountUsageGauge.image(
            for: reading,
            theme: theme,
            scale: displayScale
        ) else {
            return Image(systemName: "gauge.with.dots.needle.67percent")
        }
        return Image(uiImage: gauge)
    }

    /// The catalogue's row for the login this chat runs on, which is where its usage lives —
    /// joined by `accountID`, as the settings screen joins it, because a session row carries no
    /// usage of its own. Nil for a guest share, a runtime without account routing, or an older
    /// host, and the disc then shows the mark alone.
    private var sessionAccount: RemoteAccountChoiceDTO? {
        let agent = model.me?.newSessionCatalog?.agents.first { $0.id == currentSession.agentKind }
        return MobileSessionSettingsPresentation.account(for: currentSession, in: agent)
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

    private var canOpenSessionSettings: Bool {
        currentSession.accountID != nil
            || currentSession.limitRecovery != nil
            || (model.canReadUsage && model.activeHost != nil)
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
        #if DEBUG
            // The marketing terminal is a privacy-reviewed PTY resource already installed by the
            // DEBUG initializer above. Treating it as a dormant row would replace it with a socket.
            if MobileDemoFixture.isMarketing(
                ProcessInfo.processInfo.environment[MobileDemoScene.environmentKey]
            ), connection != nil {
                return
            }
            // An evidence run asks for one opening state and stays in it; nothing connects.
            if let fixture = MobileSessionOpeningFixture.current {
                launchError = fixture.launchError
                return
            }
        #endif
        guard let hostID = model.activeHostID else {
            launchError = RemoteClientError.invalidResponse.localizedDescription
            return
        }
        let pool = MobileSessionConnectionPool.shared
        pool.discardEntries(exceptHostID: hostID)
        let key = MobileConnectionPoolKey(hostID: hostID, sessionID: session.id)
        if let warmed = pool.take(key) as? RemoteSessionConnection {
            warmed.onWorkspaceChanged = { [weak workspaceActivity] event in
                workspaceActivity?.receive(event)
            }
            connection = warmed
            return
        }
        do {
            // A UI switch deliberately tears down the old process. Always ask readiness from
            // the newest catalogue row rather than the immutable navigation value, which may
            // still say that the pre-switch surface was available.
            let latest = model.me?.sessions.first(where: { $0.id == session.id }) ?? session
            if openingStrategy == .resumeIfNeeded {
                try await model.makeSessionReady(latest)
            }
            guard let client = model.client else {
                throw RemoteClientError.invalidResponse
            }
            let current = model.me?.sessions.first(where: { $0.id == session.id }) ?? session
            let made = RemoteSessionConnection(
                session: current,
                client: client,
                reconnectClient: { attempt in
                    await model.clientForSessionReconnect(hostID: hostID, attempt: attempt)
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

    private func reopenAfterAccountMove() {
        connection?.disconnect(markEnded: false)
        connection = nil
        launchError = nil
        Task { await open() }
    }

    private func mutate(
        dismissImmediately: Bool = false,
        operation: @escaping @MainActor () async throws -> Void
    ) {
        guard !isMutatingSession else { return }
        isMutatingSession = true
        if dismissImmediately {
            connection?.disconnect(markEnded: false)
            dismiss()
        }
        Task {
            defer { isMutatingSession = false }
            do {
                try await operation()
            } catch is CancellationError {
                return
            } catch {
                MobileDiagnostics.logDegraded(.sessionAction, error: error)
                if dismissImmediately {
                    model.reportArchiveMutationFailure(error)
                    if !model.navigationPath.contains(.session(currentSession.id)) {
                        // The presentation-only hide has also ended, so take the person back to
                        // the chat whose archive failed instead of silently dropping the action.
                        model.navigationPath.append(.session(currentSession.id))
                    }
                } else {
                    sessionActionError = error.localizedDescription
                }
            }
        }
    }
}

/// The one Workspace action used by the session menu and its deterministic evidence fixture.
/// The destination keeps its stable name and repeats the toolbar's activity dot on its own icon,
/// so the state survives the hop into the menu without becoming a second line of prose.
struct SessionWorkspaceMenuButton: View {
    let hasUnseenBrowser: Bool
    let action: () -> Void

    @Environment(\.displayScale) private var displayScale
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        Button(action: action) {
            Text(MobileSessionChrome.workspaceMenuTitle())
            menuGlyph
        }
        .accessibilityLabel(
            MobileSessionChrome.workspaceMenuAccessibilityLabel(
                hasUnseenBrowser: hasUnseenBrowser
            )
        )
    }

    private var menuGlyph: Image {
        guard hasUnseenBrowser,
              let image = MobileWorkspaceActivityMenuGlyph.image(
                theme: theme,
                scale: displayScale
              ) else {
            return Image(systemName: MobileSessionChrome.workspaceMenuSystemImage())
        }
        return Image(uiImage: image)
    }
}

/// The one visual vocabulary for unseen Workspace activity, shared by the toolbar handle and the
/// Workspace action inside its menu.
struct MobileWorkspaceActivityDot: View {
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        Circle()
            .fill(theme.accent)
            .frame(
                width: MobileDesign.Size.workspaceActivityDot,
                height: MobileDesign.Size.workspaceActivityDot
            )
            .overlay {
                Circle()
                    .strokeBorder(
                        theme.surface,
                        lineWidth: MobileDesign.Size.badgeStroke
                    )
            }
            .accessibilityHidden(true)
    }
}

/// `UIMenu` extracts text and one `Image` from each SwiftUI button. An arbitrary custom icon view
/// makes the whole action disappear, so render the shared dot and Workspace symbol into the image
/// slot the native menu explicitly supports.
enum MobileWorkspaceActivityMenuGlyph {
    private struct Drawn: Equatable {
        let theme: RemoteThemePalette
        let scale: CGFloat
    }

    @MainActor private static var lastDrawn: Drawn?
    @MainActor private static var lastImage: UIImage?

    @MainActor
    static func image(theme: RemoteThemePalette, scale: CGFloat) -> UIImage? {
        let drawn = Drawn(theme: theme, scale: scale)
        if drawn == lastDrawn, let lastImage { return lastImage }

        let side = MobileDesign.Size.usageMenuGauge
        let renderer = ImageRenderer(
            content: Image(systemName: MobileSessionChrome.workspaceMenuSystemImage())
                .font(.system(size: side * 0.8, weight: .medium))
                .foregroundStyle(theme.accent)
                .frame(width: side, height: side)
                .overlay(alignment: .topTrailing) {
                    MobileWorkspaceActivityDot()
                        .mobileTheme(theme)
                }
                .padding(MobileDesign.Size.usageMenuGaugeInset)
        )
        renderer.scale = max(scale, 1)
        let image = renderer.uiImage?.withRenderingMode(.alwaysOriginal)
        lastDrawn = image == nil ? nil : drawn
        lastImage = image
        return image
    }
}

/// The session's one trailing toolbar control.
///
/// It carries the workspace's unseen-browser dot, because Workspace now lives inside the menu
/// this opens: a milestone the phone was not watching still has to be visible from the outside.
struct SessionActionsToolbarIcon: View {
    @ObservedObject var activity: MobileWorkspaceActivity
    let identity: MobileAgentIdentity
    let reading: MobileAccountUsageReading?
    /// The alternate login, when there is one. Its badge is device-local and opt-in; the menu
    /// continues to name the account regardless of this compact presentation choice.
    let account: RemoteSessionAccountDTO?

    @AppStorage(MobileSessionAccountBadgePreference.key)
    private var showsAccountBadge = MobileSessionAccountBadgePreference.defaultValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        disc
            .overlay(alignment: .topTrailing) {
                if activity.hasUnseenBrowser {
                    // The toolbar clips its label to the disc's 34-point bounds. The shared dot
                    // keeps both its fill and separating ring inside that boundary.
                    MobileWorkspaceActivityDot()
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(
                reduceMotion ? .easeOut(duration: 0.15) : .snappy(duration: 0.32),
                value: activity.hasUnseenBrowser
            )
    }

    /// The disc gives one quiet breath when the agent opens or navigates a browser tab — the
    /// pulse the ellipsis used to give — and the dot stays until Browser is opened. A brand
    /// mark is not a symbol, so the breath is a scale phase rather than a symbol effect.
    @ViewBuilder
    private var disc: some View {
        let presentedAccount = MobileSessionAccountBadgePreference.presentedAccount(
            account,
            isEnabled: showsAccountBadge
        )
        let disc = MobileAccountDisc(
            identity: identity,
            reading: reading,
            account: presentedAccount
        )
        if reduceMotion {
            disc
        } else {
            disc.phaseAnimator(
                [false, true],
                trigger: activity.latestBrowserActivityID
            ) { content, lifted in
                content.scaleEffect(lifted ? MobileDesign.Motion.activityBreathScale : 1)
            } animation: { _ in
                .snappy(duration: MobileDesign.Motion.activityBreathDuration)
            }
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
            // A healthy title answers the question its second line raises: tapping it opens
            // the same connection panel the chat list's title does.
            MobileConnectionStatusButton(
                title: MobileSessionChrome.navigationTitle(
                    for: connection.session,
                    in: model.me,
                    liveTitle: connection.mirroredCaption
                ),
                status: label,
                statusColor: color
            )
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
        case let .openUpdatePage(url):
            openURL(url)
        }
    }

    private var title: some View {
        MobileConnectionNavigationTitle(
            title: MobileSessionChrome.navigationTitle(
                for: connection.session,
                in: model.me,
                liveTitle: connection.mirroredCaption
            ),
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
        case .connecting:
            return connection.hasEverConnected
                ? MobileL10n.string("Reconnecting…")
                : MobileL10n.string("Opening chat…")
        case .connected:
            return model.activeHost?.name ?? MobileL10n.string("Connected")
        case let .ended(reason): return reason
        case let .failed(failure): return failure.message
        }
    }
}

struct TerminalRemoteView: View {
    @ObservedObject var connection: RemoteSessionConnection
    /// False only while the draft that started this session still shows its own title over
    /// this screen; see `SessionDetailView.installsPrincipalTitle`.
    var installsPrincipalTitle = true
    @Binding private var isShowingFind: Bool
    @EnvironmentObject private var model: RemoteAppModel
    @EnvironmentObject private var continuity: MobileSessionContinuityStore
    @EnvironmentObject private var keyboards: MobileTerminalKeyboardStore
    @Environment(\.remoteTheme) private var inheritedTheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var waitedLongEnough = false
    @State private var openingSnapshot: UIImage?
    @State private var showsAttentionRequest = false
    @State private var showsKeyboardEditor = false
    @State private var directAttachmentTray: ComposerAttachmentTray?
    @State private var directAttachmentNotice: String?
    @State private var showsDirectAttachmentNotice = false
    @State private var directAttachmentPhotoItems: [PhotosPickerItem] = []
    @State private var isPickingDirectAttachmentPhotos = false
    @State private var isImportingDirectAttachmentFiles = false
    @State private var isChoosingDirectAttachmentSource = false
    @State private var pendingDirectAttachmentSource: DirectAttachmentSource?
    /// Picks whose files are still being read. A pick is not finished when its first file is.
    @State private var directAttachmentPicksInFlight = 0
    @State private var directAttachmentBusyRetries = 0
    /// Read once, when the chooser opens, rather than while the body is being evaluated: the
    /// terminal republishes on presence, typing, the grid and canSend, and each of those would
    /// otherwise have cost an XPC round trip to the pasteboard server.
    @State private var clipboardOffersContent = false
    @State private var pendingDirectAttachmentInsertionID: String?
    @State private var selectionQuotes: [RemoteTerminalSelectionQuote] = []
    @State private var selectedInputPreference: MobileTerminalInputPreference?
    @State private var findQuery = ""
    @State private var findMatchIndex = 0
    @State private var findMatchTotal = 0
    @FocusState private var findFieldFocused: Bool
    @StateObject private var keyBridge = TerminalKeyBridge()
    @AppStorage(MobileTerminalFontSize.preferenceKey)
    private var terminalFontSize = MobileTerminalFontSize.defaultValue
    @AppStorage(MobileTerminalInputPreference.defaultPreferenceKey)
    private var defaultInputPreference = MobileTerminalInputPreference.direct

    init(
        connection: RemoteSessionConnection,
        installsPrincipalTitle: Bool = true,
        isShowingFind: Binding<Bool> = .constant(false)
    ) {
        self.connection = connection
        self.installsPrincipalTitle = installsPrincipalTitle
        _isShowingFind = isShowingFind
    }

    private var theme: RemoteThemePalette {
        connection.theme.map(RemoteThemePalette.init) ?? inheritedTheme
    }

    /// Hydrating after a connect, or locked from the moment the app lost the front until the
    /// socket proved itself again — one span from the reader's side.
    private var isCatchingUp: Bool {
        connection.isTerminalHydrating || connection.isAwaitingResume
    }

    /// A reconnect keeps the live screen; the lock from leaving the app does too.
    private var keepsLiveScreen: Bool {
        connection.holdsPreviousScreen || connection.isAwaitingResume
    }

    private var presentation: TerminalSurfacePresentation {
        TerminalSurfacePresentation.resolve(
            isLoading: isCatchingUp,
            keepsLiveScreen: keepsLiveScreen,
            hasSnapshot: openingSnapshot != nil,
            waitedLongEnough: waitedLongEnough
        )
    }

    private var isLockedLive: Bool {
        if case .lockedLive = presentation { return true }
        return false
    }

    /// The loader over a softened screen is owed only once the wait has lasted a beat, and
    /// only while the person is looking — the switcher card is the softened screen alone.
    private var wantsLoaderTimer: Bool {
        presentation.delaysLoader && scenePhase == .active
    }

    private var terminalOpacity: Double {
        switch presentation {
        case .live: return 1
        case .lockedLive: return SessionDetailMetrics.reconnectDim
        case .snapshot, .loader: return 0
        }
    }

    private var openingStatus: String {
        MobileSessionChrome.openingStatus(isAvailable: true, routeWalk: model.routeWalkStatus)
    }

    private var terminalBackground: Color {
        guard let hex = connection.terminalTheme?.background,
              let color = UIColor(remoteHex: hex)
        else {
            return theme.ground
        }
        return Color(color)
    }

    private var inputPreference: MobileTerminalInputPreference {
        #if DEBUG
            if ProcessInfo.processInfo.environment[MobileDemoScene.environmentKey] == "terminal-compose" {
                return .compose
            }
        #endif
        return selectedInputPreference
            ?? terminalContinuity?.terminalInputPreference
            ?? defaultInputPreference
    }

    private var inputMode: MobileTerminalInputMode {
        connection.terminalInputMode(preference: inputPreference)
    }

    private var usesIndependentComposer: Bool { inputMode == .independentComposer }

    private var allowsDirectInput: Bool { inputMode == .direct }

    /// A participant roster may temporarily force the atomic composer. The stored preference is
    /// still kept, but changing it while the visible mode is host-required would look like a
    /// broken button and could re-enable raw typing at the wrong moment.
    private var canChooseInputPreference: Bool {
        guard connection.capability == .interact,
              connection.supportsAtomicTerminalSubmission,
              connection.supportsFocusedInputControl,
              connection.inputControl?.canWrite != false,
              let state = connection.inputControl,
              !MobileCollaborationPresentation.hasOtherParticipant(state),
              !connection.isPromptSubmissionPending else { return false }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            MobileRunPlanDisclosure(connection: connection)
            if isShowingFind {
                terminalFindBar
            }
            terminalSurface
            TerminalCollaborationBar(
                connection: connection,
                askForInput: { showsAttentionRequest = true }
            )
            InputControlBar(connection: connection)
            AttentionActivityBanner(connection: connection)
            if usesIndependentComposer {
                TerminalLineComposer(
                    connection: connection,
                    bridge: keyBridge,
                    quotes: $selectionQuotes,
                    focusesOnAppear: rememberedTerminalKeyboardUp
                )
            }
            if allowsDirectInput, !selectionQuotes.isEmpty {
                TerminalSelectionQuoteTray(
                    quotes: selectionQuotes,
                    placement: .standalone(insert: TerminalSelectionQuoteTray.Insert(
                        isEnabled: canInsertSelectionQuotes,
                        action: insertSelectionQuotes
                    )),
                    remove: removeSelectionQuote
                )
            }
            TerminalKeyBar(
                connection: connection,
                bridge: keyBridge,
                agentKind: connection.session.agentKind,
                customize: { showsKeyboardEditor = true },
                inputPreference: inputPreference,
                effectiveInputMode: inputMode,
                canChooseInputPreference: canChooseInputPreference,
                toggleInputPreference: toggleInputPreference,
                showsAttachmentKey: allowsDirectInput
                    && connection.supportsTerminalAttachmentInsertion,
                canAttach: directAttachmentPicksInFlight == 0
                    && directAttachmentTray?.canAcceptMore == true,
                chooseAttachmentSource: beginChoosingDirectAttachmentSource,
                isChoosingAttachmentSource: $isChoosingDirectAttachmentSource,
                attachmentSourceActions: directAttachmentSourceActions
            )
        }
        .toolbarBackground(theme.surface, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            if installsPrincipalTitle {
                ToolbarItem(placement: .principal) {
                    RemoteNavigationTitle(connection: connection)
                }
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
        .onAppear(perform: restoreInputPreference)
        .onAppear(perform: configureDirectAttachments)
        .onAppear(perform: seedSelectionQuotesForEvidence)
        .onAppear { keyBridge.seedKeyboardWanted(rememberedTerminalKeyboardUp) }
        .onChange(of: isShowingFind) { _, isShowing in
            if isShowing {
                keyBridge.dismissKeyboardForModeSwitch()
                findFieldFocused = true
            } else {
                clearTerminalFind()
            }
        }
        .onDisappear(perform: rememberTerminalKeyboard)
        .onReceive(
            NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
        ) { _ in rememberTerminalKeyboard() }
        .onChange(of: model.client != nil) { _, _ in
            configureDirectAttachments()
        }
        .onChange(of: directAttachmentPhotoItems) { _, items in
            Task { await loadDirectAttachmentPhotos(items) }
        }
        .onChange(of: connection.promptSubmissionFeedback) { _, feedback in
            handleDirectAttachmentInsertion(feedback)
        }
        .onChange(of: connection.isPromptSubmissionPending) { _, isPending in
            // A busy Mac answered "not now". This is the moment it stops being now.
            guard !isPending else { return }
            insertDirectAttachmentsIfReady()
        }
        .onChange(of: isChoosingDirectAttachmentSource) { _, isPresented in
            guard !isPresented, let source = pendingDirectAttachmentSource else { return }
            pendingDirectAttachmentSource = nil
            switch source {
            case .photos: isPickingDirectAttachmentPhotos = true
            case .files: isImportingDirectAttachmentFiles = true
            case .clipboard: pasteClipboardIntoTerminal()
            }
        }
        .themedAlert(
            "Attachment",
            message: directAttachmentNotice,
            isPresented: $showsDirectAttachmentNotice,
            actions: [
                ThemedDialogAction("OK") {
                    directAttachmentNotice = nil
                    directAttachmentTray?.clearNotice()
                },
            ]
        )
        .photosPicker(
            isPresented: $isPickingDirectAttachmentPhotos,
            selection: $directAttachmentPhotoItems,
            maxSelectionCount: remainingDirectAttachmentSlots,
            matching: .any(of: [.images, .videos])
        )
        .fileImporter(
            isPresented: $isImportingDirectAttachmentFiles,
            allowedContentTypes: ComposerAttachmentSources.documentTypes,
            allowsMultipleSelection: true
        ) { result in
            importDirectAttachmentFiles(result)
        }
    }

    private var terminalFindBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(theme.secondaryLabel)
                .accessibilityHidden(true)
            TextField(MobileL10n.string("Find in terminal"), text: $findQuery)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($findFieldFocused)
                .submitLabel(.search)
                .onSubmit { findNextTerminalMatch() }
                .onChange(of: findQuery) { _, query in
                    guard !query.isEmpty else {
                        clearTerminalSearchSelection()
                        return
                    }
                    findNextTerminalMatch()
                }
            Text(findMatchSummary)
                .font(.caption.monospacedDigit())
                .foregroundStyle(theme.secondaryLabel)
                .frame(minWidth: 38, alignment: .trailing)
                .accessibilityLabel(MobileL10n.string("Search matches"))
            Button(action: findPreviousTerminalMatch) {
                Image(systemName: "chevron.up")
            }
            .disabled(findQuery.isEmpty || findMatchTotal == 0)
            .accessibilityLabel(MobileL10n.string("Previous match"))
            Button(action: findNextTerminalMatch) {
                Image(systemName: "chevron.down")
            }
            .disabled(findQuery.isEmpty || findMatchTotal == 0)
            .accessibilityLabel(MobileL10n.string("Next match"))
            Button(MobileL10n.string("Done")) {
                isShowingFind = false
            }
        }
        .font(.body)
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .foregroundStyle(theme.label)
        .background(theme.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.divider).frame(height: theme.borderWidth)
        }
    }

    private var findMatchSummary: String {
        guard !findQuery.isEmpty else { return "" }
        return "\(findMatchIndex)/\(findMatchTotal)"
    }

    private func findNextTerminalMatch() {
        guard !findQuery.isEmpty, let terminal = keyBridge.terminalView else {
            clearTerminalSearchSelection()
            return
        }
        _ = terminal.findNext(findQuery)
        updateTerminalFindSummary(terminal)
    }

    private func findPreviousTerminalMatch() {
        guard !findQuery.isEmpty, let terminal = keyBridge.terminalView else { return }
        _ = terminal.findPrevious(findQuery)
        updateTerminalFindSummary(terminal)
    }

    private func updateTerminalFindSummary(_ terminal: RemoteTerminalView) {
        let summary = terminal.searchMatchSummary(findQuery)
        findMatchIndex = summary.index
        findMatchTotal = summary.total
    }

    private func clearTerminalSearchSelection() {
        keyBridge.terminalView?.clearSearch()
        findMatchIndex = 0
        findMatchTotal = 0
    }

    private func clearTerminalFind() {
        clearTerminalSearchSelection()
        findQuery = ""
        findFieldFocused = false
    }

    private var terminalSurface: some View {
        TerminalViewRepresentable(
            connection: connection,
            theme: connection.terminalTheme,
            chromeTheme: theme,
            allowsDirectInput: allowsDirectInput,
            keyBridge: keyBridge,
            fontSize: terminalFontSize,
            onFontSizeChange: { terminalFontSize = $0 },
            initialScrollProgress: initialTerminalScrollProgress,
            onScrollProgress: saveTerminalViewport,
            quoteSelection: inputMode == .none ? nil : addSelectionQuote,
            focusesOnCreation: rememberedTerminalKeyboardUp
        )
        .opacity(terminalOpacity)
        .blur(
            radius: isLockedLive && !reduceMotion ? SessionDetailMetrics.reconnectBlurRadius : 0
        )
        .overlay {
            switch presentation {
            case .live:
                EmptyView()
            case let .lockedLive(showsLoader):
                if showsLoader {
                    MobileLoadingPlaceholder(MobileL10n.string("Reconnecting…"), standsOnContent: true)
                }
            case let .snapshot(showsLoader):
                ZStack {
                    if let openingSnapshot {
                        Image(uiImage: openingSnapshot)
                            .resizable()
                            .scaledToFill()
                            .blur(radius: reduceMotion ? 0 : SessionDetailMetrics.reconnectBlurRadius)
                            .opacity(SessionDetailMetrics.reconnectDim)
                            .clipped()
                    }
                    if showsLoader {
                        MobileLoadingPlaceholder(openingStatus, standsOnContent: true)
                    }
                }
                .background(terminalBackground)
            case .loader:
                MobileLoadingPlaceholder(openingStatus)
                    .background(terminalBackground)
            }
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: SessionDetailMetrics.reconnectRevealDuration),
            value: presentation
        )
        .task(id: wantsLoaderTimer) {
            guard wantsLoaderTimer else {
                waitedLongEnough = false
                return
            }
            try? await Task.sleep(for: SessionDetailMetrics.reconnectPlateDelay)
            guard !Task.isCancelled else { return }
            waitedLongEnough = true
        }
        .onAppear {
            openingSnapshot = MobileTerminalSnapshotCache.shared.image(for: connection.session.id)
        }
        .onChange(of: presentation) { _, now in
            if now == .live { openingSnapshot = nil }
        }
        .background(terminalBackground)
        // `TerminalViewRepresentable` owns this inset inside its stable-width UIKit host. Keeping
        // it outside in SwiftUI would make the host guess how much of the navigation viewport a
        // travelling destination will eventually receive.
        .background(terminalBackground)
    }

    private var terminalContinuity: MobileSessionContinuityStore.SessionState? {
        guard let hostID = model.activeHostID else { return nil }
        return continuity.state(hostID: hostID, sessionID: connection.session.id)
    }

    private var initialTerminalScrollProgress: Double? {
        if let persisted = terminalContinuity?.terminalViewportProgress { return persisted }
        #if DEBUG
            // The scrollback evidence uses the shipping continuity path to hold the real SwiftTerm
            // viewport above its live edge. No snapshot-only overlay manufactures the button.
            if ProcessInfo.processInfo.environment["THREADING_MOBILE_UI_EVIDENCE_ID"]?
                .hasPrefix("terminal-scrollback-") == true
            {
                return 0.32
            }
        #endif
        return nil
    }

    /// The keyboard comes back if this chat was left while writing, and recently; otherwise a
    /// chat opens with the keyboard down. Returning from the background needs no memory: the
    /// terminal is not rebuilt, so iOS restores the responder it had.
    private var rememberedTerminalKeyboardUp: Bool {
        guard let hostID = model.activeHostID else { return false }
        let state = continuity.state(hostID: hostID, sessionID: connection.session.id)
        return MobileTerminalKeyboardMemory.opensKeyboard(
            wasUp: state.terminalKeyboardWasUp,
            leftAt: state.terminalKeyboardLeftAt
        )
    }

    private func rememberTerminalKeyboard() {
        guard let hostID = model.activeHostID else { return }
        continuity.setTerminalKeyboardUp(
            keyBridge.keyboardWantedUp,
            at: Date(),
            hostID: hostID,
            sessionID: connection.session.id
        )
    }

    private func saveTerminalViewport(_ progress: Double) {
        guard let hostID = model.activeHostID else { return }
        continuity.setTerminalViewport(
            progress: progress,
            hostID: hostID,
            sessionID: connection.session.id
        )
    }

    private func restoreInputPreference() {
        guard selectedInputPreference == nil else { return }
        #if DEBUG
            // Evidence fixtures share one demo session inside a single cloned simulator. The Compose
            // fixture forces presentation only; persisting it would turn every later Direct fixture
            // into Compose and make the keyboard-open evidence test the wrong surface.
            if ProcessInfo.processInfo.environment[MobileDemoScene.environmentKey] == "terminal-compose" {
                return
            }
        #endif
        if let restored = terminalContinuity?.terminalInputPreference {
            selectedInputPreference = restored
        } else {
            // The computed value already uses this default. Materialize it for future launches
            // without rewriting identical SwiftUI state and remounting a newly focused terminal.
            saveInputPreference(defaultInputPreference)
        }
    }

    private func toggleInputPreference() {
        guard canChooseInputPreference else { return }
        keyBridge.dismissKeyboardForModeSwitch()
        let next: MobileTerminalInputPreference = inputPreference == .direct ? .compose : .direct
        selectedInputPreference = next
        saveInputPreference(next)
    }

    private func saveInputPreference(_ preference: MobileTerminalInputPreference) {
        guard let hostID = model.activeHostID else { return }
        continuity.setTerminalInputPreference(
            preference,
            hostID: hostID,
            sessionID: connection.session.id
        )
    }

    private var remainingDirectAttachmentSlots: Int {
        max(
            1,
            RemoteAttachmentUploadLimits.maximumPerMessage
                - (directAttachmentTray?.items.count ?? 0)
        )
    }

    // MARK: - Quoted selection

    private var canInsertSelectionQuotes: Bool {
        if isSelectionQuoteEvidence { return true }
        return connection.phase == .connected
            && connection.capability == .interact
            && connection.inputControl?.canWrite != false
    }

    private func addSelectionQuote(_ text: String) {
        guard let quote = RemoteTerminalSelectionQuote(selectedText: text) else { return }
        selectionQuotes = RemoteTerminalSelectionQuote.appending(quote, to: selectionQuotes)
    }

    private func removeSelectionQuote(_ id: UUID) {
        selectionQuotes.removeAll { $0.id == id }
    }

    /// Types the quotes at the TUI's cursor, as one paste when the program has bracketed paste
    /// on. Return stays with the person: the TUI still owns editing and submission.
    private func insertSelectionQuotes() {
        guard canInsertSelectionQuotes, !selectionQuotes.isEmpty else { return }
        connection.sendTerminalKey(RemoteTerminalSelectionQuote.insertionText(
            for: selectionQuotes,
            bracketedPaste: keyBridge.bracketedPasteActive
        ))
        selectionQuotes = []
    }

    private var isSelectionQuoteEvidence: Bool {
        #if DEBUG
            ProcessInfo.processInfo.environment[MobileDemoScene.environmentKey] == "terminal-selection"
        #else
            false
        #endif
    }

    private func seedSelectionQuotesForEvidence() {
        #if DEBUG
            guard isSelectionQuoteEvidence, selectionQuotes.isEmpty,
                  let quote = RemoteTerminalSelectionQuote(selectedText: """
                  nginx: [emerg] unknown directive "serer_name" in /etc/nginx/sites-enabled/app:12
                  nginx: configuration file /etc/nginx/nginx.conf test failed
                  """) else { return }
            selectionQuotes = [quote]
        #endif
    }

    // MARK: - Clipboard

    private func beginChoosingDirectAttachmentSource() {
        guard directAttachmentPicksInFlight == 0,
              directAttachmentTray?.canAcceptMore == true else { return }
        clipboardOffersContent = ComposerClipboard.general.hasContent
        isChoosingDirectAttachmentSource = true
    }

    private var directAttachmentSourceActions: [ThemedDialogAction] {
        var actions: [ThemedDialogAction] = []
        // First, because it is the one that answers "the thing I just copied". The pickers are
        // for choosing something; this is for the thing already in hand.
        if clipboardOffersContent {
            actions.append(ThemedDialogAction("From Clipboard") {
                pendingDirectAttachmentSource = .clipboard
            })
        }
        actions.append(ThemedDialogAction("Photo Library") {
            pendingDirectAttachmentSource = .photos
        })
        actions.append(ThemedDialogAction("Files") {
            pendingDirectAttachmentSource = .files
        })
        actions.append(ThemedDialogAction("Cancel", role: .cancel))
        return actions
    }

    /// Puts whatever is on the clipboard into the live TUI.
    ///
    /// Files take the route the pickers take — staged, uploaded, and their workspace paths typed
    /// at the cursor — because a program reading a PTY has nowhere to put a picture. Text is
    /// typed at the cursor as one paste, which is all the edit menu's own Paste does and saves a
    /// long press aimed at a single prompt line while an agent is drawing over it.
    private func pasteClipboardIntoTerminal() {
        let clipboard = ComposerClipboard.general
        let files = clipboard.files()
        if !files.isEmpty {
            guard let tray = directAttachmentTray else { return }
            for file in files {
                tray.add(data: file.data, name: file.name, type: file.type)
            }
            return
        }
        if let text = clipboard.text() {
            connection.sendTerminalKey(RemoteTerminalPaste.delimited(
                text,
                bracketedPaste: keyBridge.bracketedPasteActive
            ))
            return
        }
        // Nothing was taken, so say why. A raw terminal write is acknowledged by nothing, and a
        // paste that silently did not happen is the failure this whole path exists to remove.
        directAttachmentNotice = clipboard.holdsOversizedText()
            ? MobileL10n.string("That is more text than one paste can carry.")
            : MobileL10n.string("There’s nothing on the clipboard to paste.")
        showsDirectAttachmentNotice = true
    }

    private func configureDirectAttachments() {
        guard directAttachmentTray == nil, let client = model.client else { return }
        let tray = ComposerAttachmentTray(
            client: client,
            uploadScopeID: connection.session.id
        )
        tray.onChange = {
            // A failed upload has no chip to be dismissed from here — this surface shows no
            // attachment strip at all — so one left in the tray holds a slot out of the
            // message's file limit for as long as the session is open. It goes the moment it
            // fails, on account of having failed; the notice the tray raises alongside it is
            // what the person is actually told. Removing it because *some* notice appeared
            // meant an unrelated one — a file that could not be read, one file too many — swept
            // away chips that had nothing to do with it.
            tray.removeFailed()
            // Only ever *set* the notice from the tray, never clear it. Mirroring the tray's
            // notice in both directions meant any change to the tray — clearing it after an
            // insertion, most of all — silently erased a message this view had raised about the
            // insertion itself. That is why clearing the tray used to snapshot the notice and
            // write it back afterwards: two different facts were sharing one variable.
            if let notice = tray.notice {
                directAttachmentNotice = notice
                showsDirectAttachmentNotice = true
            }
            insertDirectAttachmentsIfReady()
        }
        directAttachmentTray = tray
    }

    private func loadDirectAttachmentPhotos(_ items: [PhotosPickerItem]) async {
        guard let tray = directAttachmentTray else { return }
        // A pick is not finished when its first file is. Every `loadTransferable` suspends —
        // a photo may still be coming down from iCloud — and the first file's upload can finish
        // inside one of those gaps. Without this the tray looked settled between two photos, the
        // first was inserted on its own, and the acceptance that followed cleared the tray and
        // cancelled the uploads of the ones still being read: three photos chosen, one inserted,
        // two gone, and nothing said about either.
        directAttachmentPicksInFlight += 1
        defer {
            directAttachmentPicksInFlight -= 1
            insertDirectAttachmentsIfReady()
        }
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let type = item.supportedContentTypes.first
            else {
                tray.reportUnreadableFile()
                continue
            }
            tray.add(
                data: data,
                name: "photo-\(UUID().uuidString.prefix(8)).\(type.preferredFilenameExtension ?? "jpg")",
                type: type
            )
        }
        directAttachmentPhotoItems = []
    }

    private func importDirectAttachmentFiles(_ result: Result<[URL], Error>) {
        guard let urls = try? result.get() else {
            directAttachmentTray?.reportUnreadableFile()
            return
        }
        guard !urls.isEmpty else { return }
        directAttachmentPicksInFlight += 1
        Task { @MainActor in
            defer {
                directAttachmentPicksInFlight -= 1
                insertDirectAttachmentsIfReady()
            }
            guard let tray = directAttachmentTray else { return }
            for url in urls.prefix(remainingDirectAttachmentSlots) {
                let accessed = url.startAccessingSecurityScopedResource()
                let loaded = await Task.detached(priority: .userInitiated) {
                    let data = ComposerAttachmentSources.readFile(at: url)
                    let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
                        ?? UTType(filenameExtension: url.pathExtension)
                    return data.flatMap { data in type.map { (data, $0) } }
                }.value
                if accessed { url.stopAccessingSecurityScopedResource() }
                guard let (data, type) = loaded else {
                    tray.reportUnreadableFile()
                    continue
                }
                tray.add(data: data, name: url.lastPathComponent, type: type)
            }
        }
    }

    /// A direct terminal already has the TUI's own attachment affordance. Once the upload has
    /// reached the Mac, type its path at the cursor immediately instead of asking the person to
    /// manage a second attachment row and press a second Insert button.
    private func insertDirectAttachmentsIfReady() {
        guard allowsDirectInput,
              directAttachmentPicksInFlight == 0,
              pendingDirectAttachmentInsertionID == nil,
              directAttachmentTray?.isSettling == false else { return }
        guard let ids = directAttachmentTray?.readyUploadIDs,
              !ids.isEmpty,
              let requestID = connection.insertTerminalAttachments(ids) else { return }
        directAttachmentNotice = nil
        pendingDirectAttachmentInsertionID = requestID
    }

    /// How long a busy Mac is waited out before its files are given up on. The terminal counts
    /// as busy for as long as one submission is in flight, so waiting costs nothing but the
    /// wait — and it still has to end somewhere, or a Mac answering busy forever would keep the
    /// phone holding the same files for as long as the session stayed open.
    private static let maximumDirectAttachmentBusyRetries = 2

    private func handleDirectAttachmentInsertion(
        _ feedback: RemotePromptSubmissionFeedback?
    ) {
        guard let feedback,
              feedback.requestID == pendingDirectAttachmentInsertionID else { return }
        pendingDirectAttachmentInsertionID = nil
        switch feedback.status {
        case .accepted:
            directAttachmentBusyRetries = 0
            directAttachmentTray?.clear()
            directAttachmentNotice = nil
            return
        case .busy where directAttachmentBusyRetries
            < Self.maximumDirectAttachmentBusyRetries:
            // Busy is a moment, not a refusal: the Mac is part-way through another submission.
            // The bytes are already on it, so discarding them charges the person a second pick
            // for somebody else's timing. Hold them, and try again the moment the terminal
            // stops submitting.
            directAttachmentBusyRetries += 1
            directAttachmentNotice = MobileL10n.string(
                "The Mac was busy. These files will be inserted in a moment."
            )
        case .busy, .rejected:
            directAttachmentBusyRetries = 0
            directAttachmentTray?.clear()
            directAttachmentNotice = MobileL10n.string(
                "The Mac couldn’t insert these files. Please choose them again."
            )
        case .unavailable:
            directAttachmentBusyRetries = 0
            directAttachmentTray?.clear()
            directAttachmentNotice = MobileL10n.string(
                "The session changed before these files could be inserted. Please choose them again."
            )
        case .conflict:
            directAttachmentBusyRetries = 0
            directAttachmentTray?.clear()
            directAttachmentNotice = MobileL10n.string(
                "These files could not be inserted safely. Please choose them again."
            )
        }
        showsDirectAttachmentNotice = directAttachmentNotice != nil
    }
}

private enum DirectAttachmentSource {
    case photos
    case files
    case clipboard
}

private struct TerminalCollaborationBar: View {
    @ObservedObject var connection: RemoteSessionConnection
    let askForInput: () -> Void
    @EnvironmentObject private var notifications: RemoteNotificationManager
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        let people = Array(connection.presence.values)
        let typing = uniqueNames(people.filter { $0.state == .typing })
        let viewing = uniqueNames(people)
        let label = notifications.typingIndicatorsEnabled && !typing.isEmpty
            ? label(for: typing, action: .typing)
            : notifications.peoplePresenceEnabled && !viewing.isEmpty
            ? label(for: viewing, action: .viewing)
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

    private func label(for names: [String], action: RemotePresenceState) -> String {
        if names.count == 1 {
            return action == .typing
                ? MobileL10n.string("%@ is typing…", names[0])
                : MobileL10n.string("%@ is here", names[0])
        }
        if names.count == 2 {
            let joined = names.joined(separator: MobileL10n.string(" and "))
            return action == .typing
                ? MobileL10n.string("%@ are typing…", joined)
                : MobileL10n.string("%@ are here", joined)
        }
        return action == .typing
            ? MobileL10n.string("%lld people are typing…", Int64(names.count))
            : MobileL10n.string("%lld people are here", Int64(names.count))
    }
}

private struct TerminalLineComposer: View {
    @ObservedObject var connection: RemoteSessionConnection
    @ObservedObject var bridge: TerminalKeyBridge
    @Binding var quotes: [RemoteTerminalSelectionQuote]
    /// Writing here was writing in this chat: a chat left mid-draft opens with the composer
    /// focused again, within the keyboard memory's recall.
    var focusesOnAppear = false
    @EnvironmentObject private var model: RemoteAppModel
    @EnvironmentObject private var continuity: MobileSessionContinuityStore
    @Environment(\.remoteTheme) private var theme
    @State private var draft = ""
    @State private var pendingSubmissionID: String?
    /// The draft as it was when the pending line left, so acceptance clears only a draft the
    /// person has not edited since.
    @State private var pendingSubmissionDraft: String?
    @State private var submissionNotice: String?
    @State private var attachmentTray: ComposerAttachmentTray?
    @State private var attachmentItems: [ComposerAttachmentItem] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var attachmentPicksInFlight = 0
    @State private var isPickingPhotos = false
    @State private var isImportingFiles = false
    /// Whether the clipboard is holding a file worth offering. A `Menu` has no moment of
    /// opening to hang the question on, so it is answered when this composer appears and again
    /// whenever the pasteboard could have changed — rather than on every body evaluation, which
    /// a live terminal performs constantly.
    @State private var clipboardOffersFiles = false
    /// The editor is UIKit-owned, so first-responder truth comes back through a plain binding.
    @State private var draftIsFocused = false

    var body: some View {
        VStack(spacing: 0) {
            if connection.isPromptSubmissionPending, pendingSubmissionID != nil {
                statusLabel("Sending once…", showsProgress: true)
            } else if let submissionNotice {
                statusLabel(submissionNotice, isWarning: true)
            }

            if !attachmentItems.isEmpty {
                ComposerAttachmentStrip(
                    items: attachmentItems,
                    theme: theme,
                    isRemovalEnabled: !connection.isPromptSubmissionPending,
                    remove: { attachmentTray?.remove($0) }
                )
            }
            if !quotes.isEmpty {
                TerminalSelectionQuoteTray(
                    quotes: quotes,
                    placement: .inComposer,
                    remove: { id in quotes.removeAll { $0.id == id } }
                )
            }

            ZStack(alignment: .topLeading) {
                TerminalLinePromptEditor(
                    text: $draft,
                    isFocused: $draftIsFocused,
                    theme: theme,
                    onSubmit: submit
                )
                .mobileUIEvidenceKeyboardFocus($draftIsFocused)

                if draft.isEmpty {
                    Text("Compose on this device…")
                        .font(.body)
                        .foregroundStyle(theme.secondaryLabel)
                        .padding(.top, TerminalLinePromptMetrics.textInsets.top)
                        .padding(.leading, MobileDesign.Size.minimumTapTarget)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            // Both controls retain their full 44-point targets. They occupy only the first line,
            // while the editor's text-container exclusions let every later line run beneath.
            .overlay(alignment: .topLeading) { attachmentMenu }
            .overlay(alignment: .topTrailing) { sendButton }
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
        .onAppear(perform: configureAttachments)
        .onAppear { if focusesOnAppear { draftIsFocused = true } }
        .onChange(of: draftIsFocused) { _, focused in
            if focused { bridge.noteKeyboardWanted() }
        }
        .onAppear(perform: refreshClipboardOffer)
        // A pasteboard written in another app raises no notification here, so returning to the
        // foreground is the moment that has to ask again; the local notification covers a copy
        // made inside this app without waiting for a trip through the switcher.
        .onReceive(
            NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)
        ) { _ in refreshClipboardOffer() }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication.didBecomeActiveNotification
            )
        ) { _ in refreshClipboardOffer() }
        .onChange(of: photoItems) { _, items in
            Task { await loadPhotos(items) }
        }
        .photosPicker(
            isPresented: $isPickingPhotos,
            selection: $photoItems,
            maxSelectionCount: remainingAttachmentSlots,
            matching: .any(of: [.images, .videos])
        )
        .fileImporter(
            isPresented: $isImportingFiles,
            allowedContentTypes: ComposerAttachmentSources.documentTypes,
            allowsMultipleSelection: true
        ) { result in
            importFiles(result)
        }
    }

    private var canSubmit: Bool {
        connection.phase == .connected
            && connection.capability == .interact
            && connection.inputControl?.canWrite != false
            && !connection.isPromptSubmissionPending
            && attachmentPicksInFlight == 0
            && attachmentTray?.isSettling != true
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !quotes.isEmpty
                || attachmentTray?.readyUploadIDs.isEmpty == false)
    }

    private var attachmentMenu: some View {
        Menu {
            // Text pastes into the draft itself, at the insertion point, the way the system has
            // always done it. This entry is for what that cannot carry: a picture has no text to
            // insert, and a copied one is in neither picker.
            if clipboardOffersFiles {
                Button(action: stageClipboardFiles) {
                    Label(
                        MobileL10n.string("From Clipboard"),
                        systemImage: "doc.on.clipboard"
                    )
                }
            }
            // A PhotosPicker inside a Menu is torn down with the menu before its sheet can
            // present; the item requests presentation and .photosPicker below shows it.
            Button {
                isPickingPhotos = true
            } label: {
                Label(MobileL10n.string("Photo Library"), systemImage: "photo.on.rectangle")
            }
            Button {
                isImportingFiles = true
            } label: {
                Label("Files", systemImage: "folder")
            }
        } label: {
            Image(systemName: "paperclip")
                .font(.headline)
                .frame(
                    width: MobileDesign.Size.minimumTapTarget,
                    height: MobileDesign.Size.minimumTapTarget
                )
        }
        .disabled(
            connection.isPromptSubmissionPending
                || attachmentPicksInFlight > 0
                || attachmentTray?.canAcceptMore != true
        )
        .accessibilityLabel(MobileL10n.string("Attachments"))
    }

    private var sendButton: some View {
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
        let line = RemoteTerminalSelectionQuote.submissionText(
            for: quotes,
            draft: draft,
            bracketedPaste: bridge.bracketedPasteActive
        )
        if let requestID = connection.submitTerminalLine(
            line,
            attachmentUploadIDs: attachmentTray?.readyUploadIDs ?? []
        ) {
            pendingSubmissionID = requestID
            pendingSubmissionDraft = draft
        }
    }

    private var remainingAttachmentSlots: Int {
        max(
            1,
            RemoteAttachmentUploadLimits.maximumPerMessage - (attachmentTray?.items.count ?? 0)
        )
    }

    private func configureAttachments() {
        guard attachmentTray == nil, let client = model.client else { return }
        let tray = ComposerAttachmentTray(
            client: client,
            uploadScopeID: connection.session.id
        )
        tray.onChange = {
            attachmentItems = tray.items
            submissionNotice = tray.notice
        }
        attachmentTray = tray
    }

    private func refreshClipboardOffer() {
        clipboardOffersFiles = ComposerClipboard.general.hasFiles
    }

    private func stageClipboardFiles() {
        guard let tray = attachmentTray else { return }
        let files = ComposerClipboard.general.files()
        guard !files.isEmpty else {
            // Between drawing the entry and choosing it, the clipboard changed under it.
            refreshClipboardOffer()
            submissionNotice = MobileL10n.string("There’s nothing on the clipboard to attach.")
            return
        }
        for file in files {
            tray.add(data: file.data, name: file.name, type: file.type)
        }
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty, let tray = attachmentTray else { return }
        attachmentPicksInFlight += 1
        defer { attachmentPicksInFlight -= 1 }
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let type = item.supportedContentTypes.first
            else {
                tray.reportUnreadableFile()
                continue
            }
            tray.add(
                data: data,
                name: "photo-\(UUID().uuidString.prefix(8)).\(type.preferredFilenameExtension ?? "jpg")",
                type: type
            )
        }
        photoItems = []
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        guard let urls = try? result.get() else {
            attachmentTray?.reportUnreadableFile()
            return
        }
        guard !urls.isEmpty else { return }
        attachmentPicksInFlight += 1
        Task { @MainActor in
            defer { attachmentPicksInFlight -= 1 }
            guard let tray = attachmentTray else { return }
            for url in urls.prefix(remainingAttachmentSlots) {
                let accessed = url.startAccessingSecurityScopedResource()
                let loaded = await Task.detached(priority: .userInitiated) {
                    let data = ComposerAttachmentSources.readFile(at: url)
                    let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
                        ?? UTType(filenameExtension: url.pathExtension)
                    return data.flatMap { data in type.map { (data, $0) } }
                }.value
                if accessed { url.stopAccessingSecurityScopedResource() }
                guard let (data, type) = loaded else {
                    tray.reportUnreadableFile()
                    continue
                }
                tray.add(data: data, name: url.lastPathComponent, type: type)
            }
        }
    }

    private func restoreDraft() {
        #if DEBUG
            if ProcessInfo.processInfo.environment[MobileDemoScene.environmentKey]
                == "terminal-compose"
            {
                draft = "Review the attachment spacing, then let every wrapped line use the full composer width."
                return
            }
        #endif
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
        let sentDraft = pendingSubmissionDraft
        pendingSubmissionDraft = nil
        if feedback.status == .accepted {
            if draft == sentDraft {
                draft = ""
            }
            quotes = []
            submissionNotice = nil
            attachmentTray?.clear()
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

/// The atomic terminal composer uses one native text container so its first line can flow around
/// overlaid actions and its later lines can reclaim their width. A SwiftUI multiline `TextField`
/// is a single rectangular layout item and therefore cannot express this first-line-only shape.
struct TerminalLinePromptEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let theme: RemoteThemePalette
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: $isFocused, onSubmit: onSubmit)
    }

    func makeUIView(context: Context) -> IntrinsicTextView {
        let view = TerminalLineTextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.isOpaque = false
        view.font = TerminalLinePromptMetrics.font
        view.textContainerInset = TerminalLinePromptMetrics.textInsets
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.adjustsFontForContentSizeCategory = true
        view.autocapitalizationType = .none
        view.autocorrectionType = .no
        view.returnKeyType = .send
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.accessibilityLabel = MobileL10n.string("Compose on this device…")
        view.minimumIntrinsicHeight = MobileDesign.Size.minimumTapTarget
        view.maximumIntrinsicHeight = TerminalLinePromptMetrics.maximumHeight
        view.firstLineLeadingAccessoryWidth = MobileDesign.Size.minimumTapTarget
        view.firstLineTrailingAccessoryWidth = MobileDesign.Size.minimumTapTarget
        view.firstLineAccessoryHeight = MobileDesign.Size.minimumTapTarget
        return view
    }

    func updateUIView(_ view: IntrinsicTextView, context: Context) {
        context.coordinator.onSubmit = onSubmit
        if view.text != text {
            view.text = text
            view.invalidateIntrinsicContentSize()
        }
        view.font = TerminalLinePromptMetrics.font
        view.textContainerInset = TerminalLinePromptMetrics.textInsets
        view.textColor = theme.uiLabel
        view.tintColor = theme.uiAccent
        view.minimumIntrinsicHeight = MobileDesign.Size.minimumTapTarget
        view.maximumIntrinsicHeight = TerminalLinePromptMetrics.maximumHeight
        view.firstLineLeadingAccessoryWidth = MobileDesign.Size.minimumTapTarget
        view.firstLineTrailingAccessoryWidth = MobileDesign.Size.minimumTapTarget
        view.firstLineAccessoryHeight = MobileDesign.Size.minimumTapTarget

        if isFocused, !view.isFirstResponder {
            Task { @MainActor [weak view] in
                guard let view, isFocused, view.window != nil else { return }
                view.becomeFirstResponder()
            }
        } else if !isFocused, view.isFirstResponder {
            view.resignFirstResponder()
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: IntrinsicTextView,
        context _: Context
    ) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        uiView.updateFirstLineAccessoryExclusions(for: width)
        let measured = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        return CGSize(
            width: width,
            height: min(
                max(measured.height, MobileDesign.Size.minimumTapTarget),
                uiView.maximumIntrinsicHeight
            )
        )
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        private var text: Binding<String>
        private var isFocused: Binding<Bool>
        var onSubmit: () -> Void

        init(
            text: Binding<String>,
            isFocused: Binding<Bool>,
            onSubmit: @escaping () -> Void
        ) {
            self.text = text
            self.isFocused = isFocused
            self.onSubmit = onSubmit
        }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
            textView.invalidateIntrinsicContentSize()
        }

        func textViewDidBeginEditing(_: UITextView) {
            isFocused.wrappedValue = true
        }

        func textViewDidEndEditing(_: UITextView) {
            isFocused.wrappedValue = false
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn _: NSRange,
            replacementText replacement: String
        ) -> Bool {
            guard replacement == "\n", textView.markedTextRange == nil else { return true }
            onSubmit()
            return false
        }
    }
}

private enum TerminalLinePromptMetrics {
    static let maximumLines: CGFloat = 5
    static var font: UIFont { .preferredFont(forTextStyle: .body) }
    static var textInsets: UIEdgeInsets {
        let vertical = max(
            0,
            (MobileDesign.Size.minimumTapTarget - font.lineHeight) / 2
        )
        return UIEdgeInsets(top: vertical, left: 0, bottom: vertical, right: 0)
    }

    static var maximumHeight: CGFloat {
        let insets = textInsets
        return ceil(font.lineHeight * maximumLines + insets.top + insets.bottom)
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
    @State private var capabilityKindFilter: RemoteComposerCapabilityKind?
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
                       !value.isEmpty
                    {
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
                if $0.kind != $1.kind { return $0.kind == .command }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                    == .orderedAscending
            }
        } else {
            return []
        }
        guard let capabilityKindFilter else { return items }
        if capabilityKindFilter == .skill {
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
           })
        {
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
        draft = skill.trigger == .dollar ? "$" : "/"
        showsCapabilityCatalog = true
        capabilityKindFilter = .skill
    }

    @ViewBuilder
    private var presenceBanner: some View {
        let people = Array(connection.presence.values)
        let typingNames = uniqueNames(people.filter { $0.state == .typing })
        let viewingNames = uniqueNames(people)
        if notifications.typingIndicatorsEnabled, !typingNames.isEmpty {
            let label = presenceLabel(names: typingNames, action: .typing)
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
            let label = presenceLabel(names: viewingNames, action: .viewing)
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
           pendingSubmissionID != nil
        {
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

    private func presenceLabel(names: [String], action: RemotePresenceState) -> String {
        if names.count == 1 {
            return action == .typing
                ? MobileL10n.string("%@ is typing…", names[0])
                : MobileL10n.string("%@ is here", names[0])
        }
        if names.count == 2 {
            let joined = names.joined(separator: MobileL10n.string(" and "))
            return action == .typing
                ? MobileL10n.string("%@ are typing…", joined)
                : MobileL10n.string("%@ are here", joined)
        }
        return action == .typing
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
            ProcessInfo.processInfo.environment[MobileDemoScene.environmentKey]
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
          deviceName != presence.displayName
    else {
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
                .lineLimit(1 ... 6)
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
                            send(action: .request)
                        }
                        .buttonStyle(.borderless)
                        .font(.caption.weight(.semibold))
                        .padding(.trailing, MobileDesign.Spacing.inset)
                    }

                    if state.canManage || state.canHandOff {
                        Menu {
                            if state.canManage, state.mode != .collaborative {
                                Button(MobileL10n.string("Collaborative")) {
                                    send(action: .collaborative)
                                }
                            }
                            if state.canManage, !state.canWrite {
                                Button(MobileL10n.string("Reclaim control")) {
                                    send(action: .reclaim)
                                }
                            }
                            if state.mode == .collaborative, state.canManage {
                                Button(MobileL10n.string("Focus on me")) {
                                    send(
                                        action: .focused,
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
                                            action: .handoff,
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

    private func send(action: RemoteInputControlAction, targetID: String? = nil) {
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
               context.date.timeIntervalSince1970 - event.createdAt < 90
            {
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
                        .lineLimit(2 ... 4)
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
                                    Text(item.kind == .skill
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
