import SwiftUI
import ThreadingRemoteKit
import UIKit

#if os(iOS)
/// The host-owned phases of opening a standalone project terminal.
///
/// This is operational truth, not extension presentation: the Mac readiness request settles
/// `startingOnMac`, then the bounded socket hello and terminal hydration settle `openingTerminal`.
/// A cached catalogue row chooses only the first sentence; the live catalogue and connection own
/// every later transition.
enum ProjectTerminalOpeningPhase: Equatable {
    case startingOnMac
    case openingTerminal

    init(isAvailable: Bool) {
        self = isAvailable ? .openingTerminal : .startingOnMac
    }

    var message: String {
        switch self {
        case .startingOnMac:
            return MobileL10n.string("Starting terminal on your Mac…")
        case .openingTerminal:
            return MobileL10n.string("Opening terminal…")
        }
    }
}

struct ProjectTerminalOpeningAttemptID: Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

@MainActor
struct ProjectTerminalOpeningAttempt {
    let id: ProjectTerminalOpeningAttemptID
    var phase: ProjectTerminalOpeningPhase
    var connection: RemoteSessionConnection?

    init(
        id: ProjectTerminalOpeningAttemptID = ProjectTerminalOpeningAttemptID(),
        phase: ProjectTerminalOpeningPhase,
        connection: RemoteSessionConnection? = nil
    ) {
        self.id = id
        self.phase = phase
        self.connection = connection
    }
}

enum ProjectTerminalOpeningFailure: Equatable {
    case preparation(String)
    case connection(RemoteConnectionFailure)
    case ended(String)

    var message: String {
        switch self {
        case let .preparation(message), let .ended(message): return message
        case let .connection(failure): return failure.message
        }
    }

    var recoveryTitle: String {
        switch self {
        case .preparation, .ended: return MobileL10n.string("Try Again")
        case let .connection(failure): return failure.recoveryTitle
        }
    }
}

@MainActor
enum ProjectTerminalOpeningState {
    case opening(ProjectTerminalOpeningAttempt)
    case live(RemoteSessionConnection)
    case failed(ProjectTerminalOpeningFailure)

    var attemptID: ProjectTerminalOpeningAttemptID? {
        guard case let .opening(attempt) = self else { return nil }
        return attempt.id
    }

    var openingPhase: ProjectTerminalOpeningPhase? {
        guard case let .opening(attempt) = self else { return nil }
        return attempt.phase
    }

    var connection: RemoteSessionConnection? {
        switch self {
        case let .opening(attempt): return attempt.connection
        case let .live(connection): return connection
        case .failed: return nil
        }
    }

    var failure: ProjectTerminalOpeningFailure? {
        guard case let .failed(failure) = self else { return nil }
        return failure
    }

    func owns(_ attemptID: ProjectTerminalOpeningAttemptID) -> Bool {
        self.attemptID == attemptID
    }

    func isOpening(_ connection: RemoteSessionConnection) -> Bool {
        guard case let .opening(attempt) = self else { return false }
        return attempt.connection === connection
    }
}

enum ProjectTerminalConnectionOpeningOutcome: Equatable {
    case pending
    case ready
    case failed(ProjectTerminalOpeningFailure)

    static func resolve(
        phase: RemoteSessionConnection.Phase,
        isTerminalHydrating: Bool
    ) -> ProjectTerminalConnectionOpeningOutcome {
        switch phase {
        case .connecting:
            return .pending
        case .connected:
            return isTerminalHydrating ? .pending : .ready
        case let .ended(reason):
            return .failed(.ended(reason))
        case let .failed(failure):
            return .failed(.connection(failure))
        }
    }
}

#if DEBUG
    /// Standalone-terminal opening phases held still in the shipping detail shell for evidence.
    enum MobileProjectTerminalOpeningFixture: String {
        case starting = "project-terminal-opening-starting"
        case connecting = "project-terminal-opening-connecting"

        var phase: ProjectTerminalOpeningPhase {
            switch self {
            case .starting: return .startingOnMac
            case .connecting: return .openingTerminal
            }
        }

        var terminal: RemoteProjectTerminalSummaryDTO {
            RemoteProjectTerminalSummaryDTO(
                id: "project-terminal-opening-demo",
                title: "rindastudio",
                projectName: "rindastudio",
                state: self == .starting ? .dormant : .idle,
                isAvailable: self == .connecting
            )
        }
    }
#endif

/// A standalone project shell on the paired Mac.
///
/// The connection reuses the terminal renderer, but the screen intentionally owns none of the
/// chat lifecycle: no workspace, archive, pin, snooze, agent surface, or permission approval.
struct ProjectTerminalDetailView: View {
    private enum OpeningExecution {
        case automatic
        #if DEBUG
            /// A screenshot fixture holds typed presentation only and is forbidden to open.
            case heldEvidence
        #endif
    }

    @EnvironmentObject private var model: RemoteAppModel
    @Environment(\.remoteTheme) private var theme
    @Environment(\.openURL) private var openURL
    let terminal: RemoteProjectTerminalSummaryDTO
    private let openingExecution: OpeningExecution

    @State private var openingState: ProjectTerminalOpeningState
    /// The Mac `connection` was opened against, so a route move on another Mac is not adopted.
    @State private var connectedHostID: String?
    @State private var actionError: String?
    @State private var pendingShareCapability: RemoteCapability?
    @State private var sharedLink: SharedSessionLink?
    @State private var isMutating = false

    init(terminal: RemoteProjectTerminalSummaryDTO) {
        self.terminal = terminal
        openingExecution = .automatic
        _openingState = State(initialValue: .opening(ProjectTerminalOpeningAttempt(
            phase: ProjectTerminalOpeningPhase(isAvailable: terminal.isAvailable)
        )))
    }

    #if DEBUG
        init(evidenceFixture: MobileProjectTerminalOpeningFixture) {
            terminal = evidenceFixture.terminal
            openingExecution = .heldEvidence
            _openingState = State(initialValue: .opening(ProjectTerminalOpeningAttempt(
                phase: evidenceFixture.phase
            )))
        }
    #endif

    private var currentTerminal: RemoteProjectTerminalSummaryDTO {
        model.dashboardTerminal(id: terminal.id) ?? terminal
    }

    var body: some View {
        ZStack {
            if let connection = openingState.connection {
                ProjectTerminalConnectionContent(
                    connection: connection,
                    openingLoaderOwner: openingState.isOpening(connection)
                        ? .containingScreen
                        : .terminalSurface,
                    onOpeningOutcome: { accept($0, from: connection) }
                )
            } else if let failure = openingState.failure {
                ContentUnavailableView {
                    Label(
                        MobileL10n.string("Couldn’t open terminal"),
                        systemImage: "exclamationmark.triangle"
                    )
                } description: {
                    Text(failure.message)
                } actions: {
                    Button(failure.recoveryTitle) { recover(from: failure) }
                }
            } else {
                Color.clear
            }

            // This is one retained view across readiness, connection and hydration. Its finite
            // full-screen geometry is owned here, while MorphLabel changes only the phase words.
            if let phase = openingState.openingPhase {
                MobileLoadingPlaceholder(phase.message)
            }
        }
        .navigationTitle(currentTerminal.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.canManageSessions {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            pendingShareCapability = .view
                        } label: {
                            Label(MobileL10n.string("Share view-only link"), systemImage: "eye")
                        }
                        .disabled(!currentTerminal.isAvailable || isMutating)

                        Button {
                            pendingShareCapability = .interact
                        } label: {
                            Label(
                                MobileL10n.string("Share full-control link"),
                                systemImage: "terminal"
                            )
                        }
                        .disabled(isMutating)

                        if currentTerminal.isShared {
                            Divider()
                            Button(role: .destructive) {
                                revokeShares()
                            } label: {
                                Label(MobileL10n.string("Stop sharing"), systemImage: "person.crop.circle.badge.minus")
                            }
                            .disabled(isMutating)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel(MobileL10n.string("Terminal actions"))
                }
            }
        }
        .toolbarBackground(theme.surface, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .background(theme.ground)
        .task(id: openingState.attemptID) {
            switch openingExecution {
            case .automatic:
                guard let attemptID = openingState.attemptID else { return }
                await open(attemptID: attemptID)
            #if DEBUG
                case .heldEvidence:
                    return
            #endif
            }
        }
        .onChange(of: model.routeIdentity) { _, _ in
            guard let connection = openingState.connection, let client = model.client,
                  model.activeHostID == connectedHostID else { return }
            connection.adoptRoute(client)
        }
        .onDisappear { openingState.connection?.leave() }
        .onChange(of: model.networkPathGeneration) { _, _ in
            openingState.connection?.networkPathChanged()
        }
        .sheet(item: $sharedLink) { link in
            SharedSessionLinkView(link: link)
                .mobileTheme(theme)
        }
        .themedConfirmationDialog(
            pendingShareCapability == .view
                ? MobileL10n.string("Share terminal for viewing?")
                : MobileL10n.string("Share full terminal control?"),
            message: pendingShareCapability == .view
                ? MobileL10n.string("The link can watch this terminal’s output while its shell is running.")
                : MobileL10n.string("Anyone who accepts can start the shell and run commands as your Mac user. The project folder is only its starting directory, not a security boundary."),
            isPresented: Binding(
                get: { pendingShareCapability != nil },
                set: { if !$0 { pendingShareCapability = nil } }
            ),
            actions: shareActions(for: pendingShareCapability)
        )
        .themedAlert(
            MobileL10n.string("Remote action failed"),
            message: actionError ?? "",
            isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            ),
            actions: [ThemedDialogAction(MobileL10n.string("OK"))]
        )
    }

    /// Runs only for the attempt id installed in `openingState`. A retry replaces that id; every
    /// suspension point verifies ownership before it may mutate state or start a socket. The
    /// readiness poll, socket hello and hydration each have bounded deadlines in their owning
    /// types. Cancellation changes no replacement attempt, and every non-cancellation failure
    /// replaces the spinner with a recovery surface.
    private func open(attemptID: ProjectTerminalOpeningAttemptID) async {
        guard openingState.owns(attemptID), openingState.connection == nil else { return }
        do {
            guard let hostID = model.activeHostID else {
                throw RemoteClientError.invalidResponse
            }
            connectedHostID = hostID
            let authoritative = try await model.liveTerminalForOpening(id: terminal.id)
            try Task.checkCancellation()
            guard setOpeningPhase(
                ProjectTerminalOpeningPhase(isAvailable: authoritative.isAvailable),
                for: attemptID
            ) else { return }
            try await model.makeTerminalReady(authoritative)
            try Task.checkCancellation()
            guard setOpeningPhase(.openingTerminal, for: attemptID) else { return }
            guard let client = model.client else { throw RemoteClientError.invalidResponse }
            let latest = model.me?.terminals?.first(where: { $0.id == terminal.id })
                ?? authoritative
            let presentation = RemoteSessionSummaryDTO(
                id: latest.id,
                title: latest.title,
                agentKind: "terminal",
                surface: .terminal,
                state: RemoteSessionActivity(rawValue: latest.state.rawValue),
                projectName: latest.projectName,
                isAvailable: latest.isAvailable,
                lastActiveAt: latest.createdAt,
                isShared: latest.isShared,
                terminalTheme: latest.terminalTheme,
                terminalThemeAssignmentID: latest.terminalThemeAssignmentID,
                inheritedTerminalThemeName: latest.inheritedTerminalThemeName,
                inheritedTerminalTheme: latest.inheritedTerminalTheme
            )
            let made = RemoteSessionConnection(
                session: presentation,
                target: .projectTerminal(latest.id),
                client: client,
                reconnectClient: { request in
                    await model.clientForSessionReconnect(hostID: hostID, request: request)
                }
            )
            guard install(made, for: attemptID) else { return }
            made.connect()
        } catch is CancellationError {
            return
        } catch {
            guard openingState.owns(attemptID) else { return }
            MobileDiagnostics.logDegraded(.sessionAction, error: error)
            openingState = .failed(.preparation(error.localizedDescription))
        }
    }

    @discardableResult
    private func setOpeningPhase(
        _ phase: ProjectTerminalOpeningPhase,
        for attemptID: ProjectTerminalOpeningAttemptID
    ) -> Bool {
        guard case var .opening(attempt) = openingState,
              attempt.id == attemptID else { return false }
        attempt.phase = phase
        openingState = .opening(attempt)
        return true
    }

    private func install(
        _ connection: RemoteSessionConnection,
        for attemptID: ProjectTerminalOpeningAttemptID
    ) -> Bool {
        guard case var .opening(attempt) = openingState,
              attempt.id == attemptID,
              attempt.connection == nil else { return false }
        attempt.connection = connection
        openingState = .opening(attempt)
        return true
    }

    private func accept(
        _ outcome: ProjectTerminalConnectionOpeningOutcome,
        from connection: RemoteSessionConnection
    ) {
        guard openingState.isOpening(connection) else { return }
        switch outcome {
        case .pending:
            return
        case .ready:
            openingState = .live(connection)
        case let .failed(failure):
            connection.disconnect(markEnded: false)
            openingState = .failed(failure)
        }
    }

    private func recover(from failure: ProjectTerminalOpeningFailure) {
        switch failure {
        case .preparation, .ended:
            retryOpening()
        case let .connection(connectionFailure):
            switch connectionFailure.recovery {
            case .reconnect:
                retryOpening()
            case .pairAgain:
                model.isPairing = true
            case .openLocalNetworkSettings:
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                openURL(url)
            case let .openUpdatePage(url):
                openURL(url)
            }
        }
    }

    private func retryOpening() {
        connectedHostID = nil
        openingState = .opening(ProjectTerminalOpeningAttempt(
            phase: ProjectTerminalOpeningPhase(isAvailable: currentTerminal.isAvailable)
        ))
    }

    /// The chosen grant is captured, not read back: the system action sheet clears its
    /// presentation binding before the button's handler runs, and that binding is what holds
    /// `pendingShareCapability`.
    private func shareActions(for capability: RemoteCapability?) -> [ThemedDialogAction] {
        guard let capability else { return [] }
        return [
            ThemedDialogAction(MobileL10n.string("Create link")) {
                createShare(capability: capability)
            },
            ThemedDialogAction(MobileL10n.string("Cancel"), role: .cancel) {
                pendingShareCapability = nil
            },
        ]
    }

    private func createShare(capability: RemoteCapability) {
        pendingShareCapability = nil
        isMutating = true
        Task {
            defer { isMutating = false }
            do {
                let response = try await model.createTerminalShare(
                    for: currentTerminal,
                    capability: capability
                )
                guard let url = URL(string: response.url) else {
                    throw RemoteClientError.invalidResponse
                }
                sharedLink = SharedSessionLink(
                    sessionTitle: currentTerminal.title,
                    url: url,
                    capability: response.capability,
                    canApprovePermissions: false,
                    expiresAt: Date(timeIntervalSince1970: response.expiresAt)
                )
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func revokeShares() {
        isMutating = true
        Task {
            defer { isMutating = false }
            do {
                try await model.revokeTerminalShares(for: currentTerminal)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}

/// Observes exactly the connection installed by one project-terminal opening attempt. Once the
/// parent accepts a terminal outcome this view remains mounted for the live surface, but
/// `openingLoaderOwner` returns to the terminal and later reconnect presentation stays there.
private struct ProjectTerminalConnectionContent: View {
    @ObservedObject var connection: RemoteSessionConnection
    let openingLoaderOwner: TerminalOpeningLoaderOwner
    let onOpeningOutcome: (ProjectTerminalConnectionOpeningOutcome) -> Void

    var body: some View {
        TerminalRemoteView(
            connection: connection,
            openingLoaderOwner: openingLoaderOwner
        )
        .onAppear(perform: publishOpeningOutcome)
        .onChange(of: connection.phase) { _, _ in publishOpeningOutcome() }
        .onChange(of: connection.isTerminalHydrating) { _, _ in publishOpeningOutcome() }
    }

    private func publishOpeningOutcome() {
        guard openingLoaderOwner == .containingScreen else { return }
        onOpeningOutcome(ProjectTerminalConnectionOpeningOutcome.resolve(
            phase: connection.phase,
            isTerminalHydrating: connection.isTerminalHydrating
        ))
    }
}

#endif
