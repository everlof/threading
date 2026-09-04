import SwiftUI
import ThreadingRemoteKit
import UIKit

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
    /// The ink for a mark that takes its slot's tint; nil is the secondary ink every slot draws
    /// at rest. The identity picker lifts its chosen tile to `label` this way. A brand mark that
    /// keeps its own colour ignores it, as it ignores every tint.
    var tint: Color? = nil
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
                .foregroundStyle(tint ?? theme.secondaryLabel)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: MobileDesign.Size.rowMarkGlyph, weight: .medium))
                .foregroundStyle(tint ?? theme.secondaryLabel)
        }
    }
}

// MARK: - Mobile Account Usage Reading

/// What the account disc rings for one login, as a chat on one model is metered.
///
/// The Mac's toolbar pill gauges the *binding* window, the fullest of the account's own and of
/// those scoped to the session's model, and names every window in its text. The phone's disc
/// has no text beside it, so it rings each window instead: the account's own outermost, the
/// longest on the outside, and a model-scoped window innermost, hugging the mark, present only
/// when the chat runs a model that window meters. The account's rings therefore never move when
/// a Fable chat is opened; the model's own ring appears inside them.
///
/// Resolved from the catalogue's per-window list when the host sends one, and from the single
/// binding fraction an older host sends otherwise, so a phone ahead of its Mac draws what that
/// Mac knew how to say.
struct MobileAccountUsageReading: Equatable {

    /// One ring. A nil fraction is a window whose reset has passed, or whose value the Mac did
    /// not know: the track is drawn, the arc is not.
    struct Ring: Equatable, Identifiable {
        let id: String
        let fraction: Double?
    }

    /// Outermost first.
    let rings: [Ring]

    /// The words the rings stand for, in the Mac's reading order, `5h 43% · 7d 73% · 7d Fable
    /// 89%`, for VoiceOver and the draft's identity line. Nil when there is nothing to say. It
    /// names every window the chat is metered by, including one the disc had no room to ring.
    let summary: String?

    /// The first future reset among the same windows `rings` and `summary` describe.
    ///
    /// Kept on the resolved reading so a presentation cannot accidentally choose from the
    /// account's unfiltered wire list and promote a scoped limit for another model.
    let nextReset: Date?

    init(rings: [Ring], summary: String?, nextReset: Date? = nil) {
        self.rings = rings
        self.summary = summary
        self.nextReset = nextReset
    }

    /// The rings for `account` as a chat on `model` is metered. A nil model means the account's
    /// default, the fallback the Mac's own pill makes, because that is what the next turn spends.
    static func resolve(
        account: RemoteAccountChoiceDTO?,
        model: String?,
        now: Date = Date()
    ) -> MobileAccountUsageReading? {
        guard let account else { return nil }
        guard let windows = account.usageWindows else {
            return MobileAccountUsageReading(
                rings: account.usageFraction.map {
                    [Ring(id: MobileUsageDefaults.bindingRingID, fraction: $0)]
                } ?? [],
                summary: account.usageSummary,
                nextReset: nil
            )
        }

        let metered = model ?? account.defaultModelID
        let chosen = windows.filter { window in
            guard let meters = window.metersModelIDs else { return true }
            guard let metered else { return false }
            return meters.contains(metered)
        }
        let accountWide = chosen
            .filter { $0.metersModelIDs == nil }
            .sorted { ($0.windowDuration ?? -1) > ($1.windowDuration ?? -1) }
        let scoped = chosen.filter { $0.metersModelIDs != nil }
        let rings = (accountWide + scoped)
            .prefix(MobileUsageDefaults.ringCapacity)
            .map { Ring(id: $0.id, fraction: liveFraction($0, now: now)) }
        let summary = chosen
            .map { "\($0.name) \(value($0, now: now))" }
            .joined(separator: MobileUsageDefaults.segmentSeparator)
        let nextReset = chosen
            .compactMap(\.resetsAt)
            .map(Date.init(timeIntervalSince1970:))
            .filter { $0 > now }
            .min()
        return MobileAccountUsageReading(
            rings: Array(rings),
            summary: summary.isEmpty ? nil : summary,
            nextReset: nextReset
        )
    }

    /// The Mac's own rule, `AccountUsage.Window.isExpired`: past the reset, the fraction is a
    /// leftover from the window before, and the phone may hold a catalogue for hours.
    private static func liveFraction(_ window: RemoteAccountUsageWindowDTO, now: Date) -> Double? {
        if let resetsAt = window.resetsAt, resetsAt <= now.timeIntervalSince1970 { return nil }
        return window.fraction
    }

    private static func value(_ window: RemoteAccountUsageWindowDTO, now: Date) -> String {
        guard let fraction = liveFraction(window, now: now) else {
            return MobileUsageDefaults.unknownValue
        }
        return "\(Int((fraction * 100).rounded()))%"
    }
}

/// The disc's vocabulary, matching the Mac's `UsageDefaults` so a reading is one text on both.
enum MobileUsageDefaults {
    /// How many rings fit around the mark at the disc's stroke and gap; a fourth would touch it.
    static let ringCapacity = 3
    /// The one ring an older host's single fraction draws.
    static let bindingRingID = "binding"
    static let segmentSeparator = " · "
    static let unknownValue = "—"
    /// Quiet until three quarters, alarming only when the window is nearly spent — the Mac's
    /// `UsageDefaults` thresholds, so one reading is one colour on both.
    static let warningFraction = 0.75
    static let criticalFraction = 0.9
}

/// How close a window is to its limit, as a colour rather than a number.
///
/// Named once because two drawings now answer it: the toolbar disc's rings and the chat menu's
/// gauge are the same reading at two sizes, and a threshold written twice is a threshold that
/// drifts.
enum MobileUsageSeverity {
    case normal
    case warning
    case critical

    static func from(fraction: Double?) -> MobileUsageSeverity {
        switch fraction ?? 0 {
        case ..<MobileUsageDefaults.warningFraction: return .normal
        case ..<MobileUsageDefaults.criticalFraction: return .warning
        default: return .critical
        }
    }
}

// MARK: - Mobile Account Disc

/// Device-local presentation of the alternate-login badge on a session's usage/action disc.
///
/// Account identity remains present in the menu and its accessibility content. This preference
/// controls only the small visual badge layered over the navigation-bar item, where an initial or
/// custom emoji competes with the provider mark and usage rings. It is deliberately opt-in.
enum MobileSessionAccountBadgePreference {
    static let key = "threading.mobile.session-actions.show-account-badge"
    static let defaultValue = false

    static func presentedAccount(
        _ account: RemoteSessionAccountDTO?,
        isEnabled: Bool
    ) -> RemoteSessionAccountDTO? {
        isEnabled ? account : nil
    }
}

/// The account as a bar control: the runtime's mark on the toolbar's disc, ringed by how much
/// of the account's allowance is used.
///
/// The rings are the usage reading the old identity capsule spelled out — "5h 18% · 7d 63%" —
/// each window drawn as how close to its limit it is, the week outside the five hours, and a
/// model's own window inside both when the chat runs that model (`MobileAccountUsageReading`).
/// The disc is the dashboard's toolbar circle, so the bar keeps one kind of control, and the
/// mark is the one the rows draw, so the runtime looks like itself. The draft's bar wears it to
/// choose an account; the chat's bar wears the same disc, for the same account, as the handle on
/// the session's actions — so starting a chat keeps the control where it was.
struct MobileAccountDisc: View {
    let identity: MobileAgentIdentity
    /// Nil, or a reading with no rings, draws the mark alone: a share, or a host that does not
    /// report usage.
    let reading: MobileAccountUsageReading?
    /// The chip a row would wear, for a chat on a login that is not the CLI's default one.
    ///
    /// Nil is the ordinary case and the Mac decides it, not this view: `RemoteAccountBridge`
    /// sends a session's account only when the chat runs somewhere other than the standard
    /// login, which is exactly when saying *which* login is worth a badge. Passing it here puts
    /// the disc in the bar under the same rule as the mark in a row.
    ///
    /// **Unlike a row's, this chip is drawn inside the disc rather than hanging off it.** A
    /// navigation bar clips its item at the item's own bounds, so the row's three-point overhang
    /// came out as a badge with a flat bottom — 13 points of 15, measured off the screen, and 9
    /// at a wider overhang. Padding the item does not buy the room back; only staying inside the
    /// frame does. `MobileSessionMark` keeps its overhang, because a row clips nothing.
    var account: RemoteSessionAccountDTO?
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        ZStack {
            Circle()
                .fill(theme.controlResting)
            MobileAgentMarkGlyph(identity: identity)
            if let reading {
                MobileAccountUsageRings(reading: reading, theme: theme)
            }
        }
        .frame(
            width: MobileDesign.Size.compactControl,
            height: MobileDesign.Size.compactControl
        )
        .overlay(alignment: .bottomTrailing) {
            if let account {
                MobileAccountChip(account: account)
                    .offset(
                        x: MobileAccountDiscChipOverhang.current,
                        y: MobileAccountDiscChipOverhang.current
                    )
            }
        }
        .contentShape(Circle())
    }
}

/// **Scaffolding.** How far the login chip hangs past the toolbar disc, so both candidates can be
/// photographed from one build. `.rows` is the value a row's tile uses; `.clear` hangs it out far
/// enough to stay off the usage arcs. Delete with the one that is not chosen.
enum MobileAccountDiscChipOverhang {
    static var current: CGFloat {
#if DEBUG
        if let value = ProcessInfo.processInfo.environment["THREADING_MOBILE_DISC_CHIP"],
           let points = Double(value) {
            return CGFloat(points)
        }
        return MobileDesign.Offset.accountChipDiscOverhang
#else
        MobileDesign.Offset.accountChipDiscOverhang
#endif
    }
}

// MARK: - Mobile Account Usage Rings

/// One account's reading as rings, and nothing else: no disc under them and no mark inside them.
///
/// Split out of `MobileAccountDisc` when the chat menu's usage row wanted the same drawing at
/// its own size. The rings are the drawing; where they are drawn — around the toolbar's mark,
/// or into a menu glyph — is the caller's business.
///
/// The theme is passed rather than read from the environment because one of those callers is
/// `ImageRenderer`, which renders outside the view tree and inherits none of it.
struct MobileAccountUsageRings: View {
    let reading: MobileAccountUsageReading
    let theme: RemoteThemePalette

    var body: some View {
        ZStack {
            ringLayers
        }
    }

    @ViewBuilder
    private var ringLayers: some View {
        ForEach(Array(reading.rings.enumerated()), id: \.element.id) { depth, ring in
            let tint = theme.usageTint(for: ring.fraction)
            let inset = CGFloat(depth) * MobileDesign.Size.usageRingPitch
            Circle()
                .stroke(
                    tint.opacity(MobileDesign.Opacity.usageRingTrack),
                    lineWidth: MobileDesign.Size.badgeStroke
                )
                .padding(inset)
            if let fraction = ring.fraction {
                Circle()
                    .trim(from: 0, to: min(max(fraction, 0), 1))
                    .stroke(
                        tint,
                        style: StrokeStyle(
                            lineWidth: MobileDesign.Size.badgeStroke,
                            lineCap: .round
                        )
                    )
                    .padding(inset)
                    .rotationEffect(.degrees(-90))
            }
        }
    }
}

// MARK: - Mobile Account Usage Gauge

/// The rings as a picture, for the one place that cannot hold a view: a menu row.
///
/// `UIMenu` builds its own rows out of a title, a subtitle and an image, so a chat menu's usage
/// row spells its exact reading and reset out while the gauge makes the same percentages
/// glanceable. The image may be any picture at all, so this renders the reading the disc that
/// opened the menu is already ringed by and hands that same drawing over at glyph size.
///
/// Rendered rather than drawn again in Core Graphics: `MobileAccountUsageRings` is the one
/// definition of what a reading looks like, and a second one would drift from it.
enum MobileAccountUsageGauge {

    /// What the last picture was drawn from. A `Menu`'s content is built with the body that
    /// holds it, not when it is opened, so a chat streaming output rebuilds this row many times
    /// a second while nothing about the reading has changed. One entry is the whole cache: a
    /// screen has one login, and a reading that moves has replaced the one before it.
    private struct Drawn: Equatable {
        let reading: MobileAccountUsageReading
        let theme: RemoteThemePalette
        let scale: CGFloat
    }

    @MainActor private static var lastDrawn: Drawn?
    @MainActor private static var lastImage: UIImage?

    /// Nil when there is nothing to draw — a reading with no rings, which is a host that reports
    /// usage in words only. The caller keeps the words in that case.
    @MainActor
    static func image(
        for reading: MobileAccountUsageReading,
        theme: RemoteThemePalette,
        scale: CGFloat
    ) -> UIImage? {
        guard !reading.rings.isEmpty else { return nil }
        let drawn = Drawn(reading: reading, theme: theme, scale: scale)
        if drawn == lastDrawn, let lastImage { return lastImage }
        let side = MobileDesign.Size.usageMenuGauge
        let renderer = ImageRenderer(
            content: MobileAccountUsageRings(reading: reading, theme: theme)
                .frame(width: side, height: side)
                .padding(MobileDesign.Size.usageMenuGaugeInset)
        )
        renderer.scale = max(scale, 1)
        // The severity tints are the point of the drawing; a menu would otherwise paint the
        // whole glyph in its own tint colour and every reading would look alike.
        let image = renderer.uiImage?.withRenderingMode(.alwaysOriginal)
        lastDrawn = image == nil ? nil : drawn
        lastImage = image
        return image
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
