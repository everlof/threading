import Foundation
import ThreadingDesignKit

/// What a newcomer needs to write `.threading/bluetooth.yaml`: a complete example that compiles,
/// a compact reference, and a prompt that hands the job to a coding agent.
///
/// One source for all three surfaces — the pane's "?" panel, the file "Create File" writes, and
/// `docs/bluetooth-packet-definitions.md` — and `BluetoothPacketDefinitionTests` compiles
/// `example` and decodes a packet with it, so the example cannot rot into something the parser
/// refuses.
enum BluetoothDefinitionsGuide {
    static let example = """
        # Threading Bluetooth packet definitions (Device Logs → Bluetooth → ?).
        # ATT values of the characteristics below are decoded with these types.
        # Saved changes apply to the next packet; no Rescan needed.
        version: 1

        services:
          - name: Example Watch
            uuid: 6E400001-B5A3-F393-E0A9-E50E24DCCA9E
            characteristics:
              - name: Messages
                uuid: 6E400003-B5A3-F393-E0A9-E50E24DCCA9E
                # handle: 0x0025   # set it when the capture missed discovery
                message: Frame       # both directions; or rx: / tx: for one each
              - name: Battery Level
                uuid: 2A19
                message: { seq: [{ id: percent, type: u8, unit: "%" }] }

        types:
          Frame:
            summary: "{kind} #{seq} {body}"
            seq:
              - { id: kind, type: u8, enum: MessageKind }
              - { id: seq, type: u16 }          # little-endian unless written u16be
              - id: body
                type:
                  switch-on: kind
                  cases:
                    LOCATION: Location
                    STATUS: Status
                    _: bytes                     # anything else: show the remaining bytes

          Location:
            seq:
              - { id: lat, type: s32, scale: 0.0000001, unit: "°" }
              - { id: lon, type: s32, scale: 0.0000001, unit: "°" }
              - { id: accuracy, type: u16, scale: 0.1, unit: " m" }
              - { id: flags, type: u8, flags: { precise: 0, background: 1 } }

          Status:
            seq:
              - { id: name_length, type: u8, hidden: true }
              - { id: name, type: str, size: name_length }
              - { id: readings, type: s16, scale: 0.01, repeat: eos }

        enums:
          MessageKind: { 0x01: LOCATION, 0x02: STATUS }

        # Optional: colour words in decoded rows — enum and flag names, or a field
        # id to colour its value. red orange yellow green teal blue purple pink gray.
        highlight:
          LOCATION: green
          STATUS: blue
          accuracy: orange
        """

    struct Reference: Equatable {
        let term: String
        let detail: String
    }

    static let reference: [Reference] = [
        .init(term: "File", detail: "<project>/.threading/bluetooth.yaml, committed with your app."),
        .init(term: "Characteristic", detail: "name, uuid and/or handle (server: phone for the iPhone's own), then message: (or rx: / tx:)."),
        .init(term: "Numbers", detail: "u8 u16 u24 u32 u64, s8 … s64, f32 f64 — little-endian; add be (u16be) for big-endian."),
        .init(term: "Other types", detail: "bool, bytes, str, msgpack, or any name under types:."),
        .init(term: "Field keys", detail: "id, type, enum, scale, unit, flags, size, repeat, hidden."),
        .init(term: "Sizes", detail: "size: 4, size: rest, or size: an earlier integer field. repeat: eos, a count, or a field."),
        .init(term: "Choices", detail: "type: { switch-on: kind, cases: { NAME: Type, 0x05: Type, _: bytes } }."),
        .init(term: "Summary", detail: "summary: \"{kind} #{seq}\" prints a type as one line; otherwise id=value pairs."),
        .init(term: "MessagePack", detail: "type: msgpack, with match: [{ pattern: \"{ $cmd: $value }\", summary: \"{cmd} {value}\" }] and enum: { cmd: Commands }."),
        .init(term: "Learned enums", detail: "learn: { from: <characteristic>, pattern: \"{ map_*: { $number: $name } }\" } under an enum: the device's own table, remembered per device."),
        .init(term: "Shapes", detail: "shapes: { Values: { datetime: [year, month, date] } } with values: Values names array positions by command."),
        .init(term: "Highlight", detail: "highlight: { LOCATION: green, accuracy: orange } colours a word, or a field's value."),
    ]

    /// The advanced half of the format, shown to an agent beside the example. Each line is a
    /// working construct, and a test compiles the whole snippet.
    static let advancedExample = """
        # A self-describing protocol: MessagePack, with the device's own command table.
        services:
          - name: Example Watch
            characteristics:
              - name: Command
                uuid: 6E401980-B5A3-F393-E0A9-E6414D494E41
                message: CommandMessage
              - name: ANCS Source            # a characteristic the iPhone hosts
                uuid: 9FBF120D-6301-42D9-8C58-25E699A21DBD
                server: phone
                message: bytes

        types:
          CommandMessage:
            seq:
              - id: value
                type: msgpack                # one MessagePack value
                match:                       # first pattern that fits renders the row
                  - { pattern: "{ $cmd: $value }", summary: "{cmd} {value}" }
                  - { pattern: "[ $cmd:int, ...$args ]", summary: "read {cmd} {args}" }
                  - { pattern: "$cmd:int", summary: "read {cmd}" }
                enum: { cmd: Command }       # name the $cmd capture with an enum
                values: CommandValues        # shape $value by the command's name

        shapes:
          CommandValues:
            datetime: [year, month, date, hour, minute, second]

        enums:
          Command:
            0x00: map_cmd                    # fixed entries, if any
            learn:                           # the rest come from the device's own traffic
              from: Command                  # a characteristic name above
              pattern: "{ map_cmd: { $number:int: $name:str } }"
          Setting:
            learn:
              from: Command
              pattern: "{ map_settings: { $number:int: $name:str } }"
              names: Command                 # map_settings is a Command name
        """

    static let explanation = L10n.string("Threading decodes Bluetooth down to ATT: which attribute was written or notified, and its raw bytes. What those bytes mean is your app's protocol, so your project describes it in a small YAML file and every matching row shows decoded fields instead of hex.")

    /// A prompt for a coding agent working in the same checkout.
    static func agentPrompt(path: String) -> String {
        """
        Write Threading Bluetooth packet definitions for this app at \(path).

        1. Find the app's BLE code: the GATT service and characteristic UUIDs it uses, and the code that encodes values it writes and decodes notifications/indications/reads it receives (look for CoreBluetooth `CBUUID`, Android `BluetoothGattCharacteristic`/`UUID.fromString`, Kotlin Multiplatform/Kable/Nordic BLE wrappers, firmware structs, MessagePack or protobuf messages sent over a characteristic).
        2. For each characteristic, describe its value as a type. Use exactly this format (YAML subset: no anchors, tags or | blocks):

        \(example)

        Rules: numbers are little-endian unless suffixed `be`; `size:` and `repeat:` take a number, `rest`/`eos`, or an earlier integer field id; `switch-on:` names an earlier integer field and `cases:` keys are enum names, numbers, or `_`; `scale:` multiplies; `flags:` names bits; `hidden: true` keeps length fields out of the row; `summary:` with {field} placeholders gives one readable line. Use `rx:`/`tx:` when the two directions differ. Add `handle: 0x00NN` only when a captured row shows the attribute handle and no discovery happened; add `server: phone` to a characteristic the iPhone itself hosts (ANCS, Current Time). Long reads and long writes are joined before decoding.

        3. If a characteristic carries MessagePack, or the device assigns its own command numbers at runtime (it publishes a number → name table the app reads and caches), use these instead of fixed layouts:

        \(advancedExample)

        Pattern grammar: `{ K: V }` matches a map entry by entry (one rendered part per entry); `[a, b, ...$rest]` an array; `$name` binds anything, `$name:int` (or str, float, bool, nil, bin, map, array) binds one kind; `_` matches anything; a bare word matches a string or an integer's enum name, with `*` as a wildcard (`map_*`); numbers and "quoted strings" match literally. A `learn:` pattern must bind `$number` and `$name`; learned names win over fixed ones, are remembered per device across captures, and may differ per firmware, so describe values by command *name* (shapes, summaries), never by number. Use `names:` when the pattern's words come from another enum.
        4. Prefer the app's own names for messages, enums, commands and fields. Do not guess layouts you cannot find in the code; leave them as `bytes` (or plain `msgpack`) with a comment. Optionally add `highlight: { WORD: green }` for words worth spotting (colours: red orange yellow green teal blue purple pink gray).
        5. Save the file. Threading reloads it within a second. Check it with the Device Logs tools: `visible` answers with a `Packet definitions: … characteristics, … types` line (plus what devices taught, e.g. `Command: 149 learned`) or a line-numbered error to fix; `search` for "App" rows, or focus with `packets: "app"`, shows decoded packets, and rows ending in ⚠ name the field whose bytes did not fit.
        """
    }
}
