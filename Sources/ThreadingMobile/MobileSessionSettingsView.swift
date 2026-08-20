import SwiftUI
import ThreadingRemoteKit

#if os(iOS)
/// The stable choices shown by the phone for one chat's limit-recovery policy.
///
/// Keeping the presentation as values makes two important compatibility rules testable without
/// rendering a sheet: an older host's missing policy means the control is absent, while a host
/// that advertises account routing always offers the ranked answer even when only one login is
/// currently configured.
struct MobileSessionLimitRecoveryChoice: Equatable, Identifiable {
    let policy: RemoteLimitRecoveryPolicyDTO
    let title: String

    var id: String {
        [policy.action, policy.accountID].compactMap { $0 }.joined(separator: ":")
    }
}

enum MobileSessionSettingsPresentation {
    static func account(
        for session: RemoteSessionSummaryDTO,
        in agent: RemoteAgentChoiceDTO?
    ) -> RemoteAccountChoiceDTO? {
        guard let accountID = session.accountID else { return nil }
        return agent?.accounts?.first { $0.id == accountID }
    }

    static func moveDestinations(
        for session: RemoteSessionSummaryDTO,
        in agent: RemoteAgentChoiceDTO?
    ) -> [RemoteAccountChoiceDTO] {
        guard let currentAccountID = session.accountID else { return [] }
        return agent?.accounts?.filter { $0.id != currentAccountID } ?? []
    }

    static func limitRecoveryChoices(
        for session: RemoteSessionSummaryDTO,
        in agent: RemoteAgentChoiceDTO?
    ) -> [MobileSessionLimitRecoveryChoice] {
        guard session.limitRecovery != nil else { return [] }

        var choices = [
            MobileSessionLimitRecoveryChoice(
                policy: .init(action: RemoteLimitRecoveryPolicyDTO.flagOnly),
                title: MobileL10n.string("Stop and Wait for Me")
            ),
            MobileSessionLimitRecoveryChoice(
                policy: .init(action: RemoteLimitRecoveryPolicyDTO.waitForReset),
                title: MobileL10n.string("Continue at Reset")
            ),
        ]

        // `accounts == nil` is the compatibility signal for a runtime or older host that does
        // not expose account routing. An empty/single list still gets the ranked answer: it can
        // be armed before another login is added, matching the Mac's standing-policy menu.
        if let accounts = agent?.accounts {
            choices.append(.init(
                policy: .init(action: RemoteLimitRecoveryPolicyDTO.resumeOnBestAccount),
                title: MobileL10n.string("Continue on the Best Login")
            ))
            choices.append(contentsOf: accounts
                .filter { $0.id != session.accountID }
                .map { account in
                    .init(
                        policy: .init(
                            action: RemoteLimitRecoveryPolicyDTO.resumeVia,
                            accountID: account.id
                        ),
                        title: MobileL10n.string("Continue as %@", account.name)
                    )
                })
        }
        return choices
    }

    static func limitRecoveryTitle(
        for session: RemoteSessionSummaryDTO,
        in agent: RemoteAgentChoiceDTO?
    ) -> String? {
        guard let policy = session.limitRecovery else { return nil }
        switch policy.action {
        case RemoteLimitRecoveryPolicyDTO.flagOnly:
            return MobileL10n.string("Stop and Wait for Me")
        case RemoteLimitRecoveryPolicyDTO.waitForReset:
            return MobileL10n.string("Continue at Reset")
        case RemoteLimitRecoveryPolicyDTO.resumeOnBestAccount:
            return MobileL10n.string("Continue on the Best Login")
        case RemoteLimitRecoveryPolicyDTO.resumeVia:
            let name = agent?.accounts?.first { $0.id == policy.accountID }?.name
                ?? policy.accountID
            return name.map { MobileL10n.string("Continue as %@", $0) }
        default:
            return nil
        }
    }
}

/// Owner-only operational settings for one running chat.
///
/// Account credentials, recovery execution and usage provenance stay on the Mac. This surface
/// sends only a catalog account ID or a policy choice over the authenticated owner channel.
struct MobileSessionSettingsView: View {
    @EnvironmentObject private var model: RemoteAppModel
    @Environment(\.remoteTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    let sessionID: String
    let onAccountMoved: () -> Void

    @State private var pendingAccount: RemoteAccountChoiceDTO?
    @State private var isConfirmingAccountMove = false
    @State private var isMutating = false
    @State private var errorMessage: String?
    @State private var showsUsage = false

    private var session: RemoteSessionSummaryDTO? {
        let active = model.me?.sessions.first { $0.id == sessionID }
        return active ?? model.me?.archivedSessions?.first { $0.id == sessionID }
    }

    private var agent: RemoteAgentChoiceDTO? {
        guard let session else { return nil }
        return model.me?.newSessionCatalog?.agents.first { $0.id == session.agentKind }
    }

    private var currentAccount: RemoteAccountChoiceDTO? {
        guard let session else { return nil }
        return MobileSessionSettingsPresentation.account(for: session, in: agent)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: MobileDesign.Spacing.pane) {
                    if let session {
                        if session.accountID != nil {
                            settingsSection("Chat") {
                                accountRow(session)
                            }
                        }

                        if session.limitRecovery != nil {
                            settingsSection(
                                "Limits",
                                footer: MobileL10n.string(
                                    "This controls how this chat responds when an account limit "
                                        + "is reached."
                                )
                            ) {
                                limitRecoveryRow(session)
                            }
                        }

                        if model.canReadUsage, model.activeHost != nil {
                            settingsSection("Usage") {
                                settingsActionRow(
                                    symbol: "chart.bar.xaxis",
                                    title: MobileL10n.string("Usage"),
                                    detail: currentAccount?.usageSummary
                                        ?? MobileL10n.string(
                                            "Cost, tokens, limits, and reset history"
                                        )
                                ) {
                                    showsUsage = true
                                }
                            }
                        }
                    } else {
                        ContentUnavailableView(
                            "Chat unavailable",
                            systemImage: "bubble.left.and.exclamationmark.bubble.right"
                        )
                    }
                }
                .padding(.horizontal, MobileDesign.Spacing.inset)
                .padding(.top, MobileDesign.Spacing.medium)
                .padding(.bottom, MobileDesign.Spacing.pane)
            }
            .background(theme.ground)
            .navigationTitle("Chat Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(theme.surface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showsUsage) {
            if let link = model.activeHost?.link {
                RemoteUsageDashboardView(link: link, isDemo: model.isDemo)
                    .mobileTheme(theme)
            }
        }
        .presentationDetents([.large])
        .themedConfirmationDialog(
            MobileL10n.string(
                "Move “%@” to %@?",
                session?.title ?? MobileL10n.string("this chat"),
                pendingAccount?.name ?? MobileL10n.string("this account")
            ),
            message:
                "The agent stops and starts under the new account, then resumes this same "
                + "conversation. Work currently in progress is interrupted.",
            isPresented: $isConfirmingAccountMove,
            actions: [
                ThemedDialogAction("Move Chat", systemImage: "person.crop.circle.badge.arrow.forward") {
                    moveToPendingAccount()
                },
                ThemedDialogAction("Cancel", role: .cancel),
            ]
        )
        .themedAlert(
            "Remote action failed",
            message: errorMessage ?? "",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            ),
            actions: [ThemedDialogAction("OK")]
        )
    }

    private func accountRow(_ session: RemoteSessionSummaryDTO) -> some View {
        Menu {
            let destinations = MobileSessionSettingsPresentation.moveDestinations(
                for: session,
                in: agent
            )
            if destinations.isEmpty {
                Text("No other accounts")
            } else {
                ForEach(destinations) { account in
                    Button(accountMenuTitle(account)) {
                        pendingAccount = account
                        isConfirmingAccountMove = true
                    }
                }
            }
        } label: {
            settingsRow(
                symbol: "person.crop.circle",
                title: MobileL10n.string("Account"),
                detail: accountDetail(session),
                showsChevron: true
            )
        }
        .buttonStyle(.plain)
        .disabled(isMutating)
    }

    private func limitRecoveryRow(_ session: RemoteSessionSummaryDTO) -> some View {
        Menu {
            ForEach(MobileSessionSettingsPresentation.limitRecoveryChoices(
                for: session,
                in: agent
            )) { choice in
                Button {
                    setLimitRecovery(choice.policy, for: session)
                } label: {
                    if choice.policy == session.limitRecovery {
                        Label(choice.title, systemImage: "checkmark")
                    } else {
                        Text(choice.title)
                    }
                }
            }
        } label: {
            settingsRow(
                symbol: "clock.arrow.circlepath",
                title: MobileL10n.string("When the Limit Is Reached"),
                detail: MobileSessionSettingsPresentation.limitRecoveryTitle(
                    for: session,
                    in: agent
                ),
                showsChevron: true
            )
        }
        .buttonStyle(.plain)
        .disabled(isMutating)
    }

    private func accountDetail(_ session: RemoteSessionSummaryDTO) -> String {
        let name = currentAccount?.name ?? session.accountID ?? MobileL10n.string("Unknown")
        guard let usage = currentAccount?.usageSummary else { return name }
        return "\(name) · \(usage)"
    }

    private func accountMenuTitle(_ account: RemoteAccountChoiceDTO) -> String {
        guard let usage = account.usageSummary else { return account.name }
        return "\(account.name) · \(usage)"
    }

    private func moveToPendingAccount() {
        guard !isMutating, let account = pendingAccount, let session else { return }
        isMutating = true
        Task {
            defer { isMutating = false }
            do {
                try await model.moveSessionAccount(account.id, for: session)
                onAccountMoved()
                dismiss()
            } catch is CancellationError {
                return
            } catch {
                MobileDiagnostics.logDegraded(.sessionAction, error: error)
                errorMessage = error.localizedDescription
            }
        }
    }

    private func setLimitRecovery(
        _ policy: RemoteLimitRecoveryPolicyDTO,
        for session: RemoteSessionSummaryDTO
    ) {
        guard !isMutating, policy != session.limitRecovery else { return }
        isMutating = true
        Task {
            defer { isMutating = false }
            do {
                try await model.setLimitRecovery(policy, for: session)
            } catch is CancellationError {
                return
            } catch {
                MobileDiagnostics.logDegraded(.sessionAction, error: error)
                errorMessage = error.localizedDescription
            }
        }
    }

    private func settingsSection<Content: View>(
        _ title: LocalizedStringKey,
        footer: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: MobileDesign.Spacing.small) {
            Text(title)
                .font(.headline)
                .foregroundStyle(theme.label)
                .padding(.horizontal, MobileDesign.Spacing.inset)
            ThemedRowGroup(content: content)
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryLabel)
                    .padding(.horizontal, MobileDesign.Spacing.inset)
            }
        }
    }

    private func settingsActionRow(
        symbol: String,
        title: String,
        detail: String?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            settingsRow(
                symbol: symbol,
                title: title,
                detail: detail,
                showsChevron: true
            )
        }
        .buttonStyle(.plain)
    }

    private func settingsRow(
        symbol: String,
        title: String,
        detail: String?,
        showsChevron: Bool
    ) -> some View {
        HStack(spacing: MobileDesign.Spacing.medium) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.accent)
                .frame(
                    width: MobileDesign.Size.minimumTapTarget,
                    height: MobileDesign.Size.minimumTapTarget
                )
                .background(
                    theme.accentMuted,
                    in: RoundedRectangle(cornerRadius: theme.controlRadius)
                )
            VStack(alignment: .leading, spacing: MobileDesign.Spacing.hairline) {
                Text(title)
                    .foregroundStyle(theme.label)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(theme.secondaryLabel)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: MobileDesign.Spacing.small)
            if isMutating {
                ProgressView().controlSize(.small)
            } else if showsChevron {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.tertiaryLabel)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, MobileDesign.Spacing.inset)
        .padding(.vertical, MobileDesign.Spacing.small)
        .contentShape(Rectangle())
    }
}
#endif
