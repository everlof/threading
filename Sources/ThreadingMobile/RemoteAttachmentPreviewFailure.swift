import Foundation

/// Separates lifecycle cancellation from a preview failure a person can act on.
///
/// SwiftUI cancels a page's `.task` whenever a lazy gallery page leaves the retained window.
/// URL loading may surface that either as `CancellationError` or `URLError.cancelled`; neither
/// means the attachment is degraded, and neither may replace a later page's content with error
/// UI or enter diagnostics.
enum RemoteAttachmentPreviewFailure {
    static func message(for error: Error) -> String? {
        if error is CancellationError { return nil }
        if let urlError = error as? URLError, urlError.code == .cancelled { return nil }
        return error.localizedDescription
    }
}
