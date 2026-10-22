import AppKit

/// Places the opening action and its optional time and import choices in one row. A host owns
/// the actions; this view owns their spacing, ink alignment and compression order.
@MainActor
final class OpeningComposerActionRowView: NSView {
    init(primary: ThemedButton, importButton: ThemedButton? = nil,
         cancelEditButton: ThemedButton? = nil, curfewButton: ThemedIconButton? = nil,
         scheduleButton: ThemedIconButton? = nil) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("composer.session-start.actions")

        let controls: [NSView?] = [importButton, cancelEditButton, curfewButton,
                                   scheduleButton, primary]
        for control in controls.compactMap({ $0 }) {
            control.translatesAutoresizingMaskIntoConstraints = false
            addSubview(control)
        }

        NSLayoutConstraint.activate([
            primary.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            primary.trailingAnchor.constraint(equalTo: trailingAnchor),
            primary.topAnchor.constraint(equalTo: topAnchor),
            primary.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        if let scheduleButton {
            NSLayoutConstraint.activate([
                scheduleButton.centerYAnchor.constraint(equalTo: centerYAnchor),
                scheduleButton.trailingAnchor.constraint(equalTo: primary.leadingAnchor,
                                                         constant: -Design.Spacing.small)
            ])
        }
        if let curfewButton {
            let following: NSView = scheduleButton.map { $0 as NSView } ?? primary
            NSLayoutConstraint.activate([
                curfewButton.centerYAnchor.constraint(equalTo: centerYAnchor),
                curfewButton.trailingAnchor.constraint(equalTo: following.leadingAnchor,
                                                       constant: -Design.Spacing.small)
            ])
        }

        let trailingChoice: NSView = curfewButton.map { $0 as NSView }
            ?? scheduleButton.map { $0 as NSView } ?? primary
        if let importButton {
            // The quiet import offer gives up width before the primary action or time controls.
            importButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            NSLayoutConstraint.activate([
                importButton.leadingAnchor.constraint(equalTo: leadingAnchor,
                    constant: -importButton.opticalHorizontalInset),
                importButton.centerYAnchor.constraint(equalTo: centerYAnchor),
                importButton.heightAnchor.constraint(equalTo: primary.heightAnchor),
                importButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingChoice.leadingAnchor,
                    constant: -Design.Spacing.medium)
            ])
        }
        if let cancelEditButton {
            NSLayoutConstraint.activate([
                cancelEditButton.leadingAnchor.constraint(equalTo: leadingAnchor),
                cancelEditButton.centerYAnchor.constraint(equalTo: centerYAnchor),
                cancelEditButton.heightAnchor.constraint(equalTo: primary.heightAnchor),
                cancelEditButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingChoice.leadingAnchor,
                    constant: -Design.Spacing.medium)
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
