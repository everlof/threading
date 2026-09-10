import AppKit

// MARK: - App Theme Tool Parsing

/// The parsing the app-theme tools share between the sidebar block and the material's
/// backdrop: a gradient from its wire form, image bytes from a path or base64, a backdrop
/// patch applied to a base, and the document form both blocks read back through.
///
/// A type of its own rather than more methods on `AgentToolCoordinator`, and the reason is the
/// authority ratchet in `scripts/check_architecture_boundaries.sh`: the coordinator is the
/// tool hub, and argument validation and result shaping that could live beside the model
/// should. Nothing here touches a tool, a session or a window — it takes wire arguments and
/// returns theme values, the shape an application service has.
@MainActor
enum AppThemeToolParsing {

    static func gradient(
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

    static func imageBytes(
        _ source: AppThemeImageArguments,
        describing field: String,
        maximumBytes: Int = SidebarStyleLimits.maximumImageBytes
    ) throws -> Data {
        if let rawPath = cleaned(source.path) {
            let path = (rawPath as NSString).expandingTildeInPath
            let data: Data
            do {
                data = try BoundedFileReader.read(
                    URL(fileURLWithPath: path),
                    maximumBytes: maximumBytes
                )
            } catch BoundedFileReadError.exceedsLimit(maximumBytes: _) {
                throw AppThemeEditingError.invalid(
                    "\(field): file exceeds "
                        + "\(maximumBytes / (1024 * 1024)) MB."
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
            guard data.count <= maximumBytes else {
                throw AppThemeEditingError.invalid(
                    "\(field): image exceeds "
                        + "\(maximumBytes / (1024 * 1024)) MB."
                )
            }
            return data
        }
        throw AppThemeEditingError.invalid("\(field): provide {path} or {base64}.")
    }

    /// Turns a material backdrop patch into the block `appThemeMaterial` records — the
    /// sidebar background's idiom, applied to the app's broad grounds. Image bytes are stored
    /// under the theme's id before validation can refuse the document, so the update path
    /// snapshots the slot first (see `updateAppTheme`) and the create path removes the
    /// folder on failure.
    static func backdrop(
        _ patch: AppThemeBackdropArguments,
        base: ThemeBackdrop?,
        themeID: AppThemeID,
        kind: AppTheme.VariantKind
    ) throws -> ThemeBackdrop? {
        if patch.remove == true {
            guard patch.gradient == nil, patch.image == nil else {
                throw AppThemeEditingError.invalid(
                    "material.backdrop cannot set fields and remove in the same patch."
                )
            }
            return nil
        }
        guard patch.gradient == nil || patch.removeGradient != true else {
            throw AppThemeEditingError.invalid(
                "material.backdrop cannot set gradient and remove_gradient in the same patch."
            )
        }
        guard patch.image == nil || patch.removeImage != true else {
            throw AppThemeEditingError.invalid(
                "material.backdrop cannot set image and remove_image in the same patch."
            )
        }

        var backdrop = base ?? ThemeBackdrop()

        if patch.removeGradient == true {
            backdrop.gradient = nil
        } else if let gradient = patch.gradient {
            backdrop.gradient = try Self.gradient(gradient)
        }

        if patch.removeImage == true {
            backdrop.image = nil
        } else if let image = patch.image {
            guard let source = image.source else {
                throw AppThemeEditingError.invalid(
                    "material.backdrop.image needs a source: {path} or {base64}."
                )
            }
            let data = try Self.imageBytes(
                source,
                describing: "material.backdrop.image.source",
                maximumBytes: ThemeAssetSlot.backdrop.maximumImageBytes
            )
            guard let stored = ThemeAssetStore.store(
                imageData: data,
                for: themeID,
                slot: .backdrop,
                variant: kind
            ) else {
                throw AppThemeEditingError.invalid(
                    "material.backdrop.image.source is not a readable image (or exceeds "
                        + "\(ThemeAssetSlot.backdrop.maximumImageBytes / (1024 * 1024)) MB)."
                )
            }
            let mode: ThemeBackdrop.ImageLayer.Mode
            if let rawMode = cleaned(image.mode) {
                guard let parsed = ThemeBackdrop.ImageLayer.Mode(rawValue: rawMode) else {
                    throw AppThemeEditingError.invalid(
                        "material.backdrop.image.mode must be \"tile\", \"fill\" or \"fit\"."
                    )
                }
                mode = parsed
            } else {
                mode = .fill
            }
            backdrop.image = ThemeBackdrop.ImageLayer(
                asset: stored,
                mode: mode,
                opacity: image.opacity ?? 1
            )
        }

        return backdrop.isEmpty ? nil : backdrop
    }

    /// The sidebar block as create/update speak it, with asset names in place of bytes — an
    /// agent re-supplying an image sends a new {path}/{base64}; everything else round-trips.
    /// A backdrop as create/update speak it — the sidebar's gradient and image halves, and the
    /// material's whole block, are the same two keys.
    static func document(_ backdrop: ThemeBackdrop) -> [String: Any] {
        var document: [String: Any] = [:]
        if let gradient = backdrop.gradient {
            document["gradient"] = [
                "angle_degrees": gradient.angleDegrees,
                "stops": gradient.stops.map {
                    ["color": $0.color.hexString, "position": $0.position]
                }
            ] as [String: Any]
        }
        if let image = backdrop.image {
            document["image"] = [
                "asset": image.asset,
                "mode": image.mode.rawValue,
                "opacity": image.opacity
            ] as [String: Any]
        }
        return document
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
}
