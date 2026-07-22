import Foundation

/// Turns the identifier a CLI stores into the name a person uses.
///
/// The composer offered "Default model", which names the *setting* rather than the answer —
/// the one thing a user wants from that chip is which model the session will actually run on,
/// and "Default" makes them go and look it up. Every identifier here comes from the user's own
/// config, so this only has to be readable, not exhaustive.
enum ModelName {

    /// The suffix Claude uses for the long-context variant of a model.
    private static let longContextSuffix = "[1m]"
    private static let longContextLabel = "1M"

    /// Known families, longest first so `claude-fable-5` is matched before `claude`.
    ///
    /// A deliberately short table: an id it does not recognise is tidied rather than dropped,
    /// so a model released after this was written still reads as itself instead of as
    /// "Default".
    private static let families: [(id: String, name: String)] = [
        ("claude-fable-5", "Fable 5"),
        ("claude-opus-4-8", "Opus 4.8"),
        ("claude-sonnet-5", "Sonnet 5"),
        ("claude-haiku-4-5", "Haiku 4.5"),
        ("fable", "Fable"),
        ("opus", "Opus"),
        ("sonnet", "Sonnet"),
        ("haiku", "Haiku")
    ]

    /// `claude-fable-5[1m]` → `Fable 5 · 1M`, `opus[1m]` → `Opus · 1M`, `gpt-5-codex` →
    /// `gpt-5-codex`.
    static func display(for identifier: String) -> String {
        var id = identifier.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return identifier }

        var suffix = ""
        if id.lowercased().hasSuffix(longContextSuffix) {
            id = String(id.dropLast(longContextSuffix.count))
            suffix = " · \(longContextLabel)"
        }

        let lowered = id.lowercased()
        if let family = families.first(where: { lowered == $0.id || lowered.hasPrefix($0.id) }) {
            return family.name + suffix
        }

        // Unknown: hand back what the config said. A wrong friendly name would be worse than
        // an unfamiliar accurate one, since this is the string that says what you are paying for.
        return id + suffix
    }
}
