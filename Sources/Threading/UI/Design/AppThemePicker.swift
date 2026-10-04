import AppKit

/// Shared value population for app-theme pickers. Packs are explicit saved recipes; a theme
/// never acquires extension membership by sharing a name or ID with one.
@MainActor
enum AppThemePicker {
    /// What each picker named when it was last populated, so a refused pack activation can put
    /// the selection back. Weak keys: a picker that goes away takes its entry with it.
    private static let populatedSelections = NSMapTable<ThemedPopUp, NSString>.weakToStrongObjects()

    static func populate(_ popUp: ThemedPopUp, selectedThemeID: AppThemeID,
                         host: AppearanceActivationHost = .shared) {
        popUp.removeAllItems()
        populatedSelections.setObject(selectedThemeID.rawValue as NSString, forKey: popUp)
        let packs = host.state?.packs ?? []
        // A saved pack for the theme already selected is offered once, under that theme's own
        // head at the end; the general group above lists only the others.
        let offers = host.state?.activePackID == nil
            ? packs.filter { $0.themeID == selectedThemeID.rawValue }
            : []
        let others = packs.filter { pack in !offers.contains { $0.id == pack.id } }
        if !others.isEmpty {
            popUp.addHeader(L10n.string("Appearance packs"))
            for pack in others {
                popUp.addItem(packItem(title: pack.name, pack: pack, host: host))
            }
        }
        for section in AppThemeLibrary.sections {
            if let title = section.title { popUp.addHeader(title) }
            for theme in section.themes {
                popUp.addItem(ThemedMenuItem(title: theme.name, representedValue: theme.id.rawValue))
            }
        }
        if !offers.isEmpty {
            let themeName = AppThemeLibrary.theme(withID: selectedThemeID)?.name ?? selectedThemeID.rawValue
            popUp.addHeader(L10n.format("Packs for “%@”", themeName))
            for pack in offers {
                popUp.addItem(packItem(title: L10n.format("Use with “%@” pack", pack.name), pack: pack, host: host))
            }
        }
        let selectedIndex = popUp.indexOfItem { item in
            if let packID = host.state?.activePackID { return item.representedValue as? UUID == packID }
            return item.representedValue as? String == selectedThemeID.rawValue
        }
        popUp.selectItem(at: selectedIndex ?? popUp.indexOfFirstItem ?? -1)
    }

    /// Returns true for a pack row, including a refused activation. Theme rows stay on their
    /// existing selection path, which releases any active pack through ThemeSwitch. A refusal
    /// puts the picker back on what it named before, rather than on a pack that is not active.
    static func activatePackIfSelected(_ popUp: ThemedPopUp,
                                      host: AppearanceActivationHost = .shared) -> Bool {
        guard let id = popUp.selectedItem?.representedValue as? UUID else { return false }
        if let reason = host.submit(.activatePack(id)) {
            if let previous = populatedSelections.object(forKey: popUp) {
                populate(popUp, selectedThemeID: AppThemeID(previous as String), host: host)
            }
            host.presentFailure(reason)
        }
        return true
    }

    private static func packItem(title: String, pack: AppearancePack,
                                 host: AppearanceActivationHost) -> ThemedMenuItem {
        var item = ThemedMenuItem(title: title, representedValue: pack.id)
        item.help = host.unavailableReason(for: .activatePack(pack.id))
        item.isEnabled = item.help == nil
        return item
    }
}
