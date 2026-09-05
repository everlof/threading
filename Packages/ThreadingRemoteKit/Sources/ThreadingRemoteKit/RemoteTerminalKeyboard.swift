import Foundation

// The customizable terminal key bar's vocabulary: what a key *is*, how a run of them is
// stored, and which bytes each one puts on the PTY. This is device-local model, not wire
// data — a layout never leaves the phone that authored it — but it lives in this package
// because it is pure Foundation shared vocabulary (the defaults are keyed by the same
// `agentKind` strings the wire speaks) and because this is the one iOS-shared target with
// a test suite. The encoder is where the correctness lives: modifier-aware CSI sequences
// and the application-cursor-mode split are exactly the details a view-embedded string
// table got wrong the first time.

/// The modifier set a key definition can carry, and the xterm modifier-code arithmetic.
public struct RemoteTerminalKeyModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int

    private enum CodingKeys: String, CodingKey {
        case rawValue
    }

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let shift = RemoteTerminalKeyModifiers(rawValue: 1 << 0)
    public static let alt = RemoteTerminalKeyModifiers(rawValue: 1 << 1)
    public static let control = RemoteTerminalKeyModifiers(rawValue: 1 << 2)

    private static let supportedRawValue = shift.rawValue | alt.rawValue | control.rawValue

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try container.decode(Int.self, forKey: .rawValue)
        guard decoded & ~Self.supportedRawValue == 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .rawValue,
                in: container,
                debugDescription: "Terminal key modifiers contain unsupported bits."
            )
        }
        self.init(rawValue: decoded)
    }

    public func encode(to encoder: Encoder) throws {
        guard rawValue & ~Self.supportedRawValue == 0 else {
            throw EncodingError.invalidValue(self, .init(
                codingPath: encoder.codingPath,
                debugDescription: "Terminal key modifiers contain unsupported bits."
            ))
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rawValue, forKey: .rawValue)
    }

    /// The `;N` parameter xterm's modified-key CSI sequences carry: 1 plus shift(1),
    /// alt(2), control(4). `nil` when no modifier is held, because an unmodified key uses
    /// the short sequence form rather than `;1`.
    var xtermParameter: Int? {
        guard !isEmpty else { return nil }
        var value = 1
        if contains(.shift) { value += 1 }
        if contains(.alt) { value += 2 }
        if contains(.control) { value += 4 }
        return value
    }
}

/// A key the encoder knows how to spell. Raw values are storage identity — renaming one
/// silently breaks every saved layout that uses it.
public enum RemoteTerminalNamedKey: String, Codable, CaseIterable, Sendable {
    case escape
    case tab
    case enter
    case backspace
    case forwardDelete
    case up, down, left, right
    case home, end
    case pageUp, pageDown
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12

    /// The label a key wears when its definition names no custom one. Word-like labels
    /// ("esc", "tab") are localization keys on the client; glyphs pass through unchanged.
    public var defaultLabel: String {
        switch self {
        case .escape: return "esc"
        case .tab: return "tab"
        case .enter: return "↩"
        case .backspace: return "⌫"
        case .forwardDelete: return "⌦"
        case .up: return "↑"
        case .down: return "↓"
        case .left: return "←"
        case .right: return "→"
        case .home: return "home"
        case .end: return "end"
        case .pageUp: return "pgup"
        case .pageDown: return "pgdn"
        case .f1, .f2, .f3, .f4, .f5, .f6,
             .f7, .f8, .f9, .f10, .f11, .f12:
            return rawValue.uppercased()
        }
    }
}

/// The two modifiers that can latch onto the *next* key — a bar key or a keystroke typed
/// on the system keyboard — instead of carrying a chord of their own.
public enum RemoteTerminalLatchingModifier: String, Codable, CaseIterable, Sendable {
    case control
    case alt

    public var defaultLabel: String {
        switch self {
        case .control: return "⌃"
        case .alt: return "⌥"
        }
    }

    var keyModifier: RemoteTerminalKeyModifiers {
        switch self {
        case .control: return .control
        case .alt: return .alt
        }
    }
}

/// Which of the terminal bar's two rows owns a key. Raw values are device-local storage
/// identity: changing one would move saved keys back to the fallback row.
public enum RemoteTerminalKeyRow: String, Codable, CaseIterable, Sendable {
    case top
    case bottom
}

/// What pressing a key does. `named` is the curated catalogue; `sequence` is the escape
/// hatch for a hand-written byte string; `snippet` types text and optionally submits it;
/// `latch` arms a modifier for whatever comes next.
public enum RemoteTerminalKeyAction: Equatable, Sendable {
    case named(RemoteTerminalNamedKey, RemoteTerminalKeyModifiers)
    case sequence(String)
    case snippet(text: String, submits: Bool)
    case latch(RemoteTerminalLatchingModifier)

    /// The label this action wears when its definition names no custom one.
    public var defaultLabel: String {
        switch self {
        case .named(let key, let modifiers):
            var prefix = ""
            if modifiers.contains(.control) { prefix += "⌃" }
            if modifiers.contains(.alt) { prefix += "⌥" }
            if modifiers.contains(.shift) { prefix += "⇧" }
            return prefix + key.defaultLabel
        case .sequence:
            return "␛"
        case .snippet(let text, _):
            return String(text.prefix(12))
        case .latch(let modifier):
            return modifier.defaultLabel
        }
    }
}

extension RemoteTerminalKeyAction: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, key, modifiers, sequence, text, submits, modifier
    }

    private enum Kind: String, Codable {
        case named, sequence, snippet, latch
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // An unknown kind throws rather than degrading to a guess: the store's archive
        // version decides forward compatibility, and a key that cannot say what it does
        // must not sit on a bar that writes to a PTY.
        switch try container.decode(Kind.self, forKey: .kind) {
        case .named:
            self = .named(
                try container.decode(RemoteTerminalNamedKey.self, forKey: .key),
                try container.decodeIfPresent(
                    RemoteTerminalKeyModifiers.self, forKey: .modifiers
                ) ?? []
            )
        case .sequence:
            self = .sequence(try container.decode(String.self, forKey: .sequence))
        case .snippet:
            self = .snippet(
                text: try container.decode(String.self, forKey: .text),
                submits: try container.decodeIfPresent(Bool.self, forKey: .submits) ?? false
            )
        case .latch:
            self = .latch(
                try container.decode(RemoteTerminalLatchingModifier.self, forKey: .modifier)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .named(let key, let modifiers):
            try container.encode(Kind.named, forKey: .kind)
            try container.encode(key, forKey: .key)
            if !modifiers.isEmpty {
                try container.encode(modifiers, forKey: .modifiers)
            }
        case .sequence(let sequence):
            try container.encode(Kind.sequence, forKey: .kind)
            try container.encode(sequence, forKey: .sequence)
        case .snippet(let text, let submits):
            try container.encode(Kind.snippet, forKey: .kind)
            try container.encode(text, forKey: .text)
            try container.encode(submits, forKey: .submits)
        case .latch(let modifier):
            try container.encode(Kind.latch, forKey: .kind)
            try container.encode(modifier, forKey: .modifier)
        }
    }
}

/// One key on the bar. `id` is what reordering and deletion address; `customLabel` is the
/// user's caption and `nil` means the action names itself.
public struct RemoteTerminalKeyDefinition: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var customLabel: String?
    public var action: RemoteTerminalKeyAction
    public var row: RemoteTerminalKeyRow

    public init(
        id: UUID = UUID(),
        customLabel: String? = nil,
        action: RemoteTerminalKeyAction,
        row: RemoteTerminalKeyRow = .bottom
    ) {
        self.id = id
        self.customLabel = customLabel
        self.action = action
        self.row = row
    }

    public var label: String {
        if let customLabel, !customLabel.isEmpty { return customLabel }
        return action.defaultLabel
    }

    private enum CodingKeys: String, CodingKey {
        case id, customLabel, action, row
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        customLabel = try container.decodeIfPresent(String.self, forKey: .customLabel)
        action = try container.decode(RemoteTerminalKeyAction.self, forKey: .action)
        // Every archive written before row placement existed described the original bottom run.
        row = try container.decodeIfPresent(RemoteTerminalKeyRow.self, forKey: .row) ?? .bottom
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(customLabel, forKey: .customLabel)
        try container.encode(action, forKey: .action)
        if row != .bottom {
            try container.encode(row, forKey: .row)
        }
    }
}

/// One ordered key catalogue. Each row preserves the relative order of the keys assigned to it.
public struct RemoteTerminalKeyboardLayout: Codable, Equatable, Sendable {
    public var keys: [RemoteTerminalKeyDefinition]

    public init(keys: [RemoteTerminalKeyDefinition]) {
        self.keys = keys
    }

    public func keys(in row: RemoteTerminalKeyRow) -> [RemoteTerminalKeyDefinition] {
        keys.filter { $0.row == row }
    }

    /// The stock bar for one agent kind, keyed by the `agentKind` string the wire already
    /// carries. Every kind keeps the familiar esc/⌃C/tab/arrow run this bar shipped with,
    /// gains the two latching modifiers, and Claude Code alone leads with ⇧⇥ — the
    /// permission-mode cycle is that TUI's one key a phone keyboard cannot reach at all.
    public static func standard(forAgentKind agentKind: String) -> RemoteTerminalKeyboardLayout {
        var keys: [RemoteTerminalKeyDefinition] = [
            RemoteTerminalKeyDefinition(action: .named(.escape, []))
        ]
        if agentKind == "claude" {
            keys.append(RemoteTerminalKeyDefinition(action: .named(.tab, .shift)))
        }
        keys.append(contentsOf: [
            RemoteTerminalKeyDefinition(action: .latch(.control)),
            RemoteTerminalKeyDefinition(action: .latch(.alt)),
            RemoteTerminalKeyDefinition(action: .named(.tab, [])),
            RemoteTerminalKeyDefinition(action: .named(.up, [])),
            RemoteTerminalKeyDefinition(action: .named(.down, [])),
            RemoteTerminalKeyDefinition(action: .named(.left, [])),
            RemoteTerminalKeyDefinition(action: .named(.right, [])),
        ])
        return RemoteTerminalKeyboardLayout(keys: keys)
    }
}

/// The latch's whole behaviour, as a value: a tap cycles off → armed → locked → off, an
/// armed modifier spends itself on the next key, a locked one holds until tapped off.
public struct RemoteTerminalLatchState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case off
        case armed
        case locked
    }

    public private(set) var control: Phase = .off
    public private(set) var alt: Phase = .off

    public init() {}

    public func phase(of modifier: RemoteTerminalLatchingModifier) -> Phase {
        modifier == .control ? control : alt
    }

    public mutating func tap(_ modifier: RemoteTerminalLatchingModifier) {
        let next: (Phase) -> Phase = { phase in
            switch phase {
            case .off: return .armed
            case .armed: return .locked
            case .locked: return .off
            }
        }
        if modifier == .control {
            control = next(control)
        } else {
            alt = next(alt)
        }
    }

    /// The modifiers currently held, armed and locked alike.
    public var heldModifiers: RemoteTerminalKeyModifiers {
        var held: RemoteTerminalKeyModifiers = []
        if control != .off { held.insert(.control) }
        if alt != .off { held.insert(.alt) }
        return held
    }

    /// Spends armed modifiers after a key has used them; locked ones stay held.
    public mutating func consumeArmed() {
        if control == .armed { control = .off }
        if alt == .armed { alt = .off }
    }

    public var isIdle: Bool { control == .off && alt == .off }
}

/// Spells keys with the classic terminal keyboard contract, including DECCKM (application cursor
/// mode changes what an unmodified arrow/home/end sends) and xterm's `;N` modifier parameter.
/// Live terminal views use their emulator's negotiated encoder; this remains the portable model
/// and the fallback for clients that do not own an emulator instance.
public enum RemoteTerminalKeyEncoder {
    private static let escapeByte: UInt8 = 0x1b

    /// The bytes a key press puts on the PTY. `latched` is folded into a `named` action's
    /// own modifiers; a `latch` action produces no bytes and returns nil.
    public static func bytes(
        for action: RemoteTerminalKeyAction,
        latched: RemoteTerminalKeyModifiers = [],
        applicationCursor: Bool = false
    ) -> [UInt8]? {
        switch action {
        case .named(let key, let modifiers):
            return bytes(
                for: key,
                modifiers: modifiers.union(latched),
                applicationCursor: applicationCursor
            )
        case .sequence(let sequence):
            return Array(sequence.utf8)
        case .snippet(let text, let submits):
            return Array(text.utf8) + (submits ? [0x0d] : [])
        case .latch:
            return nil
        }
    }

    /// Applies latched modifiers to bytes the system keyboard produced. A single ASCII
    /// character becomes its control form and/or gains an ESC (meta) prefix; anything
    /// else — multi-byte input, sequences the terminal view already encoded — passes
    /// through unchanged rather than being guessed at.
    public static func applyLatched(
        _ modifiers: RemoteTerminalKeyModifiers,
        toTyped bytes: [UInt8]
    ) -> [UInt8] {
        guard !modifiers.isEmpty, bytes.count == 1, let byte = bytes.first,
              byte >= 0x20, byte < 0x7f else { return bytes }
        var result = byte
        if modifiers.contains(.control), let control = controlByte(for: byte) {
            result = control
        }
        if modifiers.contains(.alt) {
            return [escapeByte, result]
        }
        return [result]
    }

    /// The control-key form of a printable ASCII byte: letters fold to 0x01–0x1a, and the
    /// handful of punctuation control mappings xterm honours. Nil where no form exists.
    private static func controlByte(for byte: UInt8) -> UInt8? {
        switch byte {
        case 0x61...0x7a: return byte & 0x1f // a-z
        case 0x41...0x5a: return byte & 0x1f // A-Z
        case 0x20, 0x40: return 0x00 // space, @
        case 0x5b...0x5f: return byte & 0x1f // [ \ ] ^ _
        case 0x3f: return 0x7f // ? → DEL
        default: return nil
        }
    }

    private static func bytes(
        for key: RemoteTerminalNamedKey,
        modifiers: RemoteTerminalKeyModifiers,
        applicationCursor: Bool
    ) -> [UInt8] {
        switch key {
        case .escape:
            return [escapeByte]
        case .tab:
            // Shift+Tab is CSI Z (back-tab); other modifiers do not change what tab sends.
            return modifiers.contains(.shift) ? csi("Z") : [0x09]
        case .enter:
            return modifiers.contains(.alt) ? [escapeByte, 0x0d] : [0x0d]
        case .backspace:
            let base: UInt8 = modifiers.contains(.control) ? 0x08 : 0x7f
            return modifiers.contains(.alt) ? [escapeByte, base] : [base]
        case .forwardDelete:
            return tildeSequence(3, modifiers: modifiers)
        case .up:
            return cursorSequence("A", modifiers: modifiers, applicationCursor: applicationCursor)
        case .down:
            return cursorSequence("B", modifiers: modifiers, applicationCursor: applicationCursor)
        case .right:
            return cursorSequence("C", modifiers: modifiers, applicationCursor: applicationCursor)
        case .left:
            return cursorSequence("D", modifiers: modifiers, applicationCursor: applicationCursor)
        case .home:
            return cursorSequence("H", modifiers: modifiers, applicationCursor: applicationCursor)
        case .end:
            return cursorSequence("F", modifiers: modifiers, applicationCursor: applicationCursor)
        case .pageUp:
            return tildeSequence(5, modifiers: modifiers)
        case .pageDown:
            return tildeSequence(6, modifiers: modifiers)
        case .f1, .f2, .f3, .f4:
            // Unmodified F1–F4 are SS3 (ESC O P…S); with a modifier they take CSI 1;N form.
            let final = ["f1": "P", "f2": "Q", "f3": "R", "f4": "S"][key.rawValue] ?? "P"
            if let parameter = modifiers.xtermParameter {
                return csi("1;\(parameter)\(final)")
            }
            return [escapeByte, 0x4f] + Array(final.utf8)
        case .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12:
            let codes = [
                "f5": 15, "f6": 17, "f7": 18, "f8": 19,
                "f9": 20, "f10": 21, "f11": 23, "f12": 24,
            ]
            return tildeSequence(codes[key.rawValue] ?? 15, modifiers: modifiers)
        }
    }

    /// Arrows, home and end: SS3 in application cursor mode, CSI otherwise — except that a
    /// modified key always takes the CSI `1;N` form, in both modes.
    private static func cursorSequence(
        _ final: String,
        modifiers: RemoteTerminalKeyModifiers,
        applicationCursor: Bool
    ) -> [UInt8] {
        if let parameter = modifiers.xtermParameter {
            return csi("1;\(parameter)\(final)")
        }
        if applicationCursor {
            return [escapeByte, 0x4f] + Array(final.utf8)
        }
        return csi(final)
    }

    /// The `CSI code ~` family (delete, page keys, F5–F12), with the modifier parameter
    /// spliced before the tilde when one is held.
    private static func tildeSequence(_ code: Int, modifiers: RemoteTerminalKeyModifiers) -> [UInt8] {
        if let parameter = modifiers.xtermParameter {
            return csi("\(code);\(parameter)~")
        }
        return csi("\(code)~")
    }

    private static func csi(_ body: String) -> [UInt8] {
        [escapeByte, 0x5b] + Array(body.utf8)
    }
}
