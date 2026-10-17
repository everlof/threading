import AppKit

/// The window host's SF Symbol service: `Design.Symbol` artwork, redrawn for each configuration.
@MainActor
enum LinuxSymbols {
    /// An unconfigured symbol keeps the placeholder’s full 44pt canvas and 36pt optical size;
    /// a configured one is drawn at exactly its point size and weight.
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
