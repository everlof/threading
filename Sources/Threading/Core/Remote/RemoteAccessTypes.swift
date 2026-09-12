import Foundation
import ThreadingExtensionKit
import ThreadingRemoteKit

// `RemoteCapability` and the wire DTOs live in `ThreadingRemoteKit` (shared with future clients).
// The types below are server-only — they reference `SessionID` and the app's routing — so they
// stay here.

enum RemoteInputControlDefault: String, CaseIterable {
    case collaborative
    case focusedOwner

    var title: String {
        switch self {
        case .collaborative: return L10n.string("Collaborative")
        case .focusedOwner: return L10n.string("Focused on owner")
        }
    }
}

/// Where a report sent from a paired phone does its work.
///
/// Every other route into a managed workspace is a decision somebody makes while looking at the
/// composer. A shake report is not: it starts a session while its owner is away from the Mac, in
/// whichever checkout they happened to leave open, and the first they see of it is a sidebar row
/// that has already been editing for ten minutes. So the choice is made once, in advance, on the
/// Mac that owns the checkout — not on the phone, where the whole point is that the report costs
/// one tap.
///
/// `.sameCheckout` is the default because it is what this route has always done, and because the
/// two isolated answers are only reachable for a Git project whose agent has the finish
/// handshake. `RemoteSessionMirrorRegistry` resolves that per project before publishing anything,
/// so a phone is never offered a workspace the Mac would then refuse.
enum PhoneReportWorkspacePolicy: String, CaseIterable, Sendable {
    /// The project's own checkout, alongside whatever the Mac is doing in it.
    case sameCheckout

    /// A locked worktree of its own, fast-forwarded into the checkout it started from once the
    /// agent finishes.
    case ownWorkspaceMerged

    /// A locked worktree of its own, kept afterwards so the work can be read before it lands.
    case ownWorkspaceKept

    /// The plan this policy asks for before any project is considered.
    var requestedPlan: ManagedWorkspacePlan? {
        switch self {
        case .sameCheckout: return nil
        case .ownWorkspaceMerged: return ManagedWorkspacePlan(delivery: .mergeAndCleanUp)
        case .ownWorkspaceKept: return ManagedWorkspacePlan(delivery: .keepForReview)
        }
    }

    /// The plan a report chat in one project may actually run under.
    ///
    /// Both conditions are the composer's own, asked here instead of there: a worktree needs a
    /// Git checkout to branch from, and the delivery at the end of it needs an agent that can
    /// perform the finish handshake. A report is worth more than the workspace it wanted, so a
    /// project that fails either one still receives its chat — in the project's own checkout,
    /// which is where every phone report has always run.
    ///
    /// Takes the two answers rather than a `Project` so the rule can be exercised without a
    /// repository on disk, and so the caller pays for `canProvision` once per catalogue.
    func resolvedPlan(
        canProvisionWorkspace: Bool,
        supportsFinishHandshake: Bool
    ) -> ManagedWorkspacePlan? {
        guard canProvisionWorkspace, supportsFinishHandshake else { return nil }
        return requestedPlan
    }

    /// The settings pop-up's wording, read as the end of its row's title: "Reports from your
    /// phone ▸ Their own workspace, merged when finished".
    var settingsTitle: String {
        switch self {
        case .sameCheckout: return L10n.string("The project’s own checkout")
        case .ownWorkspaceMerged: return L10n.string("Their own workspace, merged when finished")
        case .ownWorkspaceKept: return L10n.string("Their own workspace, kept for review")
        }
    }
}

/// Which remote targets a share reaches.
enum RemoteScope: Equatable, Sendable {
    /// The owner's own devices: every remote-capable session and project terminal in the app.
    case allSessions
    /// A guest share of exactly one session.
    case session(SessionID)
    /// A guest share of exactly one standalone project terminal.
    case projectTerminal(TerminalID)

    func covers(_ sessionID: SessionID) -> Bool {
        switch self {
        case .allSessions: return true
        case let .session(allowed): return allowed == sessionID
        case .projectTerminal: return false
        }
    }

    func covers(_ terminalID: TerminalID) -> Bool {
        switch self {
        case .allSessions: return true
        case let .projectTerminal(allowed): return allowed == terminalID
        case .session: return false
        }
    }
}

/// Who is holding a capability link.
///
/// Scope answers *which chats* a link reaches; principal answers *whose device* it represents.
/// Keeping the two separate is the important permission boundary: a collaborator may interact
/// with one shared chat without becoming an owner who can approve tools or manage the Mac.
enum RemotePrincipal: Equatable, Sendable {
    case ownerDevice
    case guest
}

/// A stable participant behind one accepted chat invite.
///
/// The invitation bearer is deliberately not an identity: it may be copied through any share
/// sheet and exists only until first acceptance. The resulting membership gets its own id,
/// device-bound bearer, and human label for turn attribution, presence, and notifications.
struct RemoteMember: Equatable, Sendable {
    let id: String
    let displayName: String
    let deviceID: String
}

/// The result of verifying a bearer token: what the holder is allowed to do, and where.
///
/// A value type deliberately: it is resolved once against the share store's current state and
/// then carried on the connection, so a per-frame authorization check never has to hop to the
/// main queue where the store lives.
struct RemoteAuthorization: Equatable, Sendable {
    let shareID: String
    let capability: RemoteCapability
    let scope: RemoteScope
    let principal: RemotePrincipal
    let expiresAt: Date?
    let member: RemoteMember?
    /// A cryptographic capability is still the credential; this binds that credential to the
    /// stable device identifier that received it so copying only the bearer is insufficient.
    let boundDeviceID: String?
    private let permissionApproval: Bool

    init(
        shareID: String,
        capability: RemoteCapability,
        scope: RemoteScope,
        principal: RemotePrincipal? = nil,
        expiresAt: Date? = nil,
        member: RemoteMember? = nil,
        boundDeviceID: String? = nil,
        canApprovePermissions: Bool? = nil
    ) {
        self.shareID = shareID
        self.capability = capability
        self.scope = scope
        // Preserve the natural meaning of existing call sites while making guest shares explicit:
        // an all-session capability is an owner device; a one-session capability is a guest.
        self.principal = principal ?? (scope == .allSessions ? .ownerDevice : .guest)
        self.expiresAt = expiresAt
        self.member = member
        self.boundDeviceID = boundDeviceID ?? member?.deviceID
        permissionApproval = canApprovePermissions
            ?? (self.principal == .ownerDevice && capability == .interact)
    }

    var canApprovePermissions: Bool {
        guard permissionApproval, capability == .interact else { return false }
        if case .projectTerminal = scope { return false }
        return true
    }

    var canManageHost: Bool {
        principal == .ownerDevice
            && capability == .interact
            && scope == .allSessions
    }

    /// Host usage includes whole-machine spend and provider account labels. It is an owner read,
    /// independent of whether that paired owner credential may mutate host settings.
    var canReadHostUsage: Bool {
        principal == .ownerDevice && scope == .allSessions
    }

    /// Search crosses project, transcript and source boundaries, so it is an owner read just
    /// like whole-host usage. View-only owner devices may search; one-session guests may not.
    var canUseUniversalSearch: Bool {
        principal == .ownerDevice && scope == .allSessions
    }

    var isExpired: Bool {
        expiresAt.map { $0 <= Date() } ?? false
    }

    func isBound(to deviceID: String?) -> Bool {
        guard let boundDeviceID else { return true }
        return boundDeviceID == RemoteInboundPolicy.normalizedDeviceID(deviceID)
    }

    var collaborationParticipantID: String {
        principal == .ownerDevice
            ? RemoteCollaborationParticipantDTO.ownerID
            : (member?.id ?? shareID)
    }
}

struct RemoteInputControlRecord: Equatable {
    var mode: RemoteInputControlMode
    var controllerID: String?
    var revision: Int

    static func initial(default setting: RemoteInputControlDefault) -> Self {
        switch setting {
        case .collaborative:
            return Self(mode: .collaborative, controllerID: nil, revision: 0)
        case .focusedOwner:
            return Self(
                mode: .focused,
                controllerID: RemoteCollaborationParticipantDTO.ownerID,
                revision: 0
            )
        }
    }
}

/// Pure authority rules for a live input-control handoff. UI state is only a projection of this
/// record; every write is checked against it again on the Mac.
enum RemoteInputControlPolicy {
    static func canWrite(_ record: RemoteInputControlRecord, participantID: String) -> Bool {
        record.mode == .collaborative || record.controllerID == participantID
    }

    static func isFocusedController(
        _ record: RemoteInputControlRecord,
        participantID: String
    ) -> Bool {
        record.mode == .focused && record.controllerID == participantID
    }

    static func applying(
        _ action: RemoteInputControlAction,
        to record: RemoteInputControlRecord,
        actorID: String,
        actorCanManage: Bool,
        targetID: String?,
        eligibleParticipantIDs: Set<String>
    ) -> (record: RemoteInputControlRecord, status: RemoteInputControlResultStatus)? {
        var updated = record
        switch action {
        case .collaborative:
            guard actorCanManage else { return (record, .forbidden) }
            updated.mode = .collaborative
            updated.controllerID = nil
        case .focused:
            guard actorCanManage else { return (record, .forbidden) }
            let target = targetID ?? actorID
            guard eligibleParticipantIDs.contains(target) else { return (record, .unavailable) }
            updated.mode = .focused
            updated.controllerID = target
        case .handoff:
            guard actorCanManage || (
                record.mode == .focused && record.controllerID == actorID
            ) else { return (record, .forbidden) }
            guard let targetID, eligibleParticipantIDs.contains(targetID) else {
                return (record, .unavailable)
            }
            updated.mode = .focused
            updated.controllerID = targetID
        case .reclaim:
            guard actorCanManage else { return (record, .forbidden) }
            updated.mode = .focused
            updated.controllerID = RemoteCollaborationParticipantDTO.ownerID
        case .request:
            guard record.mode == .focused, record.controllerID != actorID else {
                return (record, .rejected)
            }
            return (record, .delivered)
        }
        guard updated != record else { return (record, .applied) }
        updated.revision &+= 1
        return (updated, .applied)
    }
}

/// Supplies authorizations to the server. Implemented by the coordinator's owner-device token
/// plus its exact-session guest capabilities. Callable from the server queue, so implementations
/// must be thread-safe (an immutable snapshot behind a lock, not a hop to main).
protocol RemoteAuthorizing: AnyObject, Sendable {
    func authorization(forToken token: String) -> RemoteAuthorization?

    /// Revalidates an authorization captured by an already-authenticated connection.
    /// Socket closure is asynchronous, so every operation that crosses to another executor
    /// checks this immediately before reading or mutating session state.
    func isCurrent(_ authorization: RemoteAuthorization) -> Bool
}

/// What the router decided an HTTP request should become.
enum RemoteRouteDecision: Sendable {
    /// A plain HTTP answer (static asset, REST result, or an error).
    case respond(HTTPResponse)
    /// Upgrade to a WebSocket bound to this session id. The token is validated on the first
    /// frame, not here, because a browser `WebSocket` cannot set an `Authorization` header.
    case upgrade(sessionID: String)
    /// Upgrade to a WebSocket bound to one standalone project terminal.
    case upgradeTerminal(terminalID: String)
}

/// Validation that runs on the remote server queue before anything is retained on or enqueued
/// to the main actor. The WebSocket frame ceiling is intentionally much larger than individual
/// actions, because it is a parser safety limit rather than an application-level allowance.
enum RemoteInboundPolicy {
    static func normalizedMutationRequestID(_ rawValue: String?) -> String? {
        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.utf8.count <= RemoteAccessDefaults.maximumMutationRequestIDBytes,
              value.utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7E })
        else {
            return nil
        }
        return value
    }

    static func normalizedDeviceID(_ rawValue: String?) -> String? {
        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.utf8.count <= RemoteAccessDefaults.maximumDeviceIDBytes,
              value.unicodeScalars.allSatisfy(isAllowedDeviceScalar)
        else {
            return nil
        }
        return value
    }

    /// A device's self-reported label, held to exactly the rules a member's display name is.
    ///
    /// It is shown beside a Revoke button, so it is worth being explicit about what it is not:
    /// nothing is authorized by it. The device id is the bound identity; this only decides which
    /// of two rows a person recognises as their phone.
    static func normalizedDeviceName(_ rawValue: String?) -> String? {
        normalizedMemberName(rawValue)
    }

    /// How much terminal replay a joining client says it can keep, held to the host's own range.
    ///
    /// Only a missing or non-positive value is "no statement", and only that is answered with
    /// the whole ring. Anything else is a statement and stays one: it is clamped into the range
    /// rather than discarded, because the host's fresh repaint makes any tail length
    /// screen-correct, so honouring a small ask costs the client scrollback while refusing it
    /// costs the client the parse it asked to avoid. The upper end is the ring itself — a larger
    /// number is not a request for more history, because none exists.
    static func normalizedTerminalReplayBudget(_ rawValue: Int?) -> Int? {
        guard let rawValue, rawValue > 0 else { return nil }
        return min(
            max(rawValue, RemoteAccessDefaults.minimumTerminalReplayBudgetBytes),
            RemoteAccessDefaults.ringBufferBytes
        )
    }

    static func normalizedMemberName(_ rawValue: String?) -> String? {
        // Bounded before the per-scalar work below, not after it: the length that decides the
        // answer is the *normalized* one, so without this a frame-sized name was normalized in
        // full before being refused. See `maximumNameInputBytes`.
        guard let rawValue, rawValue.utf8.count <= RemoteAccessDefaults.maximumNameInputBytes else {
            return nil
        }
        let printable = rawValue.unicodeScalars.compactMap { scalar -> String? in
            if CharacterSet.controlCharacters.contains(scalar) { return nil }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { return " " }
            return String(scalar)
        }.joined()
        let value = printable
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !value.isEmpty,
              value.utf8.count <= RemoteAccessDefaults.maximumMemberNameBytes
        else {
            return nil
        }
        return value
    }

    static func acceptsBearerToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= RemoteAccessDefaults.maximumBearerTokenBytes
    }

    static func acceptsSearchToken(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 128
            && value.unicodeScalars.allSatisfy { scalar in
                scalar.value < 128 && !CharacterSet.whitespacesAndNewlines.contains(scalar)
            }
    }

    static func acceptsTerminalInput(_ value: String) -> Bool {
        value.utf8.count <= RemoteAccessDefaults.maximumTerminalInputBytes
    }

    static func acceptsPrompt(_ value: String) -> Bool {
        value.utf8.count <= RemoteAccessDefaults.maximumPromptBytes
    }

    static func acceptsContextAttachments(
        _ values: [RemoteConversationContextAttachmentDTO]?
    ) -> Bool {
        guard let values else { return true }
        guard values.count <= ConversationContextPolicy.maximumAttachments else { return false }
        guard let encoded = try? ConversationContextPolicy.encoder.encode(values) else {
            return false
        }
        return encoded.count <= ConversationContextPolicy.maximumEnvelopeUTF8Bytes
    }

    static func acceptsAttentionRecipientID(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= RemoteAccessDefaults.maximumPermissionIDBytes
            && value.unicodeScalars.allSatisfy { scalar in
                !CharacterSet.controlCharacters.contains(scalar)
                    && !CharacterSet.whitespacesAndNewlines.contains(scalar)
            }
    }

    static func acceptsAttentionNote(_ value: String) -> Bool {
        value.utf8.count <= RemoteAttentionDefaults.maximumNoteUTF8Bytes
            && !value.contains("\u{00}")
    }

    static func normalizedAttentionNote(_ rawValue: String?) -> String? {
        guard let rawValue, acceptsAttentionNote(rawValue) else { return nil }
        let printable = rawValue.unicodeScalars.compactMap { scalar -> String? in
            if CharacterSet.controlCharacters.contains(scalar) { return nil }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { return " " }
            return String(scalar)
        }.joined()
        let value = printable.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return value.isEmpty ? nil : value
    }

    static func acceptsPermissionID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= RemoteAccessDefaults.maximumPermissionIDBytes
    }

    static func acceptsAttachmentID(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= RemoteAccessDefaults.maximumPermissionIDBytes
            && value.unicodeScalars.allSatisfy { scalar in
                CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
            }
    }

    static func acceptsExtensionIdentifier(_ value: String) -> Bool {
        value.utf8.count <= RemoteAccessDefaults.maximumPermissionIDBytes
            && ExtensionIdentifierRules.isContributionIdentifier(value)
    }

    static func acceptsExtensionResourcePath(_ value: String) -> Bool {
        value.utf8.count <= RemoteAccessDefaults.maximumRepositoryPathBytes
            && !value.utf8.contains(0)
            && ExtensionIdentifierRules.isSafeRelativePath(value)
    }

    static func acceptsConversationRowID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= RemoteAccessDefaults.maximumPermissionIDBytes
    }

    static func acceptsThemeID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= RemoteAccessDefaults.maximumThemeIDBytes
    }

    static func acceptsSessionTitle(_ value: String) -> Bool {
        value.utf8.count <= RemoteAccessDefaults.maximumSessionTitleBytes
    }

    static func acceptsLaunchIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= RemoteAccessDefaults.maximumLaunchIdentifierBytes
    }

    /// An account handle is `AccountHandle.name`, which that type documents as the
    /// *directory*/discovery spelling of a provider login, so a value arriving over the network
    /// must not be able to name somewhere else on disk. The command layer does already fail
    /// closed -- `moveRemoteSession` resolves the handle against discovered accounts and refuses
    /// an unknown one -- but "not an account" and "not an account identifier" are different
    /// answers, and only the second one is knowable at the boundary, where it costs nothing and
    /// cannot be lost to a later refactor of the lookup.
    static func acceptsAccountIdentifier(_ value: String) -> Bool {
        acceptsLaunchIdentifier(value)
            && !value.contains("/")
            && !value.contains("\\")
            && !value.contains("\u{00}")
            && value != "."
            && value != ".."
    }

    static func acceptsRepositoryPath(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= RemoteAccessDefaults.maximumRepositoryPathBytes
            && !value.contains("\u{00}")
    }

    private static func isAllowedDeviceScalar(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 45, 46, 58, 95, 48 ... 57, 65 ... 90, 97 ... 122:
            return true
        default:
            return false
        }
    }
}

/// Bounded, in-memory exactly-once state for native conversation prompts sent over WebSocket.
/// The main-actor mirror owns mutation; this value remains separate so expiry, conflict, and
/// eviction behavior can be verified without a live agent process.
struct RemotePromptReplayCache {
    struct Key: Hashable {
        let sessionID: String
        let principalID: String
        let requestID: String
    }

    enum Decision: Equatable {
        case new
        case replay(RemotePromptSubmissionStatus)
        case conflict
    }

    private struct Entry {
        let fingerprint: Data
        let status: RemotePromptSubmissionStatus
        let createdAt: Date
    }

    private let maximumEntries: Int
    private let lifetime: TimeInterval
    private var entries: [Key: Entry] = [:]
    private var order: [Key] = []

    init(
        maximumEntries: Int = RemoteAccessDefaults.maximumPromptReplayEntries,
        lifetime: TimeInterval = RemoteAccessDefaults.promptReplayLifetime
    ) {
        self.maximumEntries = max(1, maximumEntries)
        self.lifetime = max(0, lifetime)
    }

    var count: Int { entries.count }

    mutating func decision(
        for key: Key,
        fingerprint: Data,
        now: Date = Date()
    ) -> Decision {
        purgeExpired(now: now)
        guard let entry = entries[key] else { return .new }
        guard entry.fingerprint == fingerprint else { return .conflict }
        return .replay(entry.status)
    }

    mutating func store(
        _ status: RemotePromptSubmissionStatus,
        for key: Key,
        fingerprint: Data,
        now: Date = Date()
    ) {
        purgeExpired(now: now)
        // Dropped from *both* sides before the eviction loop counts. Pulling the key out of
        // `order` alone left `entries.count` still reading "full", so re-storing a key already
        // held evicted the oldest *other* entry to make room for something that needed none —
        // and every prompt stores its key twice, once on accept and once when its status
        // settles. The evicted prompt's replay state went with it, so its retry read as `.new`
        // and it was submitted a second time: the one guarantee this cache exists for.
        if entries[key] != nil {
            order.removeAll { $0 == key }
            entries[key] = nil
        }
        while entries.count >= maximumEntries, let oldest = order.first {
            order.removeFirst()
            entries[oldest] = nil
        }
        entries[key] = Entry(fingerprint: fingerprint, status: status, createdAt: now)
        order.append(key)
    }

    mutating func remove(sessionID: String) {
        let keys = entries.keys.filter { $0.sessionID == sessionID }
        for key in keys {
            entries[key] = nil
        }
        order.removeAll { $0.sessionID == sessionID }
    }

    mutating func removeAll() {
        entries.removeAll(keepingCapacity: false)
        order.removeAll(keepingCapacity: false)
    }

    private mutating func purgeExpired(now: Date) {
        let expired = entries.compactMap { key, entry in
            now.timeIntervalSince(entry.createdAt) > lifetime ? key : nil
        }
        guard !expired.isEmpty else { return }
        let expiredSet = Set(expired)
        for key in expiredSet {
            entries[key] = nil
        }
        order.removeAll { expiredSet.contains($0) }
    }
}

/// Bounded replay and cooldown state for the human-only attention action. A retry with the same
/// request id gets its original result, while a new request to the same person inside the
/// cooldown is collapsed before either an in-app event or a push can be emitted.
struct RemoteAttentionRequestPolicy {
    struct RequestKey: Hashable {
        let sessionID: String
        let principalID: String
        let requestID: String
    }

    struct RateKey: Hashable {
        let sessionID: String
        let principalID: String
        let recipientID: String
    }

    enum Decision: Equatable {
        case proceed
        case replay(RemoteAttentionRequestStatus)
        case conflict
        case rateLimited
    }

    private struct Entry {
        let fingerprint: Data
        let status: RemoteAttentionRequestStatus
        let createdAt: Date
    }

    private let maximumEntries: Int
    private let lifetime: TimeInterval
    private let cooldown: TimeInterval
    private var entries: [RequestKey: Entry] = [:]
    private var order: [RequestKey] = []
    private var latestDelivery: [RateKey: Date] = [:]

    init(
        maximumEntries: Int = RemoteAccessDefaults.maximumPromptReplayEntries,
        lifetime: TimeInterval = RemoteAccessDefaults.promptReplayLifetime,
        cooldown: TimeInterval = RemoteAccessDefaults.attentionRequestCooldown
    ) {
        self.maximumEntries = max(1, maximumEntries)
        self.lifetime = max(0, lifetime)
        self.cooldown = max(0, cooldown)
    }

    var count: Int { entries.count }

    mutating func decision(
        requestKey: RequestKey,
        rateKey: RateKey,
        fingerprint: Data,
        now: Date = Date()
    ) -> Decision {
        purgeExpired(now: now)
        if let entry = entries[requestKey] {
            return entry.fingerprint == fingerprint ? .replay(entry.status) : .conflict
        }
        if let last = latestDelivery[rateKey], now.timeIntervalSince(last) < cooldown {
            return .rateLimited
        }
        return .proceed
    }

    mutating func store(
        _ status: RemoteAttentionRequestStatus,
        requestKey: RequestKey,
        rateKey: RateKey,
        fingerprint: Data,
        now: Date = Date()
    ) {
        purgeExpired(now: now)
        // Both sides, for the reason spelled out in `RemotePromptReplayCache.store`. Here the
        // entry lost to a needless eviction is a poke, so its retry notifies the person twice.
        if entries[requestKey] != nil {
            order.removeAll { $0 == requestKey }
            entries[requestKey] = nil
        }
        while entries.count >= maximumEntries, let oldest = order.first {
            order.removeFirst()
            entries[oldest] = nil
        }
        entries[requestKey] = Entry(
            fingerprint: fingerprint,
            status: status,
            createdAt: now
        )
        order.append(requestKey)
        if status == .delivered { latestDelivery[rateKey] = now }
    }

    mutating func remove(sessionID: String) {
        let requestKeys = entries.keys.filter { $0.sessionID == sessionID }
        for key in requestKeys {
            entries[key] = nil
        }
        order.removeAll { $0.sessionID == sessionID }
        latestDelivery = latestDelivery.filter { $0.key.sessionID != sessionID }
    }

    mutating func removeAll() {
        entries.removeAll(keepingCapacity: false)
        order.removeAll(keepingCapacity: false)
        latestDelivery.removeAll(keepingCapacity: false)
    }

    private mutating func purgeExpired(now: Date) {
        let expiredRequests = entries.compactMap { key, entry in
            now.timeIntervalSince(entry.createdAt) > lifetime ? key : nil
        }
        let expiredSet = Set(expiredRequests)
        for key in expiredSet {
            entries[key] = nil
        }
        if !expiredSet.isEmpty { order.removeAll { expiredSet.contains($0) } }
        latestDelivery = latestDelivery.filter {
            now.timeIntervalSince($0.value) <= max(lifetime, cooldown)
        }
    }
}

/// The one definition of whether a stored session belongs on the remote surface. Keeping this
/// shared by list, resume and WebSocket attach prevents a known UUID from becoming a side door
/// around archiving.
enum RemoteSessionAccess {
    @MainActor
    static func isVisible(_ session: AgentSession?) -> Bool {
        guard let session, !session.isArchived else { return false }

        // A reserved scheduled start is a real local conversation so the sidebar can select it,
        // but the remote protocol has no scheduled-state projection or lifecycle actions yet.
        // Hiding it at the shared access gate keeps list, resume and WebSocket attach aligned:
        // an empty, not-yet-launched session must not look like an ordinary remote chat.
        return ScheduledMessageStore.shared.scheduledStart(for: session.id) == nil
    }
}

/// Produces bounded, provider-neutral projections for conversation frames.
///
/// The local timeline remains complete. A joining client receives a recent window and explicitly
/// pages backwards; live traffic then contains only appended or updated rows. Permission previews
/// use their encoded size because a partial diff is not enough information to authorize a write:
/// oversized requests become view-only cards that must be decided on the Mac.
enum RemoteConversationWirePolicy {
    private static let truncationMarker = "\n…"
    private static let omittedNotice = "Earlier conversation content is not shown on this device."
    static let localReviewReason = "This request is too large to review safely here. Review it on the Mac."

    static func bounded(_ snapshot: RemoteConversationSnapshotDTO) -> RemoteConversationSnapshotDTO {
        RemoteConversationSnapshotDTO(
            rows: boundedRows(snapshot.rows),
            streamingText: truncated(
                snapshot.streamingText,
                toUTF8Bytes: RemoteAccessDefaults.maximumRemoteStreamingBytes
            ),
            canSend: snapshot.canSend,
            composerCapabilities: safeCapabilities(snapshot.composerCapabilities),
            permission: snapshot.permission.map(safePermission),
            questions: safeQuestions(snapshot.questions),
            revision: snapshot.revision,
            hasEarlier: snapshot.hasEarlier
        )
    }

    /// The recent window sent after auth or revision recovery.
    static func initial(
        _ snapshot: RemoteConversationSnapshotDTO,
        revision: Int
    ) -> RemoteConversationSnapshotDTO {
        let window = pageRows(
            snapshot.rows,
            beforeIndex: snapshot.rows.count,
            requestedLimit: RemoteAccessDefaults.maximumRemoteConversationRows
        )
        return RemoteConversationSnapshotDTO(
            rows: window.rows,
            streamingText: truncated(
                snapshot.streamingText,
                toUTF8Bytes: RemoteAccessDefaults.maximumRemoteStreamingBytes
            ),
            canSend: snapshot.canSend,
            composerCapabilities: safeCapabilities(snapshot.composerCapabilities),
            permission: snapshot.permission.map(safePermission),
            questions: safeQuestions(snapshot.questions),
            revision: revision,
            hasEarlier: window.hasEarlier
        )
    }

    static func page(
        _ snapshot: RemoteConversationSnapshotDTO,
        beforeRowID: String?,
        requestedLimit: Int?
    ) -> RemoteConversationPageDTO {
        let beforeIndex: Int
        if let beforeRowID,
           let index = snapshot.rows.firstIndex(where: { $0.id == beforeRowID })
        {
            beforeIndex = index
        } else {
            beforeIndex = snapshot.rows.count
        }
        let window = pageRows(
            snapshot.rows,
            beforeIndex: beforeIndex,
            requestedLimit: requestedLimit
                ?? RemoteAccessDefaults.maximumRemoteConversationPageRows
        )
        return RemoteConversationPageDTO(
            rows: window.rows,
            beforeRowID: beforeRowID,
            hasEarlier: window.hasEarlier
        )
    }

    /// Returns nil when the timeline no longer has append/update shape or when one delta would
    /// exceed the bounded conversation payload. The caller then sends a fresh initial window.
    static func delta(
        from previous: RemoteConversationSnapshotDTO,
        to current: RemoteConversationSnapshotDTO,
        baseRevision: Int,
        revision: Int
    ) -> RemoteConversationDeltaDTO? {
        guard previous.rows.count <= current.rows.count else { return nil }
        let commonCount = previous.rows.count
        guard zip(previous.rows, current.rows.prefix(commonCount)).allSatisfy({
            $0.id == $1.id
        }) else {
            return nil
        }

        let updated = zip(previous.rows, current.rows.prefix(commonCount))
            .compactMap { old, new in old == new ? nil : new }
        let appended = Array(current.rows.dropFirst(commonCount))
        let safeUpdated = fittedRows(updated)
        let safeAppended = fittedRows(appended)
        guard safeUpdated.complete, safeAppended.complete else { return nil }
        let previousCapabilities = safeCapabilities(previous.composerCapabilities)
        let currentCapabilities = safeCapabilities(current.composerCapabilities)

        return RemoteConversationDeltaDTO(
            baseRevision: baseRevision,
            revision: revision,
            appendedRows: safeAppended.rows,
            updatedRows: safeUpdated.rows,
            streamingText: truncated(
                current.streamingText,
                toUTF8Bytes: RemoteAccessDefaults.maximumRemoteStreamingBytes
            ),
            canSend: current.canSend,
            composerCapabilities: previousCapabilities == currentCapabilities
                ? nil
                : currentCapabilities,
            permission: current.permission.map(safePermission),
            questions: safeQuestions(current.questions)
        )
    }

    /// Builds a live delta after the controller's row generation proved the row arrays equal.
    ///
    /// Streaming updates are metadata-only and can arrive twenty times a second. Re-checking
    /// every settled row here made that main-thread cost proportional to total chat history.
    /// The count guard catches a broken caller cheaply; the stronger identity proof is the
    /// controller-owned `(generation, revision)` pair and never crosses the wire.
    static func deltaWithUnchangedRows(
        from previous: RemoteConversationSnapshotDTO,
        to current: RemoteConversationSnapshotDTO,
        baseRevision: Int,
        revision: Int
    ) -> RemoteConversationDeltaDTO? {
        guard previous.rows.count == current.rows.count else { return nil }
        let previousCapabilities = safeCapabilities(previous.composerCapabilities)
        let currentCapabilities = safeCapabilities(current.composerCapabilities)
        return RemoteConversationDeltaDTO(
            baseRevision: baseRevision,
            revision: revision,
            streamingText: truncated(
                current.streamingText,
                toUTF8Bytes: RemoteAccessDefaults.maximumRemoteStreamingBytes
            ),
            canSend: current.canSend,
            composerCapabilities: previousCapabilities == currentCapabilities
                ? nil
                : currentCapabilities,
            permission: current.permission.map(safePermission),
            questions: safeQuestions(current.questions)
        )
    }

    /// Permission evidence may be shown to every collaborator, while the action is enabled only
    /// for members who were explicitly granted approval rights for this chat. This keeps
    /// collaboration and approval independently configurable without making a guest an owner.
    static func authorized(
        _ snapshot: RemoteConversationSnapshotDTO,
        for authorization: RemoteAuthorization,
        canWrite: Bool = true
    ) -> RemoteConversationSnapshotDTO {
        let canSend = snapshot.canSend && authorization.capability == .interact && canWrite
        let permission = snapshot.permission.map { permission in
            guard !authorization.canApprovePermissions else { return permission }
            return RemotePermissionRequestDTO(
                id: permission.id,
                toolName: permission.toolName,
                summary: permission.summary,
                filePath: permission.filePath,
                diff: permission.diff,
                canDecide: false,
                unavailableReason: "You don’t have permission to approve requests in this chat."
            )
        }
        return RemoteConversationSnapshotDTO(
            rows: snapshot.rows,
            streamingText: snapshot.streamingText,
            canSend: canSend,
            composerCapabilities: authorization.capability == .interact
                ? snapshot.composerCapabilities
                : [],
            permission: permission,
            questions: safeQuestions(snapshot.questions).map { $0.allowingAnswers(authorization.capability == .interact && canWrite) },
            revision: snapshot.revision,
            hasEarlier: snapshot.hasEarlier
        )
    }

    static func authorized(
        _ delta: RemoteConversationDeltaDTO,
        for authorization: RemoteAuthorization,
        canWrite: Bool = true
    ) -> RemoteConversationDeltaDTO {
        let permission = authorizedPermission(delta.permission, for: authorization)
        return RemoteConversationDeltaDTO(
            baseRevision: delta.baseRevision,
            revision: delta.revision,
            appendedRows: delta.appendedRows,
            updatedRows: delta.updatedRows,
            streamingText: delta.streamingText,
            canSend: delta.canSend && authorization.capability == .interact && canWrite,
            composerCapabilities: authorization.capability == .interact
                ? delta.composerCapabilities
                : delta.composerCapabilities.map { _ in [] },
            permission: permission,
            questions: safeQuestions(delta.questions ?? []).map { $0.allowingAnswers(authorization.capability == .interact && canWrite) },
            hasEarlier: delta.hasEarlier
        )
    }

    static func safeQuestions(_ questions: [RemoteQuestionRequestDTO]) -> [RemoteQuestionRequestDTO] {
        guard questions.count <= 3 else { return [] }
        var ids = Set<String>()
        return questions.filter { $0.isValid && ids.insert($0.id).inserted }
    }

    static func safePermission(_ request: RemotePermissionRequestDTO) -> RemotePermissionRequestDTO {
        if let size = try? JSONEncoder().encode(request).count,
           size <= RemoteAccessDefaults.maximumRemotePermissionBytes
        {
            return request
        }
        return RemotePermissionRequestDTO(
            id: truncated(request.id, toUTF8Bytes: RemoteAccessDefaults.maximumPermissionIDBytes),
            toolName: truncated(request.toolName, toUTF8Bytes: 256),
            summary: truncated(request.summary, toUTF8Bytes: 4 * 1024),
            filePath: request.filePath.map { truncated($0, toUTF8Bytes: 4 * 1024) },
            diff: [],
            canDecide: false,
            unavailableReason: localReviewReason
        )
    }

    private static func authorizedPermission(
        _ permission: RemotePermissionRequestDTO?,
        for authorization: RemoteAuthorization
    ) -> RemotePermissionRequestDTO? {
        guard let permission else { return nil }
        guard !authorization.canApprovePermissions else { return permission }
        return RemotePermissionRequestDTO(
            id: permission.id,
            toolName: permission.toolName,
            summary: permission.summary,
            filePath: permission.filePath,
            diff: permission.diff,
            canDecide: false,
            unavailableReason: "You don’t have permission to approve requests in this chat."
        )
    }

    static func safeCapabilities(
        _ capabilities: [RemoteComposerCapabilityDTO]
    ) -> [RemoteComposerCapabilityDTO] {
        // Reserve the array brackets, then one comma for every item after the first. This keeps
        // the encoded catalog itself within the advertised aggregate cap rather than only the
        // sum of its entries.
        var remaining = max(
            0,
            RemoteAccessDefaults.maximumRemoteComposerCapabilityBytes - 2
        )
        var result: [RemoteComposerCapabilityDTO] = []
        for capability in capabilities.prefix(
            RemoteAccessDefaults.maximumRemoteComposerCapabilities
        ) {
            guard remaining > 0 else { break }
            let safe = RemoteComposerCapabilityDTO(
                id: truncated(capability.id, toUTF8Bytes: 512),
                name: truncated(capability.name, toUTF8Bytes: 256),
                displayName: truncated(capability.displayName, toUTF8Bytes: 256),
                description: truncated(capability.description, toUTF8Bytes: 1500),
                argumentHint: truncated(capability.argumentHint, toUTF8Bytes: 512),
                aliases: capability.aliases.prefix(12).map {
                    truncated($0, toUTF8Bytes: 256)
                },
                kind: capability.kind,
                isAvailableInSkillCatalog: capability.isAvailableInSkillCatalog,
                trigger: capability.trigger,
                presentation: capability.presentation,
                isEnabled: capability.isEnabled,
                unavailableReason: capability.unavailableReason.map {
                    truncated($0, toUTF8Bytes: 512)
                }
            )
            guard let encodedSize = try? JSONEncoder().encode(safe).count else { break }
            let size = encodedSize + (result.isEmpty ? 0 : 1)
            guard size <= remaining else {
                break
            }
            result.append(safe)
            remaining -= size
        }
        return result
    }

    private static func pageRows(
        _ rows: [RemoteConversationRowDTO],
        beforeIndex: Int,
        requestedLimit: Int
    ) -> (rows: [RemoteConversationRowDTO], hasEarlier: Bool) {
        let limit = min(
            max(1, requestedLimit),
            RemoteAccessDefaults.maximumRemoteConversationRows
        )
        let end = min(max(0, beforeIndex), rows.count)
        let start = max(0, end - limit)
        let candidates = Array(rows[start ..< end])
        let fitted = fittedRows(candidates)
        let omittedWithinWindow = fitted.rows.count < candidates.count
        return (
            fitted.rows,
            start > 0 || omittedWithinWindow || !fitted.complete
        )
    }

    private static func fittedRows(
        _ rows: [RemoteConversationRowDTO]
    ) -> (rows: [RemoteConversationRowDTO], complete: Bool) {
        var remaining = RemoteAccessDefaults.maximumRemoteConversationContentBytes
        var newestFirst: [RemoteConversationRowDTO] = []
        var complete = true

        for row in rows.reversed() {
            let fitted = fittedRow(row, budget: remaining)
            let cost = contentBytes(in: fitted)
            guard cost <= remaining else {
                complete = false
                break
            }
            newestFirst.append(fitted)
            remaining -= cost
            if contentBytes(in: row) > cost { complete = false }
            if remaining == 0 {
                complete = newestFirst.count == rows.count
                break
            }
        }
        return (Array(newestFirst.reversed()), complete)
    }

    private static func boundedRows(
        _ rows: [RemoteConversationRowDTO]
    ) -> [RemoteConversationRowDTO] {
        let candidates = rows.suffix(RemoteAccessDefaults.maximumRemoteConversationRows)
        var remaining = RemoteAccessDefaults.maximumRemoteConversationContentBytes
        var newestFirst: [RemoteConversationRowDTO] = []
        var omitted = candidates.count < rows.count

        for row in candidates.reversed() {
            let fitted = fittedRow(row, budget: remaining)
            let cost = contentBytes(in: fitted)
            guard cost <= remaining else {
                omitted = true
                break
            }
            newestFirst.append(fitted)
            remaining -= cost
            if contentBytes(in: row) > cost { omitted = true }
            if remaining == 0 { break }
        }

        var result = Array(newestFirst.reversed())
        if omitted {
            result.insert(
                RemoteConversationRowDTO(
                    id: "remote-truncated",
                    kind: .notice,
                    text: omittedNotice
                ),
                at: 0
            )
        }
        return result
    }

    private static func fittedRow(
        _ row: RemoteConversationRowDTO,
        budget: Int
    ) -> RemoteConversationRowDTO {
        var remaining = budget

        func take(_ value: String?, maximum: Int) -> String? {
            guard let value else { return nil }
            let limited = truncated(value, toUTF8Bytes: min(maximum, remaining))
            remaining = max(0, remaining - limited.utf8.count)
            return limited
        }

        let id = take(row.id, maximum: 256) ?? ""
        let kind = RemoteConversationRowKind(
            rawValue: take(row.kind.rawValue, maximum: 64) ?? ""
        )
        let toolName = take(row.toolName, maximum: 256)
        let summary = take(row.summary, maximum: 8 * 1024)
        let text = take(row.text, maximum: RemoteAccessDefaults.maximumRemoteConversationFieldBytes)
        let result = take(row.result, maximum: RemoteAccessDefaults.maximumRemoteConversationFieldBytes)

        return RemoteConversationRowDTO(
            id: id,
            kind: kind,
            text: text,
            toolName: toolName,
            summary: summary,
            result: result,
            isError: row.isError
        )
    }

    private static func contentBytes(in row: RemoteConversationRowDTO) -> Int {
        [row.id, row.kind.rawValue, row.text, row.toolName, row.summary, row.result]
            .compactMap { $0 }
            .reduce(0) { $0 + $1.utf8.count }
    }

    private static func truncated(_ value: String, toUTF8Bytes limit: Int) -> String {
        guard value.utf8.count > limit else { return value }
        guard limit > truncationMarker.utf8.count else { return "" }

        let contentLimit = limit - truncationMarker.utf8.count
        var prefix = value.utf8.prefix(contentLimit)
        while String(bytes: prefix, encoding: .utf8) == nil, !prefix.isEmpty {
            prefix = prefix.dropLast()
        }
        return String(decoding: prefix, as: UTF8.self) + truncationMarker
    }
}
