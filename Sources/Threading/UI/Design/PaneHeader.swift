import AppKit

/// The top band of a pane: a hairline below, its controls centred in the band, leading
/// actions at one edge and trailing ones at the other — `PaneFooterView`'s mirror.
///
/// The band's whole geometry is stated here for the same reason the footer's is: the height,
/// the edge-to-edge hairline, the corner-adapted insets and the align-by-ink rule were each
/// re-derived per pane before they were a component, and each pane got one of them subtly
/// wrong. The height is the same measure the content pane's header strip uses
/// (`PaneHeaderDefaults.height` reads it from here), so the two panes' header hairlines land
/// on one line across the split.
///
/// The header draws nothing itself — the hairline is a `SeparatorView`, and the ground beneath
/// is the pane's own. Hosts pin leading, trailing and top; the band supplies its height.
public final class PaneHeaderView: NSView {

    // MARK: - Geometry

    /// Deep enough for a tab or an inline control, with the same air above and below, followed
    /// by the rule that ends the band. The rule is outside that air: counting it inside the old
    /// fixed height made a one-point separator almost invisible to the geometry and let
    /// Bauhaus's four-point rule consume most of the lower margin.
    public static var bandHeight: CGFloat {
        Design.Size.tabHeight + Design.Spacing.small * 2 + Design.Radius.border
    }

    /// Ink-to-edge distance, measured from the corner-adapted content region.
    ///
    /// Stated here rather than at each band for the reason the height is: every band that
    /// re-derived it got it subtly wrong. A band this component does not itself lay out — the
    /// window's caption row, when a theme seats the window's commands in it — reads these two
    /// rather than repeating the numbers.
    public static let contentInset: CGFloat = Design.Spacing.inset

    /// Between sibling controls on the same side.
    public static let itemSpacing: CGFloat = Design.Spacing.small

    // MARK: - Properties

    /// The region the content insets from: the corner-adapted safe area where the platform can
    /// state one and the band asks for it, the band's own edges otherwise. Exposed so a test can
    /// assert the margin against what the content is actually measured from.
    private let margin: PaneBandMargin
    public private(set) lazy var contentGuide: NSLayoutGuide = makeContentGuide(margin)

    /// The vertical content region, ending where the separator begins. Exposed as an anchor so
    /// composite pane headers can align their host-owned controls to the same row without
    /// re-deriving the separator's theme-dependent thickness.
    private let contentAreaGuide = NSLayoutGuide()
    public var contentCenterYAnchor: NSLayoutYAxisAnchor { contentAreaGuide.centerYAnchor }

    private let separator = SeparatorView()
    private lazy var bandHeightConstraint = heightAnchor.constraint(
        equalToConstant: Self.bandHeight
    )
    private let appEvents = AppEventObservations()
    private var appliedBandHeight: CGFloat?

    // MARK: - Initialization

    /// Both arrays run leading-to-trailing; the first leading view and the last trailing view
    /// touch their margins and are the ones aligned by ink.
    public init(
        leading: [NSView] = [],
        trailing: [NSView] = [],
        margin: PaneBandMargin = .cornerAdapted
    ) {
        self.margin = margin
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        bandHeightConstraint.isActive = true
        _ = contentGuide
        installSeparator()
        installContentAreaGuide()
        install(leading: leading, trailing: trailing)
        applyMetrics()

        // Theme materials own rule weight, so changing theme is a remeasure as well as a
        // redraw. The layout pass is the guarantee for a detached band that missed the event.
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in self?.applyMetrics() }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func layout() {
        applyMetrics()
        super.layout()
    }

    // MARK: - Private Methods

    private func makeContentGuide(_ margin: PaneBandMargin) -> NSLayoutGuide {
        if #available(macOS 26.0, *), margin == .cornerAdapted {
            return layoutGuide(for: .safeArea(cornerAdaptation: .horizontal))
        }
        let guide = NSLayoutGuide()
        addLayoutGuide(guide)
        NSLayoutConstraint.activate([
            guide.leadingAnchor.constraint(equalTo: leadingAnchor),
            guide.trailingAnchor.constraint(equalTo: trailingAnchor),
            guide.topAnchor.constraint(equalTo: topAnchor),
            guide.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        return guide
    }

    private func installSeparator() {
        addSubview(separator)
        NSLayoutConstraint.activate([
            // Edge to edge: the rule is the pane's own fold, and a rule that stops short of
            // the pane it divides reads as a stray line rather than as a boundary.
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func installContentAreaGuide() {
        addLayoutGuide(contentAreaGuide)
        NSLayoutConstraint.activate([
            contentAreaGuide.leadingAnchor.constraint(equalTo: contentGuide.leadingAnchor),
            contentAreaGuide.trailingAnchor.constraint(equalTo: contentGuide.trailingAnchor),
            contentAreaGuide.topAnchor.constraint(equalTo: topAnchor),
            contentAreaGuide.bottomAnchor.constraint(equalTo: separator.topAnchor)
        ])
    }

    private func install(leading: [NSView], trailing: [NSView]) {
        // One text line per band: controls are centred, and loose text sits on the first
        // titled control's baseline rather than on its own centre — the footer's rule,
        // mirrored, including mounting every view before constraining any: a follower may
        // precede its anchor, and a baseline constraint against a view not yet in the
        // hierarchy has no common ancestor. See `PaneBandTextAlignment`.
        let baselineAnchor = PaneBandTextAlignment.anchor(among: leading + trailing)
        for view in leading + trailing {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        for view in leading + trailing {
            if let baselineAnchor, PaneBandTextAlignment.joins(view, anchoredBy: baselineAnchor) {
                view.firstBaselineAnchor.constraint(
                    equalTo: baselineAnchor.firstBaselineAnchor
                ).isActive = true
                continue
            }
            // Centred above the rule rather than across it, so the air above the row and the
            // air below it are the same air at every authored rule weight.
            view.centerYAnchor.constraint(equalTo: contentCenterYAnchor).isActive = true
        }

        if let first = leading.first {
            first.leadingAnchor.constraint(
                equalTo: contentGuide.leadingAnchor,
                constant: Self.contentInset - opticalInset(of: first)
            ).isActive = true
        }
        for (previous, next) in zip(leading, leading.dropFirst()) {
            next.leadingAnchor.constraint(
                equalTo: previous.trailingAnchor,
                constant: Self.itemSpacing
            ).isActive = true
        }

        if let last = trailing.last {
            last.trailingAnchor.constraint(
                equalTo: contentGuide.trailingAnchor,
                constant: -(Self.contentInset - opticalInset(of: last))
            ).isActive = true
        }
        for (previous, next) in zip(trailing, trailing.dropFirst()) {
            next.leadingAnchor.constraint(
                equalTo: previous.trailingAnchor,
                constant: Self.itemSpacing
            ).isActive = true
        }

        // The two runs must not meet: without this nothing relates them, and a leading view
        // wide enough — the brand row's wordmark in a narrow sidebar — draws under the
        // trailing controls rather than compressing. Went unwritten while no band carried
        // content on both sides.
        if let lastLeading = leading.last, let firstTrailing = trailing.first {
            lastLeading.trailingAnchor.constraint(
                lessThanOrEqualTo: firstTrailing.leadingAnchor,
                constant: -Self.itemSpacing
            ).isActive = true
        }
    }

    private func opticalInset(of view: NSView) -> CGFloat {
        (view as? OpticalInsetProviding)?.opticalHorizontalInset ?? 0
    }

    private func applyMetrics() {
        let height = Self.bandHeight
        guard appliedBandHeight != height else { return }
        appliedBandHeight = height
        bandHeightConstraint.constant = height
        invalidateIntrinsicContentSize()
        needsLayout = true
    }
}
