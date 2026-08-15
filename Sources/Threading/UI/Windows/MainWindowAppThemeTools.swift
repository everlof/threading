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

        // Minted before the variants are built: a sidebar patch may carry image bytes, and
        // the store files them under the theme's id. A failure anywhere below removes the
        // folder again, so a refused create leaves nothing behind.
        let newID = AppThemeLibrary.makeCustomID()
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
                    themeID: newID,
                    patch: patch,
                    legacyRoles: receivesLegacy ? arguments.roles : nil,
                    legacyMaterial: receivesLegacy ? arguments.material : nil,
                    legacyTerminalColors: receivesLegacy ? arguments.terminalColors : nil
                )
            }
            let theme = try AppThemeEditing.assemble(
                id: newID,
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
            ThemeAssetStore.removeAll(for: newID)
            return .failure(error.localizedDescription)
        }
    }

    func duplicateAppTheme(_ arguments: DuplicateAppThemeArguments) -> MCPToolResult {
        guard let source = appTheme(referencedBy: arguments.themeID) else {
            return missingAppTheme(arguments.themeID)
        }

        do {
            let name = cleaned(arguments.name) ?? AppThemeLibrary.uniqueCopyName(of: source)
            let copy = try AppThemeLibrary.duplicate(source, name: name)
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

        // A sidebar image patch overwrites a slot file in place before validation can refuse
        // the document that references it, so the slots about to be replaced are snapshotted
        // first and put back on any failure — otherwise the standing document would show the
        // new image under the old everything-else.
        var replacedAssets: [(name: String, data: Data)] = []
        var introducedAssets: [String] = []
        for (rawKind, patch) in arguments.variants ?? [:] {
            guard let sidebar = patch.sidebar,
                  let kind = AppTheme.VariantKind(rawValue: rawKind.lowercased()) else { continue }
            var slots: [SidebarAssetSlot] = []
            if sidebar.image?.source != nil { slots.append(.background) }
            if case .image = sidebar.logo { slots.append(.logo) }
            for slot in slots {
                let fileName = slot.fileName(for: kind)
                if let existing = ThemeAssetStore.pngData(named: fileName, for: source.id) {
                    replacedAssets.append((fileName, existing))
                } else if ThemeAssetStore.assetExists(named: fileName, for: source.id) {
                    return .failure(
                        "The existing sidebar image could not be backed up, so no changes were made."
                    )
                } else {
                    introducedAssets.append(fileName)
                }
            }
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
                    themeID: source.id,
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
            var rollbackFailure: Error?
            for (fileName, data) in replacedAssets {
                do {
                    try ThemeAssetStore.restore(
                        pngData: data,
                        named: fileName,
                        for: source.id
                    )
                } catch {
                    rollbackFailure = rollbackFailure ?? error
                }
            }
            for fileName in introducedAssets {
                do {
                    try ThemeAssetStore.remove(assetName: fileName, for: source.id)
                } catch {
                    rollbackFailure = rollbackFailure ?? error
                }
            }
            guard let rollbackFailure else { return .failure(error.localizedDescription) }
            return .failure(
                error.localizedDescription
                    + " The sidebar image rollback also failed: "
                    + rollbackFailure.localizedDescription
            )
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
        themeID: AppThemeID,
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
        let sidebar = try appThemeSidebar(
            patch?.sidebar,
            base: source?.sidebar,
            themeID: themeID,
            kind: kind
        )
        let chrome = try appThemeChrome(patch?.chrome, base: source?.chrome)
        return AppThemeEditing.makeVariant(
            named: name,
            from: base,
            kind: kind,
            roles: roles,
            material: material,
            terminalPalette: terminal,
            sidebar: sidebar,
            chrome: chrome
        )
    }

    // MARK: Chrome Parsing

    /// Turns a chrome patch into the change `makeVariant` applies — the sidebar's idiom, for
    /// the block whose presence hands the whole window frame to the theme.
    private func appThemeChrome(
        _ patch: AppThemeChromeArguments?,
        base: WindowChromeStyle?
    ) throws -> AppThemeEditing.ChromeChange {
        guard let patch else { return .inherit }
        if patch.remove == true {
            guard patch.titleBar == nil, patch.frame == nil else {
                throw AppThemeEditingError.invalid(
                    "chrome cannot set fields and remove in the same patch."
                )
            }
            return .remove
        }

        var style: WindowChromeStyle
        if let base {
            style = base
        } else {
            guard let active = patch.titleBar?.activeGradient else {
                throw AppThemeEditingError.invalid(
                    "A theme stating chrome for the first time needs "
                        + "chrome.title_bar.active_gradient."
                )
            }
            style = WindowChromeStyle(
                titleBar: WindowChromeStyle.TitleBar(
                    activeGradient: try sidebarGradient(active)
                )
            )
        }

        if let titleBar = patch.titleBar {
            guard titleBar.inactiveGradient == nil
                || titleBar.removeInactiveGradient != true else {
                throw AppThemeEditingError.invalid(
                    "chrome cannot set inactive_gradient and remove_inactive_gradient "
                        + "in the same patch."
                )
            }
            guard titleBar.ink == nil || titleBar.removeInk != true else {
                throw AppThemeEditingError.invalid(
                    "chrome cannot set ink and remove_ink in the same patch."
                )
            }
            guard titleBar.inactiveInk == nil || titleBar.removeInactiveInk != true else {
                throw AppThemeEditingError.invalid(
                    "chrome cannot set inactive_ink and remove_inactive_ink in the same patch."
                )
            }
            guard titleBar.height == nil || titleBar.removeHeight != true else {
                throw AppThemeEditingError.invalid(
                    "chrome cannot set height and remove_height in the same patch."
                )
            }
            guard titleBar.activeTexture == nil || titleBar.removeActiveTexture != true else {
                throw AppThemeEditingError.invalid(
                    "chrome cannot set active_texture and remove_active_texture in the same patch."
                )
            }
            guard titleBar.inactiveTexture == nil
                || titleBar.removeInactiveTexture != true else {
                throw AppThemeEditingError.invalid(
                    "chrome cannot set inactive_texture and remove_inactive_texture "
                        + "in the same patch."
                )
            }
            guard titleBar.tabWidth == nil || titleBar.removeTabWidth != true else {
                throw AppThemeEditingError.invalid(
                    "chrome cannot set tab_width and remove_tab_width in the same patch."
                )
            }
            guard titleBar.visibleButtons == nil
                || titleBar.resetVisibleButtons != true else {
                throw AppThemeEditingError.invalid(
                    "chrome cannot set visible_buttons and reset_visible_buttons "
                        + "in the same patch."
                )
            }
            if let active = titleBar.activeGradient {
                style.titleBar.activeGradient = try sidebarGradient(active)
            }
            if titleBar.removeInactiveGradient == true {
                style.titleBar.inactiveGradient = nil
            } else if let inactive = titleBar.inactiveGradient {
                style.titleBar.inactiveGradient = try sidebarGradient(inactive)
            }
            if titleBar.removeInk == true {
                style.titleBar.ink = nil
            } else if let rawInk = cleaned(titleBar.ink) {
                guard let color = NSColor(hex: rawInk) else {
                    throw AppThemeEditingError.invalid(
                        "chrome.title_bar.ink must be #RRGGBB or #RRGGBBAA."
                    )
                }
                style.titleBar.ink = color
            }
            if titleBar.removeInactiveInk == true {
                style.titleBar.inactiveInk = nil
            } else if let rawInk = cleaned(titleBar.inactiveInk) {
                guard let color = NSColor(hex: rawInk) else {
                    throw AppThemeEditingError.invalid(
                        "chrome.title_bar.inactive_ink must be #RRGGBB or #RRGGBBAA."
                    )
                }
                style.titleBar.inactiveInk = color
            }
            if let rawAlignment = cleaned(titleBar.titleAlignment) {
                guard let parsed = WindowChromeStyle.TitleBar.Alignment(
                    rawValue: rawAlignment
                ) else {
                    throw AppThemeEditingError.invalid(
                        "chrome.title_bar.title_alignment must be \"leading\" or \"center\"."
                    )
                }
                style.titleBar.titleAlignment = parsed
            }
            if let rawFontStyle = cleaned(titleBar.titleFontStyle) {
                guard let parsed = WindowChromeStyle.TitleBar.TitleFontStyle(
                    rawValue: rawFontStyle
                ) else {
                    throw AppThemeEditingError.invalid(
                        "chrome.title_bar.title_font_style must be \"upright\" or \"italic\"."
                    )
                }
                style.titleBar.titleFontStyle = parsed
            }
            if titleBar.removeHeight == true {
                style.titleBar.height = nil
            } else if let height = titleBar.height {
                style.titleBar.height = height
            }
            if let rawGlyphs = cleaned(titleBar.buttonGlyphStyle) {
                guard let parsed = WindowChromeStyle.TitleBar.ButtonGlyphStyle(
                    rawValue: rawGlyphs
                ) else {
                    throw AppThemeEditingError.invalid(
                        "chrome.title_bar.button_glyph_style must be \"squares\", "
                            + "\"platinum\", \"beos\", \"openstep\", \"irix\", "
                            + "\"amiga\", \"aqua\", \"aqua_tiger\", \"classic_player\", "
                            + "\"tui\", or \"plain\"."
                    )
                }
                style.titleBar.buttonGlyphStyle = parsed
            }
            if let rawPlacement = cleaned(titleBar.buttonPlacement) {
                guard let parsed = WindowChromeStyle.TitleBar.ButtonPlacement(
                    rawValue: rawPlacement
                ) else {
                    throw AppThemeEditingError.invalid(
                        "chrome.title_bar.button_placement must be \"trailing\", \"leading\", "
                            + "\"split\", or \"bookends\"."
                    )
                }
                style.titleBar.buttonPlacement = parsed
            }
            if let showsAppIcon = titleBar.showsAppIcon {
                style.titleBar.showsAppIcon = showsAppIcon
            }
            if let rawShape = cleaned(titleBar.shape) {
                guard let parsed = WindowChromeStyle.TitleBar.Shape(rawValue: rawShape) else {
                    throw AppThemeEditingError.invalid(
                        "chrome.title_bar.shape must be \"full_width\" or \"leading_tab\"."
                    )
                }
                style.titleBar.shape = parsed
            }
            if titleBar.removeTabWidth == true {
                style.titleBar.tabWidth = nil
            } else if let tabWidth = titleBar.tabWidth {
                style.titleBar.tabWidth = tabWidth
            }
            if titleBar.resetVisibleButtons == true {
                style.titleBar.visibleButtons = WindowChromeStyle.TitleBar.ButtonRole
                    .standardOperations
            } else if let rawButtons = titleBar.visibleButtons {
                let parsed = rawButtons.compactMap { raw -> WindowChromeStyle.TitleBar.ButtonRole? in
                    guard let value = cleaned(raw) else { return nil }
                    return WindowChromeStyle.TitleBar.ButtonRole(rawValue: value)
                }
                guard parsed.count == rawButtons.count else {
                    throw AppThemeEditingError.invalid(
                        "chrome.title_bar.visible_buttons accepts only \"close\", "
                            + "\"minimize\", \"zoom\", \"depth\", and \"window_menu\"."
                    )
                }
                style.titleBar.visibleButtons = parsed
            }
            if titleBar.removeActiveTexture == true {
                style.titleBar.activeTexture = nil
            } else if let texture = titleBar.activeTexture {
                style.titleBar.activeTexture = try appThemeChromeTexture(
                    texture,
                    base: style.titleBar.activeTexture,
                    path: "chrome.title_bar.active_texture"
                )
            }
            if titleBar.removeInactiveTexture == true {
                style.titleBar.inactiveTexture = nil
            } else if let texture = titleBar.inactiveTexture {
                style.titleBar.inactiveTexture = try appThemeChromeTexture(
                    texture,
                    base: style.titleBar.inactiveTexture,
                    path: "chrome.title_bar.inactive_texture"
                )
            }
        }

        guard patch.frame == nil || patch.removeFrame != true else {
            throw AppThemeEditingError.invalid(
                "chrome cannot set frame and remove_frame in the same patch."
            )
        }
        if patch.removeFrame == true {
            style.frame = nil
        } else if let frame = patch.frame {
            let base = style.frame ?? WindowChromeStyle.Frame(
                width: WindowChromeStyleLimits.defaultFrameWidth
            )
            style.frame = WindowChromeStyle.Frame(
                width: frame.width ?? base.width,
                cornerRadius: frame.cornerRadius ?? base.cornerRadius,
                antialiasesCorners: frame.antialiasesCorners ?? base.antialiasesCorners
            )
        }

        return .set(style)
    }

    private func appThemeChromeTexture(
        _ patch: AppThemeChromeTextureArguments,
        base: WindowChromeStyle.TitleBar.Texture?,
        path: String
    ) throws -> WindowChromeStyle.TitleBar.Texture {
        guard patch.color == nil || patch.removeColor != true else {
            throw AppThemeEditingError.invalid(
                "\(path) cannot set color and remove_color in the same patch."
            )
        }
        guard patch.spacing == nil || patch.removeSpacing != true else {
            throw AppThemeEditingError.invalid(
                "\(path) cannot set spacing and remove_spacing in the same patch."
            )
        }

        let kind: WindowChromeStyle.TitleBar.Texture.Kind
        if let rawKind = cleaned(patch.kind) {
            guard let parsed = WindowChromeStyle.TitleBar.Texture.Kind(rawValue: rawKind) else {
                throw AppThemeEditingError.invalid(
                    "\(path).kind must be \"pinstripes\", \"caption_rails\", "
                        + "\"aqua_pinstripes\", \"dither\", \"brushed_metal\", or \"rule\"."
                )
            }
            kind = parsed
        } else if let base {
            kind = base.kind
        } else {
            throw AppThemeEditingError.invalid("\(path) needs a kind.")
        }

        let color: NSColor?
        if patch.removeColor == true {
            color = nil
        } else if let rawColor = cleaned(patch.color) {
            guard let parsed = NSColor(hex: rawColor) else {
                throw AppThemeEditingError.invalid(
                    "\(path).color must be #RRGGBB or #RRGGBBAA."
                )
            }
            color = parsed
        } else {
            color = base?.color
        }

        let spacing = patch.removeSpacing == true ? nil : (patch.spacing ?? base?.spacing)
        return WindowChromeStyle.TitleBar.Texture(
            kind: kind,
            color: color,
            spacing: spacing
        )
    }

    // MARK: Sidebar Parsing

    /// Turns a sidebar patch into the change `makeVariant` applies. Image bytes are stored
    /// under the theme's id as a side effect — the callers own cleanup on failure, which is
    /// why create removes the fresh folder and update restores the slots it replaced.
    private func appThemeSidebar(
        _ patch: AppThemeSidebarArguments?,
        base: SidebarStyle?,
        themeID: AppThemeID,
        kind: AppTheme.VariantKind
    ) throws -> AppThemeEditing.SidebarChange {
        guard let patch else { return .inherit }
        if patch.remove == true {
            let statesAnything = patch.gradient != nil || patch.image != nil
                || patch.logo != nil || patch.title != nil || patch.navigatorWell != nil
            guard !statesAnything else {
                throw AppThemeEditingError.invalid(
                    "sidebar cannot set fields and remove in the same patch."
                )
            }
            return .remove
        }
        guard patch.gradient == nil || patch.removeGradient != true else {
            throw AppThemeEditingError.invalid(
                "sidebar cannot set gradient and remove_gradient in the same patch."
            )
        }
        guard patch.image == nil || patch.removeImage != true else {
            throw AppThemeEditingError.invalid(
                "sidebar cannot set image and remove_image in the same patch."
            )
        }
        guard patch.title == nil || patch.removeTitle != true else {
            throw AppThemeEditingError.invalid(
                "sidebar cannot set title and remove_title in the same patch."
            )
        }
        guard patch.navigatorWell == nil || patch.removeNavigatorWell != true else {
            throw AppThemeEditingError.invalid(
                "sidebar cannot set navigator_well and remove_navigator_well in the same patch."
            )
        }

        var style = base ?? SidebarStyle()
        var background = style.background ?? SidebarStyle.Background()

        if patch.removeGradient == true {
            background.gradient = nil
        } else if let gradient = patch.gradient {
            background.gradient = try sidebarGradient(gradient)
        }

        if patch.removeImage == true {
            background.image = nil
        } else if let image = patch.image {
            guard let source = image.source else {
                throw AppThemeEditingError.invalid(
                    "sidebar.image needs a source: {path} or {base64}."
                )
            }
            let data = try imageBytes(source, describing: "sidebar.image.source")
            guard let stored = ThemeAssetStore.store(
                imageData: data,
                for: themeID,
                slot: .background,
                variant: kind
            ) else {
                throw AppThemeEditingError.invalid(
                    "sidebar.image.source is not a readable image (or exceeds "
                        + "\(SidebarStyleLimits.maximumImageBytes / (1024 * 1024)) MB)."
                )
            }
            let mode: SidebarStyle.ImageLayer.Mode
            if let rawMode = cleaned(image.mode) {
                guard let parsed = SidebarStyle.ImageLayer.Mode(rawValue: rawMode) else {
                    throw AppThemeEditingError.invalid(
                        "sidebar.image.mode must be \"tile\", \"fill\" or \"fit\"."
                    )
                }
                mode = parsed
            } else {
                mode = .fill
            }
            background.image = SidebarStyle.ImageLayer(
                asset: stored,
                mode: mode,
                opacity: image.opacity ?? 1
            )
        }

        if patch.removeNavigatorWell == true {
            style.navigatorWell = nil
        } else if let wellPatch = patch.navigatorWell {
            let fill: NSColor
            if let rawFill = cleaned(wellPatch.fill) {
                guard let parsed = NSColor(hex: rawFill) else {
                    throw AppThemeEditingError.invalid(
                        "sidebar.navigator_well.fill must be #RRGGBB or #RRGGBBAA."
                    )
                }
                fill = parsed
            } else if let existing = style.navigatorWell?.fill {
                fill = existing
            } else {
                throw AppThemeEditingError.invalid(
                    "A newly stated sidebar.navigator_well needs an opaque fill."
                )
            }

            let bevel: SidebarStyle.NavigatorWell.Bevel
            if let rawBevel = cleaned(wellPatch.bevel) {
                guard let parsed = SidebarStyle.NavigatorWell.Bevel(rawValue: rawBevel) else {
                    throw AppThemeEditingError.invalid(
                        "sidebar.navigator_well.bevel must be \"sunken\", \"raised\" or \"none\"."
                    )
                }
                bevel = parsed
            } else {
                bevel = style.navigatorWell?.bevel ?? .sunken
            }
            style.navigatorWell = SidebarStyle.NavigatorWell(fill: fill, bevel: bevel)
        }

        var brand = style.brand ?? SidebarStyle.Brand()
        if let logo = patch.logo {
            switch logo {
            case .mark:
                brand.logo = .mark
            case .hidden:
                brand.logo = .hidden
            case .image(let source):
                let data = try imageBytes(source, describing: "sidebar.logo")
                guard let stored = ThemeAssetStore.store(
                    imageData: data,
                    for: themeID,
                    slot: .logo,
                    variant: kind
                ) else {
                    throw AppThemeEditingError.invalid(
                        "sidebar.logo is not a readable image."
                    )
                }
                brand.logo = .asset(stored)
            }
        }

        if patch.removeTitle == true {
            brand.title = nil
        } else if let title = patch.title {
            let weight: SidebarStyle.Brand.Title.Weight?
            if let rawWeight = cleaned(title.weight) {
                guard let parsed = SidebarStyle.Brand.Title.Weight(rawValue: rawWeight) else {
                    throw AppThemeEditingError.invalid(
                        "title.weight must be \"regular\", \"medium\", \"semibold\" or \"bold\"."
                    )
                }
                weight = parsed
            } else {
                weight = nil
            }
            let parsed = SidebarStyle.Brand.Title(
                text: cleaned(title.text),
                fontFamily: cleaned(title.fontFamily),
                fontSize: title.fontSize,
                weight: weight,
                hidden: title.hidden ?? false
            )
            brand.title = parsed.isEmpty ? nil : parsed
        }

        style.background = background.isEmpty ? nil : background
        style.brand = brand.isEmpty ? nil : brand
        return .set(style)
    }

    private func sidebarGradient(
        _ arguments: AppThemeGradientArguments
    ) throws -> SidebarStyle.Gradient {
        let stops = try (arguments.stops ?? []).map { stop -> SidebarStyle.Gradient.Stop in
            guard let hex = cleaned(stop.color), let color = NSColor(hex: hex) else {
                throw AppThemeEditingError.invalid(
                    "A gradient stop's color must be #RRGGBB or #RRGGBBAA."
                )
            }
            guard let position = stop.position else {
                throw AppThemeEditingError.invalid(
                    "A gradient stop needs a position between 0 and 1."
                )
            }
            return SidebarStyle.Gradient.Stop(color: color, position: position)
        }
        return SidebarStyle.Gradient(
            stops: stops,
            angleDegrees: arguments.angleDegrees ?? 180
        )
    }

    private func imageBytes(
        _ source: AppThemeImageArguments,
        describing field: String
    ) throws -> Data {
        if let rawPath = cleaned(source.path) {
            let path = (rawPath as NSString).expandingTildeInPath
            let data: Data
            do {
                data = try BoundedFileReader.read(
                    URL(fileURLWithPath: path),
                    maximumBytes: SidebarStyleLimits.maximumImageBytes
                )
            } catch BoundedFileReadError.exceedsLimit(maximumBytes: _) {
                throw AppThemeEditingError.invalid(
                    "\(field): file exceeds "
                        + "\(SidebarStyleLimits.maximumImageBytes / (1024 * 1024)) MB."
                )
            } catch {
                throw AppThemeEditingError.invalid("\(field): no readable file at \(path).")
            }
            return data
        }
        if let base64 = cleaned(source.base64) {
            guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
                throw AppThemeEditingError.invalid("\(field): base64 did not decode.")
            }
            guard data.count <= SidebarStyleLimits.maximumImageBytes else {
                throw AppThemeEditingError.invalid(
                    "\(field): image exceeds "
                        + "\(SidebarStyleLimits.maximumImageBytes / (1024 * 1024)) MB."
                )
            }
            return data
        }
        throw AppThemeEditingError.invalid("\(field): provide {path} or {base64}.")
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
        guard patch.controlGlow == nil || patch.removeControlGlow != true else {
            throw AppThemeEditingError.invalid(
                "material cannot set control_glow and remove_control_glow in the same patch."
            )
        }
        guard patch.popoverStyle == nil || patch.removePopoverStyle != true else {
            throw AppThemeEditingError.invalid(
                "material cannot set popover_style and remove_popover_style in the same patch."
            )
        }
        guard patch.controlBorderWidth == nil || patch.removeControlBorderWidth != true else {
            throw AppThemeEditingError.invalid(
                "material cannot set control_border_width and remove_control_border_width "
                    + "in the same patch."
            )
        }
        guard patch.backdropPattern == nil || patch.removeBackdropPattern != true else {
            throw AppThemeEditingError.invalid(
                "material cannot set backdrop_pattern and remove_backdrop_pattern "
                    + "in the same patch."
            )
        }
        guard patch.buttonStyle == nil || patch.removeButtonStyle != true else {
            throw AppThemeEditingError.invalid(
                "material cannot set button_style and remove_button_style in the same patch."
            )
        }
        guard patch.headingStyle == nil || patch.removeHeadingStyle != true else {
            throw AppThemeEditingError.invalid(
                "material cannot set heading_style and remove_heading_style in the same patch."
            )
        }
        guard patch.fontFamily == nil || patch.removeFontFamily != true else {
            throw AppThemeEditingError.invalid(
                "material cannot set font_family and remove_font_family in the same patch."
            )
        }
        guard patch.fontFallbacks == nil || patch.removeFontFallbacks != true else {
            throw AppThemeEditingError.invalid(
                "material cannot set font_fallbacks and remove_font_fallbacks in the same patch."
            )
        }

        guard patch.bevel == nil || patch.removeBevel != true else {
            throw AppThemeEditingError.invalid(
                "material cannot set bevel and remove_bevel in the same patch."
            )
        }

        var material = base
        if let value = patch.panelRadius { material.panelRadius = CGFloat(value) }
        if let value = patch.controlRadius { material.controlRadius = CGFloat(value) }
        if let value = patch.borderWidth { material.borderWidth = CGFloat(value) }
        if patch.removeControlBorderWidth == true {
            material.controlBorderWidth = nil
        } else if let value = patch.controlBorderWidth {
            material.controlBorderWidth = CGFloat(value)
        }
        if patch.removeBackdropPattern == true {
            material.backdropPattern = nil
        } else if let patternPatch = patch.backdropPattern {
            let kind: AppTheme.Material.BackdropPattern.Kind
            if let raw = cleaned(patternPatch.kind) {
                guard let parsed = AppTheme.Material.BackdropPattern.Kind(rawValue: raw) else {
                    throw AppThemeEditingError.invalid(
                        "material.backdrop_pattern.kind must be \"dots\", \"grid\", "
                            + "\"diagonal_grid\", or \"perspective_grid\"."
                    )
                }
                kind = parsed
            } else if let inherited = base.backdropPattern?.kind {
                kind = inherited
            } else {
                throw AppThemeEditingError.invalid(
                    "material.backdrop_pattern.kind is required when the base has no pattern."
                )
            }

            let role: AppThemeRole
            if let raw = cleaned(patternPatch.role) {
                guard let parsed = AppThemeRole.named(raw) else {
                    throw AppThemeEditingError.invalid(
                        "\"\(raw)\" is not a valid backdrop_pattern.role."
                    )
                }
                role = parsed
            } else {
                role = base.backdropPattern?.role ?? .border
            }

            material.backdropPattern = AppTheme.Material.BackdropPattern(
                kind: kind,
                role: role,
                opacity: patternPatch.opacity ?? base.backdropPattern?.opacity ?? 0.08,
                spacing: CGFloat(patternPatch.spacing ?? Double(base.backdropPattern?.spacing ?? 20)),
                lineWidth: CGFloat(
                    patternPatch.lineWidth ?? Double(base.backdropPattern?.lineWidth ?? 1)
                )
            )
        }
        if let value = patch.textScale { material.textScale = CGFloat(value) }
        if let value = patch.choiceHeight { material.choiceHeight = CGFloat(value) }

        if patch.removePopoverStyle == true {
            material.popoverStyle = .system
        } else if let popoverPatch = patch.popoverStyle {
            var style = base.popoverStyle
            if let raw = cleaned(popoverPatch.arrow) {
                guard let parsed = AppTheme.Material.PopoverStyle.Arrow(rawValue: raw) else {
                    throw AppThemeEditingError.invalid(
                        "material.popover_style.arrow must be \"triangle\" or \"none\"."
                    )
                }
                style.arrow = parsed
            }
            if let raw = cleaned(popoverPatch.surfaceRole) {
                guard let parsed = AppThemeRole.named(raw) else {
                    throw AppThemeEditingError.invalid(
                        "\(raw) is not a valid popover_style.surface_role."
                    )
                }
                style.surfaceRole = parsed
            }
            if let raw = cleaned(popoverPatch.edge) {
                guard let parsed = AppTheme.Material.PopoverStyle.Edge(rawValue: raw) else {
                    throw AppThemeEditingError.invalid(
                        "material.popover_style.edge must be \"flat\", \"material\", or \"none\"."
                    )
                }
                style.edge = parsed
            }
            if let raw = cleaned(popoverPatch.shadow) {
                guard let parsed = AppTheme.Material.PopoverStyle.Shadow(rawValue: raw) else {
                    throw AppThemeEditingError.invalid(
                        "material.popover_style.shadow must be \"automatic\", \"system\", "
                            + "\"material\", or \"none\"."
                    )
                }
                style.shadow = parsed
            }
            if let raw = cleaned(popoverPatch.density) {
                guard let parsed = AppTheme.Material.PopoverStyle.Density(rawValue: raw) else {
                    throw AppThemeEditingError.invalid(
                        "material.popover_style.density must be \"regular\" or \"compact\"."
                    )
                }
                style.density = parsed
            }
            if let raw = cleaned(popoverPatch.glyphStyle) {
                guard let parsed = AppTheme.Material.PopoverStyle.GlyphStyle(rawValue: raw) else {
                    throw AppThemeEditingError.invalid(
                        "material.popover_style.glyph_style must be \"system\" or \"classic\"."
                    )
                }
                style.glyphStyle = parsed
            }
            if let value = popoverPatch.cornerRadius {
                guard (0...24).contains(value) else {
                    throw AppThemeEditingError.invalid(
                        "material.popover_style.corner_radius must be between 0 and 24."
                    )
                }
                style.cornerRadius = CGFloat(value)
            }
            material.popoverStyle = style
        }

        if let rawPlacement = cleaned(patch.scrollerPlacement) {
            guard let parsed = AppTheme.Material.ScrollerPlacement(rawValue: rawPlacement) else {
                throw AppThemeEditingError.invalid(
                    "material.scroller_placement must be \"trailing\" or \"leading\"."
                )
            }
            material.scrollerPlacement = parsed
        }
        if let rawTrack = cleaned(patch.scrollerTrackStyle) {
            guard let parsed = AppTheme.Material.ScrollerTrackStyle(rawValue: rawTrack) else {
                throw AppThemeEditingError.invalid(
                    "material.scroller_track_style must be \"solid\" or \"stippled\"."
                )
            }
            material.scrollerTrackStyle = parsed
        }
        if let rawAppearance = cleaned(patch.scrollerAppearance) {
            guard let parsed = AppTheme.Material.ScrollerAppearance(
                rawValue: rawAppearance
            ) else {
                throw AppThemeEditingError.invalid(
                    "material.scroller_appearance must be \"automatic\", \"windows_98\", "
                        + "\"platinum\", \"beos\", \"openstep\", \"irix\", \"amiga\", "
                        + "\"aqua\", or \"aqua_tiger\"."
                )
            }
            material.scrollerAppearance = parsed
        }
        if let rawAppearance = cleaned(patch.menuAppearance) {
            guard let parsed = AppTheme.Material.MenuAppearance(rawValue: rawAppearance) else {
                throw AppThemeEditingError.invalid(
                    "material.menu_appearance must be \"automatic\", \"windows_98\", "
                        + "\"platinum\", \"beos\", \"openstep\", \"irix\", \"amiga\", "
                        + "\"aqua\", or \"aqua_tiger\"."
                )
            }
            material.menuAppearance = parsed
        }
        if let rawProgress = cleaned(patch.progressStyle) {
            guard let parsed = AppTheme.Material.ProgressStyle(rawValue: rawProgress) else {
                throw AppThemeEditingError.invalid(
                    "material.progress_style must be \"continuous\", \"segmented\", \"irix\", "
                        + "or \"amiga\"."
                )
            }
            material.progressStyle = parsed
        }
        if let rawChoice = cleaned(patch.choiceStyle) {
            guard let parsed = AppTheme.Material.ChoiceStyle(rawValue: rawChoice) else {
                throw AppThemeEditingError.invalid(
                    "material.choice_style must be \"chip\", \"dropdown\", \"popup\", "
                        + "\"double_arrow_popup\", \"aqua_popup\", or \"cycle\"."
                )
            }
            material.choiceStyle = parsed
        }
        if let rawCheckbox = cleaned(patch.checkboxStyle) {
            guard let parsed = AppTheme.Material.CheckboxStyle(rawValue: rawCheckbox) else {
                throw AppThemeEditingError.invalid(
                    "material.checkbox_style must be \"automatic\", \"recessed_tick\", "
                        + "\"windows_98_tick\", or \"beos_cross\"."
                )
            }
            material.checkboxStyle = parsed
        }
        if let rawToggle = cleaned(patch.toggleStyle) {
            guard let parsed = AppTheme.Material.ToggleStyle(rawValue: rawToggle) else {
                throw AppThemeEditingError.invalid(
                    "material.toggle_style must be \"automatic\" or \"on_off_button\"."
                )
            }
            material.toggleStyle = parsed
        }

        if patch.removeButtonStyle == true {
            material.buttonStyle = .system
        } else if let buttonPatch = patch.buttonStyle {
            guard buttonPatch.primaryBorderRole == nil
                    || buttonPatch.removePrimaryBorder != true else {
                throw AppThemeEditingError.invalid(
                    "material.button_style cannot set primary_border_role and "
                        + "remove_primary_border in the same patch."
                )
            }

            var style = base.buttonStyle
            if let raw = cleaned(buttonPatch.textTransform) {
                guard let parsed = AppTheme.Material.ButtonStyle.TextTransform(rawValue: raw) else {
                    throw AppThemeEditingError.invalid(
                        "material.button_style.text_transform must be \"none\" or \"uppercase\"."
                    )
                }
                style.textTransform = parsed
            }
            if let raw = cleaned(buttonPatch.titleRendering) {
                guard let parsed = AppTheme.Material.ButtonStyle.TitleRendering(
                    rawValue: raw
                ) else {
                    throw AppThemeEditingError.invalid(
                        "material.button_style.title_rendering must be \"font\" or \"pixel_5x6\"."
                    )
                }
                style.titleRendering = parsed
            }
            if let raw = cleaned(buttonPatch.fontWeight) {
                guard let parsed = AppTheme.Material.ButtonStyle.FontWeight(rawValue: raw) else {
                    throw AppThemeEditingError.invalid(
                        "material.button_style.font_weight must be \"regular\", \"medium\", "
                            + "\"semibold\", or \"bold\"."
                    )
                }
                style.fontWeight = parsed
            }
            if let raw = cleaned(buttonPatch.typeface) {
                guard let parsed = AppTheme.Material.Typeface(rawValue: raw) else {
                    let accepted = AppTheme.Material.Typeface.allCases
                        .map(\.rawValue)
                        .joined(separator: ", ")
                    throw AppThemeEditingError.invalid(
                        "\"\(raw)\" is not a valid button_style.typeface. Accepted: \(accepted)."
                    )
                }
                style.typeface = parsed
            }
            if let family = cleaned(buttonPatch.fontFamily) {
                guard Design.Typography.availableFamilies.contains(family) else {
                    throw AppThemeEditingError.invalid(
                        "\"\(family)\" is not an installed font family on this machine."
                    )
                }
                style.fontFamily = family
            }
            if let value = buttonPatch.tracking { style.tracking = CGFloat(value) }
            if let value = buttonPatch.fontScale { style.fontScale = CGFloat(value) }
            if let value = buttonPatch.minimumWidth { style.minimumWidth = CGFloat(value) }
            if let value = buttonPatch.minimumHeight { style.minimumHeight = CGFloat(value) }
            if let value = buttonPatch.embossesDisabledTitle {
                style.embossesDisabledTitle = value
            }
            if let value = buttonPatch.antialiasesTitle {
                style.antialiasesTitle = value
            }
            if let raw = cleaned(buttonPatch.primaryTreatment) {
                guard let parsed = AppTheme.Material.ButtonStyle.PrimaryTreatment(rawValue: raw) else {
                    throw AppThemeEditingError.invalid(
                        "material.button_style.primary_treatment must be \"filled\", "
                            + "\"outlined\", or \"raised\"."
                    )
                }
                style.primaryTreatment = parsed
            }
            if let raw = cleaned(buttonPatch.primaryRole) {
                guard let parsed = AppThemeRole.named(raw) else {
                    throw AppThemeEditingError.invalid(
                        "\"\(raw)\" is not a valid button_style.primary_role."
                    )
                }
                style.primaryRole = parsed
            }
            if let raw = cleaned(buttonPatch.secondaryRole) {
                guard let parsed = AppThemeRole.named(raw) else {
                    throw AppThemeEditingError.invalid(
                        "\"\(raw)\" is not a valid button_style.secondary_role."
                    )
                }
                style.secondaryRole = parsed
            }
            if let raw = cleaned(buttonPatch.secondaryHoverRole) {
                guard let parsed = AppThemeRole.named(raw) else {
                    throw AppThemeEditingError.invalid(
                        "\"\(raw)\" is not a valid button_style.secondary_hover_role."
                    )
                }
                style.secondaryHoverRole = parsed
            }
            if let raw = cleaned(buttonPatch.secondaryShadow) {
                guard let parsed = AppTheme.Material.ButtonStyle.SecondaryShadow(
                    rawValue: raw
                ) else {
                    throw AppThemeEditingError.invalid(
                        "material.button_style.secondary_shadow must be \"control\", "
                            + "\"panel\", or \"none\"."
                    )
                }
                style.secondaryShadow = parsed
            }
            if buttonPatch.removePrimaryBorder == true {
                style.primaryBorderRole = nil
            } else if let raw = cleaned(buttonPatch.primaryBorderRole) {
                guard let parsed = AppThemeRole.named(raw) else {
                    throw AppThemeEditingError.invalid(
                        "\"\(raw)\" is not a valid button_style.primary_border_role."
                    )
                }
                style.primaryBorderRole = parsed
            }
            if let value = buttonPatch.hoverOffsetX { style.hoverOffsetX = CGFloat(value) }
            if let value = buttonPatch.hoverOffsetY { style.hoverOffsetY = CGFloat(value) }
            if let value = buttonPatch.pressedOffsetX { style.pressedOffsetX = CGFloat(value) }
            if let value = buttonPatch.pressedOffsetY { style.pressedOffsetY = CGFloat(value) }
            if let value = buttonPatch.collapseShadowOnHover {
                style.collapseShadowOnHover = value
            }
            material.buttonStyle = style
        }

        if patch.removeHeadingStyle == true {
            material.headingStyle = nil
        } else if let headingPatch = patch.headingStyle {
            var style = base.headingStyle ?? AppTheme.Material.HeadingStyle()
            if let raw = cleaned(headingPatch.typeface) {
                guard let parsed = AppTheme.Material.Typeface(rawValue: raw) else {
                    let accepted = AppTheme.Material.Typeface.allCases
                        .map(\.rawValue)
                        .joined(separator: ", ")
                    throw AppThemeEditingError.invalid(
                        "\"\(raw)\" is not a valid heading_style.typeface. Accepted: \(accepted)."
                    )
                }
                style.typeface = parsed
            }
            if let family = cleaned(headingPatch.fontFamily) {
                guard Design.Typography.availableFamilies.contains(family) else {
                    throw AppThemeEditingError.invalid(
                        "\"\(family)\" is not an installed font family on this machine."
                    )
                }
                style.fontFamily = family
            }
            if let raw = cleaned(headingPatch.fontWeight) {
                guard let parsed = AppTheme.Material.ButtonStyle.FontWeight(rawValue: raw) else {
                    throw AppThemeEditingError.invalid(
                        "material.heading_style.font_weight must be \"regular\", \"medium\", "
                            + "\"semibold\", or \"bold\"."
                    )
                }
                style.fontWeight = parsed
            }
            if let italic = headingPatch.italic { style.italic = italic }
            material.headingStyle = style
        }

        if patch.removeBevel == true {
            material.bevel = nil
        } else if let bevel = patch.bevel {
            let style: AppTheme.Bevel.Style
            if let rawStyle = cleaned(bevel.style) {
                guard let parsed = AppTheme.Bevel.Style(rawValue: rawStyle) else {
                    throw AppThemeEditingError.invalid(
                        "material.bevel.style must be \"hard\" or \"soft\"."
                    )
                }
                style = parsed
            } else {
                style = base.bevel?.style ?? .hard
            }
            material.bevel = AppTheme.Bevel(
                width: CGFloat(bevel.width ?? Double(base.bevel?.width ?? 2)),
                style: style
            )
        }

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
            material.fontFamily = family
        }
        if patch.removeFontFallbacks == true {
            material.fontFallbacks = []
        } else if let fallbacks = patch.fontFallbacks {
            var seen = Set<String>()
            material.fontFallbacks = fallbacks.compactMap { raw in
                let family = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !family.isEmpty else { return nil }
                return seen.insert(family.lowercased()).inserted ? family : nil
            }
        }
        if patch.fontFamily != nil || patch.fontFallbacks != nil
            || patch.removeFontFamily == true || patch.removeFontFallbacks == true {
            // Historical faces are commonly proprietary and therefore absent on the machine
            // authoring the theme. Keep those names in the document so installing the real face
            // later improves the theme automatically, but require the *chain* to contain one
            // family CoreText can resolve today. That catches a misspelled chain without making
            // MS Sans Serif, Charcoal, Swiss 721, or Topaz impossible to author on modern macOS.
            let available = Set(Design.Typography.availableFamilies.map { $0.lowercased() })
            guard material.fontFamilies.isEmpty
                    || material.fontFamilies.contains(where: { available.contains($0.lowercased()) }) else {
                throw AppThemeEditingError.invalid(
                    "material font_family/font_fallbacks must include at least one installed "
                        + "font family on this machine."
                )
            }
        }
        if patch.removeGlow == true {
            material.glow = nil
        } else if let glow = patch.glow {
            material.glow = try appThemeGlow(glow, base: base.glow, field: "glow")
        }
        if patch.removeControlGlow == true {
            material.controlGlow = nil
        } else if let glow = patch.controlGlow {
            material.controlGlow = try appThemeGlow(
                glow,
                base: base.controlGlow,
                field: "control_glow"
            )
        }
        return material
    }

    /// Resolves the shared paired-shadow patch vocabulary for either panel or control depth.
    /// Keeping this one parser is what makes the two fields genuinely equivalent for custom
    /// themes rather than two almost-identical APIs that drift on partial updates.
    private func appThemeGlow(
        _ patch: AppThemeGlowArguments,
        base: AppTheme.Glow?,
        field: String
    ) throws -> AppTheme.Glow {
        guard patch.highlight == nil || patch.removeHighlight != true else {
            throw AppThemeEditingError.invalid(
                "material.\(field) cannot set highlight and remove_highlight in the same patch."
            )
        }

        let role: AppThemeRole
        if let rawRole = cleaned(patch.role) {
            guard let parsed = AppThemeRole.named(rawRole) else {
                throw AppThemeEditingError.invalid(
                    "\"\(rawRole)\" is not a valid \(field) role."
                )
            }
            role = parsed
        } else {
            role = base?.role ?? .accent
        }

        let highlight: AppTheme.Glow.Highlight?
        if patch.removeHighlight == true {
            highlight = nil
        } else if let patchHighlight = patch.highlight {
            let highlightRole: AppThemeRole
            if let rawRole = cleaned(patchHighlight.role) {
                guard let parsed = AppThemeRole.named(rawRole) else {
                    throw AppThemeEditingError.invalid(
                        "\"\(rawRole)\" is not a valid \(field) highlight role."
                    )
                }
                highlightRole = parsed
            } else {
                highlightRole = base?.highlight?.role ?? .bevelHighlight
            }
            highlight = AppTheme.Glow.Highlight(
                role: highlightRole,
                radius: CGFloat(
                    patchHighlight.radius ?? Double(base?.highlight?.radius ?? 6)
                ),
                opacity: patchHighlight.opacity ?? base?.highlight?.opacity ?? 0.3,
                offsetX: CGFloat(
                    patchHighlight.offsetX ?? Double(base?.highlight?.offsetX ?? 0)
                ),
                offsetY: CGFloat(
                    patchHighlight.offsetY ?? Double(base?.highlight?.offsetY ?? 0)
                )
            )
        } else {
            highlight = base?.highlight
        }

        return AppTheme.Glow(
            role: role,
            radius: CGFloat(patch.radius ?? Double(base?.radius ?? 6)),
            opacity: patch.opacity ?? base?.opacity ?? 0.2,
            offsetX: CGFloat(patch.offsetX ?? Double(base?.offsetX ?? 0)),
            offsetY: CGFloat(patch.offsetY ?? Double(base?.offsetY ?? 0)),
            highlight: highlight
        )
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
        var document: [String: Any] = [
            // `roles`, `material`, and `terminal_colors` can be copied directly into the
            // corresponding create/update variant patch. `resolved_roles` is inspection-only.
            "roles": explicit,
            "resolved_roles": resolved,
            "material": appThemeMaterialDocument(material),
            "terminal_palette_id": terminal.id.rawValue,
            "terminal_colors": terminalColorDocument(terminal)
        ]
        if let sidebar = variant?.sidebar {
            document["sidebar"] = appThemeSidebarDocument(sidebar)
        }
        if let chrome = variant?.chrome {
            document["chrome"] = appThemeChromeDocument(chrome)
        }
        return document
    }

    /// The chrome block as create/update speak it; everything round-trips.
    private func appThemeChromeDocument(_ chrome: WindowChromeStyle) -> [String: Any] {
        func gradientDocument(_ gradient: SidebarStyle.Gradient) -> [String: Any] {
            [
                "angle_degrees": gradient.angleDegrees,
                "stops": gradient.stops.map {
                    ["color": $0.color.hexString, "position": $0.position]
                }
            ]
        }

        var titleBar: [String: Any] = [
            "active_gradient": gradientDocument(chrome.titleBar.activeGradient),
            "title_alignment": chrome.titleBar.titleAlignment.rawValue,
            "title_font_style": chrome.titleBar.titleFontStyle.rawValue,
            "button_glyph_style": chrome.titleBar.buttonGlyphStyle.rawValue,
            "button_placement": chrome.titleBar.buttonPlacement.rawValue,
            "shows_app_icon": chrome.titleBar.showsAppIcon,
            "shape": chrome.titleBar.shape.rawValue,
            "visible_buttons": chrome.titleBar.visibleButtons.map(\.rawValue)
        ]
        if let inactive = chrome.titleBar.inactiveGradient {
            titleBar["inactive_gradient"] = gradientDocument(inactive)
        }
        if let ink = chrome.titleBar.ink { titleBar["ink"] = ink.hexString }
        if let ink = chrome.titleBar.inactiveInk { titleBar["inactive_ink"] = ink.hexString }
        if let height = chrome.titleBar.height { titleBar["height"] = height }
        if let width = chrome.titleBar.tabWidth { titleBar["tab_width"] = width }
        if let texture = chrome.titleBar.activeTexture {
            titleBar["active_texture"] = appThemeChromeTextureDocument(texture)
        }
        if let texture = chrome.titleBar.inactiveTexture {
            titleBar["inactive_texture"] = appThemeChromeTextureDocument(texture)
        }

        var document: [String: Any] = ["title_bar": titleBar]
        if let frame = chrome.frame {
            document["frame"] = [
                "width": frame.width,
                "corner_radius": frame.cornerRadius,
                "antialiases_corners": frame.antialiasesCorners
            ]
        }
        return document
    }

    private func appThemeChromeTextureDocument(
        _ texture: WindowChromeStyle.TitleBar.Texture
    ) -> [String: Any] {
        var document: [String: Any] = ["kind": texture.kind.rawValue]
        if let color = texture.color { document["color"] = color.hexString }
        if let spacing = texture.spacing { document["spacing"] = spacing }
        return document
    }

    /// The sidebar block as create/update speak it, with asset names in place of bytes — an
    /// agent re-supplying an image sends a new {path}/{base64}; everything else round-trips.
    private func appThemeSidebarDocument(_ sidebar: SidebarStyle) -> [String: Any] {
        var document: [String: Any] = [:]
        if let gradient = sidebar.background?.gradient {
            document["gradient"] = [
                "angle_degrees": gradient.angleDegrees,
                "stops": gradient.stops.map {
                    ["color": $0.color.hexString, "position": $0.position]
                }
            ] as [String: Any]
        }
        if let image = sidebar.background?.image {
            document["image"] = [
                "asset": image.asset,
                "mode": image.mode.rawValue,
                "opacity": image.opacity
            ] as [String: Any]
        }
        if let brand = sidebar.brand {
            switch brand.logo {
            case .mark: document["logo"] = "mark"
            case .hidden: document["logo"] = "hidden"
            case .asset(let name): document["logo"] = ["asset": name]
            }
            if let title = brand.title {
                var titleDocument: [String: Any] = ["hidden": title.hidden]
                if let text = title.text { titleDocument["text"] = text }
                if let family = title.fontFamily { titleDocument["font_family"] = family }
                if let size = title.fontSize { titleDocument["font_size"] = size }
                if let weight = title.weight { titleDocument["weight"] = weight.rawValue }
                document["title"] = titleDocument
            }
        }
        if let well = sidebar.navigatorWell {
            document["navigator_well"] = [
                "fill": well.fill.hexString,
                "bevel": well.bevel.rawValue
            ]
        }
        return document
    }

    private func appThemeMaterialDocument(_ material: AppTheme.Material) -> [String: Any] {
        func glowDocument(_ glow: AppTheme.Glow) -> [String: Any] {
            var document: [String: Any] = [
                "role": glow.role.wireName,
                "radius": Double(glow.radius),
                "opacity": glow.opacity,
                "offset_x": Double(glow.offsetX),
                "offset_y": Double(glow.offsetY)
            ]
            if let highlight = glow.highlight {
                document["highlight"] = [
                    "role": highlight.role.wireName,
                    "radius": Double(highlight.radius),
                    "opacity": highlight.opacity,
                    "offset_x": Double(highlight.offsetX),
                    "offset_y": Double(highlight.offsetY)
                ]
            }
            return document
        }

        var document: [String: Any] = [
            "panel_radius": Double(material.panelRadius),
            "control_radius": Double(material.controlRadius),
            "border_width": Double(material.borderWidth),
            "text_scale": Double(material.textScale),
            "choice_height": Double(material.choiceHeight),
            "typeface": material.typeface.rawValue,
            "scroller_placement": material.scrollerPlacement.rawValue,
            "scroller_track_style": material.scrollerTrackStyle.rawValue,
            "scroller_appearance": material.scrollerAppearance.rawValue,
            "menu_appearance": material.menuAppearance.rawValue,
            "progress_style": material.progressStyle.rawValue,
            "choice_style": material.choiceStyle.rawValue,
            "checkbox_style": material.checkboxStyle.rawValue,
            "toggle_style": material.toggleStyle.rawValue
        ]
        if let width = material.controlBorderWidth {
            document["control_border_width"] = Double(width)
        }
        if let pattern = material.backdropPattern {
            document["backdrop_pattern"] = [
                "kind": pattern.kind.rawValue,
                "role": pattern.role.wireName,
                "opacity": pattern.opacity,
                "spacing": Double(pattern.spacing),
                "line_width": Double(pattern.lineWidth)
            ]
        }
        let popover = material.popoverStyle
        var popoverDocument: [String: Any] = [
            "arrow": popover.arrow.rawValue,
            "surface_role": popover.surfaceRole.wireName,
            "edge": popover.edge.rawValue,
            "shadow": popover.shadow.rawValue,
            "density": popover.density.rawValue,
            "glyph_style": popover.glyphStyle.rawValue
        ]
        if let radius = popover.cornerRadius {
            popoverDocument["corner_radius"] = Double(radius)
        }
        document["popover_style"] = popoverDocument
        let button = material.buttonStyle
        var buttonDocument: [String: Any] = [
            "text_transform": button.textTransform.rawValue,
            "title_rendering": button.titleRendering.rawValue,
            "font_weight": button.fontWeight.rawValue,
            "tracking": Double(button.tracking),
            "font_scale": Double(button.fontScale),
            "primary_treatment": button.primaryTreatment.rawValue,
            "primary_role": button.primaryRole.wireName,
            "secondary_role": button.secondaryRole.wireName,
            "secondary_hover_role": button.secondaryHoverRole.wireName,
            "secondary_shadow": button.secondaryShadow.rawValue,
            "hover_offset_x": Double(button.hoverOffsetX),
            "hover_offset_y": Double(button.hoverOffsetY),
            "pressed_offset_x": Double(button.pressedOffsetX),
            "pressed_offset_y": Double(button.pressedOffsetY),
            "collapse_shadow_on_hover": button.collapseShadowOnHover
        ]
        buttonDocument["embosses_disabled_title"] = button.embossesDisabledTitle
        buttonDocument["antialiases_title"] = button.antialiasesTitle
        if let width = button.minimumWidth {
            buttonDocument["minimum_width"] = Double(width)
        }
        if let height = button.minimumHeight {
            buttonDocument["minimum_height"] = Double(height)
        }
        if let role = button.primaryBorderRole {
            buttonDocument["primary_border_role"] = role.wireName
        }
        if let typeface = button.typeface {
            buttonDocument["typeface"] = typeface.rawValue
        }
        if let family = button.fontFamily {
            buttonDocument["font_family"] = family
        }
        document["button_style"] = buttonDocument
        if let heading = material.headingStyle {
            var headingDocument: [String: Any] = ["italic": heading.italic]
            if let typeface = heading.typeface {
                headingDocument["typeface"] = typeface.rawValue
            }
            if let family = heading.fontFamily {
                headingDocument["font_family"] = family
            }
            if let weight = heading.fontWeight {
                headingDocument["font_weight"] = weight.rawValue
            }
            document["heading_style"] = headingDocument
        }
        if let family = material.fontFamily { document["font_family"] = family }
        if !material.fontFallbacks.isEmpty {
            document["font_fallbacks"] = material.fontFallbacks
        }
        if let bevel = material.bevel {
            document["bevel"] = [
                "width": Double(bevel.width),
                "style": bevel.style.rawValue
            ]
        }
        if let glow = material.glow {
            document["glow"] = glowDocument(glow)
        }
        if let glow = material.controlGlow {
            document["control_glow"] = glowDocument(glow)
        }
        return document
    }

    private func terminalColorDocument(_ theme: TerminalTheme) -> [String: String] {
        Dictionary(uniqueKeysWithValues: ThemeColorKey.allCases.map {
            ($0.wireName, theme[$0].hexString)
        })
    }
}
