import Foundation

/// Persistent storage for app-chrome themes created by the user or an agent.
///
/// Stock themes remain Swift literals. Custom themes are value documents keyed by stable IDs,
/// so their display names can change without invalidating the selected-theme preference.
final class AppThemeStore {

    static let shared = AppThemeStore()

    private enum Keys {
        static let customThemes = "customAppThemes"
    }

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = Keys.customThemes) {
        self.defaults = defaults
        self.key = key
    }

    var themes: [AppTheme] {
        guard let data = defaults.data(forKey: key),
              let themes = try? JSONDecoder().decode([AppTheme].self, from: data) else {
            return []
        }
        return themes
    }

    func insert(_ theme: AppTheme) {
        var stored = themes
        stored.append(theme)
        save(stored)
    }

    @discardableResult
    func replace(_ theme: AppTheme) -> Bool {
        var stored = themes
        guard let index = stored.firstIndex(where: { $0.id == theme.id }) else { return false }
        stored[index] = theme
        save(stored)
        return true
    }

    @discardableResult
    func remove(id: AppThemeID) -> Bool {
        var stored = themes
        let count = stored.count
        stored.removeAll { $0.id == id }
        guard stored.count != count else { return false }
        save(stored)
        return true
    }

    private func save(_ themes: [AppTheme]) {
        guard let data = try? JSONEncoder().encode(themes) else { return }
        defaults.set(data, forKey: key)
    }
}
