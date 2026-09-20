import Foundation
import ThreadingRemoteKit

/// Questions remain pending while their recipient is active; only resolving the request clears
/// them. At most 256 request/device pairs and timers are retained (normally 1–4). Input callbacks
/// do no scans: a deadline reads the shared scalar activity timestamp and reschedules itself.
@MainActor
final class RemoteResponseNotificationCoordinator {
    enum Scope: Hashable, CaseIterable { case session, browser }

    typealias Target = RemoteNotificationTargetIdentity

    /// Deliberately contains no notification title, body, tool arguments or response text.
    struct DiagnosticContext {
        let hostID: String
        let sessionID: String
        let eventID: String
        let kind: RemoteNotificationKind
    }
    typealias DiagnosticSink = @MainActor (DiagnosticContext, Target, [RemoteDiagnosticField: String]) -> Void

    private struct Key: Hashable {
        let sessionID: String
        let kind: RemoteNotificationKind
        let scope: Scope
        let target: Target
    }

    private enum DeliveryState {
        case pending
        case sending
        case accepted
        case refused
    }

    private struct Entry {
        let event: RemoteNotificationEventDTO
        var task: (any RemoteTurnNotificationScheduledTask)?
        var liveSent = false
        var state: DeliveryState = .pending
        var retryCount = 0
        var retryNotBeforeUptime: TimeInterval?
    }

    static let maximumEntries = 256
    static let retryDelays: [TimeInterval] = [1, 5, 30]
    private let clock: any RemoteTurnNotificationClock
    private let scheduler: any RemoteTurnNotificationScheduling
    private let activity: RemoteNotificationParticipantActivitySource
    private let isAuthorized: @MainActor (RemoteNotificationEventDTO, Target) -> Bool
    private let liveSink: @MainActor (RemoteNotificationEventDTO, Target) -> Void
    private let pushSink: @MainActor (
        RemoteNotificationEventDTO, Target, @escaping @MainActor (RemoteNotificationPushResult) -> Void
    ) -> Void
    private let retractionSink: @MainActor (RemoteNotificationRetractionDTO, Target, Bool) -> Void
    private let diagnosticSink: DiagnosticSink
    private var entries: [Key: Entry] = [:]

    init(
        clock: any RemoteTurnNotificationClock,
        scheduler: any RemoteTurnNotificationScheduling,
        activity: RemoteNotificationParticipantActivitySource,
        isAuthorized: @escaping @MainActor (RemoteNotificationEventDTO, Target) -> Bool,
        liveSink: @escaping @MainActor (RemoteNotificationEventDTO, Target) -> Void,
        pushSink: @escaping @MainActor (
            RemoteNotificationEventDTO, Target, @escaping @MainActor (RemoteNotificationPushResult) -> Void
        ) -> Void,
        retractionSink: @escaping @MainActor (RemoteNotificationRetractionDTO, Target, Bool) -> Void,
        diagnosticSink: @escaping DiagnosticSink = { _, _, _ in }
    ) {
        self.clock = clock
        self.scheduler = scheduler
        self.activity = activity
        self.isAuthorized = isAuthorized
        self.liveSink = liveSink
        self.pushSink = pushSink
        self.retractionSink = retractionSink
        self.diagnosticSink = diagnosticSink
    }

    var count: Int { entries.count }

    func requested(_ event: RemoteNotificationEventDTO, targets: [Target], scope: Scope = .session) {
        guard event.kind.lifecycle == .responseRequest else { return }
        resolve(sessionID: event.sessionID, kind: event.kind, scope: scope)
        for target in targets {
            guard entries.count < Self.maximumEntries, isAuthorized(event, target) else {
                diagnose("refused", event, target: target, fields: [
                    .reason: entries.count >= Self.maximumEntries ? "queueBound" : "authorization",
                ])
                continue
            }
            diagnose("created", event, target: target)
            let key = Key(sessionID: event.sessionID, kind: event.kind, scope: scope, target: target)
            let foreground = activity.isForeground(
                participantID: target.participantID, deviceID: target.deviceID
            )
            entries[key] = Entry(event: event, liveSent: foreground)
            if foreground { liveSink(event, target) }
            evaluate(key, eventID: event.id)
        }
    }

    /// Called on semantic blocker removal, never on editing bytes or simply viewing a chat.
    func resolve(sessionID: String, kind: RemoteNotificationKind? = nil, scope: Scope? = nil) {
        for key in entries.keys.filter({ $0.sessionID == sessionID && (kind == nil || $0.kind == kind)
            && (scope == nil || $0.scope == scope) }) {
            guard let entry = entries.removeValue(forKey: key) else { continue }
            entry.task?.cancel()
            diagnose("invalidated", entry.event, target: key.target, fields: [.reason: "resolved"])
            // Live tombstones also cover a callback queued before resolution. Background removal
            // is sent only for accepted pushes; in-flight acceptance revalidates below.
            retract(entry.event, target: key.target, background: entry.state == .accepted)
        }
    }

    func presenceChanged() {
        for (key, entry) in Array(entries) where entry.state == .pending {
            evaluate(key, eventID: entry.event.id)
        }
    }

    /// Registration or provider changes are new delivery evidence, so even a previously refused
    /// attempt can be tried again. Ordinary input does not reset the bounded retry budget.
    func transportChanged() {
        for (key, var entry) in Array(entries) where entry.state == .refused {
            entry.state = .pending
            entry.retryCount = 0
            entry.retryNotBeforeUptime = nil
            entries[key] = entry
            diagnose("revalidated", entry.event, target: key.target, fields: [.reason: "transportChanged"])
            evaluate(key, eventID: entry.event.id)
        }
        presenceChanged()
    }

    func reset() {
        for entry in entries.values { entry.task?.cancel() }
        entries.removeAll()
    }

    /// Rechecked by the asynchronous shipping sender immediately before beginning network I/O.
    func canSend(_ event: RemoteNotificationEventDTO, to target: Target) -> Bool {
        let isPending = Scope.allCases.contains { scope in
            let key = Key(sessionID: event.sessionID, kind: event.kind, scope: scope, target: target)
            return entries[key]?.event.id == event.id
        }
        return isPending
            && isAuthorized(event, target)
            && activity.activeReason(for: target.participantID, nowUptime: clock.uptime) == nil
    }

    private func evaluate(_ key: Key, eventID: String) {
        guard var entry = entries[key], entry.event.id == eventID, entry.state == .pending else { return }
        entry.task?.cancel()
        entry.task = nil
        guard isAuthorized(entry.event, key.target) else {
            diagnose("invalidated", entry.event, target: key.target, fields: [.reason: "authorization"])
            entries[key] = nil
            return
        }
        switch activity.activeReason(for: key.target.participantID, nowUptime: clock.uptime) {
        case .phone:
            diagnose("deferred", entry.event, target: key.target, fields: [.reason: "activePhone"])
            entries[key] = entry // Detachment re-evaluates an unanswered request.
        case .mac:
            guard let deadline = activity.macDeadline(nowUptime: clock.uptime) else { return }
            diagnose("deferred", entry.event, target: key.target, fields: [
                .reason: "activeMac", .delayMS: String(Int((deadline - clock.uptime) * 1_000)),
            ])
            entry.task = scheduler.schedule(after: max(0, deadline - clock.uptime)) { [weak self] in
                self?.evaluate(key, eventID: eventID)
            }
            entries[key] = entry
        case nil:
            if let deadline = entry.retryNotBeforeUptime, deadline > clock.uptime {
                entry.task = scheduler.schedule(after: deadline - clock.uptime) { [weak self] in
                    self?.evaluate(key, eventID: eventID)
                }
                entries[key] = entry
                return
            }
            entry.retryNotBeforeUptime = nil
            let needsLiveDelivery = !entry.liveSent
            entry.liveSent = true
            entry.state = .sending
            entries[key] = entry
            let event = entry.event
            if needsLiveDelivery { liveSink(event, key.target) }
            pushSink(event, key.target) { [weak self] result in
                self?.pushFinished(result, event: event, key: key)
            }
        }
    }

    private func pushFinished(
        _ result: RemoteNotificationPushResult,
        event: RemoteNotificationEventDTO,
        key: Key
    ) {
        var fields: [RemoteDiagnosticField: String] = [
            .transport: "apns", .status: result.diagnosticStatus,
        ]
        if let code = result.failureCode { fields[.code] = code }
        if let trace = result.providerTrace { fields[.providerTrace] = trace }
        diagnose(result.accepted ? "sent" : "refused", event, target: key.target, fields: fields)
        guard var entry = entries[key], entry.event.id == event.id else {
            if result.accepted { retract(event, target: key.target, background: true) }
            return
        }
        guard isAuthorized(event, key.target) else {
            entries[key] = nil
            if result.accepted { retract(event, target: key.target, background: true) }
            return
        }
        if result.accepted {
            // Acceptance is not resolution. Returning to a device does not answer a question.
            entry.state = .accepted
            entries[key] = entry
            return
        }
        entry.state = .pending
        entries[key] = entry
        if !canSend(event, to: key.target) {
            evaluate(key, eventID: event.id)
            return
        }
        // A refusal this Mac decided before any network I/O is not a transient network fault:
        // nothing about waiting one second makes a missing provider or a withdrawn consent
        // succeed. Those wait for `transportChanged`, which is the registration/provider edge
        // they actually depend on, and which restores a fresh retry budget when it arrives.
        let retryable = result.attempted
            && (result.statusCode == nil || result.statusCode == 429
                || (result.statusCode.map { $0 >= 500 } ?? false))
        guard retryable, entry.retryCount < Self.retryDelays.count else {
            entry.state = .refused
            entries[key] = entry
            return
        }
        let delay = Self.retryDelays[entry.retryCount]
        diagnose("deferred", event, target: key.target, fields: [
            .reason: "retry", .delayMS: String(Int(delay * 1_000)),
            .attempt: String(entry.retryCount + 2),
        ])
        entry.retryCount += 1
        entry.retryNotBeforeUptime = clock.uptime + delay
        entry.task = scheduler.schedule(after: delay) { [weak self] in
            self?.evaluate(key, eventID: event.id)
        }
        entries[key] = entry
    }

    private func diagnose(
        _ phase: String, _ event: RemoteNotificationEventDTO, target: Target,
        fields: [RemoteDiagnosticField: String] = [:]
    ) {
        var fields = fields
        fields[.phase] = phase
        fields[.queueSize] = String(entries.count)
        diagnosticSink(.init(
            hostID: event.hostID, sessionID: event.sessionID, eventID: event.id, kind: event.kind
        ), target, fields)
    }

    private func retract(_ event: RemoteNotificationEventDTO, target: Target, background: Bool) {
        diagnose("retracted", event, target: target, fields: [
            .transport: background ? "liveAndBackground" : "live",
        ])
        retractionSink(.init(
            hostID: event.hostID,
            sessionID: event.sessionID,
            eventID: event.id,
            kind: event.kind
        ), target, background)
    }
}
