import AppKit

// The checked Linux theme uses the production switch's modern sliding material.
extension AppTheme.Material {
    enum ToggleStyle { case automatic, onOffButton }
}

extension AppThemePalette.Material {
    var toggleStyle: AppTheme.Material.ToggleStyle { .automatic }
    var panelRadius: CGFloat { Design.Radius.panel }
}

extension Design.Accessibility {
    static let differentiatesWithoutColor = false
}

extension Design.Motion {
    static var standard: TimeInterval { reducesStatusMotion ? 0 : 0.2 }
}
