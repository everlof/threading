import AppKit
import ThreadingRemoteKit

// MARK: - Account Badge

/// The small chip an alternate account rides on the corner of a session row's agent mark:
/// the account's emoji, else its discovered avatar, else the initial of its login email on
/// a colour hashed from that address.
///
/// It exists because the two facts a row must carry — *which agent* and *which account* —
/// were competing for one 16pt slot, and the account kept winning: an alternate account
/// replaced Claude's starburst and OpenAI's knot with a flat `c.circle.fill`, so a sidebar
/// full of alternate accounts showed no agent at all. Splitting them lets the mark stay the
/// row's glyph and the account ride its corner, which is the badge's ordinary meaning on
/// this platform.
///
/// The initial comes from the **email** rather than the alias, because aliases are named
/// after the agent and collide on it — `claude-nhartley` and `claude-ikeller` are both `c`,
/// which identifies nothing — while the address names the person (`D`, `L`). The fill hashes
/// the whole address, so two accounts sharing an initial still differ by colour, exactly as
/// `GeneratedProjectIcon` separates two same-initial projects.
///
/// The default account gets no chip: its agent's own mark already says everything the row
/// knows, and a badge on every row would be chrome rather than a difference.
@MainActor
enum AccountBadge {

    // MARK: - Properties

    /// Drawn chips, keyed by everything that defines one. An avatar landing or an emoji
    /// being chosen changes the key rather than needing the cache flushed.
    private static let cache = NSCache<NSString, NSImage>()
    /// The exact account images already published into a host fact snapshot. Navigator image
    /// prefetch is allowed to read this memory-only projection, never to rediscover accounts or
    /// probe avatar files while a table is scrolling.
    private static let publishedCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 256
        return cache
    }()

    // MARK: - Public Methods

    /// The chip for an account, or nil when the row has nothing extra to say — no account
    /// at all (a shell), or the CLI's default one.
    static func chip(
        for account: AgentAccount?,
        surface: AccountAppearanceSurface = .sidebar,
        store: AccountPreferencesStore = .shared,
        resolved: AccountPresentation? = nil
    ) -> NSImage? {
        guard let account else { return nil }
        let presentation = resolved ?? AccountPresentation.resolve(account, surface: surface, store: store)
        guard presentation.showsBadge(isDefault: account.isDefault, surface: surface) else { return nil }
        let avatar = presentation.imageID.flatMap { AccountImageStore.image($0) }
        let key = [
            account.id.rawValue, surface.rawValue, presentation.glyph,
            String(presentation.isEmoji), presentation.background.hexString,
            presentation.foreground.hexString, presentation.imageID ?? "",
            avatar.map { String(ObjectIdentifier($0).hashValue) } ?? ""
        ].joined(separator: "|") as NSString
        if resolved == nil, let cached = cache.object(forKey: key) {
            cached.accessibilityDescription = presentation.name
            publishedCache.setObject(cached, forKey: account.id.rawValue as NSString)
            return cached
        }
        let image: NSImage
        if let avatar { image = drawAvatar(avatar) }
        else if presentation.isEmoji && AccountAppearance.normalizedHex(presentation.style.backgroundHex) == nil {
            image = drawEmoji(presentation.glyph)
        } else {
            image = chipImage { bounds in
                presentation.background.setFill()
                NSBezierPath(ovalIn: bounds).fill()
                drawCentred(
                    text: presentation.glyph,
                    font: .systemFont(
                        ofSize: presentation.glyph.count > 1
                            ? AccountBadgeDefaults.fontSize / 1.4 : AccountBadgeDefaults.fontSize,
                        weight: .heavy
                    ),
                    colour: presentation.foreground, in: bounds
                )
            }
        }
        image.accessibilityDescription = presentation.name
        if resolved == nil {
            cache.countLimit = 256
            cache.setObject(image, forKey: key)
            publishedCache.setObject(image, forKey: account.id.rawValue as NSString)
        }
        return image
    }

    /// Provider identity and account content share one menu image without competing for a slot.
    static func mark(for account: AgentAccount, surface: AccountAppearanceSurface,
                     store: AccountPreferencesStore = .shared, resolved: AccountPresentation? = nil) -> NSImage? {
        guard let mark = account.provider.icon else { return chip(for: account, surface: surface, store: store, resolved: resolved) }
        guard let chip = chip(for: account, surface: surface, store: store, resolved: resolved) else { return mark }
        return NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            TemplateImageDrawing.draw(mark, in: NSRect(x: 0, y: 4, width: 14, height: 14),
                                      tint: Design.Text.label)
            chip.draw(in: NSRect(x: 9, y: 0, width: 9, height: 9))
            return true
        }
    }

    /// Returns only an image which `chip(for:)` already admitted while building host identity
    /// facts. This method performs no account discovery, file read, avatar lookup, or drawing.
    static func publishedChip(forAccountID accountID: String) -> NSImage? {
        publishedCache.object(forKey: accountID as NSString)
    }

    /// The letter a chip falls back to: the first letter or digit of the account's login
    /// email, else of its display name for an account whose email cannot be read.
    static func initial(for account: AgentAccount) -> String {
        account.presentation(in: .sidebar).glyph
    }

    // MARK: - Private Methods

    static func hue(for account: AgentAccount) -> CGFloat {
        hue(seed: AccountAvatarStore.cachedEmail(for: account)
            ?? AccountEmailProbe.cachedEmail(for: account) ?? account.id.rawValue)
    }

    private static func hue(seed: String) -> CGFloat {
        CGFloat(GeneratedProjectIcon.stableHash(seed) % 360) / 360
    }

    private static func drawEmoji(_ emoji: String) -> NSImage {
        chipImage { bounds in
            drawCentred(
                text: emoji,
                font: .systemFont(ofSize: AccountBadgeDefaults.emojiFontSize),
                colour: nil,
                in: bounds
            )
        }
    }

    private static func drawAvatar(_ avatar: NSImage) -> NSImage {
        chipImage { bounds in
            NSBezierPath(ovalIn: bounds).addClip()
            let scale = max(bounds.width / max(avatar.size.width, 1),
                            bounds.height / max(avatar.size.height, 1))
            let size = NSSize(width: avatar.size.width * scale, height: avatar.size.height * scale)
            avatar.draw(in: NSRect(x: bounds.midX - size.width / 2,
                                  y: bounds.midY - size.height / 2,
                                  width: size.width, height: size.height))
        }
    }

    /// The initial on a filled disc, hued like a generated project tile — like an emoji,
    /// this is content identifying a thing rather than chrome, so it is one of the few
    /// places that does not derive from a system colour.
    ///
    /// It is brighter than the tile ramp, though: a 9pt disc carrying a 7pt letter has far
    /// less area to make its colour read than a 16pt tile, and the letter is what the chip
    /// is *for*.
    private static func drawInitial(_ glyph: String, seed: String) -> NSImage {
        let fill = NSColor(
            hue: hue(seed: seed),
            saturation: AccountBadgeDefaults.saturation,
            brightness: AccountBadgeDefaults.brightness,
            alpha: 1
        )

        return chipImage { bounds in
            fill.setFill()
            NSBezierPath(ovalIn: bounds).fill()

            drawCentred(
                text: glyph,
                font: .systemFont(ofSize: AccountBadgeDefaults.fontSize, weight: .heavy),
                colour: .white,
                in: bounds
            )
        }
    }

    private static func chipImage(_ body: @escaping (NSRect) -> Void) -> NSImage {
        let side = AccountBadgeDefaults.chipSize
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { bounds in
            body(bounds)
            return true
        }
    }

    private static func drawCentred(text: String, font: NSFont, colour: NSColor?, in bounds: NSRect) {
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        attributes[.foregroundColor] = colour

        let measured = NSAttributedString(string: text, attributes: attributes).size()
        if measured.width > bounds.width {
            attributes[.font] = font.withSize(font.pointSize * bounds.width / measured.width)
        }
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        string.draw(
            at: NSPoint(
                x: bounds.midX - size.width / 2,
                y: bounds.midY - size.height / 2
            )
        )
    }
}

// MARK: - Account Badge Defaults

enum AccountBadgeDefaults {
    /// Large enough for one capital letter at Retina scale, small enough to stay a badge on
    /// the 16pt icon slot rather than a second icon competing with the mark.
    static let chipSize: CGFloat = 9
    static let fontSize: CGFloat = 7
    /// An emoji's glyph outgrows its point size, so it is set below the letter's.
    static let emojiFontSize: CGFloat = 8

    /// How far the chip hangs past the mark's corner, into the gap the row already keeps
    /// between the icon slot and the title. Flush inside the slot, the chip covered the
    /// middle of a 13pt mark; hanging it out trades a little of that gap for the mark
    /// staying recognisable underneath.
    static let cornerOverhang: CGFloat = 2

    /// Brighter than `GeneratedIconDefaults`, whose ramp is tuned for a 16pt tile.
    static let saturation: CGFloat = 0.72
    static let brightness: CGFloat = 0.78

    /// For an account with neither a readable email nor an alphanumeric name.
    static let fallbackGlyph = "•"

    static let cacheKeySeparator = "|"
}
