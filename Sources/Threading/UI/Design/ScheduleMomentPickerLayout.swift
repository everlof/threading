import AppKit

enum ScheduleMomentPickerColumn {
    static let day = NSUserInterfaceItemIdentifier("ScheduleMomentDayColumn")
    static let time = NSUserInterfaceItemIdentifier("ScheduleMomentTimeColumn")
}

@MainActor
enum ScheduleMomentPickerLayout {
    static let sheetWidth: CGFloat = 520
    static let sheetHeight: CGFloat = 460
    /// Wide enough for `Wednesday` over `17 Sept` without truncating either.
    static let dayColumnWidth: CGFloat = 180
    static let minimumListHeight: CGFloat = 240
    static let minimumDayRowHeight: CGFloat = 44
    static let minimumTimeRowHeight: CGFloat = 28

    static var dayRowHeight: CGFloat {
        max(
            minimumDayRowHeight,
            Design.Typography.lineHeight(of: Design.Typography.body())
                + Design.Typography.lineHeight(of: Design.Typography.subheading())
                + Design.Spacing.hairline
                + 2 * Design.Spacing.small
        )
    }

    static var timeRowHeight: CGFloat {
        max(
            minimumTimeRowHeight,
            Design.Typography.lineHeight(of: Design.Typography.numericBody())
                + 2 * Design.Spacing.tight
        )
    }

    static func headings(_ heading: NSView, _ note: NSView) -> NSStackView {
        let stack = NSStackView(views: [heading, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.hairline
        return stack
    }

    static func lists(dayCaption: NSView, dayScroll: NSView,
                      timeCaption: NSView, timeScroll: NSView) -> NSStackView {
        let dayColumn = NSStackView(views: [dayCaption, dayScroll])
        dayColumn.orientation = .vertical
        dayColumn.alignment = .leading
        dayColumn.spacing = Design.Spacing.small
        dayScroll.widthAnchor.constraint(equalTo: dayColumn.widthAnchor).isActive = true

        let timeColumn = NSStackView(views: [timeCaption, timeScroll])
        timeColumn.orientation = .vertical
        timeColumn.alignment = .leading
        timeColumn.spacing = Design.Spacing.small
        timeScroll.widthAnchor.constraint(equalTo: timeColumn.widthAnchor).isActive = true

        let row = NSStackView(views: [dayColumn, timeColumn])
        row.orientation = .horizontal
        row.alignment = .top
        row.distribution = .fill
        row.spacing = Design.Spacing.medium
        dayColumn.widthAnchor.constraint(equalToConstant: dayColumnWidth).isActive = true
        timeColumn.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    static func prepareList(_ scroll: NSView) {
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: minimumListHeight).isActive = true
    }

    static func footer(spacer: NSView, cancel: NSView, confirm: NSView) -> NSStackView {
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [spacer, cancel, confirm])
        stack.orientation = .horizontal
        stack.spacing = Design.Spacing.small
        return stack
    }

    static func attach(headings: NSView, lists: NSView, summary: NSView,
                       footer: NSView, to surface: NSView) {
        let stack = NSStackView(views: [headings, lists, summary, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.medium
        stack.setCustomSpacing(Design.Spacing.large, after: headings)
        stack.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: surface.topAnchor, constant: Design.Spacing.pane),
            stack.bottomAnchor.constraint(equalTo: surface.bottomAnchor,
                                          constant: -Design.Spacing.pane),
            stack.leadingAnchor.constraint(equalTo: surface.leadingAnchor,
                                           constant: Design.Spacing.pane),
            stack.trailingAnchor.constraint(equalTo: surface.trailingAnchor,
                                            constant: -Design.Spacing.pane)
        ])
        for child in stack.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }
}
