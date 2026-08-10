import Foundation

/// Persistent storage for app-chrome themes created by the user or an agent.
///
/// Stock themes remain Swift literals. Custom themes are value documents keyed by stable IDs,
/// so their display names can change without invalidating the selected-theme preference.
@MainActor
final class AppThemeStore {

    static let shared = AppThemeStore()

    private enum Keys {
        static let customThemes = "customAppThemes"
    }

    private let persistence: RecoverableDefaultsStore<[AppTheme]>
    private var storedThemes: [AppTheme]

    /// `PreferenceStore` rather than `.standard`: a custom theme is something the user made, and
    /// the hosted tests share the app's preferences. One probe palette per suite run used to
    /// survive in the real list.
    init(defaults: UserDefaults = PreferenceStore.shared, key: String = Keys.customThemes) {
        let persistence = RecoverableDefaultsStore<[AppTheme]>(
            defaults: defaults,
            key: key,
            criticality: .userAuthored,
            sizePolicy: .compactMetadata
        )
        self.persistence = persistence
        self.storedThemes = persistence.load(defaultValue: []).value
    }

    var themes: [AppTheme] {
        storedThemes
    }

    @discardableResult
    func insert(_ theme: AppTheme) -> Bool {
        var stored = storedThemes
        stored.append(theme)
        return commit(stored)
    }

    @discardableResult
    func replace(_ theme: AppTheme) -> Bool {
        var stored = storedThemes
        guard let index = stored.firstIndex(where: { $0.id == theme.id }) else { return false }
        stored[index] = theme
        return commit(stored)
    }

    @discardableResult
    func remove(id: AppThemeID) -> Bool {
        var stored = storedThemes
        let count = stored.count
        stored.removeAll { $0.id == id }
        guard stored.count != count else { return false }
        return commit(stored)
    }

    @discardableResult
    private func commit(_ themes: [AppTheme]) -> Bool {
        guard persistence.save(themes) else { return false }
        storedThemes = themes
        return true
    }
}
