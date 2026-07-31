import Foundation
import ThreadingRemoteKit

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

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }()

    func fetchMe() async throws -> RemoteMeDTO {
        let (data, response) = try await Self.session.data(for: request(url: link.meURL))
        return try decodeMe(data: data, response: response)
    }

    func acceptInvitation(
        displayName: String
    ) async throws -> RemoteAcceptInvitationResponseDTO {
        try await postResponse(
            RemoteAcceptInvitationRequestDTO(displayName: displayName),
            to: link.invitationAcceptanceURL
        )
    }

    func resume(sessionID: String) async throws {
        var request = request(url: link.resumeURL(sessionID: sessionID))
        request.httpMethod = "POST"
        let (data, response) = try await Self.session.data(for: request)
        _ = try validate(data: data, response: response, accepted: 200...299)
    }

    func setAppTheme(themeID: String) async throws -> RemoteMeDTO {
        try await post(
            RemoteSetAppThemeRequestDTO(themeID: themeID),
            to: link.appThemeURL
        )
    }

    func setSessionTheme(sessionID: String, themeID: String?) async throws -> RemoteMeDTO {
        try await post(
            RemoteSetTerminalThemeRequestDTO(themeID: themeID),
            to: link.sessionThemeURL(sessionID: sessionID)
        )
    }

    func createSession(
        _ creation: RemoteCreateSessionRequestDTO
    ) async throws -> RemoteCreateSessionResponseDTO {
        try await postResponse(creation, to: link.createSessionURL)
    }

    func renameSession(sessionID: String, title: String) async throws -> RemoteMeDTO {
        try await post(
            RemoteRenameSessionRequestDTO(title: title),
            to: link.renameSessionURL(sessionID: sessionID)
        )
    }

    func setSessionPinned(sessionID: String, isPinned: Bool) async throws -> RemoteMeDTO {
        try await post(
            RemoteSetSessionPinnedRequestDTO(isPinned: isPinned),
            to: link.pinnedSessionURL(sessionID: sessionID)
        )
    }

    func setSessionArchived(sessionID: String, isArchived: Bool) async throws -> RemoteMeDTO {
        try await post(
            RemoteSetSessionArchivedRequestDTO(isArchived: isArchived),
            to: link.archivedSessionURL(sessionID: sessionID)
        )
    }

    func setSessionSurface(sessionID: String, surface: String) async throws -> RemoteMeDTO {
        try await post(
            RemoteSetSessionSurfaceRequestDTO(surface: surface),
            to: link.sessionSurfaceURL(sessionID: sessionID)
        )
    }

    func registerNotifications(
        _ registration: RemoteNotificationRegistrationDTO
    ) async throws -> RemoteNotificationRegistrationResponseDTO {
        try await postResponse(registration, to: link.notificationRegistrationURL)
    }

    func uploadDiagnostics(
        _ records: [RemoteDiagnosticRecord]
    ) async throws -> RemoteDiagnosticUploadResponseDTO {
        try await postResponse(
            RemoteDiagnosticUploadRequestDTO(source: .iOSClient, records: records),
            to: link.diagnosticUploadURL
        )
    }

    func createShare(
        sessionID: String,
        capability: String,
        canApprovePermissions: Bool
    ) async throws -> RemoteCreateShareResponseDTO {
        try await postResponse(
            RemoteCreateShareRequestDTO(
                capability: capability,
                canApprovePermissions: canApprovePermissions
            ),
            to: link.sessionShareURL(sessionID: sessionID)
        )
    }

    func revokeShares(sessionID: String) async throws -> RemoteMeDTO {
        try await post(
            RemoteRevokeSharesRequestDTO(),
            to: link.sessionUnshareURL(sessionID: sessionID)
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

    func attachmentData(sessionID: String, path: String) async throws -> Data {
        guard let url = link.attachmentURL(sessionID: sessionID, path: path) else {
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
        return request
    }

    private func post<Body: Encodable>(_ body: Body, to url: URL) async throws -> RemoteMeDTO {
        try await postResponse(body, to: url)
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
        to url: URL
    ) async throws -> Response {
        var request = request(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await Self.session.data(for: request)
        _ = try validate(data: data, response: response, accepted: 200...299)
        return try JSONDecoder().decode(Response.self, from: data)
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
