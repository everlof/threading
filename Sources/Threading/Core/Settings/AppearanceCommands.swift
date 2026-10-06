import Foundation

enum AppearanceCommandTarget: Equatable {
    case theme(String)
    case terminalTheme(String)
    case extensionEnabled(String, Bool)

    var keywords: [String] {
        switch self {
        case .theme: return ["theme", "themes", L10n.string("Themes")]
        case .terminalTheme: return ["terminal theme", "terminal themes", L10n.string("Themes")]
        case .extensionEnabled: return ["extensions", L10n.string("Extensions")]
        }
    }

    /// The activation-service change this command requests; a terminal theme goes through the
    /// existing scoped assignment instead, after its scope has been chosen.
    var action: AppearanceActivationAction? {
        switch self {
        case .theme(let id): return .selectTheme(id)
        case .extensionEnabled(let id, let enabled): return .setExtensionEnabled(id, enabled)
        case .terminalTheme: return nil
        }
    }

    var commandID: String {
        switch self {
        case .theme(let id): return "appearance.theme.use." + Self.component(id)
        case .terminalTheme(let id): return "appearance.terminal-theme.use." + Self.component(id)
        case .extensionEnabled(let id, let enabled):
            return "appearance.extension." + (enabled ? "enable." : "disable.") + Self.component(id)
        }
    }

    /// UTF-8 hex has no separators or locale-sensitive escaping and cannot collide on names.
    private static func component(_ value: String) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var encoded: [UInt8] = []
        encoded.reserveCapacity(value.utf8.count * 2)
        for byte in value.utf8 {
            encoded.append(digits[Int(byte >> 4)])
            encoded.append(digits[Int(byte & 15)])
        }
        return String(decoding: encoded, as: UTF8.self)
    }
}

@MainActor
enum AppearanceCommands {
    static func refresh(host: AppearanceActivationHost) {
        CommandRegistry.shared.replaceAppearanceCommands(catalog(host: host))
    }

    static func catalog(host: AppearanceActivationHost, themes: [AppTheme] = AppThemeLibrary.all) -> [AppCommand] {
        let snapshot = host.inventory()
        let state = host.state
        let enabledExtensionIDs = state?.enabledExtensionIDs ?? []
        let selectedThemeID = state?.themeID
        let stockIDs = Set(AppThemeLibrary.stock.map(\.id))
        let contributors = Dictionary(ExtensionAppearanceRegistry.shared.contributions.flatMap { contribution in
            contribution.themes.map { ($0.id, contribution.extensionName) }
        }, uniquingKeysWith: { first, _ in first })
        var commands = themes.map { theme in
            let origin = contributors[theme.id]
                ?? (stockIDs.contains(theme.id) ? L10n.string("Built-in") : L10n.string("Custom"))
            let active = theme.id.rawValue == selectedThemeID
            return command(
                .theme(theme.id.rawValue),
                title: L10n.format("Use %@ Theme", theme.name),
                detail: active ? L10n.format("Current theme · %@", origin) : origin
            )
        }
        commands += ThemeAssignments.selectableThemes.map { theme in
            command(.terminalTheme(theme.id.rawValue), title: L10n.format("Use %@ Terminal Theme…", theme.name),
                    detail: L10n.string("Choose the default, a project, a session or a terminal."))
        }
        for (id, installed) in snapshot.extensions.sorted(by: { $0.value.name < $1.value.name }) {
            let detail = enabledExtensionIDs.contains(id) ? L10n.string("Enabled") : L10n.string("Disabled")
            commands.append(command(.extensionEnabled(id, false),
                                    title: L10n.format("Disable %@ Extension", installed.name), detail: detail))
            commands.append(command(.extensionEnabled(id, true),
                                    title: L10n.format("Enable %@ Extension", installed.name), detail: detail))
        }
        return commands
    }

    static func command(_ target: AppearanceCommandTarget, title: String, detail: String?) -> AppCommand {
        AppCommand(id: target.commandID, group: .appearance, title: title, detail: detail,
                   defaultShortcut: nil, isEditable: true, origin: .appearance,
                   iconName: "paintpalette", appearanceTarget: target)
    }

    static func unavailableReason(_ target: AppearanceCommandTarget, host: AppearanceActivationHost) -> String? {
        if case .terminalTheme(let id) = target {
            return ThemeAssignments.selectableTheme(withID: TerminalThemeID(rawValue: id)) == nil
                ? AppearanceActivationError.themeUnavailable.localizedDescription : nil
        }
        return target.action.flatMap { host.unavailableReason(for: $0) }
    }
}
