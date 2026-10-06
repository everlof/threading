import Foundation

/// The fixture has no resource bundle, so it reads the native window's checked theme export from
/// the source tree. Every fixture linking this file sits two directories below the Linux package.
enum LinuxThemeSnapshot {
    static var url: URL? {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/WindowHarness/Resources/Theme/threading.json")
            .standardizedFileURL
    }
}
