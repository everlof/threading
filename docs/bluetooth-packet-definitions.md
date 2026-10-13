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
| `type` | `u8 u16 u24 u32 u64`, `s8 … s64`, `f32 f64`: little-endian; append `be` (`u16be`) for big-endian. `bool` (one byte), `bytes`, `str` (UTF-8), `msgpack` (one MessagePack value), a type name, an inline type, or a `switch-on`. |
| `enum` | Integer only. Shows the case name, or `7?` for an unknown value. On a `msgpack` field it names integer map keys. |
| `scale`, `unit` | Multiply an integer or float; append a unit (`unit: " m"`). |
| `flags` | Integer only. `{ name: bit }`; shows the set names joined by `|`, or `none`. |
| `bits` | Integer only. `{ command: 0-7, token: { bits: 8-15, enum: Token } }` splits the value into named bit ranges, shown as `{command=… token=…}`. Each part is a value of its own (`word.command`) for `switch-on`, `if` and flows. |
| `if` | The field is present only when this holds for earlier fields: a flag name (`if: wideRate`), its negation (`if: "!wideRate"`), an integer field or bit part (non-zero), or a comparison (`if: "op == START"`, `if: "result != 1"`). |
| `size` | For `bytes`, `str` and types: a number, `rest`, or an earlier integer field. Without it they take the rest of the enclosing value. |
| `repeat` | `eos` (until the end), a count, or an earlier integer field. Shows up to 16 items. |
| `hidden` | `true` keeps a field (typically a length) out of the default rendering. |
| `doc` | Free text, ignored. |

`switch-on` names an earlier single integer field of the same type (or a `bits:` part, as
`word.command`). `cases` keys are enum case names, numbers, or `_` for anything else. A value with
no matching case and no `_` shows its remaining bytes.

`switch-on` may instead name **another characteristic's field**, `Characteristic Name.field`: the
last value of that field decoded on the same connection. That is how a value whose meaning depends
on an earlier command is read — Nordic's legacy DFU packet characteristic carries image sizes, an
init packet or image bytes depending on the control point's last opcode:

```yaml
- name: DFU Packet
  message:
    switch-on: DFU Control Point.op
    cases: { START_DFU: ImageSizes, INIT_PARAMS: InitPacket, _: bytes }
```

Until that field has been seen the row says `<DFU Control Point.op not seen yet>` and shows the
bytes.

Without `summary`, a type renders as `id=value` pairs; a nested type is wrapped in `{…}`.

## Matching

Both ends of an LE link can be GATT servers with separate handle spaces: the accessory hosts your
service, the iPhone hosts ANCS, Current Time and the like, and both may have a handle 0x0028. Each
ATT packet is assigned to one database: responses, notifications and indications come from the
sender's, requests and writes go to the receiver's. Handles, discovery and pending reads are kept
per connection *and* database, and rows about the iPhone's own database say `(iPhone's database)`.

A characteristic matches by UUID. A handle's UUID comes from, in order:

1. **Discovery in this capture** — Read By Group Type (services), Read By Type for 0x2803
   (characteristic declarations, with their properties) and Find Information (descriptors).
2. **The device's remembered table.** Every discovery that passes through is kept per device, so a
   later capture decodes without one — iOS caches the tables of bonded devices and almost never
   rediscovers, so most captures need this. See *Remembered GATT tables*.
3. **A `handle:` pin** in the file, only when no table knows the handle. A pin means the
   accessory's database; add `server: phone` for a characteristic the iPhone hosts (a UUID matches
   in whichever database it was discovered in, unless `server:` restricts it). A pin that disagrees
   with a known table is the stale one: the footer names its line, and the table wins.

### Remembered GATT tables

The accessory's table is stored under its identity — the address from the LE (Enhanced) Connection
Complete, else its Device Name; the iPhone's own table (ANCS and the like) under the phone being
captured, because it is the same for every peer. They live in
`~/Library/Application Support/codes.threading/DeviceLogs/bluetooth-gatt-tables.json`, at most 64
devices and 1,024 attributes per table; a damaged file reads as empty, and nothing leaves the Mac.

A connection that began before the capture has no connection event, so its table is chosen by
fit: every handle its traffic touches must exist in the table, and each operation must be allowed
by that characteristic's properties — a write needs write or write-without-response, a
notification notify, an indication indicate, a read read; descriptors take reads and writes. One
fitting table is used; several use the most recent and the footer says `assumed`; none — or
traffic that later contradicts the choice — leaves the connection undecoded rather than mislabelled
(`GATT: no remembered table fits this connection`). A table known by identity is checked the same
way.

What changes a remembered table:

- A rediscovered service replaces that service's range only (iOS often rediscovers one service).
- A Service Changed indication (0x2A05) drops the entries in its start–end range.
- A different Database Hash (0x2B2A) drops the whole table.
- A different Firmware Revision (0x2A26) marks it `stale` in the footer but keeps it — updates
  often keep the layout — until traffic contradicts it.
- A disconnection forgets only which device the connection was, never the table.

ATT rows whose UUID came from memory end in `(remembered)`. The footer and the agent `visible`
answer carry a line such as `GATT: Kronaby (fw 20240705-…) remembered 13 Oct 15:06 · 14
characteristics`. **Forget Remembered Tables** in the **?** panel drops them all. Guessing a table
for a device never discovered in any capture is out of scope.

Values are decoded from Write Request/Command, Signed Write (signature excluded), Handle Value
Notification/Indication and Read Response. A value longer than one response (MTU − 1 bytes) is
joined from the Read Blob responses that follow and decoded once, on the last piece; until then the
row says `N bytes so far`. A long write — Prepare Write segments committed by Execute Write — is
joined by offset and decoded on the Execute Write as `long write`. Both cap at 512 bytes, the ATT
maximum. L2CAP fragments are reassembled per direction, because both ends' fragments interleave on
one connection.

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
**Fully decoded only** also leaves out rows whose bytes did not fit the definition — those carrying
`⚠` — whatever their level, since your definitions may rightly call a well-formed packet an error. Both combine with the level and text filters and hide rather than discard.
Agents pass `packets: "app"` or `"complete"` to the device-log `focus` tool; `clear_focus` returns
to all packets.

## MessagePack

`type: msgpack` decodes one MessagePack value and renders it like the rest of a row: maps as
`{key=value …}`, arrays as `[a, b]`, strings quoted, binary as hex, extensions as `ext5<…>`. String
keys that are plain words are unquoted; an `enum:` on the field names integer keys:

```yaml
- { id: body, type: msgpack, enum: AnimaCommand }   # {19=22} → {error=22}
```

Containers show up to 64 items (`…+N` for the rest); nesting, steps and rendered length share the
per-value bounds below. Several values in a row: `repeat: eos`.

### Patterns

A self-describing protocol has no fixed layout to describe, so a `msgpack` field can instead say
what its values look like and how to print them. The first rule whose pattern fits renders the value;
with none fitting, the value renders plainly.

```yaml
- id: value
  type: msgpack
  match:
    - { pattern: "{ $cmd: $value }", summary: "{cmd} {value}" }      # write, response, notification
    - { pattern: "[ $cmd:int, ...$args ]", summary: "read {cmd} {args}" }
    - { pattern: "$cmd:int", summary: "read {cmd}" }
  enum: { cmd: AnimaCommand }        # name a capture with an enum
  values: AnimaValues                # shape the other captures by that name (see Shapes)
```

| Pattern | Matches |
|---|---|
| `{ K: V }` | a non-empty map whose every entry matches; each entry is one binding, rendered and joined with `, ` |
| `[a, b]`, `[a, ...$rest]`, `[a, ...]` | an array of exactly / at least that many items; `$rest` binds the remainder |
| `$name`, `$name:int` | anything, or one kind: `int str float bool nil bin map array` |
| `_`, `_:str` | anything (or one kind), unbound |
| `0x14`, `"text"` | that number, that string |
| `word`, `map_*` | a string, or an integer whose enum name is that word; `*` matches any run |

Without a `summary:`, a rule prints `capture=value` pairs. Patterns are at most 256 characters, 64
nodes and 8 levels deep; one match yields at most 4,096 bindings.

### Learned enums

Some devices assign numbers at runtime and publish the table themselves — Anima watches answer a
read of `map_cmd` with pages of `{number: name}`. An enum can learn from that traffic:

```yaml
enums:
  AnimaCommand:
    0x00: map_cmd                       # entries the firmware fixes, if any
    learn:
      from: Anima Command               # a characteristic; values the device sends
      pattern: "{ map_cmd: { $number:int: $name:str } }"
  AnimaSetting:
    learn:
      from: Anima Command
      pattern: "{ map_settings: { $number:int: $name:str } }"
      names: AnimaCommand               # map_settings is a command name, not a setting
```

The pattern must bind `$number` and `$name`. Each received value of the `from:` characteristic is
parsed as one MessagePack value and matched; every binding adds an entry. Learn blocks run in file
order over one view, so a page that teaches `map_settings` already names the next block's words. A
device may teach several enums (16 `learn:` blocks per file).

Learned entries win over the file's, apply to integer `enum:` fields as well as msgpack captures,
and are **remembered per device across captures** in
`~/Library/Application Support/codes.threading/DeviceLogs/bluetooth-learned-enums.json` — the
app caches the table after pairing, so it may cross the air only once. A device is keyed by its
address from the connection, else its name; a capture that started mid-connection uses the device
that taught the enum most recently. The store keeps the device's name and Firmware Revision
(0x2A26) when the capture read them, holds at most 64 devices and 4,096 entries per enum, and a
damaged file reads as empty. The footer adds `AnimaCommand: 149 learned (Kronaby, fw …)`. Learning
from a binary table (structs rather than MessagePack) is not supported yet.

Tables are kept **per firmware build**, at most four per device: a build may renumber every name
(a firmware that numbers names from one counter does whenever a build compiles in other features).
The build is the Firmware Revision String (0x2A26), or the characteristic a root `firmware:`
names. A device on a build it has not taught yet decodes raw, and the footer says
`AnimaCommand: nothing learned from fw … yet`; a table learned before the capture read the revision
is filed under it once it does.

`learn:` may also be a list, for a device whose tables share one number space — several pages
teaching one enum.

### Shapes

Numbers can change per firmware; names do not. So a value is described by its command's *name*:

```yaml
shapes:
  AnimaValues:
    datetime: [year, month, date, hourOfDay, minute, second, dayOfWeek, utcOffset]
```

With `values: AnimaValues` on the field, a binding whose enum capture names `datetime` prints its
other captures as `{year=2026 month=10 …}`. Extra array items follow as `+[…]`; a non-array value
prints plainly. At most 1,024 shapes per file.

## Levels

An enum entry may say how loud a row naming it is, and a match rule may set a level for what it
renders. The entry wins:

```yaml
enums:
  DeviceError:
    4: OUT_OF_MEMORY
    6: { name: BATTERY_WARNING, level: warning }
    22: { name: BATTERY_OK, level: info }        # sent as an "error" on every subscribe
    BATTERY_CRITICAL: { level: error }            # a learned name: no number needed
types:
  Message:
    seq:
      - id: value
        type: msgpack
        match:
          - { pattern: "{ error: $code:int }", summary: "error {code}", level: error }
```

Levels are `debug`, `info`, `warning` and `error`, and they set the row's level, so the level filter
and the agent's `minimum_level` see them.

## Built-in profiles

`include:` adds definitions Threading ships, compiled before your file, so yours win wherever both
describe the same UUID, type or enum, and your types may use theirs:

| Profile | Covers |
|---|---|
| `gatt` | Generic Access, Generic Attribute (Service Changed, Database Hash, CCCD), Device Information, Battery, Current Time, Heart Rate (with its flag-dependent fields) |
| `ancs` | Apple Notification Center Service: Notification Source, Control Point, Data Source |
| `nordic-dfu` | Nordic Secure DFU (FE59, SDK 12+): control point requests and responses paired, buttonless DFU, image bytes counted |
| `nordic-legacy-dfu` | Nordic legacy DFU (0x1530, SDK ≤ 11): the packet characteristic read by the control point's last opcode, and the image's CRC-16 checked |

```yaml
include: [gatt, ancs]
```

## Across packets

### Transactions

A transaction says which packet answers which:

```yaml
transactions:
  - name: read
    request:  { characteristic: Command, op: write, match: ["$cmd:int", "[$cmd:int, ...]"] }
    response: { characteristic: Command, op: read, match: ["{ $cmd: _ }", "[]"] }
    key: cmd               # a value both sides carry
    pending: "[]"          # "not ready yet": shown, does not close the request
    timeout: 30s
  - name: error
    request:  { characteristic: Command, op: write }
    response: { characteristic: Events, match: "{ error: $code }", where: { code: "!BATTERY_OK" } }
    within: 2s             # the latest write inside the window
  - name: FOTA             # a binary protocol that echoes the opcode it answers
    request:  { characteristic: FOTA RX, where: { packetType: [INIT, PAGE_START, PAGE_END] } }
    response: { characteristic: FOTA TX, where: { packetType: RESPONSE } }
    key: packetType = responseTo
    timeout: 10s
```

An **endpoint** is a `characteristic:`, optionally an `op:` (`write`, `read`, `notify`, `indicate`,
`any`), `where:` conditions on the values its definition decoded (a name or number, a list of them,
or `"!VALUE"` for anything else), and `match:` patterns (one or a list) tried against its MessagePack
value, whose captures join those values. A packet without a value the endpoint names is not that
endpoint.

The response row ends in `↩ read: read battery · 42 ms`, or `↩ read pending: …`. `key:` is one value
name or `request = response`; a response must carry the key to pair — a characteristic re-read after
a write is not an answer — so bind it in the response's `match:` when the row's own rule does not.
Without `within:` the oldest open request is answered first. An ATT Error Response to the read or
write a transaction waits on fails it (`↩ read failed: …`). A request still open after `timeout:`
becomes a warning row, `read: no response within 30 s to read map_buildinfo (sent 3 min ago)`,
reported by the first packet after the deadline. Requests that answer with silence on success (a
data chunk acknowledged only on error) should simply not be requests: leave them out with `where:`.

### Streams and transfers

A stream joins values across packets:

```yaml
streams:
  - name: firmware log                      # a log channel split at arbitrary bytes
    data: { characteristic: Events, where: { cmd: live_logs }, data: value }
    lines: true
    levels: { E: Error, W: Warning, D: Debug }
  - name: FOTA image                        # a transfer with a declared size and checksum
    start: { characteristic: FOTA RX, where: { packetType: INIT }, total: appSize, crc32: appHash }
    data:  { characteristic: FOTA RX, where: { packetType: PAGE_DATA }, data: bytes }
  - name: file                              # explicit offsets, kept apart by path
    data: { characteristic: Command, match: "{ file: [$key:str, $total:int, $offset:int, $data:bin, ...] }" }
```

Endpoints read their values through named roles: `data` (bytes or text), `offset`, `total`, `key`,
`crc32`, `crc16`; each defaults to a value of the same name. `start:` begins a transfer, `info:`
supplies a total or checksum later without restarting, `end:` finishes one that has no total.

With `lines: true`, the bytes are text: each complete line becomes a row `Device · firmware log · …`
at the level of the first matching token among its first four (`levels:`), else Info. Otherwise the
stream is a transfer: rows report progress every 10 % of the total (or every 64 KiB without one) and
finish with `FOTA image complete · 151 KiB in 3 min 12 s · 805 B/s · crc32 ok`. A mismatch is an
error row; a transfer whose pieces arrived out of order or with gaps says the CRC was not checked
rather than claiming a mismatch; a restart says how far the last attempt got. CRCs are computed
incrementally (CRC-32 as zlib, CRC-16/CCITT-FALSE as Nordic's legacy DFU), so nothing is buffered.
`key` keeps up to 8 transfers per stream apart.

Flow rows have subsystem `App`, so **App packets only** keeps them.

## Linking app log lines

An app usually logs what it sends and receives without the bytes. `logs:` rules say which log lines
describe which packets:

```yaml
logs:
  - match: 'Write -> cmd: "(?<key>[^"]+)"'
    packet: { characteristic: Command, op: write, key: cmd }
  - match: 'Notification -> cmd: "(?<key>[^"]+)"'
    packet: { characteristic: Events, key: cmd }
    within: 2s
```

`match:` is a regular expression over the Regular Logs message; its `key` group must equal the
packet's decoded value named by `key:`. With both tabs shown, selecting such a log line selects its
packet in the Bluetooth tab and the reverse. Rows link only when the characteristic, direction and
key agree, and among those the nearest in time within `within:` (default 5 s, at most 60 s) wins —
both streams are timed by the phone. The agent's `linked` tool returns both rows. Linking reads the
rows each tab holds (its 50,000-row ring), not the searchable history. At most 64 rules, 512
characters each.

## Advertising

```yaml
advertising:
  - name: Example watch
    company: 0x0D30                 # Bluetooth SIG company identifier
    message: { summary: "model {model}", seq: [{ id: model, type: u8, enum: Model }] }
```

Manufacturer-specific data (AD type 0xFF) from that company is decoded on the advertising row:
`Advertising C4:7C:8D:6A:4F:2A "Kronaby" -60 dBm · Example watch model pronto`.

## Link health

Without any definitions, the link's own HCI events read as words under subsystem `Link`, naming the
device where the capture knows it:

- `Connected Kronaby · iPhone is central · interval 30 ms latency 0 timeout 6000 ms`
- `Connection parameters Kronaby · interval 15 ms latency 4 timeout 1000 ms`, and a device's
  request for new ones
- `Data length …`, `PHY … tx 2M · rx 2M`, `Encryption on …`, `Long-term key requested …`
- `Disconnected Kronaby: Connection Timeout` — at Warning unless someone chose to end the link;
  `Encryption failed Kronaby: PIN or Key Missing` is the classic lost bond.

CCCD writes are tracked per characteristic, and a notification or indication on a characteristic
whose CCCD this capture saw switched off ends in `· notified while its CCCD is off`, at Warning.

## Colours

Every message in Device Logs is drawn with its structure coloured, in the app theme's syntax
colours: `RX`/`TX`, `key=` names, numbers and hex, quoted strings, UUIDs, brackets and separators.
Bluetooth rows also dim the byte count and hex preview. Decoded rows also show the device and
direction and the characteristic name in bold. Every enum case name — declared or learned — is
drawn in a colour of its own: the hue is a stable hash of the name, so `datetime` is the same colour
in every row and capture, and lightness and chroma are the theme's syntax keyword colour measured in
OKLCH, lifted to legible contrast on the theme's ground, so names follow a theme change. Hues skip
the reds, which read as errors. Error rows keep one warning colour.

Your file can colour its own words:

```yaml
highlight:
  LOCATION: green      # an enum or flag name, wherever it appears in a decoded row
  accuracy: orange     # a field id: the id and its value in `accuracy=4.5`
```

Colours: `red orange yellow green teal blue purple pink gray`. A word must be letters, digits,
`_` or `-`; at most 256. Summary templates print values without their ids, so colour those by the
enum or flag word instead. Colouring is per visible row, and only the first 2,048 characters of a
message are examined.

## When bytes do not fit

The row is logged at `Warning`, keeps the fields that decoded and adds `⚠ body.lat: needs 4 bytes, 2 left` or
`⚠ 3 trailing bytes not described`. The packet's own row is never lost.

## Bounds

Per value: 16 levels of nested types, 20,000 field reads, 4,096 repeat items, 1,024 rendered
characters, 32 bytes shown per `bytes` field, 128 named values kept for flows. Per file: 512 types,
256 fields per type, 512 characteristics, 4,096 enum cases, 32 bit fields per field, 64
transactions, 64 streams, 64 `logs:` rules. Per connection: 16 open requests per transaction, 8
transfers per stream, one 4 KiB partial line per stream, 256 remembered context values. Decoding
runs on the capture worker.
