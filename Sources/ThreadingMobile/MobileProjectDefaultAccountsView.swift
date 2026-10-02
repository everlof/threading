import SwiftUI
import ThreadingRemoteKit

#if os(iOS)
/// The project whose Default Accounts editor is open, for the dashboard's `sheet(item:)`.
struct MobileProjectDefaultAccountsRoute: Identifiable, Equatable {
    let projectID: String
    /// The list as the catalogue held it when the editor was opened.
    let list: [RemoteAccountReferenceDTO]?

    var id: String { projectID }
}

// MARK: - Mobile Project Default Accounts View

/// The owner's editor for one project's ordered logins: the ones a new chat here starts on, in
/// order, and the rest of the Mac's logins to add from.
///
/// A `List`, because the rows are reordered and removed — `ThemedSettingsSection` keeps `EditButton`
/// reordering and swipe to delete while the colours stay the theme's. Edits stay on the phone
/// until Save sends the whole list; the Mac stores it and answers with the catalogue every draft
/// reads. A login the catalogue no longer offers stays in the list as "Unavailable login" until
/// it is removed by hand, because the catalogue omits a login that is merely switched off.
struct MobileProjectDefaultAccountsView: View {
    @EnvironmentObject private var model: RemoteAppModel
    @Environment(\.remoteTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    let projectID: String
    @State private var editor: MobileProjectDefaultAccountsEditor
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(route: MobileProjectDefaultAccountsRoute) {
        projectID = route.projectID
        _editor = State(initialValue: MobileProjectDefaultAccountsEditor(list: route.list))
    }

    private var project: RemoteProjectChoiceDTO? {
        model.me?.newSessionCatalog?.projects.first { $0.id == projectID }
    }

    /// The catalogue's runtimes with the freshest readings over them, as the draft sees them.
    private var agents: [RemoteAgentChoiceDTO] {
        (model.me?.newSessionCatalog?.agents ?? []).map(model.agentWithCurrentUsage)
    }

    var body: some View {
        let agents = agents
        let available = editor.available(in: agents)
        let now = Date()
        NavigationStack {
            List {
                ThemedSettingsSection {
                    if editor.entries.isEmpty {
                        Text(MobileL10n.string("No logins yet. New chats here start on the usual login."))
                            .font(.subheadline)
                            .foregroundStyle(theme.secondaryLabel)
                    }
                    ForEach(Array(editor.entries.enumerated()), id: \.element) { index, reference in
                        listedRow(rank: index + 1, reference: reference, agents: agents, now: now)
                    }
                    .onMove { source, destination in
                        editor.move(fromOffsets: source, toOffset: destination)
                    }
                    .onDelete { offsets in
                        editor.remove(atOffsets: offsets)
                    }
                } header: {
                    HStack {
                        Text(MobileL10n.string("In Order"))
                        Spacer(minLength: MobileDesign.Spacing.small)
                        // In the section it edits rather than the bar: Cancel and Save already
                        // stand there, and a third item cut the title down to "Default Acco…".
                        EditButton()
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(theme.accent)
                            .disabled(editor.entries.isEmpty || isSaving)
                    }
                } footer: {
                    Text(MobileL10n.string(
                        "A new chat in this project starts on the first login that is not out of usage."
                    ))
                }

                if !available.isEmpty {
                    ThemedSettingsSection {
                        ForEach(available, id: \.self) { reference in
                            availableRow(reference, agents: agents, now: now)
                        }
                    } header: {
                        Text(MobileL10n.string("Not Used Automatically"))
                    } footer: {
                        Text(MobileL10n.string(
                            "You can still start any chat on these by choosing the login yourself."
                        ))
                    }
                }
            }
            .themedSettingsPage(theme)
            .navigationTitle(MobileL10n.string("Default Accounts"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(MobileL10n.string("Cancel")) { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(MobileL10n.string("Save")) { save() }
                        .disabled(!editor.hasChanges || isSaving || project == nil)
                }
            }
        }
        .presentationDetents([.large])
        // A swipe would discard the reordering without a word; Cancel says so on purpose.
        .interactiveDismissDisabled(editor.hasChanges || isSaving)
        .themedAlert(
            "Couldn’t save default accounts",
            message: errorMessage ?? "",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            ),
            actions: [ThemedDialogAction("OK")]
        )
    }

    // MARK: - Rows

    private func listedRow(
        rank: Int,
        reference: RemoteAccountReferenceDTO,
        agents: [RemoteAgentChoiceDTO],
        now: Date
    ) -> some View {
        let resolved = resolve(reference, in: agents)
        let modelID = resolved.modelID
        let state = MobileProjectDefaultAccounts.state(
            of: resolved.account,
            model: modelID,
            now: now
        )
        let reading = MobileAccountUsageReading.resolve(
            account: resolved.account,
            model: modelID,
            now: now
        )
        let detail = MobileProjectDefaultAccounts.stateLine(
            state,
            account: resolved.account,
            reading: reading,
            now: now
        )
        return HStack(spacing: MobileDesign.Spacing.medium) {
            Text(rank.formatted())
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(theme.secondaryLabel)
                .frame(minWidth: MobileDesign.Spacing.large, alignment: .trailing)
            accountLabel(
                resolved,
                reading: reading,
                detail: detail,
                isWarning: !state.isPickable
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(MobileL10n.string(
            "%lld. %@",
            Int64(rank),
            MobileL10n.string("%@ · %@", resolved.name, resolved.runtimeName)
        ))
        .accessibilityValue(detail)
    }

    private func availableRow(
        _ reference: RemoteAccountReferenceDTO,
        agents: [RemoteAgentChoiceDTO],
        now: Date
    ) -> some View {
        let resolved = resolve(reference, in: agents)
        let reading = MobileAccountUsageReading.resolve(
            account: resolved.account,
            model: resolved.modelID,
            now: now
        )
        let words = resolved.account.map {
            MobileAccountUsageWords.resolve(account: $0, reading: reading).text
        } ?? MobileL10n.string("Usage unknown")
        return Button {
            editor.add(reference)
        } label: {
            HStack(spacing: MobileDesign.Spacing.medium) {
                accountLabel(resolved, reading: reading, detail: words, isWarning: false)
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(editor.canAdd ? theme.accent : theme.tertiaryLabel)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!editor.canAdd || isSaving)
        .accessibilityLabel(MobileL10n.string(
            "Add %@",
            MobileL10n.string("%@ · %@", resolved.name, resolved.runtimeName)
        ))
        .accessibilityValue(words)
    }

    /// The disc a chat on this login wears in the bar — the runtime's mark with the login's
    /// chip, ringed by its reading — so a list that crosses runtimes says which runtime without
    /// a word; then the login's name, and its one-line state.
    private func accountLabel(
        _ resolved: ResolvedLogin,
        reading: MobileAccountUsageReading?,
        detail: String,
        isWarning: Bool
    ) -> some View {
        HStack(spacing: MobileDesign.Spacing.medium) {
            MobileAccountDisc(
                identity: .resolve(resolved.agentID),
                reading: reading,
                account: resolved.account?.appearance(in: .usage)
            )
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: MobileDesign.Spacing.hairline) {
                Text(resolved.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(resolved.account == nil ? theme.secondaryLabel : theme.label)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(isWarning ? theme.warning : theme.secondaryLabel)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Resolution

    private struct ResolvedLogin {
        let agentID: String
        let agent: RemoteAgentChoiceDTO?
        let account: RemoteAccountChoiceDTO?
        let modelID: String?
        let name: String
        let runtimeName: String
    }

    /// A reference's catalogue row. One the catalogue does not list keeps its handle as its name
    /// and the runtime's own name, so the row still says which login it was.
    private func resolve(
        _ reference: RemoteAccountReferenceDTO,
        in agents: [RemoteAgentChoiceDTO]
    ) -> ResolvedLogin {
        let agent = agents.first { $0.id == reference.agentID }
        let account = agent?.accounts?.first { $0.id == reference.accountID }
        let modelID: String? = if let agent, let account {
            model.newSessionDefaultModel(agent: agent, account: account)
        } else {
            nil
        }
        return ResolvedLogin(
            agentID: reference.agentID,
            agent: agent,
            account: account,
            modelID: modelID,
            name: account?.visibleName ?? reference.accountID,
            runtimeName: agent?.name ?? MobileAgentIdentity.resolve(reference.agentID).displayName
        )
    }

    // MARK: - Saving

    private func save() {
        guard !isSaving, editor.hasChanges else { return }
        isSaving = true
        let request = editor.request(projectID: projectID)
        Task {
            defer { isSaving = false }
            do {
                try await model.setProjectDefaultAccounts(
                    projectID: request.projectID,
                    accounts: request.accounts
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

// MARK: - Mobile Account Substitution Receipt

/// The one line a chat opens with when the Mac started it on another listed login than the
/// draft showed: "Started on Spare — Work is out until 18:40".
///
/// The attention banner's strip — an accent-muted band under the navigation bar, a glyph in the
/// status column and one caption line — because this is the same kind of thing: a one-off
/// receipt of something that happened, not a state the chat stays in. It leaves on its own
/// (`MobileAccountSubstitutionNotice.displayDuration`) or at a tap, and does not come back when
/// the screen is rebuilt.
struct MobileAccountSubstitutionReceipt: View {
    let text: String
    let dismiss: () -> Void
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        Button(action: dismiss) {
            HStack(alignment: .top, spacing: MobileDesign.Spacing.small) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .foregroundStyle(theme.accent)
                    .frame(width: MobileDesign.Size.terminalStatusIconColumn)
                Text(text)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(theme.label)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(theme.tertiaryLabel)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, MobileDesign.Spacing.inset)
            .padding(.vertical, MobileDesign.Spacing.small)
            .background(theme.accentMuted)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(text)
        .accessibilityHint(MobileL10n.string("Dismisses this notice"))
    }
}
#endif
