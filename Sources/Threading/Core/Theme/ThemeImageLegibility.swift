import AppKit
import ImageIO

/// Advisory image check: at most thirty 64×64 thumbnails per adaptive theme (a picture and four
/// full-colour sprites in each of three regions per variant), decoded and sampled off the main
/// actor. It measures the least legible tenth, not one exceptional bright pixel.
///
/// The cost is bounded by the sample count, the thumbnail size, the gradient's stops and the
/// opacity search's twenty steps. Linearising a channel is a table read rather than a `pow`, and
/// an opaque label's luminance is computed once: the exact path made about 80 million `pow` calls
/// for a full theme, all on values that need six significant digits. Measured in an optimized
/// build, the worst case fell from 949 to 181 ms (performance.md).
enum ThemeImageLegibility {
    struct RGB: Sendable {
        let r: Double, g: Double, b: Double

        func over(_ ground: RGB, opacity: Double) -> RGB {
            RGB(r: r * opacity + ground.r * (1 - opacity),
                g: g * opacity + ground.g * (1 - opacity),
                b: b * opacity + ground.b * (1 - opacity))
        }

        /// WCAG relative luminance of this sRGB colour.
        var luminance: Double {
            0.2126 * Linearization.linear(r) + 0.7152 * Linearization.linear(g)
                + 0.0722 * Linearization.linear(b)
        }
    }

    /// Where an image is drawn under text, which says which ground it is composited over.
    enum Region: String, Sendable {
        case backdrop = "material.backdrop"
        case sidebar = "sidebar.background"
        /// The new-session composer's welcome, measured with the greeting's ink when it states one.
        case welcome = "welcome.backdrop"
    }

    struct Sample: Sendable {
        let name: String
        let data: Data?
        let url: URL?
        let opacity: Double
        let label: RGB
        let labelAlpha: Double
        let grounds: [RGB]
        /// `AppTheme.VariantKind.rawValue`; a string so the sample stays `Sendable`.
        var variant: String?
        var region: Region = .backdrop
        /// The particle sprite this sample stands for, when it is not the region's picture.
        var sprite: String?
    }

    /// One picture that leaves the label under the contrast floor.
    struct Finding: Sendable, Equatable {
        let name: String
        let variant: String?
        let region: Region
        let sprite: String?
        /// The least legible tenth's label contrast at the stated opacity.
        let ratio: Double
        /// The highest opacity, in 5% steps below the stated one, that clears the floor.
        let suggestedOpacity: Double

        /// The agent-facing line `create_app_theme`/`update_app_theme` append.
        var toolText: String {
            String(format: "%@: labels reach %.1f:1 over the least legible tenth; try opacity ≤ %.2f.",
                   name, ratio, suggestedOpacity)
        }
    }

    private static let thumbnailSize = 64
    private static let contrastFloor = Double(ThemeContrast.minimumRatio)
    private static let maximumSourceBytes = 8 * 1_024 * 1_024
    private static let opacityStep = 0.05
    /// The share of pixels a picture may leave below the floor before it is reported.
    private static let worstFraction = 10

    /// The agent tools' advisory: a paragraph to append, or "" when every picture reads.
    @MainActor
    static func warnings(for theme: AppTheme) async -> String {
        let lines = await findings(for: theme).map(\.toolText)
        return lines.isEmpty ? "" : "\n\nImage legibility warnings:\n" + lines.joined(separator: "\n")
    }

    /// Every finding for `theme`, optionally limited to some variants. The documents and asset
    /// names are read here; files are read, decoded and sampled on a detached worker.
    @MainActor
    static func findings(for theme: AppTheme, kinds: [AppTheme.VariantKind]? = nil) async -> [Finding] {
        let samples = samples(for: theme, kinds: kinds ?? theme.availableVariants)
        guard !samples.isEmpty else { return [] }
        return await Task.detached(priority: .utility) { samples.compactMap(finding) }.value
    }

    @MainActor
    static func samples(for theme: AppTheme, kinds: [AppTheme.VariantKind]) -> [Sample] {
        func rgb(_ color: NSColor) -> RGB {
            let value = color.usingColorSpace(.sRGB) ?? color
            return RGB(r: value.redComponent, g: value.greenComponent, b: value.blueComponent)
        }
        var samples: [Sample] = []
        for kind in kinds {
            guard let variant = theme.variant(kind), let appearance = kind.appearance else { continue }
            let welcomeInk = variant.welcome?.greeting?.style?.ink
            for (region, backdrop, role, ink) in [
                (Region.backdrop, variant.material.backdrop, AppThemeRole.ground, nil),
                (Region.sidebar, variant.sidebar?.background, AppThemeRole.surface, nil),
                (Region.welcome, variant.welcome?.backdrop, AppThemeRole.ground, welcomeInk)
            ] as [(Region, ThemeBackdrop?, AppThemeRole, ThemeInk?)] {
                var assets: [(file: String, opacity: Double, sprite: String?)] = []
                if let image = backdrop?.image, image.opacity > 0 {
                    assets.append((image.asset, image.opacity, nil))
                }
                if let particles = backdrop?.particles {
                    for spriteName in particles.sprites.prefix(ThemeParticleLimits.maximumSprites) {
                        if let sprite = variant.sprites.first(where: { $0.name == spriteName }), !sprite.tinted {
                            assets.append((sprite.asset,
                                min(particles.opacity, ThemeParticleLimits.ambientOpacityCeiling), spriteName))
                        }
                    }
                }
                guard !assets.isEmpty else { continue }
                let ground = rgb(theme.resolved(role, appearance: appearance))
                let grounds = backdrop?.gradient?.stops.map {
                    rgb($0.color).over(ground, opacity: $0.color.alphaComponent)
                } ?? [ground]
                let label = ink?.resolved(in: theme, appearance: appearance)
                    ?? theme.resolved(.label, appearance: appearance)
                for asset in assets {
                    let name = "\(kind.rawValue).\(region.rawValue)" + (asset.sprite.map { ".sprite.\($0)" } ?? "")
                    samples.append(Sample(name: name,
                        data: ExtensionAppearanceRegistry.shared.sidebarAssetData(named: asset.file, forThemeID: theme.id),
                        url: ThemeAssetStore.assetURL(named: asset.file, for: theme.id),
                        opacity: asset.opacity, label: rgb(label), labelAlpha: label.alphaComponent,
                        grounds: grounds.isEmpty ? [ground] : grounds,
                        variant: kind.rawValue, region: region, sprite: asset.sprite))
                }
            }
        }
        return samples
    }

    static func warning(_ sample: Sample) -> String? {
        finding(sample)?.toolText
    }

    static func finding(_ sample: Sample) -> Finding? {
        guard let pixels = thumbnailPixels(sample) else { return nil }
        let ratio = leastLegibleRatio(pixels, sample: sample, opacity: sample.opacity)
        guard ratio < contrastFloor else { return nil }
        // Search downward in bounded 5% steps. Contrast can be non-monotonic for coloured
        // imagery, so a binary search would make a promise the image cannot keep.
        var suggested = max(0, sample.opacity - opacityStep)
        while suggested > 0, leastLegibleRatio(pixels, sample: sample, opacity: suggested) < contrastFloor {
            suggested = max(0, suggested - opacityStep)
        }
        return Finding(name: sample.name, variant: sample.variant, region: sample.region,
            sprite: sample.sprite, ratio: ratio, suggestedOpacity: suggested)
    }

    // MARK: - Private Methods

    /// Straight (unpremultiplied) ink and coverage for every thumbnail pixel, decoded once.
    private struct Pixel { let ink: RGB; let alpha: Double }

    private static func thumbnailPixels(_ sample: Sample) -> [Pixel]? {
        let data: Data
        if let supplied = sample.data {
            data = supplied
        } else if let url = sample.url,
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= maximumSourceBytes,
                  let stored = try? Data(contentsOf: url) {
            data = stored
        } else { return nil }
        guard data.count <= maximumSourceBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: thumbnailSize,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: thumbnailSize, height: thumbnailSize,
                bitsPerComponent: 8, bytesPerRow: thumbnailSize * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let buffer = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: thumbnailSize, height: thumbnailSize))
        let bytes = buffer.assumingMemoryBound(to: UInt8.self)
        return (0..<(thumbnailSize * thumbnailSize)).map { index in
            let alpha = Double(bytes[index * 4 + 3]) / 255
            let divisor = max(alpha * 255, 1)
            return Pixel(ink: RGB(r: Double(bytes[index * 4]) / divisor,
                                  g: Double(bytes[index * 4 + 1]) / divisor,
                                  b: Double(bytes[index * 4 + 2]) / divisor),
                         alpha: alpha)
        }
    }

    private static func leastLegibleRatio(_ pixels: [Pixel], sample: Sample, opacity: Double) -> Double {
        var ratios: [Double] = []
        ratios.reserveCapacity(pixels.count)
        // An opaque label is the same ink over every pixel: weigh it once, not per pixel.
        let opaqueLabel = sample.labelAlpha >= 1 ? sample.label.luminance : nil
        for pixel in pixels {
            var worst = Double.infinity
            for ground in sample.grounds {
                let background = pixel.ink.over(ground, opacity: pixel.alpha * opacity)
                let a = opaqueLabel ?? sample.label.over(background, opacity: sample.labelAlpha).luminance
                let b = background.luminance
                worst = min(worst, (max(a, b) + 0.05) / (min(a, b) + 0.05))
            }
            ratios.append(worst.isFinite ? worst : 1)
        }
        ratios.sort()
        return ratios[ratios.count / worstFraction]
    }

    /// The sRGB transfer function as a table, linearly interpolated: within 1e-6 of the exact
    /// curve everywhere, which is far below what a 3:1 advisory can resolve.
    enum Linearization {
        private static let steps = 4_096
        private static let table: [Double] = (0...steps).map { step in
            exact(Double(step) / Double(steps))
        }

        static func exact(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }

        static func linear(_ value: Double) -> Double {
            let position = min(max(value, 0), 1) * Double(steps)
            let index = Int(position)
            guard index < steps else { return table[steps] }
            let fraction = position - Double(index)
            return table[index] + (table[index + 1] - table[index]) * fraction
        }
    }
}
