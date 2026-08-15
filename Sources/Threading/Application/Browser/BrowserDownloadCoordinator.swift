import Foundation

/// Stable identity for one WebKit download without making application state depend on WebKit.
struct BrowserDownloadID: Hashable {
    private let rawValue: ObjectIdentifier

    init(_ object: AnyObject) {
        rawValue = ObjectIdentifier(object)
    }
}

enum BrowserAgentDownloadResult: Equatable {
    case success(URL)
    case failure(String)
}

@MainActor
final class BrowserAgentDownloadRequest {
    private(set) var isAttached = false
    private var result: BrowserAgentDownloadResult?
    private var continuation: CheckedContinuation<BrowserAgentDownloadResult, Never>?

    func attach() {
        guard result == nil else { return }
        isAttached = true
    }

    func wait() async -> BrowserAgentDownloadResult {
        if let result { return result }
        return await withCheckedContinuation { continuation in
            if let result {
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
            }
        }
    }

    func finish(_ result: BrowserAgentDownloadResult) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(returning: result)
        continuation = nil
    }

    func failIfUnattached(_ message: String) {
        guard !isAttached else { return }
        finish(.failure(message))
    }
}

enum BrowserDownloadDestinationDecision: Equatable {
    case approved(URL)
    case cancelled
    case rejected(String)
}

enum BrowserDownloadCompletion: Equatable {
    case completed(URL)
    case missingDestination
}

/// Owns the runtime lifecycle of browser downloads.
///
/// The WebKit delegate remains a UI adapter: it asks for user consent, presents outcomes, and
/// translates `WKDownload` callbacks into this Foundation-only state machine. This coordinator
/// owns which request is awaiting a download, which destination was approved, and the bounded
/// runtime-only history.
@MainActor
final class BrowserDownloadCoordinator {
    static let maximumRecentDownloads = 20
    static let agentStartTimeout: TimeInterval = 5

    private let prepareDestination: (URL) throws -> Void
    private var pendingAgentRequest: BrowserAgentDownloadRequest?
    private var agentRequests: [BrowserDownloadID: BrowserAgentDownloadRequest] = [:]
    private var destinations: [BrowserDownloadID: URL] = [:]
    private(set) var recentDownloads: [URL] = []

    init(
        prepareDestination: @escaping (URL) throws -> Void = { destination in
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
        }
    ) {
        self.prepareDestination = prepareDestination
    }

    func beginAgentRequest() -> BrowserAgentDownloadRequest? {
        guard pendingAgentRequest == nil else { return nil }
        let request = BrowserAgentDownloadRequest()
        pendingAgentRequest = request
        return request
    }

    func endAgentRequest(_ request: BrowserAgentDownloadRequest) {
        guard pendingAgentRequest === request else { return }
        pendingAgentRequest = nil
    }

    func attachPendingAgentRequest(to downloadID: BrowserDownloadID) {
        guard let request = pendingAgentRequest, !request.isAttached else { return }
        request.attach()
        agentRequests[downloadID] = request
    }

    func isAgentRequested(_ downloadID: BrowserDownloadID) -> Bool {
        agentRequests[downloadID] != nil
    }

    func decideDestination(
        _ destination: URL?,
        for downloadID: BrowserDownloadID
    ) -> BrowserDownloadDestinationDecision {
        guard let destination else {
            agentRequests.removeValue(forKey: downloadID)?
                .finish(.failure("The user cancelled the native download save panel."))
            return .cancelled
        }

        do {
            try prepareDestination(destination)
            destinations[downloadID] = destination
            return .approved(destination)
        } catch {
            let message = error.localizedDescription
            agentRequests.removeValue(forKey: downloadID)?
                .finish(.failure(
                    "Could not use the user-approved download destination: " + message
                ))
            return .rejected(message)
        }
    }

    func finish(_ downloadID: BrowserDownloadID) -> BrowserDownloadCompletion {
        guard let destination = destinations.removeValue(forKey: downloadID) else {
            agentRequests.removeValue(forKey: downloadID)?
                .finish(.failure("WebKit completed a download without a destination."))
            return .missingDestination
        }

        agentRequests.removeValue(forKey: downloadID)?.finish(.success(destination))
        recentDownloads.append(destination)
        if recentDownloads.count > Self.maximumRecentDownloads {
            recentDownloads.removeFirst(recentDownloads.count - Self.maximumRecentDownloads)
        }
        return .completed(destination)
    }

    func fail(_ downloadID: BrowserDownloadID, message: String) {
        destinations.removeValue(forKey: downloadID)
        agentRequests.removeValue(forKey: downloadID)?
            .finish(.failure("Download failed: \(message)"))
    }
}
