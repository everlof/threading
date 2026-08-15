import AppKit
import ObjectiveC

/// A mark's size, kept true to the type it is weighed against.
///
/// # Why this is not just a constant
///
/// `Design.Symbol.control` is 11 points *because SF 13 regular's stem is 1.25 points* — the
/// number was measured as one half of a pair, and the other half is a label. The chrome's type
/// is not fixed: a theme states `material.textScale` (0.80 under Win98, 0.94 under TUI) and the
/// reader states an app text size (0.90…1.30), and between them every label in the window moves.
/// A mark written down as a literal does not, so the measured pair held at exactly one setting
/// of two dials. `Design.Symbol.Role` is the fix: the role resolves against the type currently
/// on screen rather than against the type that happened to be current when the number was typed.
///
/// That leaves the same gap `PanelContentInset` found for a rounded panel's padding. A theme
/// switch re-applies every surface and re-resolves every recorded font, because a `CGColor`, a
/// layer corner and an `NSFont` all freeze at assignment — and so does a constraint's `constant`,
/// and so does a symbol image that was rendered at a configuration. A view that *stores* a mark
/// rather than resolving one inside `draw(_:)` therefore has to be re-stated by the same sweep,
/// or a live theme switch leaves a resized label beside a frozen mark: exactly the mismatch this
/// whole change exists to remove, reintroduced one theme switch later.
///
/// # What a call site hands over
///
/// The **role**, never the number it currently resolves to. A recorded number is the bug.
@MainActor
private final class RecordedSymbolMetric {

    /// Held weakly, for the reason `PanelContentInset` holds its constraints weakly: a row that
    /// rebuilds its content must not keep re-stating the layout it replaced.
    private struct Sized {
        weak var constraint: NSLayoutConstraint?
        let role: Design.Symbol.Role
        let sign: CGFloat
        /// Air the box carries around the mark — the `+2` a settings row's leading glyph has
        /// always had. Layout, so it does not scale; the mark inside it does.
        let extra: CGFloat
    }

    /// An image view whose `symbolConfiguration` was set once. Weak for the same reason.
    private struct Configured {
        weak var view: NSImageView?
        let role: Design.Symbol.Role
        let weight: NSFont.Weight
    }

    /// An image view handed a finished render of a named symbol. Weak for the same reason.
    private struct Rendered {
        weak var view: NSImageView?
        let name: String
        let slot: CGFloat?
        let role: Design.Symbol.Role
        let weight: NSFont.Weight
    }

    private var sized: [Sized] = []
    private var configured: [Configured] = []
    private var rendered: [Rendered] = []

    func add(_ constraints: [NSLayoutConstraint], role: Design.Symbol.Role, extra: CGFloat) {
        sized.append(contentsOf: constraints.map {
            Sized(
                constraint: $0,
                role: role,
                sign: $0.constant < 0 ? -1 : 1,
                extra: extra
            )
        })
    }

    func add(_ view: NSImageView, role: Design.Symbol.Role, weight: NSFont.Weight) {
        configured.append(Configured(view: view, role: role, weight: weight))
    }

    func add(
        _ view: NSImageView,
        name: String,
        slot: CGFloat?,
        role: Design.Symbol.Role,
        weight: NSFont.Weight
    ) {
        rendered.append(
            Rendered(view: view, name: name, slot: slot, role: role, weight: weight)
        )
    }

    /// Re-states every live record at the size its role resolves to now, and reports whether
    /// anything moved — a view that is already correct must not ask for a layout pass on every
    /// appearance change.
    @discardableResult
    func restate() -> Bool {
        var moved = false

        sized = sized.filter { entry in
            guard let constraint = entry.constraint else { return false }
            let wanted = (entry.role.pointSize + entry.extra) * entry.sign
            if constraint.constant != wanted {
                constraint.constant = wanted
                moved = true
            }
            return true
        }

        configured = configured.filter { entry in
            guard let view = entry.view else { return false }
            let wanted = Design.Symbol.configuration(entry.role.pointSize, weight: entry.weight)
            if view.symbolConfiguration != wanted {
                view.symbolConfiguration = wanted
                moved = true
            }
            return true
        }

        rendered = rendered.filter { entry in
            guard let view = entry.view else { return false }
            let pointSize = entry.role.pointSize
            let image = Design.Symbol.image(
                entry.name,
                slot: entry.slot ?? pointSize,
                pointSize: pointSize,
                weight: entry.weight
            )
            if view.image?.size != image?.size {
                moved = true
            }
            view.image = image
            return true
        }

        return moved
    }
}

@MainActor private var recordedSymbolMetricKey: UInt8 = 0

@MainActor
extension NSView {

    /// Holds `constraints` at a mark's size, now and after every theme change.
    ///
    /// The call site builds and activates its own constraints with whatever constant it likes —
    /// the sign is read from what it wrote, the magnitude is replaced immediately — so
    /// `constant: Design.Symbol.control` stays readable at the point of use and stays *true*
    /// afterwards. **Author a real constant**, including on an edge that starts flush: a zero
    /// carries no sign.
    ///
    /// `plus` is the air the box keeps around the mark, which several settings rows carry as
    /// `Design.Symbol.control + 2`. It is layout rather than optics, so it does not scale: the
    /// glyph inside the box grows and shrinks, the air stays the air.
    ///
    /// Registered on the view holding the constraints, since the sweep walks the tree and
    /// re-resolves that view's font in the same pass — which is the value this one is paired to.
    func holdAtSymbolSize(
        _ constraints: [NSLayoutConstraint],
        _ role: Design.Symbol.Role,
        plus extra: CGFloat = 0
    ) {
        recordedSymbolMetric().add(constraints, role: role, extra: extra)
        restateRecordedSymbolMetric()
    }

    /// Re-states what `holdAtSymbolSize` and `holdSymbolConfiguration` recorded. Called by the
    /// app-theme sweep for every view it repaints, beside the font these marks are weighed
    /// against.
    func reapplyRecordedSymbolSize() {
        guard let recorded = objc_getAssociatedObject(
            self,
            &recordedSymbolMetricKey
        ) as? RecordedSymbolMetric else { return }
        if recorded.restate() { needsLayout = true }
    }

    fileprivate func recordedSymbolMetric() -> RecordedSymbolMetric {
        if let existing = objc_getAssociatedObject(
            self,
            &recordedSymbolMetricKey
        ) as? RecordedSymbolMetric {
            return existing
        }
        let recorded = RecordedSymbolMetric()
        objc_setAssociatedObject(
            self,
            &recordedSymbolMetricKey,
            recorded,
            .OBJC_ASSOCIATION_RETAIN
        )
        return recorded
    }

    fileprivate func restateRecordedSymbolMetric() {
        if let recorded = objc_getAssociatedObject(
            self,
            &recordedSymbolMetricKey
        ) as? RecordedSymbolMetric, recorded.restate() {
            needsLayout = true
        }
    }
}

@MainActor
extension NSImageView {

    /// Configures this view's symbol at a mark's size, now and after every theme change.
    ///
    /// The replacement for a bare `symbolConfiguration = Design.Symbol.configuration(…)`, which
    /// bakes the size the theme happened to be showing when the view was built.
    func holdSymbolConfiguration(
        _ role: Design.Symbol.Role,
        weight: NSFont.Weight = .medium
    ) {
        recordedSymbolMetric().add(self, role: role, weight: weight)
        restateRecordedSymbolMetric()
    }

    /// Shows `name` at a mark's size, re-rendered after every theme change.
    ///
    /// The `NSImageView` twin of `GlyphView.setSymbol`, for the handful of views outside the
    /// design system that hold a plain image view. Prefer `GlyphView` in anything new — it
    /// draws on the pixel grid and takes the host's ink — but a stale render is the same bug in
    /// either, so both have the same answer.
    func holdSymbol(
        _ name: String,
        slot: CGFloat? = nil,
        role: Design.Symbol.Role = .control,
        weight: NSFont.Weight = .medium
    ) {
        recordedSymbolMetric().add(
            self,
            name: name,
            slot: slot,
            role: role,
            weight: weight
        )
        restateRecordedSymbolMetric()
    }
}
