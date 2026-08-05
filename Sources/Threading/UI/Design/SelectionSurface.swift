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
struct SelectionSurface {

    /// What to paint.
    ///
    /// The theme's `selection` role at whatever strength this surface is entitled to — translucent
    /// as authored, so it composites over whatever it lands on rather than replacing it.
    let fill: NSColor

    /// The opaque colour painting `fill` actually produces.
    ///
    /// What `ink` was measured against, and what anything else drawn inside the selection must
    /// measure against too — a glyph, a badge, a second fill.
    let ground: NSColor

    /// The label tiers that read on `ground`.
    let ink: Design.Ink
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
    static func stated(over hostGround: NSColor) -> SelectionSurface {
        let fill = authored
        let ground = fill.composited(over: hostGround)
        return SelectionSurface(fill: fill, ground: ground, ink: Design.Text.on(ground))
    }

    /// The same fill **held back until the chrome's own label reads on it**, ink untouched.
    ///
    /// For a surface whose contents ink themselves and cannot be told. A theme that authored a
    /// selection its labels already read on is returned unchanged and never second-guessed, which
    /// is every stock theme but two: only Windows 98 (0.9) and Platinum (0.88) are held back, and
    /// only far enough to clear `Defaults.minimumLabelRatio`.
    ///
    /// Held back **toward the ground** rather than moved along its own lightness the way
    /// `NSColor.legible(on:)` moves an ink. A selection is not a colour anyone reads; it is a colour
    /// that says *this row, not that one*, and the honest way to say less is to say it more
    /// quietly. Moving its lightness instead would keep the strength and lose the hue, which under
    /// Windows 98 turns navy into a pale blue nobody chose.
    static func quiet(over hostGround: NSColor) -> SelectionSurface {
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

    /// `stated`, as **dynamic colours**, for a surface that states its colours once and never
    /// rebuilds them.
    ///
    /// `NSTextView.selectedTextAttributes` is set at construction and read by TextKit for the life
    /// of the view, and a field editor is lent out by AppKit already built. Neither redraws through
    /// a call site that could resolve a colour again, so the resolution moves into the colours
    /// themselves and a live theme switch is answered at the next draw with nobody told.
    ///
    /// `hostGround` is a closure for the same reason: the ground under a text view moves when the
    /// theme does, and a ground captured once would pin the ink to the theme the view was built in.
    static func dynamic(
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
                    colour = tier(stated(over: hostGround()))
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

    private static func readsLabel(on ground: NSColor) -> Bool {
        ThemeContrast.ratio(Design.Text.label, ground) >= Defaults.minimumLabelRatio
    }

    enum Defaults {

        /// WCAG AA for body text.
        ///
        /// Deliberately not `ThemeContrast.minimumRatio`, which is 3.0 and answers a different
        /// question: that floor exists to refuse an *unreadable terminal palette* a user typed in,
        /// where holding a deliberate aesthetic to body-text contrast would reject Solarized. A
        /// row's title is body text in the app's own chrome, and the app is not entitled to the
        /// latitude it extends to somebody else's palette.
        static let minimumLabelRatio: CGFloat = 4.5

        /// How finely the hold-back walks down from the authored strength. Twenty-four steps put
        /// the granularity below a percentage point of alpha, which is finer than any theme's
        /// authored value is meaningful to.
        static let holdBackSteps = 24
    }
}
