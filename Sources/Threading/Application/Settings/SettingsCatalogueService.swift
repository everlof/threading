import Foundation

/// AppKit-free catalogue values admitted by the settings command boundary.
struct SettingsCataloguePage: Equatable, Sendable {
    struct Setting: Equatable, Sendable {
        let title: String
        let section: String?
    }

    let id: String
    let title: String
    let group: String
    let terms: [String]
    let settings: [Setting]
}

enum SettingsCatalogueCommandResult: Equatable, Sendable {
    case success(String)
    case failure(String)
}

/// Owns the complete `list_settings` application result and wire serialization.
///
/// UI supplies its current localized page projection. The service owns the stable payload shape,
/// ordering-preserving conversion, and JSON policy, so an MCP adapter has no catalogue state or
/// serialization policy of its own.
struct SettingsCatalogueService: Sendable {
    func list(pages: [SettingsCataloguePage]) -> SettingsCatalogueCommandResult {
        let payload = Payload(
            pages: pages.map { page in
                Payload.Page(
                    id: page.id,
                    title: page.title,
                    group: page.group,
                    terms: page.terms,
                    settings: page.settings.map {
                        Payload.Setting(title: $0.title, section: $0.section)
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

    private struct Payload: Encodable {
        struct Setting: Encodable {
            let title: String
            let section: String?
        }

        struct Page: Encodable {
            let id: String
            let title: String
            let group: String
            let terms: [String]
            let settings: [Setting]
        }

        let pages: [Page]
    }
}
