import SwiftUI
import ThreadingRemoteKit

#if os(iOS)
/// A standalone project shell on the paired Mac.
///
/// The connection reuses the terminal renderer, but the screen intentionally owns none of the
/// chat lifecycle: no workspace, archive, pin, snooze, agent surface, or permission approval.
struct ProjectTerminalDetailView: View {
    @EnvironmentObject private var model: RemoteAppModel
    @Environment(\.remoteTheme) private var theme
    let terminal: RemoteProjectTerminalSummaryDTO

    @State private var connection: RemoteSessionConnection?
    @State private var launchError: String?
    @State private var actionError: String?
    @State private var pendingShareCapability: String?
    @State private var sharedLink: SharedSessionLink?
    @State private var isMutating = false

    private var currentTerminal: RemoteProjectTerminalSummaryDTO {
        model.me?.terminals?.first(where: { $0.id == terminal.id }) ?? terminal
    }

    var body: some View {
        Group {
            if let connection {
                TerminalRemoteView(connection: connection)
            } else if let launchError {
                ContentUnavailableView {
                    Label(
                        MobileL10n.string("Couldn’t open terminal"),
                        systemImage: "exclamationmark.triangle"
                    )
                } description: {
                    Text(launchError)
                } actions: {
                    Button(MobileL10n.string("Try Again")) {
                        self.launchError = nil
                        Task { await open() }
                    }
                }
            } else {
                MobileLoadingPlaceholder(MobileL10n.string(
                    currentTerminal.isAvailable
                        ? "Opening terminal…"
                        : "Starting terminal on your Mac…"
                ))
            }
        }
        .navigationTitle(currentTerminal.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.canManageSessions {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            pendingShareCapability = RemoteCapability.view.rawValue
                        } label: {
                            Label(MobileL10n.string("Share view-only link"), systemImage: "eye")
                        }
                        .disabled(!currentTerminal.isAvailable || isMutating)

                        Button {
                            pendingShareCapability = RemoteCapability.interact.rawValue
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
        .task { await open() }
        .onDisappear { connection?.disconnect(markEnded: false) }
        .sheet(item: $sharedLink) { link in
            SharedSessionLinkView(link: link)
                .mobileTheme(theme)
        }
        .themedConfirmationDialog(
            pendingShareCapability == RemoteCapability.view.rawValue
                ? MobileL10n.string("Share terminal for viewing?")
                : MobileL10n.string("Share full terminal control?"),
            message: pendingShareCapability == RemoteCapability.view.rawValue
                ? MobileL10n.string("The link can watch this terminal’s output while its shell is running.")
                : MobileL10n.string("Anyone who accepts can start the shell and run commands as your Mac user. The project folder is only its starting directory, not a security boundary."),
            isPresented: Binding(
                get: { pendingShareCapability != nil },
                set: { if !$0 { pendingShareCapability = nil } }
            ),
            actions: [
                ThemedDialogAction(MobileL10n.string("Create link"), systemImage: "link") {
                    createShare()
                },
                ThemedDialogAction(MobileL10n.string("Cancel"), role: .cancel) {
                    pendingShareCapability = nil
                },
            ]
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

    private func open() async {
        do {
            guard let hostID = model.activeHostID else {
                throw RemoteClientError.invalidResponse
            }
            try await model.makeTerminalReady(currentTerminal)
            guard let client = model.client else { throw RemoteClientError.invalidResponse }
            let latest = model.me?.terminals?.first(where: { $0.id == terminal.id }) ?? terminal
            let presentation = RemoteSessionSummaryDTO(
                id: latest.id,
                title: latest.title,
                agentKind: "terminal",
                surface: .terminal,
                state: latest.state,
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
                reconnectClient: { attempt in
                    await model.clientForSessionReconnect(hostID: hostID, attempt: attempt)
                }
            )
            connection = made
            made.connect()
        } catch is CancellationError {
            return
        } catch {
            MobileDiagnostics.logDegraded(.sessionAction, error: error)
            launchError = error.localizedDescription
        }
    }

    private func createShare() {
        guard let capability = pendingShareCapability else { return }
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

#endif
