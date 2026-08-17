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

enum RemoteClientError: LocalizedError {
    case invalidResponse
    case unauthorized
    case upgradeRequired(String)
    case server(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return MobileL10n.string("The Mac returned an unreadable response.")
        case .unauthorized:
            return MobileL10n.string(
                "This invitation is expired or already used, or this membership was revoked."
            )
        case .upgradeRequired:
            return MobileL10n.string(
                "This version of Threading can’t connect to this Mac. Update Threading and try again."
            )
        case .server(let status):
            return MobileL10n.string("The Mac returned HTTP %lld.", status)
        }
    }
}

struct RemoteClient {
    let link: RemoteConnectionLink
    let requestTimeout: TimeInterval?

    init(link: RemoteConnectionLink, requestTimeout: TimeInterval? = nil) {
        self.link = link
        self.requestTimeout = requestTimeout
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
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
        return Self.session.webSocketTask(with: url)
    }

    func eventsWebSocketTask() throws -> URLSessionWebSocketTask {
        guard let url = link.eventsWebSocketURL else {
            throw RemoteClientError.invalidResponse
        }
        return Self.session.webSocketTask(with: url)
    }

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
        if response.statusCode == 426,
           let upgrade = try? JSONDecoder().decode(RemoteUpgradeRequiredDTO.self, from: data) {
            throw RemoteClientError.upgradeRequired(upgrade.message)
        }
        guard accepted.contains(response.statusCode) else {
            throw RemoteClientError.server(response.statusCode)
        }
        return response
    }
}
