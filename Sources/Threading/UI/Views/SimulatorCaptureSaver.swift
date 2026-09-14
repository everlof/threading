import AppKit
import UniformTypeIdentifiers

/// Where the Simulator pane's snapshots and recordings go, and how they are revealed or re-saved.
///
/// Default captures land in a "Threading" folder — images under Pictures, movies under Movies, the
/// OS-idiomatic homes — and are revealed in Finder so the location never has to be hunted for. A
/// Save As… sheet and clipboard copy are offered for when the default is not wanted.
@MainActor
enum SimulatorCaptureSaver {
    /// The default capture folder, created on demand. `nonisolated`: bounded filesystem work.
    nonisolated static func defaultDirectory(video: Bool) -> URL {
        let base = FileManager.default.urls(
            for: video ? .moviesDirectory : .picturesDirectory, in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
        let directory = base.appendingPathComponent("Threading", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// `iPhone 17 Pro 2026-09-14 at 15.42.07.png` — Finder-safe, sortable, and human-readable.
    static func suggestedName(device: SimulatorDevice, fileExtension: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let safeDevice = device.name.replacingOccurrences(of: "/", with: "-")
        return "\(safeDevice) \(formatter.string(from: Date())).\(fileExtension)"
    }

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Write `data` into the default folder under `suggestedName`, returning the URL, or nil on
    /// failure. Does not reveal — the caller decides.
    @discardableResult
    nonisolated static func write(_ data: Data, suggestedName: String, video: Bool) -> URL? {
        let url = defaultDirectory(video: video).appendingPathComponent(suggestedName)
        return writeData(data, to: url) ? url : nil
    }

    /// Write bytes to an exact URL. `nonisolated`: bounded I/O, not main-actor work.
    @discardableResult
    nonisolated static func writeData(_ data: Data, to url: URL) -> Bool {
        (try? data.write(to: url, options: .atomic)) != nil
    }

    static func copyImage(_ image: NSImage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    /// Present a Save As… sheet, then hand the chosen destination to `writeTo` and reveal it.
    static func saveAs(
        suggestedName: String,
        contentType: UTType,
        video: Bool,
        from window: NSWindow?,
        writeTo: @escaping (URL) -> Bool
    ) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [contentType]
        panel.canCreateDirectories = true
        panel.directoryURL = defaultDirectory(video: video)
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url, writeTo(url) else { return }
            reveal(url)
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(panel.runModal())
        }
    }
}
