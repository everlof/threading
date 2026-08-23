import SwiftUI
import ThreadingRemoteKit

// MARK: - Mobile Agent Identity

/// Who is talking in a chat, resolved from the raw runtime name the wire sends.
///
/// The phone deliberately keeps its own small table instead of asking the Mac for a name and an
/// image per row: the marks are ours, they ship in this app's asset catalogue, and a row that had
/// to wait for bytes would draw an empty slot on every cold open. `unknown` keeps a readable name
/// for a runtime added to the Mac before this app ships again, rather than dropping the row's
/// identity entirely.
///
/// ## Marks and surface glyphs are different questions
///
/// A **mark** says *who is talking* — Claude's starburst, OpenAI's knot — and belongs to a session
/// row, exactly as it does in the Mac sidebar. A **surface glyph** says *what you are looking at*:
/// `terminal` for a terminal, `bubble.left.and.bubble.right` for a natively rendered conversation.
///
/// Those two were the same glyph here until now, and the reading was wrong in both directions: an
/// agent's own TUI mirrored from the Mac is a *provider* TUI, not a shell, so every chat on the
/// phone showed a terminal and no chat showed its provider. Reserve `terminal` for a terminal a
/// person would call a terminal — a plain shell — and let the mark carry identity.
enum MobileAgentIdentity: Equatable {
    case claude
    case codex
    case grok
    case openCode
    case cursor
    case unknown(String)

    // MARK: - Properties

    /// The runtime's own mark, or the SF Symbol standing in for one we do not bundle.
    ///
    /// Mirrors `AgentKind.icon` on the Mac, including which marks keep their own colour: OpenAI's
    /// knot is monochrome by design and ships as a template so it tints with its context, while
    /// Claude's coral starburst is drawn as authored.
    enum Mark: Equatable {
        /// An image in this app's asset catalogue. `keepsItsOwnColour` is false for a template
        /// mark, which takes the tint of the slot it is drawn in.
        case brand(asset: String, keepsItsOwnColour: Bool)
        case symbol(String)
    }

    var displayName: String {
        switch self {
        case .claude: return MobileL10n.string("Claude Code")
        case .codex: return "Codex"
        case .grok: return "Grok"
        case .openCode: return "OpenCode"
        case .cursor: return "Cursor"
        case .unknown(let kind): return kind.capitalized
        }
    }

    /// The name of this runtime's own interactive TUI, hosted in a mirrored terminal. The Mac
    /// spells it the same way, through the same catalogue key.
    var originalUITitle: String {
        MobileL10n.string("%@ UI", displayName)
    }

    var mark: Mark {
        switch self {
        case .claude:
            return .brand(asset: MobileAgentMarkAssets.claude, keepsItsOwnColour: true)
        case .codex:
            return .brand(asset: MobileAgentMarkAssets.codex, keepsItsOwnColour: false)
        case .grok: return .symbol("bolt.circle")
        case .openCode: return .symbol("curlybraces.square")
        case .cursor: return .symbol("cursorarrow")
        case .unknown: return .symbol("sparkle")
        }
    }

    // MARK: - Public Methods

    /// The identity behind a wire `agentKind`. Unknown names are kept rather than mapped onto a
    /// runtime we happen to know, which is how a Grok session came to be labelled "Codex UI".
    static func resolve(_ agentKind: String) -> Self {
        switch agentKind {
        case "claude": return .claude
        case "codex": return .codex
        case "grok": return .grok
        case "opencode": return .openCode
        case "cursor": return .cursor
        default: return .unknown(agentKind)
        }
    }
}

// MARK: - Mobile Agent Mark Assets

enum MobileAgentMarkAssets {
    static let claude = "AgentIconClaude"
    static let codex = "AgentIconCodex"
}

// MARK: - Mobile Mark Tile

/// The tile every dashboard row leads with: a rounded square in the control's resting colour,
/// holding the one glyph that says what the row is.
///
/// A chat's tile carries its runtime's mark and a terminal's carries the terminal symbol, and
/// they are the same tile — same size, same corner, same ground, same dimming when the thing is
/// not running on the Mac. The terminal row used to draw a circle of its own with an accent-tinted
/// glyph, which put two tile shapes and two ink weights down one list; the Mac sidebar gives both
/// kinds of row one icon slot, and so does this.
struct MobileMarkTile<Glyph: View>: View {
    var isDimmed = false
    @ViewBuilder let glyph: () -> Glyph
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: MobileDesign.Size.rowMarkRadius, style: .continuous)
                .fill(theme.controlResting)
            glyph()
        }
        .frame(width: MobileDesign.Size.rowMark, height: MobileDesign.Size.rowMark)
        .opacity(isDimmed ? MobileDesign.Opacity.dormantMark : 1)
    }
}

// MARK: - Mobile Terminal Mark

/// The tile of a standalone terminal: the `terminal` symbol, drawn the way a symbol mark is drawn
/// for a runtime we have no brand image for, because a plain shell is exactly what that symbol is
/// reserved for (see `MobileAgentIdentity`). The Mac's terminal row leads with the same symbol.
struct MobileTerminalMark: View {
    var isDimmed = false
    @Environment(\.remoteTheme) private var theme

    /// Read by value models as well as views (the by-type heading names its kind with it).
    nonisolated static let symbolName = "terminal"

    var body: some View {
        MobileMarkTile(isDimmed: isDimmed) {
            Image(systemName: Self.symbolName)
                .font(.system(size: MobileDesign.Size.rowMarkGlyph, weight: .medium))
                .foregroundStyle(theme.secondaryLabel)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(MobileL10n.string("Terminal"))
    }
}

// MARK: - Mobile Session Mark

/// The tile that identifies a chat: its runtime's mark, with an alternate account's chip on the
/// bottom-trailing corner.
///
/// Both facts a row must carry are shown at once, at the weights they deserve — the same split the
/// Mac sidebar arrived at after giving the account the whole slot and hiding the agent on every row
/// that was not on the default login. The chip is an overlay rather than a second arranged view, so
/// rows with and without one still align, and it hangs past the tile because flush inside it
/// covered the middle of the mark.
struct MobileSessionMark: View {
    let agentKind: String
    let account: RemoteSessionAccountDTO?
    var isDimmed = false
    @Environment(\.remoteTheme) private var theme

    private var identity: MobileAgentIdentity { .resolve(agentKind) }

    var body: some View {
        MobileMarkTile(isDimmed: isDimmed) {
            mark
        }
        .overlay(alignment: .bottomTrailing) {
            if let account {
                MobileAccountChip(account: account)
                    .offset(
                        x: MobileDesign.Offset.accountChipOverhang,
                        y: MobileDesign.Offset.accountChipOverhang
                    )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Private Properties

    private var mark: some View {
        MobileAgentMarkGlyph(identity: identity)
    }

    private var accessibilityLabel: String {
        guard let account else { return identity.displayName }
        return "\(identity.displayName) · \(account.name)"
    }
}

// MARK: - Mobile Agent Mark Glyph

/// A runtime's mark alone, at the tile's glyph size, in the secondary ink. The row tile draws it
/// on its square; the draft's account control draws it on a disc in the navigation bar. One
/// drawing, so the same runtime looks the same in both places.
struct MobileAgentMarkGlyph: View {
    let identity: MobileAgentIdentity
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        switch identity.mark {
        case .brand(let asset, let keepsItsOwnColour):
            // A template mark takes the slot's tint the way the symbols beside it do, which is what
            // keeps the monochrome knot visible in both a light and a dark theme.
            Image(asset)
                .renderingMode(keepsItsOwnColour ? .original : .template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(
                    width: MobileDesign.Size.rowMarkGlyph,
                    height: MobileDesign.Size.rowMarkGlyph
                )
                .foregroundStyle(theme.secondaryLabel)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: MobileDesign.Size.rowMarkGlyph, weight: .medium))
                .foregroundStyle(theme.secondaryLabel)
        }
    }
}

// MARK: - Mobile Account Disc

/// The account as a bar control: the runtime's mark on the toolbar's disc, ringed by how much
/// of the account's allowance is used.
///
/// The ring is the usage reading the old identity capsule spelled out — "5h 18% · 7d 63%" —
/// reduced to the one fact a glance needs, how close to the limit. The disc is the dashboard's
/// toolbar circle, so the bar keeps one kind of control, and the mark is the one the rows draw,
/// so the runtime looks like itself. The draft's bar wears it to choose an account; the chat's
/// bar wears the same disc, for the same account, as the handle on the session's actions — so
/// starting a chat keeps the control where it was.
struct MobileAccountDisc: View {
    let identity: MobileAgentIdentity
    /// Peak consumed fraction, 0...1; nil draws the mark alone, for a share or a host that does
    /// not report usage.
    let usageFraction: Double?
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        ZStack {
            Circle()
                .fill(theme.controlResting)
            MobileAgentMarkGlyph(identity: identity)
            if let usageFraction {
                let tint = usageTint(for: usageFraction)
                Circle()
                    .stroke(
                        tint.opacity(MobileDesign.Opacity.usageRingTrack),
                        lineWidth: MobileDesign.Size.badgeStroke
                    )
                Circle()
                    .trim(from: 0, to: min(max(usageFraction, 0), 1))
                    .stroke(
                        tint,
                        style: StrokeStyle(
                            lineWidth: MobileDesign.Size.badgeStroke,
                            lineCap: .round
                        )
                    )
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(
            width: MobileDesign.Size.compactControl,
            height: MobileDesign.Size.compactControl
        )
        .contentShape(Circle())
    }

    /// The ring's colour by how close the account is to its limit — the thresholds the draft's
    /// identity capsule used for its usage text.
    private func usageTint(for fraction: Double) -> Color {
        if fraction >= 0.9 { return theme.negative }
        if fraction >= 0.75 { return theme.warning }
        return theme.positive
    }
}

// MARK: - Mobile Account Chip

/// An alternate account's chip: the emoji it was given, else the initial of its login on a disc
/// coloured by the hue the Mac hashed from that address.
///
/// Neither the glyph nor the hue is decided here. Both arrive on the wire already resolved, so this
/// chip and the one in the Mac sidebar cannot drift apart — see `RemoteAccountBridge`.
struct MobileAccountChip: View {
    let account: RemoteSessionAccountDTO
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        ZStack {
            if let hue = account.hue {
                Circle().fill(Color(
                    hue: hue,
                    saturation: MobileDesign.Colour.accountChipSaturation,
                    brightness: MobileDesign.Colour.accountChipBrightness
                ))
            }
            Text(account.glyph)
                .font(.system(
                    size: account.isEmoji
                        ? MobileDesign.Size.accountChipEmoji
                        : MobileDesign.Size.accountChipGlyph,
                    weight: .heavy
                ))
                .foregroundStyle(account.isEmoji ? theme.label : Color.white)
                .minimumScaleFactor(MobileDesign.Colour.accountChipMinimumScale)
                .lineLimit(1)
        }
        .frame(
            width: MobileDesign.Size.accountChip,
            height: MobileDesign.Size.accountChip
        )
        // The ring is the row's own panel, not a neutral: a chip hanging off the mark has to read
        // as a badge on it rather than as a second glyph beside it, under every authored theme.
        .overlay(
            Circle().strokeBorder(theme.panel, lineWidth: MobileDesign.Size.accountChipRing)
        )
        .accessibilityHidden(true)
    }
}
