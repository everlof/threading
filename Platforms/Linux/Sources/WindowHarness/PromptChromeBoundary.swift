import AppKit

// Threading's exported light/dark variants use the ordinary flat field style.
extension AppTheme.Material {
    enum FieldStyle { case standard, outlined }
}
extension AppThemePalette.Material {
    var fieldStyle: AppTheme.Material.FieldStyle { .standard }
}
@MainActor enum OutlinedField {
    static var borderWidth: CGFloat {
        preconditionFailure("The Linux theme export does not carry outlined field materials")
    }
}
extension Design.Size {
    static let inputHeight: CGFloat = 44
    static let inputMaxHeight: CGFloat = 180
}
extension Design.Surface {
    static var fieldDropTarget: NSColor {
        let field = LinuxTheme.color("fieldSurface")
        let accent = LinuxTheme.color("accent")
        return field.blended(withFraction: 0.16, of: accent) ?? field
    }
}
