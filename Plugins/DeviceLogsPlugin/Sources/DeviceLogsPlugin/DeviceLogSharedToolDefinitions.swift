import ThreadingPluginKit

/// The shared-panel contract. Legacy history tools remain available for existing conversations.
enum DeviceLogSharedToolDefinitions {
    private static let bluetoothPrefix = "bluetooth_"

    /// Explicit identities keep reads pinned to their stream even when a person changes tabs.
    static func route(_ name: String) -> (name: String, stream: DeviceLogPaneViewController.Stream)? {
        if names.contains(name) { return (name, .regular) }
        guard name.hasPrefix(bluetoothPrefix) else { return nil }
        let base = String(name.dropFirst(bluetoothPrefix.count))
        return names.contains(base) ? (base, .bluetooth) : nil
    }

    static var bluetoothTools: [PluginTool] {
        tools.map { declaration in
            PluginTool(
                name: bluetoothPrefix + declaration.name, title: "Bluetooth logs",
                detail: "Read and control this session's shared Bluetooth packet panel",
                symbol: declaration.symbol,
                summary: bluetoothSummary(declaration.name),
                inputSchemaJSON: declaration.name == DeviceLogToolNames.configure
                    ? configurationSchema(bluetooth: true) : declaration.inputSchemaJSON,
                paneSectionToReveal: "bluetooth"
            )
        }
    }

    private static func configurationSchema(bluetooth: Bool) -> String {
        let sourceFields = bluetooth
            ? #"""
                "packets":{"type":"string","enum":["all","app","complete"],"description":"All packets, project-decoded app packets, or fully decoded packets."}
                """#
            : #"""
                "route":{"type":"string","enum":["system","app_log","console"],"description":"App source route; system does not relaunch the app."},
                "bundle_id":{"type":"string","description":"Exact installed app bundle identity; empty clears."},
                "process":{"type":"string","description":"Exact observed process name; empty clears."},
                "pid":{"type":"integer","minimum":0}
                """#
        return """
            {"type":"object","properties":{
              "expected_revision":{"type":"integer","minimum":0},
              "device_id":{"type":"string","description":"Exact device identity from the target stream's state.devices."},
              "source":{"type":"string","description":"Exact source identity/title from the target stream's state.sources."},
              \(sourceFields),
              "text":{"type":"string","description":"Shared text filter, at most 512 UTF-8 bytes. Literal folds ASCII case only; regex is bounded to 4096 characters and 2ms per field, 250ms per projection."},
              "text_mode":{"type":"string","enum":["literal","regex"]},
              "levels":{"type":"array","items":{"type":"string","enum":["debug","info","notice","warning","error","fault"]},"uniqueItems":true},
              "subsystem":{"type":"string"},"category":{"type":"string"},
              "follow":{"type":"boolean"},"paused":{"type":"boolean"},
              "show_context":{"type":"boolean"},"clear_filter":{"type":"boolean"}
            },"additionalProperties":false}
            """
    }

    private static func bluetoothSummary(_ name: String) -> String {
        let operation: String
        switch name {
        case DeviceLogToolNames.state:
            operation = "Read the Bluetooth panel's actual device/source catalog, capture state, reader status, packet filter and project definition status. refresh:true invokes the panel's asynchronous Rescan; discovery_pending means read state again for results. Use bluetooth_configure, then bluetooth_read or bluetooth_wait."
        case DeviceLogToolNames.configure:
            operation = "Change the visible Bluetooth panel using exact device_id/source from bluetooth_state. packets selects all, app (project-decoded) or complete (fully decoded) packets. text/text_mode, levels, subsystem/category, show_context, follow and paused use the panel's own controls. Omitted fields keep their values; clear_filter resets text and packet filters. expected_revision refuses stale changes atomically. App bundle/process/PID and route fields are not supported for Bluetooth."
        case DeviceLogToolNames.read:
            operation = "Read the Bluetooth panel's current filtered packet buffer. Returns structured rows, stable IDs, cursor, revision and loss/truncation metadata. Continue with the returned cursor and has_more, even for an empty bounded scan. Filter or source changes rebase the cursor with changed/change_reason; expected_revision refuses stale calls. pending means the shared context projection is preparing. Does not move the viewport."
        case DeviceLogToolNames.wait:
            operation = "Wait for new packets matching the Bluetooth panel's current filter, up to timeout_seconds (default 5, maximum 30). Use the last bluetooth_read cursor; omitting it starts at the current tail. Returns the same structured page as bluetooth_read, with explicit timeout, filter/source changes and capture status."
        default:
            operation = "Reveal the exact row_id from bluetooth_read or bluetooth_wait in the Bluetooth panel. Optional through_row_id selects an inclusive range of at most 200 capture rows. Missing/filtered/evicted rows and stale expected_revision are refused. This deliberately changes scroll and selection; reads do not."
        }
        return operation + " Targets this session's Bluetooth stream regardless of the selected tab; the person sees the same filter. Capture is phone-wide HCI traffic, not app stdout. Starting capture does not prove packets arrived."
    }

    static let names: Set<String> = [
        DeviceLogToolNames.state, DeviceLogToolNames.configure, DeviceLogToolNames.read,
        DeviceLogToolNames.wait, DeviceLogToolNames.reveal,
    ]

    static var tools: [PluginTool] { [
        tool(
            DeviceLogToolNames.state, symbol: "list.bullet.rectangle",
            summary: """
                Read this session's actual Regular Logs panel state: selected device and source, \
                observed processes, filter, follow/pause state, capture availability and retention. \
                Manual changes are visible here. Use configure to change the same panel, then read \
                or wait without repeating filters. Set refresh:true after connecting a device or \
                installing/restarting an app to invoke the same bounded async Rescan as the UI. \
                discovery_pending reports an unfinished scan; read state again for its catalog \
                freshness and results. This is not an independent log-file reader.
                """,
            schema: #"{"type":"object","properties":{"refresh":{"type":"boolean","description":"Rescan through the panel's existing asynchronous discovery."}},"additionalProperties":false}"#
        ),
        tool(
            DeviceLogToolNames.configure, symbol: "line.3.horizontal.decrease",
            summary: """
                Change this session's visible Regular Logs panel. Omitted fields keep their values; \
                empty optional strings clear them, pid 0 clears the PID filter, clear_filter resets \
                the filter. Use identities from state, never a guessed app display name. A bundle \
                selects that installed app's source; process selects an observed process. Filters \
                are shared with the person watching. expected_revision refuses the entire change \
                if the person or another call changed configuration. Invalid changes are atomic. \
                Device/source changes may restart capture; a console route may relaunch the app. \
                Available metadata and stdout/stderr depend on the selected capture route, as state reports. \
                Literal text folds ASCII letter case only; non-ASCII bytes compare exactly. Regex uses \
                ICU case-insensitive matching, examines only the first 4096 characters of each field, \
                and stops cooperatively after 2ms per field; later or expensive matches can be missed. \
                The panel's regex projection also has a cooperative 250ms aggregate budget; \
                state.projection_limited and read.output_truncated disclose limited results. \
                Text scans message, process, subsystem and category; other predicates combine with AND, \
                selected levels with OR. The pattern is limited to 512 UTF-8 bytes.
                """,
            schema: configurationSchema(bluetooth: false)
        ),
        tool(
            DeviceLogToolNames.read, symbol: "text.alignleft",
            summary: """
                Read structured entries from this session's current Regular Logs panel filter, \
                including visible context and expanded folds when enabled (see state.read_scope \
                and each row's is_match). \
                No device, app or text filters belong on this call: configure the shared panel first. \
                Return rows in capture order, stable row IDs, a continuation cursor, revision, count, \
                has_more, capture status and explicit history/drop/truncation information. Pass the \
                returned cursor to continue. A changed configuration or source rebases that cursor \
                and is reported with changed/change_reason; explicit expected_revision still refuses \
                stale calls. pending:true means the panel's context projection is still preparing; \
                wait or retry with the cursor. Worker scans yield after a cooperative 50ms slice \
                with has_more/output_truncated, even if no rows matched. Reads do not change the \
                filter, selected process or scroll.
                """,
            schema: """
                {"type":"object","properties":{
                  "cursor":{"type":"string"},"limit":{"type":"integer","minimum":1,"maximum":50},
                  "expected_revision":{"type":"integer","minimum":0}
                },"additionalProperties":false}
                """
        ),
        tool(
            DeviceLogToolNames.wait, symbol: "clock",
            summary: """
                Wait up to timeout_seconds (default 5, maximum 30) for new entries matching this \
                session's existing Regular Logs filter. Supply the last read cursor to wait after \
                those rows. An omitted cursor starts at the current tail. Return the same structured \
                page as read, including timeout and configuration/source changes. A filter change \
                ends the wait explicitly. Do not repeat filters or poll a separate log file.
                """,
            schema: """
                {"type":"object","properties":{
                  "cursor":{"type":"string"},"limit":{"type":"integer","minimum":1,"maximum":50},
                  "timeout_seconds":{"type":"number","minimum":0,"maximum":30},
                  "expected_revision":{"type":"integer","minimum":0}
                },"additionalProperties":false}
                """
        ),
        tool(
            DeviceLogToolNames.reveal, symbol: "scope",
            summary: """
                Reveal and highlight the exact stable row_id returned by read/wait in this session's \
                Regular Logs panel. Optional through_row_id selects the inclusive range. This is the \
                deliberate scroll/selection operation; the filter stays shared. A missing/evicted row \
                or changed revision is reported explicitly. Ranges span at most 200 capture rows. \
                Never substitute a text search for row identity.
                """,
            schema: """
                {"type":"object","properties":{
                  "row_id":{"type":"string","minLength":1},
                  "through_row_id":{"type":"string","minLength":1},
                  "expected_revision":{"type":"integer","minimum":0}
                },"required":["row_id"],"additionalProperties":false}
                """
        ),
    ] }

    private static func tool(_ name: String, symbol: String, summary: String, schema: String) -> PluginTool {
        PluginTool(
            name: name, title: "Device logs", detail: "Read and control this session's shared log panel",
            symbol: symbol, summary: summary, inputSchemaJSON: schema, paneSectionToReveal: "regular"
        )
    }
}
