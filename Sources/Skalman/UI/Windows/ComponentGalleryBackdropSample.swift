import AppKit

/// The gallery's concrete story for the otherwise-abstract `BackdropOverlay` contract.
@MainActor
final class ComponentGalleryBackdropSample: BackdropOverlay {

    private let label = NSTextField(
        labelWithString: L10n.string("Backdrop-aware ink")
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        label.applyFont(.control)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func applyInk(_ ink: Design.Ink) {
        applyLayerBackground(ink.surface)
        label.textColor = ink.base
    }
}
