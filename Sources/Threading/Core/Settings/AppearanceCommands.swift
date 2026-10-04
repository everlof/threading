import Foundation

enum AppearanceCommandTarget: Equatable {
    case theme(String)
    case terminalTheme(String)
    case activate(UUID)
    case deactivate(UUID)
    case toggle(UUID)
    case retry(UUID)
    case edit(UUID?)
    case remove(UUID)
    case extensionEnabled(String, Bool)

    var keywords: [String] {
        switch self {
        case .theme: return ["theme", "themes", L10n.string("Themes")]
        case .terminalTheme: return ["terminal theme", "terminal themes", L10n.string("Themes")]
        case .extensionEnabled: return ["extensions", L10n.string("Extensions")]
        default: return ["pack", "packs", L10n.string("Appearance packs")]
        }
    }

    var action: AppearanceActivationAction? {
        switch self {
        case .theme(let id): return .selectTheme(id)
        case .activate(let id): return .activatePack(id)
        case .deactivate(let id): return .deactivatePack(id)
        case .remove(let id): return .removePack(id)
        case .extensionEnabled(let id, let enabled): return .setExtensionEnabled(id, enabled)
        case .toggle, .retry, .edit, .terminalTheme: return nil
        }
    }

    var commandID: String {
        switch self {
        case .theme(let id): return "appearance.theme.use." + Self.component(id)
        case .terminalTheme(let id): return "appearance.terminal-theme.use." + Self.component(id)
        case .activate(let id): return "appearance.pack.activate." + id.uuidString.lowercased()
        case .deactivate(let id): return "appearance.pack.deactivate." + id.uuidString.lowercased()
        case .toggle(let id): return "appearance.pack.toggle." + id.uuidString.lowercased()
        case .retry(let id): return "appearance.pack.retry." + id.uuidString.lowercased()
        case .edit(nil): return "appearance.pack.create"
        case .edit(let id?): return "appearance.pack.edit." + id.uuidString.lowercased()
        case .remove(let id): return "appearance.pack.remove." + id.uuidString.lowercased()
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
        let desiredExtensionIDs = state?.desiredExtensionIDs ?? []
        let selectedThemeID = state?.selectedThemeID
        let activePack = state?.activePack
        let stockIDs = Set(AppThemeLibrary.stock.map(\.id))
        let contributors = Dictionary(ExtensionAppearanceRegistry.shared.contributions.flatMap { contribution in
            contribution.themes.map { ($0.id, contribution.extensionName) }
        }, uniquingKeysWith: { first, _ in first })
        var commands = themes.map { theme in
            let origin = contributors[theme.id]
                ?? (stockIDs.contains(theme.id) ? L10n.string("Built-in") : L10n.string("Custom"))
            let active = activePack == nil && theme.id.rawValue == selectedThemeID
            return command(
                .theme(theme.id.rawValue),
                title: L10n.format("Use %@ Theme", theme.name),
                detail: active ? L10n.format("Current theme · %@", origin) : origin
            )
        }
        commands.append(command(.edit(nil), title: L10n.string("Create Appearance Pack…"),
                                detail: L10n.string("Choose a theme and its companion extensions.")))
        commands += ThemeAssignments.selectableThemes.map { theme in
            command(.terminalTheme(theme.id.rawValue), title: L10n.format("Use %@ Terminal Theme…", theme.name),
                    detail: L10n.string("Choose the default, a project, a session or a terminal."))
        }
        for pack in state?.packs ?? [] {
            let detail = host.packDetail(pack, snapshot: snapshot)
            let active = pack.id == state?.activePackID
            commands.append(command(.activate(pack.id), title: L10n.format("Activate %@ Pack", pack.name), detail: detail))
            commands.append(command(.deactivate(pack.id), title: L10n.format("Deactivate %@ Pack", pack.name), detail: detail))
            commands.append(command(.toggle(pack.id), title: L10n.format("Toggle %@ Pack", pack.name), detail: detail))
            commands.append(command(.edit(pack.id), title: L10n.format("Edit %@ Pack…", pack.name), detail: detail))
            commands.append(command(.remove(pack.id), title: L10n.format("Remove %@ Pack", pack.name),
                                    detail: L10n.string("Remove the saved combination. Installed themes and extensions stay.")))
            if active, pack.extensions.contains(where: {
                if case .failed = snapshot.extensions[$0.identifier]?.status { return true }
                return false
            }) {
                commands.append(command(.retry(pack.id), title: L10n.format("Retry %@ Pack", pack.name), detail: detail))
            }
        }
        for (id, runtime) in snapshot.extensions.sorted(by: { $0.value.name < $1.value.name }) {
            let enabled = desiredExtensionIDs.contains(id)
            let manual = state?.manuallyEnabledExtensionIDs.contains(id) == true
            let pack = activePack.flatMap { $0.extensionIDs.contains(id) ? $0 : nil }
            let detail = pack.map { L10n.format("Also deactivates %@ Pack", $0.name) }
                ?? host.enablementDetail(identifier: id)
            commands.append(command(.extensionEnabled(id, false),
                                    title: L10n.format("Disable %@ Extension", runtime.name), detail: detail))
            commands.append(command(.extensionEnabled(id, true),
                                    title: enabled && !manual
                                        ? L10n.format("Keep %@ Enabled Without Pack", runtime.name)
                                        : L10n.format("Enable %@ Extension", runtime.name),
                                    detail: host.enablementDetail(identifier: id)))
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
        if let action = target.action { return host.unavailableReason(for: action) }
        if let failure = host.failure { return failure }
        if host.isChanging { return AppearanceActivationError.changeInProgress.localizedDescription }
        switch target {
        case .toggle(let id):
            return host.unavailableReason(for: host.state?.activePackID == id ? .deactivatePack(id) : .activatePack(id))
        case .edit:
            return host.inventory().extensionsSuppressed ? AppearanceActivationError.suppressed.localizedDescription : nil
        case .retry(let id):
            guard host.state?.activePackID == id, let pack = host.state?.activePack else {
                return AppearanceActivationError.packUnavailable.localizedDescription
            }
            do {
                try host.inventory().validate(pack, manualExtensionIDs: host.state?.manuallyEnabledExtensionIDs ?? [])
                return nil
            } catch { return error.localizedDescription }
        default: return nil
        }
    }
}
