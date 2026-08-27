import Foundation

/// One provider- or application-owned action the native composer can offer.
///
/// This is deliberately metadata, not a parsed skill file. Claude and Codex remain authoritative
/// for scope, precedence, policy, plugins, and the instructions that actually run; Threading only
/// keeps enough information to discover and invoke what the live session advertised.
struct ComposerCapability: Equatable, Sendable {
    enum Kind: String, Sendable {
        case command
        case skill
    }

    enum Trigger: String, Sendable {
        case slash
        case dollar

        var prefix: Character {
            switch self {
            case .slash: "/"
            case .dollar: "$"
            }
        }
    }

    /// Whether invoking this action opens an agent turn or controls the session itself.
    enum Presentation: String, Sendable {
        case turn
        case command
    }

    let id: String
    let name: String
    let displayName: String
    let description: String
    let argumentHint: String
    let aliases: [String]
    let kind: Kind
    /// Whether this row belongs in the app-owned skill browser. This can be true while `kind`
    /// remains `.command` for Claude's initialize-only snapshot: that wire shape has no kind
    /// discriminator, so hiding provisional rows would make every opening-session skill
    /// undiscoverable until after the first prompt.
    let isAvailableInSkillCatalog: Bool
    let trigger: Trigger
    let presentation: Presentation

    /// Whether this action can be invoked, and where it cannot, why.
    let availability: Availability

    /// Whether an action can be invoked right now, carrying its reason where it cannot.
    ///
    /// One value rather than `isEnabled: Bool` beside `unavailableReason: String?`, which
    /// admitted two states nothing could render: disabled with no explanation, where the row
    /// greys out and says nothing about why; and enabled *with* a reason, where the row offers
    /// the action and explains why it is unusable. All four producers had to hold the two in
    /// step by hand, and three wrote the same `enabled ? nil : reason` ternary to do it.
    ///
    /// A reason is therefore required, not optional: `PromptCompletionView` shows it in place
    /// of the description on a disabled row, so an unexplained refusal is a blank line where
    /// the answer should be.
    enum Availability: Equatable, Sendable {
        case available
        case unavailable(reason: String)

        var isEnabled: Bool {
            self == .available
        }

        var reason: String? {
            guard case .unavailable(let reason) = self else { return nil }
            return reason
        }

        /// The same value with its reason shortened for a bounded wire projection.
        func mappingReason(_ transform: (String) -> String) -> Availability {
            guard case .unavailable(let reason) = self else { return self }
            return .unavailable(reason: transform(reason))
        }
    }

    /// Retained as the reading vocabulary: the invalid pairs are gone from *construction*, and
    /// the call sites that only ever asked these two questions did not have to learn a new
    /// shape to keep asking them. Only the four producers changed.
    var isEnabled: Bool { availability.isEnabled }
    var unavailableReason: String? { availability.reason }

    init(
        id: String,
        name: String,
        displayName: String? = nil,
        description: String = "",
        argumentHint: String = "",
        aliases: [String] = [],
        kind: Kind,
        isAvailableInSkillCatalog: Bool? = nil,
        trigger: Trigger,
        presentation: Presentation,
        availability: Availability = .available
    ) {
        self.id = id
        self.name = name
        self.displayName = displayName ?? name
        self.description = description
        self.argumentHint = argumentHint
        self.aliases = aliases
        self.kind = kind
        self.isAvailableInSkillCatalog = isAvailableInSkillCatalog ?? (kind == .skill)
        self.trigger = trigger
        self.presentation = presentation
        self.availability = availability
    }

    var invocationText: String { String(trigger.prefix) + name }
}

struct ComposerInvocation: Equatable, Sendable {
    let capability: ComposerCapability
    let arguments: String
    let sourceText: String
}

struct ComposerCapabilityCatalogNormalization: Equatable, Sendable {
    let capabilities: [ComposerCapability]
    let wasTruncated: Bool
}

/// Bounds provider-owned metadata before it becomes long-lived main-actor state or AppKit rows.
///
/// The remote projection has its own encoded-frame budget, but that boundary is too late for the
/// Mac: a local CLI can still return thousands of entries or a multi-megabyte description. Names
/// and ids are protocol identity and are therefore rejected rather than shortened; presentation
/// fields may be truncated without changing what is invoked.
enum ComposerCapabilityCatalogPolicy {
    static let maximumCapabilities = 256
    static let maximumInspectedCapabilities = 1_024
    static let maximumCatalogUTF8Bytes = 64 * 1_024
    static let maximumRenderedSuggestions = 64
    static let maximumIDUTF8Bytes = 512
    static let maximumNameUTF8Bytes = 256
    static let maximumDescriptionUTF8Bytes = 1_500
    static let maximumArgumentHintUTF8Bytes = 512
    static let maximumUnavailableReasonUTF8Bytes = 512
    static let maximumAliases = 12
    static let maximumAliasUTF8Bytes = 256
    static let maximumPrivatePathUTF8Bytes = 16 * 1_024

    static func normalize(
        _ capabilities: [ComposerCapability]
    ) -> ComposerCapabilityCatalogNormalization {
        var result: [ComposerCapability] = []
        var remainingBytes = maximumCatalogUTF8Bytes
        var wasTruncated = capabilities.count > maximumInspectedCapabilities

        for capability in capabilities.prefix(maximumInspectedCapabilities) {
            guard result.count < maximumCapabilities else {
                wasTruncated = true
                break
            }
            guard !capability.id.isEmpty,
                  !capability.name.isEmpty,
                  fits(capability.id, within: maximumIDUTF8Bytes),
                  fits(capability.name, within: maximumNameUTF8Bytes)
            else {
                wasTruncated = true
                continue
            }

            let aliases = capability.aliases.prefix(maximumAliases).filter {
                !$0.isEmpty && fits($0, within: maximumAliasUTF8Bytes)
            }
            let safe = ComposerCapability(
                id: capability.id,
                name: capability.name,
                displayName: truncated(
                    capability.displayName.isEmpty ? capability.name : capability.displayName,
                    toUTF8Bytes: maximumNameUTF8Bytes
                ),
                description: truncated(
                    capability.description,
                    toUTF8Bytes: maximumDescriptionUTF8Bytes
                ),
                argumentHint: truncated(
                    capability.argumentHint,
                    toUTF8Bytes: maximumArgumentHintUTF8Bytes
                ),
                aliases: Array(aliases),
                kind: capability.kind,
                isAvailableInSkillCatalog: capability.isAvailableInSkillCatalog,
                trigger: capability.trigger,
                presentation: capability.presentation,
                availability: capability.availability.mappingReason {
                    truncated($0, toUTF8Bytes: maximumUnavailableReasonUTF8Bytes)
                }
            )
            if safe != capability { wasTruncated = true }

            let size = estimatedUTF8Bytes(of: safe)
            guard size <= remainingBytes else {
                wasTruncated = true
                break
            }
            result.append(safe)
            remainingBytes -= size
        }

        if result.count < capabilities.count { wasTruncated = true }
        return ComposerCapabilityCatalogNormalization(
            capabilities: result,
            wasTruncated: wasTruncated
        )
    }

    /// Membership arrays share the same identity and work bounds as the full catalog.
    static func boundedNames(_ names: [String]) -> Set<String> {
        Set(names.prefix(maximumInspectedCapabilities).filter {
            !$0.isEmpty && fits($0, within: maximumNameUTF8Bytes)
        })
    }

    static func acceptsPrivatePath(_ path: String) -> Bool {
        !path.isEmpty && fits(path, within: maximumPrivatePathUTF8Bytes)
    }

    private static func estimatedUTF8Bytes(of capability: ComposerCapability) -> Int {
        capability.id.utf8.count
            + capability.name.utf8.count
            + capability.displayName.utf8.count
            + capability.description.utf8.count
            + capability.argumentHint.utf8.count
            + capability.aliases.reduce(0) { $0 + $1.utf8.count }
            + (capability.unavailableReason?.utf8.count ?? 0)
    }

    private static func fits(_ value: String, within limit: Int) -> Bool {
        value.utf8.prefix(limit + 1).count <= limit
    }

    private static func truncated(_ value: String, toUTF8Bytes limit: Int) -> String {
        guard limit > 0 else { return "" }
        var result = ""
        var byteCount = 0
        for character in value {
            let bytes = String(character).utf8.count
            guard byteCount + bytes <= limit else {
                let marker = "…"
                while !result.isEmpty,
                      byteCount + marker.utf8.count > limit,
                      let last = result.popLast() {
                    byteCount -= String(last).utf8.count
                }
                return result + (marker.utf8.count <= limit ? marker : "")
            }
            result.append(character)
            byteCount += bytes
        }
        return result
    }
}

/// Optional surface implemented by transports that can advertise and semantically invoke
/// composer actions. Keeping it beside, rather than on, `ConversationStreamSession` means a
/// future provider can ship ordinary native chat before it has a discovery protocol.
@MainActor
protocol ComposerCapabilityProviding: AnyObject {
    var composerCapabilities: [ComposerCapability] { get }
    var onComposerCapabilitiesChange: (() -> Void)? { get set }

    /// Whether the transport has finished its opening command-catalog handshake.
    ///
    /// A process being able to buffer ordinary text is not the same fact. The opening composer
    /// can hand a slash-shaped first message over immediately after launch, while Claude, Codex,
    /// and ACP are still discovering the actions that decide whether that text is a native
    /// command, a refused terminal-only operation, or an ordinary prompt. Callers hold only that
    /// syntax until this answer becomes true, then resolve it against the live catalog exactly
    /// like every later message.
    var isComposerCapabilityCatalogReady: Bool { get }

    @discardableResult
    func send(
        _ invocation: ComposerInvocation,
        identifiedBy id: ConversationMessageID
    ) -> Bool
}

extension ComposerCapabilityProviding {
    /// Convenience for callers that do not already own a stable message identity.
    @discardableResult
    func send(_ invocation: ComposerInvocation) -> Bool {
        send(invocation, identifiedBy: ConversationMessageID())
    }
}

/// The leading command token is the only syntax Threading owns. Everything after it remains an
/// opaque argument string for the provider, including quotes, paths, and further slash tokens.
enum ComposerCapabilityResolver {
    /// Whether the leading token uses syntax whose meaning depends on the live catalog.
    ///
    /// Kept beside `invocation(in:capabilities:)` so the opening-message gate and the resolver
    /// cannot disagree about trimming or which prefixes Threading owns.
    static func hasLeadingTrigger(in text: String) -> Bool {
        guard let first = text.trimmingCharacters(in: .whitespacesAndNewlines).first else {
            return false
        }
        return ComposerCapability.Trigger(prefix: first) != nil
    }

    static func invocation(
        in text: String,
        capabilities: [ComposerCapability]
    ) -> ComposerInvocation? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first,
              let trigger = ComposerCapability.Trigger(prefix: first) else { return nil }

        let tokenEnd = trimmed.firstIndex(where: { $0.isWhitespace }) ?? trimmed.endIndex
        let token = String(trimmed[trimmed.index(after: trimmed.startIndex)..<tokenEnd])
        guard !token.isEmpty else { return nil }

        let capability = capabilities.first { capability in
            guard capability.trigger == trigger else { return false }
            return capability.name.caseInsensitiveCompare(token) == .orderedSame
                || capability.aliases.contains {
                    $0.caseInsensitiveCompare(token) == .orderedSame
                }
        }
        guard let capability else { return nil }

        let arguments = tokenEnd == trimmed.endIndex
            ? ""
            : String(trimmed[tokenEnd...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return ComposerInvocation(
            capability: capability,
            arguments: arguments,
            sourceText: trimmed
        )
    }
}

/// Pure query/filtering used by the AppKit completion surface. UTF-16 offsets match AppKit's
/// selection ranges, including for a prompt containing emoji after the command token.
struct ComposerCompletionQuery: Equatable {
    let trigger: ComposerCapability.Trigger
    let fragment: String
    let replacementRange: NSRange

    static func parse(_ text: String, caretUTF16Offset: Int) -> ComposerCompletionQuery? {
        let utf16Count = (text as NSString).length
        guard caretUTF16Offset >= 1, caretUTF16Offset <= utf16Count,
              let first = text.first,
              let trigger = ComposerCapability.Trigger(prefix: first) else { return nil }

        let nsText = text as NSString
        var tokenEnd = utf16Count
        for offset in 1..<utf16Count {
            let scalar = nsText.substring(with: NSRange(location: offset, length: 1))
            if scalar.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
                tokenEnd = offset
                break
            }
        }
        guard caretUTF16Offset <= tokenEnd else { return nil }

        let fragment = nsText.substring(
            with: NSRange(location: 1, length: max(0, caretUTF16Offset - 1))
        )
        return ComposerCompletionQuery(
            trigger: trigger,
            fragment: fragment,
            replacementRange: NSRange(location: 0, length: tokenEnd)
        )
    }

    func suggestions(
        from capabilities: [ComposerCapability],
        matching kind: ComposerCapability.Kind? = nil
    ) -> [ComposerCapability] {
        let needle = fragment.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let ranked = capabilities
            .filter { capability in
                guard capability.trigger == trigger else { return false }
                if let kind {
                    if kind == .skill {
                        guard capability.isAvailableInSkillCatalog else { return false }
                    } else {
                        guard capability.kind == kind else { return false }
                    }
                }
                guard !needle.isEmpty else { return true }
                let contains = searchableValues(for: capability).contains {
                    $0.folding(
                        options: [.caseInsensitive, .diacriticInsensitive],
                        locale: .current
                    ).contains(needle)
                }
                return contains || typoMatches(capability, needle: needle)
            }
            .sorted { lhs, rhs in
                let lhsScore = score(lhs, needle: needle)
                let rhsScore = score(rhs, needle: needle)
                if lhsScore != rhsScore { return lhsScore < rhsScore }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
                    == .orderedAscending
            }
        return Array(ranked.prefix(ComposerCapabilityCatalogPolicy.maximumRenderedSuggestions))
    }

    private func searchableValues(for capability: ComposerCapability) -> [String] {
        [capability.name, capability.displayName, capability.description] + capability.aliases
    }

    private func score(_ capability: ComposerCapability, needle: String) -> Int {
        guard !needle.isEmpty else { return capability.kind == .command ? 0 : 1 }
        let name = folded(capability.name)
        if name == needle { return 0 }
        if name.hasPrefix(needle) { return 1 }
        if capability.aliases.contains(where: { folded($0).hasPrefix(needle) }) { return 2 }
        if name.contains(needle) { return 3 }
        if searchableValues(for: capability).contains(where: { folded($0).contains(needle) }) {
            return 4
        }
        if typoMatches(capability, needle: needle) { return 5 }
        return 6
    }

    private func folded(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    /// Keeps a likely command visible through one insertion, deletion, or substitution. This is
    /// deliberately limited to names and aliases at three characters or more: descriptions are
    /// search prose, and typo-expanding one- and two-letter fragments would turn `/` completion
    /// into noise. The two-pointer walk is linear in the provider-bounded name length.
    private func typoMatches(_ capability: ComposerCapability, needle: String) -> Bool {
        guard needle.count >= 3 else { return false }
        return ([capability.name] + capability.aliases).contains {
            isOneEditAway(folded($0), from: needle)
        }
    }

    private func isOneEditAway(_ candidate: String, from needle: String) -> Bool {
        let candidate = Array(candidate)
        let needle = Array(needle)
        guard abs(candidate.count - needle.count) <= 1 else { return false }

        var candidateIndex = 0
        var needleIndex = 0
        var edits = 0
        while candidateIndex < candidate.count, needleIndex < needle.count {
            if candidate[candidateIndex] == needle[needleIndex] {
                candidateIndex += 1
                needleIndex += 1
                continue
            }
            edits += 1
            guard edits <= 1 else { return false }
            if candidate.count > needle.count {
                candidateIndex += 1
            } else if needle.count > candidate.count {
                needleIndex += 1
            } else {
                candidateIndex += 1
                needleIndex += 1
            }
        }
        if candidateIndex < candidate.count || needleIndex < needle.count { edits += 1 }
        return edits == 1
    }
}

private extension ComposerCapability.Trigger {
    init?(prefix: Character) {
        switch prefix {
        case "/": self = .slash
        case "$": self = .dollar
        default: return nil
        }
    }
}
