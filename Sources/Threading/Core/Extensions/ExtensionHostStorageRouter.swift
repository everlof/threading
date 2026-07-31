import Foundation
import ThreadingExtensionKit

/// Executes extension-controlled storage requests away from AppKit's main actor.
///
/// Storage is synchronous at the SDK boundary, but it can enumerate a 100 MiB cache and decode
/// multi-megabyte request bodies. A hostile extension must not be able to turn either operation
/// into a frozen app. One serial queue also preserves the ordering a synchronous extension sees.
final class ExtensionHostStorageRouter: @unchecked Sendable {
    private struct Failure: Encodable {
        let error: String
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(
        label: "codes.threading.extension-host.storage",
        qos: .userInitiated
    )
    private weak var keyValueStore: ExtensionKeyValueStoring?
    private weak var cacheStore: ExtensionCacheStoring?

    func install(
        keyValue: ExtensionKeyValueStoring?,
        cache: ExtensionCacheStoring?
    ) {
        lock.lock()
        keyValueStore = keyValue
        cacheStore = cache
        lock.unlock()
    }

    func routeKeyValue(
        _ request: HTTPRequest,
        path: String,
        extensionIdentifier: String,
        respond: @escaping @Sendable (HTTPResponse) -> Void
    ) {
        lock.lock()
        let store = keyValueStore
        lock.unlock()
        queue.async {
            guard let store else {
                respond(Self.failure(
                    status: 503,
                    reason: "Service Unavailable",
                    "Extension key-value storage is unavailable."
                ))
                return
            }
            respond(Self.handleKeyValue(
                request,
                path: path,
                extensionIdentifier: extensionIdentifier,
                store: store
            ))
        }
    }

    func routeCache(
        _ request: HTTPRequest,
        path: String,
        extensionIdentifier: String,
        maximumRequestBytes: Int,
        respond: @escaping @Sendable (HTTPResponse) -> Void
    ) {
        lock.lock()
        let store = cacheStore
        lock.unlock()
        queue.async {
            guard let store else {
                respond(Self.failure(
                    status: 503,
                    reason: "Service Unavailable",
                    "Extension cache storage is unavailable."
                ))
                return
            }
            respond(Self.handleCache(
                request,
                path: path,
                extensionIdentifier: extensionIdentifier,
                maximumRequestBytes: maximumRequestBytes,
                store: store
            ))
        }
    }

    private static func handleKeyValue(
        _ request: HTTPRequest,
        path: String,
        extensionIdentifier: String,
        store: ExtensionKeyValueStoring
    ) -> HTTPResponse {
        let collection = "/v1/storage/kv"
        let prefix = collection + "/"
        if path == collection {
            guard request.method == "GET" else {
                return .status(405, "Method Not Allowed")
            }
            do {
                return json(ExtensionKeyValueSnapshot(
                    values: try store.keyValues(extensionIdentifier: extensionIdentifier)
                ))
            } catch {
                return keyValueFailure(error)
            }
        }

        let key = decodedIdentifier(in: path, after: prefix)
        guard !key.isEmpty, (try? ExtensionKeyValueStore.validate(key: key)) != nil else {
            return failure(status: 400, reason: "Bad Request", "Invalid storage key.")
        }

        switch request.method {
        case "PUT":
            guard request.header("content-type")?
                .lowercased()
                .hasPrefix("application/json") == true else {
                return failure(
                    status: 415,
                    reason: "Unsupported Media Type",
                    "Expected application/json."
                )
            }
            guard request.body.count <= ExtensionKeyValueStore.maximumStoreBytes else {
                return failure(
                    status: 413,
                    reason: "Payload Too Large",
                    "The value exceeds the key-value store quota."
                )
            }
            do {
                let write = try JSONDecoder().decode(
                    ExtensionKeyValueWrite.self,
                    from: request.body
                )
                guard write.protocolVersion == ExtensionKeyValueWrite.currentProtocolVersion else {
                    return failure(
                        status: 422,
                        reason: "Unprocessable Content",
                        "The key-value protocol version is unsupported."
                    )
                }
                try store.setKeyValue(
                    write.value,
                    extensionIdentifier: extensionIdentifier,
                    key: key
                )
                return .status(204, "No Content")
            } catch is DecodingError {
                return failure(
                    status: 400,
                    reason: "Bad Request",
                    "Invalid key-value request."
                )
            } catch {
                return keyValueFailure(error)
            }

        case "DELETE":
            do {
                try store.removeKeyValue(
                    extensionIdentifier: extensionIdentifier,
                    key: key
                )
                return .status(204, "No Content")
            } catch {
                return keyValueFailure(error)
            }

        default:
            return .status(405, "Method Not Allowed")
        }
    }

    private static func handleCache(
        _ request: HTTPRequest,
        path: String,
        extensionIdentifier: String,
        maximumRequestBytes: Int,
        store: ExtensionCacheStoring
    ) -> HTTPResponse {
        let collection = "/v1/storage/cache"
        let prefix = collection + "/"
        if path == collection {
            guard request.method == "GET" else {
                return .status(405, "Method Not Allowed")
            }
            do {
                return json(ExtensionCacheListing(
                    names: try store.cacheNames(extensionIdentifier: extensionIdentifier)
                ))
            } catch {
                return cacheFailure(error)
            }
        }

        let name = decodedIdentifier(in: path, after: prefix)
        guard !name.isEmpty, (try? ExtensionCacheStore.validate(name: name)) != nil else {
            return failure(status: 400, reason: "Bad Request", "Invalid cache name.")
        }

        switch request.method {
        case "GET":
            do {
                return json(ExtensionCacheEntry(
                    value: try store.cacheData(
                        extensionIdentifier: extensionIdentifier,
                        name: name
                    )
                ))
            } catch {
                return cacheFailure(error)
            }

        case "PUT":
            guard request.header("content-type")?
                .lowercased()
                .hasPrefix("application/json") == true else {
                return failure(
                    status: 415,
                    reason: "Unsupported Media Type",
                    "Expected application/json."
                )
            }
            guard request.body.count <= maximumRequestBytes else {
                return failure(
                    status: 413,
                    reason: "Payload Too Large",
                    "The cache entry exceeds its size limit."
                )
            }
            do {
                let write = try JSONDecoder().decode(
                    ExtensionCacheWrite.self,
                    from: request.body
                )
                guard write.protocolVersion == ExtensionCacheWrite.currentProtocolVersion else {
                    return failure(
                        status: 422,
                        reason: "Unprocessable Content",
                        "The cache protocol version is unsupported."
                    )
                }
                guard write.value.count <= ExtensionCacheStore.maximumEntryBytes else {
                    return failure(
                        status: 413,
                        reason: "Payload Too Large",
                        "The cache entry exceeds its size limit."
                    )
                }
                try store.setCacheData(
                    write.value,
                    extensionIdentifier: extensionIdentifier,
                    name: name
                )
                return .status(204, "No Content")
            } catch is DecodingError {
                return failure(
                    status: 400,
                    reason: "Bad Request",
                    "Invalid cache request."
                )
            } catch {
                return cacheFailure(error)
            }

        case "DELETE":
            do {
                try store.removeCacheData(
                    extensionIdentifier: extensionIdentifier,
                    name: name
                )
                return .status(204, "No Content")
            } catch {
                return cacheFailure(error)
            }

        default:
            return .status(405, "Method Not Allowed")
        }
    }

    private static func decodedIdentifier(in path: String, after prefix: String) -> String {
        let encoded = String(path.dropFirst(prefix.count))
        return encoded.removingPercentEncoding ?? encoded
    }

    private static func keyValueFailure(_ error: Error) -> HTTPResponse {
        switch error as? ExtensionStorageError {
        case .invalidKey:
            return failure(status: 400, reason: "Bad Request", "Invalid storage key.")
        case .tooManyKeys:
            return failure(status: 409, reason: "Conflict", "The key-value store is full.")
        case .quotaExceeded:
            return failure(
                status: 413,
                reason: "Payload Too Large",
                "The key-value store exceeds its quota."
            )
        default:
            ThreadingLogger.extensions.error(
                "Extension key-value operation failed: \(error.localizedDescription, privacy: .public)"
            )
            return failure(
                status: 500,
                reason: "Internal Server Error",
                "The extension key-value store is unavailable."
            )
        }
    }

    private static func cacheFailure(_ error: Error) -> HTTPResponse {
        switch error as? ExtensionStorageError {
        case .invalidName:
            return failure(status: 400, reason: "Bad Request", "Invalid cache name.")
        case .quotaExceeded:
            return failure(status: 413, reason: "Payload Too Large", "The extension cache is full.")
        default:
            ThreadingLogger.extensions.error(
                "Extension cache operation failed: \(error.localizedDescription, privacy: .public)"
            )
            return failure(
                status: 500,
                reason: "Internal Server Error",
                "The extension cache is unavailable."
            )
        }
    }

    private static func json<Value: Encodable>(_ value: Value) -> HTTPResponse {
        do {
            return HTTPResponse(
                status: 200,
                reason: "OK",
                contentType: "application/json",
                body: try JSONEncoder().encode(value)
            )
        } catch {
            return failure(
                status: 500,
                reason: "Internal Server Error",
                "The host response could not be encoded."
            )
        }
    }

    private static func failure(
        status: Int,
        reason: String,
        _ message: String
    ) -> HTTPResponse {
        HTTPResponse(
            status: status,
            reason: reason,
            contentType: "application/json",
            body: (try? JSONEncoder().encode(Failure(error: message))) ?? Data()
        )
    }
}
