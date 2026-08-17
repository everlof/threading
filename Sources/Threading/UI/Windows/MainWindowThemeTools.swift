import AppKit

// MARK: - Theme Tools

/// The theme tools an agent can call against the app it is running inside.
///
/// Every one of them answers for the *calling* session, which is what makes them useful: the
/// tool call already arrives attributed — the URL is the identity — so "set the theme" needs no
/// argument saying which terminal, and the terminal that asked is the one that changes.
extension AgentToolCoordinator {

    // MARK: List

    func listThemes(for sessionID: SessionID) -> MCPToolResult {
        let themes = ThemeAssignments.selectableThemes
        guard !themes.isEmpty else { return .failure("No themes are installed.") }

        let listing = themes.map { theme -> String in
            let origin: String
            if theme.id == .followsAppTheme {
                origin = "dynamic, follows app chrome"
            } else {
                origin = ThemeManager.shared.isBuiltIn(theme) ? "built-in" : "custom"
            }
            return "  \(theme.id.rawValue) — \(theme.name) (\(origin)) — background"
                + " \(theme.background.hexString),"
                + " text \(theme.foreground.hexString)"
        }

        return .success(
            "Themes (\(themes.count)):\n" + listing.joined(separator: "\n")
                + "\n\n" + currentThemeDescription(for: sessionID)
        )
    }

    // MARK: Set

    func setTheme(_ arguments: SetThemeArguments, for sessionID: SessionID) -> MCPToolResult {
        guard let scope = resolveScope(arguments.scope) else {
            return .failure(Self.scopeError(arguments.scope ?? ""))
        }

        let rawID = arguments.themeID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let legacyName = arguments.theme?.trimmingCharacters(in: .whitespacesAndNewlines)

        let theme: TerminalTheme?
        if let rawID, !rawID.isEmpty {
            theme = ThemeAssignments.selectableTheme(withID: TerminalThemeID(rawID))
        } else if let legacyName, !legacyName.isEmpty {
            theme = ThemeAssignments.selectableTheme(named: legacyName)
        } else {
            return clearTheme(scope: scope, for: sessionID)
        }

        guard let theme else {
            let reference = rawID.flatMap { $0.isEmpty ? nil : $0 }
                ?? legacyName.flatMap { $0.isEmpty ? nil : $0 }
                ?? ""
            return .failure(
                "No terminal theme matching \"\(reference)\". Available IDs: "
                    + ThemeAssignments.selectableThemes.map(\.id.rawValue).joined(separator: ", ")
                    + "."
            )
        }

        return apply(theme, scope: scope, for: sessionID)
    }

    /// Applies a theme at one scope and reports what the session actually draws with now —
    /// which is not always the theme just set. A project-wide change is invisible in a session
    /// that named its own, and saying so is the difference between a tool that worked and a
    /// tool the agent believes worked.
    private func apply(
        _ theme: TerminalTheme,
        scope: ThemeScope,
        for sessionID: SessionID
    ) -> MCPToolResult {
        switch scope {
        case .session:
            ThemeAssignments.setTheme(id: theme.id, forSession: sessionID)
        case .project:
            guard let project = ProjectStore.shared.project(forSessionID: sessionID) else {
                return .failure("This session belongs to no project.")
            }
            ThemeAssignments.setTheme(id: theme.id, forProject: project.id)
        case .global:
            ThemeAssignments.setDefaultTheme(theme)
        }

        var message = "Set \(theme.name) (\(theme.id.rawValue)) as the"
            + " \(scopeDescription(scope, for: sessionID)) theme."

        if let effective = ThemeAssignments.resolution(for: sessionID),
           effective.themeID != theme.id {
            message += " This session still draws with"
                + " \(ThemeAssignments.displayName(for: effective.themeID)), which is set on"
                + " its \(effective.scope.rawValue) — clear that to let it through."
        } else {
            message = join(message, surfaceNote(for: sessionID))
        }

        return .success(message)
    }

    private func clearTheme(scope: ThemeScope, for sessionID: SessionID) -> MCPToolResult {
        switch scope {
        case .session:
            ThemeAssignments.setTheme(id: nil, forSession: sessionID)
        case .project:
            guard let project = ProjectStore.shared.project(forSessionID: sessionID) else {
                return .failure("This session belongs to no project.")
            }
            ThemeAssignments.setTheme(id: nil, forProject: project.id)
        case .global:
            return .failure(
                "The default theme cannot be cleared — there is nothing above it to inherit"
                    + " from. Set it to another theme instead."
            )
        }

        return .success(
            join(
                "Cleared the \(scopeDescription(scope, for: sessionID)) theme.",
                currentThemeDescription(for: sessionID)
            )
        )
    }

    // MARK: Create

    func createTheme(_ arguments: CreateThemeArguments, for sessionID: SessionID) -> MCPToolResult {
        // Every argument is checked before anything is stored, so a call that fails leaves no
        // half-made theme behind for the retry to collide with.
        guard let target = applyScope(arguments.apply) else {
            return .failure(Self.scopeError(arguments.apply ?? "", allowsNone: true))
        }

        guard let name = arguments.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            return .failure("Provide a name for the theme.")
        }

        guard ThemeManager.shared.theme(named: name) == nil,
              !ThemeManager.shared.isReserved(name) else {
            return .failure(
                "A theme named \"\(name)\" already exists, and an existing theme is never"
                    + " overwritten. Choose another name."
            )
        }

        guard let colors = arguments.colors, !colors.isEmpty else {
            return .failure("Provide at least one colour in `colors`.")
        }

        // The base is what unspecified colours keep, so it defaults to what the user is
        // already looking at — which is what makes "warmer background" a one-colour call.
        let rawBaseID = arguments.baseID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let legacyBaseName = arguments.base?.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: TerminalTheme
        if let rawBaseID, !rawBaseID.isEmpty {
            guard let found = ThemeAssignments.selectableTheme(withID: TerminalThemeID(rawBaseID)) else {
                return .failure("No terminal theme with id \"\(rawBaseID)\" to use as a base.")
            }
            base = found
        } else if let legacyBaseName, !legacyBaseName.isEmpty {
            guard let found = ThemeAssignments.selectableTheme(named: legacyBaseName) else {
                return .failure("No theme named \"\(legacyBaseName)\" to use as a base.")
            }
            base = found
        } else {
            base = ThemeAssignments.theme(for: sessionID)
        }

        var theme = base.duplicated(named: name).adoptingBoldForeground(from: colors)

        for (rawKey, value) in colors {
            guard let key = ThemeColorKey.named(rawKey) else {
                return .failure(
                    "\"\(rawKey)\" is not a colour in a theme. Valid names: "
                        + ThemeColorKey.allCases.map(\.wireName).joined(separator: ", ") + "."
                )
            }
            guard let color = NSColor(hex: value) else {
                return .failure("\"\(value)\" is not a hex colour. Use the form \"#1E1E2E\".")
            }
            theme[key] = color
        }

        guard ThemeContrast.isLegible(
            foreground: theme.foreground,
            background: theme.background
        ) else {
            let ratio = String(
                format: "%.1f",
                ThemeContrast.ratio(theme.foreground, theme.background)
            )
            return .failure(
                "Text at \(theme.foreground.hexString) on \(theme.background.hexString) has a"
                    + " contrast ratio of \(ratio):1, below the \(Int(ThemeContrast.minimumRatio)):1"
                    + " this app requires — the terminal would be unreadable, and it is where the"
                    + " user would have to type to undo it. Move them further apart."
            )
        }

        // Bold text is text. It is checked separately rather than folded into the line above
        // because a caller that states only `bold_foreground` never touches `foreground`, and
        // would otherwise get an unreadable heading past a gate that passed on the body.
        guard ThemeContrast.isLegible(
            foreground: theme.boldForeground,
            background: theme.background
        ) else {
            let ratio = String(
                format: "%.1f",
                ThemeContrast.ratio(theme.boldForeground, theme.background)
            )
            return .failure(
                "bold_foreground at \(theme.boldForeground.hexString) on"
                    + " \(theme.background.hexString) has a contrast ratio of \(ratio):1, below"
                    + " the \(Int(ThemeContrast.minimumRatio)):1 this app requires — headings"
                    + " would be unreadable. Move them further apart."
            )
        }

        guard ThemeAssignments.create(theme) else {
            return .failure("Could not create \"\(name)\".")
        }

        guard let scope = target else {
            return .success(
                "Created \(name) (\(theme.id.rawValue)). It is not in use — apply it with set_theme."
            )
        }

        return .success(
            join(
                "Created \(name) (\(theme.id.rawValue)).",
                apply(theme, scope: scope, for: sessionID).text
            )
        )
    }

    // MARK: - Scopes

    private func resolveScope(_ raw: String?) -> ThemeScope? {
        guard let raw, !raw.isEmpty else { return .session }
        return ThemeScope(rawValue: raw.lowercased())
    }

    /// The same, plus "none" — which is a valid answer to *where to apply this*, and not a
    /// scope. The double optional distinguishes "not understood" from "understood as nowhere".
    private func applyScope(_ raw: String?) -> ThemeScope?? {
        guard let raw, !raw.isEmpty else { return .some(.session) }
        if raw.lowercased() == "none" { return .some(nil) }
        guard let scope = ThemeScope(rawValue: raw.lowercased()) else { return nil }
        return .some(scope)
    }

    private static func scopeError(_ raw: String, allowsNone: Bool = false) -> String {
        let values = ThemeScope.allCases.map(\.rawValue) + (allowsNone ? ["none"] : [])
        return "\"\(raw)\" is not a scope. Use one of: \(values.joined(separator: ", "))."
    }

    private func scopeDescription(_ scope: ThemeScope, for sessionID: SessionID) -> String {
        switch scope {
        case .session:
            return "session"
        case .project:
            let name = ProjectStore.shared.project(forSessionID: sessionID)?.name
            return name.map { "project (\($0))" } ?? "project"
        case .global:
            return "app-wide default"
        }
    }

    // MARK: - Description

    /// Joins sentences, dropping the ones that had nothing to say — `surfaceNote` is empty for
    /// an ordinary terminal, which is most of them.
    private func join(_ sentences: String...) -> String {
        sentences.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func currentThemeDescription(for sessionID: SessionID) -> String {
        guard let resolved = ThemeAssignments.resolution(for: sessionID) else {
            return "This session draws with \(ThemeAssignments.defaultTheme.name)."
        }

        let source: String
        switch resolved.scope {
        case .session: source = "set on this session"
        case .project: source = "inherited from this project"
        case .global: source = "the app-wide default"
        }

        return join(
            "This session draws with \(ThemeAssignments.displayName(for: resolved.themeID))"
                + " (\(resolved.themeID.rawValue), \(source)).",
            surfaceNote(for: sessionID)
        )
    }

    /// A natively-rendered session is drawn in system colours by design, so a theme reaches
    /// only the backdrop behind it. Saying so is the honest answer to a tool that otherwise
    /// reports success while nothing visible changes.
    private func surfaceNote(for sessionID: SessionID) -> String {
        guard ProjectStore.shared.session(withID: sessionID)?.usesNativeUI == true else { return "" }
        return "Note: this session is shown as a conversation rather than a terminal, so the"
            + " theme sets only the backdrop behind it until it is shown as a terminal again."
    }
}
