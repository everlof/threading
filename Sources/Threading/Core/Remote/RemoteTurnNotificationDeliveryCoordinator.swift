import Foundation
import ThreadingRemoteKit

enum RemoteNotificationParticipantID: Hashable, Sendable {
    case owner
    case member(String)
}

struct RemoteTurnNotificationTarget: Sendable {
    typealias Identity = RemoteNotificationTargetIdentity

    let shareID: String
    let deviceID: String
    let participantID: RemoteNotificationParticipantID
    let isTurnCompletionEnabled: Bool
    let includesResponsePreviews: Bool
    let supportsRetraction: Bool

    init(
        shareID: String,
        deviceID: String,
        participantID: RemoteNotificationParticipantID,
        isTurnCompletionEnabled: Bool = true,
        includesResponsePreviews: Bool,
        supportsRetraction: Bool
    ) {
        self.shareID = shareID
        self.deviceID = deviceID
        self.participantID = participantID
        self.isTurnCompletionEnabled = isTurnCompletionEnabled
        self.includesResponsePreviews = includesResponsePreviews
        self.supportsRetraction = supportsRetraction
    }

    var identity: Identity {
        Identity(shareID: shareID, deviceID: deviceID, participantID: participantID)
    }
}

struct RemoteTurnNotificationCompletion: Sendable {
    let eventID: String
    let hostID: String
    let sessionID: SessionID
    let participantID: RemoteNotificationParticipantID
    let generation: UInt64
    let title: String
    let snapshot: CompletedTurnSnapshot?
    let createdAt: Double
}

/// The diagnostic boundary deliberately cannot carry response content.
struct RemoteTurnNotificationDiagnosticContext: Equatable, Sendable {
    let eventID: String
    let hostID: String
    let sessionID: SessionID
    let participantID: RemoteNotificationParticipantID
    let generation: UInt64
}

protocol RemoteTurnNotificationClock: AnyObject {
    var uptime: TimeInterval { get }
}

final class SystemRemoteTurnNotificationClock: RemoteTurnNotificationClock {
    var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

@MainActor
protocol RemoteTurnNotificationScheduledTask: AnyObject {
    func cancel()
}

@MainActor
protocol RemoteTurnNotificationScheduling: AnyObject {
    func schedule(
        after delay: TimeInterval,
        _ action: @escaping @MainActor () -> Void
    ) -> any RemoteTurnNotificationScheduledTask
}

@MainActor
final class SystemRemoteTurnNotificationScheduler: RemoteTurnNotificationScheduling {
    func schedule(
        after delay: TimeInterval,
        _ action: @escaping @MainActor () -> Void
    ) -> any RemoteTurnNotificationScheduledTask {
        SystemScheduledTask(delay: delay, action: action)
    }

    private final class SystemScheduledTask: RemoteTurnNotificationScheduledTask {
        private var task: Task<Void, Never>?

        init(delay: TimeInterval, action: @escaping @MainActor () -> Void) {
            let nanoseconds = UInt64((max(0, delay) * 1_000_000_000).rounded(.up))
            task = Task { @MainActor in
                do {
                    try await Task<Never, Never>.sleep(nanoseconds: nanoseconds)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                action()
            }
        }

        func cancel() {
            task?.cancel()
            task = nil
        }
    }
}

/// Process-local presence facts. It contains no conversation content and performs only scalar or
/// bounded-dictionary mutation on the AppKit input path.
@MainActor
final class RemoteNotificationParticipantActivitySource {
    enum ActiveReason: String {
        case mac
        case phone
    }

    private struct DeviceKey: Hashable {
        let participantID: RemoteNotificationParticipantID
        let deviceID: String
    }

    private let macWindowSeconds: @MainActor () -> TimeInterval
    private var macApplicationIsActive = false
    private var macIsAvailable = true
    private var lastMacInteractionUptime: TimeInterval?
    private var foregroundConnectionCounts: [DeviceKey: Int] = [:]
    private var foregroundParticipantCounts: [RemoteNotificationParticipantID: Int] = [:]

    /// Seconds since the last keyboard, pointer or scroll input anywhere on this Mac, or `nil`
    /// where nothing can say — the test host, or a build with no probe installed.
    ///
    /// The owner is at the Mac when the Mac is in use, not when Threading happens to be the
    /// frontmost application. Measured on 11 September 2026: a prompt submitted in Threading at
    /// 13:53:01, a switch to another app, the turn finishing at 13:53:17 with Threading in the
    /// background, and the completion pushed to the phone at once — retracted seven seconds
    /// later by the next keystroke in Threading. With the probe installed the app-local
    /// monitor no longer decides presence; without it, that monitor remains the fallback.
    var systemInputAge: @MainActor () -> TimeInterval? = { nil }

    init(macWindowSeconds: @escaping @MainActor () -> TimeInterval) {
        self.macWindowSeconds = macWindowSeconds
    }

    func recordMacInteraction(at uptime: TimeInterval) {
        macApplicationIsActive = true
        lastMacInteractionUptime = uptime
    }

    func setMacApplicationActive(_ isActive: Bool) {
        macApplicationIsActive = isActive
    }

    /// Whether this Mac can be used at all right now: false while the screen is locked, the
    /// display is asleep, or another user's login session is in front. Input age keeps looking
    /// recent for a whole window after the screen locks, and that is exactly when the owner has
    /// left.
    func setMacAvailable(_ isAvailable: Bool) {
        macIsAvailable = isAvailable
    }

    func attachForegroundDevice(
        participantID: RemoteNotificationParticipantID,
        deviceID: String
    ) {
        let key = DeviceKey(participantID: participantID, deviceID: deviceID)
        foregroundConnectionCounts[key, default: 0] += 1
        foregroundParticipantCounts[participantID, default: 0] += 1
    }

    func detachForegroundDevice(
        participantID: RemoteNotificationParticipantID,
        deviceID: String
    ) {
        let key = DeviceKey(participantID: participantID, deviceID: deviceID)
        guard let count = foregroundConnectionCounts[key] else { return }
        foregroundConnectionCounts[key] = count > 1 ? count - 1 : nil
        if let participantCount = foregroundParticipantCounts[participantID] {
            foregroundParticipantCounts[participantID] = participantCount > 1
                ? participantCount - 1
                : nil
        }
    }

    func removeAllForegroundDevices() {
        foregroundConnectionCounts.removeAll(keepingCapacity: false)
        foregroundParticipantCounts.removeAll(keepingCapacity: false)
    }

    func isForeground(
        participantID: RemoteNotificationParticipantID,
        deviceID: String
    ) -> Bool {
        foregroundConnectionCounts[
            DeviceKey(participantID: participantID, deviceID: deviceID)
        ] != nil
    }

    func activeReason(
        for participantID: RemoteNotificationParticipantID,
        nowUptime: TimeInterval
    ) -> ActiveReason? {
        if foregroundParticipantCounts[participantID] != nil {
            return .phone
        }
        guard participantID == .owner, macDeadline(nowUptime: nowUptime) != nil else {
            return nil
        }
        return .mac
    }

    /// When the current window of Mac use runs out, or `nil` when the Mac is not in use.
    func macDeadline(nowUptime: TimeInterval) -> TimeInterval? {
        guard macIsAvailable else { return nil }
        let window = macWindowSeconds()
        guard window > 0, let age = macInputAge(nowUptime: nowUptime), age < window else {
            return nil
        }
        return nowUptime + (window - age)
    }

    /// Seconds since the owner last used this Mac: the system-wide probe where one is installed,
    /// otherwise the app-local monitor, which can only see input while Threading is active.
    private func macInputAge(nowUptime: TimeInterval) -> TimeInterval? {
        if let age = systemInputAge(), age >= 0 {
            return age
        }
        guard macApplicationIsActive, let lastMacInteractionUptime else { return nil }
        let age = nowUptime - lastMacInteractionUptime
        return age >= 0 ? age : nil
    }
}

/// Coordinates routine turn completions. Response requests use their own coordinator because
/// activity defers an unanswered request rather than marking it seen. Explicit milestones and
/// person-to-person attention keep the immediate delivery path.
@MainActor
final class RemoteTurnNotificationDeliveryCoordinator {
    typealias TargetSource = @MainActor (
        SessionID,
        RemoteNotificationParticipantID
    ) -> [RemoteTurnNotificationTarget]
    typealias GenerationSource = @MainActor (SessionID) -> UInt64
    typealias LiveSink = @MainActor (
        RemoteNotificationEventDTO,
        RemoteTurnNotificationTarget
    ) -> Int
    typealias PushSink = @MainActor (
        RemoteNotificationEventDTO,
        RemoteTurnNotificationTarget,
        @escaping @MainActor (RemoteNotificationPushResult) -> Void
    ) -> Void
    typealias RetractionSink = @MainActor (
        RemoteNotificationRetractionDTO,
        RemoteTurnNotificationTarget,
        Bool,
        Bool
    ) -> Void
    typealias DiagnosticSink = @MainActor (
        String,
        RemoteTurnNotificationDiagnosticContext,
        RemoteTurnNotificationTarget?,
        [RemoteDiagnosticField: String]
    ) -> Void

    private struct PendingKey: Hashable {
        let sessionID: SessionID
        let participantID: RemoteNotificationParticipantID
    }

    private struct Pending {
        let completion: RemoteTurnNotificationCompletion
        let token: UUID
        let deadlineUptime: TimeInterval
        let task: any RemoteTurnNotificationScheduledTask
    }

    private struct LedgerEntry {
        let context: RemoteTurnNotificationDiagnosticContext
        let target: RemoteTurnNotificationTarget
        let acceptedAtUptime: TimeInterval
        var retractionRequested: Bool
    }

    static let maximumPendingCompletions = 256
    static let maximumAcceptedDeliveries = 256
    static let acceptedDeliveryLifetime: TimeInterval = 24 * 60 * 60

    private let clock: any RemoteTurnNotificationClock
    private let scheduler: any RemoteTurnNotificationScheduling
    private let activity: RemoteNotificationParticipantActivitySource
    private let targetSource: TargetSource
    private let generationSource: GenerationSource
    private let liveSink: LiveSink
    private let pushSink: PushSink
    private let retractionSink: RetractionSink
    private let diagnosticSink: DiagnosticSink
    private var pending: [PendingKey: Pending] = [:]
    private var ledger: [LedgerEntry] = []
    private var interactionEpochs: [RemoteNotificationParticipantID: UInt64] = [:]
    private var macInteractionTask: (any RemoteTurnNotificationScheduledTask)?

    init(
        clock: any RemoteTurnNotificationClock,
        scheduler: any RemoteTurnNotificationScheduling,
        activity: RemoteNotificationParticipantActivitySource,
        targetSource: @escaping TargetSource,
        generationSource: @escaping GenerationSource,
        liveSink: @escaping LiveSink,
        pushSink: @escaping PushSink,
        retractionSink: @escaping RetractionSink,
        diagnosticSink: @escaping DiagnosticSink
    ) {
        self.clock = clock
        self.scheduler = scheduler
        self.activity = activity
        self.targetSource = targetSource
        self.generationSource = generationSource
        self.liveSink = liveSink
        self.pushSink = pushSink
        self.retractionSink = retractionSink
        self.diagnosticSink = diagnosticSink
    }

    var pendingCount: Int { pending.count }
    var acceptedDeliveryCount: Int { ledger.count }

    func completed(_ completion: RemoteTurnNotificationCompletion) {
        pruneAcceptedDeliveries()
        guard generationSource(completion.sessionID) == completion.generation else {
            diagnose("invalidated", completion, reason: "generation")
            return
        }
        diagnose("created", completion)

        let targets = targetSource(completion.sessionID, completion.participantID)
        for target in targets where target.isTurnCompletionEnabled && activity.isForeground(
            participantID: completion.participantID,
            deviceID: target.deviceID
        ) {
            let event = event(for: completion, target: target)
            diagnose(
                "revalidated",
                completion,
                target: target,
                additional: [.transport: "live"].merging(previewFields(event)) { _, new in new }
            )
            let recipients = liveSink(event, target)
            diagnose(
                recipients > 0 ? "sent" : "refused",
                completion,
                target: target,
                additional: [
                    .transport: "live",
                    .attempt: "1",
                    .total: String(recipients),
                ].merging(previewFields(event)) { _, new in new }
            )
        }

        switch activity.activeReason(for: completion.participantID, nowUptime: clock.uptime) {
        case .phone:
            diagnose("canceled", completion, reason: "activePhone", activitySource: "phone")
        case .mac:
            guard let deadline = activity.macDeadline(nowUptime: clock.uptime) else {
                sendPushes(completion)
                return
            }
            deferCompletion(completion, deadlineUptime: deadline)
        case nil:
            sendPushes(completion)
        }
    }

    func turnStarted(sessionID: SessionID, generation: UInt64) {
        pruneAcceptedDeliveries()
        invalidate(where: { $0.sessionID == sessionID }, reason: "newTurn")
        retract(where: {
            $0.context.sessionID == sessionID
                && $0.context.generation < generation
        }, reason: "newTurn")
    }

    func participantInteracted(
        _ participantID: RemoteNotificationParticipantID,
        source: String
    ) {
        pruneAcceptedDeliveries()
        interactionEpochs[participantID, default: 0] &+= 1
        invalidate(where: { $0.participantID == participantID }, reason: "interaction")
        retract(where: { $0.context.participantID == participantID }, reason: source)
    }

    func macInteracted(at uptime: TimeInterval) {
        activity.recordMacInteraction(at: uptime)
        // Off disables Mac-presence effects completely. A real new turn still invalidates its
        // older generation through `turnStarted`, independently of this activity preference.
        guard activity.macDeadline(nowUptime: uptime) != nil else { return }
        // AppKit calls this for every deliberate input event. Keep that hot path O(1), and
        // coalesce queue/ledger work away from a high-frequency input burst.
        guard macInteractionTask == nil else { return }
        macInteractionTask = scheduler.schedule(after: 0.1) { [weak self] in
            guard let self else { return }
            self.macInteractionTask = nil
            self.participantInteracted(.owner, source: "mac")
        }
    }

    /// Threading came to the front.
    ///
    /// Presence resumes for the whole participant, so later completions defer again. Only the
    /// chat on screen has been *seen*: being in the app is not the same as having looked at
    /// every one of them, which is the rule `AttentionAlertCenter` already applies to its own
    /// banners — it withdraws the visible session's and leaves the rest standing. Activation
    /// used to route through `macInteracted`, so a one-second glance at Threading retracted
    /// every accepted completion push on the phone, for chats the user never opened.
    ///
    /// A push still in flight when this arrives is a separate question, and its answer has not
    /// moved: `pushFinished` retracts it because the participant is active again, whichever
    /// session it belonged to. What that rule cannot reach is a push already delivered.
    func macBecameActive(at uptime: TimeInterval, viewing sessionID: SessionID?) {
        pruneAcceptedDeliveries()
        activity.recordMacInteraction(at: uptime)
        guard let sessionID else { return }
        invalidate(
            where: { $0.participantID == .owner && $0.sessionID == sessionID },
            reason: "viewed"
        )
        retract(
            where: { $0.context.participantID == .owner && $0.context.sessionID == sessionID },
            reason: "macViewed"
        )
    }

    func setMacApplicationActive(_ isActive: Bool) {
        activity.setMacApplicationActive(isActive)
        guard !isActive else { return }
        flushIfMacIsNotInUse(reason: "macInactive")
    }

    /// The screen locked, the display slept, or another login session came to the front.
    func macBecameUnavailable() {
        activity.setMacAvailable(false)
        flushIfMacIsNotInUse(reason: "macUnavailable")
    }

    func macBecameAvailable() {
        activity.setMacAvailable(true)
    }

    /// Leaving Threading is not leaving the Mac. A flush while the Mac is still in use would
    /// reach `sendPushes`, whose activity check cancels rather than defers, so pending work stays
    /// on its timers until a deadline finds the Mac idle or the screen goes away.
    private func flushIfMacIsNotInUse(reason: String) {
        guard activity.activeReason(for: .owner, nowUptime: clock.uptime) == nil else { return }
        flush(where: { $0.participantID == .owner }, reason: reason)
    }

    func foregroundDeviceAttached(
        participantID: RemoteNotificationParticipantID,
        deviceID: String
    ) {
        activity.attachForegroundDevice(participantID: participantID, deviceID: deviceID)
        participantInteracted(participantID, source: "phone")
    }

    func foregroundDeviceDetached(
        participantID: RemoteNotificationParticipantID,
        deviceID: String
    ) {
        activity.detachForegroundDevice(participantID: participantID, deviceID: deviceID)
    }

    func reset() {
        for value in pending.values { value.task.cancel() }
        macInteractionTask?.cancel()
        macInteractionTask = nil
        pending.removeAll(keepingCapacity: false)
        ledger.removeAll(keepingCapacity: false)
        interactionEpochs.removeAll(keepingCapacity: false)
        activity.removeAllForegroundDevices()
    }

    private func deferCompletion(
        _ completion: RemoteTurnNotificationCompletion,
        deadlineUptime: TimeInterval
    ) {
        let key = PendingKey(
            sessionID: completion.sessionID,
            participantID: completion.participantID
        )
        if let replaced = pending.removeValue(forKey: key) {
            replaced.task.cancel()
            diagnose("replaced", replaced.completion)
        } else if pending.count >= Self.maximumPendingCompletions {
            diagnose("refused", completion, reason: "queueBound")
            return
        }

        let token = UUID()
        let delay = max(0, deadlineUptime - clock.uptime)
        let task = scheduler.schedule(after: delay) { [weak self] in
            self?.deadlineFired(key: key, token: token)
        }
        pending[key] = Pending(
            completion: completion,
            token: token,
            deadlineUptime: deadlineUptime,
            task: task
        )
        diagnose(
            "deferred",
            completion,
            reason: "activeMac",
            activitySource: "mac",
            additional: [.delayMS: milliseconds(delay)]
        )
    }

    private func deadlineFired(key: PendingKey, token: UUID) {
        guard let value = pending[key], value.token == token else { return }
        pending[key] = nil
        value.task.cancel()
        diagnose("deadlineFired", value.completion)
        guard generationSource(value.completion.sessionID) == value.completion.generation else {
            diagnose("invalidated", value.completion, reason: "generation")
            return
        }
        if let reason = activity.activeReason(
            for: value.completion.participantID,
            nowUptime: clock.uptime
        ) {
            if reason == .mac, let deadline = activity.macDeadline(nowUptime: clock.uptime) {
                deferCompletion(value.completion, deadlineUptime: deadline)
            } else {
                diagnose(
                    "canceled",
                    value.completion,
                    reason: "activePhone",
                    activitySource: "phone"
                )
            }
            return
        }
        sendPushes(value.completion)
    }

    private func sendPushes(_ completion: RemoteTurnNotificationCompletion) {
        guard generationSource(completion.sessionID) == completion.generation else {
            diagnose("invalidated", completion, reason: "generation")
            return
        }
        guard activity.activeReason(
            for: completion.participantID,
            nowUptime: clock.uptime
        ) == nil else {
            diagnose("canceled", completion, reason: "activityRevalidation")
            return
        }

        // Target lookup itself is the deadline revalidation. This method is main-actor isolated,
        // so walking that immutable snapshot cannot race a registration mutation and remains
        // linear in the bounded subscription count. The asynchronous sender revalidates the
        // chosen identity and mutable consent again before touching APNs.
        let targets = targetSource(completion.sessionID, completion.participantID)
            .filter(\.isTurnCompletionEnabled)
        for target in targets {
            let event = event(for: completion, target: target)
            diagnose(
                "revalidated",
                completion,
                target: target,
                additional: previewFields(event)
            )
            let interactionEpoch = interactionEpochs[completion.participantID, default: 0]
            pushSink(event, target) { [weak self] result in
                self?.pushFinished(
                    completion: completion,
                    target: target,
                    event: event,
                    interactionEpoch: interactionEpoch,
                    result: result
                )
            }
        }
    }

    private func pushFinished(
        completion: RemoteTurnNotificationCompletion,
        target: RemoteTurnNotificationTarget,
        event: RemoteNotificationEventDTO,
        interactionEpoch: UInt64,
        result: RemoteNotificationPushResult
    ) {
        var fields: [RemoteDiagnosticField: String] = [
            .transport: "apns",
            .attempt: "1",
            .result: result.accepted ? "accepted" : "refused",
            .status: result.diagnosticStatus,
        ]
        if let providerTrace = result.providerTrace { fields[.providerTrace] = providerTrace }
        if let failureCode = result.failureCode { fields[.code] = failureCode }
        fields.merge(previewFields(event)) { _, new in new }
        diagnose(result.accepted ? "sent" : "refused", completion, target: target,
                 additional: fields)
        guard result.accepted else { return }

        if ledger.count >= Self.maximumAcceptedDeliveries {
            ledger.removeFirst(ledger.count - Self.maximumAcceptedDeliveries + 1)
        }
        ledger.append(LedgerEntry(
            context: diagnosticContext(for: completion),
            target: target,
            acceptedAtUptime: clock.uptime,
            retractionRequested: false
        ))
        let currentTarget = targetSource(
            completion.sessionID,
            completion.participantID
        ).first { $0.identity == target.identity }
        let eventContainsPreview = event.bodyLocalization == nil
        if generationSource(completion.sessionID) != completion.generation
            || interactionEpochs[completion.participantID, default: 0] != interactionEpoch
            || activity.activeReason(
                for: completion.participantID,
                nowUptime: clock.uptime
            ) != nil
            || currentTarget?.isTurnCompletionEnabled != true
            || (eventContainsPreview && currentTarget?.includesResponsePreviews != true)
        {
            retract(where: { $0.context.eventID == event.id }, reason: "postSendRevalidation")
        }
    }

    private func invalidate(
        where predicate: (PendingKey) -> Bool,
        reason: String
    ) {
        let keys = pending.keys.filter(predicate)
        for key in keys {
            guard let value = pending.removeValue(forKey: key) else { continue }
            value.task.cancel()
            diagnose("invalidated", value.completion, reason: reason)
        }
    }

    private func flush(where predicate: (PendingKey) -> Bool, reason: String) {
        let keys = pending.keys.filter(predicate)
        for key in keys {
            guard let value = pending.removeValue(forKey: key) else { continue }
            value.task.cancel()
            diagnose("revalidated", value.completion, reason: reason)
            sendPushes(value.completion)
        }
    }

    private func retract(
        where predicate: (LedgerEntry) -> Bool,
        reason: String
    ) {
        for index in ledger.indices where predicate(ledger[index])
            && !ledger[index].retractionRequested
        {
            let entry = ledger[index]
            guard let currentTarget = targetSource(
                entry.context.sessionID,
                entry.context.participantID
            ).first(where: {
                $0.identity == entry.target.identity
                    && $0.supportsRetraction
            }) else { continue }
            ledger[index].retractionRequested = true
            retractionSink(retraction(for: entry), currentTarget, true, true)
            diagnose(
                "retracted",
                context: entry.context,
                target: currentTarget,
                reason: reason,
                additional: [.transport: "liveAndBackground"]
            )
        }
    }

    private func pruneAcceptedDeliveries() {
        let cutoff = clock.uptime - Self.acceptedDeliveryLifetime
        ledger.removeAll { $0.acceptedAtUptime < cutoff }
    }

    private func event(
        for completion: RemoteTurnNotificationCompletion,
        target: RemoteTurnNotificationTarget
    ) -> RemoteNotificationEventDTO {
        let preview = target.includesResponsePreviews
            ? TurnCompletionPreviewFormatter.preview(
                from: completion.snapshot?.generation == completion.generation
                    ? completion.snapshot?.finalAssistantText
                    : nil
            )
            : nil
        return RemoteNotificationEventDTO(
            id: completion.eventID,
            kind: .turnCompleted,
            hostID: completion.hostID,
            sessionID: completion.sessionID.uuidString,
            title: completion.title,
            body: preview ?? "Finished its turn.",
            bodyLocalization: preview == nil
                ? .init(key: "Finished its turn.")
                : nil,
            createdAt: completion.createdAt,
            turnGeneration: completion.generation
        )
    }

    private func retraction(for entry: LedgerEntry) -> RemoteNotificationRetractionDTO {
        RemoteNotificationRetractionDTO(
            hostID: entry.context.hostID,
            sessionID: entry.context.sessionID.uuidString,
            eventID: entry.context.eventID,
            kind: .turnCompleted
        )
    }

    private func previewFields(
        _ event: RemoteNotificationEventDTO
    ) -> [RemoteDiagnosticField: String] {
        let present = event.bodyLocalization == nil
        return [
            .previewPresent: present ? "true" : "false",
            .previewBytes: String(present ? event.body.utf8.count : 0),
        ]
    }

    private func diagnose(
        _ phase: String,
        _ completion: RemoteTurnNotificationCompletion,
        target: RemoteTurnNotificationTarget? = nil,
        reason: String? = nil,
        activitySource: String? = nil,
        additional: [RemoteDiagnosticField: String] = [:]
    ) {
        diagnose(
            phase,
            context: diagnosticContext(for: completion),
            target: target,
            reason: reason,
            activitySource: activitySource,
            additional: additional
        )
    }

    private func diagnosticContext(
        for completion: RemoteTurnNotificationCompletion
    ) -> RemoteTurnNotificationDiagnosticContext {
        RemoteTurnNotificationDiagnosticContext(
            eventID: completion.eventID,
            hostID: completion.hostID,
            sessionID: completion.sessionID,
            participantID: completion.participantID,
            generation: completion.generation
        )
    }

    private func diagnose(
        _ phase: String,
        context: RemoteTurnNotificationDiagnosticContext,
        target: RemoteTurnNotificationTarget? = nil,
        reason: String? = nil,
        activitySource: String? = nil,
        additional: [RemoteDiagnosticField: String] = [:]
    ) {
        var fields: [RemoteDiagnosticField: String] = [
            .phase: phase,
            .generation: String(context.generation),
            .queueSize: String(pending.count),
        ]
        if let reason { fields[.reason] = reason }
        if let activitySource { fields[.activitySource] = activitySource }
        fields.merge(additional) { _, new in new }
        diagnosticSink(
            phase,
            context,
            target,
            fields
        )
    }

    private func milliseconds(_ interval: TimeInterval) -> String {
        String(max(0, Int((interval * 1_000).rounded())))
    }
}
