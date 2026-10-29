import AppKit
import ThreadingDesignKit
import ThreadingPluginKit

/// The bundle's principal class.
///
/// `@objc` with an explicit name because `NSBundle` matches the principal class through the
/// Objective-C runtime, and a Swift-mangled name is not what the Info.plist can spell.
@objc(DeviceLogsPlugin)
public final class DeviceLogsPlugin: NSObject, ThreadingNativePlugin {

    private var workspace: DeviceLogWorkspaceViewController?
    @MainActor private var pane: DeviceLogPaneViewController? { workspace?.selectedPane }
    private(set) var appliedThemeCount = 0

    /// The pane a test drives. The tools act on it, so a test of the tools needs to see it.
    @MainActor
    public var paneForTesting: DeviceLogPaneViewController? { pane }
    @MainActor var workspaceForTesting: DeviceLogWorkspaceViewController? { workspace }

    public override required init() { super.init() }

    // This must remain the generation embedded when the plugin is compiled. Do not forward to
    // ThreadingPluginAPI.version: the installed bundle uses the host's framework at runtime.
    public static let pluginAPIVersion = 7

    public var pluginIdentifier: String { "codes.threading.plugin.devicelogs" }

    public func makePaneView(context: PluginContext) -> NSView {
        // Construction and all callbacks are main-actor isolated by the plugin contract.
        MainActor.assumeIsolated {
            let workspace = DeviceLogWorkspaceViewController(
                sessionID: context.argument("sessionID"),
                toolPath: nil,
                preferredMachineID: context.argument("deviceID"),
                checkoutPath: context.argument("checkoutPath"),
                deviceServices: context.deviceServices
            )
            self.workspace = workspace
            if context.argument("hostPaneSections") == "true" { return workspace.sectionView(.regular) }
            return workspace.view
        }
    }

    public func makePaneSectionView(identifier: String) -> NSView? {
        MainActor.assumeIsolated {
            guard let stream = DeviceLogPaneViewController.Stream(rawValue: identifier) else { return nil }
            return workspace?.sectionView(stream)
        }
    }

    public func setPaneSectionPresented(identifier: String, presented: Bool) {
        MainActor.assumeIsolated {
            guard let stream = DeviceLogPaneViewController.Stream(rawValue: identifier) else { return }
            workspace?.setSectionPresented(stream, presented: presented)
        }
    }

    public func activatePane(context: PluginContext) {
        MainActor.assumeIsolated {
            if let value = context.argument("stream"),
               let stream = DeviceLogPaneViewController.Stream(rawValue: value) { workspace?.selectStream(stream) }
            guard let deviceID = context.argument("deviceID") else { return }
            workspace?.selectMachine(id: deviceID)
        }
    }

    #if DEBUG
    /// The app's render test loads the real bundle through PluginKit; it cannot import this
    /// module's private Swift types. This fixture seam supplies a bounded synthetic capture
    /// through the production decoder, then uses the same table and source controls.
    @objc public func installBluetoothCaptureForTesting(_ data: Data) {
        MainActor.assumeIsolated {
            guard let workspace, data.count <= BluetoothPacketDecoder.Limits.chunkBytes else { return }
            var decoder = BluetoothPacketDecoder()
            guard let rows = try? decoder.append(data) else { return }
            workspace.setPresented(false)
            let phone = DeviceLogSourceOption.Machine(id: "bluetooth-fixture", title: "Test iPhone", isSimulator: false)
            let options = [
                DeviceLogSourceOption(machine: phone, title: "System log (USB)",
                    kind: .device(udid: phone.id, overNetwork: false)),
                DeviceLogSourceOption(machine: phone, title: L10n.format("Bluetooth (%@)", "USB"),
                    kind: .bluetooth(udid: phone.id, overNetwork: false, toolPath: nil)),
            ]
            workspace.discover = { $0(options) }
            workspace.sourceFactory = { _, _, _ in BufferedDeviceLogSource() }
            for pane in workspace.panes.values { pane.sourceFactory = workspace.sourceFactory }
            workspace.selectStream(.bluetooth)
            // Establish the fixture source identity through the normal selection path before
            // inserting rows, so a later visibility change resumes the same source.
            workspace.setPresented(true)
            guard let pane else { return }
            pane.installRowsForTesting(rows)
            workspace.panes[.regular]?.installRowsForTesting([
                .init(time: "09:41:00", level: "Info", process: "ExampleApp", subsystem: "Connection",
                    message: "Connected to the peripheral"),
                .init(time: "09:41:01", level: "Info", process: "ExampleApp", subsystem: "Connection",
                    message: "Received characteristic update"),
            ])
        }
    }

    @objc public func showBluetoothProfileBrowserForTesting() {
        MainActor.assumeIsolated { pane?.showBluetoothProfileBrowserForTesting() }
    }

    /// The product-shell evidence uses the loaded bundle and the production shared-panel tools.
    @objc public func installSharedDeviceLogsForTesting() {
        MainActor.assumeIsolated {
            guard let workspace else { return }
            workspace.setPresented(false)
            let phone = DeviceLogSourceOption.Machine(
                id: "device-logs-fixture", title: "David’s 16 Pro", isSimulator: false
            )
            let options = [
                DeviceLogSourceOption(machine: phone, title: "Chameleon",
                    kind: .app(deviceID: phone.id, bundleID: "com.example.chameleon", appName: "Chameleon"),
                    application: .init(bundleID: "com.example.chameleon", name: "Chameleon", executableName: "Ananke",
                        executablePath: "/private/var/containers/Bundle/Application/fixture/Chameleon.app/Ananke")),
                DeviceLogSourceOption(machine: phone, title: "OtherApp",
                    kind: .app(deviceID: phone.id, bundleID: "com.example.otherapp", appName: "OtherApp")),
                DeviceLogSourceOption(machine: phone, title: "System log (USB)",
                    kind: .device(udid: phone.id, overNetwork: false)),
            ]
            workspace.discover = { $0(options) }
            workspace.sourceFactory = { _, _, _ in BufferedDeviceLogSource() }
            for pane in workspace.panes.values { pane.sourceFactory = workspace.sourceFactory }
            workspace.selectStream(.regular)
            workspace.setPresented(true)
            guard let regular = workspace.panes[.regular] else { return }
            regular.selectAppForTesting(bundleID: "com.example.chameleon", route: .system)
            regular.installRowsForTesting([
                .init(time: "09:41:00.001", level: "Info", process: "Ananke", subsystem: "com.example.chameleon",
                    message: "[AirLab] TX NS", id: "shared-log-tx-ns", deviceID: phone.id,
                    bundleID: "com.example.chameleon", pid: 4242, category: "Bluetooth", source: .stdout),
                .init(time: "09:41:00.012", level: "Info", process: "OtherApp", subsystem: "com.example.otherapp",
                    message: "Background refresh completed", id: "shared-log-other-app", deviceID: phone.id,
                    bundleID: "com.example.otherapp", pid: 5252, category: "Lifecycle", source: .system),
                .init(time: "09:41:00.024", level: "Info", process: "Ananke", subsystem: "com.example.chameleon",
                    message: "[AirLab] RX ANCS CP", id: "shared-log-rx-cp", deviceID: phone.id,
                    bundleID: "com.example.chameleon", pid: 4242, category: "Bluetooth", source: .stdout),
                .init(time: "09:41:00.036", level: "Info", process: "Ananke", subsystem: "com.example.chameleon",
                    message: "Scene became active", id: "shared-log-unrelated", deviceID: phone.id,
                    bundleID: "com.example.chameleon", pid: 4242, category: "Lifecycle", source: .system),
                .init(time: "09:41:00.048", level: "Error", process: "Ananke", subsystem: "com.example.chameleon",
                    message: "[AirLab] TX DS", id: "shared-log-tx-ds", deviceID: phone.id,
                    bundleID: "com.example.chameleon", pid: 4242, category: "Bluetooth", source: .stderr),
            ])
        }
    }
    #endif

    // MARK: - Tools

    public var pluginTools: [PluginTool] {
        DeviceLogSharedToolDefinitions.tools + DeviceLogSharedToolDefinitions.bluetoothTools + [
            PluginTool(
                name: DeviceLogToolNames.search,
                title: "Device logs",
                detail: "Search, focus and fold the live log stream",
                symbol: "list.bullet.rectangle",
                summary: """
                    Search everything the selected Device Logs tab has recorded, including rows that have scrolled out of view. Regular Logs and Bluetooth have separate histories. Substring match, case-insensitive. Use it to find out what the app under development actually printed rather than guessing.
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
                    Fold the selected Device Logs tab down to what matters: rows matching the pattern and at or above the level are kept with two rows of context either side, everything else collapses into a line saying how many are hidden. In the Bluetooth tab, packets "app" keeps only packets decoded by the project's .threading/bluetooth.yaml and "complete" only those whose bytes fit their definition exactly. Nothing is deleted and the user can open any fold. The tab's own controls move to match, so the person watching can see what you asked for.
                    """,
                inputSchemaJSON: """
                    {"type":"object","properties":{ "pattern":{"type":"string","description":"Substring that marks a row as interesting."}, "minimum_level":{"type":"string","enum":["debug","info","notice","warning","error","fault"], "description":"Rows below this level are folded away."}, "packets":{"type":"string","enum":["all","app","complete"],"description":"Bluetooth tab: all packets, only packets decoded by the project's packet definitions (subsystem App), or only those decoded without a misfit warning."}}}
                    """
            ),
            PluginTool(
                name: DeviceLogToolNames.clearFocus,
                title: "Device logs",
                detail: "Search, focus and fold the live log stream",
                symbol: "xmark.circle",
                summary: "Unfold everything and clear the selected Device Logs tab's filter.",
                inputSchemaJSON: #"{"type":"object","properties":{}}"#
            ),
            PluginTool(
                name: DeviceLogToolNames.timeRange,
                title: "Device logs",
                detail: "Search, focus and fold the live log stream",
                symbol: "clock",
                summary: """
                    Rows recorded in the selected Device Logs tab between two instants, as ISO 8601 timestamps. Use it when you know when something happened — a crash, a request — and want what surrounded it. Rows whose line carried no timestamp are not in any range.
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
                summary: "What the selected Device Logs tab is showing right now, after any focus you applied.",
                inputSchemaJSON: #"{"type":"object","properties":{}}"#
            ),
            PluginTool(
                name: DeviceLogToolNames.linked,
                title: "Device logs",
                detail: "Search, focus and fold the live log stream",
                symbol: "link",
                summary: """
                    Find the row in the other Device Logs tab that a row is about, by the logs: rules in the project's .threading/bluetooth.yaml: an app log line's Bluetooth packet, or a packet's app log line. Give text from the row in the selected tab; the newest held row containing it is used. Both rows are returned and the partner is selected in its tab. Rows link only when the rule's characteristic, direction and key agree, nearest in time within the rule's window.
                    """,
                inputSchemaJSON: """
                    {"type":"object","properties":{ "text":{"type":"string","description":"Substring of the row to link from, in the selected tab."}}, "required":["text"]}
                    """
            ),
            PluginTool(
                name: DeviceLogToolNames.timelines,
                title: "Bluetooth logs",
                detail: "Read a paired iPhone's Bluetooth packets",
                symbol: "timeline.selection",
                summary: """
                    Timelines of recorded tries of firmware updates (DFU) and other procedures the project's Bluetooth definitions declare (include: [nordic-dfu] or procedures:), newest first. Each starts with how the try ended and why, then the firmware before and after, the steps reached, and every step, link event (connection parameters, disconnection reasons, the device coming back as its bootloader under another address), error, transfer progress and checksum check, with offsets from the start. Kept across captures on this Mac. Use it to explain a failed update.
                    """,
                inputSchemaJSON: """
                    {"type":"object","properties":{ "last":{"type":"integer","description":"How many of the most recent tries to return (default 5)."}}}
                    """
            ),
            PluginTool(
                name: DeviceLogToolNames.bluetooth,
                title: "Bluetooth logs",
                detail: "Read a paired iPhone's Bluetooth packets",
                symbol: "antenna.radiowaves.left.and.right",
                summary: """
                    Open the Bluetooth tab and select packet capture for one paired iPhone in this chat's Device Logs pane. Requires its exact hardware UDID, external idevicebtlogger (brew install libimobiledevice), and Apple's Bluetooth logging profile on the phone. Captures phone-wide HCI traffic, not app stdout or an over-the-air sniffer. Prefer bluetooth_state/configure/read/wait/reveal for explicit Bluetooth targeting and shared filters; visible/search/time_range are legacy selected-tab queries. Starting is not proof of received packets; bluetooth_state reports reader status. Use bluetooth_state with refresh:true after connecting a phone or installing tools. A running Bluetooth capture continues while hidden and stops when its tab or session closes.
                    """,
                inputSchemaJSON: #"{"type":"object","properties":{"device_id":{"type":"string","description":"Exact paired iPhone hardware UDID."}},"required":["device_id"]}"#,
                paneSectionToReveal: "bluetooth"
            ),
        ]
    }

    public func invokeTool(
        named name: String,
        argumentsJSON: String,
        completion: @escaping (String, Bool) -> Void
    ) {
        if let route = DeviceLogSharedToolDefinitions.route(name) {
            MainActor.assumeIsolated {
                DeviceLogSharedToolAdapter.invoke(
                    named: route.name, argumentsJSON: argumentsJSON, pane: workspace?.panes[route.stream],
                    stream: route.stream.rawValue,
                    completion: completion
                )
            }
            return
        }
        let arguments = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)))
            as? [String: Any] ?? [:]
        MainActor.assumeIsolated {
            guard let pane else {
                return completion("The log pane is not open.", true)
            }
            switch name {
            case DeviceLogToolNames.bluetooth:
                guard let deviceID = arguments["device_id"] as? String, !deviceID.isEmpty else {
                    return completion("Give the paired iPhone's exact device_id (hardware UDID).", true)
                }
                guard workspace?.isPresented == true else {
                    return completion("Show this chat's Device Logs pane before starting Bluetooth capture (device_log_prepare can reveal it).", true)
                }
                guard workspace?.selectBluetooth(deviceID: deviceID) == true else {
                    return completion("That iPhone has no discovered Bluetooth source. Connect and trust it, then Rescan in Device Logs.", true)
                }
                completion("Starting Bluetooth capture for \(deviceID). Use visible to check for packets or setup errors.", false)
            case DeviceLogToolNames.search:
                search(arguments, pane: pane, completion: completion)
            case DeviceLogToolNames.timelines:
                let last = min(max((arguments["last"] as? Int) ?? 5, 1), BluetoothProcedureHistory.Limits.attempts)
                // The worker saves within a second; read the file off the main actor.
                Task.detached(priority: .userInitiated) {
                    let text = BluetoothProcedureFormatting.all(BluetoothProcedureHistory.load(), last: last)
                    completion(text.isEmpty
                        ? "No procedure tries recorded. Firmware updates are recorded when the project's .threading/bluetooth.yaml includes nordic-dfu or nordic-legacy-dfu, or declares procedures:, while a Bluetooth capture runs."
                        : text, false)
                }
            case DeviceLogToolNames.linked:
                guard let text = arguments["text"] as? String, !text.isEmpty, let workspace else {
                    return completion("Give text from the row to link from.", true)
                }
                let needle = Array(text.lowercased().utf8)
                guard let row = pane.heldRows.last(where: { LogFocus.contains($0.message, needle) }) else {
                    return completion("No row in this tab contains \u{201C}\(text)\u{201D}.", true)
                }
                guard let linked = workspace.revealLinked(to: row, from: workspace.selectedStream) else {
                    let reason = workspace.panes[.bluetooth]?.logLinks.isEmpty != false
                        ? "The Bluetooth definitions have no logs: rules, so nothing links."
                        : "No row in the other tab matches it by the logs: rules within their window."
                    return completion("Found:\n" + DeviceLogToolFormatting.lines([row]) + "\n" + reason, false)
                }
                completion("Linked:\n" + DeviceLogToolFormatting.lines([row, linked]), false)
            case DeviceLogToolNames.timeRange:
                timeRange(arguments, pane: pane, completion: completion)
            case DeviceLogToolNames.focus:
                let pattern = arguments["pattern"] as? String ?? ""
                let severity = DeviceLogToolLevels.severity(named: arguments["minimum_level"] as? String)
                let packets = (arguments["packets"] as? String).flatMap { name in
                    BluetoothPacketFilter.allCases.first { $0.toolName == name }
                }
                guard !pattern.isEmpty || severity > 0 || packets.map({ $0 != .all }) == true else {
                    return completion(
                        "Give a pattern, a minimum_level, packets, or a combination — otherwise nothing is folded.",
                        true
                    )
                }
                if let packets, packets != pane.packetFilter { pane.setPacketFilter(packets) }
                pane.applyFocus(pattern: pattern, minimumSeverity: severity)
                let summary = pane.focusSummary
                pane.noteAgentAction(Self.note(focusing: pattern, severity: severity))
                completion(
                    "Focused. \(summary.shown) of \(summary.total) rows shown, "
                        + "\(summary.folded) folded into markers the user can open.",
                    false
                )
            case DeviceLogToolNames.clearFocus:
                pane.setPacketFilter(.all)
                pane.applyFocus(pattern: "", minimumSeverity: 0)
                pane.clearAgentNote()
                completion("Cleared. All \(pane.focusSummary.total) rows are shown.", false)
            case DeviceLogToolNames.visible:
                let rows = pane.visibleRowsForTools(limit: DeviceLogToolLimits.rowsPerAnswer)
                let summary = pane.focusSummary
                completion(
                    DeviceLogToolFormatting.answer(
                        rows: rows, total: summary.shown, subject: "on screen"
                    ) + "\nReader: " + pane.readerStatus,
                    false
                )
            default:
                completion("Device logs has no tool called \(name).", true)
            }
        }
    }

    /// What the footer says the agent did. Short, because it shares a line with the row count and
    /// the rate, and a note nobody can read past is not visibility.
    private static func note(searched text: String, matches: Int) -> String {
        "agent searched \u{201C}\(text)\u{201D} · \(matches) \(matches == 1 ? "match" : "matches")"
    }

    private static func note(focusing pattern: String, severity: Int) -> String {
        if pattern.isEmpty { return "agent focused on level" }
        return "agent focused on \u{201C}\(pattern)\u{201D}"
    }

    private static func note(range total: Int) -> String {
        "agent read a time range · \(total) \(total == 1 ? "row" : "rows")"
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
                // The reply arrives on the queue that owns the store, and the pane is main-actor.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        pane.noteAgentAction(
                            Self.note(searched: text, matches: total),
                            searching: text
                        )
                    }
                }
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
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        pane.noteAgentAction(Self.note(range: total))
                    }
                }
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
        appliedThemeCount += 1
        MainActor.assumeIsolated {
            try? HostThemeHandoff.install(encoded: theme.encodedTheme)
            if let workspace {
                if workspace.usesHostSections { workspace.repaintSections() }
                else { AppThemeRefresh.repaint(workspace.view) }
            }
        }
    }
}
