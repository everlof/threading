import SwiftUI

/// WidgetKit is a system-owned surface: adaptive foregrounds survive the user's tinted Home
/// Screen, vibrant Lock Screen, StandBy and background removal. Fixed Mac palette colors do not.
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
}
