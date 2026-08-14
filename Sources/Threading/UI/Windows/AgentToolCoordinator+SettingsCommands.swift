import AppKit

/// What `list_settings` answers with: the catalogue, page by page.
private struct SettingsCataloguePayload: Encodable {
    struct SettingEntry: Encodable {
        let title: String
        let section: String?
    }

    struct PageEntry: Encodable {
        let id: String
        let title: String
        let group: String
        let terms: [String]
        /// The page's individual settings, so an answer can name the row itself — the app
        /// scrolls to a named setting rather than leaving the reader at the top of the page.
        let settings: [SettingEntry]
    }

    let pages: [PageEntry]
}

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
        let payload = SettingsCataloguePayload(
            pages: SettingsPages.all.map { page in
                SettingsCataloguePayload.PageEntry(
                    id: page.id,
                    title: page.title,
                    group: page.group,
                    terms: page.displayTerms,
                    settings: page.entries.map {
                        SettingsCataloguePayload.SettingEntry(
                            title: $0.title,
                            section: $0.section
                        )
                    }
                )
            }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(payload),
              let text = String(data: data, encoding: .utf8) else {
            return .failure("Could not list the settings pages.")
        }
        return .success(text)
    }
}
