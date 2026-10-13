import Foundation

/// Definitions every project would otherwise copy: the Bluetooth SIG's common services, Apple's
/// Notification Center Service, and Nordic's two DFU generations. A project names the ones it
/// wants with `include: [gatt, ancs, nordic-dfu]`; each is compiled before the project's own file,
/// so the project wins wherever both describe the same UUID, type or enum.
///
/// Layouts are from the published specifications (Bluetooth SIG Assigned Numbers and GATT
/// Specification Supplement, Apple's ANCS specification, Nordic's nRF5 SDK DFU documentation);
/// no vendor code is copied. Type and enum names carry the profile's prefix so they do not
/// collide with a project's.
enum BluetoothProfiles {
    static let names = ["gatt", "ancs", "nordic-dfu", "nordic-legacy-dfu"]

    static func text(_ name: String) -> String? {
        switch name {
        case "gatt": return gatt
        case "ancs": return ancs
        case "nordic-dfu": return nordicDFU
        case "nordic-legacy-dfu": return nordicLegacyDFU
        default: return nil
        }
    }

    static let gatt = """
        services:
          - name: Generic Access
            uuid: 1800
            characteristics:
              - { name: Device Name, uuid: 2A00, message: GattText }
              - { name: Appearance, uuid: 2A01, message: { summary: "{appearance}", seq: [{ id: appearance, type: u16 }] } }
              - { name: Preferred Connection Parameters, uuid: 2A04, message: GattConnectionParameters }
          - name: Generic Attribute
            uuid: 1801
            characteristics:
              - { name: Service Changed, uuid: 2A05, message: GattServiceChanged }
              - { name: Client Supported Features, uuid: 2B29, message: { seq: [{ id: features, type: u8, flags: { robustCaching: 0, eatt: 1, multipleNotifications: 2 } }] } }
              - { name: Database Hash, uuid: 2B2A, message: GattBytes }
              - { name: Client Characteristic Configuration, uuid: 2902, message: GattClientConfiguration }
              - { name: Characteristic User Description, uuid: 2901, message: GattText }
          - name: Device Information
            uuid: 180A
            characteristics:
              - { name: Manufacturer Name, uuid: 2A29, message: GattText }
              - { name: Model Number, uuid: 2A24, message: GattText }
              - { name: Serial Number, uuid: 2A25, message: GattText }
              - { name: Hardware Revision, uuid: 2A27, message: GattText }
              - { name: Firmware Revision, uuid: 2A26, message: GattText }
              - { name: Software Revision, uuid: 2A28, message: GattText }
              - { name: System ID, uuid: 2A23, message: GattBytes }
              - { name: PnP ID, uuid: 2A50, message: GattPnpId }
          - name: Battery
            uuid: 180F
            characteristics:
              - { name: Battery Level, uuid: 2A19, message: { summary: "{level}", seq: [{ id: level, type: u8, unit: "%" }] } }
          - name: Current Time
            uuid: 1805
            characteristics:
              - { name: Current Time, uuid: 2A2B, message: GattCurrentTime }
              - { name: Local Time Information, uuid: 2A0F, message: GattLocalTime }
          - name: Heart Rate
            uuid: 180D
            characteristics:
              - { name: Heart Rate Measurement, uuid: 2A37, message: GattHeartRate }
              - { name: Body Sensor Location, uuid: 2A38, message: { summary: "{location}", seq: [{ id: location, type: u8, enum: GattBodySensorLocation }] } }
              - { name: Heart Rate Control Point, uuid: 2A39, message: { seq: [{ id: command, type: u8, enum: GattHeartRateCommand }] } }

        types:
          GattText:
            summary: "{value}"
            seq:
              - { id: value, type: str }
          GattBytes:
            summary: "{value}"
            seq:
              - { id: value, type: bytes }
          GattConnectionParameters:
            summary: "interval {minimum}–{maximum} latency {latency} timeout {timeout}"
            seq:
              - { id: minimum, type: u16, scale: 1.25, unit: " ms" }
              - { id: maximum, type: u16, scale: 1.25, unit: " ms" }
              - { id: latency, type: u16 }
              - { id: timeout, type: u16, scale: 10, unit: " ms" }
          GattServiceChanged:
            summary: "handles {start}–{end} changed"
            seq:
              - { id: start, type: u16 }
              - { id: end, type: u16 }
          GattClientConfiguration:
            summary: "{configuration}"
            seq:
              - { id: configuration, type: u16, flags: { notifications: 0, indications: 1 } }
          GattPnpId:
            summary: "{source} vendor {vendor} product {product} version {version}"
            seq:
              - { id: source, type: u8, enum: GattVendorIdSource }
              - { id: vendor, type: u16 }
              - { id: product, type: u16 }
              - { id: version, type: u16 }
          GattCurrentTime:
            summary: "{year}-{month}-{day} {hours}:{minutes}:{seconds} {dayOfWeek} {reason}"
            seq:
              - { id: year, type: u16 }
              - { id: month, type: u8 }
              - { id: day, type: u8 }
              - { id: hours, type: u8 }
              - { id: minutes, type: u8 }
              - { id: seconds, type: u8 }
              - { id: dayOfWeek, type: u8, enum: GattDayOfWeek }
              - { id: fractions, type: u8, hidden: true }
              - { id: reason, type: u8, flags: { manual: 0, externalReference: 1, timeZone: 2, daylightSaving: 3 } }
          GattLocalTime:
            summary: "UTC offset {offset} DST {dst}"
            seq:
              - { id: offset, type: s8, scale: 0.25, unit: " h" }
              - { id: dst, type: u8, enum: GattDaylightSaving }
          # Heart rate is u8 or u16 by flag bit 0; energy and RR intervals are present only when flagged.
          GattHeartRate:
            seq:
              - id: flags
                type: u8
                flags: { wideRate: 0, contactDetected: 1, contactSupported: 2, energyPresent: 3, intervalsPresent: 4 }
              - { id: rate, type: u8, unit: " bpm", if: "!wideRate" }
              - { id: wideRate, type: u16, unit: " bpm", if: wideRate }
              - { id: energy, type: u16, unit: " kJ", if: energyPresent }
              - { id: intervals, type: u16, scale: 0.9765625, unit: " ms", repeat: eos, if: intervalsPresent }

        enums:
          GattVendorIdSource: { 1: BluetoothSIG, 2: USB }
          GattDayOfWeek: { 0: unknown, 1: Monday, 2: Tuesday, 3: Wednesday, 4: Thursday, 5: Friday, 6: Saturday, 7: Sunday }
          GattDaylightSaving: { 0: standard, 2: half-hour, 4: daylight, 8: double, 255: unknown }
          GattBodySensorLocation: { 0: other, 1: chest, 2: wrist, 3: finger, 4: hand, 5: earLobe, 6: foot }
          GattHeartRateCommand: { 1: resetEnergyExpended }
        """

    static let ancs = """
        services:
          - name: ANCS
            uuid: 7905F431-B5CE-4E99-A40F-4B1E122D00D0
            characteristics:
              - { name: ANCS Notification Source, uuid: 9FBF120D-6301-42D9-8C58-25E699A21DBD, server: phone, message: AncsNotificationSource }
              - { name: ANCS Control Point, uuid: 69D1D8F3-45E1-49A8-9821-9BBDFDAAD9D9, server: phone, message: AncsControlPoint }
              # A long answer continues in further notifications without the header; those rows warn.
              - { name: ANCS Data Source, uuid: 22EAC6E9-24D6-4BB5-BE44-B36ACE7C7BFB, server: phone, message: AncsDataSource }

        types:
          AncsNotificationSource:
            summary: "{eventId} {categoryId} uid {notificationUid} {eventFlags}"
            seq:
              - { id: eventId, type: u8, enum: AncsEventId }
              - { id: eventFlags, type: u8, flags: { silent: 0, important: 1, preExisting: 2, positiveAction: 3, negativeAction: 4 } }
              - { id: categoryId, type: u8, enum: AncsCategoryId }
              - { id: categoryCount, type: u8 }
              - { id: notificationUid, type: u32 }
          AncsControlPoint:
            summary: "{commandId} {body}"
            seq:
              - { id: commandId, type: u8, enum: AncsCommandId }
              - id: body
                type:
                  switch-on: commandId
                  cases:
                    GetNotificationAttributes: AncsGetNotificationAttributes
                    PerformNotificationAction: AncsPerformNotificationAction
                    _: bytes
          AncsGetNotificationAttributes:
            summary: "uid {notificationUid} {attributes}"
            seq:
              - { id: notificationUid, type: u32 }
              - { id: attributes, type: AncsAttributeRequest, repeat: eos }
          AncsAttributeRequest:
            summary: "{attributeId}{maxLength}"
            seq:
              - { id: attributeId, type: u8, enum: AncsNotificationAttributeId }
              - id: maxLength
                type:
                  switch-on: attributeId
                  cases:
                    Title: AncsMaxLength
                    Subtitle: AncsMaxLength
                    Message: AncsMaxLength
                    _: AncsNothing
          AncsMaxLength:
            summary: "≤{maxLength}"
            seq:
              - { id: maxLength, type: u16 }
          AncsNothing:
            summary: ""
            seq:
              - { id: none, type: bytes, size: 0, hidden: true }
          AncsPerformNotificationAction:
            summary: "uid {notificationUid} {actionId}"
            seq:
              - { id: notificationUid, type: u32 }
              - { id: actionId, type: u8, enum: AncsActionId }
          AncsDataSource:
            summary: "{commandId} uid {notificationUid} {attributes}"
            seq:
              - { id: commandId, type: u8, enum: AncsCommandId }
              - { id: notificationUid, type: u32 }
              - { id: attributes, type: AncsAttribute, repeat: eos }
          AncsAttribute:
            summary: "{attributeId}={value}"
            seq:
              - { id: attributeId, type: u8, enum: AncsNotificationAttributeId }
              - { id: length, type: u16, hidden: true }
              - { id: value, type: str, size: length }

        enums:
          AncsEventId: { 0: Added, 1: Modified, 2: Removed }
          AncsCategoryId:
            0: Other
            1: IncomingCall
            2: MissedCall
            3: Voicemail
            4: Social
            5: Schedule
            6: Email
            7: News
            8: HealthAndFitness
            9: BusinessAndFinance
            10: Location
            11: Entertainment
          AncsCommandId: { 0: GetNotificationAttributes, 1: GetAppAttributes, 2: PerformNotificationAction }
          AncsNotificationAttributeId:
            0: AppIdentifier
            1: Title
            2: Subtitle
            3: Message
            4: MessageSize
            5: Date
            6: PositiveActionLabel
            7: NegativeActionLabel
          AncsActionId: { 0: Positive, 1: Negative }
        """

    /// nRF5 SDK 12 and later, and nRF Connect SDK's MCUboot-less Secure DFU.
    static let nordicDFU = """
        services:
          - name: Secure DFU
            uuid: FE59
            characteristics:
              - { name: Secure DFU Control Point, uuid: 8EC90001-F315-4F60-9FB8-838830DAEA50, tx: NordicDfuRequest, rx: NordicDfuResponse }
              - { name: Secure DFU Packet, uuid: 8EC90002-F315-4F60-9FB8-838830DAEA50, message: NordicDfuPacket }
              - { name: Buttonless DFU, uuid: 8EC90003-F315-4F60-9FB8-838830DAEA50, tx: NordicButtonlessRequest, rx: NordicButtonlessResponse }
              - { name: Buttonless DFU (bonded), uuid: 8EC90004-F315-4F60-9FB8-838830DAEA50, tx: NordicButtonlessRequest, rx: NordicButtonlessResponse }

        types:
          NordicDfuRequest:
            summary: "{op} {body}"
            seq:
              - { id: op, type: u8, enum: NordicDfuOp }
              - id: body
                type:
                  switch-on: op
                  cases:
                    CREATE: { summary: "{type} {size}", seq: [{ id: type, type: u8, enum: NordicDfuObject }, { id: size, type: u32, unit: " B" }] }
                    SET_PRN: { summary: "every {packets} packets", seq: [{ id: packets, type: u16 }] }
                    SELECT: { summary: "{type}", seq: [{ id: type, type: u8, enum: NordicDfuObject }] }
                    PING: { summary: "#{id}", seq: [{ id: id, type: u8 }] }
                    _: bytes
          NordicDfuResponse:
            summary: "{request} {result}{body}"
            seq:
              - { id: op, type: u8, enum: NordicDfuOp, hidden: true }
              - { id: request, type: u8, enum: NordicDfuOp }
              - { id: result, type: u8, enum: NordicDfuResult }
              - id: body
                if: "result == SUCCESS"
                type:
                  switch-on: request
                  cases:
                    SELECT: { summary: " max {maxSize} offset {offset} crc32 {crc}", seq: [{ id: maxSize, type: u32 }, { id: offset, type: u32 }, { id: crc, type: u32 }] }
                    CALCULATE_CHECKSUM: { summary: " offset {offset} crc32 {crc}", seq: [{ id: offset, type: u32 }, { id: crc, type: u32 }] }
                    MTU_GET: { summary: " mtu {mtu}", seq: [{ id: mtu, type: u16 }] }
                    PING: { summary: " #{id}", seq: [{ id: id, type: u8 }] }
                    _: bytes
          NordicDfuPacket:
            summary: "{data}"
            seq:
              - { id: data, type: bytes }
          NordicButtonlessRequest:
            summary: "{op} {name}"
            seq:
              - { id: op, type: u8, enum: NordicButtonlessOp }
              - { id: length, type: u8, if: "op == SET_NAME", hidden: true }
              - { id: name, type: str, size: length, if: "op == SET_NAME" }
          NordicButtonlessResponse:
            summary: "{request} {result}"
            seq:
              - { id: op, type: u8, enum: NordicButtonlessOp, hidden: true }
              - { id: request, type: u8, enum: NordicButtonlessOp }
              - { id: result, type: u8, enum: NordicButtonlessResult }

        enums:
          NordicDfuOp:
            0x00: PROTOCOL_VERSION
            0x01: CREATE
            0x02: SET_PRN
            0x03: CALCULATE_CHECKSUM
            0x04: EXECUTE
            0x06: SELECT
            0x07: MTU_GET
            0x08: WRITE
            0x09: PING
            0x0A: HW_VERSION_GET
            0x0B: FW_VERSION_GET
            0x0C: ABORT
            0x60: RESPONSE
          NordicDfuObject: { 1: COMMAND, 2: DATA }
          NordicDfuResult:
            0x00: { name: INVALID, level: error }
            0x01: { name: SUCCESS, level: info }
            0x02: { name: OP_CODE_NOT_SUPPORTED, level: error }
            0x03: { name: INVALID_PARAMETER, level: error }
            0x04: { name: INSUFFICIENT_RESOURCES, level: error }
            0x05: { name: INVALID_OBJECT, level: error }
            0x07: { name: UNSUPPORTED_TYPE, level: error }
            0x08: { name: OPERATION_NOT_PERMITTED, level: error }
            0x0A: { name: OPERATION_FAILED, level: error }
            0x0B: { name: EXTENDED_ERROR, level: error }
          NordicButtonlessOp: { 0x01: ENTER_BOOTLOADER, 0x02: SET_NAME, 0x20: RESPONSE }
          NordicButtonlessResult:
            0x01: { name: SUCCESS, level: info }
            0x02: { name: OP_CODE_NOT_SUPPORTED, level: error }
            0x04: { name: OPERATION_FAILED, level: error }
            0x05: { name: INVALID_ADVERTISEMENT_NAME, level: error }
            0x06: { name: BUSY, level: warning }
            0x07: { name: NOT_BONDED, level: error }

        transactions:
          - name: Secure DFU
            request:  { characteristic: Secure DFU Control Point, op: write }
            response: { characteristic: Secure DFU Control Point, op: notify }
            key: op = request
            timeout: 10s
          - name: Buttonless DFU
            request:  { characteristic: Buttonless DFU, op: write }
            response: { characteristic: Buttonless DFU, op: indicate }
            key: op = request
            timeout: 10s

        streams:
          # Objects are created and executed one at a time, so the image has no single total here.
          - name: Secure DFU image
            data: { characteristic: Secure DFU Packet, op: write }
        """

    /// nRF5 SDK 11 and earlier. The packet characteristic carries three different things, told
    /// apart only by the control point's last opcode.
    static let nordicLegacyDFU = """
        services:
          - name: Legacy DFU
            uuid: 00001530-1212-EFDE-1523-785FEABCD123
            characteristics:
              - { name: Legacy DFU Control Point, uuid: 00001531-1212-EFDE-1523-785FEABCD123, message: NordicLegacyControl }
              - name: Legacy DFU Packet
                uuid: 00001532-1212-EFDE-1523-785FEABCD123
                message:
                  switch-on: Legacy DFU Control Point.op
                  cases:
                    START_DFU: { summary: "sizes softdevice {softdevice} bootloader {bootloader} application {application}", seq: [{ id: softdevice, type: u32 }, { id: bootloader, type: u32 }, { id: application, type: u32 }] }
                    INIT_PARAMS: NordicLegacyInitPacket
                    _: { summary: "{image}", seq: [{ id: image, type: bytes }] }
              - { name: Legacy DFU Version, uuid: 00001534-1212-EFDE-1523-785FEABCD123, message: { summary: "{major}.{minor}", seq: [{ id: minor, type: u8 }, { id: major, type: u8 }] } }

        types:
          NordicLegacyControl:
            summary: "{op} {body}"
            seq:
              - { id: op, type: u8, enum: NordicLegacyOp }
              - id: body
                type:
                  switch-on: op
                  cases:
                    START_DFU: { summary: "{image}", seq: [{ id: image, type: u8, enum: NordicLegacyImage }] }
                    INIT_PARAMS: { summary: "{phase}", seq: [{ id: phase, type: u8, enum: NordicLegacyInitPhase }] }
                    PACKET_NOTIFY_REQ: { summary: "every {packets} packets", seq: [{ id: packets, type: u16 }] }
                    RESPONSE: { summary: "{request} → {status}", seq: [{ id: request, type: u8, enum: NordicLegacyOp }, { id: status, type: u8, enum: NordicLegacyStatus }] }
                    PACKET_RESPONSE: { summary: "{received} received", seq: [{ id: received, type: u32, unit: " B" }] }
                    _: bytes
          NordicLegacyInitPacket:
            summary: "init device {deviceType} rev {deviceRevision} app {applicationVersion} softdevices {softdevices} crc16 {crc}"
            seq:
              - { id: deviceType, type: u16 }
              - { id: deviceRevision, type: u16 }
              - { id: applicationVersion, type: u32 }
              - { id: softdeviceCount, type: u16, hidden: true }
              - { id: softdevices, type: u16, repeat: softdeviceCount }
              - { id: crc, type: u16 }

        enums:
          NordicLegacyOp:
            0x01: START_DFU
            0x02: INIT_PARAMS
            0x03: RECEIVE_IMAGE
            0x04: VALIDATE
            0x05: ACTIVATE_AND_RESET
            0x06: RESET
            0x07: REPORT_RECEIVED_SIZE
            0x08: PACKET_NOTIFY_REQ
            0x10: RESPONSE
            0x11: PACKET_RESPONSE
          NordicLegacyImage: { 1: SOFTDEVICE, 2: BOOTLOADER, 3: SOFTDEVICE_BOOTLOADER, 4: APPLICATION }
          NordicLegacyInitPhase: { 0: START, 1: COMPLETE }
          NordicLegacyStatus:
            0x01: { name: SUCCESS, level: info }
            0x02: { name: INVALID_STATE, level: error }
            0x03: { name: NOT_SUPPORTED, level: error }
            0x04: { name: DATA_EXCEEDS_LIMIT, level: error }
            0x05: { name: CRC_ERROR, level: error }
            0x06: { name: OPERATION_FAILED, level: error }

        transactions:
          - name: Legacy DFU
            request:  { characteristic: Legacy DFU Control Point, op: write }
            response: { characteristic: Legacy DFU Control Point, op: notify, where: { op: RESPONSE } }
            key: op = request
            timeout: 30s

        streams:
          - name: Legacy DFU image
            start: { characteristic: Legacy DFU Packet, total: application }
            info:  { characteristic: Legacy DFU Packet, crc16: crc }
            data:  { characteristic: Legacy DFU Packet, data: image }
        """
}
