import AppKit
import QuickLookUI

// MARK: - Quick Look Presenter

/// Opens a file in the system Quick Look panel, and owns the panel's data for longer than
/// whatever asked for it.
///
/// `QLPreviewPanel.dataSource` is **non-retaining**. Pointing it at the view that opened the
/// panel means anything that removes that view — submitting the prompt, switching the display
/// panel's tab, closing the session — can leave the still-open system panel messaging a
/// deallocated object. This process-lifetime owner keeps the panel safe while still replacing
/// its single item every time another file is asked for.
///
/// One owner rather than one per call site, because the panel is a single system window: two
/// data sources would be two objects fighting over one panel's contents.
@MainActor
final class QuickLookPresenter: NSObject, @preconcurrency QLPreviewPanelDataSource {

    static let shared = QuickLookPresenter()

    private var previewURL: URL?

    /// Whether there is a file to preview. Asked *before* an affordance is offered, so a menu
    /// item that could only beep is left out rather than shown and then refused.
    static func canPreview(_ url: URL?) -> Bool {
        guard let url, url.isFileURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Shows the file, answering whether the panel opened. False means the file is gone —
    /// callers decide whether that is worth a beep or worth staying quiet about.
    @discardableResult
    func present(_ url: URL?) -> Bool {
        guard Self.canPreview(url), let url, let panel = QLPreviewPanel.shared() else {
            return false
        }

        previewURL = url
        panel.dataSource = self
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
        panel.makeKeyAndOrderFront(nil)
        panel.refreshCurrentPreviewItem()
        return true
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard index == 0, let previewURL else { return nil }
        return previewURL as NSURL
    }
}
