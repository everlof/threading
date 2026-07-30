import AppKit

/// Every colour decision the app's own chrome makes, named once.
///
/// The app had fourteen semantic tokens in `Design` and **two hundred and twenty** direct
/// `NSColor.secondaryLabelColor`-style calls around them, which is why a theme that only
/// replaced `Design.Surface.*` would have repainted the panels and left every label, status
/// dot, diff wash and syntax hue exactly as it found them. This is that missing vocabulary:
/// the roles a view asks for instead of naming a colour.
///
/// It is deliberately small. A role earns its place by being asked for somewhere the *answer*
/// should differ between themes — not by every distinct colour in the app, which is how a
/// palette becomes a list of two hundred values nobody can author.
enum AppThemeRole: String, CaseIterable, Codable {

    // MARK: Surfaces

    /// The window's own backdrop, behind everything.
    case ground
    /// The sidebar and other large structural areas.
    case surface
    /// A container holding content: a card, the prompt box, a settings group.
    case panel
    /// A container that sits above `panel` — a popover, a menu-like sheet.
    case elevated
    /// A control at rest, below full opacity so a row of them stays quiet.
    case controlResting
    /// The same control under the pointer.
    case controlHover

    // MARK: Lines

    case border
    case divider

    // MARK: Text

    case label
    case secondaryLabel
    case tertiaryLabel
    case quaternaryLabel

    // MARK: Accent

    case accent
    /// The accent dropped well below full, for a fill that must not compete with its own text.
    case accentMuted
    /// The fill behind selected text.
    case selection

    // MARK: Status

    /// A session that is working.
    case statusPositive
    /// A session wanting attention.
    case statusWarning
    /// A failure, an error row, a non-zero exit.
    case statusNegative

    // MARK: Diff

    case diffAdded
    case diffRemoved

    // MARK: Syntax

    case syntaxKeyword
    case syntaxType
    case syntaxString
    case syntaxNumber
    case syntaxComment

    /// What this role resolves to with no theme in play — the system colour the app used
    /// before any of this existed.
    ///
    /// This is the whole reason the design system's "system colours only" rule survives rather
    /// than being abolished: the System theme *is* these answers, so a user who never picks a
    /// style keeps light/dark and their own accent colour working exactly as before.
    var systemColor: NSColor {
        switch self {
        case .ground: return .windowBackgroundColor
        case .surface: return .windowBackgroundColor
        // An ink wash rather than `textBackgroundColor` at 0.4: on both of the modern system
        // grounds — pure white in light, `#1E1E1E` in dark — `textBackgroundColor` *is* the
        // ground, so a panel filled with it at any alpha was the ground again and every card,
        // prompt box and code block under System drew as a border around nothing. A twentieth
        // of the label's ink is the same recipe styled themes derive their control fills from,
        // and it is visibly a surface on both appearances.
        case .panel: return .labelColor.withAlphaComponent(0.05)
        case .elevated: return .controlBackgroundColor
        case .controlResting: return .unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.5)
        case .controlHover: return .unemphasizedSelectedContentBackgroundColor
        case .border: return .separatorColor
        // Resolve, then multiply — `withAlphaComponent` *replaces* alpha, and `separatorColor`
        // is the rare catalog colour that carries its own (white or black at 10%). Replacing
        // gave white at **50%**: a hairline five times louder than the border it is meant to
        // sit under, and in dark mode the one bright line in the window. The provider resolves
        // per appearance, so light and dark each halve their own separator.
        case .divider:
            return NSColor(name: NSColor.Name("threading.system.divider")) { _ in
                guard let separator = NSColor.separatorColor.usingColorSpace(.sRGB) else {
                    return .separatorColor
                }
                return separator.withAlphaComponent(separator.alphaComponent * 0.5)
            }
        case .label: return .labelColor
        case .secondaryLabel: return .secondaryLabelColor
        case .tertiaryLabel: return .tertiaryLabelColor
        case .quaternaryLabel: return .quaternaryLabelColor
        case .accent: return .controlAccentColor
        case .accentMuted: return .controlAccentColor.withAlphaComponent(0.22)
        case .selection: return .selectedTextBackgroundColor
        case .statusPositive: return .systemGreen
        case .statusWarning: return .systemOrange
        case .statusNegative: return .systemRed
        case .diffAdded: return .systemGreen
        case .diffRemoved: return .systemRed
        case .syntaxKeyword: return .systemPurple
        case .syntaxType: return .systemTeal
        case .syntaxString: return .systemOrange
        case .syntaxNumber: return .systemBlue
        case .syntaxComment: return .tertiaryLabelColor
        }
    }

    /// Roles a style has to state for itself. Everything else is derived from these, so a theme
    /// document is a dozen values rather than twenty-five — see `AppTheme.resolved`.
    static let authored: [AppThemeRole] = [
        .ground, .surface, .panel, .border, .label, .accent,
        .statusPositive, .statusWarning, .statusNegative,
        .syntaxKeyword, .syntaxType, .syntaxString, .syntaxNumber
    ]

    /// Snake case is the agent-facing spelling. The stored document keeps the enum's original
    /// raw values for compatibility, while tools accept both forms so hand-authored documents
    /// and model-authored patches meet at the same role.
    var wireName: String {
        rawValue.reduce(into: "") { result, character in
            if character.isUppercase {
                result.append("_")
                result.append(character.lowercased())
            } else {
                result.append(character)
            }
        }
    }

    static func named(_ name: String) -> AppThemeRole? {
        allCases.first {
            $0.rawValue.caseInsensitiveCompare(name) == .orderedSame
                || $0.wireName.caseInsensitiveCompare(name) == .orderedSame
        }
    }
}
