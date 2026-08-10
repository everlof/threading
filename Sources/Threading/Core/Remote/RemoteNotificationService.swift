import CryptoKit
import Foundation
import ThreadingRemoteKit

/// Session-scoped notification fan-out.
///
/// A live events socket gives an open phone an immediate event. APNs covers suspension and
/// backgrounding when provider credentials are configured on the Mac. Both paths receive the
/// same bounded DTO and the phone deduplicates by its stable event id.
@MainActor
final class RemoteNotificationService {

    static let shared = RemoteNotificationService()

    enum RequestedDeliveryResult: Equatable {
        case delivered(recipient: String)
        case unavailable(reason: String)
    }

    private enum InteractionActor: Equatable {
        case owner
        case member(id: String, name: String)
    }

    private struct Subscription {
        let deviceID: String
        let deviceToken: String
        let environment: RemoteAPNSPushSender.Environment
        let authorization: RemoteAuthorization
        let enabledKinds: Set<RemoteNotificationKind>
        let soundEnabledKinds: Set<RemoteNotificationKind>
    }

    private struct DeliverySummary {
        let liveRecipients: Int
        let pushTargets: Int

        var isReachable: Bool { liveRecipients > 0 || pushTargets > 0 }
    }

    private var subscriptions: [String: Subscription] = [:]
    private let pushSender = RemoteAPNSPushSender.fromEnvironment()
    private let observations = AppEventObservations()
    private var announcedGuestShares: Set<String> = []
    private var currentActorBySession: [SessionID: InteractionActor] = [:]
    private var lastActivityBySession: [SessionID: SessionActivity] = [:]

    private init() {
        observations.observe(SessionActivityDidChange.self) { [weak self] event in
            Task { @MainActor in self?.activityChanged(sessionID: event.sessionID) }
        }
        observations.observe(TerminalSessionDidEnd.self) { [weak self] event in
            Task { @MainActor in self?.lastActivityBySession[event.sessionID] = nil }
        }
    }

    var supportsPush: Bool { pushSender != nil }

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
        let normalized = rawRecipient?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalized {
        case "owner", "everyone", "all":
            return true
        case nil, "", "requester", "me":
            return (currentActorBySession[sessionID] ?? .owner) == .owner
        default:
            return false
        }
    }

    func register(
        _ registration: RemoteNotificationRegistrationDTO,
        deviceID: String,
        authorization: RemoteAuthorization
    ) -> RemoteNotificationRegistrationResponseDTO? {
        guard let environment = RemoteAPNSPushSender.Environment(
            rawValue: registration.environment
        ), Self.acceptsDeviceToken(registration.deviceToken) else {
            return nil
        }

        let key = "\(authorization.shareID):\(deviceID)"
        subscriptions[key] = Subscription(
            deviceID: deviceID,
            deviceToken: registration.deviceToken.lowercased(),
            environment: environment,
            authorization: authorization,
            enabledKinds: Set(registration.enabledKinds),
            soundEnabledKinds: Set(
                registration.soundEnabledKinds ?? registration.enabledKinds
            )
        )

        // A guest cannot be notified before accepting a capability: there is no account or
        // device identity to target yet. Registration is that acceptance boundary, so announce
        // the newly shared chat exactly once here.
        if authorization.principal == .guest,
           !announcedGuestShares.contains(key),
           case .session(let sessionID) = authorization.scope,
           let session = ProjectStore.shared.session(withID: sessionID) {
            announcedGuestShares.insert(key)
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

        return RemoteNotificationRegistrationResponseDTO(
            delivery: pushSender == nil ? "live" : "push"
        )
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

    /// A provider-neutral session edge says the terminal is waiting for a human response.
    /// The hook/BEL layer owns detecting that state; notifications never scrape terminal text.
    private func activityChanged(sessionID: SessionID) {
        let activity = AgentRuntime.shared.activity(sessionID: sessionID)
        let previous = lastActivityBySession[sessionID] ?? .dormant
        lastActivityBySession[sessionID] = activity
        guard activity == .awaitingUser, previous != .awaitingUser,
              let session = ProjectStore.shared.session(withID: sessionID) else { return }

        // Native permission requests already have a dedicated, safer notification that names
        // the tool and reaches only people allowed to decide it.
        if AgentRuntime.shared.conversation(for: sessionID)?.remoteSnapshot.permission != nil {
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
        let requested = rawRecipient?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = requested?.lowercased()

        let predicate: (Subscription) -> Bool
        let label: String
        switch normalized {
        case nil, "", "requester", "me":
            switch currentActorBySession[sessionID] ?? .owner {
            case .owner:
                predicate = { $0.authorization.principal == .ownerDevice }
                label = "the requester’s owner devices"
            case .member(let id, let name):
                predicate = { $0.authorization.member?.id == id }
                label = name
            }
        case "owner":
            predicate = { $0.authorization.principal == .ownerDevice }
            label = "the owner"
        case "everyone", "all":
            predicate = { _ in true }
            label = "everyone in this chat"
        default:
            let memberID = normalized.flatMap { normalized in
                normalized.hasPrefix("member:")
                    ? String(normalized.dropFirst("member:".count))
                    : nil
            }
            let matches = available.filter {
                if let memberID {
                    return $0.authorization.member?.id.lowercased() == memberID
                }
                return $0.authorization.member?.displayName
                    .caseInsensitiveCompare(requested ?? "") == .orderedSame
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
            label = matches.first?.authorization.member?.displayName ?? requested ?? "member"
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
            return .unavailable(reason: "No opted-in device is currently reachable.")
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
        subscriptions = subscriptions.filter { $0.value.authorization.shareID != shareID }
        announcedGuestShares = announcedGuestShares.filter { !$0.hasPrefix("\(shareID):") }
    }

    func reset() {
        subscriptions.removeAll()
        announcedGuestShares.removeAll()
        currentActorBySession.removeAll()
    }

    @discardableResult
    private func deliver(
        _ event: RemoteNotificationEventDTO,
        matching predicate: @escaping (Subscription) -> Bool
    ) -> DeliverySummary {
        let targets = subscriptions.values.filter {
            $0.enabledKinds.contains(event.kind) && predicate($0)
        }
        let liveRecipients = RemoteSessionMirrorRegistry.shared.broadcastNotification(event) {
            authorization, deviceID in
            // The authenticated socket proves access, while this exact device registration proves
            // notification consent. One opted-in owner device must not opt every owner device in.
            guard let deviceID,
                  let subscription = subscriptions[
                    "\(authorization.shareID):\(deviceID)"
                  ],
                  subscription.enabledKinds.contains(event.kind) else {
                return false
            }
            return predicate(subscription)
        }

        guard let pushSender else {
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
            return DeliverySummary(liveRecipients: liveRecipients, pushTargets: 0)
        }
        for target in targets {
            let device = Self.diagnosticID(target.deviceID, prefix: "device")
            Task {
                let result = await pushSender.send(
                    event,
                    deviceToken: target.deviceToken,
                    environment: target.environment,
                    playsSound: target.soundEnabledKinds.contains(event.kind)
                )
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
            pushTargets: targets.count
        )
    }

    private func matchingSubscriptions(
        kind: RemoteNotificationKind,
        predicate: (Subscription) -> Bool
    ) -> [Subscription] {
        subscriptions.values.filter { $0.enabledKinds.contains(kind) && predicate($0) }
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

    private static func acceptsDeviceToken(_ value: String) -> Bool {
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !token.isEmpty
            && token.utf8.count <= RemoteAccessDefaults.maximumPushDeviceTokenBytes
            && token.unicodeScalars.allSatisfy {
                (48...57).contains($0.value)
                    || (65...70).contains($0.value)
                    || (97...102).contains($0.value)
            }
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
                    "APNs refused a remote notification: \(result.diagnosticDescription, privacy: .public)"
                )
            }
            return result
        } catch {
            ThreadingLogger.remote.warning(
                "APNs notification delivery failed: \(error.localizedDescription, privacy: .public)"
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
