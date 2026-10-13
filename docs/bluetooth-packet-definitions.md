# Bluetooth packet definitions

Device Logs' Bluetooth tab decodes the radio's own grammar (HCI, L2CAP, ATT) by itself. The bytes
*inside* an ATT value belong to your app's protocol, so your project describes them in
`.threading/bluetooth.yaml` at the root of the session's checkout. Rows whose characteristic
matches are shown decoded:

```
RX Pulse 4F2A → iPhone · Messages notify · LOCATION #412 {lat=59.3293° lon=18.0686° accuracy=4.5 m flags=precise} · 14 bytes | 01 9c 01 …
```

The in-app **?** panel (Bluetooth tab, beside **Set Up…**) carries the same reference, a working
example, **Create File**, and a **Copy Agent Prompt** that asks an agent to write the file from your
app's BLE code. The example is `BluetoothDefinitionsGuide.example`; a test compiles and decodes it,
so it is always valid.

## File

- Location: `<checkout>/.threading/bluetooth.yaml` (or `.yml`). The checkout is the session's
  working directory, so a managed worktree reads its own copy.
- Saved changes are picked up within a second while capture runs; no Rescan.
- The Bluetooth footer shows `Packet definitions: … · N characteristics, M types` or the first
  error with its line number. Agents see the same line in the `visible` tool's `Reader:` answer.
- YAML subset: block and flow mappings and lists, comments, quoted strings. Anchors, aliases,
  tags, multi-document files and `|`/`>` blocks are rejected. At most 256 KiB.

## Shape

```yaml
version: 1                    # optional; only 1 exists
services:
  - name: Example Watch       # names the device when the capture doesn't; uuid is documentation
    uuid: 6E400001-B5A3-F393-E0A9-E50E24DCCA9E
    characteristics:
      - name: Messages        # shown in decoded rows, after the device
        uuid: 6E400003-B5A3-F393-E0A9-E50E24DCCA9E
        handle: 0x0025        # optional, see Matching
        message: Frame        # both directions; or rx: (notify/indicate/read) and tx: (write)
types:
  Frame:
    summary: "{kind} #{seq} {body}"   # optional one-line rendering
    seq:                              # fields, in wire order
      - { id: kind, type: u8, enum: MessageKind }
      - { id: seq, type: u16 }
      - id: body
        type:
          switch-on: kind
          cases: { LOCATION: Location, 0x05: Status, _: bytes }
enums:
  MessageKind: { 0x01: LOCATION, 0x02: STATUS }
```

A `message`, `rx`, `tx`, field `type` or `cases` value may be a built-in type, a name under
`types:`, or an inline `{ seq: [...] }`.

## Fields

| Key | Meaning |
|---|---|
| `id` | Required. Letters, digits, `_`, `-`. Later fields and `summary` refer to it. |
| `type` | `u8 u16 u24 u32 u64`, `s8 … s64`, `f32 f64`: little-endian; append `be` (`u16be`) for big-endian. `bool` (one byte), `bytes`, `str` (UTF-8), a type name, an inline type, or a `switch-on`. |
| `enum` | Integer only. Shows the case name, or `7?` for an unknown value. |
| `scale`, `unit` | Multiply an integer or float; append a unit (`unit: " m"`). |
| `flags` | Integer only. `{ name: bit }`; shows the set names joined by `|`, or `none`. |
| `size` | For `bytes`, `str` and types: a number, `rest`, or an earlier integer field. Without it they take the rest of the enclosing value. |
| `repeat` | `eos` (until the end), a count, or an earlier integer field. Shows up to 16 items. |
| `hidden` | `true` keeps a field (typically a length) out of the default rendering. |
| `doc` | Free text, ignored. |

`switch-on` names an earlier single integer field of the same type. `cases` keys are enum case
names, numbers, or `_` for anything else. A value with no matching case and no `_` shows its
remaining bytes.

Without `summary`, a type renders as `id=value` pairs; a nested type is wrapped in `{…}`.

## Matching

A characteristic matches by its `handle:` first, then by `uuid:`. UUIDs are learned per connection
from the GATT discovery responses (Read By Type for characteristic declarations) present in the
capture. iOS caches the GATT database of known accessories, so a capture started later may contain
no discovery: then the ATT row shows `attribute=0x00NN` and no `uuid=`, and you add that
`handle:`. A Read Response is matched to the outstanding Read Request's handle.

Values are decoded from Write Request/Command, Signed Write (signature excluded), Handle Value
Notification/Indication and Read Response. Prepare/Execute Write and Read Blob are not reassembled.

## Naming the device

A decoded row starts with who sent it: `Pulse 4F2A → iPhone` for a notification, indication or read,
`iPhone → Pulse 4F2A` for a write. The device is named from the most specific thing the capture
says about that connection:

1. its GATT Device Name (0x2A00), when the phone reads it;
2. the local name it advertised (AD type 0x09, or the shortened 0x08), tied to the connection by
   the LE Connection Complete's peer address;
3. the `name:` of the service the matched characteristic is listed under;
4. its address, or `peripheral` when even that was not captured.

A Disconnection Complete forgets what was learned, so a reused connection handle does not inherit
another device's name. The advertised name only appears when the advertisement and the connection
are both in the capture; the service name is the stable fallback.

## Showing only decoded packets

The Bluetooth filter bar's first menu has three choices. **App packets only** keeps the rows with
subsystem `App`, matched exactly (a filter-field search for "app" would also hit other rows).
**Fully decoded only** also leaves out rows whose bytes did not fit the definition: those are
logged at `Warning`. Both combine with the level and text filters and hide rather than discard.
Agents pass `packets: "app"` or `"complete"` to the device-log `focus` tool; `clear_focus` returns
to all packets.

## When bytes do not fit

The row is logged at `Warning`, keeps the fields that decoded and adds `⚠ body.lat: needs 4 bytes, 2 left` or
`⚠ 3 trailing bytes not described`. The packet's own row is never lost.

## Bounds

Per value: 16 levels of nested types, 20,000 field reads, 4,096 repeat items, 1,024 rendered
characters, 32 bytes shown per `bytes` field. Per file: 512 types, 256 fields per type, 512
characteristics, 4,096 enum cases. Decoding runs on the capture worker.
