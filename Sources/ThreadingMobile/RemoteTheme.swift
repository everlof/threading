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
    }

    enum Size {
        static let minimumTapTarget: CGFloat = 44
        static let navigationStatusIndicator: CGFloat = 6
        static let dialogActionHeight: CGFloat = 52
        static let conversationEstimatedRowHeight: CGFloat = 88
        static let conversationHistoryTrigger: CGFloat = 180
        static let conversationBottomTolerance: CGFloat = 140
        static let permissionDiffMaximumHeight: CGFloat = 220
        static let permissionDiffMinimumHeight: CGFloat = minimumTapTarget * 2
        static let diffMarkerColumnWidth: CGFloat = 18
        static let workspaceActivityDot: CGFloat = 7
        static let badgeStroke: CGFloat = 2
    }

    enum Offset {
        static let workspaceActivityDot: CGFloat = 3
    }

    enum Typography {
        static let messageLineSpacing: CGFloat = 4
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
    var uiLabel: UIColor { uiColor("label", fallback: "#F3F4F6") }
    var uiSecondaryLabel: UIColor { uiColor("secondary_label", fallback: "#A7ABB4") }
    var uiTertiaryLabel: UIColor { uiColor("tertiary_label", fallback: "#747983") }
    var uiAccent: UIColor { uiColor("accent", fallback: "#FFFFFF") }
    var uiWarning: UIColor { uiColor("status_warning", fallback: "#D9A441") }
    var uiNegative: UIColor { uiColor("status_negative", fallback: "#D87878") }
    var uiDiffAdded: UIColor { uiColor("diff_added", fallback: "#55B978") }
    var uiDiffRemoved: UIColor { uiColor("diff_removed", fallback: "#D87878") }

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
