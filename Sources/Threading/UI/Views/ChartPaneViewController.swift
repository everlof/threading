import AppKit

/// A chart tab's whole content: the chart, the caption the panel writes under it, and the two
/// ways to take the chart out of the app.
///
/// It exists so the panel can host a chart the same way it hosts a semantic document — as a
/// controller it can install and release — rather than growing a third permanently-retained
/// content view beside the image view and the web view for a tab that may never be opened.
///
/// **The actions are here rather than in the panel's own footer menu**, which is where every
/// other content kind keeps them. The panel adds its hosted view last so that it layers over the
/// image and web surfaces, and a hosted view runs from under the header to the foot of the pane —
/// so for a chart the `⋯` sat beneath an opaque ground, and "Copy Chart Data", documented there
/// as the one thing a chart tab owes its reader, could not be clicked at all. A content view that
/// fills the pane has to carry its own controls.
@MainActor
final class ChartPaneViewController: NSViewController {

    private enum Layout {
        static let inset = Design.Spacing.inset

        /// How hard the content holds the foot of the pane — a step below the card's own ceiling
        /// on the plot (`ChartCardView.applyPlotCeiling`) and below the height a ranking states,
        /// which is the point: the pane is the room on offer, not an instruction to fill it.
        static let fillsPane = NSLayoutConstraint.Priority(
            NSLayoutConstraint.Priority.defaultHigh.rawValue - 1
        )

        /// How long a button wears the checkmark that says the pasteboard took it. A copy makes
        /// no sound and moves nothing on screen, so without a receipt the only way to learn
        /// whether the press landed is to paste somewhere else and look.
        static let receiptDwell: TimeInterval = 1.5
    }

    private enum Glyph {
        static let picture = "photo.on.rectangle"
        static let numbers = "tablecells"
        static let taken = "checkmark"
    }

    private let spec: ChartSpec
    private let subtitle: String
    private var card: ChartCardView?

    private lazy var pictureButton = button(
        symbol: Glyph.picture,
        named: Self.pictureAction
    ) { [weak self] in self?.pressedPicture() }

    private lazy var numbersButton = button(
        symbol: Glyph.numbers,
        named: Self.numbersAction
    ) { [weak self] in self?.pressedNumbers() }

    private static var pictureAction: String { L10n.string("Copy the chart as a picture") }
    private static var numbersAction: String { L10n.string("Copy the numbers behind the chart") }

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

        // One row under the chart: what the panel has to say about it at one end, what can be
        // done with it at the other. A row rather than two placements, so the caption and the
        // buttons stand at one height whatever the theme makes of a control.
        let footer = ControlRowView(
            leading: makeCaption().map { [$0] } ?? [],
            trailing: [pictureButton, numbersButton]
        )
        container.addSubview(footer)

        var constraints = [
            card.leadingAnchor.constraint(
                equalTo: container.leadingAnchor,
                constant: Layout.inset
            ),
            card.trailingAnchor.constraint(
                equalTo: container.trailingAnchor,
                constant: -Layout.inset
            ),
            card.topAnchor.constraint(equalTo: container.topAnchor, constant: Layout.inset),

            footer.topAnchor.constraint(
                equalTo: card.bottomAnchor,
                constant: Design.Spacing.small
            ),
            footer.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: card.trailingAnchor),

            // The foot of the pane is a limit; reaching it is only a preference. **Filling the
            // pane must not be required**: required, it outranked the card's own ceiling on the
            // plot, so a panel dragged narrow went on drawing a column of chart the full height
            // of the window — which is the shape that reported this.
            footer.bottomAnchor.constraint(
                lessThanOrEqualTo: container.bottomAnchor,
                constant: -Layout.inset
            )
        ]

        // A chart takes the room its own shape asks for, not the room the panel happens to have.
        // See `ChartCardView.boundedHeight(for:)`: a ranking's vertical axis is its categories,
        // so a taller pane is empty ground under the chart rather than taller rows. The bound is
        // a preference and the floor of the pane is a limit — a required height inside pane
        // content becomes the window's own minimum size, which is a bug this pane already had
        // once.
        if let bounded = ChartCardView.boundedHeight(for: spec) {
            let height = card.heightAnchor.constraint(equalToConstant: bounded)
            height.priority = .defaultHigh
            constraints.append(height)
        } else {
            let fills = footer.bottomAnchor.constraint(
                equalTo: container.bottomAnchor,
                constant: -Layout.inset
            )
            fills.priority = Layout.fillsPane
            constraints.append(fills)
        }

        NSLayoutConstraint.activate(constraints)
        view = container
    }

    // MARK: - Taking the Chart With You

    /// The chart as a picture: what the reader is looking at, rather than a second rendering of
    /// the same numbers. See `ChartCardView.drawnAsImage`.
    @discardableResult
    func copyPicture(to pasteboard: NSPasteboard = .general) -> Bool {
        guard let image = card?.drawnAsImage() else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects([image])
    }

    /// The numbers, tab-separated, which is what a spreadsheet and a message both take.
    @discardableResult
    func copyNumbers(to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(spec.tabSeparatedValues, forType: .string)
    }

    // MARK: - Private Methods

    private func pressedPicture() {
        guard copyPicture() else {
            SystemAlert.refuse()
            return
        }
        acknowledge(pictureButton, restoring: Glyph.picture, named: Self.pictureAction)
    }

    private func pressedNumbers() {
        copyNumbers()
        acknowledge(numbersButton, restoring: Glyph.numbers, named: Self.numbersAction)
    }

    /// The receipt: the button wears a checkmark for a beat, then goes back to offering the
    /// action. It is the only feedback a copy has to give.
    private func acknowledge(
        _ button: ThemedIconButton,
        restoring symbol: String,
        named name: String
    ) {
        button.setSymbol(Glyph.taken, accessibility: L10n.string("Copied"))
        DispatchQueue.main.asyncAfter(deadline: .now() + Layout.receiptDwell) { [weak button] in
            button?.setSymbol(symbol, accessibility: name)
        }
    }

    /// The panel's own words about the chart — how many series, how many categories.
    ///
    /// Held inside the pane by a required `<=`, so — like the card's title, and like the panel's
    /// caption before it — an ordinary label's resistance would make this line the narrowest the
    /// pane could be dragged. It may end in an ellipsis instead of deciding a window's minimum.
    private func makeCaption() -> NSTextField? {
        guard !subtitle.isEmpty else { return nil }
        // The paragraph style rather than the field's `lineBreakMode`, for the reason
        // `ChartCardView.truncating` states: attributed content carries its own, and it wins.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let label = NSTextField.label(
            attributed: NSAttributedString(
                string: subtitle,
                attributes: [
                    .font: Design.Typography.detail(),
                    .foregroundColor: Design.Text.secondary,
                    .paragraphStyle: paragraph
                ]
            )
        )
        label.setContentCompressionResistancePriority(
            Design.Priority.belowFittingSize,
            for: .horizontal
        )
        label.toolTip = subtitle
        return label
    }

    private func button(
        symbol: String,
        named name: String,
        onPress: @escaping () -> Void
    ) -> ThemedIconButton {
        let button = ThemedIconButton(
            symbolName: symbol,
            accessibility: name,
            target: .inline,
            inkSource: .chrome
        )
        button.toolTip = name
        button.onPress = onPress
        return button
    }
}
