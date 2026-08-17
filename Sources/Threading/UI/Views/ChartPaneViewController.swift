import AppKit

/// A chart tab's whole content: the caption the panel writes, and the chart itself.
///
/// It exists so the panel can host a chart the same way it hosts a semantic document — as a
/// controller it can install and release — rather than growing a third permanently-retained
/// content view beside the image view and the web view for a tab that may never be opened.
@MainActor
final class ChartPaneViewController: NSViewController {

    private enum Layout {
        static let inset = Design.Spacing.inset
    }

    private let spec: ChartSpec
    private let subtitle: String
    private var card: ChartCardView?

    init(spec: ChartSpec, subtitle: String) {
        self.spec = spec
        self.subtitle = subtitle
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = ThemedSurfaceView()
        container.applySurface(fill: Design.Surface.ground, radius: .fixed(0), pattern: .none)
        container.translatesAutoresizingMaskIntoConstraints = false
        let card = ChartCardView(spec: spec)
        self.card = card
        container.addSubview(card)

        var constraints = [
            card.leadingAnchor.constraint(
                equalTo: container.leadingAnchor,
                constant: Layout.inset
            ),
            card.trailingAnchor.constraint(
                equalTo: container.trailingAnchor,
                constant: -Layout.inset
            ),
            card.topAnchor.constraint(equalTo: container.topAnchor, constant: Layout.inset)
        ]

        // A chart takes the room its own shape asks for, not the room the panel happens to have.
        // See `ChartCardView.boundedHeight(for:)`: a ranking's vertical axis is its categories,
        // so a taller pane is empty ground under the chart rather than taller rows. The bound is
        // a preference and the floor of the pane is a limit — a required height inside pane
        // content becomes the window's own minimum size, which is a bug this pane already had
        // once.
        let bounded = ChartCardView.boundedHeight(for: spec)
        if let bounded {
            let height = card.heightAnchor.constraint(equalToConstant: bounded)
            height.priority = .defaultHigh
            constraints.append(height)
        }

        /// The card's foot: level with the pane's when the chart fills it, above it when the
        /// chart's own height is smaller than the room.
        func footConstraint(of view: NSView) -> NSLayoutConstraint {
            bounded == nil
                ? view.bottomAnchor.constraint(
                    equalTo: container.bottomAnchor,
                    constant: -Layout.inset
                )
                : view.bottomAnchor.constraint(
                    lessThanOrEqualTo: container.bottomAnchor,
                    constant: -Layout.inset
                )
        }

        if subtitle.isEmpty {
            constraints.append(footConstraint(of: card))
        } else {
            let caption = NSTextField.label(
                attributed: NSAttributedString(
                    string: subtitle,
                    attributes: [
                        .font: Design.Typography.detail(),
                        .foregroundColor: Design.Text.secondary
                    ]
                )
            )
            container.addSubview(caption)
            constraints.append(contentsOf: [
                caption.topAnchor.constraint(
                    equalTo: card.bottomAnchor,
                    constant: Design.Spacing.small
                ),
                caption.leadingAnchor.constraint(equalTo: card.leadingAnchor),
                caption.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor),
                footConstraint(of: caption)
            ])
        }

        NSLayoutConstraint.activate(constraints)
        view = container
    }
}
