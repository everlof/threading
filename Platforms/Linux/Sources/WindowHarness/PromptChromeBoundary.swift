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
