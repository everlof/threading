import AppKit
import ImageIO

// MARK: - Theme Art Advisory

/// What `create_app_theme` and `update_app_theme` tell the authoring agent about its pictures
/// against the grounds they stand on — the reporting half of `ThemeArtSeparation`.
///
/// The agent draws a logo and a mascot as files and never sees them where they land: on the
/// brand band, on the Dock's plate, at the foot of a dark sidebar. The first agent-made theme
/// reviewed copied every light picture into its dark slots, so a dark-outlined character stood
/// on a near-black column and its logo on a brown band in brown, and nothing it was told said
/// so. These lines say so, in the slot's own path, with what the host already did about it:
///
/// - **The brand logo and the Dock tile** are identity art. The host rims them when their edge
///   disappears, and the line says that it did and how to take the choice back.
/// - **Mascot poses** are decorative and stay as drawn; the line asks for art drawn for the
///   ground.
/// - **A Dock logo too small to fill its plate sharply** is named with the size it needs.
///
/// Bounded: at most two logo grounds and five poses per variant, so fourteen pictures for an
/// adaptive theme, each read under `maximumSourceBytes` and decoded as a thumbnail through
/// ImageIO on a detached worker. The main actor resolves colours and paths and nothing else.
enum ThemeArtAdvisory {

    /// One picture against one ground, resolved on the main actor so the worker reads only
    /// files and numbers.
    struct Sample: Sendable {
        enum Role: Sendable, Equatable {
            /// The sidebar's brand slot: on the band, or on the column's top.
            case brandLogo(onBand: Bool)
            /// The theme's logo on the Dock tile's plate, with the pixels it needs.
            case dockLogo(minimumPixels: Int)
            /// One mascot pose at the column's foot.
            case mascot(mood: String)
        }

        /// The slot as the tools spell it, e.g. `dark.sidebar.logo`.
        let path: String
        let role: Role
        let grounds: [ThemeLuminance.RGB]
        let source: ImageSource
        /// The same slot's picture in the other appearance, when there is one.
        let counterpart: ImageSource?
        let counterpartName: String?
    }

    /// Where a picture's bytes are: a custom theme's stored file, or a contributed package's
    /// bytes read at inspection.
    struct ImageSource: Sendable, Equatable {
        let url: URL?
        let data: Data?
    }

    // MARK: - Properties

    /// Larger than any stored picture slot; a file above it is not read.
    static let maximumSourceBytes = 8 * 1_024 * 1_024
    /// The thumbnail the edge is measured on is drawn from a decode no larger than this.
    private static let decodeSide = 256

    // MARK: - Public Methods

    /// The paragraph the tools append, or "" when every picture stands apart.
    @MainActor
    static func warnings(for theme: AppTheme) async -> String {
        let lines = await findings(for: theme)
        return lines.isEmpty ? "" : "\n\nArt warnings:\n" + lines.joined(separator: "\n")
    }

    /// One agent-facing line per picture that does not stand apart, or is too small for the
    /// Dock. Colours and paths are read here; files are read and measured on a worker.
    @MainActor
    static func findings(for theme: AppTheme) async -> [String] {
        let samples = samples(for: theme)
        guard !samples.isEmpty else { return [] }
        return await Task.detached(priority: .utility) { samples.flatMap(lines(for:)) }.value
    }

    @MainActor
    static func samples(for theme: AppTheme) -> [Sample] {
        var samples: [Sample] = []
        for kind in theme.availableVariants {
            guard let variant = theme.variant(kind), let appearance = kind.appearance else { continue }
            let other = AppTheme.VariantKind.allCases.first { $0 != kind }
            let otherVariant = other.flatMap { theme.variant($0) }
            func source(_ asset: String) -> ImageSource {
                ImageSource(
                    url: ThemeAssetStore.assetURL(named: asset, for: theme.id),
                    data: ExtensionAppearanceRegistry.shared.sidebarAssetData(named: asset, forThemeID: theme.id)
                )
            }
            // Resolved inside the appearance, so a role that falls back to a dynamic colour is
            // measured as this appearance draws it.
            var column: [ThemeLuminance.RGB] = []
            var plate = ThemeLuminance.RGB(r: 0, g: 0, b: 0)
            var bandStops: [ThemeLuminance.RGB]?
            appearance.performAsCurrentDrawingAppearance {
                let surface = ThemeArtSeparation.rgb(theme.resolved(.surface, appearance: appearance))
                column = [surface] + (variant.sidebar?.background?.gradient?.stops ?? []).map {
                    ThemeArtSeparation.rgb($0.color).over(surface, opacity: $0.color.alphaComponent)
                }
                plate = ThemeArtSeparation.rgb(theme.resolved(.ground, appearance: appearance))
                bandStops = variant.sidebar?.brand?.band?.gradient.stops.map { ThemeArtSeparation.rgb($0.color) }
            }

            if let brand = variant.sidebar?.brand, case .asset(let logo) = brand.logo {
                var counterpart: ImageSource?
                if let otherBrand = otherVariant?.sidebar?.brand, case .asset(let otherLogo) = otherBrand.logo {
                    counterpart = source(otherLogo)
                }
                samples.append(Sample(
                    path: "\(kind.rawValue).sidebar.logo",
                    role: .brandLogo(onBand: bandStops != nil),
                    grounds: bandStops ?? column,
                    source: source(logo),
                    counterpart: counterpart,
                    counterpartName: other?.rawValue
                ))
                if brand.dockIcon {
                    samples.append(Sample(
                        path: "\(kind.rawValue).sidebar.logo_in_dock",
                        role: .dockLogo(minimumPixels: Int(GeneratedAppIcon.Layout.minimumSharpMarkPixels)),
                        grounds: [plate],
                        source: source(logo),
                        counterpart: counterpart,
                        counterpartName: other?.rawValue
                    ))
                }
            }

            for mood in ThemeMascotMood.allCases {
                guard let pose = variant.sidebar?.mascot?.poses[mood] else { continue }
                samples.append(Sample(
                    path: "\(kind.rawValue).sidebar.mascot.poses.\(mood.rawValue)",
                    role: .mascot(mood: mood.rawValue),
                    grounds: column,
                    source: source(pose.asset),
                    counterpart: otherVariant?.sidebar?.mascot?.poses[mood].map { source($0.asset) },
                    counterpartName: other?.rawValue
                ))
            }
        }
        return samples
    }

    /// The lines one sample earns: none when its picture stands apart (and, on the Dock, is
    /// large enough), otherwise what is wrong and what the host did about it.
    static func lines(for sample: Sample) -> [String] {
        guard let data = bytes(sample.source),
              let image = decode(data) else { return [] }
        var lines: [String] = []

        if case .dockLogo(let minimumPixels) = sample.role {
            let longer = max(image.pixelWidth, image.pixelHeight)
            if longer < minimumPixels {
                lines.append(
                    "\(sample.path): the logo is \(longer) px, and the Dock tile needs "
                        + "\(minimumPixels) px on its longer side to fill its plate sharply. "
                        + "Supply a 512 × 512 logo."
                )
            }
        }

        guard let measure = ThemeArtSeparation.measure(image.thumbnail, grounds: sample.grounds),
              !measure.separates else { return lines }
        let edge = "only \(measure.percent)% of its edge reaches "
            + "\(Int(ThemeArtSeparation.floor)):1 against "
        let copy = isCopy(of: sample, data: data).map { " It is the same picture as the \($0) appearance's." } ?? ""
        switch sample.role {
        case .brandLogo(let onBand):
            lines.append(
                "\(sample.path): " + edge + (onBand ? "the brand band" : "the sidebar's top")
                    + ", so Threading draws it with a rim in "
                    + (onBand ? "the band's ink" : "the label colour")
                    + ". Draw this appearance's logo for that ground to choose its edge yourself."
                    + copy
            )
        case .dockLogo:
            lines.append(
                "\(sample.path): " + edge + "the Dock tile's plate (the theme's ground), so "
                    + "Threading rims the mark in the label colour to keep the app findable. "
                    + "Draw this appearance's logo for its ground to choose its edge yourself."
                    + copy
            )
        case .mascot:
            lines.append(
                "\(sample.path): " + edge + "the sidebar, so the figure sinks into the column. "
                    + "Draw this appearance's pose for its own ground — a lighter outline or rim "
                    + "on a dark sidebar, a darker one on a pale sidebar."
                    + copy
            )
        }
        return lines
    }

    // MARK: - Private Methods

    private struct Decoded {
        let thumbnail: CGImage
        let pixelWidth: Int
        let pixelHeight: Int
    }

    private static func bytes(_ source: ImageSource) -> Data? {
        if let data = source.data { return data.count <= maximumSourceBytes ? data : nil }
        guard let url = source.url,
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= maximumSourceBytes else { return nil }
        return try? Data(contentsOf: url)
    }

    private static func decode(_ data: Data) -> Decoded? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: decodeSide,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        return Decoded(thumbnail: thumbnail, pixelWidth: width, pixelHeight: height)
    }

    /// The other appearance's name when this slot holds the very bytes that one does — the
    /// usual cause of art that suits one ground and not the other. A package naming one file
    /// for both appearances is the same case, and is reported the same way.
    private static func isCopy(of sample: Sample, data: Data) -> String? {
        guard let counterpart = sample.counterpart,
              let other = bytes(counterpart),
              other == data else { return nil }
        return sample.counterpartName
    }
}
