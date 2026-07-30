import AppKit

// MARK: - Persisted Panel

/// The on-disk form of a session's display panel — enough to rebuild its tabs after a relaunch,
/// plus the signature the agent last observed so a resume only re-states the panel when it changed.
struct PersistedPanel: Codable {
    var tabs: [PersistedTab]
    var activeTabID: String?

    /// The `signature` the agent was last known to be aware of. Compared at `initialize`: equal
    /// means the agent's own transcript already reflects the panel, so it is not re-described.
    var observedSignature: String?

    /// The drawer host's selection and open state, beside the panel's. Optional so every
    /// pre-drawer layout still decodes; the drawer's *tabs* ride in `tabs` with
    /// `host == PersistedTab.drawerHost`.
    var drawerActiveTabID: String? = nil
    var drawerOpen: Bool? = nil

    var panelTabs: [PersistedTab] { tabs.filter { $0.host == nil } }
    var drawerTabs: [PersistedTab] { tabs.filter { $0.host == PersistedTab.drawerHost } }
}

/// One tab, reduced to what survives a restart. Images are cached as PNGs (`cacheFile`) so a
/// generated screenshot — which has no file behind it — comes back too.
struct PersistedTab: Codable {
    enum Kind: String, Codable {
        case browser
        case html
        case image
        case review
        case info
        case terminal
        case files
        case attachments
        case extensionPanel
        case compare
    }

    var id: String
    var kind: Kind
    var title: String?
    var subtitle: String
    /// Browser: the current URL. Image: the original file or page URL, kept for the panel's actions.
    var url: String?
    /// HTML: the document itself.
    var html: String?
    /// Image: the PNG filename in the session's cache directory.
    var cacheFile: String?
    /// Review: the selected `GitReviewMode` raw value. Optional so older layouts still decode;
    /// defaulted so the other kinds' call sites need not mention it.
    var mode: String? = nil
    /// Extension panel: stable contribution owner and local panel identifier.
    var extensionIdentifier: String? = nil
    var extensionPanelID: String? = nil
    /// Compare: the two absolute paths and the optional per-side captions. `mode` above carries
    /// the `ImageCompareMode` raw value the way it carries review's.
    var compareOldPath: String? = nil
    var compareNewPath: String? = nil
    var compareOldTitle: String? = nil
    var compareNewTitle: String? = nil
    /// Which pane hosts the tab. Nil is the display panel — the value every layout written
    /// before the drawer became a host implicitly carries, which is the whole migration.
    var host: String? = nil

    static let drawerHost = "drawer"
}

extension PersistedPanel {

    /// A compact, order-sensitive fingerprint of the panel, used to decide whether the agent needs
    /// to be re-told its state. Two panels with the same tabs, order and selection compare equal.
    ///
    /// Panel-host tabs only: the drawer is the user's own furniture, and its tabs changing must
    /// not re-brief an agent about a panel that did not.
    var signature: String {
        let parts = panelTabs.map { tab -> String in
            switch tab.kind {
            case .browser: return "b:\(tab.url ?? "")"
            case .html: return "h:\(tab.title ?? "")·\(tab.subtitle)"
            case .image: return "i:\(tab.title ?? tab.url ?? "")"
            case .review: return "r:\(tab.mode ?? "")"
            case .info: return "n"
            case .terminal: return "t"
            case .files: return "f"
            case .attachments: return "a"
            case .extensionPanel:
                return "e:\(tab.extensionIdentifier ?? "")/\(tab.extensionPanelID ?? "")"
            case .compare:
                return "c:\(tab.compareOldPath ?? "")→\(tab.compareNewPath ?? "")"
            }
        }
        return parts.joined(separator: "|") + "#" + (activeTabID ?? "")
    }

    /// The prose handed to the agent at `initialize` when the panel changed while it was away.
    var agentDescription: String {
        var lines = [
            "## Current display panel",
            "This session's display panel already holds these tabs (they persist across restarts):"
        ]

        for (index, tab) in panelTabs.enumerated() {
            let active = tab.id == activeTabID ? " — active" : ""
            let detail: String
            switch tab.kind {
            case .browser:
                detail = "browser on \(tab.url ?? "a blank page")"
            case .html:
                detail = "document \"\(tab.title ?? "HTML")\""
            case .image:
                let name = tab.title ?? tab.url.flatMap { URL(string: $0)?.lastPathComponent } ?? "image"
                detail = "image \"\(name)\""
            case .review:
                detail = "git review panel (the user's diff view; they may stage and commit from it)"
            case .info:
                detail = "session info panel (the user can see this session's processes and "
                    + "listening ports, so a dev server you start is visible to them)"
            case .terminal:
                detail = "a shell the user opened in this project (their own terminal — you "
                    + "cannot type into it, and what they run there is not in your transcript)"
            case .files:
                detail = "a file tree of the project folder (the user is browsing the files "
                    + "you are working in)"
            case .attachments:
                detail = "visual files referenced in this session (images and PDFs)"
            case .extensionPanel:
                detail = "extension panel \"\(tab.title ?? "Panel")\""
            case .compare:
                let oldName = (tab.compareOldPath as NSString?)?.lastPathComponent ?? "old"
                let newName = (tab.compareNewPath as NSString?)?.lastPathComponent ?? "new"
                detail = "file comparison of \(oldName) against \(newName)"
            }
            lines.append("\(index). \(detail)\(active)")
        }

        lines.append(
            "Use panel_list_tabs for details or panel_activate_tab to bring one to the front. "
            + "If this differs from what you last did, the user changed it while you were away."
        )
        return lines.joined(separator: "\n")
    }
}

// MARK: - Display Pane Store

/// Persists each session's display-panel layout, so the tabs — including the browser's page and
/// any screenshots — come back after a relaunch, the way the window frame and pane width already do.
///
/// All access is on the main queue (the pane controller drives it, and the informing path hops to
/// main), so it needs no locking of its own.
final class DisplayPaneStore {

    static let shared = DisplayPaneStore()
    private init() {}

    private let fileManager = FileManager.default

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private let decoder = JSONDecoder()

    // MARK: Layout

    func loadLayout(for sessionID: SessionID) -> PersistedPanel? {
        guard let payload = StateManager.shared.loadPanelPayload(for: sessionID) else { return nil }
        return try? decoder.decode(PersistedPanel.self, from: Data(payload.utf8))
    }

    /// Replaces the stored *panel* tabs and selection, preserving the drawer's tabs and the
    /// observed signature (which tracks the agent's awareness, not the layout).
    func saveLayout(tabs: [PersistedTab], activeID: String?, for sessionID: SessionID) {
        var panel = loadLayout(for: sessionID) ?? PersistedPanel(tabs: [], activeTabID: nil, observedSignature: nil)
        panel.tabs = tabs + panel.drawerTabs
        panel.activeTabID = activeID
        write(panel, for: sessionID)
    }

    /// The drawer host's slice of the same payload: its tabs, its selection, and whether the
    /// drawer stands open for the session. One file per session either way — the drawer's tabs
    /// are the session's exactly as the panel's are.
    func saveDrawerLayout(
        tabs: [PersistedTab],
        activeID: String?,
        open: Bool?,
        for sessionID: SessionID
    ) {
        var panel = loadLayout(for: sessionID) ?? PersistedPanel(tabs: [], activeTabID: nil, observedSignature: nil)
        panel.tabs = panel.panelTabs + tabs
        panel.drawerActiveTabID = activeID
        if let open { panel.drawerOpen = open }
        write(panel, for: sessionID)
    }

    func signature(for sessionID: SessionID) -> String? {
        loadLayout(for: sessionID)?.signature
    }

    func observedSignature(for sessionID: SessionID) -> String? {
        loadLayout(for: sessionID)?.observedSignature
    }

    func setObserved(_ signature: String?, for sessionID: SessionID) {
        guard var panel = loadLayout(for: sessionID) else { return }
        panel.observedSignature = signature
        write(panel, for: sessionID)
    }

    /// The layout is a row; the images beside it are still files, because a PNG in a database
    /// is a PNG with extra steps.
    private func write(_ panel: PersistedPanel, for sessionID: SessionID) {
        do {
            let data = try encoder.encode(panel)
            StateManager.shared.savePanelPayload(String(decoding: data, as: UTF8.self), for: sessionID)
        } catch {
            ThreadingLogger.mcp.error("Could not encode display panel: \(error.localizedDescription)")
        }
    }

    // MARK: Image Cache

    /// Writes an image tab's PNG to the session cache, returning the filename to persist. Named by
    /// the tab id so it lines up with the tab and is trivially removed when the tab closes.
    func cacheImage(_ image: NSImage, tabID: UUID, for sessionID: SessionID) -> String? {
        guard let data = image.pngRepresentation else { return nil }
        let name = tabID.uuidString + "." + DisplayPaneStoreDefaults.imageExtension
        do {
            try fileManager.createDirectory(at: cacheDirectory(sessionID), withIntermediateDirectories: true)
            try data.write(to: cacheDirectory(sessionID).appendingPathComponent(name), options: .atomic)
            return name
        } catch {
            ThreadingLogger.mcp.error("Could not cache panel image: \(error.localizedDescription)")
            return nil
        }
    }

    func loadImage(_ name: String, for sessionID: SessionID) -> NSImage? {
        NSImage(contentsOf: cacheDirectory(sessionID).appendingPathComponent(name))
    }

    func removeCachedImage(_ name: String, for sessionID: SessionID) {
        try? fileManager.removeItem(at: cacheDirectory(sessionID).appendingPathComponent(name))
    }

    /// Saves a browser capture at a real path the terminal agent can read in addition to the MCP
    /// image block. These are evidence, not panel layout, so retain only a small rolling set.
    func cacheBrowserScreenshot(_ data: Data, for sessionID: SessionID) -> URL? {
        cacheBrowserArtifact(
            data,
            prefix: "browser-shot-",
            fileExtension: "png",
            maximumCount: DisplayPaneStoreDefaults.maximumBrowserScreenshots,
            for: sessionID
        )
    }

    func cacheBrowserTrace(_ data: Data, for sessionID: SessionID) -> URL? {
        cacheBrowserArtifact(
            data,
            prefix: "browser-trace-",
            fileExtension: "json",
            maximumCount: DisplayPaneStoreDefaults.maximumBrowserTraces,
            for: sessionID
        )
    }

    func cacheBrowserVisualArtifact(
        _ data: Data,
        kind: String,
        for sessionID: SessionID
    ) -> URL? {
        let safeKind = kind == "diff" ? "diff" : "actual"
        return cacheBrowserArtifact(
            data,
            prefix: "browser-visual-\(safeKind)-",
            fileExtension: "png",
            maximumCount: DisplayPaneStoreDefaults.maximumBrowserVisualArtifacts,
            for: sessionID
        )
    }

    private func cacheBrowserArtifact(
        _ data: Data,
        prefix: String,
        fileExtension: String,
        maximumCount: Int,
        for sessionID: SessionID
    ) -> URL? {
        let directory = cacheDirectory(sessionID)
        let name = prefix + UUID().uuidString.lowercased() + "." + fileExtension
        let url = directory.appendingPathComponent(name)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            pruneBrowserArtifacts(
                in: directory,
                prefix: prefix,
                fileExtension: fileExtension,
                maximumCount: maximumCount
            )
            return url
        } catch {
            ThreadingLogger.mcp.error(
                "Could not cache browser artifact: \(error.localizedDescription)"
            )
            return nil
        }
    }

    private func pruneBrowserArtifacts(
        in directory: URL,
        prefix: String,
        fileExtension: String,
        maximumCount: Int
    ) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys)
        ) else { return }
        let captures = files
            .filter {
                $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == fileExtension
            }
            .sorted {
                let left = (try? $0.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
                return left < right
            }
        for stale in captures.dropLast(maximumCount) {
            try? fileManager.removeItem(at: stale)
        }
    }

    // MARK: Cleanup

    /// Drops the stored layout and cache of every session not in the set, called when sessions are
    /// deleted so a removed session leaves nothing behind on disk.
    func retainOnly(sessionIDs: Set<SessionID>) {
        StateManager.shared.retainPanelLayouts(sessionIDs: sessionIDs)

        // The image caches are still directories on disk, so they are still swept by hand.
        let keep = Set(sessionIDs.map(\.uuidString))
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return }

        for entry in entries {
            let base = entry.deletingPathExtension().lastPathComponent
            if !keep.contains(base) {
                try? fileManager.removeItem(at: entry)
            }
        }
    }

    // MARK: Paths

    private var root: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Threading", isDirectory: true)
            .appendingPathComponent(DisplayPaneStoreDefaults.rootDirectory, isDirectory: true)
    }

    private func layoutFile(_ sessionID: SessionID) -> URL {
        root.appendingPathComponent(sessionID.uuidString).appendingPathExtension(DisplayPaneStoreDefaults.layoutExtension)
    }

    private func cacheDirectory(_ sessionID: SessionID) -> URL {
        root.appendingPathComponent(sessionID.uuidString, isDirectory: true)
    }
}

// MARK: - Defaults

enum DisplayPaneStoreDefaults {
    static let rootDirectory = "panels"
    static let layoutExtension = "json"
    static let imageExtension = "png"
    static let maximumBrowserScreenshots = 8
    static let maximumBrowserTraces = 4
    static let maximumBrowserVisualArtifacts = 8
}

// MARK: - PNG Encoding

private extension NSImage {
    var pngRepresentation: Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
