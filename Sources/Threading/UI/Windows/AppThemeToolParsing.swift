import AppKit
import ThreadingRemoteKit

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
        let statedStops = arguments.stops ?? []
        guard (2...ThemeBackdropLimits.maximumGradientStops).contains(statedStops.count) else {
            throw AppThemeEditingError.invalid(
                "A gradient needs 2 to \(ThemeBackdropLimits.maximumGradientStops) stops."
            )
        }
        let stops = try statedStops.map { stop -> SidebarStyle.Gradient.Stop in
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
            angleDegrees: arguments.angleDegrees ?? 180,
            drift: arguments.drift.map {
                ThemeGradientDrift(
                    duration: $0.duration ?? ThemeGradientDrift.defaultDuration,
                    distance: $0.distance ?? ThemeGradientDrift.defaultDistance
                )
            }
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
            guard patch.gradient == nil, patch.image == nil, patch.particles == nil else {
                throw AppThemeEditingError.invalid(
                    "material.backdrop cannot set fields and remove in the same patch."
                )
            }
            return nil
        }
        guard patch.particles == nil || patch.removeParticles != true else {
            throw AppThemeEditingError.invalid(
                "material.backdrop cannot set particles and remove_particles in the same patch."
            )
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

        if patch.removeParticles == true {
            backdrop.particles = nil
        } else if let particles = patch.particles {
            backdrop.particles = try Self.particles(
                particles,
                base: backdrop.particles,
                field: "material.backdrop.particles"
            )
        }

        return backdrop.isEmpty ? nil : backdrop
    }

    // MARK: - Sidebar

    /// Turns a sidebar patch into the change `makeVariant` applies. Image bytes are stored
    /// under the theme's id as a side effect — the callers own cleanup on failure, which is
    /// why create removes the fresh folder and update restores the slots it replaced.
    static func sidebar(
        _ patch: AppThemeSidebarArguments?,
        base: SidebarStyle?,
        themeID: AppThemeID,
        kind: AppTheme.VariantKind
    ) throws -> AppThemeEditing.SidebarChange {
        guard let patch else { return .inherit }
        if patch.remove == true {
            let statesAnything = patch.gradient != nil || patch.image != nil
                || patch.logo != nil || patch.title != nil || patch.navigatorWell != nil
                || patch.particles != nil || patch.band != nil || patch.logoMotion != nil
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
        guard patch.particles == nil || patch.removeParticles != true else {
            throw AppThemeEditingError.invalid(
                "sidebar cannot set particles and remove_particles in the same patch."
            )
        }
        guard patch.band == nil || patch.removeBand != true else {
            throw AppThemeEditingError.invalid(
                "sidebar cannot set band and remove_band in the same patch."
            )
        }
        guard patch.logoMotion == nil || patch.removeLogoMotion != true else {
            throw AppThemeEditingError.invalid(
                "sidebar cannot set logo_motion and remove_logo_motion in the same patch."
            )
        }

        var style = base ?? SidebarStyle()
        var background = style.background ?? SidebarStyle.Background()

        if patch.removeGradient == true {
            background.gradient = nil
        } else if let gradient = patch.gradient {
            background.gradient = try Self.gradient(gradient)
        }

        if patch.removeImage == true {
            background.image = nil
        } else if let image = patch.image {
            guard let source = image.source else {
                throw AppThemeEditingError.invalid(
                    "sidebar.image needs a source: {path} or {base64}."
                )
            }
            let data = try Self.imageBytes(source, describing: "sidebar.image.source")
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

        if patch.removeParticles == true {
            background.particles = nil
        } else if let particles = patch.particles {
            background.particles = try Self.particles(
                particles,
                base: background.particles,
                field: "sidebar.particles"
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
                let data = try Self.imageBytes(source, describing: "sidebar.logo")
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

        if patch.removeBand == true {
            brand.band = nil
        } else if let band = patch.band {
            brand.band = try Self.band(band, base: brand.band)
        }

        if patch.removeLogoMotion == true {
            brand.motion = nil
        } else if let motion = patch.logoMotion {
            brand.motion = try Self.logoMotion(motion, base: brand.motion)
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
            let color: NSColor?
            if let rawColor = cleaned(title.color) {
                guard let parsed = NSColor(hex: rawColor) else {
                    throw AppThemeEditingError.invalid(
                        "sidebar.title.color must be #RRGGBB or #RRGGBBAA."
                    )
                }
                color = parsed
            } else {
                color = nil
            }
            let parsed = SidebarStyle.Brand.Title(
                text: cleaned(title.text),
                fontFamily: cleaned(title.fontFamily),
                fontSize: title.fontSize,
                weight: weight,
                hidden: title.hidden ?? false,
                color: color
            )
            brand.title = parsed.isEmpty ? nil : parsed
        }

        style.background = background.isEmpty ? nil : background
        style.brand = brand.isEmpty ? nil : brand
        return .set(style)
    }

    /// The sidebar block as create/update speak it, with asset names in place of bytes.
    static func document(_ sidebar: SidebarStyle) -> [String: Any] {
        var document: [String: Any] = [:]
        if let background = sidebar.background {
            document.merge(Self.document(background)) { _, new in new }
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
                if let color = title.color { titleDocument["color"] = color.hexString }
                document["title"] = titleDocument
            }
            if let band = brand.band {
                document["band"] = Self.document(band)
            }
            if let motion = brand.motion {
                document["logo_motion"] = Self.document(motion)
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

    // MARK: - Particles

    /// A particle patch merged onto what is already stated: each field it names replaces the
    /// base's, and `style` is required only when there is no base to take it from.
    static func particles(
        _ patch: AppThemeParticlesArguments,
        base: ThemeParticles?,
        field: String
    ) throws -> ThemeParticles {
        let style: ThemeParticles.Style
        if let raw = cleaned(patch.style) {
            guard let parsed = ThemeParticles.Style(rawValue: raw) else {
                throw AppThemeEditingError.invalid(
                    "\(field).style must be one of "
                        + ThemeParticles.Style.allCases.map { "\"\($0.rawValue)\"" }
                            .joined(separator: ", ") + "."
                )
            }
            style = parsed
        } else if let inherited = base?.style {
            style = inherited
        } else {
            throw AppThemeEditingError.invalid("\(field).style is required for new particles.")
        }

        var particles = base ?? ThemeParticles(style: style)
        particles.style = style
        if let raw = cleaned(patch.shape) {
            guard let shape = ThemeParticles.Shape(rawValue: raw) else {
                throw AppThemeEditingError.invalid(
                    "\(field).shape must be one of "
                        + ThemeParticles.Shape.allCases.map { "\"\($0.rawValue)\"" }
                            .joined(separator: ", ") + "."
                )
            }
            particles.shape = shape
        }
        if let colors = patch.colors {
            particles.colors = try colors.map { raw in
                guard let ink = ThemeInk(wireValue: raw) else {
                    throw AppThemeEditingError.invalid(
                        "\(field).colors: \"\(raw)\" is neither a theme role nor #RRGGBB."
                    )
                }
                return ink
            }
        }
        if let density = patch.density { particles.density = density }
        if let size = patch.size { particles.size = size }
        if let speed = patch.speed { particles.speed = speed }
        if let opacity = patch.opacity { particles.opacity = opacity }
        return particles
    }

    static func document(_ particles: ThemeParticles) -> [String: Any] {
        var document: [String: Any] = [
            "style": particles.style.rawValue,
            "colors": particles.resolvedInks.map(\.wireValue),
            "density": particles.density,
            "speed": particles.speed,
            "opacity": particles.opacity
        ]
        if let shape = particles.shape { document["shape"] = shape.rawValue }
        if let size = particles.size { document["size"] = size }
        return document
    }

    // MARK: - Transition

    static func transition(
        _ patch: AppThemeTransitionArguments,
        base: ThemeTransition?
    ) throws -> ThemeTransition {
        let particles: ThemeParticles
        if let particlePatch = patch.particles {
            particles = try Self.particles(
                particlePatch,
                base: base?.particles,
                field: "transition.particles"
            )
        } else if let inherited = base?.particles {
            particles = inherited
        } else {
            throw AppThemeEditingError.invalid(
                "transition.particles is required for a new transition — at least a style."
            )
        }
        let inherited = base ?? ThemeTransition(particles: particles)
        var wash = inherited.wash
        if let raw = cleaned(patch.wash) {
            guard let ink = ThemeInk(wireValue: raw) else {
                throw AppThemeEditingError.invalid(
                    "transition.wash: \"\(raw)\" is neither a theme role nor #RRGGBB."
                )
            }
            wash = ink
        }
        return ThemeTransition(
            particles: particles,
            duration: patch.duration ?? inherited.duration,
            wash: wash,
            washOpacity: patch.washOpacity ?? inherited.washOpacity,
            shimmer: patch.shimmer ?? inherited.shimmer
        )
    }

    static func document(_ transition: ThemeTransition) -> [String: Any] {
        var document: [String: Any] = [
            "particles": Self.document(transition.particles),
            "duration": transition.duration,
            "wash_opacity": transition.washOpacity,
            "shimmer": transition.shimmer
        ]
        if let wash = transition.wash { document["wash"] = wash.wireValue }
        return document
    }

    // MARK: - Band and Logo Motion

    static func band(
        _ patch: AppThemeSidebarBandArguments,
        base: SidebarStyle.Brand.Band?
    ) throws -> SidebarStyle.Brand.Band {
        let gradient: SidebarStyle.Gradient
        if let gradientPatch = patch.gradient {
            gradient = try Self.gradient(gradientPatch)
        } else if let inherited = base?.gradient {
            gradient = inherited
        } else {
            throw AppThemeEditingError.invalid("sidebar.band needs a gradient.")
        }
        var band = SidebarStyle.Brand.Band(gradient: gradient, ink: base?.ink)
        if let raw = cleaned(patch.ink) {
            guard let ink = NSColor(hex: raw) else {
                throw AppThemeEditingError.invalid("sidebar.band.ink must be #RRGGBB or #RRGGBBAA.")
            }
            band.ink = ink
        }
        return band
    }

    static func document(_ band: SidebarStyle.Brand.Band) -> [String: Any] {
        var document: [String: Any] = [
            "gradient": [
                "angle_degrees": band.gradient.angleDegrees,
                "stops": band.gradient.stops.map {
                    ["color": $0.color.hexString, "position": $0.position]
                }
            ] as [String: Any]
        ]
        if let ink = band.ink { document["ink"] = ink.hexString }
        return document
    }

    static func logoMotion(
        _ patch: AppThemeLogoMotionArguments,
        base: SidebarStyle.Brand.LogoMotion?
    ) throws -> SidebarStyle.Brand.LogoMotion {
        func beat(_ raw: String?, _ name: String) throws -> SidebarStyle.Brand.LogoMotion.Beat?? {
            guard let raw = cleaned(raw) else { return .none }
            if raw == "none" { return .some(nil) }
            guard let parsed = SidebarStyle.Brand.LogoMotion.Beat(rawValue: raw) else {
                throw AppThemeEditingError.invalid(
                    "sidebar.logo_motion.\(name) must be \"none\" or one of "
                        + SidebarStyle.Brand.LogoMotion.Beat.allCases.map { "\"\($0.rawValue)\"" }
                            .joined(separator: ", ") + "."
                )
            }
            return .some(parsed)
        }

        var motion = base ?? SidebarStyle.Brand.LogoMotion()
        if let hover = try beat(patch.hover, "hover") { motion.hover = hover }
        if let press = try beat(patch.press, "press") { motion.press = press }
        if let launch = try beat(patch.launch, "launch") { motion.launch = launch }
        if let particles = patch.particles {
            motion.particles = try Self.particles(
                particles,
                base: motion.particles,
                field: "sidebar.logo_motion.particles"
            )
        }
        if let origin = patch.origin {
            let current = motion.resolvedOrigin
            motion.origin = SidebarStyle.Brand.LogoMotion.Origin(
                x: origin.x ?? current.x,
                y: origin.y ?? current.y
            )
        }
        if let working = patch.working { motion.working = working }
        return motion
    }

    static func document(_ motion: SidebarStyle.Brand.LogoMotion) -> [String: Any] {
        var document: [String: Any] = ["working": motion.working]
        if let hover = motion.hover { document["hover"] = hover.rawValue }
        if let press = motion.press { document["press"] = press.rawValue }
        if let launch = motion.launch { document["launch"] = launch.rawValue }
        if let particles = motion.particles { document["particles"] = Self.document(particles) }
        if let origin = motion.origin { document["origin"] = ["x": origin.x, "y": origin.y] }
        return document
    }

    /// The sidebar block as create/update speak it, with asset names in place of bytes — an
    /// agent re-supplying an image sends a new {path}/{base64}; everything else round-trips.
    /// A backdrop as create/update speak it — the sidebar's gradient and image halves, and the
    /// material's whole block, are the same two keys.
    static func document(_ backdrop: ThemeBackdrop) -> [String: Any] {
        var document: [String: Any] = [:]
        if let gradient = backdrop.gradient {
            var fields: [String: Any] = [
                "angle_degrees": gradient.angleDegrees,
                "stops": gradient.stops.map {
                    ["color": $0.color.hexString, "position": $0.position]
                }
            ] as [String: Any]
            if let drift = gradient.drift {
                fields["drift"] = ["duration": drift.duration, "distance": drift.distance]
            }
            document["gradient"] = fields
        }
        if let image = backdrop.image {
            document["image"] = [
                "asset": image.asset,
                "mode": image.mode.rawValue,
                "opacity": image.opacity
            ] as [String: Any]
        }
        if let particles = backdrop.particles {
            document["particles"] = Self.document(particles)
        }
        return document
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
}
