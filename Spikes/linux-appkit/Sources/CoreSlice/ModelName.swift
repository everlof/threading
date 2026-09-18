import Foundation

/// Turns the identifier a CLI stores into the name a person uses.
///
/// The composer offered "Default model", which names the *setting* rather than the answer —
/// the one thing a user wants from that chip is which model the session will actually run on,
/// and "Default" makes them go and look it up. Every identifier here comes from the user's own
/// config, so this only has to be readable, not exhaustive.
///
/// The version is **read out of the id, not looked up in a table.** A table keyed on the ids
/// known when it was written matched by prefix, so `claude-fable-5-1` hit the `claude-fable-5`
/// row and read "Fable 5" — on the login whose `settings.json` pinned exactly that id, the row
/// marked *account default* named the previous model while running the newer one. Anthropic's
/// ids have one shape (`claude-<family>-<major>[-<minor>][-<yyyymmdd>]`, with an older
/// version-first form for the 3.x generation), so reading that shape names a version this file
/// has never heard of, and a family it has never heard of stays verbatim rather than guessed.
public enum ModelName {

    // MARK: - Types

    /// One identifier taken apart.
    ///
    /// `version` is nil for an alias (`opus`), which the CLI resolves to whatever that family's
    /// latest is at launch — so an alias has a family and a long-context flag but no version of
    /// its own to name. See `versionedDisplay(for:resolvedAs:)` for where its version comes from.
    public struct Reading: Equatable, Sendable {
        /// The family, capitalised the way it is written: `Fable`, `Opus`.
        public let family: String
        /// `5.1`, `4.8`, or nil for an alias.
        public let version: String?
        /// Whether the id carries Claude's long-context suffix.
        public let isLongContext: Bool

        /// `Fable 5.1 · 1M`, `Opus`, `Haiku 4.5`.
        public var name: String {
            let base = version.map { "\(family) \($0)" } ?? family
            return ModelName.marked(base, isLongContext: isLongContext)
        }
    }

    /// The published tiers, most capable first.
    ///
    /// Declaration order *is* the order: `rawValue` is what sorts a model list, so a new tier is
    /// added in its place rather than given a number to remember. Anthropic's own tiering is what
    /// this follows — Fable above Opus above Sonnet above Haiku — which is also the order of the
    /// list prices, so the ranking is checkable against something outside this file.
    ///
    /// Deliberately families rather than versions: a menu ordered by dated version would put
    /// last year's Opus above this year's Sonnet, and would need editing on every release. The
    /// alias inside a family already tracks its latest.
    public enum Tier: Int, CaseIterable {
        case fable
        case opus
        case sonnet
        case haiku

        /// Every spelling that names this tier. Mythos is Fable's tier — the same capabilities at
        /// the same price through a different distribution — so it sorts as one.
        public var tokens: [String] {
            switch self {
            case .fable: return ["fable", "mythos"]
            case .opus: return ["opus"]
            case .sonnet: return ["sonnet"]
            case .haiku: return ["haiku"]
            }
        }
    }

    // MARK: - Properties

    /// The suffix Claude uses for the long-context variant of a model.
    private static let longContextSuffix = "[1m]"
    private static let longContextLabel = "1M"
    private static let longContextMarkSeparator = " · "

    /// The shape of a full Anthropic id: this prefix, then dash-separated segments.
    private static let claudePrefix = "claude-"
    private static let segmentSeparator: Character = "-"
    private static let versionSeparator = "."

    /// A version segment is `4` or `8`; a dated snapshot is `20251001`. Anything else in a
    /// numeric position is a shape this has not seen, and the id is left verbatim.
    private static let versionSegmentMaximumDigits = 2
    private static let versionSegmentLimit = 2
    private static let dateSegmentDigits = 8

    // MARK: - Public Methods

    /// Which tier `identifier` belongs to, or nil for one no tier names.
    ///
    /// Containment, like `scope(_:meters:)` and for the same reason: the id a CLI hands us is
    /// `fable`, `claude-fable-5`, or `claude-fable-5[1m]` depending on where it was read, and a
    /// tier that only matched one spelling would sort the other two as unknown.
    ///
    /// Nil is a real answer and the one an organisation's own grant gets. It sorts *after* every
    /// named tier rather than being guessed into one: putting an unrecognised model above Opus
    /// on a hunch is worse than leaving it where the source listed it.
    public static func tier(of identifier: String) -> Tier? {
        let id = identifier.lowercased()
        return Tier.allCases.first { tier in
            tier.tokens.contains { id.contains($0) }
        }
    }

    /// `identifier` taken apart, or nil when it is not an id of a family this knows.
    ///
    /// Reads both shapes Anthropic has used — `claude-opus-4-1-20250805` and the older
    /// `claude-3-5-sonnet-20241022` — and the bare aliases the CLI documents. A dated snapshot
    /// segment is dropped, since the date is not part of the name anyone uses. A segment that is
    /// neither a known family, a short version number nor a date makes the whole id unreadable:
    /// a wrong friendly name would be worse than an unfamiliar accurate one, since this string
    /// says what the session will cost.
    public static func read(_ identifier: String) -> Reading? {
        var id = identifier.trimmingCharacters(in: .whitespaces).lowercased()
        guard !id.isEmpty else { return nil }

        let isLongContext = id.hasSuffix(longContextSuffix)
        if isLongContext { id.removeLast(longContextSuffix.count) }

        if let family = familyName(forToken: id) {
            return Reading(family: family, version: nil, isLongContext: isLongContext)
        }

        guard id.hasPrefix(claudePrefix) else { return nil }
        var family: String?
        var versionSegments: [String] = []
        for segment in id.dropFirst(claudePrefix.count)
            .split(separator: segmentSeparator, omittingEmptySubsequences: false) {
            if segment.isEmpty { return nil }
            if segment.allSatisfy({ $0.isASCII && $0.isWholeNumber }) {
                if segment.count == dateSegmentDigits { continue }
                guard segment.count <= versionSegmentMaximumDigits,
                      versionSegments.count < versionSegmentLimit
                else { return nil }
                versionSegments.append(String(segment))
            } else if family == nil, let name = familyName(forToken: String(segment)) {
                family = name
            } else {
                return nil
            }
        }
        guard let family, !versionSegments.isEmpty else { return nil }
        return Reading(
            family: family,
            version: versionSegments.joined(separator: versionSeparator),
            isLongContext: isLongContext
        )
    }

    /// Whether `identifier` names a version of its own, as `claude-opus-5` does and `opus`
    /// does not. An alias's version is only known once a runtime has resolved it.
    public static func isVersioned(_ identifier: String) -> Bool {
        read(identifier)?.version != nil
    }

    /// `claude-fable-5-1[1m]` → `Fable 5.1 · 1M`, `opus[1m]` → `Opus · 1M`, `gpt-5-codex` →
    /// `gpt-5-codex`.
    public static func display(for identifier: String) -> String {
        let id = identifier.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return identifier }

        if let reading = read(id) { return reading.name }

        // Unknown: hand back what the config said, keeping only the mark this understands. A
        // wrong friendly name would be worse than an unfamiliar accurate one, since this is the
        // string that says what you are paying for.
        return marked(bare(id), isLongContext: hasLongContextSuffix(id))
    }

    /// An alias named after the model it was watched resolving to: `opus` seen as
    /// `claude-opus-5` reads `Opus 5`, and `fable[1m]` seen as `claude-fable-5-1[1m]` reads
    /// `Fable 5.1 · 1M`.
    ///
    /// Nil when there is nothing to add — the id already names its version, or the runtime's
    /// answer cannot be read — and nil when the answer names a *different family*, which a
    /// mis-keyed record could and a correct one never does. The long-context mark follows the
    /// alias rather than the answer, because the alias is what will launch.
    public static func versionedDisplay(for identifier: String, resolvedAs resolved: String) -> String? {
        guard let alias = read(identifier),
              alias.version == nil,
              let answer = read(resolved),
              let version = answer.version,
              answer.family == alias.family
        else { return nil }
        return Reading(family: alias.family, version: version, isLongContext: alias.isLongContext).name
    }

    /// The service's own name for a model this cannot read, with the mark this does understand
    /// carried over from the id: the CLI caches `claude-quasar-9[1m]` as "Quasar", and the row
    /// should read `Quasar · 1M`.
    public static func display(serviceLabel label: String, for identifier: String) -> String {
        marked(label, isLongContext: hasLongContextSuffix(identifier))
    }

    /// Whether a rate limit scoped to `name` meters a session running `identifier`.
    ///
    /// The two vocabularies do not match on the nose and never will: a provider names the limit
    /// after the family it meters (`Fable`, `GPT-5.3-Codex-Spark`) while a session carries the
    /// id its CLI was launched with (`claude-fable-5[1m]`). Containment reads both, in the id
    /// and in the friendly name, so a limit matches the whole family rather than one dated
    /// version of it — which is the behaviour that survives the next model.
    ///
    /// Deliberately narrow in one direction: an unrecognised pairing is *not* a match, because a
    /// scoped limit wrongly applied would put a session in the red over a model it is not using.
    public static func scope(_ name: String, meters identifier: String) -> Bool {
        let scoped = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !scoped.isEmpty else { return false }

        let id = identifier.trimmingCharacters(in: .whitespaces).lowercased()
        guard !id.isEmpty else { return false }

        return id.contains(scoped) || display(for: identifier).lowercased().contains(scoped)
    }

    // MARK: - Private Methods

    /// The family a single token names — `opus` → `Opus` — or nil. Every family is one word,
    /// so capitalising its first letter is the whole spelling.
    private static func familyName(forToken token: String) -> String? {
        guard Tier.allCases.contains(where: { $0.tokens.contains(token) }) else { return nil }
        return token.prefix(1).uppercased() + token.dropFirst()
    }

    private static func hasLongContextSuffix(_ identifier: String) -> Bool {
        identifier.lowercased().hasSuffix(longContextSuffix)
    }

    /// The id without its long-context suffix, otherwise untouched.
    private static func bare(_ identifier: String) -> String {
        guard hasLongContextSuffix(identifier) else { return identifier }
        return String(identifier.dropLast(longContextSuffix.count))
    }

    private static func marked(_ name: String, isLongContext: Bool) -> String {
        isLongContext ? name + longContextMarkSeparator + longContextLabel : name
    }
}
