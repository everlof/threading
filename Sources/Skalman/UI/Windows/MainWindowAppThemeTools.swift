import AppKit

// MARK: - App Theme Tools

/// Agent-facing lifecycle for app-chrome themes.
///
/// The deliberate workflow for “change Cyberpunk” is duplicate then patch. A built-in never
/// becomes mutable, and the agent does not have to reconstruct a future version's fields from a
/// `get` response just to make one colour different.
extension AgentToolCoordinator {

    /// Three origins, not two: a contributed theme belongs to an extension — present while it
    /// is enabled, and editable only by updating the package, which the wording below states
    /// so an agent does not try `update_app_theme` on one and misread the refusal.
    static func origin(of theme: AppTheme) -> String {
        if AppThemeLibrary.isStock(theme) { return "built-in" }
        if AppThemeLibrary.isContributed(theme) {
            let contributor = AppThemeLibrary.contributorName(of: theme)
                .map { " “\($0)”" } ?? ""
            return "extension\(contributor)"
        }
        return "custom"
    }

    func listAppThemes() -> MCPToolResult {
        let themes = AppThemeLibrary.all
        let lines = themes.map { theme in
            let origin = Self.origin(of: theme)
            let active = theme.id == AppThemeLibrary.current.id ? ", active" : ""
            let variants = theme.isSystem
                ? "light+dark system"
                : theme.availableVariants.map(\.rawValue).joined(separator: "+")
            return "  \(theme.id.rawValue) — \(theme.name) "
                + "(\(origin)\(active), \(theme.mode.appearanceName), variants: \(variants))"
        }
        return .success(
            "App themes (\(themes.count)):\n\(lines.joined(separator: "\n"))\n\n"
                + "Use IDs, not names. Built-ins must be duplicated before they can be updated."
        )
    }

    func getAppTheme(_ arguments: AppThemeReferenceArguments) -> MCPToolResult {
        guard let theme = appTheme(referencedBy: arguments.themeID) else {
            return missingAppTheme(arguments.themeID)
        }
        return .success(appThemeDocument(theme))
    }

    func setAppTheme(_ arguments: SetAppThemeArguments) -> MCPToolResult {
        guard let theme = appTheme(referencedBy: arguments.themeID) else {
            return missingAppTheme(arguments.themeID)
        }
        AppThemeLibrary.apply(theme)
        return .success("Applied \(theme.name) (\(theme.id.rawValue)) app-wide.")
    }

    func createAppTheme(_ arguments: CreateAppThemeArguments) -> MCPToolResult {
        guard let rawName = arguments.name else {
            return .failure("Provide a name for the app theme.")
        }
        let base: AppTheme
        if let baseID = arguments.baseID, !baseID.isEmpty {
            guard let found = appTheme(referencedBy: baseID) else {
                return missingAppTheme(baseID)
            }
            base = found
        } else {
            base = AppThemeLibrary.current
        }

        do {
            let patches = try appThemeVariantPatches(arguments.variants)
            let usesLegacyPatch = hasLegacyVariantPatch(
                roles: arguments.roles,
                material: arguments.material,
                terminalColors: arguments.terminalColors
            )
            guard patches.isEmpty || !usesLegacyPatch else {
                throw AppThemeEditingError.invalid(
                    "Use variants or the legacy top-level role/material fields, not both."
                )
            }
            let mode = try appThemeMode(
                arguments.appearance ?? arguments.mode,
                fallback: inferredMode(
                    base: base,
                    patchedKinds: Set(patches.keys),
                    usesLegacyPatch: usesLegacyPatch
                )
            )
            let summary = cleaned(arguments.summary)
                ?? "Custom theme based on \(base.name)."
            var kinds = Set(base.availableVariants)
            kinds.formUnion(patches.keys)
            switch mode {
            case .system:
                kinds.formUnion(AppTheme.VariantKind.allCases)
            case .light:
                kinds.insert(.light)
            case .dark:
                kinds.insert(.dark)
            }

            let legacyKind = mode == .system
                ? AppTheme.VariantKind.current(in: NSApp.effectiveAppearance)
                : AppTheme.VariantKind(mode: mode)
            var variants: [AppTheme.VariantKind: AppTheme.Variant] = [:]
            for kind in kinds {
                let patch = patches[kind]
                let receivesLegacy = usesLegacyPatch && kind == legacyKind
                variants[kind] = try patchedVariant(
                    named: rawName,
                    base: base,
                    kind: kind,
                    patch: patch,
                    legacyRoles: receivesLegacy ? arguments.roles : nil,
                    legacyMaterial: receivesLegacy ? arguments.material : nil,
                    legacyTerminalColors: receivesLegacy ? arguments.terminalColors : nil
                )
            }
            let theme = try AppThemeEditing.assemble(
                id: AppThemeLibrary.makeCustomID(),
                name: rawName,
                mode: mode,
                summary: summary,
                variants: variants
            )
            try AppThemeLibrary.create(theme)
            if arguments.apply ?? true {
                AppThemeLibrary.apply(theme)
                return .success(
                    "Created and applied \(theme.name) (\(theme.id.rawValue))."
                )
            }
            return .success(
                "Created \(theme.name) (\(theme.id.rawValue)) without applying it."
            )
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    func duplicateAppTheme(_ arguments: DuplicateAppThemeArguments) -> MCPToolResult {
        guard let source = appTheme(referencedBy: arguments.themeID) else {
            return missingAppTheme(arguments.themeID)
        }

        do {
            let name = cleaned(arguments.name) ?? AppThemeLibrary.uniqueCopyName(of: source)
            let copy = try AppThemeEditing.duplicate(
                source,
                id: AppThemeLibrary.makeCustomID(),
                name: name
            )
            try AppThemeLibrary.create(copy)
            if arguments.apply ?? false {
                AppThemeLibrary.apply(copy)
                return .success(
                    "Duplicated \(source.name) as \(copy.name) (\(copy.id.rawValue)) and applied it."
                )
            }
            return .success(
                "Duplicated \(source.name) as editable \(copy.name) (\(copy.id.rawValue))."
            )
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    func updateAppTheme(_ arguments: UpdateAppThemeArguments) -> MCPToolResult {
        guard let source = appTheme(referencedBy: arguments.themeID) else {
            return missingAppTheme(arguments.themeID)
        }
        guard AppThemeLibrary.isCustom(source) else {
            return .failure(
                "\(source.name) is built in and cannot be edited. Call duplicate_app_theme with "
                    + "theme_id=\"\(source.id.rawValue)\", then update the returned custom ID."
            )
        }

        do {
            let name = cleaned(arguments.name) ?? source.name
            let patches = try appThemeVariantPatches(arguments.variants)
            let usesLegacyPatch = hasLegacyVariantPatch(
                roles: arguments.roles,
                material: arguments.material,
                terminalColors: arguments.terminalColors
            )
            guard patches.isEmpty || !usesLegacyPatch else {
                throw AppThemeEditingError.invalid(
                    "Use variants or the legacy top-level role/material fields, not both."
                )
            }
            let mode = try appThemeMode(
                arguments.appearance ?? arguments.mode,
                fallback: source.mode
            )
            let summary: String?
            if let supplied = arguments.summary {
                summary = cleaned(supplied)
            } else {
                summary = source.summary
            }

            var variants = source.variants
            var kindsToPatch = Set(patches.keys)
            switch mode {
            case .system:
                for kind in AppTheme.VariantKind.allCases where variants[kind] == nil {
                    kindsToPatch.insert(kind)
                }
            case .light where variants[.light] == nil:
                kindsToPatch.insert(.light)
            case .dark where variants[.dark] == nil:
                kindsToPatch.insert(.dark)
            default:
                break
            }
            let legacyKind = mode == .system
                ? AppTheme.VariantKind.current(in: NSApp.effectiveAppearance)
                : AppTheme.VariantKind(mode: mode)
            if usesLegacyPatch { kindsToPatch.insert(legacyKind) }

            for kind in kindsToPatch {
                let patch = patches[kind]
                let receivesLegacy = usesLegacyPatch && kind == legacyKind
                variants[kind] = try patchedVariant(
                    named: name,
                    base: source,
                    kind: kind,
                    patch: patch,
                    legacyRoles: receivesLegacy ? arguments.roles : nil,
                    legacyMaterial: receivesLegacy ? arguments.material : nil,
                    legacyTerminalColors: receivesLegacy ? arguments.terminalColors : nil
                )
            }

            let updated = try AppThemeEditing.assemble(
                id: source.id,
                name: name,
                mode: mode,
                summary: summary,
                variants: variants
            )
            let wasActive = AppThemeLibrary.current.id == source.id
            try AppThemeLibrary.update(updated)
            if arguments.apply == true && !wasActive {
                AppThemeLibrary.apply(updated)
            }

            let state = (wasActive || arguments.apply == true)
                ? " It is active and the app repainted immediately."
                : " It remains inactive; call set_app_theme to inspect it live."
            return .success("Updated \(updated.name) (\(updated.id.rawValue)).\(state)")
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    // MARK: Parsing

    private func appTheme(referencedBy rawID: String?) -> AppTheme? {
        guard let rawID = cleaned(rawID) else { return nil }
        return AppThemeLibrary.theme(withID: AppThemeID(rawID))
    }

    private func missingAppTheme(_ rawID: String?) -> MCPToolResult {
        guard let rawID = cleaned(rawID) else {
            return .failure("Provide theme_id from list_app_themes.")
        }
        return .failure(
            "No app theme has id \"\(rawID)\". Call list_app_themes for stable IDs."
        )
    }

    private func appThemeMode(
        _ raw: String?,
        fallback: AppTheme.Mode
    ) throws -> AppTheme.Mode {
        guard let raw = cleaned(raw) else { return fallback }
        switch raw.lowercased() {
        case "adaptive", "system":
            return .system
        case "light":
            return .light
        case "dark":
            return .dark
        default:
            throw AppThemeEditingError.invalid(
                "appearance must be \"light\", \"dark\", or \"adaptive\"."
            )
        }
    }

    private func inferredMode(
        base: AppTheme,
        patchedKinds: Set<AppTheme.VariantKind>,
        usesLegacyPatch: Bool
    ) -> AppTheme.Mode {
        if usesLegacyPatch, base.mode == .system {
            return AppTheme.VariantKind.current(in: NSApp.effectiveAppearance) == .dark
                ? .dark
                : .light
        }
        if patchedKinds == [.light] { return .light }
        if patchedKinds == [.dark] { return .dark }
        return base.mode
    }

    private func appThemeVariantPatches(
        _ values: [String: AppThemeVariantArguments]?
    ) throws -> [AppTheme.VariantKind: AppThemeVariantArguments] {
        var parsed: [AppTheme.VariantKind: AppThemeVariantArguments] = [:]
        for (name, patch) in values ?? [:] {
            guard let kind = AppTheme.VariantKind(rawValue: name.lowercased()) else {
                throw AppThemeEditingError.invalid(
                    "\"\(name)\" is not a variant. Use \"light\" or \"dark\"."
                )
            }
            parsed[kind] = patch
        }
        return parsed
    }

    private func hasLegacyVariantPatch(
        roles: [String: String]?,
        material: AppThemeMaterialArguments?,
        terminalColors: [String: String]?
    ) -> Bool {
        roles != nil || material != nil || terminalColors != nil
    }

    private func patchedVariant(
        named name: String,
        base: AppTheme,
        kind: AppTheme.VariantKind,
        patch: AppThemeVariantArguments?,
        legacyRoles: [String: String]?,
        legacyMaterial: AppThemeMaterialArguments?,
        legacyTerminalColors: [String: String]?
    ) throws -> AppTheme.Variant {
        let source = base.variant(kind)
            ?? base.variant(kind == .light ? .dark : .light)
        let rolePatch = patch?.roles ?? legacyRoles
        let materialPatch = patch?.material ?? legacyMaterial
        let terminalPatch = patch?.terminalColors ?? legacyTerminalColors
        let roles = try appThemeRoles(rolePatch)
        let baseMaterial = source?.material ?? base.material
        let material = try appThemeMaterial(materialPatch, base: baseMaterial)
        let baseTerminal = source?.terminalPalette ?? base.terminalPalette
        let terminal = try appTerminalPalette(terminalPatch, base: baseTerminal)
        return AppThemeEditing.makeVariant(
            named: name,
            from: base,
            kind: kind,
            roles: roles,
            material: material,
            terminalPalette: terminal
        )
    }

    private func appThemeRoles(
        _ values: [String: String]?
    ) throws -> [AppThemeRole: NSColor] {
        var parsed: [AppThemeRole: NSColor] = [:]
        for (name, hex) in values ?? [:] {
            guard let role = AppThemeRole.named(name) else {
                throw AppThemeEditingError.invalid(
                    "\"\(name)\" is not an app-theme role. Valid roles: "
                        + AppThemeRole.allCases.map(\.wireName).joined(separator: ", ") + "."
                )
            }
            guard let color = NSColor(hex: hex) else {
                throw AppThemeEditingError.invalid(
                    "\"\(hex)\" is not a colour. Use #RRGGBB or #RRGGBBAA."
                )
            }
            parsed[role] = color
        }
        return parsed
    }

    private func appThemeMaterial(
        _ patch: AppThemeMaterialArguments?,
        base: AppTheme.Material
    ) throws -> AppTheme.Material {
        guard let patch else { return base }
        guard patch.glow == nil || patch.removeGlow != true else {
            throw AppThemeEditingError.invalid(
                "material cannot set glow and remove_glow in the same patch."
            )
        }
        guard patch.fontFamily == nil || patch.removeFontFamily != true else {
            throw AppThemeEditingError.invalid(
                "material cannot set font_family and remove_font_family in the same patch."
            )
        }

        var material = base
        if let value = patch.panelRadius { material.panelRadius = CGFloat(value) }
        if let value = patch.controlRadius { material.controlRadius = CGFloat(value) }
        if let value = patch.borderWidth { material.borderWidth = CGFloat(value) }

        if let rawTypeface = cleaned(patch.typeface) {
            // Named rather than positional, and the accepted list travels with the refusal: an
            // agent that guessed "sans-serif" from the style brief it is reading has no other
            // way to learn that this vocabulary calls it "default".
            guard let parsed = AppTheme.Material.Typeface(rawValue: rawTypeface) else {
                let accepted = AppTheme.Material.Typeface.allCases
                    .map(\.rawValue)
                    .joined(separator: ", ")
                throw AppThemeEditingError.invalid(
                    "\"\(rawTypeface)\" is not a valid typeface. Accepted: \(accepted)."
                )
            }
            material.typeface = parsed
        }

        if patch.removeFontFamily == true {
            material.fontFamily = nil
        } else if let family = cleaned(patch.fontFamily) {
            // Checked here rather than left to resolve silently, because a theme is authored on
            // one machine and read on another: an agent that names a family this machine does
            // not have should be told at the point it can still choose a different one, not have
            // its theme quietly fall back to the typeface. A theme that *arrives* naming an
            // absent family still degrades rather than failing — that is the document's rule,
            // and this is the authoring path. The live CoreText list, so a family an enabled
            // extension registered counts as installed here too.
            guard Design.Typography.availableFamilies.contains(family) else {
                throw AppThemeEditingError.invalid(
                    "\"\(family)\" is not an installed font family on this machine."
                )
            }
            material.fontFamily = family
        }
        if patch.removeGlow == true {
            material.glow = nil
        } else if let glow = patch.glow {
            let role: AppThemeRole
            if let rawRole = cleaned(glow.role) {
                guard let parsed = AppThemeRole.named(rawRole) else {
                    throw AppThemeEditingError.invalid(
                        "\"\(rawRole)\" is not a valid glow role."
                    )
                }
                role = parsed
            } else {
                role = base.glow?.role ?? .accent
            }
            material.glow = AppTheme.Glow(
                role: role,
                radius: CGFloat(glow.radius ?? Double(base.glow?.radius ?? 6)),
                opacity: glow.opacity ?? base.glow?.opacity ?? 0.2,
                offsetX: CGFloat(glow.offsetX ?? Double(base.glow?.offsetX ?? 0)),
                offsetY: CGFloat(glow.offsetY ?? Double(base.glow?.offsetY ?? 0))
            )
        }
        return material
    }

    private func appTerminalPalette(
        _ values: [String: String]?,
        base: TerminalTheme
    ) throws -> TerminalTheme {
        var palette = base
        for (name, hex) in values ?? [:] {
            guard let key = ThemeColorKey.named(name) else {
                throw AppThemeEditingError.invalid(
                    "\"\(name)\" is not a terminal colour. Valid names: "
                        + ThemeColorKey.allCases.map(\.wireName).joined(separator: ", ") + "."
                )
            }
            guard let color = NSColor(hex: hex) else {
                throw AppThemeEditingError.invalid(
                    "\"\(hex)\" is not a colour. Use #RRGGBB or #RRGGBBAA."
                )
            }
            palette[key] = color
        }
        return palette
    }

    private func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    // MARK: Document

    private func appThemeDocument(_ theme: AppTheme) -> String {
        let kinds = theme.isSystem ? AppTheme.VariantKind.allCases : theme.availableVariants
        var variants: [String: Any] = [:]
        for kind in kinds {
            variants[kind.rawValue] = appThemeVariantDocument(
                theme: theme,
                kind: kind,
                variant: theme.variant(kind)
            )
        }

        var document: [String: Any] = [
            "id": theme.id.rawValue,
            "name": theme.name,
            "origin": Self.origin(of: theme),
            "active": theme.id == AppThemeLibrary.current.id,
            "appearance": theme.mode.appearanceName,
            "available_variants": kinds.map(\.rawValue),
            "variants": variants
        ]
        if let summary = theme.summary { document["summary"] = summary }

        guard JSONSerialization.isValidJSONObject(document),
              let data = try? JSONSerialization.data(
                withJSONObject: document,
                options: [.prettyPrinted, .sortedKeys]
              ),
              let json = String(data: data, encoding: .utf8) else {
            return "Could not encode \(theme.name)."
        }
        return json
    }

    private func appThemeVariantDocument(
        theme: AppTheme,
        kind: AppTheme.VariantKind,
        variant: AppTheme.Variant?
    ) -> [String: Any] {
        let appearance = kind.appearance ?? NSAppearance.currentDrawing()
        var resolved: [String: String] = [:]
        appearance.performAsCurrentDrawingAppearance {
            for role in AppThemeRole.allCases {
                resolved[role.wireName] = theme.resolved(role, appearance: appearance).hexString
            }
        }
        let explicit = Dictionary(uniqueKeysWithValues: (variant?.roles ?? [:]).map {
            ($0.key.wireName, $0.value.hexString)
        })
        let material = variant?.material ?? .system
        let terminal = variant?.terminalPalette ?? theme.terminalPalette
        return [
            // `roles`, `material`, and `terminal_colors` can be copied directly into the
            // corresponding create/update variant patch. `resolved_roles` is inspection-only.
            "roles": explicit,
            "resolved_roles": resolved,
            "material": appThemeMaterialDocument(material),
            "terminal_palette_id": terminal.id.rawValue,
            "terminal_colors": terminalColorDocument(terminal)
        ]
    }

    private func appThemeMaterialDocument(_ material: AppTheme.Material) -> [String: Any] {
        var document: [String: Any] = [
            "panel_radius": Double(material.panelRadius),
            "control_radius": Double(material.controlRadius),
            "border_width": Double(material.borderWidth),
            "typeface": material.typeface.rawValue
        ]
        if let family = material.fontFamily { document["font_family"] = family }
        if let glow = material.glow {
            document["glow"] = [
                "role": glow.role.wireName,
                "radius": Double(glow.radius),
                "opacity": glow.opacity,
                "offset_x": Double(glow.offsetX),
                "offset_y": Double(glow.offsetY)
            ]
        }
        return document
    }

    private func terminalColorDocument(_ theme: TerminalTheme) -> [String: String] {
        Dictionary(uniqueKeysWithValues: ThemeColorKey.allCases.map {
            ($0.wireName, theme[$0].hexString)
        })
    }
}
