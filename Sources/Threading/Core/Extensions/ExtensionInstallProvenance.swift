import Foundation

/// Host-authored facts about how a package reached this installation.
///
/// This is deliberately not a trust grant. Every package keeps the same runtime containment
/// and capability checks. The first format records a local import and content digest; a future
/// author signature may add identity, but may never turn into an "unsandbox this author" flag.
struct ExtensionInstallProvenance: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1

    enum Origin: String, Codable, Sendable {
        case localImport
    }

    let formatVersion: Int
    let origin: Origin
    let sourceName: String
    let contentDigest: String
    let sdkVersion: String?
    let firstInstalledAt: Date
    let lastUpdatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case origin
        case sourceName
        case contentDigest
        case sdkVersion
        case firstInstalledAt
        case lastUpdatedAt
    }

    init(
        origin: Origin = .localImport,
        sourceName: String,
        contentDigest: String,
        sdkVersion: String?,
        firstInstalledAt: Date,
        lastUpdatedAt: Date
    ) {
        formatVersion = Self.currentFormatVersion
        self.origin = origin
        self.sourceName = sourceName
        self.contentDigest = contentDigest
        self.sdkVersion = sdkVersion
        self.firstInstalledAt = firstInstalledAt
        self.lastUpdatedAt = lastUpdatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        origin = try container.decode(Origin.self, forKey: .origin)
        sourceName = try container.decode(String.self, forKey: .sourceName)
        contentDigest = try container.decode(String.self, forKey: .contentDigest)
        sdkVersion = try container.decodeIfPresent(String.self, forKey: .sdkVersion)
        firstInstalledAt = try container.decode(Date.self, forKey: .firstInstalledAt)
        lastUpdatedAt = try container.decode(Date.self, forKey: .lastUpdatedAt)

        guard formatVersion == Self.currentFormatVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .formatVersion,
                in: container,
                debugDescription: "Unsupported provenance format version \(formatVersion)"
            )
        }
        guard !sourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              NSString(string: sourceName).lastPathComponent == sourceName,
              sourceName != ".",
              sourceName != ".." else {
            throw DecodingError.dataCorruptedError(
                forKey: .sourceName,
                in: container,
                debugDescription: "Provenance source name must be a non-empty file name"
            )
        }
        let digestScalars = contentDigest.unicodeScalars
        guard digestScalars.count == 64,
              digestScalars.allSatisfy({
                  ("0"..."9").contains(Character(String($0)))
                      || ("a"..."f").contains(Character(String($0)))
              }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .contentDigest,
                in: container,
                debugDescription: "Provenance digest must be a lowercase SHA-256 digest"
            )
        }
        if let sdkVersion,
           sdkVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw DecodingError.dataCorruptedError(
                forKey: .sdkVersion,
                in: container,
                debugDescription: "Provenance SDK version must not be blank"
            )
        }
        guard firstInstalledAt.timeIntervalSinceReferenceDate.isFinite,
              lastUpdatedAt.timeIntervalSinceReferenceDate.isFinite,
              firstInstalledAt <= lastUpdatedAt else {
            throw DecodingError.dataCorruptedError(
                forKey: .lastUpdatedAt,
                in: container,
                debugDescription: "Provenance dates are invalid or out of order"
            )
        }
    }

    var presentation: String {
        var parts = [
            L10n.string("Local import · unsigned"),
            L10n.format("SHA-256 %@", String(contentDigest.prefix(12)))
        ]
        if let sdkVersion {
            parts.append(L10n.format("SDK %@", sdkVersion))
        }
        return parts.joined(separator: " · ")
    }
}
