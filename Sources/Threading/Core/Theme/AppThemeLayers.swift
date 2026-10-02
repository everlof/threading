import AppKit

// MARK: - App Theme Layers

/// The four layers a theme can change, from its colours to its personality.
///
/// "Make a theme" means "change the colours" almost everywhere the word is used — editors,
/// terminals, design tokens — so an agent asked for one recolours and stops, even when the person
/// named a whole world. A theme that stops at the palette reads as the same app in a new tint: the
/// failure the stock catalogue's silhouette gate refuses (`testEveryStyleHasItsOwnSilhouette`).
/// The agent path has no such gate, on purpose — a recolour is sometimes exactly what was asked —
/// so it reports instead. Every create and update names the layers the theme states, which makes
/// stopping at colours a choice the agent can see rather than the default it drifted into.
enum AppThemeLayer: String, CaseIterable, Sendable {
    /// The roles and the paired terminal palette. Every variant has one.
    case palette
    /// Shape and surface: radii, borders, bevel, shadows, type, control anatomy, the backdrop and
    /// the sidebar's ground.
    case material
    /// The window frame, drawn by the theme instead of macOS.
    case chrome
    /// Personality: sounds, the switch-in transition, the theme's own words, sprites, the mascot
    /// and the brand row's logo, wordmark and motion.
    case character

    /// What the layer is, in the words an agent reads in a tool result.
    var gloss: String {
        switch self {
        case .palette: return "colours"
        case .material: return "shape, type and controls"
        case .chrome: return "the theme's own window frame"
        case .character: return "sounds, a transition, words, a mascot"
        }
    }

    /// Whether `variant` states anything in this layer beyond the app's default.
    func isStated(in variant: AppTheme.Variant) -> Bool {
        switch self {
        case .palette:
            return true
        case .material:
            return variant.material != .system
                || variant.sidebar?.background != nil
                || variant.sidebar?.navigatorWell != nil
                || variant.sidebar?.brand?.band != nil
        case .chrome:
            return variant.chrome != nil
        case .character:
            let brand = variant.sidebar?.brand
            return variant.transition != nil
                || variant.moments != nil
                || variant.words != nil
                || !variant.sprites.isEmpty
                || variant.sidebar?.mascot != nil
                || brand.map { $0.logo != .mark || $0.title != nil || $0.motion != nil || $0.dockIcon }
                    == true
        }
    }

    /// Whether this layer reads the same in `before` and `after`.
    func isUnchanged(from before: AppTheme.Variant, to after: AppTheme.Variant) -> Bool {
        switch self {
        case .palette:
            return before.roles == after.roles && before.terminalPalette == after.terminalPalette
        case .material:
            return before.material == after.material
                && before.sidebar?.background == after.sidebar?.background
                && before.sidebar?.navigatorWell == after.sidebar?.navigatorWell
                && before.sidebar?.brand?.band == after.sidebar?.brand?.band
        case .chrome:
            return before.chrome == after.chrome
        case .character:
            let was = before.sidebar?.brand
            let now = after.sidebar?.brand
            return before.transition == after.transition
                && before.moments == after.moments
                && before.words == after.words
                && before.sprites == after.sprites
                && before.sidebar?.mascot == after.sidebar?.mascot
                && was?.logo == now?.logo
                && was?.title == now?.title
                && was?.motion == now?.motion
                && was?.dockIcon == now?.dockIcon
        }
    }
}

// MARK: - App Theme Layer Report

/// What one create or update did to each layer, and what the agent that made it should hear.
struct AppThemeLayerReport: Equatable {

    enum State: Equatable {
        /// This call made the layer read differently.
        case changed
        /// Stated, but as it already was: inherited from the base, or kept from before.
        case kept
        /// Nothing stated; the app's default stands.
        case absent
    }

    /// A create inherits from its base and an update keeps what the theme had. Only the wording
    /// of a kept layer, and the colours-only note a create can earn, differ between the two.
    enum Origin: Equatable {
        case base(name: String)
        case previous
    }

    let states: [AppThemeLayer: State]
    let origin: Origin

    /// A layer is stated when any variant states it, and changed when this call changed it in
    /// any variant. A variant the starting theme lacks is compared with the one the editor patched
    /// from in its place, and against nothing when the start is System, which stores no variants.
    init(theme: AppTheme, startingFrom before: AppTheme, origin: Origin) {
        let fallback = before.availableVariants.first.flatMap { before.variant($0) }
        var states: [AppThemeLayer: State] = [:]
        for layer in AppThemeLayer.allCases {
            var stated = false
            var changed = false
            for kind in theme.availableVariants {
                guard let after = theme.variant(kind) else { continue }
                stated = stated || layer.isStated(in: after)
                if let prior = before.variant(kind) ?? fallback {
                    changed = changed || !layer.isUnchanged(from: prior, to: after)
                } else {
                    changed = changed || layer.isStated(in: after)
                }
            }
            states[layer] = !stated ? .absent : changed ? .changed : .kept
        }
        self.states = states
        self.origin = origin
    }

    /// The report as it is appended to the tool result: a line naming every layer's state, then
    /// what to do about the layers that are missing.
    var text: String {
        "\(summaryLine)\n\(guidance)"
    }

    // MARK: - Private Methods

    private static let layersBeyondPalette: [AppThemeLayer] = [.material, .chrome, .character]

    private func state(of layer: AppThemeLayer) -> State {
        states[layer] ?? .absent
    }

    private var summaryLine: String {
        let parts = AppThemeLayer.allCases.map { layer -> String in
            switch state(of: layer) {
            case .changed:
                return "\(layer.rawValue): changed"
            case .kept:
                switch origin {
                case .base(let name): return "\(layer.rawValue): from \(name)"
                case .previous: return "\(layer.rawValue): kept"
                }
            case .absent:
                return "\(layer.rawValue): none"
            }
        }
        return "Layers — \(parts.joined(separator: ", "))."
    }

    private var guidance: String {
        let missing = Self.layersBeyondPalette.filter { state(of: $0) == .absent }
        var sentences: [String] = []
        if missing.count == Self.layersBeyondPalette.count {
            sentences.append(
                "Colours only: the default shape, the native macOS frame and no character, so "
                    + "this reads as the app recoloured. That is right when colours are what the "
                    + "person asked for. If they named a look or a world — an operating system, a "
                    + "game, a film, an era, a mood — the other three layers are most of it: "
                    + Self.glossed(missing) + ". Add them with update_app_theme."
            )
        } else if !missing.isEmpty {
            sentences.append(
                "Not stated: " + Self.glossed(missing) + ". Leave them out only when the person "
                    + "asked for less than a whole look; otherwise add them with update_app_theme."
            )
        } else {
            sentences.append("All four layers are stated.")
        }
        if let inherited = inheritedNote { sentences.append(inherited) }
        sentences.append("Check it with preview_app_theme.")
        return sentences.joined(separator: " ")
    }

    /// A create that changed only the colours wears its base's shape, frame and character,
    /// which can pass for having built them. Saying whose they are keeps that visible.
    private var inheritedNote: String? {
        guard case .base(let name) = origin, state(of: .palette) == .changed else { return nil }
        let beyond = Self.layersBeyondPalette.map { state(of: $0) }
        guard !beyond.contains(.changed) else { return nil }
        let kept = Self.layersBeyondPalette.filter { state(of: $0) == .kept }
        guard !kept.isEmpty else { return nil }
        return "Only the colours are new; the "
            + Self.joined(kept.map(\.rawValue)) + " \(kept.count == 1 ? "is" : "are") \(name)'s."
    }

    private static func glossed(_ layers: [AppThemeLayer]) -> String {
        joined(layers.map { "\($0.rawValue) (\($0.gloss))" })
    }

    /// "a", "a and b", "a, b and c" — fixed English, because the reader is an agent and the
    /// wording must not move with the user's locale.
    private static func joined(_ items: [String]) -> String {
        guard let last = items.last else { return "" }
        let head = items.dropLast()
        return head.isEmpty ? last : head.joined(separator: ", ") + " and " + last
    }
}
