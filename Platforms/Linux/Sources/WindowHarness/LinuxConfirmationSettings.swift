import Foundation
@testable import CoreSlice

/// Linux's store for the production confirmation register. The key and raw values are the
/// same as AppSettings so a user's choice survives a later full Settings port.
enum LinuxConfirmationSettings {
    private static let key = "suppressedConfirmations"

    private static var suppressed: Set<ConfirmationPrompt> {
        get {
            Set((PreferenceStore.shared.stringArray(forKey: key) ?? [])
                .compactMap(ConfirmationPrompt.init(rawValue:)))
        }
        set {
            PreferenceStore.shared.set(newValue.map(\.rawValue).sorted(), forKey: key)
        }
    }

    static func asks(before prompt: ConfirmationPrompt) -> Bool {
        guard prompt.suppression != nil else { return true }
        return !suppressed.contains(prompt)
    }

    static func setAsks(_ asks: Bool, before prompt: ConfirmationPrompt) {
        guard prompt.suppression != nil else {
            assertionFailure("\(prompt.rawValue) always asks")
            return
        }
        var values = suppressed
        if asks { values.remove(prompt) }
        else { values.insert(prompt) }
        suppressed = values
    }
}
