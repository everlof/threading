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
| `size` | For `bytes`, `str` and types: a number, `rest`, or an earlier integer field. Without it they take the rest of the enclosing value. |
| `repeat` | `eos` (until the end), a count, or an earlier integer field. Shows up to 16 items. |
| `hidden` | `true` keeps a field (typically a length) out of the default rendering. |
| `doc` | Free text, ignored. |

`switch-on` names an earlier single integer field of the same type. `cases` keys are enum case
names, numbers, or `_` for anything else. A value with no matching case and no `_` shows its
remaining bytes.

Without `summary`, a type renders as `id=value` pairs; a nested type is wrapped in `{…}`.

## Matching

Both ends of an LE link can be GATT servers with separate handle spaces: the accessory hosts your
service, the iPhone hosts ANCS, Current Time and the like, and both may have a handle 0x0028. Each
ATT packet is assigned to one database: responses, notifications and indications come from the
sender's, requests and writes go to the receiver's. Handles, discovery and pending reads are kept
per connection *and* database, and rows about the iPhone's own database say `(iPhone's database)`.

A characteristic matches by its `handle:` first, then by `uuid:`. UUIDs are learned from the GATT
discovery responses (Read By Type for characteristic declarations) present in the capture. iOS
caches the GATT database of known accessories, so a capture started later may contain no discovery:
then the ATT row shows `attribute=0x00NN` and no `uuid=`, and you add that `handle:`. A pinned
handle means the accessory's database; add `server: phone` for a characteristic the iPhone hosts
(a UUID matches in whichever database it was discovered in, unless `server:` restricts it).

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
**Fully decoded only** also leaves out rows whose bytes did not fit the definition: those are
logged at `Warning`. Both combine with the level and text filters and hide rather than discard.
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
characters, 32 bytes shown per `bytes` field. Per file: 512 types, 256 fields per type, 512
characteristics, 4,096 enum cases. Decoding runs on the capture worker.
