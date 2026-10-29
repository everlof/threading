# Shared Device Logs tools

`device_log_prepare` opens this session's Device Logs pane and explains capture setup. The native
plugin then contributes the tools below. Their full names have the `plugin__devicelogs__` prefix;
they act on the session-owned **Regular Logs** pane, including a pane moved into the drawer or
dock. They use the pane's live buffer and its actual filter. The separate legacy `search` and
`time_range` tools still query recorded history.

Bluetooth has explicit counterparts: `bluetooth_state`, `bluetooth_configure`, `bluetooth_read`,
`bluetooth_wait` and `bluetooth_reveal`, with the same `plugin__devicelogs__` prefix. Each targets
and reveals the session's **Bluetooth** section, independently of which tab was selected. They
reuse the same shared-panel implementation and bounds. Regular tool names always target Regular
Logs; a tab switch never redirects either set to the other capture.

`bluetooth_configure` accepts the shared text/level/context/follow/pause controls and exact
`device_id`/`source`, plus `packets: "all" | "app" | "complete"`. It refuses app bundle/process/PID
and capture-route fields because this is phone-wide HCI traffic. `clear_filter` also resets the
packet chooser. State includes `bluetooth.packets` and `bluetooth.definitions` (status, path and
message); missing or invalid definitions are different from an empty or stopped capture.
Every response identifies its `stream`. For example, configure with
`{"device_id":"<id from bluetooth_state>","text":"ANCS","packets":"all"}`, then use
`bluetooth_read` and reveal its exact row IDs with `bluetooth_reveal`.

Opening the plugin publishes its tools to connected clients through `notifications/tools/list_changed`.
Normal Codex launches leave discovery to the server's live catalog rather than freezing a startup
allowlist. Processes already launched by an older build need one resume after updating to remove
that old process-level restriction. A restricted settings-research endpoint retains its exact scope.

| Tool | Arguments | Result |
| --- | --- | --- |
| `state` | Optional `refresh` (boolean). | Actual device/source choices, observed processes, filter, revision, follow/pause, capture and retention state. `refresh: true` runs the pane's existing asynchronous Rescan. |
| `configure` | Any patch fields below; optional `expected_revision`. | Updated visible configuration, or an atomic refusal with current state. |
| `read` | Optional `cursor`, `limit` (1–50, default 50), `expected_revision`. | Structured matching rows in capture order and a continuation cursor. |
| `wait` | Read arguments plus `timeout_seconds` (0–30, default 5). | New matching rows, timeout, or an explicit filter/source-change result. Without a cursor, starts at the current tail. |
| `reveal` | `row_id`, optional `through_row_id`, `expected_revision`. | Highlights and scrolls to that exact retained row or inclusive range spanning at most 200 capture rows. |

Configure accepts `device_id`, `source`, `route` (`system`, `app_log`, `console`), `bundle_id`,
`process`, `pid`, `text`, `text_mode` (`literal`, `regex`), `levels` (an array of `debug`, `info`,
`notice`, `warning`, `error`, `fault`), `subsystem`, `category`, `follow`, `paused`, `show_context`
and `clear_filter`. Omitted fields keep their values; empty optional strings clear them, and
`pid: 0` clears the PID filter. Use exact device, source and bundle identities from state.
Unknown keys, invalid regular expressions and invalid identities are refused before mutation.
`expected_revision` protects manual changes; traffic arrival uses a separate data revision.

After connecting a device or installing/restarting an app, call `state` with `{"refresh":true}`.
It uses the same discovery as the pane's **Rescan**, without a second catalog or capture path.
`status: "discovery_pending"` and `state.source_catalog_pending` mean discovery is still running;
call state again to inspect `state.source_catalog_updated_at` and results before configuring an
identity that was absent earlier.

Text tests message, process, subsystem and category. Literal mode ignores ASCII letter case and
compares non-ASCII bytes exactly. Regex uses ICU case-insensitive matching, examines only each
field's first 4,096 characters, and has a cooperative 2 ms budget per field. It can miss matches
beyond that prefix or after its budget. Patterns are capped at 512 UTF-8 bytes. Other filter
predicates combine with AND; selected levels combine with OR. State's `read_scope` distinguishes
matching rows from matches plus currently visible context/expanded folds; `filter_evaluation_limits`
records the regex bounds. The panel's regex projection has a cooperative 250 ms aggregate budget;
`state.projection_limited` reports an incomplete projection, and contextual reads also set
`output_truncated`. Each row's `is_match` distinguishes actual matches from context.

For example, after reading state, configure once:

```json
{"device_id":"<device from state>","bundle_id":"com.example.chameleon","text":"AirLab","text_mode":"literal","follow":false,"expected_revision":12}
```

Then call `plugin__devicelogs__read` with `{"limit":50}`. Continue with its returned `cursor`.
Use the same cursor with `wait` to observe the next events, and send returned row identities to
`reveal`. Read and wait accept no repeated device/app/text filters and do not move the scroll
position. A changed filter or replaced source rebases the cursor to the current retained buffer
and returns `changed: true` with `change_reason` and current state. An explicit stale
`expected_revision` refuses the call. A retained-history gap is reported explicitly.

Every plugin response has `status`, `revision`, `cursor`, `count`, `has_more`, `history`, `state`
and `rows`. A read with `status: "pending"`/`pending: true` waits for the panel's own context
projection instead of recomputing its entire history. Retry its cursor or call wait. Query workers
use a cooperative 50 ms aggregate slice; `has_more` and `output_truncated` disclose a partial scan.
`changed`/`change_reason` describe configuration/source changes; `data_changed`
describes traffic arrival separately. Refusals include `error.code` and `error.message`. The state records `capture_state`,
`reader_status`, `history_scope`, ring and handoff drops, and source availability. `history.missing`
reports a known retained-history gap; `history.scope` states that reads cover the retained buffer,
not every prior capture or all disk history. `cursor_truncated` reports an evicted cursor;
`output_truncated` and individual rows' `truncated` report bounded text. Follow `has_more` even
when a bounded scan returns no rows. Each response returns at most 50 rows; message and raw text
are capped, with an aggregate page budget. Tool arguments are capped at 32 KiB.

Rows preserve stable `id`, `time`, optional timestamp, device/bundle/PID, process, `level`,
subsystem, category, source channel, message and raw line when the source supplies them. `stdout`
and `stderr` are distinct only when the capture proves that distinction. A merged console stays
`console`; unavailable metadata is not inferred from the message.

System unified logs, saved app logs and app console are different capture routes. System capture
does not automatically include `print()` output and can redact private values. Console capture
may relaunch the app and merge its output streams. Preparing the optional tap alone does not
instrument an existing app: apply the returned setting, rebuild/reinstall or inject at launch,
then verify received entries. Older linked taps are not upgraded by preparing a new library.
