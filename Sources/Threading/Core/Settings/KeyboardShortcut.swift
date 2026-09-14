import AppKit

// MARK: - Keyboard Shortcut

/// One key equivalent: the character a menu item matches on, and the modifiers held with it.
///
/// A value type rather than the pair of `NSMenuItem` properties it ends up in, because a
/// shortcut has to be compared (two commands must not claim one chord), stored (an override
/// outlives the launch that set it) and drawn (`⇧⌘R`) — none of which a menu item does.
///
/// `NSEvent.ModifierFlags` is an `OptionSet` over `UInt` and not `Codable`, so the raw value is
/// what persists. Only the device-independent bits are kept: the flags an event carries also
/// describe *which* shift key was pressed, which is not part of the shortcut.
public struct KeyboardShortcut: Codable, Equatable, Hashable, Sendable {

    /// The modifier bits that distinguish one shortcut from another. Caps Lock, numeric-pad,
    /// function-key, and device-side bits ride along on ordinary events without changing the
    /// chord the user pressed.
    static let eventModifierMask: NSEvent.ModifierFlags = [.command, .control, .option, .shift]

    /// The key equivalent character, as `NSMenuItem` wants it — lowercase for letters, since
    /// an uppercase one implies Shift and would double up with the modifier mask.
    public let key: String

    private let modifierRawValue: UInt

    public var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierRawValue)
    }

    public init(key: String, modifiers: NSEvent.ModifierFlags) {
        self.key = key
        self.modifierRawValue = modifiers
            .intersection(.deviceIndependentFlagsMask)
            .rawValue
    }

    /// Whether a key-down is this chord.
    ///
    /// Letter key equivalents are stored lowercase, while holding Shift can make AppKit report
    /// an uppercase character. Comparing case-insensitively keeps the value's matching semantics
    /// aligned with the menu item semantics it models.
    func matches(_ event: NSEvent) -> Bool {
        guard !key.isEmpty, let typed = event.charactersIgnoringModifiers,
              typed.compare(key, options: .caseInsensitive) == .orderedSame else {
            return false
        }
        return event.modifierFlags.intersection(Self.eventModifierMask)
            == modifiers.intersection(Self.eventModifierMask)
    }

    // MARK: - Display

    /// The chord as macOS writes it: modifiers in the platform's fixed order, then the key.
    ///
    /// The order is Apple's and is not alphabetical or arbitrary — ⌃⌥⇧⌘ is what every menu in
    /// the system draws, so any other order reads as a different shortcut at a glance.
    public var displayString: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + Self.keyDisplay(key)
    }

    /// A key's printed form. The named keys carry no glyph of their own, so they are spelled
    /// out — a bare space or an unprintable character would draw as nothing at all.
    public static func keyDisplay(_ key: String) -> String {
        if let named = namedKeys[key] { return named }
        return key.uppercased()
    }

    private static let namedKeys: [String: String] = [
        " ": "Space",
        "\r": "↩",
        "\t": "⇥",
        "\u{8}": "⌫",
        "\u{7F}": "⌫",
        "\u{1B}": "⎋",
        "\u{F700}": "↑",
        "\u{F701}": "↓",
        "\u{F702}": "←",
        "\u{F703}": "→"
    ]

    // MARK: - Validation

    /// Whether this is a chord a menu can actually own.
    ///
    /// A key equivalent with no modifier is refused, and that is the whole rule worth having: a
    /// bare letter would fire while the user is typing into the composer or the terminal, which
    /// is most of what this app is. Shift alone does not count — `⇧A` is just `A`.
    public var isValid: Bool {
        guard !key.isEmpty else { return false }
        return modifiers.contains(.command)
            || modifiers.contains(.control)
            || modifiers.contains(.option)
    }
}
