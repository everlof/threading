import AppKit
import ThreadingRemoteKit

@MainActor
enum MacClipboardWriter {
    static func copy(_ text: String, pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}

/// Clipboard payloads are transient. Normally one request, at most 16 globally, with one
/// 64-KiB value per request and a ten-second receipt deadline. No history or retry queue.
@MainActor
final class SessionClipboardService {
    static let shared = SessionClipboardService()
    private static let maximumRequests = 16

    struct Endpoint {
        let id: ObjectIdentifier
        let deviceID: String
        let participantID: String
        let isCurrent: @MainActor () -> Bool
        let send: @MainActor (RemoteClipboardWrite) -> Void
    }

    private struct Pending {
        let endpointID: ObjectIdentifier
        let sessionID: SessionID
        let completion: @MainActor @Sendable (MCPToolResult) -> Void
        let timeout: Task<Void, Never>
    }

    private var pending: [String: Pending] = [:]
    private let writeMac: @MainActor (String) -> Bool
    private let receiptTimeout: Duration

    init(
        receiptTimeout: Duration = .seconds(10),
        writeMac: @escaping @MainActor (String) -> Bool = { MacClipboardWriter.copy($0) }
    ) {
        self.receiptTimeout = receiptTimeout
        self.writeMac = writeMac
    }

    func copy(
        text: String?, target: String?, sessionID: SessionID,
        participantID: String, endpoints: [Endpoint],
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        guard let text, !text.isEmpty,
              text.utf8.prefix(RemoteClipboardPolicy.maximumTextBytes + 1).count
                <= RemoteClipboardPolicy.maximumTextBytes else {
            completion(.failure("text must contain 1–65536 UTF-8 bytes."))
            return
        }
        let destination = target ?? ""
        guard ["mac", "ios"].contains(destination) else {
            completion(.failure("target is required: mac or ios."))
            return
        }
        if destination == "mac" {
            guard participantID == RemoteCollaborationParticipantDTO.ownerID else {
                completion(.failure("This requester cannot write the Mac owner's clipboard."))
                return
            }
            completion(writeMac(text)
                ? .success("Copied to the Mac clipboard.")
                : .failure("The Mac clipboard write failed."))
            return
        }
        let candidates = endpoints.filter {
            $0.participantID == participantID && $0.isCurrent()
        }
        guard candidates.count == 1, let endpoint = candidates.first else {
            completion(.failure(candidates.isEmpty
                ? "The intended iOS device is unavailable. Open this chat in an updated ThreadingMobile and retry; nothing was copied to the Mac."
                : "More than one iOS connection matches. Keep this chat open only on the intended iPhone or iPad and retry."))
            return
        }
        guard pending.count < Self.maximumRequests,
              !pending.values.contains(where: { $0.endpointID == endpoint.id }) else {
            completion(.failure("A clipboard delivery is already in progress. Retry after it finishes."))
            return
        }
        let requestID = UUID().uuidString
        let timeout = Task { [weak self, receiptTimeout] in
            do { try await Task.sleep(for: receiptTimeout) } catch { return }
            self?.finish(requestID, result: .failure("No iOS clipboard receipt arrived. Copying is unconfirmed; open ThreadingMobile and retry."))
        }
        pending[requestID] = Pending(
            endpointID: endpoint.id, sessionID: sessionID,
            completion: completion, timeout: timeout
        )
        endpoint.send(RemoteClipboardWrite(
            requestID: requestID, text: text,
            expiresAt: Date().timeIntervalSince1970 + RemoteClipboardPolicy.lifetimeSeconds
        ))
    }

    func receive(
        requestID: String, result: RemoteClipboardResult,
        endpointID: ObjectIdentifier, sessionID: SessionID
    ) {
        guard let request = pending[requestID], request.endpointID == endpointID,
              request.sessionID == sessionID else { return }
        let receipt: MCPToolResult
        switch result {
        case .copied: receipt = .success("Copied to the iOS clipboard.")
        case .inactive: receipt = .failure("ThreadingMobile is not active. Open it and retry; nothing was copied.")
        case .expired: receipt = .failure("The clipboard request expired before iOS could copy it. Retry with ThreadingMobile open.")
        case .invalid: receipt = .failure("iOS rejected the clipboard payload.")
        case .failed: receipt = .failure("The iOS clipboard write could not be verified.")
        }
        finish(requestID, result: receipt)
    }

    func disconnect(_ endpointID: ObjectIdentifier) {
        for id in pending.keys.filter({ pending[$0]?.endpointID == endpointID }) {
            finish(id, result: .failure("The iOS connection closed before its clipboard receipt. Copying is unconfirmed."))
        }
    }

    private func finish(_ requestID: String, result: MCPToolResult) {
        guard let request = pending.removeValue(forKey: requestID) else { return }
        request.timeout.cancel()
        request.completion(result)
    }
}
