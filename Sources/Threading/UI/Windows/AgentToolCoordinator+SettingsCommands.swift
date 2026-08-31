import AppKit

@MainActor
extension AgentToolCoordinator {
    // MARK: Settings Directory

    /// The Settings catalogue as JSON: every page's stable id, its sidebar group, its own
    /// search vocabulary, and the settings it holds. Ids are the identity a caller should
    /// answer with; titles, groups and setting titles are presentation — though a setting's
    /// title is also how an answer names the exact row (see `SettingsRowAnchor`).
    ///
    /// Takes no session argument on purpose — the catalogue is app-wide, the same for every
    /// caller, and holds no values: which pages exist is not a secret, what is set on them
    /// stays behind the pages themselves.
    func listSettings() -> MCPToolResult {
        let pages = SettingsPages.all.map { page in
            SettingsCataloguePage(
                id: page.id,
                title: page.title,
                group: page.group,
                terms: page.displayTerms,
                settings: page.liveEntries.map {
                    SettingsCataloguePage.Setting(title: $0.title, section: $0.section)
                }
            )
        }
        switch dependencies.settingsCatalogue.list(pages: pages) {
        case .success(let text):
            return .success(text)
        case .failure(let message):
            return .failure(message)
        }
    }
}
