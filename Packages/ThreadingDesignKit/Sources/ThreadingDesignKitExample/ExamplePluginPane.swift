import AppKit
import ThreadingDesignKit

/// What a plugin actually writes, compiled as a separate module.
///
/// This exists to decide the kit's public surface. A component becomes `public` because something
/// outside the kit could not be written without it — not because it looked like part of the API.
/// The shape is deliberately the one a log pane needs: a header, a row of controls, a status
/// indicator, and content on the themed ground.
public final class ExamplePluginPane: NSView {

    private let header = PaneHeaderView()
    private let follow = ThemedButton()
    private let activity = ThemedSpinner()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Design.Surface.ground.cgColor

        follow.title = "Follow"
        follow.emphasis = .primary

        let row = ControlRowView(leading: [follow], trailing: [activity])

        for view in [header, row] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: PaneHeaderDefaults.height),
            row.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Design.Spacing.small),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.medium),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
