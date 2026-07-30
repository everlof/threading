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
