import Foundation
import ThreadingSimulatorKit

final class SimulatorInputSender: @unchecked Sendable {
    enum InputError: LocalizedError {
        case unavailable
        case invalidCoordinate
        case invalidDuration
        case textTooLong
        case unsupportedCharacter(Character)
        case unsupportedButton(SimulatorBridgeButton)

        var errorDescription: String? {
            switch self {
            case .unavailable: return "Direct input is unavailable for this Xcode."
            case .invalidCoordinate: return "Simulator coordinates must be between 0 and 1."
            case .invalidDuration: return "A Simulator drag must last 100–2000 milliseconds."
            case .textTooLong: return "Simulator text is limited to 1,024 characters per call."
            case .unsupportedCharacter(let character):
                return "Simulator text does not support the character \(String(reflecting: character))."
            case .unsupportedButton(let button):
                return "An iOS Simulator has no \(button.rawValue) button."
            }
        }
    }

    private let inputLock = NSLock()
    private var stopped = false
    private var activeContact: (x: Double, y: Double)?
    private let bridge: SimulatorPrivateBridge
    private let orientation: SimulatorScreenOrientation

    init(bridge: SimulatorPrivateBridge, orientation: SimulatorScreenOrientation = .portrait) {
        self.bridge = bridge
        self.orientation = orientation
    }

    func send(_ command: SimulatorBridgeInput) throws {
        guard bridge.supportsInput, inputLock.withLock({ !stopped }) else { throw InputError.unavailable }
        switch command {
        case .tap(let x, let y):
            try validate(x, y)
            try touch(x: x, y: y, down: true)
            do {
                Thread.sleep(forTimeInterval: 0.05)
                try touch(x: x, y: y, down: false)
            } catch {
                // A failed acknowledgement must not leave a held finger in the device state.
                try? touch(x: x, y: y, down: false)
                throw error
            }

        case .drag(let fromX, let fromY, let toX, let toY, let durationMilliseconds):
            try validate(fromX, fromY)
            try validate(toX, toY)
            guard (100...2_000).contains(durationMilliseconds) else {
                throw InputError.invalidDuration
            }
            let steps = min(120, max(2, durationMilliseconds / 16))
            let delay = Double(durationMilliseconds) / 1_000 / Double(steps)
            var lastX = fromX
            var lastY = fromY
            do {
                for step in 0...steps {
                    let fraction = Double(step) / Double(steps)
                    lastX = fromX + (toX - fromX) * fraction
                    lastY = fromY + (toY - fromY) * fraction
                    try touch(x: lastX, y: lastY, down: true)
                    if step != steps { Thread.sleep(forTimeInterval: delay) }
                }
                try touch(x: toX, y: toY, down: false)
            } catch {
                try? touch(x: lastX, y: lastY, down: false)
                throw error
            }

        case .touch(let phase, let x, let y):
            try validate(x, y)
            switch phase {
            case .began:
                try touch(x: x, y: y, down: true)
            case .moved:
                // A digitizer "move" is another contact-down at the new point. Moves are sent
                // non-blocking: waiting on each one's HID completion serialized panning at the HID
                // rate. A dropped move is harmless — the next one corrects the position.
                try touch(x: x, y: y, down: true, wait: false)
            case .ended:
                try touch(x: x, y: y, down: false)
            case .cancelled:
                // A cancellation carries no meaningful point: lift the finger where it is, so the
                // guest never sees the contact jump to a corner and fling.
                try releaseActiveContact()
            }

        case .text(let text):
            guard text.count <= SimulatorBridgeText.maximumCharacterCount else {
                throw InputError.textTooLong
            }
            for character in text {
                guard let stroke = Self.stroke(for: character) else {
                    throw InputError.unsupportedCharacter(character)
                }
                if stroke.shift {
                    try key(usage: 0xE1, down: true)
                    do {
                        try pressKey(usage: stroke.usage)
                        try key(usage: 0xE1, down: false)
                    } catch {
                        try? key(usage: 0xE1, down: false)
                        throw error
                    }
                } else {
                    try pressKey(usage: stroke.usage)
                }
            }

        case .button(let button):
            // Home/lock/side use the button-key builder; volume takes the consumer-usage HID path
            // (page 12, usage 233/234) — see SimulatorPrivateBridge.
            let press: (Bool) throws -> Void
            switch button {
            case .home: press = { try self.bridge.sendButton(source: 0, down: $0) }
            case .lock: press = { try self.bridge.sendButton(source: 1, down: $0) }
            case .side: press = { try self.bridge.sendButton(source: 3_000, down: $0) }
            case .volumeUp:
                press = { try self.bridge.sendHIDUsage(page: 12, usage: 233, down: $0) }
            case .volumeDown:
                press = { try self.bridge.sendHIDUsage(page: 12, usage: 234, down: $0) }
            case .back, .overview, .rotateLeft, .rotateRight:
                throw InputError.unsupportedButton(button)
            }
            try press(true)
            do {
                try press(false)
            } catch {
                try? press(false)
                throw error
            }
        }
    }

    private func releaseActiveContact() throws {
        try inputLock.withLock {
            guard let contact = activeContact else { return }
            activeContact = nil
            try bridge.sendTouch(x: contact.x, y: contact.y, down: false, wait: true)
        }
    }

    /// Closes input admission and lifts any held finger. Idempotent; a geometry change calls it on
    /// the ordered input queue, so a move already queued behind it cannot press again before the
    /// helper closes.
    func stop() {
        inputLock.withLock {
            stopped = true
            if let contact = activeContact {
                try? bridge.sendTouch(x: contact.x, y: contact.y, down: false, wait: false)
            }
            activeContact = nil
        }
    }

    private func validate(_ x: Double, _ y: Double) throws {
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
            throw InputError.invalidCoordinate
        }
    }

    private func touch(x: Double, y: Double, down: Bool, wait: Bool = true) throws {
        let point = orientation.nativePoint(x: x, y: y)
        try inputLock.withLock {
            guard !stopped || !down else { throw InputError.unavailable }
            // Retain an attempted down even if its acknowledgement fails: the guest may have
            // received it, so stop must still issue the matching release.
            if down { activeContact = (point.x, point.y) }
            try bridge.sendTouch(x: point.x, y: point.y, down: down, wait: wait)
            if !down { activeContact = nil }
        }
    }

    private func key(usage: UInt32, down: Bool) throws {
        guard !down || inputLock.withLock({ !stopped }) else { throw InputError.unavailable }
        try bridge.sendKeyboard(usage: usage, down: down)
    }

    private func pressKey(usage: UInt32) throws {
        try key(usage: usage, down: true)
        do {
            try key(usage: usage, down: false)
        } catch {
            try? key(usage: usage, down: false)
            throw error
        }
    }

    private static func stroke(for character: Character) -> (usage: UInt32, shift: Bool)? {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first,
              scalar.isASCII else { return nil }
        let value = scalar.value
        if (97...122).contains(value) { return (4 + value - 97, false) }
        if (65...90).contains(value) { return (4 + value - 65, true) }
        if (49...57).contains(value) { return (0x1E + value - 49, false) }
        if value == 48 { return (0x27, false) }

        let fixed: [Character: (UInt32, Bool)] = [
            "\u{8}": (0x2A, false), " ": (0x2C, false), "\n": (0x28, false),
            "\t": (0x2B, false),
            "-": (0x2D, false), "_": (0x2D, true), "=": (0x2E, false), "+": (0x2E, true),
            "[": (0x2F, false), "{": (0x2F, true), "]": (0x30, false), "}": (0x30, true),
            "\\": (0x31, false), "|": (0x31, true), ";": (0x33, false), ":": (0x33, true),
            "'": (0x34, false), "\"": (0x34, true), "`": (0x35, false), "~": (0x35, true),
            ",": (0x36, false), "<": (0x36, true), ".": (0x37, false), ">": (0x37, true),
            "/": (0x38, false), "?": (0x38, true), "!": (0x1E, true), "@": (0x1F, true),
            "#": (0x20, true), "$": (0x21, true), "%": (0x22, true), "^": (0x23, true),
            "&": (0x24, true), "*": (0x25, true), "(": (0x26, true), ")": (0x27, true),
        ]
        return fixed[character]
    }
}
