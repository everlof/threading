import AppKit

/// A selection's **fill and the ink that reads on it**, as one value.
///
/// # Why this type exists
///
/// The theme states `selection` as a fill and nothing else, and every consumer picked its own
/// foreground. Those two decisions are made in different files by different people, and nothing
/// checked that they agree — so they drifted apart in *both* directions at once:
///
/// - A menu row and a list row filled with `selection` and drew `Design.Text.label` over it.
///   Under Windows 98 that is `#000000` on a 90%-opaque navy: **1.47:1**, which is not low
///   contrast but no contrast. Platinum's 88% blue managed 3.70:1, also below AA.
/// - The audit row and the completion row filled with `selection` and drew `Design.Text.selected`
///   over it — an ink measured against `Surface.accent`, which is the *opaque* accent and not
///   what either of them painted. Under Christmas, whose selection is the accent at 20%, that is
///   white on pale pink: **1.76:1**.
///
/// Both are the same bug, and it is not a bug either call site can be blamed for: the fill was
/// available on its own, so taking it on its own was the obvious thing to do. This type removes
/// that option. `Design.Surface` no longer vends the role — `scripts/check_architecture_boundaries.sh`
/// fails a build that reads `.selection` from the palette anywhere but here — so the only way to
/// obtain the fill is to obtain the ink with it, already measured against the fill *as composited
/// over the ground it is painted on*.
///
/// # The two strengths, and why a surface does not choose freely
///
/// `stated` paints the theme's own value and inverts its ink to suit. `quiet` holds the value back
/// until the chrome's ordinary label reads on it, and leaves the ink alone. Which one a surface
/// takes is decided by one question — **can it reach the ink of everything drawn inside it?**
///
/// A text run can: the selection and its foreground are two attributes on the same range. A list
/// row cannot: `ThemedTableRowView` draws the fill and the *cells* are feature code, built by nine
/// different view controllers, inking themselves from `Design.Text` as any view on the chrome's
/// ground should. Telling all of them would be a second set of inks in every list in the app,
/// which is exactly the work `ThemedTableRowView`'s own documentation says a themed list does not
/// have to do. So the row takes the strength that keeps that promise true.
///
/// A run of selected text takes `distinct`, which is `stated` held to a second promise: that the
/// fill can be *seen* on its ground, not only that the ink can be read on the fill.
public struct SelectionSurface {

    /// What to paint.
    ///
    /// The theme's `selection` role at whatever strength this surface is entitled to — translucent
    /// as authored, so it composites over whatever it lands on rather than replacing it.
    public let fill: NSColor

    /// The opaque colour painting `fill` actually produces.
    ///
    /// What `ink` was measured against, and what anything else drawn inside the selection must
    /// measure against too — a glyph, a badge, a second fill.
    public let ground: NSColor

    /// The label tiers that read on `ground`.
    public let ink: Design.Ink
}

// MARK: - Strengths

@MainActor
extension SelectionSurface {

    /// The theme's selection **as authored**, with the ink measured against it.
    ///
    /// For a surface that inks its own contents, and therefore may paint at full strength: a run
    /// of selected text, a row that draws its own title. Under Windows 98 this is the authentic
    /// navy with white ink on it; under Christmas it is the pale wash with the ordinary near-black.
    /// Neither is a constant, and neither call site has to know which it got.
    public static func stated(over hostGround: NSColor) -> SelectionSurface {
        inked(authored, over: hostGround)
    }

    /// The same fill **held back until the chrome's own label reads on it**, ink untouched.
    ///
    /// For a surface whose contents ink themselves and cannot be told. A theme that authored a
    /// selection its labels already read on is returned unchanged and never second-guessed, which
    /// is every stock theme but two: only Windows 98's solid navy and Platinum (0.88) are held
    /// back, and
    /// only far enough to clear `Defaults.minimumLabelRatio`.
    ///
    /// Held back **toward the ground** rather than moved along its own lightness the way
    /// `NSColor.legible(on:)` moves an ink. A selection is not a colour anyone reads; it is a colour
    /// that says *this row, not that one*, and the honest way to say less is to say it more
    /// quietly. Moving its lightness instead would keep the strength and lose the hue, which under
    /// Windows 98 turns navy into a pale blue nobody chose.
    public static func quiet(over hostGround: NSColor) -> SelectionSurface {
        let full = stated(over: hostGround)
        guard !readsLabel(on: full.ground) else { return full }

        // Alpha 0 is the bare ground, where the chrome's label reads by definition — so the walk
        // down from the authored strength always terminates, and there is no monotonicity to
        // assume: the first strength that passes is simply taken.
        let authored = Self.authored.usingColorSpace(.sRGB) ?? Self.authored
        let steps = Defaults.holdBackSteps
        for step in 1...steps {
            let alpha = authored.alphaComponent * CGFloat(steps - step) / CGFloat(steps)
            let fill = authored.withAlphaComponent(alpha)
            let ground = fill.composited(over: hostGround)
            guard readsLabel(on: ground) else { continue }
            return SelectionSurface(fill: fill, ground: ground, ink: Design.Ink.chrome)
        }

        // No strength kept the promise, which means the chrome's label does not read on the
        // *bare* ground either — reachable, because `resolvedGround` can walk out to a terminal
        // pane's backdrop, a colour the app theme does not own. The promise is already broken by
        // then, so this hands back the theme's own value with the ink that does read on it. A
        // clear fill would be the tidier-looking answer and the wrong one: a selected row that
        // paints nothing has stopped saying which row is selected, which is its whole job.
        return full
    }

    /// `stated`, **raised until it can be told from the ground it is painted on**.
    ///
    /// For a run of selected text. `stated` promises that the ink reads on the fill and nothing
    /// about the fill reading on its ground — and a highlight that cannot be seen has stopped
    /// saying what is selected, however legible the text inside it stays. Pure's night selection
    /// is `#292929`, right for a row over its black sidebar and ΔE 11.9 over the `#101010` well of
    /// the browser's address field: a URL selected in a focused field looked like the system's
    /// *inactive* highlight, white text on a grey hardly anyone could find.
    ///
    /// Raised in the theme's own terms first: a translucent wash gains its own strength, keeping
    /// the hue the theme chose. Only a fill still too close at full strength moves, toward
    /// whichever pole is further from the ground — lighter on a dark field, darker on paper. A
    /// theme whose selection already stands apart is returned exactly as `stated` answers it.
    public static func distinct(over hostGround: NSColor) -> SelectionSurface {
        let full = stated(over: hostGround)
        guard !standsApart(full.ground, from: hostGround) else { return full }

        let authored = Self.authored.usingColorSpace(.sRGB) ?? Self.authored
        let steps = Defaults.raiseSteps

        if authored.alphaComponent < 1 {
            for step in 1...steps {
                let alpha = authored.alphaComponent
                    + (1 - authored.alphaComponent) * CGFloat(step) / CGFloat(steps)
                let fill = authored.withAlphaComponent(alpha)
                guard standsApart(fill.composited(over: hostGround), from: hostGround) else { continue }
                return inked(fill, over: hostGround)
            }
        }

        // The pole is chosen as the far end from the ground, so it sits at least half the
        // lightness range away from any ground at all — the last step always passes, and the
        // first step that does is simply taken.
        let opaque = authored.withAlphaComponent(1)
        let lightens = ThemeContrast.ratio(.white, hostGround) >= ThemeContrast.ratio(.black, hostGround)
        var fill = opaque
        for step in 1...steps {
            let amount = CGFloat(step) / CGFloat(steps)
            fill = opaque.lightened(by: lightens ? amount : -amount)
            if standsApart(fill.composited(over: hostGround), from: hostGround) { break }
        }
        return inked(fill, over: hostGround)
    }

    /// `distinct`, as **dynamic colours**, for a surface that states its colours once and never
    /// rebuilds them.
    ///
    /// `NSTextView.selectedTextAttributes` is set at construction and read by TextKit for the life
    /// of the view, and a field editor is lent out by AppKit already built. Neither redraws through
    /// a call site that could resolve a colour again, so the resolution moves into the colours
    /// themselves and a live theme switch is answered at the next draw with nobody told.
    ///
    /// `hostGround` is a closure for the same reason: the ground under a text view moves when the
    /// theme does, and a ground captured once would pin the ink to the theme the view was built in.
    public static func dynamic(
        over hostGround: @escaping @MainActor () -> NSColor
    ) -> SelectionSurface {
        func resolving(
            _ name: String,
            _ tier: @escaping @MainActor (SelectionSurface) -> NSColor
        ) -> NSColor {
            NSColor(name: NSColor.Name("threading.selection.\(name)")) { appearance in
                var colour = NSColor.clear
                // Resolved in the appearance being asked about rather than the ambient one: the
                // roles underneath are dynamic, and reading them under the wrong appearance is how
                // a light variant's ink ends up measured against a dark variant's ground.
                //
                // The isolation is *inherited* rather than asserted, which is the shape every
                // dynamic role in the app already uses (`AppThemePalette.color`,
                // `Design.Surface.searchMatch`). `MainActor.assumeIsolated` would read as more
                // careful and be strictly worse: a provider reached off the main thread would
                // trap where the rest of the palette merely answers.
                appearance.performAsCurrentDrawingAppearance {
                    colour = tier(distinct(over: hostGround()))
                }
                return colour
            }
        }

        return SelectionSurface(
            fill: resolving("fill") { $0.fill },
            ground: resolving("ground") { $0.ground },
            ink: Design.Ink(
                base: resolving("ink.base") { $0.ink.base },
                label: resolving("ink.label") { $0.ink.label },
                secondary: resolving("ink.secondary") { $0.ink.secondary },
                tertiary: resolving("ink.tertiary") { $0.ink.tertiary },
                quaternary: resolving("ink.quaternary") { $0.ink.quaternary }
            )
        )
    }

    // MARK: - Private

    /// The palette's `selection` role. **The one read of it in the app** — see the type's note.
    private static var authored: NSColor { AppThemePalette.color(.selection) }

    /// `fill` over `hostGround`, with the ink measured against what that paints.
    private static func inked(_ fill: NSColor, over hostGround: NSColor) -> SelectionSurface {
        let ground = fill.composited(over: hostGround)
        return SelectionSurface(fill: fill, ground: ground, ink: Design.Text.on(ground))
    }

    private static func readsLabel(on ground: NSColor) -> Bool {
        ThemeContrast.ratio(Design.Text.label, ground) >= Defaults.minimumLabelRatio
    }

    private static func standsApart(_ selection: NSColor, from ground: NSColor) -> Bool {
        ThemeContrast.perceptualDistance(selection, ground) >= Defaults.minimumTextDistance
    }

    public enum Defaults {

        /// WCAG AA for body text.
        ///
        /// Deliberately not `ThemeContrast.minimumRatio`, which is 3.0 and answers a different
        /// question: that floor exists to refuse an *unreadable terminal palette* a user typed in,
        /// where holding a deliberate aesthetic to body-text contrast would reject Solarized. A
        /// row's title is body text in the app's own chrome, and the app is not entitled to the
        /// latitude it extends to somebody else's palette.
        public static let minimumLabelRatio: CGFloat = 4.5

        /// How far apart, as CIE76 ΔE, a run of selected text stands from the ground under it.
        ///
        /// Calibrated against the platform rather than picked: on macOS 26 a focused text view's
        /// highlight stands ΔE 28.1 (light) and 39.5 (dark) from the text background, and an
        /// unfocused one 12.2 and 18.5. The floor sits above both inactive values and below both
        /// active ones, so a themed selection may be as quiet as the system's quietest *active*
        /// highlight and never reads as an inactive one. `ThemeContrast.minimumBoldDistance` (15)
        /// answers "two inks, not one", which is too low a bar for a mark whose only job is to be
        /// seen.
        public static let minimumTextDistance: CGFloat = 24

        /// How finely the hold-back walks down from the authored strength. Twenty-four steps put
        /// the granularity below a percentage point of alpha, which is finer than any theme's
        /// authored value is meaningful to.
        public static let holdBackSteps = 24

        /// How finely `distinct` walks up — first through alpha, then toward the pole. The same
        /// granularity as the hold-back, for the same reason.
        public static let raiseSteps = 24
    }
}
