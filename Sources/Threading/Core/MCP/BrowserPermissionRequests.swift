import Foundation
import ThreadingRemoteKit

/// One authority for Mac and paired-owner answers. Only the head of each bounded queue is
/// projected to the phone; removal precedes callbacks so competing devices cannot settle twice.
@MainActor
final class BrowserPermissionRequests {
    static let maximumPending = 128
    static let maximumPerSession = 8
    static let maximumTitleBytes = 512
    static let maximumMessageBytes = 8_192
    static let lifetime: Duration = .seconds(300)
    static let shared: BrowserPermissionRequests = BrowserPermissionRequests(
        observesLifecycle: true, changed: publishChange
    )

    private static func publishChange(sessionID: SessionID, announces: Bool) {
        RemoteSessionMirrorRegistry.shared.workspaceBrowserChanged(
            sessionID, announcesActivity: announces
        )
        if announces {
            RemoteNotificationService.shared.browserPermissionRequested(sessionID: sessionID)
        } else if BrowserPermissionRequests.shared.pending(for: sessionID) == nil {
            RemoteNotificationService.shared.browserPermissionResolved(sessionID: sessionID)
        }
    }

    private struct Pending {
        let sessionID: SessionID
        let request: RemoteBrowserPermissionDTO
        let settle: (RemoteBrowserPermissionDecision) -> Void
        let dismiss: () -> Void
        let deadline: ContinuousClock.Instant
        var expiry: Task<Void, Never>?
    }

    private var requests: [String: Pending] = [:]
    private var queues: [SessionID: [String]] = [:]
    private let observations = AppEventObservations()
    private let now: () -> ContinuousClock.Instant
    private let changed: @MainActor (SessionID, Bool) -> Void

    init(
        observesLifecycle: Bool = false,
        now: @escaping () -> ContinuousClock.Instant = { .now },
        changed: @escaping @MainActor (SessionID, Bool) -> Void = { _, _ in }
    ) {
        self.now = now
        self.changed = changed
        if observesLifecycle {
            observations.observe(TerminalSessionDidEnd.self) { [weak self] event in
                self?.cancel(sessionID: event.sessionID)
            }
            observations.observe(SessionWorkDidChange.self) { [weak self] event in
                if event.kind == .turnEnded { self?.cancel(sessionID: event.sessionID) }
            }
            observations.observe(ProjectsDidChange.self) { [weak self] _ in
                guard let self else { return }
                for sessionID in Array(self.queues.keys) where !RemoteSessionAccess.isVisible(
                    ProjectStore.shared.session(withID: sessionID)
                ) {
                    self.cancel(sessionID: sessionID)
                }
            }
        }
    }

    func pending(for sessionID: SessionID) -> RemoteBrowserPermissionDTO? {
        queues[sessionID]?.first.flatMap { requests[$0]?.request }
    }

    /// Queue saturation refuses the new call; it never evicts an unanswered grant.
    @discardableResult
    func enqueue(
        sessionID: SessionID,
        title: String,
        message: String,
        allowTitle: String = "Allow Once",
        rememberTitle: String? = "Always Allow This Host",
        denyTitle: String = "Deny",
        dismiss: @escaping () -> Void,
        settle: @escaping (RemoteBrowserPermissionDecision) -> Void
    ) -> String? {
        guard title.utf8.prefix(Self.maximumTitleBytes + 1).count <= Self.maximumTitleBytes,
              message.utf8.prefix(Self.maximumMessageBytes + 1).count <= Self.maximumMessageBytes,
              requests.count < Self.maximumPending,
              (queues[sessionID]?.count ?? 0) < Self.maximumPerSession else {
            settle(.deny)
            return nil
        }
        let id = UUID().uuidString
        let wasEmpty = queues[sessionID]?.isEmpty ?? true
        requests[id] = Pending(
            sessionID: sessionID,
            request: .init(id: id, title: title, message: message,
                           allowTitle: allowTitle, rememberTitle: rememberTitle, denyTitle: denyTitle),
            settle: settle, dismiss: dismiss, deadline: now().advanced(by: Self.lifetime)
        )
        queues[sessionID, default: []].append(id)
        requests[id]?.expiry = Task { [weak self] in
            do { try await Task.sleep(for: Self.lifetime) } catch { return }
            self?.resolve(sessionID: sessionID, id: id, decision: .deny)
        }
        changed(sessionID, wasEmpty)
        return id
    }

    @discardableResult
    func resolve(
        sessionID: SessionID,
        id: String,
        decision: RemoteBrowserPermissionDecision
    ) -> Bool {
        guard let pending = requests[id], pending.sessionID == sessionID else { return false }
        guard decision != .allowRemembered || pending.request.rememberTitle != nil else { return false }
        let wasHead = queues[sessionID]?.first == id
        let expired = now() >= pending.deadline
        requests.removeValue(forKey: id)
        queues[sessionID]?.removeAll { $0 == id }
        if queues[sessionID]?.isEmpty == true { queues.removeValue(forKey: sessionID) }
        pending.expiry?.cancel()
        // Closing the Mac sheet can synchronously answer its cancel callback. The identity is
        // already retired, so that answer cannot override the phone's decision.
        pending.dismiss()
        changed(sessionID, wasHead && queues[sessionID] != nil)
        pending.settle(expired ? .deny : decision)
        return !expired
    }

    func cancel(sessionID: SessionID) {
        let ids = queues.removeValue(forKey: sessionID) ?? []
        let pending = ids.compactMap { requests.removeValue(forKey: $0) }
        for request in pending {
            request.expiry?.cancel()
            request.dismiss()
            request.settle(.deny)
        }
        if !pending.isEmpty { changed(sessionID, false) }
    }
}
