import AppKit
#if os(Linux)
@testable import CoreSlice
#endif

/// A real disclosure control hosted as one virtual table row. The section's attachment values
/// stay in the shared projection; only headers and expanded files reach this view layer.
final class SessionAttachmentTurnHeaderView: NSTableCellView {
    let sectionID: SessionAttachmentTurnSection.ID
    let disclosure: ThemedDisclosureRow

    init(
        section: SessionAttachmentTurnSection,
        isExpanded: Bool,
        onToggle: @escaping (Bool) -> Void
    ) {
        sectionID = section.id

        let title = Self.title(for: section)
        let count = Self.fileCount(section.attachments.count)

        let titleLabel = NSTextField(labelWithString: title.uppercased())
        titleLabel.applyFont(.detail(weight: .semibold))
        titleLabel.textColor = section.isLatest ? Design.Text.label : Design.Text.tertiary
        titleLabel.lineBreakMode = .byTruncatingTail

        let countLabel = NSTextField(labelWithString: count.uppercased())
        countLabel.applyFont(.numericDetail())
        countLabel.textColor = Design.Text.quaternary
        countLabel.setContentHuggingPriority(.required, for: .horizontal)

        let divider = SeparatorView(.vertical)
        divider.heightAnchor.constraint(equalToConstant: Design.Size.inlineButtonGlyph).isActive = true

        let content = NSStackView(views: [titleLabel, divider, countLabel])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = Design.Spacing.small

        disclosure = ThemedDisclosureRow(
            content: content,
            isExpanded: isExpanded,
            isCollapsible: !section.attachments.isEmpty,
            density: .compact
        )
        super.init(frame: .zero)

        disclosure.onToggle = section.attachments.isEmpty ? nil : onToggle
        disclosure.setAccessibilityLabel("\(title), \(count)")
        disclosure.setAccessibilityIdentifier(Self.accessibilityIdentifier(for: section.id))

        let rule = SeparatorView()
        addSubview(disclosure)
        addSubview(rule)
        NSLayoutConstraint.activate([
            disclosure.topAnchor.constraint(equalTo: topAnchor),
            disclosure.leadingAnchor.constraint(equalTo: leadingAnchor),
            disclosure.trailingAnchor.constraint(equalTo: trailingAnchor),
            disclosure.bottomAnchor.constraint(equalTo: rule.topAnchor),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func title(for section: SessionAttachmentTurnSection) -> String {
        switch section.id {
        case .upcoming:
            return L10n.string("Upcoming turn")
        case .betweenTurns:
            return L10n.string("Between turns")
        case .checkpoint:
            switch section.distanceFromLatest {
            case 0:
                return L10n.string("Latest turn")
            case 1:
                return L10n.string("Previous turn")
            case .some(let distance):
                return L10n.format("%lld turns ago", Int64(distance))
            case nil:
                return L10n.string("Previous turn")
            }
        }
    }

    private static func fileCount(_ count: Int) -> String {
        count == 1 ? L10n.string("1 file") : L10n.format("%lld files", Int64(count))
    }

    private static func accessibilityIdentifier(
        for id: SessionAttachmentTurnSection.ID
    ) -> String {
        switch id {
        case .upcoming:
            return "attachments.turn.upcoming"
        case .betweenTurns:
            return "attachments.turn.between"
        case .checkpoint(let checkpointID):
            return "attachments.turn.\(checkpointID.uuidString.lowercased())"
        }
    }
}
