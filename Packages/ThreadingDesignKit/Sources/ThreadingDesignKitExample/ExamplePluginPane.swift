import AppKit
import ThreadingDesignKit

/// What a plugin actually writes, compiled as a separate module.
///
/// This exists to decide the kit's public surface. A component becomes `public` because something
/// outside the kit could not be written without it — not because it looked like part of the API.
/// The shape is deliberately the one a log pane needs, because that is the first plugin: a header,
/// a source chooser, a filter field, a follow button, and a virtualised table of rows on the
/// themed ground.
public final class ExamplePluginPane: NSView {

    private let header = PaneHeaderView()
    private let source = ThemedPopUp()
    private let filter = ThemedSearchField()
    private let follow = ThemedButton()
    private let activity = ThemedSpinner()
    private let table = ThemedTableView()
    private let scroll = ThemedScrollView()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Design.Surface.ground.cgColor

        follow.title = "Follow"
        follow.emphasis = .primary
        filter.placeholderString = "Filter"
        for title in ["Simulator", "Device", "Console", "App log"] {
            source.addItem(withTitle: title)
        }

        // A log is externally sized, so the rows are a value model behind a virtual table rather
        // than a stack that grows with the stream. See the Scaling Gate in CLAUDE.md.
        scroll.documentView = table
        scroll.hasVerticalScroller = true

        let controls = ControlRowView(leading: [source, filter], trailing: [follow, activity])

        for view in [header, controls, scroll] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: PaneHeaderDefaults.height),

            controls.topAnchor.constraint(equalTo: header.bottomAnchor),
            controls.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PaneHeaderDefaults.inset),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PaneHeaderDefaults.inset),

            scroll.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: Design.Spacing.small),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
