import ThreadingRemoteKit
import SwiftUI
import UIKit

/// Layout tokens for application-owned mobile chrome.
///
/// Remote themes own palette and material (radii, border weight and glow). Spacing remains a
/// stable iOS layout concern so changing visual theme never unexpectedly crowds a phone-sized
/// surface. Use this scale instead of introducing measurements at individual call sites.
enum MobileDesign {
    enum Spacing {
        static let hairline: CGFloat = 2
        static let tight: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let inset: CGFloat = 16
        static let large: CGFloat = 20
        static let pane: CGFloat = 24

        /// Composer actions need the normal 44-point tap target, but not a second full inset
        /// above and below it. Keeping these two axes explicit prevents a one-line composer from
        /// becoming needlessly tall while preserving the more generous reading inset at its
        /// leading and trailing edges.
        static let composerHorizontal: CGFloat = inset
        static let composerVertical: CGFloat = small
    }

    enum Size {
        static let minimumTapTarget: CGFloat = 44
        /// The icon-only chrome control: the dashboard's toolbar circles and the plus that
        /// starts a chat in a project. One size keeps them reading as the same kind of thing.
        static let compactControl: CGFloat = 34
        static let toggleTrackWidth: CGFloat = 52
        static let toggleTrackHeight: CGFloat = 32
        static let toggleThumb: CGFloat = 26
        static let navigationStatusIndicator: CGFloat = 6
        /// How wide a chat's navigation title asks to be, whatever it says.
        ///
        /// The name morphs character by character, and a morph is built against the geometry it
        /// starts in: the label resolves every character's final slot up front, then animates
        /// each one there. A title sized to its own text cannot hold still through a rename,
        /// because the new name is what changed the size — the morph is laid out in the old
        /// width, SwiftUI commits the new one a pass later, and the re-layout snaps every glyph
        /// to its final slot. On screen the animation stops half way through. Claude renaming a
        /// chat to `✳ <name>` moved this bar's title 27 points and did exactly that.
        ///
        /// A *request*, not a guarantee: a bar hands its title what its button groups leave,
        /// which on a 320-point phone is 176. Stating this as both the ideal and the maximum
        /// takes the name out of the answer while leaving the bar's own width in it, so the
        /// title still holds still — the width it settles on depends on the device, never on
        /// what the chat is called. The UIKit conversation title has stated its width since it
        /// was written, for the same reason; this is that decision, named and shared.
        static let navigationTitleWidth: CGFloat = 280
        static let navigationTitleHeight: CGFloat = minimumTapTarget
        /// The working orb standing in the status dot's place in a chat's navigation title. It
        /// takes the line the dot leaves rather than a place of its own, so the title stays
        /// centred and one mark speaks at a time; sized to the caption line it sits on rather
        /// than to the orb's own 20pt preset, which would push a two-line title past the bar.
        static let navigationWorkingOrb: CGFloat = 16
        static let dialogActionHeight: CGFloat = 52
        static let conversationEstimatedRowHeight: CGFloat = 88
        static let conversationHistoryTrigger: CGFloat = 180
        static let conversationBottomTolerance: CGFloat = 140
        static let permissionDiffMaximumHeight: CGFloat = 220
        static let permissionDiffMinimumHeight: CGFloat = minimumTapTarget * 2
        static let diffMarkerColumnWidth: CGFloat = 18
        static let workspaceActivityDot: CGFloat = 7
        static let badgeStroke: CGFloat = 2
        /// Fixed leading column used by the stacked terminal presence/control/activity rows.
        static let terminalStatusIconColumn: CGFloat = 24

        /// The session row's identity tile, its ink, and the account chip riding its corner.
        ///
        /// Sized against the row's two lines of text rather than against the old 46-point tile: a
        /// dashboard is a list to scan, and the tile was setting a row height no content asked for.
        /// A title line and a caption line come to roughly this, so the tile no longer decides.
        static let rowMark: CGFloat = 30
        static let rowMarkRadius: CGFloat = 9
        static let rowMarkGlyph: CGFloat = 16
        static let accountChip: CGFloat = 15
        static let accountChipGlyph: CGFloat = 9
        /// An emoji's glyph outgrows its point size, so it is set below the letter's.
        static let accountChipEmoji: CGFloat = 10
        static let accountChipRing: CGFloat = 1.5
        static let rowAttentionDot: CGFloat = 8
        /// The working orb at a row's trailing edge, standing where the age would be. Sized to
        /// the caption line it replaces so a working row is no taller than an idle one.
        static let rowWorkingOrb: CGFloat = 16
    }

    enum Offset {
        static let workspaceActivityDot: CGFloat = 3
        /// How far the account chip hangs past the mark's corner. Flush inside the tile it covered
        /// the middle of the mark; hanging it out keeps the mark recognisable underneath.
        static let accountChipOverhang: CGFloat = 3
        /// How far the attention dot hangs past the mark's top-trailing corner so that its
        /// centre sits on the tile's edge — the midpoint of the corner arc, not the corner of the
        /// bounding box, which on a rounded tile floats the dot off the ink.
        static let rowAttentionDotOverhang: CGFloat = Size.rowAttentionDot / 2
            - Size.rowMarkRadius * (1 - 1 / 2.squareRoot())
    }

    /// Identity colour that is content rather than chrome, so it does not come from a theme role.
    ///
    /// A generated account disc has to stay legible under every authored theme, and it means the
    /// same thing under all of them. The values match `AccountBadgeDefaults` on the Mac so one
    /// login looks like one login on both screens.
    enum Colour {
        static let accountChipSaturation: Double = 0.72
        static let accountChipBrightness: Double = 0.78
        static let accountChipMinimumScale: Double = 0.6
    }

    enum Opacity {
        /// Dims a mark whose session has no live surface, standing in for the tertiary tint that
        /// dims the symbols beside it.
        static let dormantMark: Double = 0.55
    }

    enum Typography {
        static let messageLineSpacing: CGFloat = 4
    }

    enum Motion {
        static let controlResponse: Double = 0.18
        /// LabelMorph's showcase timing brought to the pace of application chrome.
        static let nameMorphTempo: Double = 0.65
        /// The whole character cascade is bounded so sentence-length chat names do not settle
        /// more slowly than short ones.
        static let nameMorphCascade: TimeInterval = 0.3
        /// A connection phrase is one line changing state, not characters becoming a new name.
        /// Keep the complete scroll and its single shared breath inside one bounded chrome
        /// response. The scroll has to clear a caption's full line height: the old 0.2 intensity
        /// moved only about 70% of one line, leaving both phrases stacked over each other.
        static let connectionStatusMorphDuration: TimeInterval = 0.65
        static let connectionStatusMorphIntensity = 0.72
        /// Every glyph shares one eased trough. Repeating five 100 ms troughs and staggering
        /// them across the sentence made the leading half flicker while a trailing `Book Pro`
        /// stayed fully lit, so the status did not read as one moving line.
        static let connectionStatusFadePulseCount = 1
        static let connectionStatusFadeMinimumOpacity: Float = 0.66
        static let connectionStatusFadePulseDuration: TimeInterval = 0.65
        static let connectionStatusFadePauseDuration: TimeInterval = 0
        static let connectionStatusFadeTravelDuration: TimeInterval = 0
        /// Restate the one active dashboard step without keeping every row in motion.
        static let connectionProgressFadeCadence: TimeInterval = 2
    }
}

/// The compact two-line title shared by remote surfaces and owner flows.
///
/// The first line identifies the task or flow; the second always identifies connection state
/// through colour and the Mac through its user-visible name. Keeping this in the mobile design
/// layer prevents individual screens from drifting back to vague labels such as "Remote control"
/// or duplicating the host name in their body content.
struct MobileConnectionNavigationTitle: View {
    let title: String
    let status: String
    let statusColor: Color
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        VStack(spacing: MobileDesign.Spacing.hairline) {
            MobileMorphingTitle(
                title: title,
                textStyle: .headline,
                weight: .semibold,
                textColor: theme.uiLabel,
                groundColor: theme.uiSurface,
                alignment: .center
            )
            .frame(maxWidth: .infinity)

            HStack(spacing: MobileDesign.Spacing.tight) {
                Circle()
                    .fill(statusColor)
                    .frame(
                        width: MobileDesign.Size.navigationStatusIndicator,
                        height: MobileDesign.Size.navigationStatusIndicator
                    )
                MobileMorphingTitle(
                    title: status,
                    textStyle: .caption2,
                    weight: .regular,
                    textColor: theme.uiSecondaryLabel,
                    groundColor: theme.uiSurface,
                    alignment: .center,
                    role: .connectionStatus
                )
            }
            .foregroundStyle(theme.secondaryLabel)
        }
        // Asked for, not measured. The ideal is what a principal toolbar item is sized by, so
        // stating one takes the name out of the answer; the same value as the maximum keeps the
        // title inside whatever the bar's button groups actually left, which on a 320-point
        // phone is well under it. See `MobileDesign.Size.navigationTitleWidth`.
        .frame(
            idealWidth: MobileDesign.Size.navigationTitleWidth,
            maxWidth: MobileDesign.Size.navigationTitleWidth
        )
        .accessibilityElement(children: .combine)
    }
}

/// The phone's rendering of the Mac's semantic app theme.
///
/// Fallbacks preserve the original mobile appearance against an older host. The Mac sends
/// resolved values, so this layer never needs to know whether a colour came from a built-in,
/// custom, inherited, or dynamic System theme.
struct RemoteThemePalette: Equatable {
    let source: RemoteThemeDTO?

    init(_ source: RemoteThemeDTO?) {
        self.source = source
    }

    var colorScheme: ColorScheme { source?.mode == "light" ? .light : .dark }
    var ground: Color { color("ground", fallback: "#16181D") }
    var surface: Color { color("surface", fallback: "#1B1E24") }
    var panel: Color { color("panel", fallback: "#22252C") }
    var elevated: Color { color("elevated", fallback: "#292D35") }
    var controlResting: Color { color("control_resting", fallback: "#FFFFFF12") }
    var controlHover: Color { color("control_hover", fallback: "#FFFFFF20") }
    var border: Color { color("border", fallback: "#FFFFFF14") }
    var divider: Color { color("divider", fallback: "#FFFFFF0C") }
    var label: Color { color("label", fallback: "#F3F4F6") }
    var secondaryLabel: Color { color("secondary_label", fallback: "#A7ABB4") }
    var tertiaryLabel: Color { color("tertiary_label", fallback: "#747983") }
    var accent: Color { color("accent", fallback: "#FFFFFF") }
    /// Text/icon colour chosen from the resolved accent itself, not from an unrelated surface.
    /// Authored themes may pair a pale accent with either a light or dark ground.
    var accentForeground: Color { Color(uiAccentForeground) }
    var accentMuted: Color { color("accent_muted", fallback: "#FFFFFF24") }
    var selection: Color { color("selection", fallback: "#FFFFFF32") }
    var positive: Color { color("status_positive", fallback: "#55B978") }
    var warning: Color { color("status_warning", fallback: "#D9A441") }
    var negative: Color { color("status_negative", fallback: "#D87878") }
    var diffAdded: Color { color("diff_added", fallback: "#55B978") }
    var diffRemoved: Color { color("diff_removed", fallback: "#D87878") }

    var uiGround: UIColor { uiColor("ground", fallback: "#16181D") }
    var uiSurface: UIColor { uiColor("surface", fallback: "#1B1E24") }
    var uiPanel: UIColor { uiColor("panel", fallback: "#22252C") }
    var uiElevated: UIColor { uiColor("elevated", fallback: "#292D35") }
    var uiControlResting: UIColor { uiColor("control_resting", fallback: "#FFFFFF12") }
    var uiBorder: UIColor { uiColor("border", fallback: "#FFFFFF14") }
    var uiDivider: UIColor { uiColor("divider", fallback: "#FFFFFF0C") }
    var uiLabel: UIColor { uiColor("label", fallback: "#F3F4F6") }
    var uiSecondaryLabel: UIColor { uiColor("secondary_label", fallback: "#A7ABB4") }
    var uiTertiaryLabel: UIColor { uiColor("tertiary_label", fallback: "#747983") }
    var uiAccent: UIColor { uiColor("accent", fallback: "#FFFFFF") }
    var uiAccentForeground: UIColor {
        guard let luminance = uiAccent.remoteRelativeLuminance else {
            return colorScheme == .light ? .black : .white
        }
        return luminance > MobileKeyboardAppearance.lightThreshold ? .black : .white
    }
    var uiAccentMuted: UIColor { uiColor("accent_muted", fallback: "#FFFFFF24") }
    var uiPositive: UIColor { uiColor("status_positive", fallback: "#55B978") }
    var uiWarning: UIColor { uiColor("status_warning", fallback: "#D9A441") }
    var uiNegative: UIColor { uiColor("status_negative", fallback: "#D87878") }
    var uiDiffAdded: UIColor { uiColor("diff_added", fallback: "#55B978") }
    var uiDiffRemoved: UIColor { uiColor("diff_removed", fallback: "#D87878") }

    /// Adaptive identity colours for categorical data such as providers or accounts.
    ///
    /// These deliberately do not use the theme's semantic positive, warning or negative roles:
    /// a provider is not a connection state, warning, or failure. Keeping the distinction in the
    /// palette makes charts legible under every authored chrome without weakening status colour.
    func categorical(_ index: Int) -> Color {
        let darkFallbacks = [
            "#64A8FF", "#B69BFF", "#758BFD",
            "#42C7D9", "#EA83C5", "#C5956B",
        ]
        let lightFallbacks = [
            "#155DB1", "#6F42C1", "#3F51B5",
            "#087E8B", "#A93686", "#855A38",
        ]
        let resolvedIndex = ((index % darkFallbacks.count) + darkFallbacks.count)
            % darkFallbacks.count
        let fallback = colorScheme == .light
            ? lightFallbacks[resolvedIndex]
            : darkFallbacks[resolvedIndex]
        return color("data_series_\(resolvedIndex + 1)", fallback: fallback)
    }

    var panelRadius: CGFloat { CGFloat(source?.material.panelRadius ?? 20) }
    var controlRadius: CGFloat { CGFloat(source?.material.controlRadius ?? 10) }
    var borderWidth: CGFloat { CGFloat(source?.material.borderWidth ?? 1) }
    var glow: RemoteThemeDTO.Material.Glow? { source?.material.glow }

    func color(_ role: String, fallback: String) -> Color {
        Color(uiColor(role, fallback: fallback))
    }

    func uiColor(_ role: String, fallback: String) -> UIColor {
        UIColor(remoteHex: source?.colors[role] ?? fallback) ?? .black
    }
}

private struct RemoteThemeKey: EnvironmentKey {
    static let defaultValue = RemoteThemePalette(nil)
}

extension EnvironmentValues {
    var remoteTheme: RemoteThemePalette {
        get { self[RemoteThemeKey.self] }
        set { self[RemoteThemeKey.self] = newValue }
    }
}

extension View {
    /// Gives a themed panel the Mac theme's optional halo without duplicating shadow math.
    @ViewBuilder
    func remoteThemeGlow(_ theme: RemoteThemePalette) -> some View {
        if let glow = theme.glow,
           let color = UIColor(remoteHex: glow.color) {
            shadow(
                color: Color(color).opacity(glow.opacity),
                radius: CGFloat(glow.radius),
                x: CGFloat(glow.offsetX ?? 0),
                y: CGFloat(-(glow.offsetY ?? 0))
            )
        } else {
            self
        }
    }
}

/// A full-width action whose foreground remains legible against an arbitrary authored accent.
///
/// SwiftUI's prominent button chooses its own foreground colour, which can disappear when a Mac
/// theme supplies a pale accent. Application-owned mobile actions use the resolved accent contrast
/// instead, while secondary actions stay on the theme's control surface.
struct MobileThemedActionButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
    }

    let kind: Kind
    let theme: RemoteThemePalette
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: MobileDesign.Size.dialogActionHeight)
            .foregroundStyle(kind == .primary ? theme.accentForeground : theme.label)
            .background(
                kind == .primary ? theme.accent : theme.controlResting,
                in: RoundedRectangle(cornerRadius: theme.controlRadius)
            )
            .overlay {
                RoundedRectangle(cornerRadius: theme.controlRadius)
                    .stroke(
                        kind == .primary ? Color.clear : theme.border,
                        lineWidth: theme.borderWidth
                    )
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.42)
    }
}

/// A theme-safe mobile switch whose state stays legible when the theme accent is white.
///
/// The native switch uses a white thumb over the accent track. That collapses into a blank
/// capsule for Threading's default white accent, so the phone owns both surfaces here. Position
/// and the thumb glyph carry state independently of colour.
struct MobileThemedToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let theme: RemoteThemePalette

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: MobileDesign.Spacing.medium) {
                configuration.label
                    .foregroundStyle(theme.label)

                Spacer(minLength: MobileDesign.Spacing.medium)

                track(isOn: configuration.isOn)
            }
            .frame(minHeight: MobileDesign.Size.minimumTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .animation(
            reduceMotion ? nil : .snappy(
                duration: MobileDesign.Motion.controlResponse,
                extraBounce: 0.08
            ),
            value: configuration.isOn
        )
        .accessibilityRepresentation {
            Toggle(
                isOn: Binding(
                    get: { configuration.isOn },
                    set: { configuration.isOn = $0 }
                )
            ) {
                configuration.label
            }
            .toggleStyle(.switch)
        }
    }

    private func track(isOn: Bool) -> some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? theme.accent : theme.controlHover)

            Circle()
                .fill(isOn ? theme.ground : theme.label)
                .frame(
                    width: MobileDesign.Size.toggleThumb,
                    height: MobileDesign.Size.toggleThumb
                )
                .overlay {
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(theme.accent)
                    }
                }
                .padding((MobileDesign.Size.toggleTrackHeight - MobileDesign.Size.toggleThumb) / 2)
        }
        .frame(
            width: MobileDesign.Size.toggleTrackWidth,
            height: MobileDesign.Size.toggleTrackHeight
        )
        .overlay {
            Capsule()
                .stroke(theme.border, lineWidth: max(theme.borderWidth, 1))
        }
    }
}

extension UIColor {
    convenience init?(remoteHex source: String) {
        let hex = source.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard hex.count == 6 || hex.count == 8,
              let value = UInt64(hex, radix: 16) else {
            return nil
        }

        let hasAlpha = hex.count == 8
        let redShift: UInt64 = hasAlpha ? 24 : 16
        let greenShift: UInt64 = hasAlpha ? 16 : 8
        let blueShift: UInt64 = hasAlpha ? 8 : 0
        self.init(
            red: CGFloat((value >> redShift) & 0xff) / 255,
            green: CGFloat((value >> greenShift) & 0xff) / 255,
            blue: CGFloat((value >> blueShift) & 0xff) / 255,
            alpha: hasAlpha ? CGFloat(value & 0xff) / 255 : 1
        )
    }
}
