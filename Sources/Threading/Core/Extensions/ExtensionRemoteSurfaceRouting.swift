import Foundation
import ThreadingExtensionKit

struct ExtensionRemoteSurfaceFrameValue: Equatable {
    let metadata: ExtensionRemoteSurfaceFrame
    let pixels: Data
}

@MainActor
protocol ExtensionRemoteSurfaceConsumer: AnyObject {
    func remoteSurfaceDidConnect(definition: ExtensionRemoteSurface)
    func remoteSurfaceDidReceive(_ frame: ExtensionRemoteSurfaceFrameValue) -> Bool
    func remoteSurfaceDidDisconnect(message: String)
}

/// View-owned handle for one presentation of a declared surface.
///
/// Cancelling the handle tears down only that presentation. The companion may continue serving
/// the same declared surface to another panel or session.
@MainActor
final class ExtensionRemoteSurfaceSubscription {
    let presentationID: String

    private var viewportHandler: ((ExtensionRemoteSurfaceViewport) -> Void)?
    private var inputHandler: ((ExtensionRemoteSurfaceInput) -> Void)?
    private var cancellation: (() -> Void)?

    init(
        presentationID: String,
        viewport: @escaping (ExtensionRemoteSurfaceViewport) -> Void,
        input: @escaping (ExtensionRemoteSurfaceInput) -> Void,
        cancellation: @escaping () -> Void
    ) {
        self.presentationID = presentationID
        viewportHandler = viewport
        inputHandler = input
        self.cancellation = cancellation
    }

    deinit {
        cancellation?()
    }

    func updateViewport(
        width: Double,
        height: Double,
        scale: Double,
        isVisible: Bool
    ) {
        viewportHandler?(.init(
            presentationID: presentationID,
            width: width,
            height: height,
            scale: scale,
            isVisible: isVisible
        ))
    }

    func send(_ input: ExtensionRemoteSurfaceInput) {
        guard input.presentationID == presentationID else { return }
        inputHandler?(input)
    }

    func cancel() {
        guard let cancellation else { return }
        self.cancellation = nil
        viewportHandler = nil
        inputHandler = nil
        cancellation()
    }
}
