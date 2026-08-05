import AppKit

/// What `list_settings` answers with: the catalogue, page by page.
private struct SettingsCataloguePayload: Encodable {
    struct PageEntry: Encodable {
        let id: String
        let title: String
        let group: String
        let terms: [String]
    }

    let pages: [PageEntry]
}

@MainActor
extension AgentToolCoordinator {
    // MARK: Settings Directory

    /// The Settings catalogue as JSON: every page's stable id, its sidebar group, and its own
    /// search vocabulary. Ids are the identity a caller should answer with; titles and groups
    /// are presentation, included so the answer can *say* where the page sits.
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
                    terms: page.displayTerms
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
