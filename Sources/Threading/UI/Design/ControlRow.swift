import AppKit

/// How tall the controls in a row stand, which is the one measurement a row exists to state.
@MainActor
public enum ControlRowScale {

    /// Compact controls beside each other — a mode chip, its actions, a caption. The app's row.
    ///
    /// The height is the material's own `choiceHeight` rather than a constant of ours, because
    /// the chooser is the tallest thing a compact row holds *and* the only member a theme
    /// actually authors: Platinum states 16, OpenStep 18, Win98 21, Tiger 22, System 26, and a
    /// theme written through the MCP tools may state anything from 14 to 44. A row that fixed
    /// its height would be right under exactly one theme and visibly wrong under the rest.
    case compact

    /// A row that also holds a single-line text field, which is taller than a chip on purpose —
    /// see `Design.Size.fieldHeight`.
    case field

    public var height: CGFloat {
        switch self {
        case .compact: Design.Size.choiceHeight
        case .field: Design.Size.fieldHeight
        }
    }
}

/// What a row tells its members about itself.
///
/// **Only a row can make one.** The initializer is fileprivate, so a height reaches a control
/// from the row it sits in and from nowhere else. That is the whole mechanism: a call site
/// cannot hand a control a size, so it cannot hand it a size that disagrees with its neighbours'.
@MainActor
public struct ControlRowMetrics {

    /// The height every member of the row shares.
    public let height: CGFloat

    /// The slot a glyph is drawn in inside a control of that height.
    public let glyphSlot: CGFloat

    /// The role that mark's optical size comes from.
    ///
    /// The role rather than the size it currently resolves to: a promoted member stores what it
    /// adopted, and a mark's optical size follows the chrome's type scale, so a stored number
    /// would be the size of the theme that promoted it (`Design.Symbol.Role`).
    public let glyphRole: Design.Symbol.Role

    /// The optical size that mark is configured at, now.
    public var glyphPointSize: CGFloat { glyphRole.pointSize }

    fileprivate init(scale: ControlRowScale) {
        height = scale.height
        glyphSlot = Design.Symbol.slot(inControlOfHeight: height)
        glyphRole = Design.Symbol.role(forSlot: glyphSlot)
    }
}

/// A control that can stand as a peer in a control row: it takes its height from the row rather
/// than stating one of its own.
///
/// Conformance is what makes a control *promotable*. A view that does not conform is still
/// welcome in a row — a caption is the usual one — it simply keeps whatever size it has, which
/// is right for text and wrong for anything with a surface.
@MainActor
public protocol ControlRowMember: NSView {
    /// Adopts the row's measurements. Called when the row is built, whenever its membership
    /// changes, and again on every theme change, because the compact height is the theme's.
    func adopt(_ metrics: ControlRowMetrics)
}

/// A row of controls that belongs to content: a leading run at one edge, a trailing run at the
/// other, one shared height and one centreline.
///
/// **This exists because "a chip and two buttons in a row" was assembled by hand four times — the
/// compare surface, the Compare tab, the browser comparison, Git Review — and came out differently
/// every time.** Each host reached for an `NSStackView`, chose a spacing,
/// and let every control state its own height — so the Compare tab put a 26pt chip beside two
/// 20pt buttons and pushed both against the chip instead of the pane's trailing edge, which is
/// what it was reported as: *the buttons next to Wipe feel unbalanced and too small*. The
/// spot fix is two numbers. What was actually wrong is that nothing in the app owned the
/// question, so:
///
/// - **The height is the row's, not the member's.** Every `ControlRowMember` in the row is told
///   the row's metrics and resizes to them, including its glyph. A caller cannot pick the wrong
///   size for a button because a caller never picks one — see `ControlRowMetrics`.
/// - **The height is the theme's.** A chip is `choiceHeight` tall and an icon button was a fixed
///   20, so the mismatch changed sign across the styles: 26-vs-20 under System, 16-vs-20 under
///   Platinum, and 44-vs-20 under a theme that authors the maximum. Adoption re-runs on
///   `AppThemeDidChange`, so a live switch keeps the row level.
/// - **Slack is a spring, not a wish.** One run of members with a stretching view between the
///   two halves, so the leading members hold one edge and the trailing ones the other. The
///   Compare tab had been holding its actions out with an *empty label* set to hug loosely,
///   which is not a spring: the label collapsed and the actions huddled against the chip.
/// - **The outer edges align by interaction surface.** A chip is ink-only at rest, but its frame
///   is also the hover, menu and keyboard-focus plate. Pulling that frame outside the row to put
///   only the resting text on the margin makes the control visibly break the pane margin the
///   instant it is used. The full stable silhouette stays inside the row instead; content ink
///   gets the component's own padding, just like the content inside the cards below it.
///
/// Nothing is drawn here. The row is geometry: the members ink themselves, and the ground under
/// it is the host's.
public final class ControlRowView: NSView {

    // MARK: - Geometry

    private enum Layout {
        /// Between sibling controls. Frame to frame, deliberately: two controls side by side are
        /// two *surfaces*, and correcting their gap by ink the way the outer margins are
        /// corrected would overlap the hover targets it is measuring between.
        static let itemSpacing: CGFloat = Design.Spacing.small

        /// The least room between the two runs, so a long caption truncates rather than
        /// growing under the actions at the other end.
        static let runGap: CGFloat = Design.Spacing.medium

        /// What holds the spring at that floor once a member has been named to take the slack
        /// instead. Optional, so a row narrower than its own content compresses rather than
        /// becoming unsatisfiable — and above the wish below, so the runs keep their gap even
        /// while the named member is asking for everything.
        static let springHeld: NSLayoutConstraint.Priority = .defaultHigh

        /// The named member's standing wish to be as wide as the row.
        ///
        /// A **wish**, rather than the lowest hugging priority in the row, because hugging only
        /// relates a view to its *intrinsic* size and half the controls here have no intrinsic
        /// width at all: `ThemedSegmentedControl` states `noIntrinsicMetric`, and the absence of
        /// a constraint is looser than any priority, so the slack went to the scope run however
        /// weakly the field hugged. Something has to *ask* for the width. Above ordinary hugging
        /// (`.defaultLow`) so the member actually grows, below the spring's hold so it does not
        /// grow through the gap between the runs.
        static let stretchWish: NSLayoutConstraint.Priority = .init(
            NSLayoutConstraint.Priority.defaultHigh.rawValue - 1
        )
    }

    // MARK: - Properties

    public let scale: ControlRowScale

    /// The row's own measurements, which is what its members are handed.
    public var metrics: ControlRowMetrics { ControlRowMetrics(scale: scale) }

    public private(set) var leadingViews: [NSView] = []
    public private(set) var trailingViews: [NSView] = []

    /// The member the row's slack lands in, when one of them should have it.
    ///
    /// Nil is the ordinary row: two runs pushed to opposite edges with air between them, which
    /// is what a row of chips and buttons is. A row built around a **field** is the other shape
    /// — the field *is* the row and the controls beside it are what it is narrowed by — and
    /// there the air after the field is exactly what should not exist: Universal Search's header
    /// held its query at the width of the word "Search" with a hole where the results' width
    /// was. Named here rather than set as a hugging priority at the call site, for the same
    /// reason the height is: the spring is private, so only the row can say what outranks it.
    public private(set) var stretchingView: NSView?

    /// **One stack, not two, with a spring in the middle.**
    ///
    /// Two stacks pinned to opposite edges was the obvious shape and could not carry pressure.
    /// A stack whose width comes from its own content refuses to be narrower than that content
    /// (`clippingResistancePriority`, required by default), so in a pane too narrow for the row
    /// something had to give: at required the run kept its width and the *row* grew past the
    /// pane; lowered, the run shrank and its members hung out of it unchanged. Neither ever
    /// reached the members, which is where the give belongs — a label that truncates.
    ///
    /// A single stack pinned to both edges has a definite width, so the squeeze does reach them.
    /// Measured against the display pane's protected 260pt with the browser comparison's own
    /// header: a two-segment picker that would not go below 287 in either two-stack arrangement
    /// compresses here, which is exactly what it did before any of this was a component.
    private let runs: NSStackView = {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Layout.itemSpacing
        // The default, restated because the row depends on it: a hidden member has to leave the
        // row rather than hold its place. Git Review's Back button is usually hidden, and a
        // ghost of it indented the chip past the margin the cards below it start on.
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    /// The slack between the two runs — an actual view that can stretch, which is the whole
    /// difference between this and the empty caption the Compare tab was holding its actions out
    /// with. It hugs and resists at the lowest priority in the row, so every point of spare
    /// width lands here and every point of shortfall is taken from here first.
    private let spring: NSView = {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        view.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return view
    }()

    private lazy var heightConstraint = heightAnchor.constraint(
        equalToConstant: metrics.height
    )

    /// The named member's wish to be the width of the row, alive only while one is named.
    private var stretchWish: NSLayoutConstraint?

    /// Pins the spring *at* the floor it is otherwise only kept above, for as long as a member
    /// is carrying the row's slack. Inactive on an ordinary row, which is the shape where the
    /// air between the runs is the point.
    private lazy var springHoldsItsFloor: NSLayoutConstraint = {
        let held = spring.widthAnchor.constraint(equalToConstant: Layout.runGap)
        held.priority = Layout.springHeld
        return held
    }()
    private let appEvents = AppEventObservations()

    /// The height the row last handed out, so a layout pass that changes nothing writes nothing.
    /// A constraint constant assigned unconditionally marks the view dirty, and a `layout()`
    /// that dirties itself never settles.
    private var appliedHeight: CGFloat?

    // MARK: - Initialization

    /// Both arrays run leading to trailing. The first leading view and the last trailing view
    /// touch the row's edges with their full interaction surfaces. `stretching` names the one
    /// member the spare width belongs to, and must be one of them — see `stretchingView`.
    public init(
        scale: ControlRowScale = .compact,
        leading: [NSView] = [],
        trailing: [NSView] = [],
        stretching: NSView? = nil
    ) {
        self.scale = scale
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setupViews()
        configure(leading: leading, trailing: trailing, stretching: stretching)

        // The compact height is authored by the material, so a style switch resizes the row and
        // everything standing in it. Without this the row kept the height of the theme it was
        // built under and its members kept theirs, which is the same disagreement one layer up.
        //
        // The event is the *prompt*; `layout()` is the guarantee. A row built while detached, or
        // one whose notification is delivered after the pass that would have used it, still
        // levels itself the next time it lays out — the way `ChipView` re-reads its own anatomy.
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in self?.applyMetrics() }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Layout

    public override func layout() {
        applyMetrics()
        super.layout()
    }

    // MARK: - Public Methods

    /// Replaces what the row holds.
    ///
    /// One call rather than two, because the inequality that keeps the runs apart relates them:
    /// setting one side and then the other would rebuild that constraint twice and leave the
    /// intermediate state constrained against a run that is on its way out. Hosts whose row
    /// changes shape with its content — the Compare tab swaps a mode chip in for images and out
    /// for a text diff — call this each time.
    public func configure(leading: [NSView], trailing: [NSView], stretching: NSView? = nil) {
        for view in leadingViews + trailingViews where !leading.contains(view)
            && !trailing.contains(view) {
            view.removeFromSuperview()
        }
        leadingViews = leading
        trailingViews = trailing
        // Released before the members move and re-made after they have landed: a width relation
        // between a view and the stack it is not in yet has no common ancestor, and AppKit
        // raises rather than waiting for one.
        releaseStretch()

        fill(runs, with: leading + [spring] + trailing)
        // No stack spacing around the spring: the gap between the runs is the spring's own
        // minimum, stated once, rather than that minimum plus two sibling gaps. Every other
        // member is put back to the default first, because custom spacing outlives the
        // arrangement that wanted it — a control that moves from the end of the leading run into
        // the trailing one would otherwise carry the seam with it.
        for view in leading + trailing {
            runs.setCustomSpacing(NSStackView.useDefaultSpacing, after: view)
        }
        if let last = leading.last { runs.setCustomSpacing(0, after: last) }
        runs.setCustomSpacing(0, after: spring)
        applyStretch(to: stretching, among: leading + trailing)
        applyMetrics(force: true)
    }

    /// The height a row at `scale` stands at, for a host sizing itself around one before it has
    /// been laid out.
    public static func height(for scale: ControlRowScale) -> CGFloat { scale.height }

    // MARK: - Private Methods

    private func setupViews() {
        addSubview(runs)

        NSLayoutConstraint.activate([
            heightConstraint,
            // A member's stable frame is its complete hover, menu and focus silhouette. Keep
            // that frame on the declared row edge; the component owns any inset from its plate
            // to its title or glyph.
            runs.leadingAnchor.constraint(equalTo: leadingAnchor),
            runs.trailingAnchor.constraint(equalTo: trailingAnchor),
            // Centred on the row rather than pinned to its edges, so the air above the controls
            // and the air below them are the same air. The stack is constrained only sideways,
            // which is what stops a member taller than the row — a field dropped into a compact
            // one — from fighting the row's height instead of simply overhanging it where it can
            // be seen.
            runs.centerYAnchor.constraint(equalTo: centerYAnchor),
            // The two runs must not meet, however little room there is. This is the spring's
            // floor rather than a relation between the runs, because the runs are not separate
            // views to relate: they are the members either side of it.
            spring.widthAnchor.constraint(greaterThanOrEqualToConstant: Layout.runGap)
        ])
    }

    /// Points the spare width at one member, or puts it back in the air between the runs.
    ///
    /// Two writes, because either alone leaves the solver free to choose: the spring is held
    /// *at* its floor rather than above it, so there is spare width to place at all, and the
    /// named member is given a standing wish for the row's whole width, so there is one thing
    /// asking for it. Nothing about the member itself is changed — a control keeps the hugging
    /// priority its own component set, and moving it out of the row takes the wish with it.
    /// A member that is not in the row is not a member, and naming one is a call-site mistake
    /// rather than a silently different layout.
    private func applyStretch(to view: NSView?, among members: [NSView]) {
        if let view, !members.contains(view) {
            assertionFailure("a control row was asked to stretch a view it does not hold")
            return applyStretch(to: nil, among: members)
        }
        releaseStretch()
        stretchingView = view
        springHoldsItsFloor.isActive = view != nil
        guard let view else { return }
        let wish = view.widthAnchor.constraint(equalTo: runs.widthAnchor)
        wish.priority = Layout.stretchWish
        wish.isActive = true
        stretchWish = wish
    }

    private func releaseStretch() {
        stretchWish?.isActive = false
        stretchWish = nil
        stretchingView = nil
        springHoldsItsFloor.isActive = false
    }

    private func fill(_ stack: NSStackView, with views: [NSView]) {
        for view in stack.arrangedSubviews where !views.contains(view) {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, view) in views.enumerated() {
            view.translatesAutoresizingMaskIntoConstraints = false
            if stack.arrangedSubviews.count > index, stack.arrangedSubviews[index] === view {
                continue
            }
            stack.insertArrangedSubview(view, at: index)
        }
    }

    /// Hands every member the row's measurements.
    ///
    /// `force` is membership having changed: the height may be the one already handed out while
    /// the views it was handed to are different.
    private func applyMetrics(force: Bool = false) {
        let metrics = self.metrics
        if force || appliedHeight != metrics.height {
            appliedHeight = metrics.height
            write(metrics.height, to: heightConstraint)
            for case let member as ControlRowMember in leadingViews + trailingViews {
                member.adopt(metrics)
            }
        }
    }

    private func write(_ constant: CGFloat, to constraint: NSLayoutConstraint) {
        guard constraint.constant != constant else { return }
        constraint.constant = constant
    }
}
