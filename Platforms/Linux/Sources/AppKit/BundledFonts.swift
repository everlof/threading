#if os(Linux)
import Foundation
import AppKitTextBridge

/// Register the two fixed UI faces once, before any NSFont can measure or draw. No system
/// installation, directory scan, or per-label registration is needed. Swift's static initializer
/// serializes concurrent first use by UI and document workers.
enum BundledFonts {
    static let registered: Void = {
        let directory = Bundle.module.resourceURL!.appendingPathComponent("Fonts/Inter")
        let regular = directory.appendingPathComponent("InterVariable.ttf").path
        let italic = directory.appendingPathComponent("InterVariable-Italic.ttf").path
        let accepted = regular.withCString { regularPath in
            italic.withCString { tat_register_ui_fonts(regularPath, $0) }
        }
        precondition(accepted == 1, "The bundled Inter UI fonts could not be registered")
    }()
}

public extension NSFont {
    /// The native host calls this on its bounded startup worker before mounting UI. Isolated
    /// component fixtures can still construct fonts directly through the same once-only gate.
    static func prepareSystemFonts() { _ = BundledFonts.registered }
}
#endif
