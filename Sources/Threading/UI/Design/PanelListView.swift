import AppKit

/// The display panel's list vocabulary: a scrolling stack of full-width rows under quiet
/// section headings, with notes for what a section has to say when it has no rows to say it
/// with.
///
/// Extracted because the Info and Sharing panes had each built it by hand — same scroll, same
/// clip, same width constraint — with the insets silently different, which is how one pane's
/// headings stopped lining up with anything above them. Geometry a second pane can repeat is a
/// component's to own, so it is stated once here: content ink sits at `Spacing.inset`, on the
/// same column as the pane's own header block.
///
/// A heading never carries the count of the rows under it. The rows themselves make the count
/// apparent; the number was another visual token that helped no decision (decided in the
/// Sharing pane first, and the vocabulary keeps panes from re-deciding it apart).
final class PanelListView: NSView {

    // MARK: - Properties

    private let stack = NSStackView()
    private let scrollView = ThemedScrollView()

    /// The arranged content in order, for tests that assert what a rebuild produced.
    var rows: [NSView] { stack.arrangedSubviews }

    // MARK: - Initialization

    /// `rowSpacing` is the one density decision a pane keeps: a reference list of readings sits
    /// tighter than a list of people.
    init(rowSpacing: CGFloat) {
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = rowSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(
            top: Design.Spacing.small,
            left: Design.Spacing.inset,
            bottom: Design.Spacing.inset,
            right: Design.Spacing.inset
        )

        let clipView = FlippedClipView()
        clipView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentView = clipView
        scrollView.documentView = stack
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.widthAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public Methods

    func clear() {
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
    }

    /// A quiet heading over the rows that follow — sentence case, no count.
    func addSection(_ title: String) {
        if !stack.arrangedSubviews.isEmpty {
            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.heightAnchor.constraint(equalToConstant: Design.Spacing.tight).isActive = true
            addRow(spacer)
        }

        let label = NSTextField(labelWithString: title)
        label.applyFont(.detail())
        label.textColor = Design.Text.quaternary
        label.translatesAutoresizingMaskIntoConstraints = false
        addRow(label)
    }

    /// What a section says when it has no rows: wrapped, quiet, on the content ink column.
    @discardableResult
    func addNote(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.applyFont(.subheading)
        label.textColor = Design.Text.tertiary
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        addRow(label)
        return label
    }

    /// Any full-width content: a row view, a control strip, a spacer.
    func addRow(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(
            equalTo: stack.widthAnchor,
            constant: -(stack.edgeInsets.left + stack.edgeInsets.right)
        ).isActive = true
    }
}
