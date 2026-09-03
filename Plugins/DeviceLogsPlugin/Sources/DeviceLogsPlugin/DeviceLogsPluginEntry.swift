import AppKit
import ThreadingDesignKit
import ThreadingPluginKit

/// The bundle's principal class.
///
/// `@objc` with an explicit name because `NSBundle` matches the principal class through the
/// Objective-C runtime, and a Swift-mangled name is not what the Info.plist can spell.
@objc(DeviceLogsPlugin)
public final class DeviceLogsPlugin: NSObject, ThreadingNativePlugin {

    private var pane: DeviceLogPaneViewController?

    /// The pane a test drives. The tools act on it, so a test of the tools needs to see it.
    @MainActor
    public var paneForTesting: DeviceLogPaneViewController? { pane }

    public override required init() { super.init() }

    public static var pluginAPIVersion: Int { ThreadingPluginAPI.version }

    public var pluginIdentifier: String { "codes.threading.plugin.devicelogs" }

    public func makePaneView(context: PluginContext) -> NSView {
        // The host builds panes on the main actor; the contract is `@objc` and so cannot say so.
        MainActor.assumeIsolated {
            let pane = DeviceLogPaneViewController(owningSessionID: context.argument("session"))
            apply(theme: context.theme)
            self.pane = pane
            return pane.view
        }
    }

    // MARK: - Tools

    public var pluginTools: [PluginTool] {
        [
            PluginTool(
                name: DeviceLogToolNames.search,
                title: "Device logs",
                detail: "Search, focus and fold the live log stream",
                symbol: "list.bullet.rectangle",
                summary: """
                    Search everything this chat's log pane has recorded, including rows that have scrolled out of view. Substring match, case-insensitive. Use it to find out what the app under development actually printed rather than guessing.
                    """,
                inputSchemaJSON: """
                    {"type":"object","properties":{ "text":{"type":"string","description":"Substring to look for."}, "limit":{"type":"integer","description":"Rows to return, newest last."}}, "required":["text"]}
                    """
            ),
            PluginTool(
                name: DeviceLogToolNames.focus,
                title: "Device logs",
                detail: "Search, focus and fold the live log stream",
                symbol: "line.3.horizontal.decrease",
                summary: """
                    Fold the pane down to what matters: rows matching the pattern and at or above the level are kept with two rows of context either side, everything else collapses into a line saying how many are hidden. Nothing is deleted and the user can open any fold. The pane's own controls move to match, so the person watching can see what you asked for.
                    """,
                inputSchemaJSON: """
                    {"type":"object","properties":{ "pattern":{"type":"string","description":"Substring that marks a row as interesting."}, "minimum_level":{"type":"string","enum":["debug","info","notice","warning","error","fault"], "description":"Rows below this level are folded away."}}}
                    """
            ),
            PluginTool(
                name: DeviceLogToolNames.clearFocus,
                title: "Device logs",
                detail: "Search, focus and fold the live log stream",
                symbol: "xmark.circle",
                summary: "Unfold everything and clear the pane's filter.",
                inputSchemaJSON: #"{"type":"object","properties":{}}"#
            ),
            PluginTool(
                name: DeviceLogToolNames.timeRange,
                title: "Device logs",
                detail: "Search, focus and fold the live log stream",
                symbol: "clock",
                summary: """
                    Rows recorded between two instants, as ISO 8601 timestamps. Use it when you know when something happened — a crash, a request — and want what surrounded it. Rows whose line carried no timestamp are not in any range.
                    """,
                inputSchemaJSON: """
                    {"type":"object","properties":{ "from":{"type":"string","description":"ISO 8601 instant, inclusive."}, "to":{"type":"string","description":"ISO 8601 instant, inclusive."}}, "required":["from","to"]}
                    """
            ),
            PluginTool(
                name: DeviceLogToolNames.visible,
                title: "Device logs",
                detail: "Search, focus and fold the live log stream",
                symbol: "eye",
                summary: "What the pane is showing right now, after any focus you applied.",
                inputSchemaJSON: #"{"type":"object","properties":{}}"#
            ),
        ]
    }

    public func invokeTool(
        named name: String,
        argumentsJSON: String,
        completion: @escaping (String, Bool) -> Void
    ) {
        let arguments = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)))
            as? [String: Any] ?? [:]
        MainActor.assumeIsolated {
            guard let pane else {
                return completion("The log pane is not open.", true)
            }
            switch name {
            case DeviceLogToolNames.search:
                search(arguments, pane: pane, completion: completion)
            case DeviceLogToolNames.timeRange:
                timeRange(arguments, pane: pane, completion: completion)
            case DeviceLogToolNames.focus:
                let pattern = arguments["pattern"] as? String ?? ""
                let severity = DeviceLogToolLevels.severity(named: arguments["minimum_level"] as? String)
                guard !pattern.isEmpty || severity > 0 else {
                    return completion(
                        "Give a pattern, a minimum_level, or both — otherwise nothing is folded.",
                        true
                    )
                }
                pane.applyFocus(pattern: pattern, minimumSeverity: severity)
                let summary = pane.focusSummary
                completion(
                    "Focused. \(summary.shown) of \(summary.total) rows shown, "
                        + "\(summary.folded) folded into markers the user can open.",
                    false
                )
            case DeviceLogToolNames.clearFocus:
                pane.applyFocus(pattern: "", minimumSeverity: 0)
                completion("Cleared. All \(pane.focusSummary.total) rows are shown.", false)
            case DeviceLogToolNames.visible:
                let rows = pane.visibleRowsForTools(limit: DeviceLogToolLimits.rowsPerAnswer)
                let summary = pane.focusSummary
                completion(
                    DeviceLogToolFormatting.answer(
                        rows: rows, total: summary.shown, subject: "on screen"
                    ),
                    false
                )
            default:
                completion("Device logs has no tool called \(name).", true)
            }
        }
    }

    /// Both readers ask the store on the queue that owns it, so the reply arrives off the main
    /// thread. The host hops it back; nothing here may assume otherwise.
    @MainActor
    private func search(
        _ arguments: [String: Any],
        pane: DeviceLogPaneViewController,
        completion: @escaping (String, Bool) -> Void
    ) {
        guard let text = arguments["text"] as? String, !text.isEmpty else {
            return completion("Give some text to search for.", true)
        }
        let limit = min(arguments["limit"] as? Int ?? DeviceLogToolLimits.rowsPerAnswer,
                        DeviceLogToolLimits.rowsPerAnswer)
        guard let recorder = pane.recorder else {
            return completion("This pane is not recording, so there is no history to search.", true)
        }
        recorder.read({ store -> (Int, [DeviceLogRow]) in
            let ids = try store.search(text, limit: DeviceLogToolLimits.searchScan)
            let tail = ids.suffix(limit)
            return (ids.count, try tail.compactMap { try store.row($0) })
        }) { result in
            switch result {
            case .success(let (total, rows)):
                completion(
                    DeviceLogToolFormatting.answer(
                        rows: rows, total: total, subject: "matching \"\(text)\""
                    ),
                    false
                )
            case .failure(let error):
                completion("The log store could not be searched: \(error).", true)
            }
        }
    }

    @MainActor
    private func timeRange(
        _ arguments: [String: Any],
        pane: DeviceLogPaneViewController,
        completion: @escaping (String, Bool) -> Void
    ) {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        func instant(_ key: String) -> Date? {
            guard let text = arguments[key] as? String else { return nil }
            return parser.date(from: text) ?? plain.date(from: text)
        }
        guard let from = instant("from"), let to = instant("to") else {
            return completion("Give `from` and `to` as ISO 8601 instants.", true)
        }
        guard from <= to else {
            return completion("`from` is after `to`.", true)
        }
        guard let recorder = pane.recorder else {
            return completion("This pane is not recording, so there is no history to look in.", true)
        }
        recorder.read({ store -> (Int, [DeviceLogRow]) in
            let ids = try store.ids(from: from, to: to)
            let tail = ids.suffix(DeviceLogToolLimits.rowsPerAnswer)
            return (ids.count, try tail.compactMap { try store.row($0) })
        }) { result in
            switch result {
            case .success(let (total, rows)):
                completion(
                    DeviceLogToolFormatting.answer(rows: rows, total: total, subject: "in that range"),
                    false
                )
            case .failure(let error):
                completion("The log store could not be read: \(error).", true)
            }
        }
    }

    public func apply(theme: PluginTheme) {
        try? HostThemeHandoff.install(encoded: theme.encodedTheme)
        MainActor.assumeIsolated { pane?.view.needsDisplay = true }
    }
}
