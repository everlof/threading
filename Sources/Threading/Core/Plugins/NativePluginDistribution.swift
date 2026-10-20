import CryptoKit
import Foundation

/// The signed release catalogue for first-party code bundles. Parsing and hashing run on a
/// bounded worker; neither a network response nor a plugin is trusted before this check.
struct NativePluginDistribution: Sendable {
    struct Plugin: Decodable, Sendable {
        let bundleIdentifier: String
        let bundleName: String
        let codeDirectoryHash: String
        let archiveURL: URL
        let archiveSHA256: String
        let archiveBytes: Int
    }

    struct Host: Decodable, Equatable, Sendable {
        let bundleIdentifier: String
        let bundleVersion: String
        let buildChannel: String
        let executableSHA256: String
        let designKitSHA256: String
        let pluginKitSHA256: String
    }

    private struct Payload: Decodable {
        let schemaVersion: Int
        let host: Host
        let releaseTag: String
        let plugins: [Plugin]
    }

    private struct Envelope: Decodable {
        let payload: Data
        let signature: Data
    }

    enum VerificationError: LocalizedError, Equatable {
        case invalidEnvelope
        case invalidSignature
        case wrongHostBuild
        case invalidPluginEntry

        var errorDescription: String? {
            switch self {
            case .invalidEnvelope:
                return L10n.string("The plugin release manifest could not be read.")
            case .invalidSignature:
                return L10n.string("The plugin release manifest has an invalid signature.")
            case .wrongHostBuild:
                return L10n.string("This plugin release is for a different app build.")
            case .invalidPluginEntry:
                return L10n.string("The plugin release manifest contains an invalid download.")
            }
        }
    }

    let releaseTag: String
    let plugins: [Plugin]
    private static let mainHostCache = HostCache()

    static func manifestURL(for app: URL) -> URL? {
        guard let info = infoDictionary(for: app),
              let version = info["CFBundleVersion"] as? String,
              let tag = releaseTag(for: info) else { return nil }
        return URL(string:
            "https://github.com/everlof/threading/releases/download/\(tag)/native-plugins-\(version).json"
        )
    }

    static func verify(_ data: Data, for app: URL) throws -> Self {
        guard data.count <= 64 * 1024,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.payload.count <= 48 * 1024,
              envelope.signature.count == 64,
              let info = infoDictionary(for: app),
              let encodedKey = info["SUPublicEDKey"] as? String,
              let keyData = Data(base64Encoded: encodedKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        else { throw VerificationError.invalidEnvelope }

        guard key.isValidSignature(envelope.signature, for: envelope.payload) else {
            throw VerificationError.invalidSignature
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: envelope.payload),
              payload.schemaVersion == 1,
              payload.releaseTag == releaseTag(for: info),
              payload.plugins.count <= 32 else {
            throw VerificationError.invalidEnvelope
        }
        guard payload.host == (try? hostIdentity(for: app)) else {
            throw VerificationError.wrongHostBuild
        }

        let archivePrefix =
            "https://github.com/everlof/threading/releases/download/\(payload.releaseTag)/"
        var identifiers = Set<String>()
        for plugin in payload.plugins {
            let name = plugin.bundleName
            guard !plugin.bundleIdentifier.isEmpty,
                  identifiers.insert(plugin.bundleIdentifier).inserted,
                  name.hasSuffix(".bundle"),
                  !name.dropLast(7).isEmpty,
                  name.dropLast(7).allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }),
                  plugin.archiveURL.absoluteString.hasPrefix(archivePrefix),
                  plugin.archiveURL.lastPathComponent ==
                      "\(name.dropLast(7))-\(payload.host.bundleVersion).zip",
                  plugin.archiveURL.scheme == "https",
                  plugin.archiveURL.host == "github.com",
                  plugin.archiveURL.query == nil,
                  plugin.archiveURL.fragment == nil,
                  plugin.archiveBytes > 0,
                  plugin.archiveBytes <= 100 * 1024 * 1024,
                  isCodeDirectoryHash(plugin.codeDirectoryHash),
                  isSHA256(plugin.archiveSHA256) else {
                throw VerificationError.invalidPluginEntry
            }
        }
        return .init(releaseTag: payload.releaseTag, plugins: payload.plugins)
    }

    private static func hostIdentity(for app: URL) throws -> Host {
        if app.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL {
            return try mainHostCache.value { try readHostIdentity(for: app) }
        }
        return try readHostIdentity(for: app)
    }

    private static func readHostIdentity(for app: URL) throws -> Host {
        guard let info = infoDictionary(for: app),
              let bundleIdentifier = info["CFBundleIdentifier"] as? String,
              let bundleVersion = info["CFBundleVersion"] as? String,
              let buildChannel = info["ThreadingBuildChannel"] as? String,
              let executableName = info["CFBundleExecutable"] as? String else {
            throw VerificationError.wrongHostBuild
        }
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let executable = contents.appendingPathComponent("MacOS/\(executableName)")
        let frameworks = contents.appendingPathComponent("Frameworks", isDirectory: true)
        return try Host(
            bundleIdentifier: bundleIdentifier,
            bundleVersion: bundleVersion,
            buildChannel: buildChannel,
            executableSHA256: sha256(executable),
            designKitSHA256: sha256(frameworks.appendingPathComponent(
                "ThreadingDesignKit.framework/Versions/A/ThreadingDesignKit"
            )),
            pluginKitSHA256: sha256(frameworks.appendingPathComponent(
                "ThreadingPluginKit.framework/Versions/A/ThreadingPluginKit"
            ))
        )
    }

    private static func infoDictionary(for app: URL) -> [String: Any]? {
        let info = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: info),
              let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil)
                  as? [String: Any] else { return nil }
        return dictionary
    }

    static func sha256(_ file: URL) throws -> String {
        let stream = try FileHandle(forReadingFrom: file)
        defer { try? stream.close() }
        var digest = SHA256()
        while let chunk = try stream.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            digest.update(data: chunk)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func validReleaseTag(_ tag: String) -> Bool {
        !tag.isEmpty && tag.count <= 64 && tag.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-")
        }
    }

    private static func releaseTag(for info: [String: Any]) -> String? {
        guard let version = info["CFBundleVersion"] as? String,
              !version.isEmpty,
              version.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              let channel = info["ThreadingBuildChannel"] as? String else { return nil }
        let tag: String
        switch channel {
        case "release": tag = "v\(version)"
        case "beta": tag = "beta-v\(version)"
        case "nightly": tag = "nightly"
        default: return nil
        }
        return validReleaseTag(tag) ? tag : nil
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func isCodeDirectoryHash(_ value: String) -> Bool {
        value.utf8.count == 40 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private final class HostCache: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Host?

        func value(_ compute: () throws -> Host) throws -> Host {
            lock.lock()
            defer { lock.unlock() }
            if let stored { return stored }
            let host = try compute()
            stored = host
            return host
        }
    }
}
