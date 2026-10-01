import AppKit

// MARK: - Theme Sprite

/// One small picture in a variant's sprite library — a paw print, a heart, a sheep — that any
/// of the variant's particle blocks may draw in place of a host shape (`ThemeParticles.sprites`).
///
/// **Pictures, still not code.** The particle vocabulary's rule was that a document names a
/// motion and an artwork the host draws, so a theme could never ship a shader or an unbounded
/// emitter. A sprite keeps every half of that: the host still owns the motion, the budget at
/// each placement, the hold, and the opacity ceiling over text. What it hands over is only the
/// *picture* on one emitter cell, normalised by the asset store to a bounded PNG
/// (`ThemeSpriteLimits.storedPixelSize`), and a cell's cost is its pixel size times the
/// particles alive — which the placement's budget already bounds. So a paw print costs exactly
/// what a snowflake did.
///
/// A library rather than an image per particle block because one sprite is usually wanted in
/// several places at once — the sidebar's drift, the arrival, a moment, the mascot's stream —
/// and a theme that had to upload it four times would store it four times.
public struct ThemeSprite: Codable, Equatable {

    /// How particle blocks refer to it: lowercase letters, digits, `-` and `_`.
    public var name: String
    /// Resolved through `ThemeAssetStore` for custom themes and the extension registry for
    /// contributed ones, like every other theme picture.
    public var asset: String
    /// True draws the picture as a silhouette in each of the block's inks — one paw print, any
    /// colour. False keeps its own colours, and the block's inks are ignored.
    public var tinted: Bool

    public init(name: String, asset: String, tinted: Bool = true) {
        self.name = name
        self.asset = asset
        self.tinted = tinted
    }

    private enum CodingKeys: String, CodingKey {
        case name, asset, tinted
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        asset = try container.decode(String.self, forKey: .asset)
        tinted = try container.decodeIfPresent(Bool.self, forKey: .tinted) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(asset, forKey: .asset)
        try container.encode(tinted, forKey: .tinted)
    }

    /// Whether `name` is a word a particle block can spell and a file name can carry.
    public static func isValidName(_ name: String) -> Bool {
        guard (1...ThemeSpriteLimits.maximumNameLength).contains(name.count) else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "-" || scalar == "_"
        }
    }

    /// The file a custom theme stores this sprite under for a variant.
    public static func fileName(for name: String, variant: AppTheme.VariantKind) -> String {
        "\(variant.rawValue)-sprite-\(name).png"
    }
}

// MARK: - Limits

public enum ThemeSpriteLimits {
    /// Enough for a theme's whole cast — paw, heart, bone, sheep, a Z for sleeping — and few
    /// enough that a library never becomes a picture store.
    public static let maximumSprites = 8
    public static let maximumNameLength = 24
    /// A particle is at most 24 points, and an arrival draws it 1.6× that; 128 pixels covers
    /// both at 2× without upsampling.
    public static let storedPixelSize = 128
    public static let maximumImageBytes = 1024 * 1024
}
