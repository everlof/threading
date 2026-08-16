import Foundation

/// Host-authored facts about how a package reached this installation.
///
/// This is deliberately not a trust grant. Every package keeps the same runtime containment
/// and capability checks. Format 1 recorded a local import and content digest. Format 2 also
/// records an app-catalogue origin and its inspectable source repository; neither is an author
/// trust grant and neither may turn into an "unsandbox this author" flag.
struct ExtensionInstallProvenance: Codable, Equatable, Sendable {
    static let currentFormatVersion = 2

    enum Origin: String, Codable, Sendable {
        case localImport
        case firstPartyCatalog
    }

    let formatVersion: Int
    let origin: Origin
    let sourceName: String
    let repositoryURL: URL?
    let contentDigest: String
    let sdkVersion: String?
    let firstInstalledAt: Date
    let lastUpdatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case origin
        case sourceName
        case repositoryURL
        case contentDigest
        case sdkVersion
        case firstInstalledAt
        case lastUpdatedAt
    }

    init(
        installSource: ExtensionInstallSource = .localImport,
        sourceName: String,
        contentDigest: String,
        sdkVersion: String?,
        firstInstalledAt: Date,
        lastUpdatedAt: Date
    ) {
        formatVersion = Self.currentFormatVersion
        switch installSource {
        case .localImport:
            origin = .localImport
            repositoryURL = nil
        case .firstPartyCatalog(let repositoryURL):
            origin = .firstPartyCatalog
            self.repositoryURL = repositoryURL
        }
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
        repositoryURL = try container.decodeIfPresent(URL.self, forKey: .repositoryURL)
        contentDigest = try container.decode(String.self, forKey: .contentDigest)
        sdkVersion = try container.decodeIfPresent(String.self, forKey: .sdkVersion)
        firstInstalledAt = try container.decode(Date.self, forKey: .firstInstalledAt)
        lastUpdatedAt = try container.decode(Date.self, forKey: .lastUpdatedAt)

        guard formatVersion == 1 || formatVersion == Self.currentFormatVersion else {
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
        switch origin {
        case .localImport:
            guard repositoryURL == nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .repositoryURL,
                    in: container,
                    debugDescription: "A local import must not carry a repository URL"
                )
            }
        case .firstPartyCatalog:
            guard formatVersion >= 2,
                  let repositoryURL,
                  ExtensionInstallSource.isSafeRepositoryURL(repositoryURL) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .repositoryURL,
                    in: container,
                    debugDescription: "First-party provenance needs a safe HTTPS repository URL"
                )
            }
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
            origin == .localImport
                ? L10n.string("Local import · unsigned")
                : L10n.string("From Threading · included copy"),
            L10n.format("SHA-256 %@", String(contentDigest.prefix(12)))
        ]
        if let sdkVersion {
            parts.append(L10n.format("SDK %@", sdkVersion))
        }
        return parts.joined(separator: " · ")
    }
}
