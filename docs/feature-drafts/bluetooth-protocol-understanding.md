# Bluetooth protocol understanding

> **Status: all nine slices implemented 2026-10-13 (uncommitted at the time of writing).** The
> author reference is [`docs/bluetooth-packet-definitions.md`](../bluetooth-packet-definitions.md)
> and the durable decisions are under "Across packets" in [`plugins.md`](../architecture/plugins.md).
> Still open: linking reads only the rows each tab holds (not the SQLite history), learning from a
> binary (non-MessagePack) table, and importers for vendor schemas (left to agent-written scripts).
> When those are settled, reduce this file to a pointer.
>
> **Originally:** in implementation, started 2026-10-13. Extends the Bluetooth tab of the Device Logs
> plugin (`Plugins/DeviceLogsPlugin`) and its `.threading/bluetooth.yaml` definitions, documented
> for authors in [`docs/bluetooth-packet-definitions.md`](../bluetooth-packet-definitions.md).
> When a slice ships, its durable rules move to that file and to
> [`plugins.md`](../architecture/plugins.md); this draft keeps the research and the order.

## The problem

The Bluetooth tab already decodes an app's own ATT values from a YAML file. It handles fixed
binary layouts, MessagePack with patterns, enums a device teaches over the air, and GATT tables
remembered across captures. Each packet, though, is still read **alone**. The questions people
actually ask about Bluetooth traffic involve several packets at once:

- *Which command failed?* An error arrives as a separate notification that names no command.
- *Did the transfer finish, and was it intact?* A file or firmware image is hundreds of packets,
  and only their total has a CRC.
- *What did the device log while that happened?* The firmware's own log travels inside packets,
  split at arbitrary byte boundaries.
- *Which app log line is this packet?* The app logs `Write -> cmd: "dnd"`; the capture holds
  `{12: [1, 22, 0, 7, 0]}`.

Nothing here is specific to one product. Every request/response protocol needs pairing. Every
device with DFU or file transfer needs reassembly and integrity checks. Every vendor service sits
next to the same SIG and Nordic services.

## Research (2026-10-13)

Four code bases were read: three firmware families (fw-pascal, fw-pronto and fw-primo, all
Nordic nRF52) and the companion app (app-mono, iOS + Kotlin Multiplatform). They were used to
find what a **general** tool lacks, not as a target.

| Finding | Where | What it generalises to |
|---|---|---|
| Replies carry no request id. Each command is a write followed by a read of the same characteristic, serialised by a lock in the app. The value reads as `[]` until it is ready. | `bt_svc_anima.c`, `AnankeWatchBackend.__read` | Pairing by "next operation on the same handle", plus a *pending* value |
| Errors arrive as `{error: n}` on another characteristic, naming no command. The app links them by a 2 s window. | `DIAGNOSTICS.md`, `bt_notify.c` | Pairing by time window |
| A legacy family packs a correlation token into bits 15:8 of the command number and echoes it in errors. | fw-primo `msgpack_anima.c` | Bit fields inside integers |
| Error 22 is `BATTERY_OK`, sent whenever notifications are enabled. | `bt_svc_anima.c:281` | Enum entries carry a severity |
| A custom FOTA uses a packed LE binary format: an opcode byte, a different layout per direction, `RESPONSE = [0xAA, opcode, code]`, and silence on success. Pages carry a CRC32 and so does the image. | fw-pronto `docs/fota.md` | Transfers with progress and CRC checks |
| Nordic Secure DFU (FE59) and legacy DFU (0x1530) are used unchanged. The meaning of the legacy packet characteristic depends on the last control-point opcode. | `bt_svc_dfu.c`, `AndroidDfu8Transport.kt` | Built-in profiles; decoding that depends on another characteristic |
| `live_logs` streams the firmware log as text split at arbitrary bytes. `dump_uart` and `postmortem` page out 500-byte chunks. | `log.c`, `FirmwareLogLineAssembler.kt` | Byte streams joined into lines |
| Name tables (`map_cmd`, `map_diag`, `map_error`, …) share one id counter, depend on build features, and are cached per Firmware Revision. | `generate_lookup_map.py`, `connecting.md` | Learned enums keyed by firmware; several tables per enum |
| Heart Rate Measurement's fields exist only when flag bits say so. | `HeartRateDevice.kt` | Fields that depend on a flag |
| The app logs `[DeviceWriter] Write -> cmd: "dnd"`, with no op id and no bytes. | `DeviceWriter.kt` | App log lines linked to packets by name, direction and order |
| Manufacturer data identifies the family (`vendor, model, brand, variant`). | `BluetoothAdvertiseDataParser.swift` | Decoded advertising |
| Connection interval, latency and timeout are renegotiated constantly. MTU 247, DLE 251 in the app; DLE 27 in the bootloader. | `bt_connint.c` | Connection-parameter rows |

## The contract

Each capability is a YAML construct with no product-specific behaviour, plus row text the pane,
the colouring and the agent tools already understand. All of them stay bounded in the way the
existing interpreter is: per-connection state is capped, and nothing grows with the length of
the capture.

### 1. Transactions — which response answers which request

```yaml
transactions:
  - name: command
    request:  { characteristic: Anima Command, op: write }
    response: { characteristic: Anima Command, op: read }
    key: cmd                 # a value both sides decode to; optional
    pending: "[]"            # a response matching this is "not ready yet"
    timeout: 30s
  - name: error
    request:  { characteristic: Anima Command, op: write }
    response: { characteristic: Anima Notification, match: "{ error: $code }" }
    within: 2s               # pair only inside the window; silence is not reported
  - name: FOTA
    request:  { characteristic: FOTA RX }
    response: { characteristic: FOTA TX, where: { packetType: RESPONSE } }
    key: packetType = responseTo     # request field = response field
```

- **What the row shows.** A response row ends in `↩ <request summary> · 42 ms`. An ATT Error
  Response to the request's read or write closes the transaction as failed. A request that times
  out produces a row of its own, emitted by the first packet seen after the deadline.
- **Fields.**
  - `op:` is `write`, `read`, `notify`, `indicate` or `any`.
  - `match:` is a MessagePack pattern; `where:` compares decoded field values.
  - `key:` is either one name or `request = response`.

### 2. Streams and transfers — values that span packets

```yaml
streams:
  - name: firmware log
    data: { characteristic: Anima Notification, match: "{ live_logs: $data:bin }" }
    lines: true
    levels: { E: Error, W: Warning, D: Debug }
  - name: FOTA image
    start: { characteristic: FOTA RX, where: { packetType: FOTA_INIT }, total: appSizeBytes, crc32: appHash }
    data:  { characteristic: FOTA RX, where: { packetType: PAGE_DATA }, data: bytes }
  - name: file
    data: { characteristic: Anima Command, match: "{ file: [$key:str, $total:int, $offset:int, $data:bin, ...] }" }
```

- **`lines: true`** joins the bytes and emits one row per complete line, under the stream's name
  as subsystem. The level is taken from a token in the line.
- **Otherwise the stream is a transfer.**
  - **Progress.** Throttled progress rows (`FOTA image 120/340 KiB · 35% · 41 KiB/s`) are followed
    by a final row.
  - **Integrity.** The final row reports whether the CRC (`crc32`, `crc16`) matched, when one was
    declared.
  - **Offsets.** They are explicit (`$offset`) or implicit (in order). A gap or reordering makes
    the CRC unverifiable, and the row says so rather than claiming a mismatch.
  - **Keys.** `$key` keeps several transfers apart, for example per file path.
  - **Bounds.** Line buffers and transfer state are capped per stream, and CRCs are computed
    incrementally, so no image is ever held in memory.

### 3. A richer value model

- **Bits inside an integer:**
  `bits: { command: { bits: 0-7, enum: AnimaCommand }, token: 8-15 }`
- **Conditional fields:** `if: heartRateValueFormat` (a flag of an earlier field), `if: "!flag"`,
  `if: "op == START_DFU"`.
- **Repeating shapes:** `alarm: [hours, minutes, configurationBits, ...]` repeats the group.
- **Nested maps.** A capture's enum also names the integer keys inside a map it captured, so
  `{ status_diag: $fields }` with `fields: AnimaName` shows named diag keys.

### 4. Decoding that depends on another characteristic

A `switch-on:` may name `Characteristic.field`: the last value of that field seen on the same
connection.

```yaml
- name: DFU Packet
  message:
    switch-on: DFU Control Point.op
    cases: { START_DFU: ImageSizes, INIT_PARAMS: InitPacket, _: bytes }
```

### 5. Built-in profiles

```yaml
include: [gatt, ancs, nordic-dfu, nordic-legacy-dfu]
```

Each profile is shipped YAML that is compiled first, so the project file wins whenever both
describe the same UUID, type or enum.
- **`gatt`:** Device Information strings and PnP ID, Battery Level, Device Name, Appearance,
  Service Changed, CCCD, Heart Rate Measurement and Current Time.
- **`ancs`:** Apple Notification Center Service.
- **`nordic-dfu`:** Secure DFU (FE59), with its transfer.
- **`nordic-legacy-dfu`:** SDK ≤ 11 DFU (0x1530).

### 6. Learned enums, per firmware and with severity

- **Per firmware.** Learned tables are kept per device *and* firmware revision. A device on a new
  firmware does not reuse the old numbering; it decodes raw until it teaches again, and the footer
  says so.
- **Revision source.** `firmware: <characteristic>` names where the revision is read from. The
  default is 0x2A26.
- **Several tables.** `learn:` may be a list, so several tables can teach one enum (a shared id
  space).
- **Severity.** An enum entry may carry a level, which sets the row's level:
  `22: { name: BATTERY_OK, level: info }`, `6: { name: BATTERY_WARNING, level: warning }`. A
  match rule may set one too (`level: error`); an entry's level wins over its rule's.

### 7. Linking app log lines to packets

```yaml
logs:
  - match: 'Write -> cmd: "(?<key>[^"]+)"'
    packet: { characteristic: Anima Command, op: write, key: cmd }
  - match: 'Notification -> cmd: "(?<key>[^"]+)"'
    packet: { characteristic: Anima Notification, key: cmd }
```

- **What happens.** Selecting a matching row in the device's System log selects the packet in the
  Bluetooth tab, and the reverse. Pairs are chosen by key, direction and order within a few
  seconds, never by time alone.
- **Agent tool.** The agent's `search` tool gains the same link.
- **Bounds.** Patterns are compiled once, with a bounded count and length.

### 8. Advertising

```yaml
advertising:
  - { company: 0x0D30, name: Festina watch, message: FestinaAdvertisement }
```

Manufacturer-specific data (AD type 0xFF) for a declared company is decoded and shown on the
advertising row. The decoded summary can also name the peer before it connects.

### 9. Link health

These protocol rows need no definitions:
- **HCI events** are decoded into readable rows: LE Connection Update Complete (interval, latency,
  timeout), Data Length Change, PHY Update, Encryption Change, and named Disconnection reasons.
- **CCCD writes** are tracked per handle. A notification or indication on a characteristic whose
  CCCD this capture saw disabled is flagged.

## Order of work

1. Pipe structured values out of the decoder (`Decoded.values`) and add severity, which everything
   else needs.
2. The value model (3), then cross-characteristic switches (4).
3. Transactions (1), which need packet timestamps inside the session.
4. Streams and transfers (2).
5. Built-in profiles (5).
6. Per-firmware learned enums (6).
7. Link health (9) and advertising (8).
8. Log linking (7). This is the only part that touches two panes.
9. The guide, the agent prompt, the user guide and the author documentation, kept in step.

## Out of scope

- Inferring a protocol from traffic without a definition.
- Decoding encrypted application payloads.
- Importers for one vendor's schema format. The agent prompt instead tells an agent to *generate*
  YAML from whatever schema a firmware has, which works for any vendor.
- Classic Bluetooth (RFCOMM, A2DP); LE ATT only, as today.
