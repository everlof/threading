import AppKit

// MARK: - Settings Card

/// A rounded panel that stacks rows with hairline dividers between them — the container every
/// group of settings sits in.
final class SettingsCard: NSView {

    init(rows: [NSView]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        applySurface(
            fill: Design.Surface.panel,
            radius: .panel,
            border: Design.Surface.border,
            glow: true
        )

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        // The stack goes in first, so every anchor below shares an ancestor at activation —
        // constraining a view before it is in the hierarchy raises an exception AppKit swallows,
        // leaving the card silently unbuilt.
        addSubview(stack)
        // The two ends are where the card's corner is still sweeping, and the row there pads
        // itself by `medium` — enough under a 10pt corner, and half of what a 40pt one asks. The
        // card pays the difference, so the first row's title clears the curve by the same margin
        // as the column beside it, and the rhythm *between* rows is untouched.
        let endPadding = Design.Spacing.inset - Design.Spacing.medium
        let ends = [
            stack.topAnchor.constraint(equalTo: topAnchor, constant: endPadding),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -endPadding)
        ]
        NSLayoutConstraint.activate(ends + [
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        holdAtContentInset(ends, less: Design.Spacing.medium)

        for (index, row) in rows.enumerated() {
            if index > 0 {
                let divider = NSView()
                divider.wantsLayer = true
                divider.applyLayerBackground(Design.Surface.border)
                divider.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(divider)
                // Starting on the label column, so it stays there when a broad corner moves the
                // column in.
                let start = divider.leadingAnchor.constraint(
                    equalTo: stack.leadingAnchor,
                    constant: Design.Spacing.inset
                )
                NSLayoutConstraint.activate([
                    divider.heightAnchor.constraint(equalToConstant: 1),
                    start,
                    divider.trailingAnchor.constraint(equalTo: stack.trailingAnchor)
                ])
                holdAtContentInset([start])
            }

            row.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: stack.trailingAnchor)
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
