import Foundation

/// Where `LinuxTheme` reads the checked Threading theme export: the native window's bundled
/// resource. Focused fixtures link `LinuxTheme` without a resource bundle and supply their own
/// locator for the same file instead.
enum LinuxThemeSnapshot {
    static var url: URL? {
        Bundle.module.url(forResource: "threading", withExtension: "json", subdirectory: "Theme")
    }
}
