import Foundation

/// One line of `adb devices -l`.
public struct ADBDeviceRecord: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case device
        case unauthorized
        case offline
        case other(String)

        init(_ value: String) {
            switch value {
            case "device": self = .device
            case "unauthorized": self = .unauthorized
            case "offline": self = .offline
            default: self = .other(value)
            }
        }
    }

    public let serial: String
    public let state: State
    public let model: String?
    public let product: String?
    public let device: String?
    public let transportID: String?
    public let isUSB: Bool

    /// adb names a local emulator `emulator-<console port>`.
    public var isEmulator: Bool { serial.hasPrefix("emulator-") }

    public var displayName: String {
        (model ?? product ?? serial).replacingOccurrences(of: "_", with: " ")
    }

    public static func parse(_ output: String, maximumDevices: Int = 64) throws -> [ADBDeviceRecord] {
        var records: [ADBDeviceRecord] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // The header, and the daemon's own start-up chatter ("* daemon started successfully").
            guard !line.isEmpty, !line.hasPrefix("List of devices"), !line.hasPrefix("*"),
                  !line.hasPrefix("adb server") else { continue }
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count >= 2 else { continue }
            var properties: [String: String] = [:]
            var usb = false
            for field in fields.dropFirst(2) {
                if let colon = field.firstIndex(of: ":") {
                    let key = String(field[..<colon])
                    properties[key] = String(field[field.index(after: colon)...])
                    if key == "usb" { usb = true }
                }
            }
            records.append(ADBDeviceRecord(
                serial: fields[0], state: State(fields[1]), model: properties["model"],
                product: properties["product"], device: properties["device"],
                transportID: properties["transport_id"], isUSB: usb
            ))
            guard records.count <= maximumDevices else { throw AndroidRecordError.tooManyDevices(maximum: maximumDevices) }
        }
        return records
    }
}

public enum AndroidRecordError: Error, Equatable, Sendable {
    case tooManyDevices(maximum: Int)
    case hierarchyTooLarge
    case malformedHierarchy(String)
}

/// The facts Threading reads from one AVD's `config.ini` (and its `<name>.ini` pointer).
public struct AVDConfiguration: Equatable, Sendable {
    public let name: String
    public let displayName: String
    public let apiLevel: Int?
    public let lcdWidth: Int?
    public let lcdHeight: Int?
    public let lcdDensity: Int?
    public let tag: String?
    /// The SDK-relative system image directory (`system-images/android-36/default/arm64-v8a/`).
    public let systemImagePath: String?

    public static func parse(name: String, config: String) -> AVDConfiguration {
        var values: [String: String] = [:]
        for line in config.split(whereSeparator: \.isNewline) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            values[String(line[..<equals]).trimmingCharacters(in: .whitespaces)] =
                String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
        }
        let sysdir = values["image.sysdir.1"] ?? ""
        let api = sysdir.split(separator: "/").first { $0.hasPrefix("android-") }
            .flatMap { Int($0.dropFirst("android-".count).prefix { $0.isNumber }) }
        let display = values["avd.ini.displayname"].flatMap { $0.isEmpty ? nil : $0 }
            ?? name.replacingOccurrences(of: "_", with: " ")
        return AVDConfiguration(
            name: name, displayName: display, apiLevel: api,
            lcdWidth: values["hw.lcd.width"].flatMap(Int.init),
            lcdHeight: values["hw.lcd.height"].flatMap(Int.init),
            lcdDensity: values["hw.lcd.density"].flatMap(Int.init),
            tag: values["tag.display"] ?? values["tag.id"],
            systemImagePath: sysdir.isEmpty ? nil : sysdir
        )
    }

    /// Android's own tablet boundary: a smallest width of 600dp.
    public var isTablet: Bool {
        guard let lcdWidth, let lcdHeight, let lcdDensity, lcdDensity > 0 else { return false }
        return Double(min(lcdWidth, lcdHeight)) * 160 / Double(lcdDensity) >= 600
    }

    /// The marketing version for an API level, for the runtime line ("Android 16 · API 36").
    public static func releaseName(apiLevel: Int) -> String {
        let versions: [Int: String] = [
            21: "5.0", 22: "5.1", 23: "6", 24: "7.0", 25: "7.1", 26: "8.0", 27: "8.1", 28: "9",
            29: "10", 30: "11", 31: "12", 32: "12L", 33: "13", 34: "14", 35: "15", 36: "16", 37: "17",
        ]
        guard let version = versions[apiLevel] else { return "API \(apiLevel)" }
        return "Android \(version) · API \(apiLevel)"
    }
}
