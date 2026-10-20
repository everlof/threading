import AppKit

// The checked Linux theme uses the modern checkbox. Keep the production control's material
// vocabulary in this theme adapter so the same ThemedCheckbox source runs on both platforms.
extension AppTheme.Material {
    enum CheckboxStyle {
        case automatic, recessedTick, windows98Tick, beOSCross, round

        var isHistorical: Bool { self != .automatic && self != .round }
    }
}

extension AppThemePalette.Material {
    var checkboxStyle: AppTheme.Material.CheckboxStyle { .automatic }
    var controlRadius: CGFloat { Design.Radius.control }
}

extension NSColor {
    func lightened(by amount: CGFloat) -> NSColor {
        let target: CGFloat = amount >= 0 ? 1 : 0
        let fraction = abs(amount)
        return NSColor(srgbRed: redComponent + (target - redComponent) * fraction,
                       green: greenComponent + (target - greenComponent) * fraction,
                       blue: blueComponent + (target - blueComponent) * fraction,
                       alpha: alphaComponent)
    }
}
