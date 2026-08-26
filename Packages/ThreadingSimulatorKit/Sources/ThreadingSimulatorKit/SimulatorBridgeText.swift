/// The deliberately small keyboard vocabulary accepted by the helper protocol.
///
/// CoreSimulator receives USB HID usages rather than arbitrary Unicode input. Keeping this
/// vocabulary in the shared protocol package lets the app reject unsupported text before it asks
/// for control consent, while the helper remains the final authority at the process boundary.
public enum SimulatorBridgeText {
    public static let maximumCharacterCount = 1_024

    public static func isSupported(_ text: String) -> Bool {
        text.count <= maximumCharacterCount && text.allSatisfy(isSupported)
    }

    public static func isSupported(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first,
              scalar.isASCII else { return false }
        switch scalar.value {
        case 8, 9, 10, 32, 48...57, 65...90, 97...122:
            return true
        default:
            return punctuation.contains(character)
        }
    }

    private static let punctuation = Set("-_=+[]{}\\|;:'\"`~,<>./?!@#$%^&*()")
}
