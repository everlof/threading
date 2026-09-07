import AppKit
import ThreadingRemoteKit

/// The one value consumed by account renderers. Facts and full spoken identity remain available
/// even when a compact visual omits its name. Expected 1–8 accounts, stress 256; no views here.
struct AccountPresentation {
    let name: String
    let shortName: String
    let email: String?
    let glyph: String
    let isEmoji: Bool
    let imageID: String?
    let usesAvatar: Bool
    let background: NSColor
    let foreground: NSColor
    let style: AccountAppearance

    @MainActor
    static func showsStandardBadge(provider: AgentKind) -> Bool {
        let store = AccountPreferencesStore.shared
        let defaults = store.defaultAppearance
        let own = store.appearance(for: AccountID(provider: provider, handle: .standard))
        return (defaults.shared ?? AccountAppearance())
            .overlaying(defaults.surfaces?[AccountAppearanceSurface.sidebar.rawValue])
            .overlaying(own.shared)
            .overlaying(own.surfaces?[AccountAppearanceSurface.sidebar.rawValue])
            .showDefaultBadge == true
    }

    var visibleName: String {
        guard style.showName != false else { return "" }
        return style.useShortName == true ? shortName : name
    }

    @MainActor
    static func resolve(
        _ account: AgentAccount,
        surface: AccountAppearanceSurface = .details,
        store: AccountPreferencesStore = .shared,
        draft: AccountAppearancePreferences? = nil,
        defaultsDraft: AccountAppearancePreferences? = nil
    ) -> Self {
        let defaults = defaultsDraft ?? store.defaultAppearance
        let own = draft ?? store.appearance(for: account.id)
        let style = (defaults.shared ?? AccountAppearance())
            .overlaying(defaults.surfaces?[surface.rawValue])
            .overlaying(own.shared)
            .overlaying(own.surfaces?[surface.rawValue]).normalized()
        let name = AccountName.display(for: account)
        let email = AccountAvatarStore.cachedEmail(for: account)
            ?? AccountEmailProbe.cachedEmail(for: account)
        let initial = (email ?? name).first(where: { $0.isLetter || $0.isNumber })
            .map { String($0).uppercased() } ?? AccountBadgeDefaults.fallbackGlyph
        let mode = style.badgeMode ?? "automatic"
        let legacyEmoji = account.emoji
        let isEmoji = mode == "emoji" || (mode == "automatic" && legacyEmoji != nil)
        let glyph: String
        switch mode {
        case "text": glyph = style.badgeText.flatMap { $0.isEmpty ? nil : $0 } ?? initial
        case "emoji": glyph = style.badgeText.flatMap { $0.isEmpty ? nil : $0 } ?? legacyEmoji ?? initial
        default: glyph = mode == "automatic" ? (legacyEmoji ?? initial) : initial
        }
        let hue = CGFloat(GeneratedProjectIcon.stableHash(email ?? account.id.rawValue) % 360) / 360
        let background = style.backgroundHex.flatMap(NSColor.init(hex:))
            ?? NSColor(hue: hue, saturation: AccountBadgeDefaults.saturation,
                       brightness: AccountBadgeDefaults.brightness, alpha: 1)
        let foreground = style.foregroundHex.flatMap(NSColor.init(hex:))
            ?? (background.relativeLuminanceForAccount > 0.179 ? NSColor.black : NSColor.white)
        return Self(
            name: name, shortName: own.shortName ?? name,
            email: style.showEmail == false ? nil : email,
            glyph: glyph, isEmoji: isEmoji,
            imageID: mode == "image" ? style.imageID
                : (mode == "automatic" && legacyEmoji == nil ? AccountImageStore.automaticImageID(for: account) : nil),
            usesAvatar: mode == "automatic" && legacyEmoji == nil,
            background: background, foreground: foreground, style: style
        )
    }

    func showsBadge(isDefault: Bool, surface: AccountAppearanceSurface) -> Bool {
        style.showBadge != false && style.badgeMode != "none"
            && (surface != .sidebar || !isDefault || style.showDefaultBadge == true)
    }

    var hasExplicitBadge: Bool {
        style.badgeMode != nil || style.backgroundHex != nil || style.foregroundHex != nil
            || style.showBadge != nil
    }
}

private extension NSColor {
    var relativeLuminanceForAccount: Double {
        guard let rgb = usingColorSpace(.sRGB) else { return 0 }
        func linear(_ value: CGFloat) -> Double {
            let v = Double(value)
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent)
            + 0.0722 * linear(rgb.blueComponent)
    }
}

extension AgentAccount {
    @MainActor
    func presentation(in surface: AccountAppearanceSurface = .details) -> AccountPresentation {
        AccountPresentation.resolve(self, surface: surface)
    }
}
