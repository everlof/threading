import AppKit

// MARK: - Generated Project Icon

/// The last-resort project mark: the project's initial on a rounded tile whose colour is
/// hashed from its full name.
///
/// Generated rather than fetched, because the alternative last resort was the GitHub
/// *owner's* avatar — and a person's face on every repo they own distinguishes nothing.
/// Two same-initial projects still differ by tile colour, since the hue hashes the whole
/// name.
///
/// Deterministic via a stable hash rather than `hashValue`, which is salted per process
/// and would recolour the sidebar every launch. Never persisted: it exists at draw time
/// only, so a project's icon slot stays genuinely empty and a real mark discovered later
/// simply replaces the tile with nothing to clean up.
///
/// The fill comes from a fixed-saturation HSB ramp rather than a system colour — like an
/// account emoji, it is content identifying a thing, not chrome — at a mid brightness
/// that carries the white initial in both appearances.
@MainActor
enum GeneratedProjectIcon {

    // MARK: - Properties

    private static let cache = NSCache<NSString, NSImage>()

    // MARK: - Public Methods

    static func image(for name: String) -> NSImage {
        if let cached = cache.object(forKey: name as NSString) {
            return cached
        }

        let image = draw(name: name)
        image.accessibilityDescription = name
        cache.setObject(image, forKey: name as NSString)
        return image
    }

    /// djb2 over unicode scalars — stable across launches, which `hashValue` is not.
    static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 5381
        for scalar in text.unicodeScalars {
            hash = hash &* 33 &+ UInt64(scalar.value)
        }
        return hash
    }

    // MARK: - Private Methods

    private static func draw(name: String) -> NSImage {
        let side = ProjectIconDefaults.displayPointSize
        let hue = CGFloat(stableHash(name) % 360) / 360
        let fill = NSColor(
            hue: hue,
            saturation: GeneratedIconDefaults.saturation,
            brightness: GeneratedIconDefaults.brightness,
            alpha: 1
        )

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let initial = String(trimmed.prefix(1)).uppercased()
        let glyph = initial.isEmpty ? GeneratedIconDefaults.fallbackGlyph : initial

        return NSImage(size: NSSize(width: side, height: side), flipped: false) { bounds in
            let tile = NSBezierPath(
                roundedRect: bounds,
                xRadius: ProjectIconDefaults.displayCornerRadius,
                yRadius: ProjectIconDefaults.displayCornerRadius
            )
            fill.setFill()
            tile.fill()

            let text = NSAttributedString(
                string: glyph,
                attributes: [
                    .font: NSFont.systemFont(
                        ofSize: GeneratedIconDefaults.fontSize,
                        weight: .semibold
                    ),
                    .foregroundColor: NSColor.white
                ]
            )
            let size = text.size()
            text.draw(at: NSPoint(
                x: bounds.midX - size.width / 2,
                y: bounds.midY - size.height / 2
            ))
            return true
        }
    }
}

// MARK: - Generated Icon Defaults

enum GeneratedIconDefaults {
    static let saturation: CGFloat = 0.55
    static let brightness: CGFloat = 0.62
    static let fontSize: CGFloat = 9
    /// For the pathological all-whitespace name.
    static let fallbackGlyph = "•"
}
