import Foundation

/// What the application calls itself, read from the bundle rather than written down.
///
/// The name reaches text the user reads — a settings subtitle, the name a transition preview
/// morphs a style's name into — and a literal in each of those is one more place to miss when
/// the product is renamed. `CFBundleDisplayName` is what the Finder shows when a bundle sets
/// it, `CFBundleName` is what every bundle has, and the process name is the honest answer for
/// a binary running outside a bundle.
enum AppInfo {

    static var name: String {
        let info = Bundle.main.infoDictionary
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let value = info?[key] as? String, !value.isEmpty {
                return value
            }
        }
        return ProcessInfo.processInfo.processName
    }
}
