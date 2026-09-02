import AppKit

/// A label tier held to a contrast floor **against the ground it is drawn on**.
///
/// # The defect
///
/// `Design.Text`'s four tiers stated *quietness* and never stated legibility. A styled theme
/// derives them as fractions of its own label ink — `secondaryLabel` at 0.70, `tertiaryLabel` at
/// 0.45, `quaternaryLabel` at 0.25 (`AppTheme.derive`) — and under **System** they are AppKit's
/// own, which in dark mode is white at 0.55, 0.25 and **0.10**. Nothing measured any of them
/// against what they land on, so the bottom of the ladder was below the ground it was drawn on.
///
/// Read off rendered pixels, dark, System: an attachments row's timestamp and origin — the pane's
/// chronology, set in `quaternary` over the `#1E1E1E` panel — drew at **1.34:1**, and the same
/// two words on the selected row drew at **1.20:1**. WCAG AA for body text is 4.5:1 and 1.0:1 is
/// two identical colours. The words were there and could not be read.
///
/// # Why nothing caught it
///
/// The app already holds four other things to a measured floor, and not one of them was looking
/// here:
///
/// - `ThemeContrast.isLegible` checks a **terminal palette** — somebody else's document, arriving
///   from a colour picker or an agent, held to 3.0:1 so it cannot make the one surface a user
///   would have to type into to undo it unusable. It never sees the chrome's own vocabulary.
/// - `SelectionSurface.quiet` holds a selection fill back until `Design.Text.label` reads on it.
///   Tier one, and deliberately only tier one: it is the promise a *row* can keep for cells it
///   cannot reach.
/// - `Design.Status.readable` moves a status hue until it reads on the ground *and* the surface.
///   That is this rule, applied to the eight roles that happen to be hues rather than to the four
///   that carry most of the app's words.
/// - `NSColor.legible(on:)` would have caught it and cannot, and this is the load-bearing part:
///   it asks `ThemeContrast.ratio`, which reads sRGB components and **ignores alpha entirely**. A
///   tier *is* an alpha. White at 10% measures as white — 15.9:1 against `#1E1E1E` — so every
///   tier in the app passes a check that never composited it against anything.
///
/// So the defect was not a call site being careless. `Design.Text.quaternary` is exactly what a
/// timestamp should ask for; the token was the thing that was wrong.
///
/// # The rule
///
/// A tier is *the label's ink, quieter*. So a tier that fails gives back *as little of its own
/// transparency as the floor requires*, and nothing else about it moves: same ink, same hue, one
/// step less see-through. That is the mirror image of `SelectionSurface.quiet`, which walks a
/// **fill** down until the ink on it reads; this walks an **ink** up until it reads on the fill.
///
/// A tier that already reads is returned untouched, so a palette authored with care is never
/// second-guessed — the same promise `quiet` and `legible(on:)` both make.
///
/// # What the floors are, and what they cost
///
/// Two floors, both already named in this codebase, because inventing a third number would be
/// inventing a third opinion:
///
/// - **Text that is read** holds `readingRatio` — WCAG AA for body text, the ratio
///   `SelectionSurface.Defaults.minimumLabelRatio` already holds a selected row's title to.
///   `secondary` and `tertiary` are read: a subtitle, a file path, a relative time in a sentence.
/// - **The one tier that is glanced at** holds `glanceRatio` — WCAG AA for large text, and the
///   floor `ThemeContrast.minimumRatio` already holds a terminal palette to. `quaternary` carries
///   stamps, counts and marks, and it is the tier whose whole job is to sit back.
///
/// The honest cost: the ladder compresses at the bottom, and under some themes `tertiary` lands
/// close to `secondary`. That is the correct trade and not a regression, because the range it
/// compresses out of was a range in which the quietest rung was invisible. Hierarchy in this app
/// is carried by size, weight and position as much as by ink — `Design.Typography` has a caption
/// role for exactly this — and a ladder whose bottom rung cannot be read is not a hierarchy, it
/// is a hierarchy plus a blank.
///
/// A tier is also never raised past the tier above it (`ceiling`). A quiet tier that overtook a
/// louder one would have stopped being a tier, which is the one way this rule could have made the
/// vocabulary worse rather than only flatter.
@MainActor
public enum LabelLegibility {

    // MARK: - Floors

    public enum Defaults {

        /// WCAG AA for body text.
        ///
        /// The same value, and for the same reason, as
        /// `SelectionSurface.Defaults.minimumLabelRatio`: this is the app's own chrome, and the
        /// app is not entitled to the latitude it extends to a palette somebody else authored.
        public static let readingRatio: CGFloat = SelectionSurface.Defaults.minimumLabelRatio

        /// WCAG AA for large text — the floor below which text stops being text.
        ///
        /// `ThemeContrast.minimumRatio`, borrowed rather than restated: it already carries the
        /// argument for why 3.0 is the number that "rejects the unreadable, not the
        /// low-contrast", which is precisely what the quietest tier needs and all it needs.
        public static let glanceRatio: CGFloat = ThemeContrast.minimumRatio

        /// How finely the walk gives transparency back.
        ///
        /// Twenty-four, matching `SelectionSurface.Defaults.holdBackSteps`, and for the same
        /// reason: it puts the granularity under a percentage point of alpha across the widest
        /// range a tier can travel, which is finer than any authored value is meaningful to.
        public static let strengthSteps = 24

        /// Entries kept before the table is dropped and rebuilt.
        ///
        /// Every stock theme, in both appearances, at both contrast settings, for four tiers is
        /// well under this; the cap is for the case nobody predicted rather than one that is
        /// expected. See `cached`.
        public static let cacheLimit = 512
    }

    // MARK: - Holding a tier

    /// `tier` held at `floor` over every ground it can be drawn on.
    ///
    /// `ceiling` is the strength of the tier above — the point past which giving transparency
    /// back would stop this being the quieter of the two.
    ///
    /// Returns `tier` **unchanged** when it already reads on all of them.
    public static func held(
        _ tier: NSColor,
        at floor: CGFloat,
        over grounds: [NSColor],
        ceiling: CGFloat
    ) -> NSColor {
        guard let ink = tier.usingColorSpace(.sRGB), let first = grounds.first else { return tier }

        // Every ground, not the average of them: one value is drawn on all of these, so the
        // binding constraint is whichever ground the ink is nearest to in luminance, and which
        // one that is moves with the theme.
        func reads(_ candidate: NSColor) -> Bool {
            grounds.allSatisfy {
                ThemeContrast.ratio(candidate.composited(over: $0), $0) >= floor
            }
        }

        guard !reads(ink) else { return tier }

        let authored = ink.alphaComponent
        if authored < ceiling {
            let steps = Defaults.strengthSteps
            for step in 1...steps {
                let alpha = authored + (ceiling - authored) * CGFloat(step) / CGFloat(steps)
                let candidate = ink.withAlphaComponent(alpha)
                guard reads(candidate) else { continue }
                return candidate
            }
        }

        // No strength reads, so the tier's **ink** is the problem rather than its transparency —
        // a mid-grey label on a mid-grey ground, where opacity only ever walks toward a colour
        // that is itself too close to the ground. The last resort is the one `Design.Status`
        // already takes for a status hue: composite it, then keep the hue and move the lightness
        // until it reads. Chained over the grounds in turn, as `Status.readable` chains its two:
        // the result is opaque, so it means the same thing on each of them.
        return grounds.reduce(ink.composited(over: first)) { $0.legible(on: $1, ratio: floor) }
    }

    // MARK: - Grounds

    /// The opaque grounds a label set in a `Design.Text` tier can land on.
    ///
    /// Four rather than one because a tier is a single value the whole window shares, and "the
    /// whole window" spans the backdrop, the sidebar, a card and a popover — four colours that a
    /// theme is free to separate and several do. Compositing each over the backdrop first is not
    /// optional: `panel` under **System** is `labelColor` at 5%, so measuring against it raw is
    /// measuring against a colour nothing is ever drawn on.
    ///
    /// `field` and `floating` are left out deliberately — both are derived from `panel` and
    /// `elevated` unless a period theme separates them, and a fifth near-identical ground buys
    /// nothing but arithmetic.
    public static var chromeGrounds: [NSColor] {
        let backdrop = Design.Surface.ground
        return [
            backdrop,
            Design.Surface.background.composited(over: backdrop),
            Design.Surface.panel.composited(over: backdrop),
            Design.Surface.elevated.composited(over: backdrop)
        ]
    }

    // MARK: - Tiers

    /// Which rung of the ladder a caller wants.
    public enum Rung: CaseIterable {
        case secondary
        case tertiary
        case quaternary

        /// The theme role this rung reads.
        public var role: AppThemeRole {
            switch self {
            case .secondary: return .secondaryLabel
            case .tertiary: return .tertiaryLabel
            case .quaternary: return .quaternaryLabel
            }
        }

        /// The louder role it answers with under Increase Contrast — the app's existing promotion,
        /// kept because it is a different and complementary thing from holding: it keeps a value
        /// the theme actually authored in play instead of synthesising one.
        ///
        /// `secondary` has nowhere louder to go that is not `label` itself.
        public var increasedContrastRole: AppThemeRole? {
            switch self {
            case .secondary: return nil
            case .tertiary: return .secondaryLabel
            case .quaternary: return .tertiaryLabel
            }
        }
    }

    /// One of `Design.Text`'s tiers, resolved through the theme and held at its floor.
    ///
    /// Dynamic, like every other role in the palette, so a live theme switch and an appearance
    /// flip are each answered at the next draw with nobody told. The body runs inside
    /// `performAsCurrentDrawingAppearance` for the reason `SelectionSurface.dynamic` gives: the
    /// grounds underneath are themselves dynamic, and resolving them under the ambient appearance
    /// instead is how a light variant's ink ends up measured against a dark variant's ground.
    public static func tier(_ rung: Rung) -> NSColor {
        NSColor(name: NSColor.Name("threading.legible.\(rung)")) { appearance in
            // Seeded with the rung exactly as the theme states it, so a body that somehow does
            // not run leaves the palette's own answer rather than a hole. `SelectionSurface`
            // seeds with `clear` because a *fill* that fails to resolve should paint nothing; a
            // label that fails to resolve should still be a label.
            var answer = AppThemePalette.current.resolved(rung.role, appearance: appearance)
            appearance.performAsCurrentDrawingAppearance {
                answer = ladder(under: appearance)[rung]
            }
            return answer
        }
    }

    /// **The three quiet rungs held in one pass, top down.**
    ///
    /// One pass rather than three independent ones, because a rung's ceiling is the rung above it
    /// *after* it has been held, not as the theme authored it. Held independently they inverted:
    /// under System light, `secondary` passed untouched at 4.87:1 while `tertiary` — walking up
    /// toward the *label's* strength — cleared its floor at 5.03:1 and came out louder than the
    /// tier it is supposed to sit under. Amiga Workbench did the same one rung further down. The
    /// rule meant to preserve the ladder had turned it upside down, in six themes at once.
    ///
    /// Chained, each rung stops at the strength of the one above it, so the order is a property of
    /// the construction rather than something to be checked afterwards.
    ///
    /// Under **Increase Contrast** the role promotion this replaces is kept — `tertiary` answers
    /// with the `secondaryLabel` role and `quaternary` with `tertiaryLabel` — and the quiet rung's
    /// floor rises to `readingRatio`, because a user who asked for contrast has asked for that
    /// rung to be read rather than glanced at.
    public static func ladder(under appearance: NSAppearance) -> Ladder {
        let increased = Design.Accessibility.increasesContrast
        let palette = AppThemePalette.current

        func ink(_ rung: Rung) -> NSColor {
            palette.resolved(
                increased ? (rung.increasedContrastRole ?? rung.role) : rung.role,
                appearance: appearance
            )
        }

        // The identity path first: building the value key below means resolving eight dynamic
        // colours and converting each to sRGB, and a rung is asked for once per label per draw —
        // a list of a few hundred rows would pay that for every one of them, every frame, to
        // arrive at the same ladder. A theme, an appearance and a contrast setting decide it
        // together, and `AppThemeRefresh.generation` covers the one case those three miss: a
        // custom theme edited in place, which keeps its id.
        let stamp = Stamp(
            theme: palette.id,
            appearance: appearance.name,
            increased: increased,
            generation: AppThemeRefresh.generation
        )
        if let remembered = stamps[stamp] { return remembered }

        let answer = cached(
            inks: (
                label: palette.resolved(.label, appearance: appearance),
                secondary: ink(.secondary),
                tertiary: ink(.tertiary),
                quaternary: ink(.quaternary)
            ),
            grounds: chromeGrounds,
            increased: increased
        )
        if stamps.count >= Defaults.cacheLimit { stamps.removeAll(keepingCapacity: true) }
        stamps[stamp] = answer
        return answer
    }

    /// What decides a ladder, as cheap values rather than as resolved colours.
    private struct Stamp: Hashable {
        let theme: AppThemeID
        let appearance: NSAppearance.Name
        let increased: Bool
        let generation: UInt64
    }

    private static var stamps: [Stamp: Ladder] = [:]

    /// The three held rungs, by name.
    public struct Ladder {
        public let secondary: NSColor
        public let tertiary: NSColor
        public let quaternary: NSColor

        public subscript(rung: Rung) -> NSColor {
            switch rung {
            case .secondary: return secondary
            case .tertiary: return tertiary
            case .quaternary: return quaternary
            }
        }
    }

    private static func computeLadder(
        inks: (label: NSColor, secondary: NSColor, tertiary: NSColor, quaternary: NSColor),
        grounds: [NSColor],
        increased: Bool
    ) -> Ladder {
        let reading = Defaults.readingRatio
        // Contrast asked for is contrast given: the glanced-at rung stops being glanced at.
        let glance = increased ? reading : Defaults.glanceRatio

        func strength(_ colour: NSColor) -> CGFloat {
            colour.usingColorSpace(.sRGB)?.alphaComponent ?? 1
        }

        let secondary = held(
            inks.secondary, at: reading, over: grounds, ceiling: strength(inks.label)
        )
        let tertiary = held(
            inks.tertiary, at: reading, over: grounds, ceiling: strength(secondary)
        )
        let quaternary = held(
            inks.quaternary, at: glance, over: grounds, ceiling: strength(tertiary)
        )
        return Ladder(secondary: secondary, tertiary: tertiary, quaternary: quaternary)
    }

    // MARK: - Cache

    /// `computeLadder`, remembered **by value**.
    ///
    /// The correctness layer, under the identity stamp in `ladder(under:)`: two themes that
    /// resolve to the same inks over the same grounds are the same ladder however they were
    /// reached, and nothing here has to remember to invalidate anything.
    ///
    /// The walk costs up to twenty-four candidates against four grounds per rung, and a rung is
    /// asked for once per label per draw — a list of file rows resolves one a few hundred times in
    /// a scroll. It is a pure function of its inputs, so the inputs *are* the key: a theme switch,
    /// an appearance flip, an Increase Contrast toggle and an edited custom theme each produce a
    /// different one on their own, and none of them needs to remember to invalidate anything.
    private static func cached(
        inks: (label: NSColor, secondary: NSColor, tertiary: NSColor, quaternary: NSColor),
        grounds: [NSColor],
        increased: Bool
    ) -> Ladder {
        let key = Key(
            inks: [inks.label, inks.secondary, inks.tertiary, inks.quaternary]
                .flatMap(components),
            grounds: grounds.flatMap(components),
            increased: increased
        )
        if let remembered = cache[key] { return remembered }

        let answer = computeLadder(inks: inks, grounds: grounds, increased: increased)
        // Dropped whole rather than evicted one at a time: entries are keyed by value, so the
        // stale ones are the themes the user has stopped wearing, and there is no order among
        // them worth keeping. Rebuilding costs one walk per rung at the next draw.
        if cache.count >= Defaults.cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[key] = answer
        return answer
    }

    private struct Key: Hashable {
        let inks: [CGFloat]
        let grounds: [CGFloat]
        let increased: Bool
    }

    private static var cache: [Key: Ladder] = [:]

    private static func components(_ color: NSColor) -> [CGFloat] {
        guard let srgb = color.usingColorSpace(.sRGB) else { return [] }
        return [srgb.redComponent, srgb.greenComponent, srgb.blueComponent, srgb.alphaComponent]
    }

    // MARK: - Why `label` has no rung
    //
    // It is the theme's own ink on the theme's own ground, so holding it would let the design
    // system overrule a theme's primary decision — and it is the ceiling the rest of the ladder is
    // measured up to, which cannot itself be moving.

    /// Empties the table, for a test that changes a theme's contents without changing its
    /// identity. Production never needs this — see `cached` for why.
    public static func forgetCachedTiersForTesting() {
        cache.removeAll()
        stamps.removeAll()
    }
}
