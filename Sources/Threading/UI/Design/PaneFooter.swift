import AppKit

/// A control whose frame carries padding around its visible ink — a plain `ThemedButton` holds
/// room for its hover surface, a `ThemedIconButton` for its click target. Layout that wants the
/// *ink* at a stated inset has to know how deep that padding is, or every container repeats the
/// subtraction with a number it does not own: the sidebar footer read as unevenly inset for as
/// long as its two buttons were placed by their frames, because equal frame margins are not
/// equal visual margins. Conforming is what lets `PaneFooterView` put a titled button and a
/// bare glyph on the same visual margin without knowing either type.
@MainActor
protocol OpticalInsetProviding {
    /// Horizontal distance from the frame's edge to the visible content inside it.
    var opticalHorizontalInset: CGFloat { get }
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
/// - **Controls align by ink, not by frame.** The outermost view on each side is pulled out by
///   its `OpticalInsetProviding` padding, so a plain button's glyph lands exactly on the stated
///   margin instead of its invisible hover surface doing so. Views that state no padding are
///   taken at their frame.
///
/// The footer draws nothing itself — the hairline is a `SeparatorView`, and the ground beneath
/// is the pane's own. Hosts pin leading, trailing and bottom; the band supplies its height.
final class PaneFooterView: NSView {

    // MARK: - Geometry

    private enum Layout {
        /// Ink-to-edge distance, measured from the corner-adapted content region.
        static let contentInset: CGFloat = Design.Spacing.inset
        /// Between sibling controls on the same side.
        static let itemSpacing: CGFloat = Design.Spacing.small
    }

    // MARK: - Properties

    /// The region the content insets from: the corner-adapted safe area where the platform can
    /// state one, the band's own edges elsewhere. Exposed so a test can assert the margin
    /// against what the content is actually measured from.
    private(set) var contentGuide: NSLayoutGuide!

    private let separator = SeparatorView()

    // MARK: - Initialization

    /// Both arrays run leading-to-trailing; the first leading view and the last trailing view
    /// touch their margins and are the ones aligned by ink.
    init(leading: [NSView] = [], trailing: [NSView] = []) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Design.Size.footerHeight).isActive = true
        contentGuide = makeContentGuide()
        installSeparator()
        install(leading: leading, trailing: trailing)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Private Methods

    private func makeContentGuide() -> NSLayoutGuide {
        if #available(macOS 26.0, *) {
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
        for view in leading + trailing {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
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
    }

    private func opticalInset(of view: NSView) -> CGFloat {
        (view as? OpticalInsetProviding)?.opticalHorizontalInset ?? 0
    }
}
