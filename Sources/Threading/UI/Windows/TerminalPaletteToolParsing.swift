import AppKit

// MARK: - Terminal Palette Tool Parsing

/// A terminal palette as the theme tools write and read it: colour names to hex strings, plus
/// the optional phosphor `glow` and `remove_glow`.
///
/// `create_theme`'s `colors` and an app theme variant's `terminal_colors` are the same object,
/// so one type merges a patch onto a base palette and one shapes the document `get_app_theme`
/// returns. Kept off `AgentToolCoordinator` for the reason `AppThemeToolParsing` is: it takes
/// wire arguments and returns theme values, and the tool hub's authority ratchet
/// (`scripts/check_architecture_boundaries.sh`) is for transport, not policy.
@MainActor
enum TerminalPaletteToolParsing {

    // MARK: - Patching

    /// `base` with a patch's colours and glow applied.
    ///
    /// A stated text colour carries an unstated bold colour with it (`adoptingBoldForeground`),
    /// as it always has. `field` names the patch in error messages.
    static func palette(
        _ patch: TerminalColorsArguments?,
        base: TerminalTheme,
        field: String
    ) throws -> TerminalTheme {
        let colors = patch?.colors ?? [:]
        var palette = base.adoptingBoldForeground(from: colors)
        for (name, hex) in colors {
            guard let key = ThemeColorKey.named(name) else {
                throw AppThemeEditingError.invalid(
                    "\"\(name)\" is not a terminal colour. Valid names: "
                        + ThemeColorKey.allCases.map(\.wireName).joined(separator: ", ")
                        + ", plus \(TerminalColorsArguments.glowKey) and "
                        + "\(TerminalColorsArguments.removeGlowKey)."
                )
            }
            guard let color = NSColor(hex: hex) else {
                throw AppThemeEditingError.invalid(
                    "\"\(hex)\" is not a colour. Use #RRGGBB or #RRGGBBAA."
                )
            }
            palette[key] = color
        }
        return try glow(patch, applyingTo: palette, field: field)
    }

    /// Only the glow half of a patch: removed, merged onto the palette's own glow (or
    /// `TerminalGlow.standard` when it has none), or left alone when the patch says nothing.
    static func glow(
        _ patch: TerminalColorsArguments?,
        applyingTo palette: TerminalTheme,
        field: String
    ) throws -> TerminalTheme {
        guard let patch else { return palette }
        var patched = palette
        if patch.removeGlow == true {
            guard patch.glow == nil else {
                throw AppThemeEditingError.invalid(
                    "\(field) cannot set \(TerminalColorsArguments.glowKey) and "
                        + "\(TerminalColorsArguments.removeGlowKey) in the same patch."
                )
            }
            patched.glow = nil
            return patched
        }
        guard let stated = patch.glow else { return palette }
        let base = palette.glow ?? .standard
        let glow = TerminalGlow(
            radius: stated.radius.map { CGFloat($0) } ?? base.radius,
            opacity: stated.opacity ?? base.opacity
        )
        if let error = glow.validationError(field: "\(field).\(TerminalColorsArguments.glowKey)") {
            throw AppThemeEditingError.invalid(error)
        }
        patched.glow = glow
        return patched
    }

    // MARK: - Document

    /// The palette as a patch would state it, so a document read back can be sent again: every
    /// colour by its wire name, and the glow when there is one.
    static func document(_ theme: TerminalTheme) -> [String: Any] {
        var document: [String: Any] = Dictionary(
            uniqueKeysWithValues: ThemeColorKey.allCases.map { ($0.wireName, theme[$0].hexString) }
        )
        if let glow = theme.glow {
            document[TerminalColorsArguments.glowKey] = [
                "radius": Double(glow.radius),
                "opacity": glow.opacity
            ]
        }
        return document
    }
}
