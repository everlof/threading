import Foundation

/// The host-brokered backing for `ExtensionCacheStore`.
///
/// Descriptor transport only, like `ExtensionKeyValueBroker` and for the same reason: the
/// loopback path still grants a directory, so there is no synchronous HTTP client to write and
/// no second way for storage to reach the host.
struct ExtensionCacheBroker {
    static let path = "/v1/storage/cache"

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

    func names() throws -> [String] {
        let body = try send(method: "GET", target: Self.path, body: nil)
        guard let listing = try? JSONDecoder().decode(
            ExtensionCacheListing.self,
            from: body
        ), listing.protocolVersion == ExtensionCacheListing.currentProtocolVersion else {
            throw ExtensionStorageError.unreadable("the host returned an unreadable cache listing")
        }
        return listing.names
    }

    func data(forName name: String) throws -> Data? {
        let body = try send(
            method: "GET",
            target: "\(Self.path)/\(Self.encoded(name))",
            body: nil
        )
        guard let entry = try? JSONDecoder().decode(ExtensionCacheEntry.self, from: body),
              entry.protocolVersion == ExtensionCacheEntry.currentProtocolVersion else {
            throw ExtensionStorageError.unreadable("the host returned an unreadable cache entry")
        }
        return entry.value
    }

    func setData(_ value: Data, forName name: String) throws {
        _ = try send(
            method: "PUT",
            target: "\(Self.path)/\(Self.encoded(name))",
            body: try? JSONEncoder().encode(ExtensionCacheWrite(value: value))
        )
    }

    func removeData(forName name: String) throws {
        _ = try send(
            method: "DELETE",
            target: "\(Self.path)/\(Self.encoded(name))",
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

    private static func storageError(status: Int, body: Data) -> ExtensionStorageError {
        struct Failure: Decodable {
            let error: String
        }
        switch status {
        case 400:
            return .invalidName
        case 403:
            return .unavailable("cache storage")
        case 413:
            return .quotaExceeded(maximumBytes: ExtensionCacheStore.maximumEntryBytes)
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
