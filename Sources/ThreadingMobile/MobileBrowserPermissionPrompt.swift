import SwiftUI
import ThreadingRemoteKit

/// One pending host question, fetched only on session entry and authoritative invalidations.
/// Replies capture its identity; a late read cannot resurrect a question answered on this phone.
@MainActor
final class MobileBrowserPermissionPromptState: ObservableObject {
    @Published private(set) var request: RemoteBrowserPermissionDTO?
    @Published var isPresented = false
    @Published private(set) var isSubmitting = false
    @Published private(set) var error: String?
    private var revision = 0
    private let onWorkspace: (RemoteWorkspaceDTO) -> Void

    init(
        request: RemoteBrowserPermissionDTO? = nil,
        onWorkspace: @escaping (RemoteWorkspaceDTO) -> Void = { _ in }
    ) {
        self.onWorkspace = onWorkspace
        self.request = request
        isPresented = request != nil
    }

    func refresh(load: () async throws -> RemoteWorkspaceDTO) async {
        guard !isSubmitting else { return }
        revision &+= 1
        let expected = revision
        do {
            let workspace = try await load()
            guard !Task.isCancelled, revision == expected else { return }
            apply(workspace)
        } catch {
            // A transport failure is not proof that a host question was withdrawn.
        }
    }

    func decide(
        _ question: RemoteBrowserPermissionDTO,
        decision: RemoteBrowserPermissionDecision,
        reload: () async throws -> RemoteWorkspaceDTO,
        send: (String, RemoteBrowserPermissionDecision) async throws -> RemoteWorkspaceDTO
    ) async {
        guard !isSubmitting, request?.id == question.id else { return }
        revision &+= 1
        isSubmitting = true
        isPresented = false
        error = nil
        defer { isSubmitting = false }
        do {
            apply(try await send(question.id, decision))
        } catch {
            let failure = error.localizedDescription
            if let workspace = try? await reload() { apply(workspace) }
            if request?.id == question.id { self.error = failure }
            isPresented = request != nil
        }
    }

    private func apply(_ workspace: RemoteWorkspaceDTO) {
        onWorkspace(workspace)
        if request?.id != workspace.browserPermission?.id { error = nil }
        request = workspace.browserPermission
        isPresented = request != nil
    }
}

struct MobileBrowserPermissionPromptRefresh: Equatable {
    let sequence: Int
    let route: MobileRouteIdentity?
    let notificationID: String?
    let isConnected: Bool
    let isActive: Bool
}

/// Host-owned approval over the shipping session, using the shared themed dialog boundary.
struct MobileBrowserPermissionPrompt: ViewModifier {
    let sessionID: String
    let client: RemoteClient?
    let isEnabled: Bool
    let refresh: MobileBrowserPermissionPromptRefresh
    @StateObject private var state: MobileBrowserPermissionPromptState

    init(
        sessionID: String,
        activity: MobileWorkspaceActivity,
        client: RemoteClient?,
        isEnabled: Bool,
        refresh: MobileBrowserPermissionPromptRefresh,
        initialRequest: RemoteBrowserPermissionDTO? = nil
    ) {
        self.sessionID = sessionID
        self.client = client
        self.isEnabled = isEnabled
        self.refresh = refresh
        _state = StateObject(wrappedValue: MobileBrowserPermissionPromptState(
            request: initialRequest, onWorkspace: { activity.reconcile($0) }
        ))
    }

    func body(content: Content) -> some View {
        content
            .themedAlert(
                state.request?.title ?? "",
                message: message,
                isPresented: $state.isPresented,
                actions: actions
            )
            .task(id: refresh) {
                guard isEnabled, refresh.isActive, let client else { return }
                await state.refresh { try await client.workspace(sessionID: sessionID) }
            }
    }

    private var message: String {
        [state.request?.message, state.error].compactMap { $0 }.joined(separator: "\n\n")
    }

    private var actions: [ThemedDialogAction] {
        guard let request = state.request else { return [] }
        var actions = [action(request.allowTitle, request: request, decision: .allowOnce)]
        if let title = request.rememberTitle {
            actions.append(action(title, request: request, decision: .allowRemembered))
        }
        actions.append(action(request.denyTitle, request: request, decision: .deny))
        return actions
    }

    private func action(
        _ title: String,
        request: RemoteBrowserPermissionDTO,
        decision: RemoteBrowserPermissionDecision
    ) -> ThemedDialogAction {
        ThemedDialogAction(
            title, role: decision == .deny ? .cancel : .standard,
            isEnabled: !state.isSubmitting, id: decision.rawValue
        ) {
            guard let client, isEnabled else { return }
            Task {
                await state.decide(request, decision: decision, reload: {
                    try await client.workspace(sessionID: sessionID)
                }) { id, answer in
                    try await client.decideBrowserPermission(
                        sessionID: sessionID, id: id, decision: answer
                    )
                }
            }
        }
    }
}
