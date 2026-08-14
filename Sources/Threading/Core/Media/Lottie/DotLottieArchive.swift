import Foundation

/// A `.lottie` container: a ZIP holding a manifest, one or more animations, and their images.
///
/// The container is where the format's second hazard lives. A bare Lottie may reference an image
/// by relative path and Threading drops it; a `.lottie` may reference one too, and here it is
/// **resolvable** — but only to an entry inside this same already-validated archive. Never beside
/// the archive, never elsewhere on disk, and never through a path that leaves the archive.
enum DotLottieArchive {

    struct Contents {
        let animation: Data
        /// Images keyed both by their manifest path and by their bare file name, because
        /// bodymovin writes an asset as a directory (`u`) plus a name (`p`) and the container's
        /// manifest is not obliged to agree about the directory.
        let images: [String: Data]
    }

    static let manifestName = "manifest.json"
    static let animationsDirectory = "animations"
    static let imagesDirectory = "images"

    static func read(_ data: Data, limits: MediaDocumentLimits) throws -> Contents {
        guard data.count <= limits.maximumDocumentBytes else {
            throw MediaDocumentFailure.exceedsLimits(L10n.format(
                "The document is larger than the %@ this player accepts.",
                ByteCountFormatter.string(
                    fromByteCount: Int64(limits.maximumDocumentBytes),
                    countStyle: .binary
                )
            ))
        }

        let archive: BoundedZipArchive
        do {
            archive = try BoundedZipArchive(
                data: data,
                limits: BoundedZipArchive.Limits(
                    maximumEntryCount: limits.maximumArchiveEntries,
                    maximumEntryBytes: limits.maximumArchiveEntryBytes,
                    maximumExpandedBytes: limits.maximumArchiveExpandedBytes
                )
            )
        } catch BoundedZipArchive.Failure.tooManyEntries {
            throw MediaDocumentFailure.exceedsLimits(L10n.format(
                "The container holds more than the %lld entries this player accepts.",
                Int64(limits.maximumArchiveEntries)
            ))
        } catch BoundedZipArchive.Failure.expandedArchiveTooLarge {
            throw MediaDocumentFailure.exceedsLimits(
                L10n.string("The container expands to more than this player accepts.")
            )
        } catch {
            throw MediaDocumentFailure.invalidDocument(
                L10n.string("The animation container could not be read.")
            )
        }

        let animationPath = try firstAnimationPath(in: archive)
        guard let animation = (try? archive.data(atPath: animationPath)) ?? nil else {
            throw MediaDocumentFailure.invalidDocument(
                L10n.string("The container holds no animation this player can read.")
            )
        }

        var images: [String: Data] = [:]
        for entry in archive.entries(inDirectory: imagesDirectory) {
            guard let bytes = (try? archive.data(atPath: entry.name)) ?? nil else { continue }
            let normalized = BoundedZipArchive.normalized(entry.name)
            images[normalized] = bytes
            if let name = normalized.split(separator: "/").last {
                images[String(name)] = bytes
                // Bodymovin's own `u` for a container is conventionally `images/`, so the key an
                // asset composes — `images/` plus its file name — resolves without the manifest
                // having to agree about anything.
                images["images/\(name)"] = bytes
            }
        }
        return Contents(animation: animation, images: images)
    }

    /// The manifest's first animation, or the first `animations/*.json` entry when the manifest
    /// is absent or unreadable — a container that plays is better than a refusal over metadata.
    private static func firstAnimationPath(in archive: BoundedZipArchive) throws -> String {
        if let manifestData = (try? archive.data(atPath: manifestName)) ?? nil,
           let manifest = try? JSONSerialization.jsonObject(with: manifestData),
           let root = manifest as? [String: Any],
           let animations = root["animations"] as? [[String: Any]],
           let id = animations.first?["id"] as? String,
           !id.isEmpty {
            let path = "\(animationsDirectory)/\(id).json"
            if archive.entries.contains(where: { BoundedZipArchive.normalized($0.name) == path }) {
                return path
            }
        }
        let candidates = archive.entries(inDirectory: animationsDirectory)
            .map { BoundedZipArchive.normalized($0.name) }
            .filter { $0.hasSuffix(".json") }
            .sorted()
        guard let first = candidates.first else {
            throw MediaDocumentFailure.invalidDocument(
                L10n.string("The container holds no animation this player can read.")
            )
        }
        return first
    }
}
