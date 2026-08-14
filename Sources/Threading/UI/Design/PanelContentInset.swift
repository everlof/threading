import AppKit
import ObjectiveC

/// The padding a rounded panel holds its content in, kept fitted to the corner underneath it.
///
/// # Why this is not just a constant
///
/// `Design.Spacing.inset(inside:)` answers what the padding *should* be, and a constraint built
/// with it is right for exactly as long as the theme that was current when the view was built.
/// A theme switch re-applies every surface — `AppThemeRefresh` exists because a `CGColor` and a
/// layer corner both freeze at assignment — but a constraint's `constant` is frozen the same way
/// and nothing was re-stating it. Switching from a 10pt-cornered style to Botanical's 40 left
/// every card wearing the new silhouette and the old padding, which is the fault this token was
/// added to fix, arrived at by a different route.
///
/// So the padding is recorded beside the surface and re-fitted by the same sweep that re-applies
/// the corner. The two cannot drift apart, because one pass owns both.
///
/// # What a call site hands over
///
/// The constraints it already wrote, with the signs it already chose. Only the *magnitude* is
/// ours: a leading edge authored `+inset` stays positive and a trailing edge authored `-inset`
/// stays negative, so a caller keeps its own layout grammar and this stays a padding rule rather
/// than a layout engine.
private final class RecordedContentInset {

    /// Held weakly. A constraint is retained by the view hierarchy for as long as it is active,
    /// and a card that rebuilds its content must not be kept re-fitting the constraints of a
    /// layout that no longer exists.
    private struct Entry {
        weak var constraint: NSLayoutConstraint?
        let radius: SurfaceRadius
        let sign: CGFloat
        /// What this edge pads by when the corner asks for nothing.
        let base: CGFloat
        /// Padding the content already provides on this edge, which the panel does not pay
        /// twice — see `holdAtContentInset(_:inside:from:less:)`.
        let reduction: CGFloat
    }

    private var entries: [Entry] = []

    func add(
        _ constraints: [NSLayoutConstraint],
        radius: SurfaceRadius,
        base: CGFloat,
        reduction: CGFloat
    ) {
        entries.append(contentsOf: constraints.map {
            Entry(
                constraint: $0,
                radius: radius,
                sign: $0.constant < 0 ? -1 : 1,
                base: base,
                reduction: reduction
            )
        })
    }

    /// Re-states every live constraint at the current theme's fitted inset, and reports whether
    /// any of them moved — a card that is already correct must not ask for a layout pass on
    /// every appearance change.
    @MainActor
    func refit() -> Bool {
        var moved = false
        entries = entries.filter { entry in
            guard let constraint = entry.constraint else { return false }
            let inset = Design.Spacing.inset(inside: entry.radius, from: entry.base)
            let wanted = max(0, inset - entry.reduction) * entry.sign
            if constraint.constant != wanted {
                constraint.constant = wanted
                moved = true
            }
            return true
        }
        return moved
    }
}

@MainActor private var recordedContentInsetKey: UInt8 = 0

extension NSView {

    /// Holds `constraints` at this panel's fitted content inset, now and after every theme change.
    ///
    /// The call site builds and activates its own constraints with whatever constant it likes —
    /// the sign is read from what it wrote, the magnitude is replaced immediately, so
    /// `constant: Design.Spacing.inset` and `constant: -Design.Spacing.inset` are both fine to
    /// author and stay readable at the point of use. **Author a real constant**, including on an
    /// edge that starts flush: a zero carries no sign, and would take a trailing edge outwards.
    ///
    /// Registered on the view holding the constraints — usually the panel that wears the corner,
    /// since the sweep walks the tree and re-applies its surface in the same pass.
    ///
    /// `from` is what these edges pad by when the corner asks for nothing — a card's `inset`
    /// unless the surface has measured its own, the way a chat bubble is padded by `medium`. The
    /// corner can only push content further in, never pull it back.
    ///
    /// `less` is padding the content already carries on that edge, which the panel must not pay
    /// twice. A settings card stacks rows that pad themselves 10pt vertically: the *card* owes
    /// only what the corner asks beyond that, or the first row would sit 30pt down a card whose
    /// rows are 10pt apart.
    func holdAtContentInset(
        _ constraints: [NSLayoutConstraint],
        inside radius: SurfaceRadius = .panel,
        from base: CGFloat = Design.Spacing.inset,
        less reduction: CGFloat = 0
    ) {
        let recorded: RecordedContentInset
        if let existing = objc_getAssociatedObject(
            self,
            &recordedContentInsetKey
        ) as? RecordedContentInset {
            recorded = existing
        } else {
            recorded = RecordedContentInset()
            objc_setAssociatedObject(
                self,
                &recordedContentInsetKey,
                recorded,
                .OBJC_ASSOCIATION_RETAIN
            )
        }
        recorded.add(constraints, radius: radius, base: base, reduction: reduction)
        _ = recorded.refit()
    }

    /// Re-fits what `holdAtContentInset` recorded. Called by the app-theme sweep for every view
    /// it repaints, beside the surface whose corner these insets answer to.
    func reapplyRecordedContentInset() {
        guard let recorded = objc_getAssociatedObject(
            self,
            &recordedContentInsetKey
        ) as? RecordedContentInset else { return }
        if recorded.refit() { needsLayout = true }
    }
}
