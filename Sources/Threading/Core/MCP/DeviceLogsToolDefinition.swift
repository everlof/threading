import Foundation

/// Available before a plugin loads, including to clients that retain their initial tools list.
enum DeviceLogsToolDefinition {
    static let definition = MCPToolDefinition(
        tool: .deviceLogs,
        name: "device_logs",
        groupID: "device-log",
        family: .deviceLog,
        annotations: MCPToolAnnotations(
            readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false
        ),
        title: "Device logs",
        detail: "Configure and read the same log panel the user sees.",
        symbol: "list.bullet.rectangle",
        decodeArguments: { try $0.decode(DeviceLogsArguments.self, forKey: .arguments) },
        observesPanel: true,
        executeArguments: { handler, arguments, sessionID, completion in
            handler.deviceLogs(arguments, for: sessionID, completion: completion)
        },
        description: """
            Open, configure and read this session's shared Device Logs panel. Start with action:state. \
            This tool is available before the plugin loads; no plugin-tool rediscovery or tap setup \
            is needed. stream is regular (default) or bluetooth and always targets that panel.

            Whenever you choose or change a log filter for your investigation, first apply it with \
            action:configure so the user can follow the same selection. Use exact device_id and \
            source title or bundle_id from state, then read/wait without repeating filters. Explain \
            the selected app/source and filter briefly. Use expected_revision from state/configure \
            to respect manual changes; on stale_revision inspect the returned state before retrying. \
            Omitted configure fields keep their values. clear_filter:true resets previous predicates \
            before applying this call's fields; use it when starting a different investigation. \
            Filters combine with AND, levels with OR. A process can include Apple's framework logs; \
            select an observed subsystem/category when you need only the app's own logging. \
            Prefer bundle identity over a PID that changes when the app restarts.

            state accepts refresh:true for asynchronous source discovery; discovery_pending means \
            call state again for the completed catalog. configure returns the actual panel state. \
            Check its source, filter and capture status, then verify received rows. System logs may \
            redact private values and do not automatically include print()/stdout/stderr. console \
            may relaunch the app. device_log_prepare is only needed for optional stdout/stderr tap \
            setup. Installation or source unavailability is not successful capture.

            read returns up to 50 rows in capture order, stable IDs, revision, cursor, has_more and \
            loss/truncation metadata. Continue with cursor even after an empty bounded scan when \
            has_more is true. pending means the shared context projection is preparing. wait uses \
            the last read cursor for new matches (without one, starts at the current tail), for up \
            to timeout_seconds (default 5, maximum 30). Filter/source changes are reported explicitly. \
            read/wait never move scroll or selection. reveal highlights row_id, optionally through \
            through_row_id (at most 200 capture rows); use it to show exact evidence you discuss.

            Bluetooth uses the same actions with stream:bluetooth and packets:all/app/complete. \
            It captures phone-wide HCI packets; bundle_id/process/pid/route are unsupported there. \
            If the panel cannot capture a needed source and you use a separate reader, say so and \
            mirror supported filters in the panel; do not claim both views contain the same rows.
            """,
        inputSchema: MCPInputSchema(properties: properties, required: ["action"])
    )

    // The façade advertises the union; each action is validated by the plugin's existing adapter.
    // NativePluginToolRoutingTests checks this against the shipped plugin's declarations.
    static let properties: [String: MCPPropertySchema] = [
        "action": .init(type: .string, description: "state, configure, read, wait or reveal."),
        "stream": .init(type: .string, description: "regular (default) or bluetooth."),
        "refresh": .init(type: .boolean, description: "state only: rescan devices/apps asynchronously."),
        "expected_revision": .init(type: .integer, description: "configure/read/wait/reveal: revision returned by state; stale calls refuse without overwriting manual changes."),
        "device_id": .init(type: .string, description: "configure: exact state.devices[].id."),
        "source": .init(type: .string, description: "configure: exact state.sources[].title on that device."),
        "route": .init(type: .string, description: "configure, regular only: system, app_log or console from that source's routes. console may relaunch the app."),
        "bundle_id": .init(type: .string, description: "configure, regular only: exact installed app identity from state; empty clears."),
        "process": .init(type: .string, description: "configure, regular only: exact observed process name; empty clears."),
        "pid": .init(type: .integer, description: "configure, regular only: exact process ID; 0 clears. Prefer bundle_id across app restarts."),
        "packets": .init(type: .string, description: "configure, bluetooth only: all, app (project decoded), complete (fully decoded)."),
        "text": .init(type: .string, description: "configure: shared text filter, at most 512 UTF-8 bytes; empty clears. Searches message/process/subsystem/category."),
        "text_mode": .init(type: .string, description: "configure: literal or regex. Literal folds ASCII case; regex uses bounded ICU matching (4096 characters, 2ms per field, 250ms per projection)."),
        "levels": .init(type: .array, description: "configure: debug, info, notice, warning, error, fault; ORed. [] includes all levels, including debug.", items: .init(type: .string)),
        "subsystem": .init(type: .string, description: "configure: exact observed subsystem; empty clears. Narrows framework noise within an app process."),
        "category": .init(type: .string, description: "configure: exact observed category; empty clears."),
        "follow": .init(type: .boolean, description: "configure: follow incoming rows in the visible panel."),
        "paused": .init(type: .boolean, description: "configure: pause/resume capture. Leave false when observing live output."),
        "show_context": .init(type: .boolean, description: "configure: include surrounding rows and expanded folds; read rows mark is_match."),
        "clear_filter": .init(type: .boolean, description: "configure: reset all predicates (including packet mode and severity) before applying this call's fields."),
        "cursor": .init(type: .string, description: "read/wait: continuation cursor returned by read/wait."),
        "limit": .init(type: .integer, description: "read/wait: maximum returned rows, 1–50."),
        "timeout_seconds": .init(type: .number, description: "wait only: 0–30 seconds, default 5."),
        "row_id": .init(type: .string, description: "reveal only, required: exact stable row ID from read/wait."),
        "through_row_id": .init(type: .string, description: "reveal only: inclusive end of a selection of at most 200 capture rows.")
    ]
}
