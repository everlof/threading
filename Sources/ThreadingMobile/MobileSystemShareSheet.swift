import SwiftUI
import UIKit

/// The native iOS share sheet. Sharing is an operating-system trust surface, so Threading
/// supplies the items and leaves destinations, previews, cancellation, and completion chrome to
/// `UIActivityViewController`.
struct MobileSharePayload: Identifiable {
    let id = UUID()
    let items: [URL]
}

struct MobileSystemShareSheet: UIViewControllerRepresentable {
    let items: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}
