import AppKit

/// Where a band measures its margins from.
///
/// The platform's clearance is stated per *edge*, not per point: a view spanning the sidebar's
/// full width is told to keep clear of the window's curve and of the controls floating over the
/// column, whether or not the band's own content comes anywhere near either. For a band that
/// does — one drawn hard against the window's corner — that is exactly right. For the sidebar's
/// two bands it is not: both sit a clear ten points inboard of the traffic lights above and the
/// curve below, and taking the clearance anyway indented the brand and Settings some eighty
/// points past the list they head and foot, so the column read as three columns.
public enum PaneBandMargin {
    /// The corner-adapted safe area. The default, and right wherever the band's ink can meet
    /// the window's curve or its floating controls.
    case cornerAdapted
    /// The band's own edges. For a band stacked directly above or below content that starts at
    /// the pane's edge, where the platform's clearance would indent the chrome away from the
    /// column it belongs to.
    case paneEdge
}

/// What the footer's outer margin aligns when its first or last control carries internal
/// padding. Textual chrome normally aligns the visible title or glyph; a filled call-to-action
/// aligns its plate so the coloured surface itself keeps clear of the pane edge.
public enum PaneFooterOuterEdgeAlignment: Equatable {
    case visibleContent
    case controlFrame
}

/// The bottom band of a pane: a hairline above, its controls centred in the band, leading
/// actions at one edge and trailing ones at the other.
///
/// The band's whole geometry is stated here so a footer is correct out of the box rather than
/// re-derived per pane — the height, the edge-to-edge rule, the insets, and two decisions that
/// each pane got subtly wrong when it made them itself:
///
/// - **Insets are measured from the corner-adapted region, not the frame.** A pane flush to the
///   window meets the window's rounded bottom corner, and a margin equal on both sides reads
///   unbalanced there: one edge is a straight divider, the other a curve eating into the
///   margin. On macOS 26 the content aligns to
///   `layoutGuide(for: .safeArea(cornerAdaptation: .horizontal))`, which reports clearance only
///   for edges that actually abut a curve — measured for the sidebar's band: 16pt at the window
///   corner, zero at the divider — so "equal spacing" is measured from the region the eye reads
///   as usable. A pane that sits against another pane gets no phantom inset, automatically.
/// - **Controls align by visible content by default.** The outermost view on each side is pulled
///   out by its `OpticalInsetProviding` padding, so a plain button's glyph lands exactly on the
///   stated margin instead of its invisible hover surface doing so. A footer ending in a filled
///   action can opt into control-frame alignment so its plate, rather than its title, keeps that
///   margin. Views that state no padding are identical under both rules.
///
/// The footer draws nothing itself — the hairline is a `SeparatorView`, and the ground beneath
/// is the pane's own. Hosts pin leading, trailing and bottom; the band supplies its height.
public final class PaneFooterView: NSView {

    // MARK: - Geometry

    private enum Layout {
        /// Ink-to-edge distance, measured from the corner-adapted content region.
        static let contentInset: CGFloat = Design.Spacing.inset
        /// Between sibling controls on the same side.
        static let itemSpacing: CGFloat = Design.Spacing.small
    }

    // MARK: - Properties

    /// The region the content insets from: the corner-adapted safe area where the platform can
    /// state one and the band asks for it, the band's own edges otherwise. Exposed so a test can
    /// assert the margin against what the content is actually measured from.
    private let margin: PaneBandMargin
    private let outerEdgeAlignment: PaneFooterOuterEdgeAlignment
    private(set) lazy var contentGuide: NSLayoutGuide = makeContentGuide(margin)

    private let separator = SeparatorView()

    // MARK: - Initialization

    /// Both arrays run leading-to-trailing; the first leading view and the last trailing view
    /// touch their margins and are the ones aligned by ink.
    public init(
        leading: [NSView] = [],
        trailing: [NSView] = [],
        margin: PaneBandMargin = .cornerAdapted,
        outerEdgeAlignment: PaneFooterOuterEdgeAlignment = .visibleContent
    ) {
        self.margin = margin
        self.outerEdgeAlignment = outerEdgeAlignment
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Design.Size.footerHeight).isActive = true
        _ = contentGuide
        installSeparator()
        install(leading: leading, trailing: trailing)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
            separator.topAnchor.constraint(equalTo: topAnchor)
        ])
    }

    private func install(leading: [NSView], trailing: [NSView]) {
        // One text line per band: controls are centred, and loose text sits on the first
        // titled control's baseline rather than on its own centre — two point sizes centred
        // never share one. See `PaneBandTextAlignment` for the rule and the marks that wore
        // the bug. Every view is mounted before any is constrained: the scope band's label
        // *leads* the control whose line it joins, and a baseline constraint activated
        // against a view not yet in the hierarchy has no common ancestor to hang from.
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
            // Centred in the band rather than pinned to the bottom, so the air above the row
            // and the air below it are the same air — and both are the band's, stated once.
            view.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        }

        if let first = leading.first {
            first.leadingAnchor.constraint(
                equalTo: contentGuide.leadingAnchor,
                constant: Layout.contentInset - opticalInset(of: first)
            ).isActive = true
        }
        for (previous, next) in zip(leading, leading.dropFirst()) {
            next.leadingAnchor.constraint(
                equalTo: previous.trailingAnchor,
                constant: Layout.itemSpacing
            ).isActive = true
        }

        if let last = trailing.last {
            last.trailingAnchor.constraint(
                equalTo: contentGuide.trailingAnchor,
                constant: -(Layout.contentInset - opticalInset(of: last))
            ).isActive = true
        }
        for (previous, next) in zip(trailing, trailing.dropFirst()) {
            next.leadingAnchor.constraint(
                equalTo: previous.trailingAnchor,
                constant: Layout.itemSpacing
            ).isActive = true
        }

        // The two runs must not meet — the header's rule, mirrored, so a band that grows a
        // wide leading view compresses it instead of drawing it under the trailing controls.
        if let lastLeading = leading.last, let firstTrailing = trailing.first {
            lastLeading.trailingAnchor.constraint(
                lessThanOrEqualTo: firstTrailing.leadingAnchor,
                constant: -Layout.itemSpacing
            ).isActive = true
        }
    }

    private func opticalInset(of view: NSView) -> CGFloat {
        guard outerEdgeAlignment == .visibleContent else { return 0 }
        return (view as? OpticalInsetProviding)?.opticalHorizontalInset ?? 0
    }
}
