import AppKit

/// Builds a settings pane laid out like a standard macOS preferences form.
///
/// Labels are right-aligned in a fixed column with controls aligned beside them, which is
/// what an `NSGridView` gives for free and what hand-rolled stacks tend to get wrong.
final class PreferencesFormBuilder {

    // MARK: - Properties

    private let grid = NSGridView(numberOfColumns: 2, rows: 0)
    private var isFirstSection = true

    // MARK: - Initialization

    init() {
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.columnSpacing = PreferencesLayout.columnSpacing
        grid.rowSpacing = PreferencesLayout.rowSpacing
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
    }

    // MARK: - Public Methods

    /// Adds a bold section header spanning both columns.
    @discardableResult
    func addSection(_ title: String) -> Self {
        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

        let row = grid.addRow(with: [label])
        row.mergeCells(in: NSRange(location: 0, length: 2))

        // A merged cell inherits the first column's trailing placement, which would push
        // the header to the far right.
        row.cell(at: 0).xPlacement = .leading

        // Sections after the first get breathing room above them.
        if isFirstSection {
            isFirstSection = false
        } else {
            row.topPadding = PreferencesLayout.sectionSpacing
        }

        return self
    }

    /// Adds a labelled control.
    @discardableResult
    func addRow(label: String, control: NSView, help: String? = nil) -> Self {
        let labelField = NSTextField(labelWithString: label.isEmpty ? "" : "\(label):")
        labelField.alignment = .right
        labelField.textColor = Design.Text.label

        grid.addRow(with: [labelField, control])
        addHelpIfNeeded(help)

        return self
    }

    /// Adds a control with no label, such as a checkbox, aligned to the control column.
    @discardableResult
    func addRow(control: NSView, help: String? = nil) -> Self {
        grid.addRow(with: [NSGridCell.emptyContentView, control])
        addHelpIfNeeded(help)

        return self
    }

    /// Adds explanatory text spanning both columns.
    @discardableResult
    func addNote(_ text: String) -> Self {
        let note = makeHelpLabel(text)
        let row = grid.addRow(with: [note])
        row.mergeCells(in: NSRange(location: 0, length: 2))
        row.cell(at: 0).xPlacement = .leading

        return self
    }

    /// Wraps the form in a scroll view so a small window never clips the content.
    func build() -> NSView {
        // Flipped, so a short form anchors to the top of a tall pane rather than sinking to the
        // bottom — an unflipped `NSScrollView` document view floats up from the bottom edge.
        let container = FlippedView()
        container.addSubview(grid)

        let scrollView = ThemedScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.documentView = container
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: PreferencesLayout.padding),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: PreferencesLayout.padding),
            grid.trailingAnchor.constraint(
                lessThanOrEqualTo: container.trailingAnchor,
                constant: -PreferencesLayout.padding
            ),
            grid.bottomAnchor.constraint(
                lessThanOrEqualTo: container.bottomAnchor,
                constant: -PreferencesLayout.padding
            ),
            container.widthAnchor.constraint(greaterThanOrEqualTo: grid.widthAnchor, constant: PreferencesLayout.padding * 2),
            container.heightAnchor.constraint(greaterThanOrEqualTo: grid.heightAnchor, constant: PreferencesLayout.padding * 2)
        ])

        return scrollView
    }

    // MARK: - Private Methods

    private func addHelpIfNeeded(_ help: String?) {
        guard let help else { return }

        let row = grid.addRow(with: [NSGridCell.emptyContentView, makeHelpLabel(help)])
        row.topPadding = PreferencesLayout.helpSpacing
    }

    private func makeHelpLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = Design.Text.secondary
        label.preferredMaxLayoutWidth = PreferencesLayout.helpWidth
        label.isSelectable = false

        return label
    }
}

// MARK: - Flipped View

/// A view whose origin is top-left, so content anchored to the top stays there inside a scroll
/// view taller than the content.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Preferences Layout

enum PreferencesLayout {
    static let padding: CGFloat = 24
    static let columnSpacing: CGFloat = 12
    static let rowSpacing: CGFloat = 10
    static let sectionSpacing: CGFloat = 18
    static let helpSpacing: CGFloat = 2
    static let helpWidth: CGFloat = 360
    static let controlWidth: CGFloat = 260
}
