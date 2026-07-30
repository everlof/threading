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
final class PaneHeaderView: NSView {

    // MARK: - Geometry

    /// Deep enough for a tab or an inline control, with the same air above and below.
    /// `nonisolated` so the content pane's layout constants can restate it without an actor hop.
    nonisolated static let bandHeight: CGFloat = Design.Size.tabHeight + Design.Spacing.small * 2

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
        heightAnchor.constraint(equalToConstant: Self.bandHeight).isActive = true
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
            separator.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func install(leading: [NSView], trailing: [NSView]) {
        for view in leading + trailing {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            // Centred in the band rather than pinned to an edge, so the air above the row
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
