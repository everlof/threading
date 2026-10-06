import AppKit

/// Shared value population for app-theme pickers: the library's sections, each under its head,
/// with the stored choice selected. Every row is a theme; choosing one goes through `ThemeSwitch`.
@MainActor
enum AppThemePicker {
    static func populate(_ popUp: ThemedPopUp, selectedThemeID: AppThemeID) {
        popUp.removeAllItems()
        for section in AppThemeLibrary.sections {
            if let title = section.title { popUp.addHeader(title) }
            for theme in section.themes {
                popUp.addItem(ThemedMenuItem(title: theme.name, representedValue: theme.id.rawValue))
            }
        }
        let selectedIndex = popUp.indexOfItem { $0.representedValue as? String == selectedThemeID.rawValue }
        popUp.selectItem(at: selectedIndex ?? popUp.indexOfFirstItem ?? -1)
    }
}
