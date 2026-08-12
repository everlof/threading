import AppKit
import UniformTypeIdentifiers

/// The sound list two settings rows share.
///
/// Both pickers — the notification alert and the terminal bell — offer the same sounds in the
/// same order, and only differ in what sits *above* them (a default, or a default and an off)
/// and in what a choice means. Keeping the grouping here is what makes those two rows read as
/// one vocabulary: the suggested handful, then the rest of what macOS ships, then the user's
/// own, each group separated the way System Settings separates them.
///
/// The caller owns its leading items and its represented values, because those are the parts
/// that genuinely differ. What it does not own is the order.
enum SoundPickerMenu {

    /// The installed sounds in the order both surfaces list them: the suggested handful, then
    /// the rest of what macOS ships, then the user's own. Empty groups are already gone, so a
    /// caller draws one separator per group without checking.
    ///
    /// The order lives here rather than in either caller because a settings pop-up and a row's
    /// submenu offering the same sounds in different orders is the drift this file exists to
    /// prevent.
    static func groups() -> [[NotificationSound]] {
        let (suggested, rest) = SuggestedNotificationSounds
            .partition(NotificationSoundLibrary.available())

        return [suggested, rest.filter { !$0.isUserInstalled }, rest.filter(\.isUserInstalled)]
            .filter { !$0.isEmpty }
    }

    /// Appends every installed sound to `popUp`, grouped and separated.
    ///
    /// - Parameters:
    ///   - groups: a reading taken already, for a surface filling several pickers at once. The
    ///     Customize sheet has eleven, and every one of them lists the same folders; scanning
    ///     three directories eleven times per click would be paying for one answer eleven times.
    ///     Omitted, each call takes its own reading, which is what a lone picker wants — the
    ///     list is a folder, and a sound can arrive in it between two of them.
    ///   - representedValue: turns a file name into whatever the caller stores.
    /// - Returns: the item index of each file name, for restoring the selection afterwards.
    @discardableResult
    @MainActor
    static func addSounds(
        to popUp: ThemedPopUp,
        groups: [[NotificationSound]]? = nil,
        representedValue: (String) -> Any
    ) -> [String: Int] {
        var indexOfSound: [String: Int] = [:]

        for group in groups ?? self.groups() {
            popUp.addSeparator()
            for sound in group {
                indexOfSound[sound.fileName] = popUp.numberOfItems
                popUp.addItem(
                    ThemedMenuItem(
                        title: sound.displayName,
                        representedValue: representedValue(sound.fileName)
                    )
                )
            }
        }

        return indexOfSound
    }

    /// The same list as menu entries, for the surfaces that build a submenu rather than fill a
    /// pop-up — the sidebar rows' Sounds submenu.
    ///
    /// - Parameter item: turns one sound into the row that chooses it, so the caller keeps its
    ///   own check state, represented value and action.
    @MainActor
    static func soundEntries(item: (NotificationSound) -> ThemedMenuItem) -> [ThemedMenuEntry] {
        groups().flatMap { group in
            [ThemedMenuEntry.separator] + group.map { .item(item($0)) }
        }
    }

    /// The way in for a sound of the user's own, always last and always after a separator.
    @MainActor
    static func addCustomSoundItem(to popUp: ThemedPopUp, onChoose: @escaping () -> Void) {
        popUp.addSeparator()
        popUp.addItem(customSoundItem(onChoose: onChoose))
    }

    /// The same row, for a submenu. One definition so both surfaces say the same words.
    @MainActor
    static func customSoundItem(onChoose: @escaping () -> Void) -> ThemedMenuItem {
        ThemedMenuItem(title: L10n.string("Add a Sound…"), onChoose: onChoose)
    }

    /// Runs the Add a Sound panel and hands back the installed sound.
    ///
    /// Shared for the same reason the list is: two rows offering "Add a Sound…" must accept the
    /// same formats, say the same thing, and put the file in the same place. Failure is
    /// reported here too — a copy that did not happen has to say so, rather than leaving the
    /// row looking as though it did.
    @MainActor
    static func addCustomSound(completion: @escaping (NotificationSound?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = SoundPickerDefaults.contentTypes
        // Says nothing about *which* sound, because both pickers open this panel and the row
        // the user came from already said.
        panel.message = L10n.string("Choose a sound. Anything past 30 seconds is cut short.")
        panel.prompt = L10n.string("Add")

        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                completion(nil)
                return
            }
            do {
                completion(try CustomNotificationSound.install(url))
            } catch {
                ThemedAlert(error: error).runModal()
                completion(nil)
            }
        }
    }
}

// MARK: - Sound Picker Defaults

enum SoundPickerDefaults {
    /// What the Add a Sound panel will open. The extensions `NotificationSoundLibrary` accepts,
    /// expressed as the types the panel filters on: CAF has no system-declared constant, so it
    /// is looked up by extension and simply absent if the platform stops declaring it.
    static var contentTypes: [UTType] {
        var types: [UTType] = [.aiff, .wav]
        if let caf = UTType(filenameExtension: "caf") { types.append(caf) }
        return types
    }
}
