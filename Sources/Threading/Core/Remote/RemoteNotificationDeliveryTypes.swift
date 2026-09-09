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

    /// Whether a request was actually put on the network.
    ///
    /// `status=transport` is reserved for a request that received no HTTP response, so a
    /// refusal decided on this Mac — no provider configured, a registration retired with its
    /// service, consent withdrawn while the send was queued — must not be reported as one.
    /// Flattening the two produced 835 refusals in the week to 8 September 2026 that carried
    /// no HTTP status and no code, and could not afterwards be attributed to any cause.
    let attempted: Bool

    init(
        accepted: Bool,
        statusCode: Int?,
        providerTrace: String?,
        failureCode: String? = nil,
        attempted: Bool = true
    ) {
        self.accepted = accepted
        self.statusCode = statusCode
        self.providerTrace = providerTrace
        self.failureCode = failureCode
        self.attempted = attempted
    }

    /// A send this Mac refused before any network I/O, named by cause.
    static func refusedLocally(_ failureCode: String) -> RemoteNotificationPushResult {
        RemoteNotificationPushResult(
            accepted: false,
            statusCode: nil,
            providerTrace: nil,
            failureCode: failureCode,
            attempted: false
        )
    }

    /// What the delivery journal records in its `status` field.
    var diagnosticStatus: String {
        if let statusCode { return String(statusCode) }
        return attempted ? "transport" : "local"
    }
}
