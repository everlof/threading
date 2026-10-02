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
            backdrop.image = try Self.imageLayer(
                image,
                base: backdrop.image,
                field: "material.backdrop.image"
            ) { source in
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
                return stored
            }
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
                || patch.mascot != nil || patch.logoInDock != nil || patch.analyzer != nil
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
        guard patch.mascot == nil || patch.removeMascot != true else {
            throw AppThemeEditingError.invalid(
                "sidebar cannot set mascot and remove_mascot in the same patch."
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
            background.image = try Self.imageLayer(
                image,
                base: background.image,
                field: "sidebar.image"
            ) { source in
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
                return stored
            }
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

        if let inDock = patch.logoInDock { brand.dockIcon = inDock }
        if let raw = patch.analyzer {
            if raw == "default" {
                brand.analyzer = nil
            } else {
                guard let analyzer = SidebarStyle.Brand.Analyzer(rawValue: raw) else {
                    throw AppThemeEditingError.invalid("sidebar.analyzer must be audio, workload or default.")
                }
                brand.analyzer = analyzer
            }
        }

        if patch.removeMascot == true {
            style.mascot = nil
        } else if let mascot = patch.mascot {
            style.mascot = try Self.mascot(mascot, base: style.mascot, themeID: themeID, kind: kind)
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
            if brand.dockIcon { document["logo_in_dock"] = true }
            if let analyzer = brand.analyzer { document["analyzer"] = analyzer.rawValue }
        }
        if let mascot = sidebar.mascot {
            document["mascot"] = Self.document(mascot)
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
            if patch.sprites == nil { particles.sprites = [] }
        }
        if let sprites = patch.sprites {
            particles.sprites = sprites.compactMap { cleaned($0) }
            if !particles.sprites.isEmpty, cleaned(patch.shape) == nil { particles.shape = nil }
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
        if !particles.sprites.isEmpty { document["sprites"] = particles.sprites }
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
            var fields: [String: Any] = [
                "asset": image.asset,
                "mode": image.mode.rawValue,
                "opacity": image.opacity
            ]
            if image.alignment != .center { fields["alignment"] = image.alignment.rawValue }
            document["image"] = fields
        }
        if let particles = backdrop.particles {
            document["particles"] = Self.document(particles)
        }
        return document
    }

    // MARK: - Images

    /// An image patch merged onto what is stated: a `source` stores new bytes through `store`,
    /// and without one the patch restyles the picture already there — its mode, opacity or
    /// alignment — so moving an illustration to the column's foot needs no second upload.
    static func imageLayer(
        _ patch: AppThemeSidebarImageArguments,
        base: ThemeBackdrop.ImageLayer?,
        field: String,
        store: (AppThemeImageArguments) throws -> String
    ) throws -> ThemeBackdrop.ImageLayer {
        let asset: String
        if let source = patch.source {
            asset = try store(source)
        } else if let existing = base?.asset {
            asset = existing
        } else {
            throw AppThemeEditingError.invalid("\(field) needs a source: {path} or {base64}.")
        }
        var layer = base ?? ThemeBackdrop.ImageLayer(asset: asset)
        layer.asset = asset
        if let rawMode = cleaned(patch.mode) {
            guard let parsed = ThemeBackdrop.ImageLayer.Mode(rawValue: rawMode) else {
                throw AppThemeEditingError.invalid(
                    "\(field).mode must be \"tile\", \"fill\" or \"fit\"."
                )
            }
            layer.mode = parsed
        } else if base == nil {
            layer.mode = .fill
        }
        if let opacity = patch.opacity { layer.opacity = opacity }
        if let rawAlignment = cleaned(patch.alignment) {
            guard let parsed = ThemeImageAlignment(rawValue: rawAlignment) else {
                throw AppThemeEditingError.invalid(
                    "\(field).alignment must be one of "
                        + ThemeImageAlignment.allCases.map { "\"\($0.rawValue)\"" }
                            .joined(separator: ", ") + "."
                )
            }
            layer.alignment = parsed
        }
        return layer
    }

    // MARK: - Sprites

    /// The library after a patch: named entries added or replaced (a source stores new bytes,
    /// `tinted` alone restyles one already there), named removals taken out, order kept.
    static func sprites(
        _ patch: [AppThemeSpriteArguments]?,
        remove: [String]?,
        base: [ThemeSprite],
        themeID: AppThemeID,
        kind: AppTheme.VariantKind
    ) throws -> AppThemeEditing.BlockChange<[ThemeSprite]> {
        guard patch != nil || remove != nil else { return .inherit }
        var library = base
        let removing = Set((remove ?? []).compactMap { cleaned($0) })
        for entry in patch ?? [] {
            guard let name = cleaned(entry.name), ThemeSprite.isValidName(name) else {
                throw AppThemeEditingError.invalid(
                    "sprites[].name must be 1 to \(ThemeSpriteLimits.maximumNameLength) lowercase "
                        + "letters, digits, - or _."
                )
            }
            guard !removing.contains(name) else {
                throw AppThemeEditingError.invalid(
                    "sprites cannot set and remove \"\(name)\" in the same patch."
                )
            }
            let existing = library.firstIndex { $0.name == name }
            var sprite: ThemeSprite
            if let source = entry.source {
                let data = try Self.imageBytes(
                    source,
                    describing: "sprites.\(name).source",
                    maximumBytes: ThemeSpriteLimits.maximumImageBytes
                )
                guard let stored = ThemeAssetStore.storeSprite(
                    imageData: data,
                    for: themeID,
                    name: name,
                    variant: kind
                ) else {
                    throw AppThemeEditingError.invalid(
                        "sprites.\(name).source is not a readable image."
                    )
                }
                sprite = ThemeSprite(
                    name: name,
                    asset: stored,
                    tinted: existing.map { library[$0].tinted } ?? true
                )
            } else if let existing {
                sprite = library[existing]
            } else {
                throw AppThemeEditingError.invalid(
                    "sprites.\(name) is new and needs a source: {path} or {base64}."
                )
            }
            if let tinted = entry.tinted { sprite.tinted = tinted }
            if let existing {
                library[existing] = sprite
            } else {
                library.append(sprite)
            }
        }
        library.removeAll { removing.contains($0.name) }
        return library.isEmpty ? .remove : .set(library)
    }

    static func document(_ sprites: [ThemeSprite]) -> [[String: Any]] {
        sprites.map { ["name": $0.name, "asset": $0.asset, "tinted": $0.tinted] }
    }

    // MARK: - Mascot

    static func mascot(
        _ patch: AppThemeMascotArguments,
        base: ThemeMascot?,
        themeID: AppThemeID,
        kind: AppTheme.VariantKind
    ) throws -> ThemeMascot {
        var mascot = base ?? ThemeMascot(poses: [:])
        if let size = patch.size { mascot.size = size }
        if let raw = cleaned(patch.placement) {
            guard let placement = ThemeMascot.Placement(rawValue: raw) else {
                throw AppThemeEditingError.invalid(
                    "sidebar.mascot.placement must be \"leading\", \"center\" or \"trailing\"."
                )
            }
            mascot.placement = placement
        }
        let removing = try (patch.removePoses ?? []).map { raw -> ThemeMascotMood in
            guard let mood = ThemeMascotMood(rawValue: raw.trimmingCharacters(in: .whitespaces)) else {
                throw AppThemeEditingError.invalid(
                    "sidebar.mascot.remove_poses: \"\(raw)\" is not a mood — one of "
                        + ThemeMascotMood.allCases.map { "\"\($0.rawValue)\"" }
                            .joined(separator: ", ") + "."
                )
            }
            return mood
        }
        for (raw, posePatch) in patch.poses ?? [:] {
            guard let mood = ThemeMascotMood(rawValue: raw) else {
                throw AppThemeEditingError.invalid(
                    "sidebar.mascot.poses: \"\(raw)\" is not a mood — one of "
                        + ThemeMascotMood.allCases.map { "\"\($0.rawValue)\"" }
                            .joined(separator: ", ") + "."
                )
            }
            guard !removing.contains(mood) else {
                throw AppThemeEditingError.invalid(
                    "sidebar.mascot cannot set and remove the \(mood.rawValue) pose in the same patch."
                )
            }
            mascot.poses[mood] = try Self.pose(
                posePatch,
                base: mascot.poses[mood],
                mood: mood,
                themeID: themeID,
                kind: kind
            )
        }
        for mood in removing { mascot.poses[mood] = nil }
        return mascot
    }

    private static func pose(
        _ patch: AppThemeMascotPoseArguments,
        base: ThemeMascot.Pose?,
        mood: ThemeMascotMood,
        themeID: AppThemeID,
        kind: AppTheme.VariantKind
    ) throws -> ThemeMascot.Pose {
        let field = "sidebar.mascot.poses.\(mood.rawValue)"
        let asset: String
        if let source = patch.source {
            let data = try Self.imageBytes(
                source,
                describing: "\(field).source",
                maximumBytes: ThemeMascotLimits.maximumImageBytes
            )
            guard let stored = ThemeAssetStore.storeMascotPose(
                imageData: data,
                for: themeID,
                mood: mood,
                variant: kind
            ) else {
                throw AppThemeEditingError.invalid("\(field).source is not a readable image.")
            }
            asset = stored
        } else if let existing = base?.asset {
            asset = existing
        } else {
            throw AppThemeEditingError.invalid(
                "\(field) is new and needs a source: {path} or {base64}."
            )
        }
        guard patch.particles == nil || patch.removeParticles != true else {
            throw AppThemeEditingError.invalid(
                "\(field) cannot set particles and remove_particles in the same patch."
            )
        }
        var pose = base ?? ThemeMascot.Pose(asset: asset)
        pose.asset = asset
        if let raw = cleaned(patch.motion) {
            if raw == "none" {
                pose.motion = nil
            } else {
                guard let motion = ThemeMascot.Motion(rawValue: raw) else {
                    throw AppThemeEditingError.invalid(
                        "\(field).motion must be \"none\" or one of "
                            + ThemeMascot.Motion.allCases.map { "\"\($0.rawValue)\"" }
                                .joined(separator: ", ") + "."
                    )
                }
                pose.motion = motion
            }
        }
        if let every = patch.every { pose.every = every }
        if patch.removeParticles == true {
            pose.particles = nil
        } else if let particles = patch.particles {
            pose.particles = try Self.particles(
                particles,
                base: pose.particles,
                field: "\(field).particles"
            )
        }
        if let origin = patch.origin {
            let current = pose.resolvedOrigin
            pose.origin = SidebarStyle.Brand.LogoMotion.Origin(
                x: origin.x ?? current.x,
                y: origin.y ?? current.y
            )
        }
        return pose
    }

    static func document(_ mascot: ThemeMascot) -> [String: Any] {
        var poses: [String: Any] = [:]
        for (mood, pose) in mascot.poses {
            var fields: [String: Any] = ["asset": pose.asset]
            if let motion = pose.motion { fields["motion"] = motion.rawValue }
            if let every = pose.every { fields["every"] = every }
            if let particles = pose.particles { fields["particles"] = Self.document(particles) }
            if let origin = pose.origin { fields["origin"] = ["x": origin.x, "y": origin.y] }
            poses[mood.rawValue] = fields
        }
        return [
            "size": mascot.size,
            "placement": mascot.placement.rawValue,
            "poses": poses
        ]
    }

    // MARK: - Moments

    static func moments(
        _ patch: AppThemeMomentsArguments?,
        remove: Bool?,
        base: ThemeMoments?,
        themeID: AppThemeID,
        kind: AppTheme.VariantKind
    ) throws -> AppThemeEditing.BlockChange<ThemeMoments> {
        if remove == true {
            guard patch == nil else {
                throw AppThemeEditingError.invalid(
                    "moments cannot be set and removed in the same patch."
                )
            }
            return .remove
        }
        guard let patch else { return .inherit }
        var moments = base ?? ThemeMoments()
        let stated: [(ThemeMomentEvent, AppThemeMomentArguments?)] = [
            (.turnFinished, patch.turnFinished),
            (.needsAttention, patch.needsAttention)
        ]
        for case let (event, momentPatch?) in stated {
            moments[event] = try Self.moment(
                momentPatch,
                base: moments[event],
                event: event,
                themeID: themeID,
                kind: kind
            )
        }
        return moments.isEmpty ? .remove : .set(moments)
    }

    private static func moment(
        _ patch: AppThemeMomentArguments,
        base: ThemeMoments.Moment?,
        event: ThemeMomentEvent,
        themeID: AppThemeID,
        kind: AppTheme.VariantKind
    ) throws -> ThemeMoments.Moment? {
        let field = "moments.\(event.rawValue)"
        if patch.remove == true {
            guard patch.particles == nil, patch.sound == nil else {
                throw AppThemeEditingError.invalid(
                    "\(field) cannot set fields and remove in the same patch."
                )
            }
            return nil
        }
        guard patch.particles == nil || patch.removeParticles != true else {
            throw AppThemeEditingError.invalid(
                "\(field) cannot set particles and remove_particles in the same patch."
            )
        }
        guard patch.sound == nil || patch.removeSound != true else {
            throw AppThemeEditingError.invalid(
                "\(field) cannot set sound and remove_sound in the same patch."
            )
        }
        guard event.showsParticles || (patch.particles == nil && patch.duration == nil) else {
            throw AppThemeEditingError.invalid(
                "\(field) takes a sound only — turns finish many times an hour, so a shower "
                    + "across the window on each one is too much. The sidebar mascot's "
                    + "celebrating pose is the picture of a finished turn."
            )
        }
        var moment = base ?? ThemeMoments.Moment()
        if patch.removeParticles == true {
            moment.particles = nil
        } else if let particles = patch.particles {
            moment.particles = try Self.particles(
                particles,
                base: moment.particles,
                field: "\(field).particles"
            )
        }
        // Files are never deleted here: a refused update restores the document, and a document
        // naming a file this parse had removed would be left pointing at nothing. A container
        // change leaves the old file in the theme's folder until the theme is deleted.
        if patch.removeSound == true {
            moment.sound = nil
        } else if let sound = patch.sound {
            let (data, format) = try Self.soundBytes(sound, describing: "\(field).sound")
            guard let stored = ThemeAssetStore.storeSound(
                data: data,
                for: themeID,
                event: event,
                variant: kind,
                pathExtension: format
            ) else {
                throw AppThemeEditingError.invalid(
                    "\(field).sound is not a playable sound of at most "
                        + "\(Int(ThemeMomentLimits.maximumSoundSeconds)) seconds in a "
                        + ThemeMomentLimits.soundExtensions.sorted().joined(separator: ", ")
                        + " container."
                )
            }
            moment.sound = stored
        }
        // Rebuilt rather than assigned: this is a document's number, not an animation's, and
        // the motion lint reads any `.duration =` under UI/ as the latter.
        let merged = ThemeMoments.Moment(
            particles: moment.particles,
            duration: patch.duration ?? moment.duration,
            sound: moment.sound
        )
        return merged.isEmpty ? nil : merged
    }

    /// A sound's bytes and container, from a path (its extension names the container) or from
    /// base64 with `format`.
    static func soundBytes(
        _ source: AppThemeSoundArguments,
        describing field: String
    ) throws -> (Data, String) {
        let maximum = ThemeMomentLimits.maximumSoundBytes
        if let rawPath = cleaned(source.path) {
            let path = (rawPath as NSString).expandingTildeInPath
            let format = (cleaned(source.format) ?? (path as NSString).pathExtension).lowercased()
            let data: Data
            do {
                data = try BoundedFileReader.read(URL(fileURLWithPath: path), maximumBytes: maximum)
            } catch BoundedFileReadError.exceedsLimit(maximumBytes: _) {
                throw AppThemeEditingError.invalid(
                    "\(field): file exceeds \(maximum / (1024 * 1024)) MB."
                )
            } catch {
                throw AppThemeEditingError.invalid("\(field): no readable file at \(path).")
            }
            return (data, format)
        }
        if let base64 = cleaned(source.base64) {
            guard let format = cleaned(source.format)?.lowercased() else {
                throw AppThemeEditingError.invalid(
                    "\(field): base64 needs a format — "
                        + ThemeMomentLimits.soundExtensions.sorted().joined(separator: ", ") + "."
                )
            }
            guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
                throw AppThemeEditingError.invalid("\(field): base64 did not decode.")
            }
            guard data.count <= maximum else {
                throw AppThemeEditingError.invalid(
                    "\(field): sound exceeds \(maximum / (1024 * 1024)) MB."
                )
            }
            return (data, format)
        }
        throw AppThemeEditingError.invalid("\(field): provide {path} or {base64, format}.")
    }

    static func document(_ moments: ThemeMoments) -> [String: Any] {
        var document: [String: Any] = [:]
        for event in ThemeMomentEvent.allCases {
            guard let moment = moments[event] else { continue }
            var fields: [String: Any] = [:]
            // Duration times a shower; an event that takes none has nothing to report.
            if event.showsParticles { fields["duration"] = moment.duration }
            if let particles = moment.particles { fields["particles"] = Self.document(particles) }
            if let sound = moment.sound { fields["sound"] = ["asset": sound] }
            document[event.rawValue] = fields
        }
        return document
    }

    // MARK: - Words

    static func words(
        _ patch: AppThemeWordsArguments?,
        remove: Bool?,
        base: ThemeWords?
    ) throws -> AppThemeEditing.BlockChange<ThemeWords> {
        if remove == true {
            guard patch == nil else {
                throw AppThemeEditingError.invalid(
                    "words cannot be set and removed in the same patch."
                )
            }
            return .remove
        }
        guard let patch else { return .inherit }
        guard patch.working == nil || patch.removeWorking != true else {
            throw AppThemeEditingError.invalid(
                "words cannot set working and remove_working in the same patch."
            )
        }
        guard patch.composerPlaceholder == nil || patch.removeComposerPlaceholder != true else {
            throw AppThemeEditingError.invalid(
                "words cannot set composer_placeholder and remove_composer_placeholder in the same patch."
            )
        }
        var words = base ?? ThemeWords()
        if patch.removeWorking == true {
            words.working = []
        } else if let working = patch.working {
            words.working = working.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        if patch.removeComposerPlaceholder == true {
            words.composerPlaceholder = nil
        } else if let placeholder = patch.composerPlaceholder {
            words.composerPlaceholder = placeholder.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return words.isEmpty ? .remove : .set(words)
    }

    static func document(_ words: ThemeWords) -> [String: Any] {
        var document: [String: Any] = [:]
        if !words.working.isEmpty { document["working"] = words.working }
        if let placeholder = words.composerPlaceholder {
            document["composer_placeholder"] = placeholder
        }
        return document
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
}
