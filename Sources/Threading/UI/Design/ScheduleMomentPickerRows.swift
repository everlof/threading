import AppKit

@MainActor
enum ScheduleMomentPickerRows {
    /// A day's name over its date, centred in the row's selection slot. The vertical stack
    /// alone would leave the pair against the top edge of the minimum-height row.
    static func makeDayRow(_ day: ScheduleMomentOptions.Day) -> NSView {
        let title = NSTextField(labelWithString: day.title)
        title.applyFont(.body)
        title.textColor = Design.Text.label

        let detail = NSTextField(labelWithString: day.detail)
        detail.applyFont(.subheading)
        detail.textColor = Design.Text.tertiary

        let labels = NSStackView(views: [title, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = Design.Spacing.hairline
        labels.translatesAutoresizingMaskIntoConstraints = false

        let cell = NSView()
        cell.addSubview(labels)
        NSLayoutConstraint.activate([
            labels.leadingAnchor.constraint(
                equalTo: cell.leadingAnchor,
                constant: Design.Spacing.small
            ),
            labels.trailingAnchor.constraint(
                lessThanOrEqualTo: cell.trailingAnchor,
                constant: -Design.Spacing.small
            ),
            labels.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            // A row that somehow holds more than it was measured for grows the cell honestly
            // rather than drawing over its neighbour.
            labels.topAnchor.constraint(greaterThanOrEqualTo: cell.topAnchor),
            labels.bottomAnchor.constraint(lessThanOrEqualTo: cell.bottomAnchor)
        ])
        return cell
    }

    static func makeTimeRow(_ time: ScheduleMomentOptions.Time) -> NSView {
        let title = NSTextField(labelWithString: time.title)
        // Tabular figures: a column of clock faces whose digits shift width is a column that
        // reads as ragged even though every string is the same length.
        #if os(Linux)
        title.font = Design.Typography.numericBody()
        #else
        title.applyFont(.numericBody)
        #endif
        title.textColor = Design.Text.label

        let row = NSStackView(views: [title])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(
            top: 0,
            left: Design.Spacing.small,
            bottom: 0,
            right: Design.Spacing.small
        )
        return row
    }
}
