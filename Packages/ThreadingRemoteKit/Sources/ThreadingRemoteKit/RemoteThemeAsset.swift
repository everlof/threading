import Foundation

/// A bounded phone rendition. Bytes are fetched separately, never embedded in a theme/archive.
public struct RemoteThemeAsset: Codable, Equatable, Sendable {
    public static let routePrefix = "/api/theme-assets/"
    public static let maximumBytes = 1_024 * 1_024
    public static let maximumThemeBytes = 6 * maximumBytes
    public static let maximumCount = 32
    /// How many wire entries admission examines. Entries this build cannot use (a newer
    /// Mac's slots) are skipped rather than ending the list, so the scan, not just the
    /// result, needs its own bound.
    public static let maximumExaminedCount = 4 * maximumCount
    public static let maximumFontBytes = 16 * maximumBytes
    public static let maximumShaderBytes = 256 * 1_024
    public enum Kind: Equatable, Sendable { case image, font, sound, shader }
    public let slot: String
    public let digest: String
    public let byteCount: Int
    public let mediaType: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// Background compositing and sprite tint, meaningful only for their respective slots.
    public let opacity: Double?
    public let tinted: Bool?
    public let fontFamily: String?

    public init(slot: String, digest: String, byteCount: Int, mediaType: String = "image/png",
                pixelWidth: Int, pixelHeight: Int, opacity: Double? = nil, tinted: Bool? = nil,
                fontFamily: String? = nil) {
        self.slot = slot; self.digest = digest; self.byteCount = byteCount; self.mediaType = mediaType
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        self.opacity = opacity; self.tinted = tinted
        self.fontFamily = fontFamily
    }

    public static func acceptsDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    public var pixelBound: Int? {
        switch slot {
        case "backdrop", "sidebarImage", "welcome": return 1_290
        case "logo": return 512
        case "surface.texture": return 1_024
        case "mascot.idle", "mascot.resting", "mascot.working", "mascot.attention", "mascot.celebrating": return 512
        default:
            if slot.hasPrefix("sprite."), let index = Int(slot.dropFirst(7)), (0..<8).contains(index) { return 128 }
            return nil
        }
    }

    public var kind: Kind? {
        if pixelBound != nil { return .image }
        if slot.hasPrefix("font."), let index = Int(slot.dropFirst(5)), (0..<4).contains(index) { return .font }
        if ["sound.needsAttention", "sound.turnFinished"].contains(slot) { return .sound }
        if slot == "surface.source" { return .shader }
        return nil
    }

    public var requiresOwner: Bool { kind == .font || kind == .shader }

    public var notificationSoundName: String? {
        kind == .sound && isValid ? "threading-theme-\(digest).caf" : nil
    }

    public var isValid: Bool {
        guard Self.acceptsDigest(digest), byteCount > 0,
              opacity.map({ $0.isFinite && (0...1).contains($0) }) != false else { return false }
        switch kind {
        case .image:
            guard let bound = pixelBound else { return false }
            return byteCount <= Self.maximumBytes && mediaType == "image/png"
                && (1...bound).contains(pixelWidth) && (1...bound).contains(pixelHeight)
        case .font:
            guard let fontFamily, !fontFamily.isEmpty, fontFamily.utf8.count <= 256,
                  !fontFamily.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return false }
            return byteCount <= Self.maximumFontBytes && ["font/ttf", "font/otf", "font/collection"].contains(mediaType)
                && pixelWidth == 0 && pixelHeight == 0
        case .sound:
            return byteCount <= Self.maximumBytes && mediaType == "audio/x-caf"
                && pixelWidth == 0 && pixelHeight == 0
        case .shader:
            return byteCount <= Self.maximumShaderBytes && mediaType == "text/x-metal"
                && pixelWidth == 0 && pixelHeight == 0
        case nil: return false
        }
    }

    /// Unknown slots and invalid optional assets are absent decoration, never a bad palette.
    /// An over-long list keeps its first admissible entries rather than losing all of them.
    public static func admitted(_ assets: [Self]?) -> [Self]? {
        guard let assets else { return nil }
        var bytes = 0
        var fontBytes = 0
        var seen = Set<String>()
        var accepted: [Self] = []
        for asset in assets.prefix(maximumExaminedCount) where accepted.count < maximumCount {
            guard asset.isValid, !seen.contains(asset.slot) else { continue }
            if asset.kind == .font {
                guard fontBytes + asset.byteCount <= 4 * maximumFontBytes else { continue }
                fontBytes += asset.byteCount
            } else {
                guard bytes + asset.byteCount <= maximumThemeBytes else { continue }
                bytes += asset.byteCount
            }
            seen.insert(asset.slot)
            accepted.append(asset)
        }
        return accepted.isEmpty ? nil : accepted
    }
}

/// A theme's asset list decoded one entry at a time. An entry that does not decode is
/// skipped; it never takes the rest of the list with it. At most
/// `RemoteThemeAsset.maximumExaminedCount` entries are examined.
struct RemoteThemeAssetList: Decodable {
    let assets: [RemoteThemeAsset]

    private struct Skipped: Decodable {
        init(from decoder: Decoder) throws {}
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var assets: [RemoteThemeAsset] = []
        var examined = 0
        while !container.isAtEnd, examined < RemoteThemeAsset.maximumExaminedCount {
            examined += 1
            if try container.decodeNil() { continue }
            if let asset = try? container.decode(RemoteThemeAsset.self) {
                assets.append(asset)
            } else {
                // A failed decode does not advance the container; consume the entry.
                _ = try container.decode(Skipped.self)
            }
        }
        self.assets = assets
    }
}

extension RemoteConnectionLink {
    public func themeAssetURL(digest: String) -> URL? {
        guard RemoteThemeAsset.acceptsDigest(digest) else { return nil }
        return baseURL.appendingPathComponent(String(RemoteThemeAsset.routePrefix.dropFirst()) + digest)
    }
}
