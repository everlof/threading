import AppKit

/// The window host's SF Symbol service: `Design.Symbol` artwork, redrawn for each configuration.
@MainActor
enum LinuxSymbols {
    /// An unconfigured symbol is drawn on the largest canvas so a placeholder hero scaled up to
    /// its well stays sharp; a configured one is drawn at exactly its point size and weight.
    static func install() {
        NSImage.systemSymbolProvider = { name, _, configuration in
            guard let configuration else {
                return Design.Symbol.image(name, slot: PlaceholderDefaults.iconSize,
                                           pointSize: 36, weight: .regular)
            }
            return Design.Symbol.image(name, slot: configuration.pointSize,
                                       pointSize: configuration.pointSize, weight: configuration.weight)
        }
    }
}
