import CryptoKit
import Foundation

/// The emulator's gRPC endpoint accepts ES256 JWTs signed by any key whose public half is in its
/// advertised `grpc.jwks` directory, with each method admitted by the allowlist for the token's
/// issuer. One key per Threading process, never written to disk in private form.
public struct EmulatorTokenSigner: Sendable {
    /// The SDK's default allowlist admits this issuer to exactly the methods named in a token's
    /// `aud`, which is what lets Threading control an emulator it did not start without editing
    /// any SDK file or borrowing another tool's unrestricted grant.
    public static let audienceScopedIssuer = "gradle-utp-emulator-control"
    /// The issuer named in the allowlist Threading passes to emulators it starts itself.
    public static let threadingIssuer = "threading"
    public static let tokenLifetime: TimeInterval = 60 * 60

    private let key: P256.Signing.PrivateKey
    public let keyID: String

    public init(key: P256.Signing.PrivateKey = P256.Signing.PrivateKey()) {
        self.key = key
        let digest = SHA256.hash(data: key.publicKey.x963Representation)
        self.keyID = "threading-" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The public key as a one-key JWK Set, the form the emulator's `JwkKeyLoader` reads from its
    /// `jwks` directory (a bare JWK is refused as "does not contain a valid jwk" and deleted).
    public func publicJWK() -> Data {
        let point = key.publicKey.x963Representation // 0x04 || X || Y
        let jwk: [String: String] = [
            "kty": "EC", "crv": "P-256", "alg": "ES256", "use": "sig", "kid": keyID,
            "x": Base64URL.encode(point[1..<33]), "y": Base64URL.encode(point[33..<65]),
        ]
        return (try? JSONSerialization.data(withJSONObject: ["keys": [jwk]], options: [.sortedKeys])) ?? Data()
    }

    /// A token for `methods`, named in `aud` as their full gRPC paths.
    public func token(issuer: String, methods: [EmulatorControlMethod], now: Date = Date()) throws -> String {
        // No `typ`: the emulator's validator refuses a token that sets one ("token has type
        // header set, but validator not").
        let header: [String: String] = ["alg": "ES256", "kid": keyID]
        let issuedAt = Int(now.timeIntervalSince1970)
        let payload: [String: Any] = [
            "iss": issuer,
            "aud": methods.map(\.path),
            "iat": issuedAt,
            "exp": issuedAt + Int(Self.tokenLifetime),
        ]
        let signingInput = Base64URL.encode(try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]))
            + "." + Base64URL.encode(try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
        let signature = try key.signature(for: Data(signingInput.utf8))
        return signingInput + "." + Base64URL.encode(signature.rawRepresentation)
    }

    /// The allowlist given to an emulator Threading starts: the `threading` issuer may call
    /// exactly the methods this client uses, and nothing is unprotected.
    public static func allowlist(methods: [EmulatorControlMethod] = EmulatorControlMethod.allCases) -> Data {
        let document: [String: Any] = [
            "unprotected": [String](),
            "allowlist": [["iss": threadingIssuer, "allowed": methods.map(\.path), "protected": [String]()]],
        ]
        return (try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys, .prettyPrinted])) ?? Data()
    }
}

public enum Base64URL {
    public static func encode<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ string: String) -> Data? {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }
}

// MARK: - Discovery

/// One running emulator as it advertises itself in
/// `~/Library/Caches/TemporaryItems/avd/running/pid_<pid>.ini`.
public struct RunningEmulatorRecord: Equatable, Sendable {
    public let processID: Int32
    /// The AVD's identifier (`avd.id`), which `emulator -avd` takes and `-list-avds` prints.
    public let avdName: String
    /// What the AVD is called in Android Studio (`avd.name` here is the display name).
    public let displayName: String
    public let consolePort: Int
    public let adbPort: Int?
    public let grpcPort: UInt16?
    /// The directory a client drops its public JWK into, when JWT authentication is on.
    public let jwksDirectory: URL?
    /// The merged key set the emulator currently accepts.
    public let activeJWKFile: URL?
    /// A static bearer token, when the emulator was started with `-grpc-use-token`.
    public let grpcToken: String?
    public let commandLine: String?

    /// `emulator-<console port>`, the serial adb gives the emulator.
    public var adbSerial: String { "emulator-\(consolePort)" }

    public static let maximumFileBytes = 64 * 1024

    public static func parse(_ text: String, processID: Int32) -> RunningEmulatorRecord? {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            values[String(line[..<equals]).trimmingCharacters(in: .whitespaces)] =
                String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
        }
        guard let name = values["avd.id"] ?? values["avd.name"], !name.isEmpty,
              let console = values["port.serial"].flatMap(Int.init) else { return nil }
        return RunningEmulatorRecord(
            processID: processID, avdName: name, displayName: values["avd.name"] ?? name, consolePort: console,
            adbPort: values["port.adb"].flatMap(Int.init),
            grpcPort: values["grpc.port"].flatMap(UInt16.init),
            jwksDirectory: values["grpc.jwks"].map { URL(fileURLWithPath: $0, isDirectory: true) },
            activeJWKFile: values["grpc.jwk_active"].map { URL(fileURLWithPath: $0) },
            grpcToken: values["grpc.token"].flatMap { $0.isEmpty ? nil : $0 },
            commandLine: values["cmdline"]
        )
    }

    /// The standard discovery directory on macOS.
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/TemporaryItems/avd/running", isDirectory: true)
    }

    /// Reads every `pid_*.ini` in `directory`, bounded per file and in count, keeping only records
    /// whose process is alive (a crashed emulator leaves its file behind).
    public static func scan(
        directory: URL = defaultDirectory, maximumRecords: Int = 64,
        isAlive: (Int32) -> Bool = { kill($0, 0) == 0 }
    ) -> [RunningEmulatorRecord] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        var records: [RunningEmulatorRecord] = []
        for name in names.sorted() where name.hasPrefix("pid_") && name.hasSuffix(".ini") {
            guard records.count < maximumRecords,
                  let pid = Int32(name.dropFirst(4).dropLast(4)), isAlive(pid) else { continue }
            let url = directory.appendingPathComponent(name)
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: maximumFileBytes),
                  let record = parse(String(decoding: data, as: UTF8.self), processID: pid) else { continue }
            records.append(record)
        }
        return records
    }
}

/// Whether the emulator's merged key set already lists `keyID`, i.e. the JWK dropped into its
/// `jwks` directory has been picked up.
public enum EmulatorJWKSet {
    public static func contains(keyID: String, in data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return false }
        let keys: [[String: Any]]
        if let set = object as? [String: Any], let list = set["keys"] as? [[String: Any]] {
            keys = list
        } else if let single = object as? [String: Any] {
            keys = [single]
        } else {
            return false
        }
        return keys.contains { $0["kid"] as? String == keyID }
    }
}
