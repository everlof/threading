import Foundation
import ThreadingExtensionKit
import ThreadingRemoteKit
import UIKit

enum RemoteDeviceIdentity {
    static var current: String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: "remoteDeviceID") {
            return existing
        }
        let made = UUID().uuidString.lowercased()
        defaults.set(made, forKey: "remoteDeviceID")
        return made
    }

    /// What the Mac's sharing pane calls this device — "iPhone", "iPad".
    ///
    /// The *model*, not `UIDevice.name`: the user-assigned name is entitlement-gated and, where
    /// it is readable at all, is usually the owner's own first name. A row that has to be
    /// recognised across a room wants the kind of device, and the pane already prints who the
    /// member is beside it.
    @MainActor static var currentName: String {
        UIDevice.current.model
    }
}

enum RemoteClientDefaults {
    static let requestTimeoutSeconds: TimeInterval = 20
    static let resourceTimeoutSeconds: TimeInterval = 30
    /// How far down a Foundation error chain the local-network diagnosis will look. Underlying
    /// errors nest, and an unbounded walk over attacker- or framework-controlled `userInfo` is
    /// not a bound.
    static let underlyingErrorDepthLimit = 4
}

/// Which private-network addresses iOS asks for Local Network permission before reaching.
///
/// The denial produces an ordinary no-route POSIX error, identical to the one a genuinely
/// unreachable host produces, so the address is what separates "you did not grant this" from
/// "that machine is off". Loopback is deliberately absent: it needs no grant.
enum RemoteLocalNetworkAddress {
    static func isPrivate(_ host: String) -> Bool {
        let lowered = host.lowercased()
        if lowered.hasSuffix(".local") { return true }
        if lowered.hasPrefix("fe80:") { return true }
        // Unique local addresses, fc00::/7.
        if lowered.hasPrefix("fc") || lowered.hasPrefix("fd") {
            if lowered.contains(":") { return true }
        }
        let parts = lowered.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let octets = parts.compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        switch octets[0] {
        case 10: return true
        case 169: return octets[1] == 254
        case 172: return (16...31).contains(octets[1])
        case 192: return octets[1] == 168
        default: return false
        }
    }
}

enum RemoteClientError: LocalizedError {
    case invalidResponse
    case unauthorized
    /// A `426` naming the side that is behind. The direction is kept because it decides the
    /// sentence: the same refusal means "update this app" one way and "this Mac needs a newer
    /// app" the other, and telling somebody to update the wrong device is worse than saying
    /// nothing.
    case upgradeRequired(RemoteUpdateTarget)
    case server(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return MobileL10n.string("The Mac returned an unreadable response.")
        case .unauthorized:
            return MobileL10n.string(
                "This invitation is expired or already used, or this membership was revoked."
            )
        case .upgradeRequired(let target):
            return Self.upgradeMessage(for: target)
        case .server(let status):
            return MobileL10n.string("The Mac returned HTTP %lld.", status)
        }
    }

    static func upgradeMessage(for target: RemoteUpdateTarget) -> String {
        switch target {
        case .client:
            return MobileL10n.string(
                "This version of Threading can’t connect to this Mac. Update Threading and try again."
            )
        case .host:
            return MobileL10n.string(
                "This Mac needs a newer version of Threading. Update Threading on the Mac and try again."
            )
        }
    }
}

/// Where a person goes to get the newer app either side of a refused protocol version.
///
/// One address for both directions on purpose: it is the page that hands out the Mac app and
/// links the iPhone one, so it is right whichever side the Mac says is behind. Replace it with a
/// direct App Store product link for the `client` direction once that listing exists.
enum RemoteUpdateDefaults {
    static let downloadPage = URL(string: "https://threading.codes")!
}

/// Why a remote connection stopped, in a form a screen can act on.
///
/// A localized sentence is not a state. The 2026-08-17 incident produced a phone stuck on
/// "Connecting…" and a support report that could say only that something answered and it was not
/// the Mac; both halves of that are fixed by naming the cause, keeping a structural code beside
/// the sentence a person reads, and stating what the one available next step is.
struct RemoteConnectionFailure: Equatable {

    /// What the person can do about it, which is not always "try again".
    enum Recovery: Equatable {
        case reconnect
        case pairAgain
        case openLocalNetworkSettings
        case openUpdatePage(URL)
    }

    enum Cause: String, Equatable {
        /// The address answered, and what answered was not this Mac's listener. A Quick Tunnel
        /// hostname outlives the tunnel, so a paired phone keeps reaching a stranger's 404.
        case addressChanged
        /// The address answered with a certificate that is not the one this phone pinned.
        ///
        /// Never folded into `addressChanged` or into a generic network error: those two say
        /// "the Mac moved" and "the network is unhappy", and this says something presented a
        /// different identity at the Mac's address. It is the one failure whose only honest
        /// remedy is scanning the code again, and only after checking that the Mac is the one
        /// that changed.
        case pinnedIdentityMismatch
        /// iOS refused the connection because Local Network access was never granted. It is a
        /// no-route POSIX error on a private address, which is indistinguishable from an absent
        /// host until the address is taken into account.
        case localNetworkDenied
        /// One side is too old for the other. The message says which.
        case upgradeRequired
        /// The socket opened and the Mac never greeted it.
        case helloTimeout
        /// The Mac refused an action over an otherwise healthy socket.
        case remoteAction
        /// Anything else the transport reported.
        case transport
    }

    let cause: Cause
    let message: String
    /// Where the person is sent for `upgradeRequired`, which is the only cause carrying an
    /// address of its own.
    let updatePage: URL?

    init(cause: Cause, message: String, updatePage: URL? = nil) {
        self.cause = cause
        self.message = message
        self.updatePage = updatePage
    }

    var recovery: Recovery {
        switch cause {
        case .addressChanged, .pinnedIdentityMismatch: return .pairAgain
        case .localNetworkDenied: return .openLocalNetworkSettings
        case .upgradeRequired:
            return .openUpdatePage(updatePage ?? RemoteUpdateDefaults.downloadPage)
        case .helloTimeout, .remoteAction, .transport: return .reconnect
        }
    }

    /// The one-tap next step, as the label a control or an accessibility hint uses.
    var recoveryTitle: String {
        switch recovery {
        case .reconnect: return MobileL10n.string("Reconnect")
        case .pairAgain: return MobileL10n.string("Scan the QR code again")
        case .openLocalNetworkSettings: return MobileL10n.string("Open Settings")
        case .openUpdatePage: return MobileL10n.string("Open the download page")
        }
    }

    static func helloTimeout() -> RemoteConnectionFailure {
        RemoteConnectionFailure(
            cause: .helloTimeout,
            message: MobileL10n.string("This Mac accepted the connection but never answered.")
        )
    }

    static func remoteAction(_ message: String) -> RemoteConnectionFailure {
        RemoteConnectionFailure(cause: .remoteAction, message: message)
    }

    static func transport(_ message: String) -> RemoteConnectionFailure {
        RemoteConnectionFailure(cause: .transport, message: message)
    }

    static func upgradeRequired(_ target: RemoteUpdateTarget) -> RemoteConnectionFailure {
        RemoteConnectionFailure(
            cause: .upgradeRequired,
            message: RemoteClientError.upgradeMessage(for: target),
            updatePage: RemoteUpdateDefaults.downloadPage
        )
    }

    static func pinnedIdentityMismatch() -> RemoteConnectionFailure {
        RemoteConnectionFailure(
            cause: .pinnedIdentityMismatch,
            message: MobileL10n.string(
                "This Mac’s identity does not match the one you paired with. "
                    + "If Remote Access was reset on the Mac, scan its QR code again."
            )
        )
    }

    /// Classifies a transport error against the address it was aimed at.
    ///
    /// The address is part of the diagnosis rather than decoration: Local Network denial and an
    /// absent host produce the same POSIX code, and only a private destination makes the
    /// permission the likelier of the two. Nothing here is mapped to "address changed" unless
    /// the socket really did get an HTTP answer that was not an upgrade.
    ///
    /// The pinning check is read first and from the delegate rather than from the error,
    /// because a cancelled server-trust challenge arrives as `URLError(-999)` with no underlying
    /// error and is indistinguishable from a user cancelling a request. The delegate's own
    /// verdict for that host is the only place the reason exists.
    static func transport(_ error: Error, host: String?) -> RemoteConnectionFailure {
        transport(
            error,
            host: host,
            trustVerdict: host.flatMap { RemoteClient.pinningDelegate.verdict(forHost: $0) }
        )
    }

    static func transport(
        _ error: Error,
        host: String?,
        trustVerdict: RemoteTrustVerdict?
    ) -> RemoteConnectionFailure {
        if trustVerdict == .rejectedFingerprintMismatch {
            return pinnedIdentityMismatch()
        }
        if let remote = error as? RemoteClientError, case .upgradeRequired(let target) = remote {
            return upgradeRequired(target)
        }
        if isLocalNetworkDenial(error, host: host) {
            return RemoteConnectionFailure(
                cause: .localNetworkDenied,
                message: MobileL10n.string(
                    "Threading needs Local Network access to reach this Mac on Wi-Fi. Turn it on in Settings."
                )
            )
        }
        if (error as? URLError)?.code == .badServerResponse {
            return RemoteConnectionFailure(
                cause: .addressChanged,
                message: MobileL10n.string(
                    "This Mac’s address has changed. Scan its QR code again."
                )
            )
        }
        return RemoteConnectionFailure(
            cause: .transport,
            message: error.localizedDescription
        )
    }

    static func isLocalNetworkDenial(_ error: Error, host: String?) -> Bool {
        guard let host, RemoteLocalNetworkAddress.isPrivate(host) else { return false }
        return hasNoRouteCode(error)
    }

    /// iOS reports the denial as `NWError.posix` under whichever URL-loading error wraps it, so
    /// the POSIX code has to be read through a bounded chain rather than off the top error.
    private static func hasNoRouteCode(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        var depth = 0
        while let candidate = current, depth < RemoteClientDefaults.underlyingErrorDepthLimit {
            if candidate.domain == NSPOSIXErrorDomain,
               noRouteCodes.contains(Int32(candidate.code)) {
                return true
            }
            current = candidate.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return false
    }

    private static let noRouteCodes: Set<Int32> = [
        EHOSTUNREACH, ENETUNREACH, ENETDOWN, EHOSTDOWN,
    ]
}

/// A named failure travelling as an error, for the two paths that hand one to a screen rather
/// than to a connection phase: pairing, and anything else that reports `localizedDescription`.
extension RemoteConnectionFailure: LocalizedError {
    var errorDescription: String? { message }
}

/// One failed attempt, carrying the address it was aimed at.
///
/// A Mac has several addresses and the phone tries them in order, so by the time the last error
/// reaches a screen the record's remembered address is not necessarily the one that failed. The
/// diagnosis depends on which: the same no-route code means "grant Local Network access" on a
/// private address and "that machine is not answering" on a public one.
struct RemoteConnectionAttempt: Error {
    let underlying: Error
    let host: String?

    /// The original error, whether or not it was wrapped. Diagnostics reduce errors to a
    /// structural code, and the wrapper is not one of the codes worth recording.
    static func underlying(_ error: Error) -> Error {
        (error as? RemoteConnectionAttempt)?.underlying ?? error
    }
}

struct RemoteClient {
    let link: RemoteConnectionLink
    let requestTimeout: TimeInterval?

    init(link: RemoteConnectionLink, requestTimeout: TimeInterval? = nil) {
        self.link = link
        self.requestTimeout = requestTimeout
    }

    /// The one pinning delegate, shared by every session this client opens.
    ///
    /// A server-trust challenge goes to the *session-level* delegate whenever that method
    /// exists, which is what makes a `URLSessionWebSocketTask` go through the same check as a
    /// REST call. A socket on a session without it silently keeps stock evaluation, and stock
    /// evaluation refuses a Mac's self-signed leaf outright, so the failure would be a TLS error
    /// on the socket path alone. It is one object rather than two so a pin learned once is in
    /// force everywhere, and `RemoteHostTrust` is the only thing that writes to it.
    static let pinningDelegate = RemoteCertificatePinningDelegate()

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = RemoteClientDefaults.requestTimeoutSeconds
        configuration.timeoutIntervalForResource = RemoteClientDefaults.resourceTimeoutSeconds
        configuration.waitsForConnectivity = true
        return URLSession(
            configuration: configuration,
            delegate: pinningDelegate,
            delegateQueue: nil
        )
    }()

    /// The WebSocket half deliberately does not share the request session's configuration.
    ///
    /// `waitsForConnectivity` turns an unreachable host into an indefinite wait rather than an
    /// error, and whether `URLSessionWebSocketTask` honours `timeoutIntervalForResource` is not
    /// established (the 2026-08-17 hang was never reproduced), so a socket opened through the
    /// request session had no failure path anyone could rely on: the receive loop awaited a
    /// message that never came, nothing reconnected, and the phone showed "Connecting…" until
    /// the user gave up. Here the connect fails immediately when there is no route, and the
    /// hello deadline in `RemoteSessionConnection` is the authority that bounds a host which
    /// accepts the connection and then says nothing. The resource timeout is left at its default
    /// on purpose: a healthy session socket is long-lived, and the request session's 30 seconds
    /// would be a ceiling on the conversation rather than on the handshake.
    private static let socketSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.waitsForConnectivity = false
        return URLSession(
            configuration: configuration,
            delegate: pinningDelegate,
            delegateQueue: nil
        )
    }()

    func fetchMe(timeout: TimeInterval? = nil) async throws -> RemoteMeDTO {
        var request = request(url: link.meURL)
        if let timeout { request.timeoutInterval = timeout }
        let (data, response) = try await Self.session.data(for: request)
        return try decodeMe(data: data, response: response)
    }

    func fetchUsage(
        cursor: String? = nil,
        limit: Int? = nil
    ) async throws -> RemoteUsageDashboardDTO {
        try await get(
            RemoteUsageDashboardDTO.self,
            from: link.usageURL(cursor: cursor, limit: limit)
        )
    }

    func fetchUsageLimit(seriesID: String, days: Int) async throws -> RemoteUsageLimitDTO {
        try await get(
            RemoteUsageLimitDTO.self,
            from: link.usageLimitURL(seriesID: seriesID, days: days)
        )
    }

    func acceptInvitation(
        displayName: String,
        requestID: String = UUID().uuidString.lowercased()
    ) async throws -> RemoteAcceptInvitationResponseDTO {
        try await postResponse(
            RemoteAcceptInvitationRequestDTO(displayName: displayName),
            to: link.invitationAcceptanceURL,
            requestID: requestID
        )
    }

    func issueHostedDeviceCredential(
        requestID: String = UUID().uuidString.lowercased()
    ) async throws -> RemoteHostedDeviceCredentialDTO {
        try await postResponse(
            RemoteHostedDeviceCredentialRequestDTO(),
            to: link.hostedDeviceCredentialURL,
            requestID: requestID
        )
    }

    func resume(
        sessionID: String,
        requestID: String = UUID().uuidString.lowercased()
    ) async throws {
        var request = request(url: link.resumeURL(sessionID: sessionID))
        request.httpMethod = "POST"
        request.setValue(requestID, forHTTPHeaderField: "X-Threading-Request-ID")
        let (data, response) = try await dataReplayingNetworkFailure(for: request)
        _ = try validate(data: data, response: response, accepted: 200...299)
    }

    func setAppTheme(
        themeID: String,
        requestID: String = UUID().uuidString.lowercased()
    ) async throws -> RemoteMeDTO {
        try await post(
            RemoteSetAppThemeRequestDTO(themeID: themeID),
            to: link.appThemeURL,
            requestID: requestID
        )
    }

    func setSessionTheme(
        sessionID: String,
        themeID: String?,
        requestID: String = UUID().uuidString.lowercased()
    ) async throws -> RemoteMeDTO {
        try await post(
            RemoteSetTerminalThemeRequestDTO(themeID: themeID),
            to: link.sessionThemeURL(sessionID: sessionID),
            requestID: requestID
        )
    }

    func createSession(
        _ creation: RemoteCreateSessionRequestDTO,
        requestID: String = UUID().uuidString.lowercased()
    ) async throws -> RemoteCreateSessionResponseDTO {
        try await postResponse(creation, to: link.createSessionURL, requestID: requestID)
    }

    func renameSession(
        sessionID: String,
        title: String,
        requestID: String = UUID().uuidString.lowercased()
    ) async throws -> RemoteMeDTO {
        try await post(
            RemoteRenameSessionRequestDTO(title: title),
            to: link.renameSessionURL(sessionID: sessionID),
            requestID: requestID
        )
    }

    func setSessionPinned(
        sessionID: String,
        isPinned: Bool,
        requestID: String = UUID().uuidString.lowercased()
    ) async throws -> RemoteMeDTO {
        try await post(
            RemoteSetSessionPinnedRequestDTO(isPinned: isPinned),
            to: link.pinnedSessionURL(sessionID: sessionID),
            requestID: requestID
        )
    }

    func setSessionArchived(
        sessionID: String,
        isArchived: Bool,
        requestID: String = UUID().uuidString.lowercased()
    ) async throws -> RemoteMeDTO {
        try await post(
            RemoteSetSessionArchivedRequestDTO(isArchived: isArchived),
            to: link.archivedSessionURL(sessionID: sessionID),
            requestID: requestID
        )
    }

    func setSessionSnoozed(
        sessionID: String,
        until deadline: Date?,
        requestID: String = UUID().uuidString.lowercased()
    ) async throws -> RemoteMeDTO {
        try await post(
            RemoteSetSessionSnoozeRequestDTO(
                snoozedUntil: deadline?.timeIntervalSince1970
            ),
            to: link.snoozedSessionURL(sessionID: sessionID),
            requestID: requestID
        )
    }

    func setSessionSurface(
        sessionID: String,
        surface: RemoteSessionSurface,
        requestID: String = UUID().uuidString.lowercased()
    ) async throws -> RemoteMeDTO {
        try await post(
            RemoteSetSessionSurfaceRequestDTO(surface: surface),
            to: link.sessionSurfaceURL(sessionID: sessionID),
            requestID: requestID
        )
    }

    func registerNotifications(
        _ registration: RemoteNotificationRegistrationDTO,
        requestID: String = UUID().uuidString.lowercased()
    ) async throws -> RemoteNotificationRegistrationResponseDTO {
        try await postResponse(
            registration,
            to: link.notificationRegistrationURL,
            requestID: requestID
        )
    }

    func uploadDiagnostics(
        _ records: [RemoteDiagnosticRecord],
        requestID: String = UUID().uuidString.lowercased()
    ) async throws -> RemoteDiagnosticUploadResponseDTO {
        try await postResponse(
            RemoteDiagnosticUploadRequestDTO(source: .iOSClient, records: records),
            to: link.diagnosticUploadURL,
            requestID: requestID
        )
    }

    func createShare(
        sessionID: String,
        capability: String,
        canApprovePermissions: Bool,
        requestID: String = UUID().uuidString.lowercased()
    ) async throws -> RemoteCreateShareResponseDTO {
        try await postResponse(
            RemoteCreateShareRequestDTO(
                capability: capability,
                canApprovePermissions: canApprovePermissions
            ),
            to: link.sessionShareURL(sessionID: sessionID),
            requestID: requestID
        )
    }

    func revokeShares(
        sessionID: String,
        requestID: String = UUID().uuidString.lowercased()
    ) async throws -> RemoteMeDTO {
        try await post(
            RemoteRevokeSharesRequestDTO(),
            to: link.sessionUnshareURL(sessionID: sessionID),
            requestID: requestID
        )
    }

    func gitReview(
        sessionID: String,
        mode: RemoteGitReviewMode
    ) async throws -> RemoteGitReviewSnapshotDTO {
        try await get(
            RemoteGitReviewSnapshotDTO.self,
            from: link.gitReviewURL(sessionID: sessionID, mode: mode)
        )
    }

    func repositoryFiles(sessionID: String) async throws -> RemoteRepositoryFilesDTO {
        try await get(
            RemoteRepositoryFilesDTO.self,
            from: link.repositoryFilesURL(sessionID: sessionID)
        )
    }

    func repositoryFile(sessionID: String, path: String) async throws -> RemoteRepositoryFileDTO {
        guard let url = link.repositoryFileURL(sessionID: sessionID, path: path) else {
            throw RemoteClientError.invalidResponse
        }
        return try await get(RemoteRepositoryFileDTO.self, from: url)
    }

    func attachments(sessionID: String) async throws -> RemoteAttachmentsDTO {
        try await get(
            RemoteAttachmentsDTO.self,
            from: link.attachmentsURL(sessionID: sessionID)
        )
    }

    func attachmentData(sessionID: String, id: String) async throws -> Data {
        guard let url = link.attachmentURL(sessionID: sessionID, id: id) else {
            throw RemoteClientError.invalidResponse
        }
        let (data, response) = try await Self.session.data(for: request(url: url))
        _ = try validate(data: data, response: response, accepted: 200...299)
        return data
    }

    /// Hands one composer attachment to the Mac, a chunk at a time, and answers its upload id.
    ///
    /// The id is the only thing the phone learns: where the file landed is the Mac's business,
    /// and a prompt names the upload rather than a path. Nothing is attached to the session yet
    /// — a completed upload waits in staging until a prompt claims it, or until the Mac reaps it.
    ///
    /// Cancelling mid-transfer simply stops: the partial upload is left for that reaper rather
    /// than raced with a delete the phone may not be online to send.
    func uploadAttachment(
        sessionID: String,
        name: String,
        mediaType: String,
        data: Data,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> String {
        guard !data.isEmpty else { throw RemoteClientError.invalidResponse }

        let url = link.attachmentUploadURL(sessionID: sessionID)
        let chunkSize = RemoteAttachmentUploadClientDefaults.chunkBytes
        let chunkCount = max(1, (data.count + chunkSize - 1) / chunkSize)
        var uploadID: String?

        for index in 0..<chunkCount {
            try Task.checkCancellation()
            let start = index * chunkSize
            let end = min(start + chunkSize, data.count)
            let body = RemoteAttachmentUploadRequestDTO(
                uploadID: uploadID,
                name: name,
                mediaType: mediaType,
                totalBytes: data.count,
                chunkIndex: index,
                chunkCount: chunkCount,
                chunk: data[start..<end].base64EncodedString()
            )
            // Each chunk carries its own request id: they are distinct mutations, and sharing one
            // would make the Mac's replay cache treat chunk two as a retry of chunk one.
            let result: RemoteAttachmentUploadResponseDTO = try await postResponse(
                body,
                to: url,
                requestID: UUID().uuidString
            )
            uploadID = result.uploadID
            onProgress?(Double(result.receivedBytes) / Double(data.count))
            if result.isComplete { return result.uploadID }
        }

        // Every chunk was accepted and the Mac still does not consider the file whole. Nothing
        // usable came of it, so this is a failure rather than an id the composer would name.
        throw RemoteClientError.invalidResponse
    }

    func workspace(sessionID: String) async throws -> RemoteWorkspaceDTO {
        try await get(
            RemoteWorkspaceDTO.self,
            from: link.workspaceURL(sessionID: sessionID)
        )
    }

    func browserPreviewData(sessionID: String, tabID: String) async throws -> Data {
        guard let url = link.browserPreviewURL(sessionID: sessionID, tabID: tabID) else {
            throw RemoteClientError.invalidResponse
        }
        let (data, response) = try await Self.session.data(for: request(url: url))
        _ = try validate(data: data, response: response, accepted: 200...299)
        return data
    }

    func extensionPanel(
        sessionID: String,
        extensionIdentifier: String,
        panelID: String
    ) async throws -> RemoteExtensionPanelDTO {
        guard let url = link.extensionPanelURL(
            sessionID: sessionID,
            extensionIdentifier: extensionIdentifier,
            panelID: panelID
        ) else {
            throw RemoteClientError.invalidResponse
        }
        return try await get(RemoteExtensionPanelDTO.self, from: url)
    }

    func invokeExtensionPanelAction(
        sessionID: String,
        extensionIdentifier: String,
        panelID: String,
        processGeneration: String,
        actionID: String,
        value: ExtensionJSONValue? = nil,
        requestID: String = UUID().uuidString.lowercased()
    ) async throws -> RemoteExtensionPanelActionResponseDTO {
        guard let url = link.extensionPanelURL(
            sessionID: sessionID,
            extensionIdentifier: extensionIdentifier,
            panelID: panelID
        ) else {
            throw RemoteClientError.invalidResponse
        }
        return try await postResponse(
            RemoteExtensionPanelActionRequestDTO(
                processGeneration: processGeneration,
                actionID: actionID,
                value: value
            ),
            to: url,
            requestID: requestID
        )
    }

    func extensionPanelResourceData(
        sessionID: String,
        extensionIdentifier: String,
        panelID: String,
        path: String
    ) async throws -> Data {
        guard let url = link.extensionPanelResourceURL(
            sessionID: sessionID,
            extensionIdentifier: extensionIdentifier,
            panelID: panelID,
            path: path
        ) else {
            throw RemoteClientError.invalidResponse
        }
        let (data, response) = try await Self.session.data(for: request(url: url))
        _ = try validate(data: data, response: response, accepted: 200...299)
        return data
    }

    func webSocketTask(sessionID: String) throws -> URLSessionWebSocketTask {
        guard let url = link.webSocketURL(sessionID: sessionID) else {
            throw RemoteClientError.invalidResponse
        }
        return Self.socketSession.webSocketTask(with: url)
    }

    func eventsWebSocketTask() throws -> URLSessionWebSocketTask {
        guard let url = link.eventsWebSocketURL else {
            throw RemoteClientError.invalidResponse
        }
        return Self.socketSession.webSocketTask(with: url)
    }

    /// True when a socket opened by this client cannot wait for connectivity.
    ///
    /// Asserted rather than assumed: the whole failure this fixes was a socket silently
    /// inheriting the request session's `waitsForConnectivity`.
    static var socketWaitsForConnectivity: Bool {
        socketSession.configuration.waitsForConnectivity
    }

    /// The delegate each session actually installed, so a test can prove they are the same
    /// object rather than two that happen to be configured alike.
    static var requestSessionDelegate: URLSessionDelegate? { session.delegate }
    static var socketSessionDelegate: URLSessionDelegate? { socketSession.delegate }

    private func request(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(link.token)", forHTTPHeaderField: "Authorization")
        request.setValue(String(RemoteProtocol.current), forHTTPHeaderField: "X-Threading-Protocol")
        request.setValue(
            String(RemoteProtocol.minimumSupported),
            forHTTPHeaderField: "X-Threading-Protocol-Min"
        )
        request.setValue("Threading-iOS", forHTTPHeaderField: "X-Threading-Client")
        request.setValue(RemoteDeviceIdentity.current, forHTTPHeaderField: "X-Threading-Device")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        if let requestTimeout { request.timeoutInterval = requestTimeout }
        return request
    }

    private func post<Body: Encodable>(
        _ body: Body,
        to url: URL,
        requestID: String
    ) async throws -> RemoteMeDTO {
        try await postResponse(body, to: url, requestID: requestID)
    }

    private func get<Response: Decodable>(
        _ responseType: Response.Type,
        from url: URL
    ) async throws -> Response {
        let (data, response) = try await Self.session.data(for: request(url: url))
        _ = try validate(data: data, response: response, accepted: 200...299)
        return try JSONDecoder().decode(responseType, from: data)
    }

    private func postResponse<Body: Encodable, Response: Decodable>(
        _ body: Body,
        to url: URL,
        requestID: String
    ) async throws -> Response {
        var request = request(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(requestID, forHTTPHeaderField: "X-Threading-Request-ID")
        let (data, response) = try await dataReplayingNetworkFailure(for: request)
        _ = try validate(data: data, response: response, accepted: 200...299)
        return try JSONDecoder().decode(Response.self, from: data)
    }

    /// A lost response is ambiguous: the Mac may already have applied the mutation. Retrying
    /// the same immutable request once is safe because the request id is replayed verbatim and
    /// the Mac coalesces or returns the original response for that id.
    private func dataReplayingNetworkFailure(
        for request: URLRequest
    ) async throws -> (Data, URLResponse) {
        do {
            return try await Self.session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code != .cancelled {
            return try await Self.session.data(for: request)
        }
    }

    private func decodeMe(data: Data, response: URLResponse) throws -> RemoteMeDTO {
        _ = try validate(data: data, response: response, accepted: 200...299)
        return try JSONDecoder().decode(RemoteMeDTO.self, from: data)
    }

    @discardableResult
    private func validate(
        data: Data,
        response: URLResponse,
        accepted: ClosedRange<Int>
    ) throws -> HTTPURLResponse {
        guard let response = response as? HTTPURLResponse else {
            throw RemoteClientError.invalidResponse
        }
        if response.statusCode == 401 {
            throw RemoteClientError.unauthorized
        }
        if response.statusCode == 426 {
            // The body names the side that is behind. Without it the refusal is still terminal,
            // and "this app is too old" is the safer of the two guesses to make about a host
            // that could not say.
            let upgrade = try? JSONDecoder().decode(RemoteUpgradeRequiredDTO.self, from: data)
            throw RemoteClientError.upgradeRequired(upgrade?.update ?? .client)
        }
        guard accepted.contains(response.statusCode) else {
            throw RemoteClientError.server(response.statusCode)
        }
        return response
    }
}
