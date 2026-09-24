import AppKit

/// The content of a Simulator presenter window: the adopted device's screen and nothing else.
///
/// It is a *mirror* of the pane, not a second pane. The pane keeps the lease, the stream, consent
/// and every control; this view shows the frames and touch marks the pane hands it and gives the
/// pane back every gesture made on it, so pointer and keyboard input converge on the one consented
/// route whichever window they arrive through. Notes and the accessibility inspector stay in the
/// pane — a window made to be shared on a call shows the device as the device.
@MainActor
final class SimulatorPresenterViewController: NSViewController {

    private enum Layout {
        /// Room around the device so its rounded corners read as a device, not a crop.
        static let margin = Design.Spacing.medium
    }

    let screenView: SimulatorScreenView = {
        let screen = SimulatorScreenView()
        screen.setAccessibilityLabel(L10n.string("Simulator screen"))
        screen.setAccessibilityIdentifier("simulator.presenter.screen")
        return screen
    }()

    /// Chords typed while this window is key; the pane answers them exactly as it does its own.
    var onKeyEquivalent: ((NSEvent) -> Bool)?

    private let ground: ThemedSurfaceView = {
        let ground = ThemedSurfaceView()
        ground.applySurface(fill: Design.Surface.ground, radius: .fixed(0))
        return ground
    }()

    override func loadView() {
        let root = KeyEquivalentScopeView()
        root.setAccessibilityIdentifier("simulator.presenter")
        root.onKeyEquivalent = { [weak self] event in self?.onKeyEquivalent?(event) ?? false }
        root.addSubview(ground)
        root.addSubview(screenView)
        NSLayoutConstraint.activate([
            ground.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            ground.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            ground.topAnchor.constraint(equalTo: root.topAnchor),
            ground.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            screenView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Layout.margin),
            screenView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Layout.margin),
            screenView.topAnchor.constraint(equalTo: root.topAnchor, constant: Layout.margin),
            screenView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Layout.margin),
        ])
        view = root
    }

    /// The content size that shows a frame of `imageSize` at `height` points tall, margins
    /// included — what the window asks for so the device fills it without letterboxing.
    static func contentSize(forImageSize imageSize: NSSize, height: CGFloat) -> NSSize {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return NSSize(width: height / 2, height: height)
        }
        let screenHeight = max(1, height - Layout.margin * 2)
        let screenWidth = screenHeight * imageSize.width / imageSize.height
        return NSSize(width: ceil(screenWidth + Layout.margin * 2), height: ceil(height))
    }
}
