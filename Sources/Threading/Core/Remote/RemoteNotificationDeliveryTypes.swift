import Foundation

/// Transport identity shared by completion and response-request lifetimes. Consent is read from
/// the authoritative subscription immediately before I/O, not encoded into recipient identity.
struct RemoteNotificationTargetIdentity: Hashable, Sendable {
    let shareID: String
    let deviceID: String
    let participantID: RemoteNotificationParticipantID
}

struct RemoteNotificationPushResult: Equatable, Sendable {
    let accepted: Bool
    let statusCode: Int?
    let providerTrace: String?
    let failureCode: String?

    init(
        accepted: Bool,
        statusCode: Int?,
        providerTrace: String?,
        failureCode: String? = nil
    ) {
        self.accepted = accepted
        self.statusCode = statusCode
        self.providerTrace = providerTrace
        self.failureCode = failureCode
    }
}
