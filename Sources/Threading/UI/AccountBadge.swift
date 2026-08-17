import AppKit

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
/// after the agent and collide on it — `claude-dblock` and `claude-vlundborg` are both `c`,
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

    // MARK: - Public Methods

    /// The chip for an account, or nil when the row has nothing extra to say — no account
    /// at all (a shell), or the CLI's default one.
    static func chip(for account: AgentAccount?) -> NSImage? {
        guard let account, !account.isDefault else { return nil }

        // Resolved before the key is built, since the chip's content *is* its identity: a
        // chip drawn while an avatar was still being fetched is replaced when it lands.
        let avatar = AccountAvatarStore.avatar(for: account)
        let initial = initial(for: account)
        let key = cacheKey(account: account, hasAvatar: avatar != nil, initial: initial)

        if let cached = cache.object(forKey: key) {
            return cached
        }

        let image = draw(account: account, avatar: avatar, initial: initial)
        image.accessibilityDescription = account.displayName
        cache.setObject(image, forKey: key)
        return image
    }

    /// The letter a chip falls back to: the first letter or digit of the account's login
    /// email, else of its display name for an account whose email cannot be read.
    static func initial(for account: AgentAccount) -> String {
        if let email = AccountAvatarStore.cachedEmail(for: account),
           let letter = email.first(where: { $0.isLetter || $0.isNumber }) {
            return String(letter).uppercased()
        }

        if let letter = account.displayName.first(where: { $0.isLetter || $0.isNumber }) {
            return String(letter).uppercased()
        }

        return AccountBadgeDefaults.fallbackGlyph
    }

    // MARK: - Private Methods

    private static func cacheKey(
        account: AgentAccount,
        hasAvatar: Bool,
        initial: String
    ) -> NSString {
        let parts = [account.id.rawValue, account.emoji ?? "", hasAvatar ? "avatar" : "", initial]
        return parts.joined(separator: AccountBadgeDefaults.cacheKeySeparator) as NSString
    }

    private static func draw(
        account: AgentAccount,
        avatar: NSImage?,
        initial: String
    ) -> NSImage {
        if let emoji = account.emoji {
            return drawEmoji(emoji)
        }
        if let avatar {
            return drawAvatar(avatar)
        }
        return drawInitial(initial, seed: colourSeed(for: account))
    }

    /// What the fill hashes: the login email when there is one, so a person keeps one colour
    /// across the agents they are logged into, else the account's own id.
    private static func colourSeed(for account: AgentAccount) -> String {
        AccountAvatarStore.cachedEmail(for: account) ?? account.id.rawValue
    }

    /// The disc's hue as a fraction of the wheel.
    ///
    /// Public because a remote client draws this chip too, from `RemoteSessionAccountDTO`, and the
    /// two must agree by construction rather than by two copies of the same hash.
    static func hue(for account: AgentAccount) -> CGFloat {
        hue(seed: colourSeed(for: account))
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
            avatar.draw(in: bounds)
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
