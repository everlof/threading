import SwiftUI
import WidgetKit

/// WidgetKit is a system-owned surface: adaptive foregrounds survive the user's tinted Home
/// Screen, vibrant Lock Screen, StandBy and background removal. Only the authored accent travels.
enum GlanceDesign {
    enum Spacing {
        static let tight: CGFloat = 2
        static let small: CGFloat = 4
        static let medium: CGFloat = 8
        static let pane: CGFloat = 16
    }
    static let heading = Font.headline
    static let reading = Font.subheadline.weight(.medium)
    static let caption = Font.caption2
    static let background = Color(.systemBackground)
    static let secondary = Color.secondary
    static let accent = Color.accentColor

    static func accent(hex: String?, mode: WidgetRenderingMode, colorScheme: ColorScheme) -> Color {
        guard mode == .fullColor, let hex,
              let rgb = UInt32(hex.dropFirst(), radix: 16), hex.count == 7 else { return accent }
        var channels = [Double((rgb >> 16) & 255), Double((rgb >> 8) & 255), Double(rgb & 255)]
            .map { $0 / 255 }
        let ground = colorScheme == .dark ? 0.0 : 1.0
        func luminance(_ channels: [Double]) -> Double {
            let linear = channels.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
        }
        // Capacity marks must remain distinguishable on the system's widget ground.
        for _ in 0..<20 {
            let light = luminance(channels)
            if (max(light, ground) + 0.05) / (min(light, ground) + 0.05) >= 3 { break }
            let target = colorScheme == .dark ? 1.0 : 0.0
            channels = channels.map { $0 + (target - $0) * 0.1 }
        }
        return Color(red: channels[0], green: channels[1], blue: channels[2])
    }
}
