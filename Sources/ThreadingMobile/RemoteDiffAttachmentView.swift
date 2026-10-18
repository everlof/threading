import Foundation
import NativeDiffCore
import SwiftUI
import ThreadingRemoteKit

/// A `.diff` attachment, drawn by the same renderer as the Review screen.
///
/// The Mac shows `display_compare_files` in a Compare tab, a panel surface the phone never had.
/// The comparison reaches the phone instead as a unified diff frozen into the session's
/// attachments when the agent showed it. Parsing runs off the main actor, and the rows are
/// virtualized by `DiffUIKitViewController`, so a large diff costs the viewport, not the file.
struct RemoteDiffAttachmentView: View {
    let data: Data

    @Environment(\.remoteTheme) private var theme
    @State private var document: DiffDocument?
    @State private var expandedPaths: Set<String> = []

    var body: some View {
        Group {
            if let document, document.files.isEmpty {
                ContentUnavailableView(
                    "No preview",
                    systemImage: RemoteAttachmentGlyph.name(for: .diff),
                    description: Text(MobileL10n.string("This diff has no text changes to show."))
                )
            } else if let document {
                RemoteDiffCollectionView(
                    document: document,
                    expandedPaths: $expandedPaths,
                    theme: theme,
                    isRefreshing: false,
                    onRefresh: nil
                )
            } else {
                MobileLoadingPlaceholder(MobileL10n.string("Reading diff…"))
            }
        }
        .task(id: data) {
            let parsed = await Self.document(from: data)
            guard !Task.isCancelled else { return }
            expandedPaths = DiffPresentationPolicy.default.initiallyExpandedPaths(in: parsed)
            document = parsed
        }
    }

    /// Parses on a worker: the bytes are bounded by the attachment cap, not by a frame.
    nonisolated static func document(from data: Data) async -> DiffDocument {
        await Task.detached(priority: .userInitiated) {
            DiffDocument(unifiedDiff: String(decoding: data, as: UTF8.self))
        }.value
    }
}
