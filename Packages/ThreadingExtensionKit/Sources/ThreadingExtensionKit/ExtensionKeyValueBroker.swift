import Foundation

/// The host-brokered backing for `ExtensionKeyValueStore`.
///
/// It exists because the supported runner grants an extension no writable path: App Sandbox
/// cannot express a per-extension writable directory, and the shared grant that would be
/// needed instead is one an extension could walk sideways through. Everything the file backing
/// enforced locally — key shape, key count, total size — is now enforced by the host, which is
/// where the authority belongs; the local checks that remain are there to answer without a
/// round trip, never as the boundary.
///
/// Descriptor transport only. The loopback path keeps the granted directory, so there is no
/// synchronous HTTP client to write and no second way for storage to reach the host.
struct ExtensionKeyValueBroker {
    static let path = "/v1/storage/kv"

    private let transport: ExtensionHostDescriptorTransport
    private let bearerToken: String

    init?(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let connection = try? ExtensionHostConnection(environment: environment),
              let descriptor = connection.descriptor else {
            return nil
        }
        self.transport = ExtensionHostDescriptorTransport.shared(for: descriptor)
        self.bearerToken = connection.bearerToken
    }

    init(transport: ExtensionHostDescriptorTransport, bearerToken: String) {
        self.transport = transport
        self.bearerToken = bearerToken
    }

    func snapshot() throws -> ExtensionKeyValueSnapshot {
        let body = try send(method: "GET", target: Self.path, body: nil)
        do {
            return try JSONDecoder().decode(ExtensionKeyValueSnapshot.self, from: body)
        } catch {
            throw ExtensionStorageError.unreadable(
                "the host returned an unreadable key-value snapshot"
            )
        }
    }

    func write(_ value: ExtensionJSONValue, forKey key: String) throws {
        let write = ExtensionKeyValueWrite(value: value)
        _ = try send(
            method: "PUT",
            target: "\(Self.path)/\(Self.encoded(key))",
            body: try? JSONEncoder().encode(write)
        )
    }

    func remove(forKey key: String) throws {
        _ = try send(
            method: "DELETE",
            target: "\(Self.path)/\(Self.encoded(key))",
            body: nil
        )
    }

    private func send(method: String, target: String, body: Data?) throws -> Data {
        let response: (status: Int, body: Data)
        do {
            response = try transport.sendSynchronously(
                method: method,
                requestTarget: target,
                bearerToken: bearerToken,
                contentType: body == nil ? nil : "application/json",
                body: body
            )
        } catch {
            throw ExtensionStorageError.unreadable(
                (error as? LocalizedError)?.errorDescription
                    ?? "the host connection is unavailable"
            )
        }
        guard (200..<300).contains(response.status) else {
            throw Self.storageError(status: response.status, body: response.body)
        }
        return response.body
    }

    /// Maps the host's status codes back onto the errors the file backing already raises, so a
    /// caller sees one vocabulary regardless of which side enforced the limit.
    private static func storageError(status: Int, body: Data) -> ExtensionStorageError {
        struct Failure: Decodable {
            let error: String
        }
        switch status {
        case 400:
            return .invalidKey
        case 403:
            return .unavailable("persistent key-value storage")
        case 409:
            return .tooManyKeys(maximum: ExtensionKeyValueStore.maximumKeys)
        case 413:
            return .quotaExceeded(maximumBytes: ExtensionKeyValueStore.maximumStoreBytes)
        default:
            let message = (try? JSONDecoder().decode(Failure.self, from: body).error)
                ?? "the host refused the request (\(status))"
            return .unreadable(message)
        }
    }

    private static func encoded(_ value: String) -> String {
        value.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.alphanumerics.union(
                CharacterSet(charactersIn: "-._~")
            )
        ) ?? value
    }
}
