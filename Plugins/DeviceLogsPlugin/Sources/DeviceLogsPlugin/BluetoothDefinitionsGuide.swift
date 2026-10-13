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
                # handle: 0x0025   # pin it when the capture starts after GATT discovery
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
        """

    struct Reference: Equatable {
        let term: String
        let detail: String
    }

    static let reference: [Reference] = [
        .init(term: "File", detail: "<project>/.threading/bluetooth.yaml, committed with your app."),
        .init(term: "Characteristic", detail: "name, uuid and/or handle, then message: (or rx: / tx:) naming a type."),
        .init(term: "Numbers", detail: "u8 u16 u24 u32 u64, s8 … s64, f32 f64 — little-endian; add be (u16be) for big-endian."),
        .init(term: "Other types", detail: "bool, bytes, str, or any name under types:."),
        .init(term: "Field keys", detail: "id, type, enum, scale, unit, flags, size, repeat, hidden."),
        .init(term: "Sizes", detail: "size: 4, size: rest, or size: an earlier integer field. repeat: eos, a count, or a field."),
        .init(term: "Choices", detail: "type: { switch-on: kind, cases: { NAME: Type, 0x05: Type, _: bytes } }."),
        .init(term: "Summary", detail: "summary: \"{kind} #{seq}\" prints a type as one line; otherwise id=value pairs."),
    ]

    static let explanation = L10n.string("Threading decodes Bluetooth down to ATT: which attribute was written or notified, and its raw bytes. What those bytes mean is your app's protocol, so your project describes it in a small YAML file and every matching row shows decoded fields instead of hex.")

    /// A prompt for a coding agent working in the same checkout.
    static func agentPrompt(path: String) -> String {
        """
        Write Threading Bluetooth packet definitions for this app at \(path).

        1. Find the app's BLE code: the GATT service and characteristic UUIDs it uses, and the code that encodes values it writes and decodes notifications/indications/reads it receives (look for CoreBluetooth `CBUUID`, Android `BluetoothGattCharacteristic`/`UUID.fromString`, Kotlin Multiplatform/Kable/Nordic BLE wrappers, firmware structs, or protobuf messages sent over a characteristic).
        2. For each characteristic, describe its value as a type. Use exactly this format (YAML subset: no anchors, tags or | blocks):

        \(example)

        Rules: numbers are little-endian unless suffixed `be`; `size:` and `repeat:` take a number, `rest`/`eos`, or an earlier integer field id; `switch-on:` names an earlier integer field and `cases:` keys are enum names, numbers, or `_`; `scale:` multiplies; `flags:` names bits; `hidden: true` keeps length fields out of the row; `summary:` with {field} placeholders gives one readable line. Use `rx:`/`tx:` when the two directions differ. Add `handle: 0x00NN` only when a captured row shows the attribute handle and no discovery happened.
        3. Prefer the app's own names for messages, enums and fields. Do not guess layouts you cannot find in the code; leave them as `bytes` with a comment.
        4. Save the file. Threading reloads it within a second; check the Device Logs Bluetooth tab footer for "Packet definitions: … characteristics" or a line-numbered error, and fix any error it reports.
        """
    }
}
