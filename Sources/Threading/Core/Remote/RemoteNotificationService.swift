import CryptoKit
import Foundation
import ThreadingRemoteKit

/// Session-scoped notification fan-out.
///
/// A live events socket gives an open phone an immediate event. The hosted APNs broker covers
/// suspension and backgrounding; an explicit Mac-local sender remains a development override.
/// Both paths receive the same bounded DTO and the phone deduplicates by its stable event id.
@MainActor
final class RemoteNotificationService {

    static let shared: RemoteNotificationService = {
        let store: RemoteNotificationSubscriptionPersisting =
            NSClassFromString("XCTestCase") == nil
                ? RemoteNotificationSubscriptionKeychainStore()
                : InMemoryRemoteNotificationSubscriptionStore()
        return RemoteNotificationService(
            subscriptionStore: store,
            localPushSender: RemoteAPNSPushSender.fromEnvironment(),
            recordsPersistenceDiagnostics: true
        )
    }()

    enum RequestedDeliveryResult: Equatable {
        case delivered(recipient: String)
        case unavailable(reason: String)
    }

    enum RegistrationResult: Equatable {
        case registered(RemoteNotificationRegistrationResponseDTO)
        case invalid
        case persistenceUnavailable
    }

    private enum RequestedRecipient: Equatable {
        case requester
        case owner
        case everyone
        case memberID(String)
        case named(String)

        init(_ rawValue: String?) {
            let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let normalized = trimmed.lowercased()
            switch normalized {
            case "", "requester", "me": self = .requester
            case "owner": self = .owner
            case "everyone", "all": self = .everyone
            default:
                if normalized.hasPrefix("member:") {
                    self = .memberID(String(normalized.dropFirst("member:".count)))
                } else {
                    self = .named(trimmed)
                }
            }
        }
    }

    private struct Subscription {
        let deviceID: String
        let deviceToken: String
        let hostedRegistrationID: String?
        let hostedServiceURL: String?
        let environment: RemoteAPNSPushSender.Environment
        let authorization: RemoteAuthorization
        let enabledKinds: Set<RemoteNotificationKind>
        let soundEnabledKinds: Set<RemoteNotificationKind>
    }

    private struct DeliverySummary {
        enum PushBlock: Equatable {
            case none
            case providerUnavailable
            case serviceMismatch
            case noRegistration
        }

        let liveRecipients: Int
        let pushTargets: Int
        let pushBlock: PushBlock

        var isReachable: Bool { liveRecipients > 0 || pushTargets > 0 }

        var requestedDeliveryFailureReason: String {
            switch pushBlock {
            case .providerUnavailable:
                return "The hosted push provider is unavailable, and no opted-in phone is "
                    + "connected live."
            case .serviceMismatch:
                return "The phone’s push registration belongs to another hosted service. Open "
                    + "Threading on the phone to refresh it."
            case .none, .noRegistration:
                return "No opted-in device is currently reachable."
            }
        }
    }

    private var subscriptions: [RemoteNotificationSubscriptionKey: Subscription] = [:]
    private var persistedSubscriptions: [
        RemoteNotificationSubscriptionKey: RemoteNotificationSubscriptionRecord
    ] = [:]
    typealias HostedPushSender = @MainActor (
        RemoteNotificationEventDTO,
        String,
        Bool
    ) async -> RemoteAPNSDeliveryResult

    private let subscriptionStore: RemoteNotificationSubscriptionPersisting
    private let localPushSender: RemoteAPNSPushSender?
    private let recordsPersistenceDiagnostics: Bool
    private var hostedPushSender: HostedPushSender?
    private var hostedPushAvailability: (@MainActor () -> Bool)?
    private var hostedPushServiceURL: (@MainActor () -> URL?)?
    private let observations = AppEventObservations()
    private var announcedGuestShares: Set<String> = []
    private var currentActorBySession: [SessionID: RemoteNotificationInteractionActor] = [:]
    private var lastActivityBySession: [SessionID: SessionActivity] = [:]
    private(set) var persistenceError: String?
    private var persistenceWritesBlocked = false

    init(
        subscriptionStore: RemoteNotificationSubscriptionPersisting,
        localPushSender: RemoteAPNSPushSender? = nil,
        recordsPersistenceDiagnostics: Bool = false
    ) {
        self.subscriptionStore = subscriptionStore
        self.localPushSender = localPushSender
        self.recordsPersistenceDiagnostics = recordsPersistenceDiagnostics
        do {
            let restored = try subscriptionStore.load()
            persistedSubscriptions = Dictionary(
                restored.map { ($0.key, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            ThreadingLogger.remote.info(
                "Remote notification registrations restored count=\(restored.count, privacy: .public)"
            )
        } catch {
            persistenceError = error.localizedDescription
            persistenceWritesBlocked = true
            ThreadingLogger.remote.error(
                "Remote notification persistence failed stage=load error=\(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            recordPersistenceDiagnostic(stage: "load")
        }
        observations.observe(SessionActivityDidChange.self) { [weak self] event in
            Task { @MainActor in self?.activityChanged(sessionID: event.sessionID) }
        }
        observations.observe(TerminalSessionDidEnd.self) { [weak self] event in
            Task { @MainActor in
                self?.lastActivityBySession[event.sessionID] = nil
                self?.currentActorBySession[event.sessionID] = nil
            }
        }
    }

    var supportsPush: Bool {
        localPushSender != nil || (hostedPushAvailability?() == true && hostedPushSender != nil)
    }

    var activeSubscriptionCount: Int { subscriptions.count }

    /// Rebinds durable device preferences to the capability stores that are authoritative for
    /// this Remote Access lifetime. Orphans remain inert even if their best-effort cleanup fails.
    @discardableResult
    func activate(authorizations: [RemoteAuthorization]) -> Int {
        var current: [RemoteNotificationSubscriptionKey: RemoteAuthorization] = [:]
        for authorization in authorizations where !authorization.isExpired {
            guard let deviceID = authorization.boundDeviceID else { continue }
            current[RemoteNotificationSubscriptionKey(
                shareID: authorization.shareID,
                deviceID: deviceID
            )] = authorization
        }

        subscriptions = persistedSubscriptions.reduce(into: [:]) { result, entry in
            guard let authorization = current[entry.key],
                  let subscription = Self.subscription(
                      from: entry.value,
                      authorization: authorization
                  ) else { return }
            result[entry.key] = subscription
        }

        let validPersisted = persistedSubscriptions.filter { current[$0.key] != nil }
        if validPersisted.count != persistedSubscriptions.count, !persistenceWritesBlocked {
            do {
                try subscriptionStore.save(Self.sortedRecords(validPersisted.values))
                persistedSubscriptions = validPersisted
                persistenceError = nil
            } catch {
                recordPersistenceFailure(error, stage: "prune")
            }
        }
        ThreadingLogger.remote.info(
            "Remote notification registrations activated count=\(self.subscriptions.count, privacy: .public)"
        )
        return subscriptions.count
    }

    func configureHostedPushSender(
        serviceURL: @escaping @MainActor () -> URL?,
        isAvailable: @escaping @MainActor () -> Bool,
        send: @escaping HostedPushSender
    ) {
        hostedPushServiceURL = serviceURL
        hostedPushAvailability = isAvailable
        hostedPushSender = send
    }

    func recordOwnerInteraction(sessionID: SessionID) {
        currentActorBySession[sessionID] = .owner
    }

    func recordInteraction(
        sessionID: SessionID,
        authorization: RemoteAuthorization
    ) {
        if let member = authorization.member {
            currentActorBySession[sessionID] = .member(
                id: member.id,
                name: member.displayName
            )
        } else {
            currentActorBySession[sessionID] = .owner
        }
    }

    /// Whether the requested recipient set includes the Mac owner, independently of whether any
    /// phone is registered. Local delivery uses this before posting on the owner's Mac so a guest
    /// saying “notify me” cannot accidentally alert somebody else.
    func requestedRecipientIncludesOwner(
        sessionID: SessionID,
        recipient rawRecipient: String?
    ) -> Bool {
        switch RequestedRecipient(rawRecipient) {
        case .owner, .everyone:
            return true
        case .requester:
            return (currentActorBySession[sessionID] ?? .owner) == .owner
        case .memberID, .named:
            return false
        }
    }

    func register(
        _ registration: RemoteNotificationRegistrationDTO,
        deviceID: String,
        authorization: RemoteAuthorization
    ) -> RegistrationResult {
        let deviceToken = registration.deviceToken.lowercased()
        let enabledKinds = Set(registration.enabledKinds)
        let soundEnabledKinds = Set(
            registration.soundEnabledKinds ?? registration.enabledKinds
        )
        guard let environment = RemoteAPNSPushSender.Environment(
            rawValue: registration.environment.rawValue
        ), !authorization.isExpired,
           authorization.boundDeviceID == deviceID,
           RemoteInboundPolicy.normalizedDeviceID(deviceID) == deviceID,
           RemoteNotificationSubscriptionDefaults.acceptsDeviceToken(deviceToken),
           RemoteNotificationSubscriptionDefaults.acceptsHostedRegistrationID(
               registration.hostedRegistrationID
           ),
           enabledKinds.count == registration.enabledKinds.count,
           soundEnabledKinds.isSubset(of: enabledKinds) else {
            return .invalid
        }

        let record = RemoteNotificationSubscriptionRecord(
            shareID: authorization.shareID,
            deviceID: deviceID,
            deviceToken: deviceToken,
            hostedRegistrationID: registration.hostedRegistrationID,
            hostedServiceURL: registration.hostedRegistrationID == nil
                ? nil
                : RemoteNotificationSubscriptionDefaults.normalizedHostedServiceURL(
                    hostedPushServiceURL?()
                ),
            environment: registration.environment,
            enabledKinds: enabledKinds.sorted { $0.rawValue < $1.rawValue },
            soundEnabledKinds: soundEnabledKinds.sorted { $0.rawValue < $1.rawValue }
        )
        guard RemoteNotificationSubscriptionDefaults.isValid([record]),
              !persistenceWritesBlocked else {
            return persistenceWritesBlocked ? .persistenceUnavailable : .invalid
        }
        var candidate = persistedSubscriptions
        guard candidate[record.key] != nil
                || candidate.count < RemoteNotificationSubscriptionDefaults.maximumSubscriptions
        else {
            return .persistenceUnavailable
        }
        candidate[record.key] = record
        do {
            try subscriptionStore.save(Self.sortedRecords(candidate.values))
            persistenceError = nil
        } catch {
            recordPersistenceFailure(error, stage: "save")
            return .persistenceUnavailable
        }

        persistedSubscriptions = candidate
        subscriptions[record.key] = Subscription(
            deviceID: record.deviceID,
            deviceToken: record.deviceToken,
            hostedRegistrationID: record.hostedRegistrationID,
            hostedServiceURL: record.hostedServiceURL,
            environment: environment,
            authorization: authorization,
            enabledKinds: enabledKinds,
            soundEnabledKinds: soundEnabledKinds
        )

        // A guest cannot be notified before accepting a capability: there is no account or
        // device identity to target yet. Registration is that acceptance boundary, so announce
        // the newly shared chat exactly once here.
        if authorization.principal == .guest,
           !announcedGuestShares.contains(Self.announcementKey(record.key)),
           case .session(let sessionID) = authorization.scope,
           let session = ProjectStore.shared.session(withID: sessionID) {
            announcedGuestShares.insert(Self.announcementKey(record.key))
            let event = RemoteNotificationEventDTO(
                kind: .sharedSession,
                hostID: RemoteHostIdentity.current.id,
                sessionID: sessionID.uuidString,
                title: "Chat shared with you",
                body: Self.safeText(
                    session.displayTitle,
                    bytes: RemoteAccessDefaults.maximumNotificationBodyBytes
                ),
                titleLocalization: .init(key: "Chat shared with you")
            )
            deliver(event) {
                $0.authorization.shareID == authorization.shareID
                    && $0.deviceID == deviceID
            }
        }

        let registrationSupportsPush = localPushSender != nil
            || (registration.hostedRegistrationID != nil
                && record.hostedServiceURL != nil
                && hostedPushAvailability?() == true
                && hostedPushSender != nil)
        return .registered(RemoteNotificationRegistrationResponseDTO(
            delivery: registrationSupportsPush ? .push : .live
        ))
    }

    func permissionRequested(
        sessionID: SessionID,
        toolName: String,
        summary _: String
    ) {
        guard let session = ProjectStore.shared.session(withID: sessionID) else { return }
        let event = RemoteNotificationEventDTO(
            kind: .permissionRequest,
            hostID: RemoteHostIdentity.current.id,
            sessionID: sessionID.uuidString,
            title: Self.safeText(
                "\(session.displayTitle) needs permission",
                bytes: RemoteAccessDefaults.maximumNotificationTitleBytes
            ),
            // Tool arguments, paths and diffs belong behind authentication, not on a lock screen.
            body: "\(Self.safeText(toolName, bytes: 100)) is waiting. "
                + "Open the chat to review the request.",
            titleLocalization: .init(
                key: "%@ needs permission",
                arguments: [Self.safeText(
                    session.displayTitle,
                    bytes: RemoteAccessDefaults.maximumNotificationTitleBytes
                )]
            ),
            bodyLocalization: .init(
                key: "%@ is waiting. Open the chat to review the request.",
                arguments: [Self.safeText(toolName, bytes: 100)]
            )
        )
        deliver(event) {
            $0.authorization.canApprovePermissions
                && $0.authorization.scope.covers(sessionID)
        }
    }

    /// Turns provider-neutral lifecycle edges into completion or response-needed notifications.
    /// The hook/BEL layer owns those states; notifications never scrape terminal text.
    private func activityChanged(sessionID: SessionID) {
        let activity = AgentRuntime.shared.activity(sessionID: sessionID)
        let previous = lastActivityBySession[sessionID] ?? .dormant
        lastActivityBySession[sessionID] = activity
        guard let session = ProjectStore.shared.session(withID: sessionID) else { return }

        if RemoteTurnCompletionNotificationPolicy.shouldNotify(
            from: previous,
            to: activity,
            reportsOwnTurns: AgentRuntime.shared.reportsOwnTurns(sessionID: sessionID)
        ) {
            let event = RemoteNotificationEventDTO(
                kind: .turnCompleted,
                hostID: RemoteHostIdentity.current.id,
                sessionID: sessionID.uuidString,
                title: Self.safeText(
                    session.displayTitle,
                    bytes: RemoteAccessDefaults.maximumNotificationTitleBytes
                ),
                body: "Finished its turn",
                bodyLocalization: .init(key: "Finished its turn")
            )
            let actor = currentActorBySession[sessionID] ?? .owner
            deliver(event) {
                $0.authorization.scope.covers(sessionID)
                    && RemoteTurnCompletionRecipientPolicy.matches(
                        actor,
                        authorization: $0.authorization
                    )
            }
        }

        guard activity == .awaitingUser, previous != .awaitingUser else { return }

        // Native permission requests already have a dedicated, safer notification that names
        // the tool and reaches only people allowed to decide it.
        if AgentRuntime.shared.remoteConversationSurface(for: sessionID)?
            .remoteSnapshot.permission != nil {
            return
        }

        let title = Self.safeText(
            "\(session.displayTitle) needs your response",
            bytes: RemoteAccessDefaults.maximumNotificationTitleBytes
        )
        let safeTitle = Self.safeText(
            session.displayTitle,
            bytes: RemoteAccessDefaults.maximumNotificationTitleBytes
        )
        let event = RemoteNotificationEventDTO(
            kind: .agentQuestion,
            hostID: RemoteHostIdentity.current.id,
            sessionID: sessionID.uuidString,
            title: title,
            body: "Open \(safeTitle) to answer.",
            titleLocalization: .init(
                key: "%@ needs your response",
                arguments: [safeTitle]
            ),
            bodyLocalization: .init(
                key: "Open %@ to answer.",
                arguments: [safeTitle]
            )
        )
        deliver(event) { $0.authorization.scope.covers(sessionID) }
    }

    /// Sends an explicitly requested agent update to the current turn's author by default.
    ///
    /// `recipient` also accepts `owner`, `everyone`, a member's exact display name, or
    /// `member:<id>`. Named recipients are resolved only within this chat and must be unique.
    /// A registered notification preference is consent; an open socket alone is not.
    func notifyRequested(
        sessionID: SessionID,
        title: String?,
        body: String,
        recipient rawRecipient: String?,
        destination: RemoteNotificationDestinationDTO = .session
    ) -> RequestedDeliveryResult {
        guard destination.isValid else {
            return .unavailable(reason: "The notification target is invalid.")
        }
        guard let session = ProjectStore.shared.session(withID: sessionID) else {
            return .unavailable(reason: "This chat no longer exists.")
        }
        let available = matchingSubscriptions(kind: .agentMessage) {
            $0.authorization.scope.covers(sessionID)
                && (destination.kind == .session
                    || $0.authorization.principal == .ownerDevice)
        }
        let requestedRecipient = RequestedRecipient(rawRecipient)

        let predicate: (Subscription) -> Bool
        let label: String
        switch requestedRecipient {
        case .requester:
            switch currentActorBySession[sessionID] ?? .owner {
            case .owner:
                predicate = { $0.authorization.principal == .ownerDevice }
                label = "the requester’s owner devices"
            case .member(let id, let name):
                predicate = { $0.authorization.member?.id == id }
                label = name
            }
        case .owner:
            predicate = { $0.authorization.principal == .ownerDevice }
            label = "the owner"
        case .everyone:
            predicate = { _ in true }
            label = "everyone in this chat"
        case .memberID, .named:
            let matches = available.filter { subscription in
                switch requestedRecipient {
                case .memberID(let memberID):
                    return subscription.authorization.member?.id.lowercased() == memberID
                case .named(let name):
                    return subscription.authorization.member?.displayName
                        .caseInsensitiveCompare(name) == .orderedSame
                default:
                    return false
                }
            }
            let identities = Set(matches.compactMap { $0.authorization.member?.id })
            guard identities.count == 1, let id = identities.first else {
                let names = recipientNames(in: available)
                let suffix = names.isEmpty
                    ? "No chat member has requested agent notifications enabled."
                    : "Available recipients: \(names.joined(separator: ", "))."
                return .unavailable(reason: suffix)
            }
            predicate = { $0.authorization.member?.id == id }
            let fallbackLabel: String
            switch requestedRecipient {
            case .memberID(let memberID): fallbackLabel = memberID
            case .named(let name): fallbackLabel = name
            default: fallbackLabel = "member"
            }
            label = matches.first?.authorization.member?.displayName ?? fallbackLabel
        }

        let recipients = available.filter(predicate)
        guard !recipients.isEmpty else {
            return .unavailable(
                reason: "\(label.capitalized) has not enabled requested agent notifications."
            )
        }

        let resolvedTitle = Self.safeText(
            title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? session.displayTitle,
            bytes: RemoteAccessDefaults.maximumNotificationTitleBytes
        )
        let event = RemoteNotificationEventDTO(
            kind: .agentMessage,
            hostID: RemoteHostIdentity.current.id,
            sessionID: sessionID.uuidString,
            title: resolvedTitle,
            body: Self.safeText(
                body,
                bytes: RemoteAccessDefaults.maximumNotificationBodyBytes
            ),
            destination: destination
        )
        let delivery = deliver(event) {
            $0.authorization.scope.covers(sessionID)
                && predicate($0)
        }
        guard delivery.isReachable else {
            return .unavailable(reason: delivery.requestedDeliveryFailureReason)
        }
        return .delivered(recipient: label)
    }

    /// Delivers the push/live-notification half of an explicit human attention request. The
    /// session mirror separately emits the quiet collaboration event to open chat sockets.
    /// Returning the number of reachable push targets lets the caller distinguish a useful
    /// offline poke from an opted-in registration that has no configured delivery provider.
    @discardableResult
    func attentionRequested(
        eventID: String,
        sessionID: SessionID,
        senderDisplayName: String,
        recipientID: String,
        note: String?
    ) -> Int {
        guard let session = ProjectStore.shared.session(withID: sessionID) else { return 0 }
        let predicate: (Subscription) -> Bool
        if recipientID == RemoteCollaborationParticipantDTO.ownerID {
            predicate = { $0.authorization.principal == .ownerDevice }
        } else {
            predicate = { $0.authorization.member?.id == recipientID }
        }

        let sender = Self.safeText(
            senderDisplayName,
            bytes: RemoteAccessDefaults.maximumNotificationTitleBytes
        )
        let safeSessionTitle = Self.safeText(
            session.displayTitle,
            bytes: RemoteAccessDefaults.maximumNotificationTitleBytes
        )
        let event = RemoteNotificationEventDTO(
            id: eventID,
            kind: .attentionRequest,
            hostID: RemoteHostIdentity.current.id,
            sessionID: sessionID.uuidString,
            title: Self.safeText(
                "\(sender) asked for your input",
                bytes: RemoteAccessDefaults.maximumNotificationTitleBytes
            ),
            body: note.map {
                Self.safeText($0, bytes: RemoteAccessDefaults.maximumNotificationBodyBytes)
            } ?? "Open \(safeSessionTitle) to respond.",
            titleLocalization: .init(
                key: "%@ asked for your input",
                arguments: [sender]
            ),
            bodyLocalization: note == nil
                ? .init(key: "Open %@ to respond.", arguments: [safeSessionTitle])
                : nil
        )
        return deliver(event) {
            $0.authorization.scope.covers(sessionID) && predicate($0)
        }.pushTargets
    }

    func revoke(shareID: String) {
        // Authorization was already revoked in its owning Keychain store. Drop live delivery
        // unconditionally; a secondary-store refusal may leave inert cleanup work, never access.
        subscriptions = subscriptions.filter { $0.value.authorization.shareID != shareID }
        announcedGuestShares = announcedGuestShares.filter { !$0.hasPrefix("\(shareID):") }
        guard !persistenceWritesBlocked else { return }
        let candidate = persistedSubscriptions.filter { $0.key.shareID != shareID }
        guard candidate.count != persistedSubscriptions.count else { return }
        do {
            try subscriptionStore.save(Self.sortedRecords(candidate.values))
            persistedSubscriptions = candidate
            persistenceError = nil
        } catch {
            recordPersistenceFailure(error, stage: "revoke")
        }
    }

    func reset() {
        subscriptions.removeAll()
        announcedGuestShares.removeAll()
        currentActorBySession.removeAll()
    }

    /// `Reset Everything` is explicit authority to erase even an unreadable Keychain item.
    func deleteAllForAppReset() throws {
        do {
            try subscriptionStore.deleteAll()
        } catch {
            ThreadingLogger.remote.error(
                "Remote notification persistence failed stage=delete error=\(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            recordPersistenceDiagnostic(stage: "delete")
            throw error
        }
        subscriptions.removeAll()
        persistedSubscriptions.removeAll()
        announcedGuestShares.removeAll()
        persistenceError = nil
        persistenceWritesBlocked = false
        ThreadingLogger.remote.notice("Remote notification registrations deleted for app reset")
    }

    @discardableResult
    private func deliver(
        _ event: RemoteNotificationEventDTO,
        matching predicate: @escaping (Subscription) -> Bool
    ) -> DeliverySummary {
        let targets = subscriptions.values.filter {
            $0.enabledKinds.contains(event.kind) && predicate($0)
        }
        let activeHostedServiceURL = RemoteNotificationSubscriptionDefaults
            .normalizedHostedServiceURL(hostedPushServiceURL?())
        let pushTargets: [Subscription]
        let pushBlock: DeliverySummary.PushBlock
        if localPushSender != nil {
            pushTargets = targets
            pushBlock = .none
        } else {
            pushTargets = targets.filter {
                $0.hostedRegistrationID != nil
                    && Self.hostedRegistration(
                        serviceURL: $0.hostedServiceURL,
                        belongsTo: activeHostedServiceURL
                    )
            }
            if !pushTargets.isEmpty {
                pushBlock = supportsPush ? .none : .providerUnavailable
            } else if targets.contains(where: { $0.hostedRegistrationID != nil }) {
                pushBlock = .serviceMismatch
            } else {
                pushBlock = .noRegistration
            }
        }
        let liveRecipients = RemoteSessionMirrorRegistry.shared.broadcastNotification(event) {
            authorization, deviceID in
            // The authenticated socket proves access, while this exact device registration proves
            // notification consent. One opted-in owner device must not opt every owner device in.
            guard let deviceID,
                  let subscription = subscriptions[
                    RemoteNotificationSubscriptionKey(
                        shareID: authorization.shareID,
                        deviceID: deviceID
                    )
                  ],
                  subscription.enabledKinds.contains(event.kind) else {
                return false
            }
            return predicate(subscription)
        }

        guard supportsPush else {
            MacRemoteDiagnostics.record(
                .pushProviderRefused,
                level: .warning,
                fields: [
                    .trace: event.id,
                    .kind: event.kind.rawValue,
                    .reason: "provider-configuration",
                ]
            )
            EventLog.shared.record(.remote, "Remote push unavailable", [
                "notification": event.id,
                "kind": event.kind.rawValue,
                "reason": "provider configuration",
            ])
            return DeliverySummary(
                liveRecipients: liveRecipients,
                pushTargets: 0,
                pushBlock: pushBlock == .none ? .providerUnavailable : pushBlock
            )
        }
        for target in pushTargets {
            let device = Self.diagnosticID(target.deviceID, prefix: "device")
            Task {
                let result: RemoteAPNSDeliveryResult
                if let localPushSender {
                    result = await localPushSender.send(
                        event,
                        deviceToken: target.deviceToken,
                        environment: target.environment,
                        playsSound: target.soundEnabledKinds.contains(event.kind)
                    )
                } else if let hostedPushSender,
                          let hostedRegistrationID = target.hostedRegistrationID {
                    result = await hostedPushSender(
                        event,
                        hostedRegistrationID,
                        target.soundEnabledKinds.contains(event.kind)
                    )
                } else {
                    return
                }
                var detail = [
                    "notification": event.id,
                    "kind": event.kind.rawValue,
                    "device": device,
                    "environment": target.environment.rawValue,
                    "result": result.accepted ? "accepted" : "refused",
                    "status": result.statusCode.map(String.init) ?? "transport",
                ]
                if let apnsID = result.apnsID {
                    detail["apnsID"] = apnsID
                }
                var diagnosticFields: [RemoteDiagnosticField: String] = [
                    .trace: event.id,
                    .kind: event.kind.rawValue,
                    .peer: device,
                    .environment: target.environment.rawValue,
                    .result: result.accepted ? "accepted" : "refused",
                    .status: result.statusCode.map(String.init) ?? "transport",
                ]
                if let apnsID = result.apnsID {
                    diagnosticFields[.providerTrace] = apnsID
                }
                MacRemoteDiagnostics.record(
                    result.accepted ? .pushProviderAccepted : .pushProviderRefused,
                    level: result.accepted ? .info : .warning,
                    fields: diagnosticFields
                )
                EventLog.shared.record(
                    .remote,
                    result.accepted ? "Remote push accepted" : "Remote push refused",
                    detail
                )
            }
        }
        return DeliverySummary(
            liveRecipients: liveRecipients,
            pushTargets: pushTargets.count,
            pushBlock: pushBlock
        )
    }

    private func matchingSubscriptions(
        kind: RemoteNotificationKind,
        predicate: (Subscription) -> Bool
    ) -> [Subscription] {
        subscriptions.values.filter { $0.enabledKinds.contains(kind) && predicate($0) }
    }

    nonisolated static func hostedRegistration(
        serviceURL: String?,
        belongsTo activeServiceURL: String?
    ) -> Bool {
        guard let serviceURL, let activeServiceURL else { return false }
        return serviceURL == activeServiceURL
    }

    private func recipientNames(in subscriptions: [Subscription]) -> [String] {
        var names = Set<String>()
        if subscriptions.contains(where: {
            $0.authorization.principal == .ownerDevice
        }) {
            names.insert("owner")
        }
        for subscription in subscriptions {
            if let name = subscription.authorization.member?.displayName {
                names.insert(name)
            }
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private static func subscription(
        from record: RemoteNotificationSubscriptionRecord,
        authorization: RemoteAuthorization
    ) -> Subscription? {
        guard authorization.shareID == record.shareID,
              authorization.boundDeviceID == record.deviceID,
              !authorization.isExpired,
              let environment = RemoteAPNSPushSender.Environment(
                  rawValue: record.environment.rawValue
              ) else { return nil }
        return Subscription(
            deviceID: record.deviceID,
            deviceToken: record.deviceToken,
            hostedRegistrationID: record.hostedRegistrationID,
            hostedServiceURL: record.hostedServiceURL,
            environment: environment,
            authorization: authorization,
            enabledKinds: Set(record.enabledKinds),
            soundEnabledKinds: Set(record.soundEnabledKinds)
        )
    }

    private static func sortedRecords<S: Sequence>(
        _ records: S
    ) -> [RemoteNotificationSubscriptionRecord]
    where S.Element == RemoteNotificationSubscriptionRecord {
        records.sorted {
            if $0.shareID != $1.shareID { return $0.shareID < $1.shareID }
            return $0.deviceID < $1.deviceID
        }
    }

    private static func announcementKey(_ key: RemoteNotificationSubscriptionKey) -> String {
        "\(key.shareID):\(key.deviceID)"
    }

    private func recordPersistenceFailure(_ error: Error, stage: String) {
        persistenceError = error.localizedDescription
        ThreadingLogger.remote.error(
            "Remote notification persistence failed stage=\(stage, privacy: .public) error=\(error.localizedDescription, privacy: .private(mask: .hash))"
        )
        recordPersistenceDiagnostic(stage: stage)
    }

    private func recordPersistenceDiagnostic(stage: String) {
        guard recordsPersistenceDiagnostics else { return }
        MacRemoteDiagnostics.record(
            .notificationRegistrationFailed,
            level: .error,
            fields: [
                .phase: stage,
                .reason: "persistenceUnavailable",
            ]
        )
    }

    nonisolated private static func diagnosticID(
        _ value: String,
        prefix: String
    ) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        let short = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        return "\(prefix)-\(short)"
    }

    private static func truncated(_ value: String, bytes limit: Int) -> String {
        guard value.utf8.count > limit else { return value }
        var prefix = value.utf8.prefix(max(0, limit - 3))
        while String(bytes: prefix, encoding: .utf8) == nil, !prefix.isEmpty {
            prefix = prefix.dropLast()
        }
        return String(decoding: prefix, as: UTF8.self) + "…"
    }

    /// Lock-screen copy is one line of human text, never a control-sequence transport. Besides
    /// avoiding ugly notification rendering, stripping controls bounds JSON escaping before the
    /// same strings are duplicated into APNs' alert and deep-link event payloads.
    private static func safeText(_ value: String, bytes limit: Int) -> String {
        let printable = value.unicodeScalars.map { scalar -> String in
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { return " " }
            if CharacterSet.controlCharacters.contains(scalar) { return "" }
            return String(scalar)
        }.joined()
        let oneLine = printable
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return truncated(oneLine, bytes: limit)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// A small APNs provider hosted by the Mac. Credentials are never shipped in either app:
/// development and self-hosted builds point Threading at an Apple `.p8` key through environment
/// variables; a production distribution can replace this sender with its relay without changing
/// subscription or authorization semantics.
struct RemoteAPNSDeliveryResult: Equatable, Sendable {
    let statusCode: Int?
    let reason: String
    let apnsID: String?

    var accepted: Bool { statusCode == 200 }

    var diagnosticDescription: String {
        var parts = [statusCode.map { "HTTP \($0)" } ?? "No HTTP response", reason]
        if let apnsID, !apnsID.isEmpty {
            parts.append("apns-id \(apnsID)")
        }
        return parts.joined(separator: " · ")
    }
}

actor RemoteAPNSPushSender {

    private static let maximumPrivateKeyBytes = 64 * 1_024

    enum Environment: String {
        case sandbox
        case production

        var host: String {
            switch self {
            case .sandbox: return "api.sandbox.push.apple.com"
            case .production: return "api.push.apple.com"
            }
        }
    }

    private struct Configuration {
        let keyID: String
        let teamID: String
        let topic: String
        let privateKey: P256.Signing.PrivateKey
    }

    private struct Envelope: Encodable {
        struct APS: Encodable {
            struct Alert: Encodable {
                let title: String
                let body: String
                let titleLocalizationKey: String?
                let titleLocalizationArguments: [String]?
                let bodyLocalizationKey: String?
                let bodyLocalizationArguments: [String]?

                private enum CodingKeys: String, CodingKey {
                    case title, body
                    case titleLocalizationKey = "title-loc-key"
                    case titleLocalizationArguments = "title-loc-args"
                    case bodyLocalizationKey = "loc-key"
                    case bodyLocalizationArguments = "loc-args"
                }
            }

            let alert: Alert
            let sound: String?
            let threadID: String
            let category: String

            private enum CodingKeys: String, CodingKey {
                case alert, sound, category
                case threadID = "thread-id"
            }
        }

        let aps: APS
        let event: RemoteNotificationEventDTO
    }

    private let configuration: Configuration
    private var cachedJWT: (value: String, issuedAt: TimeInterval)?

    private init(configuration: Configuration) {
        self.configuration = configuration
    }

    nonisolated static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> RemoteAPNSPushSender? {
        guard let keyID = environment["THREADING_APNS_KEY_ID"]?.nilIfEmpty,
              let teamID = environment["THREADING_APNS_TEAM_ID"]?.nilIfEmpty,
              let path = environment["THREADING_APNS_PRIVATE_KEY_PATH"]?.nilIfEmpty,
              let bytes = try? BoundedFileReader.read(
                  URL(fileURLWithPath: (path as NSString).expandingTildeInPath),
                  maximumBytes: maximumPrivateKeyBytes
              ),
              let pem = String(data: bytes, encoding: .utf8),
              let privateKey = try? P256.Signing.PrivateKey(pemRepresentation: pem)
        else {
            return nil
        }
        return RemoteAPNSPushSender(configuration: Configuration(
            keyID: keyID,
            teamID: teamID,
            topic: environment["THREADING_APNS_TOPIC"]?.nilIfEmpty
                ?? "codes.threading.mobile",
            privateKey: privateKey
        ))
    }

    @discardableResult
    func send(
        _ event: RemoteNotificationEventDTO,
        deviceToken: String,
        environment: Environment,
        playsSound: Bool = true
    ) async -> RemoteAPNSDeliveryResult {
        guard let url = URL(
            string: "https://\(environment.host)/3/device/\(deviceToken)"
        ) else {
            return RemoteAPNSDeliveryResult(
                statusCode: nil,
                reason: "Could not construct the APNs device URL.",
                apnsID: nil
            )
        }

        var deliveredEvent = event
        var body = try? JSONEncoder().encode(envelope(
            for: deliveredEvent,
            playsSound: playsSound
        ))
        if let count = body?.count, count > 4_096 {
            // APNs rejects an alert payload above 4 KB. Keep the same event id/deep link and a
            // useful prefix instead of turning an unusually escaped summary into silent loss.
            deliveredEvent = RemoteNotificationEventDTO(
                id: event.id,
                kind: event.kind,
                hostID: event.hostID,
                sessionID: event.sessionID,
                title: event.title,
                body: String(event.body.prefix(400)),
                titleLocalization: event.titleLocalization,
                bodyLocalization: event.bodyLocalization,
                destination: event.destination,
                createdAt: event.createdAt
            )
            body = try? JSONEncoder().encode(envelope(
                for: deliveredEvent,
                playsSound: playsSound
            ))
        }
        guard let body, body.count <= 4_096 else {
            return RemoteAPNSDeliveryResult(
                statusCode: nil,
                reason: "The notification payload could not be encoded below the APNs 4 KB limit.",
                apnsID: nil
            )
        }
        guard let jwt = authorizationToken() else {
            return RemoteAPNSDeliveryResult(
                statusCode: nil,
                reason: "The APNs provider token could not be signed.",
                apnsID: nil
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")
        request.setValue(configuration.topic, forHTTPHeaderField: "apns-topic")
        request.setValue("alert", forHTTPHeaderField: "apns-push-type")
        request.setValue("10", forHTTPHeaderField: "apns-priority")
        // Keep a temporarily-offline phone useful without allowing a stale approval prompt to
        // arrive days later. Requested agent updates can remain relevant for the rest of a day.
        let retention: TimeInterval = event.kind == .permissionRequest ? 3_600 : 86_400
        request.setValue(
            String(Int(event.createdAt + retention)),
            forHTTPHeaderField: "apns-expiration"
        )
        let collapseID = deliveredEvent.kind == .agentMessage
            ? deliveredEvent.id
            : "\(deliveredEvent.kind.rawValue)-\(deliveredEvent.sessionID)"
        request.setValue(collapseID, forHTTPHeaderField: "apns-collapse-id")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return RemoteAPNSDeliveryResult(
                    statusCode: nil,
                    reason: "APNs returned a non-HTTP response.",
                    apnsID: nil
                )
            }
            let result = RemoteAPNSDeliveryResult(
                statusCode: http.statusCode,
                reason: Self.responseReason(from: data)
                    ?? (http.statusCode == 200 ? "Accepted by APNs." : "APNs refused the notification."),
                apnsID: http.value(forHTTPHeaderField: "apns-id")
            )
            if !result.accepted {
                ThreadingLogger.remote.warning(
                    "APNs refused a remote notification: \(result.diagnosticDescription, privacy: .private(mask: .hash))"
                )
            }
            return result
        } catch {
            ThreadingLogger.remote.warning(
                "APNs notification delivery failed: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return RemoteAPNSDeliveryResult(
                statusCode: nil,
                reason: error.localizedDescription,
                apnsID: nil
            )
        }
    }

    private func envelope(
        for event: RemoteNotificationEventDTO,
        playsSound: Bool
    ) -> Envelope {
        Envelope(
            aps: .init(
                alert: .init(
                    title: event.title,
                    body: event.body,
                    titleLocalizationKey: event.titleLocalization?.key,
                    titleLocalizationArguments: event.titleLocalization?.arguments,
                    bodyLocalizationKey: event.bodyLocalization?.key,
                    bodyLocalizationArguments: event.bodyLocalization?.arguments
                ),
                sound: playsSound ? "default" : nil,
                threadID: event.sessionID,
                category: event.kind == .permissionRequest
                    ? "THREADING_PERMISSION"
                    : "THREADING_SESSION"
            ),
            event: event
        )
    }

    private func authorizationToken(now: TimeInterval = Date().timeIntervalSince1970) -> String? {
        if let cachedJWT, now - cachedJWT.issuedAt < 50 * 60 {
            return cachedJWT.value
        }
        let header = Self.base64URL(Data(
            #"{"alg":"ES256","kid":"\#(configuration.keyID)"}"#.utf8
        ))
        let claims = Self.base64URL(Data(
            #"{"iss":"\#(configuration.teamID)","iat":\#(Int(now))}"#.utf8
        ))
        let signingInput = "\(header).\(claims)"
        guard let signature = try? configuration.privateKey.signature(
            for: Data(signingInput.utf8)
        ) else { return nil }
        let token = "\(signingInput).\(Self.base64URL(signature.rawRepresentation))"
        cachedJWT = (token, now)
        return token
    }

    nonisolated private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    nonisolated private static func responseReason(from data: Data) -> String? {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["reason"] as? String
    }
}
