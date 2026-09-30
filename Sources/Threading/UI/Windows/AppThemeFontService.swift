import AppKit

// MARK: - App Theme Font Service

/// `add_app_theme_font`: gives a custom theme a font file of its own.
///
/// The policy is here and the file work is `ThemeFontStore`'s, run on a detached task — reading a
/// file, parsing a font and writing it to Application Support are exactly the calls the
/// main-actor latency rule moves to a worker. The main actor only checks the theme is the
/// user's to change, and afterwards repaints: a newly registered family changes what every
/// recorded font role resolves to, the extension tier's reasoning for its own fonts.
@MainActor
enum AppThemeFontService {

    static func add(_ arguments: AddAppThemeFontArguments) async -> MCPToolResult {
        guard let rawID = arguments.themeID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawID.isEmpty,
              let theme = AppThemeLibrary.theme(withID: AppThemeID(rawID)) else {
            return .failure("Provide theme_id of a custom theme from list_app_themes.")
        }
        guard AppThemeLibrary.isCustom(theme) else {
            return .failure(
                "\(theme.name) is not a custom theme. Call duplicate_app_theme first and add "
                    + "the font to the copy."
            )
        }
        let source = arguments.source
        let replace = arguments.replaceExisting == true
        guard source != nil || replace else {
            return .failure("Provide source {path} or {base64}, or replace_existing: true.")
        }

        let themeID = theme.id
        let outcome: Result<ThemeFontStore.StoredFont?, Error> = await Task.detached {
            do {
                if replace { ThemeFontStore.removeAll(for: themeID) }
                guard let source else { return .success(nil) }
                let data = try fontBytes(source)
                return .success(try ThemeFontStore.store(fontData: data, for: themeID))
            } catch {
                return .failure(error)
            }
        }.value

        AppThemeRefresh.repaintEverything()
        NotificationCenter.default.post(AppThemeDidChange(themeID: AppThemeLibrary.current.id))
        NotificationCenter.default.post(AppThemeLibraryDidChange())

        switch outcome {
        case .failure(let error):
            return .failure(error.localizedDescription)
        case .success(nil):
            return .success("Removed the fonts \(theme.name) carried.")
        case .success(let stored?):
            let families = stored.families.joined(separator: ", ")
            return .success(
                "Added a font to \(theme.name): \(families). Name the family in "
                    + "update_app_theme — sidebar.title.font_family for the wordmark, or "
                    + "material.font_family / heading_style.font_family for prose."
            )
        }
    }

    /// Reads the font from a path or base64, bounded before a byte is parsed.
    nonisolated private static func fontBytes(_ source: AppThemeImageArguments) throws -> Data {
        let limit = ThemeFontStore.maximumFontBytes
        if let rawPath = source.path?.trimmingCharacters(in: .whitespacesAndNewlines), !rawPath.isEmpty {
            let path = (rawPath as NSString).expandingTildeInPath
            do {
                return try BoundedFileReader.read(URL(fileURLWithPath: path), maximumBytes: limit)
            } catch BoundedFileReadError.exceedsLimit(maximumBytes: _) {
                throw ThemeFontStore.StoreError.tooLarge(maximumBytes: limit)
            } catch {
                throw AppThemeEditingError.invalid("source: no readable file at \(path).")
            }
        }
        if let base64 = source.base64?.trimmingCharacters(in: .whitespacesAndNewlines), !base64.isEmpty {
            guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
                throw AppThemeEditingError.invalid("source: base64 did not decode.")
            }
            guard data.count <= limit else {
                throw ThemeFontStore.StoreError.tooLarge(maximumBytes: limit)
            }
            return data
        }
        throw AppThemeEditingError.invalid("source: provide {path} or {base64}.")
    }
}
