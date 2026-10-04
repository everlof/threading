import AppKit
import ImageIO
import SwiftTerm

// MARK: - App Theme Preview Service

/// Draws an app theme on a sample window and hands back the PNG — `preview_app_theme`.
///
/// Built so an agent that authored a theme can *look* at it, which it otherwise cannot: the
/// real window is the user's, a screenshot of it needs Screen Recording and would carry their
/// projects and conversations, and an adaptive theme only ever shows one of its two variants.
/// So the sample is assembled from the components the real window uses — the sidebar's ground,
/// band and brand, a pane on the broad ground, a card, buttons, the paired terminal colours —
/// around invented rows, in whichever appearances the theme has.
///
/// **The theme is worn for the length of one synchronous render and no longer.** Components
/// resolve through `AppThemePalette.current`, so the palette is swapped, the sample is built,
/// laid out and drawn with `cacheDisplay`, and the palette is put back — all inside one main
/// actor turn, so no display pass of the real window can land in between and nothing is
/// recorded or posted. Motion is drawn as its still frame (`ThemeParticleHold.withStillFrames`),
/// because a live emitter's particles exist only in the render server and no capture here can
/// see them; a logo's plume is stamped where a running stream would have put it.
@MainActor
enum AppThemePreviewService {

    private enum Layout {
        static let size = NSSize(width: 760, height: 470)
        static let sidebarWidth: CGFloat = 250
        /// Where the real window's toolbar strip sits over the sidebar's top.
        static let titlebarHeight: CGFloat = 32
        static let rowHeight: CGFloat = 26
        static let terminalHeight: CGFloat = 112
        static let scale: CGFloat = 1.5
        /// The mascot's moods drawn small along the pane, above the terminal sample.
        static let moodFigureHeight: CGFloat = 48
        /// `frames: 3` draws the drift at evenly spaced phases of one authored cycle.
        static let driftFrameCount = 3
        static let driftPhases: [Double] = (0..<driftFrameCount).map { Double($0) / Double(driftFrameCount) }
    }

    // MARK: - Public Methods

    static func preview(
        _ arguments: PreviewAppThemeArguments,
        completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
    ) {
        let theme: AppTheme
        if let raw = arguments.themeID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            guard let found = AppThemeLibrary.theme(withID: AppThemeID(raw)) else {
                completion(.failure(
                    "No app theme has id \"\(raw)\". Call list_app_themes for stable IDs."
                ))
                return
            }
            theme = found
        } else {
            theme = AppThemeLibrary.current
        }

        let available: [AppTheme.VariantKind] = theme.isSystem
            ? AppTheme.VariantKind.allCases
            : theme.availableVariants
        let kinds: [AppTheme.VariantKind]
        switch arguments.appearance?.lowercased() {
        case "light": kinds = available.contains(.light) ? [.light] : []
        case "dark": kinds = available.contains(.dark) ? [.dark] : []
        case nil, "", "both": kinds = available
        default:
            completion(.failure("appearance must be \"light\", \"dark\", or \"both\"."))
            return
        }
        guard !kinds.isEmpty else {
            completion(.failure("\(theme.name) has no \(arguments.appearance ?? "") variant."))
            return
        }
        let count = arguments.frames ?? 1
        guard count == 1 || count == Layout.driftFrameCount else {
            completion(.failure("frames must be 1 or \(Layout.driftFrameCount).")); return
        }

        // Drawn here, where the views live; encoded on a worker, where PNG compression belongs.
        guard let image = render(theme, kinds: kinds, frameCount: count) else {
            completion(.failure("The preview could not be drawn."))
            return
        }
        let text = "Preview of \(theme.name) (\(theme.id.rawValue)), "
            + kinds.map(\.rawValue).joined(separator: " and ")
            + ", drawn on a sample window — top to bottom in that order. Particles are shown "
            + "as a still frame."
            + (count == Layout.driftFrameCount ? " Each appearance shows its gradient drift at 0, ⅓ and ⅔ of one cycle." : "")
        Task {
            let png = await Task.detached(priority: .userInitiated) { pngData(image) }.value
            guard let png else {
                completion(.failure("The preview could not be encoded."))
                return
            }
            completion(.screenshot(text, pngData: png, includeImage: true))
        }
    }

    /// The sample, one band per appearance stacked top to bottom.
    static func render(_ theme: AppTheme, kinds: [AppTheme.VariantKind], frameCount: Int = 1) -> CGImage? {
        guard frameCount == 1 || frameCount == Layout.driftFrameCount else { return nil }
        let previous = AppThemePalette.current
        AppThemePalette.set(theme)
        defer { AppThemePalette.set(previous) }

        // Phases are fractions of the authored cycle, whatever its length: fixed seconds moved
        // a default 24-second drift by 4% of a cycle, which reads as three identical frames.
        // Phase 1 is phase 0 again, so the samples stop a third short of it.
        let phases = frameCount == Layout.driftFrameCount ? Layout.driftPhases : [0]
        let frames: [CGImage] = kinds.flatMap { kind -> [CGImage] in
            guard let appearance = kind.appearance else { return [] }
            return phases.compactMap { phase in
                ThemeParticleHold.withStillFrames(phase: phase) {
                    renderFrame(theme: theme, kind: kind, appearance: appearance)
                }
            }
        }
        guard !frames.isEmpty else { return nil }

        let width = frames.map(\.width).max() ?? 0
        let height = frames.map(\.height).reduce(0, +)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        var top = height
        for frame in frames {
            top -= frame.height
            context.draw(frame, in: CGRect(x: 0, y: top, width: frame.width, height: frame.height))
        }
        return context.makeImage()
    }

    /// PNG bytes through ImageIO, which is safe off the main actor.
    nonisolated static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            "public.png" as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    // MARK: - Private Methods

    private static func renderFrame(
        theme: AppTheme,
        kind: AppTheme.VariantKind,
        appearance: NSAppearance
    ) -> CGImage? {
        var result: CGImage?
        appearance.performAsCurrentDrawingAppearance {
            let host = NSView(frame: NSRect(origin: .zero, size: Layout.size))
            host.wantsLayer = true
            host.appearance = appearance

            let sidebar = makeSidebar(theme: theme)
            let content = makeContent(theme: theme, kind: kind)
            host.addSubview(content)
            host.addSubview(sidebar)
            NSLayoutConstraint.activate([
                sidebar.topAnchor.constraint(equalTo: host.topAnchor),
                sidebar.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                sidebar.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                sidebar.widthAnchor.constraint(equalToConstant: Layout.sidebarWidth),
                content.topAnchor.constraint(equalTo: host.topAnchor),
                content.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                content.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
                content.trailingAnchor.constraint(equalTo: host.trailingAnchor)
            ])
            if let style = WindowChromeAppearance.resolve(for: appearance) {
                let band = WindowTitleBandView()
                band.fixtureStyle = style
                band.fixtureIsKey = true
                band.setTitle(theme.name)
                host.addSubview(band)
                NSLayoutConstraint.activate([
                    band.topAnchor.constraint(equalTo: host.topAnchor),
                    band.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                    band.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                    band.heightAnchor.constraint(equalToConstant: style.bandHeight)
                ])
            }
            host.layoutSubtreeIfNeeded()
            repaintTree(host)
            host.layoutSubtreeIfNeeded()

            // The rep AppKit makes for caching this view carries the colour space it actually
            // draws in; drawing it into the sRGB canvas below converts it properly. A hand-made
            // device-RGB rep did not: it received display-gamut values under a generic tag, and
            // a stated #E4000F came out an orange-red.
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)

            let width = Int(Layout.size.width * Layout.scale)
            let height = Int(Layout.size.height * Layout.scale)
            guard let drawn = rep.cgImage,
                  let context = CGContext(
                    data: nil,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return }
            context.interpolationQuality = .high
            context.draw(drawn, in: CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: Layout.scale, y: Layout.scale)

            stampLogoPlume(in: host, context: context, appearance: appearance)
            stampMascotPlumes(in: host, context: context)
            drawTerminal(theme: theme, kind: kind, in: context)
            result = context.makeImage()
        }
        return result
    }

    /// The sidebar the real window wears, around invented rows.
    private static func makeSidebar(theme: AppTheme) -> NSView {
        let column = NSView()
        column.translatesAutoresizingMaskIntoConstraints = false

        let backdrop = SidebarBackdropView()
        let band = SidebarBrandBandView()
        let brand = SidebarBrandView()
        let add = ThemedIconButton(
            symbolName: "plus",
            accessibility: L10n.string("Add Project"),
            target: .inline,
            inkSource: .chrome
        )
        let arrange = ThemedIconButton(
            symbolName: SidebarDefaults.arrangementSymbol,
            accessibility: SidebarStrings.arrangementOptions,
            target: .inline,
            inkSource: .chrome
        )
        let header = PaneHeaderView(leading: [brand], trailing: [add, arrange], margin: .paneEdge)
        band.onApply = { onBand in
            add.hostGround = onBand ? .brandBand : nil
            arrange.hostGround = onBand ? .brandBand : nil
        }

        column.addSubview(backdrop)
        column.addSubview(band)
        column.addSubview(header)

        // The real sidebar's stacking, bottom to top: the ground and its dressing, the mascot
        // standing on the column's foot, the navigator well, then the rows. A preview that drew
        // the mascot over the well showed a dog the real window hid.
        let appearance = NSAppearance.currentDrawing()
        if let mascot = SidebarAppearance.mascot(for: appearance) {
            let figure = mascotFigure(mascot, mood: .idle)
            column.addSubview(figure)
            let inset = Design.Spacing.medium
            var constraints = [
                figure.bottomAnchor.constraint(equalTo: column.bottomAnchor, constant: -Design.Spacing.small)
            ]
            switch mascot.spec.placement {
            case .leading:
                constraints.append(figure.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: inset))
            case .center:
                constraints.append(figure.centerXAnchor.constraint(equalTo: column.centerXAnchor))
            case .trailing:
                constraints.append(figure.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -inset))
            }
            NSLayoutConstraint.activate(constraints)
        }
        if let well = SidebarAppearance.navigatorWell(for: appearance) {
            let wellView = ThemedSurfaceView()
            wellView.translatesAutoresizingMaskIntoConstraints = false
            wellView.applySurface(fill: well.fill, radius: .fixed(0), bevel: well.bevel)
            column.addSubview(wellView)
            NSLayoutConstraint.activate([
                wellView.topAnchor.constraint(equalTo: header.bottomAnchor),
                wellView.bottomAnchor.constraint(equalTo: column.bottomAnchor),
                wellView.leadingAnchor.constraint(equalTo: column.leadingAnchor),
                wellView.trailingAnchor.constraint(equalTo: column.trailingAnchor)
            ])
        }

        let rows = NSStackView(views: sampleRows())
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0
        rows.translatesAutoresizingMaskIntoConstraints = false
        column.addSubview(rows)

        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: column.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: column.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            header.topAnchor.constraint(equalTo: column.topAnchor, constant: Layout.titlebarHeight),
            header.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            band.topAnchor.constraint(equalTo: column.topAnchor),
            band.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            band.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            band.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            rows.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Design.Spacing.small),
            rows.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: column.trailingAnchor)
        ])
        return column
    }

    /// A mascot standing in its box at its stated size, showing `mood`.
    private static func mascotFigure(
        _ mascot: SidebarAppearance.Mascot,
        mood: ThemeMascotMood,
        height: CGFloat? = nil
    ) -> ThemeMascotView {
        let figure = ThemeMascotView()
        let tall = height ?? CGFloat(mascot.spec.size)
        NSLayoutConstraint.activate([
            figure.heightAnchor.constraint(equalToConstant: tall),
            figure.widthAnchor.constraint(equalToConstant: (tall * mascot.aspectRatio).rounded())
        ])
        figure.configure(mascot, mood: mood, fallbackMood: .idle)
        return figure
    }

    /// Every mood the mascot draws a pose of its own for, side by side with the mood's name —
    /// how an author checks the cast without waiting for an agent to finish a turn.
    private static func mascotMoods() -> NSView? {
        guard let mascot = SidebarAppearance.mascot(for: NSAppearance.currentDrawing()) else {
            return nil
        }
        let cells: [NSView] = ThemeMascotMood.allCases.compactMap { mood in
            guard mascot.poses[mood] != nil else { return nil }
            let figure = mascotFigure(mascot, mood: mood, height: Layout.moodFigureHeight)
            let name = NSTextField(labelWithString: mood.rawValue)
            name.applyFont(.caption)
            name.textColor = Design.Text.secondary
            let cell = NSStackView(views: [figure, name])
            cell.orientation = .vertical
            cell.alignment = .centerX
            cell.spacing = Design.Spacing.tight
            return cell
        }
        guard !cells.isEmpty else { return nil }
        let strip = NSStackView(views: cells)
        strip.orientation = .horizontal
        strip.alignment = .bottom
        strip.spacing = Design.Spacing.large
        return strip
    }

    /// Invented rows — a project and its chats, one of them selected — so the sample carries
    /// nothing of the user's.
    private static func sampleRows() -> [NSView] {
        let entries: [(String, Bool, Bool)] = [
            ("Sample Project", true, false),
            ("Design the landing page", false, false),
            ("Fix the login redirect", false, true),
            (ThemeWording.untitledSessionName(for: NSAppearance.current) ?? L10n.string("New Session"), false, false),
            ("Another Project", true, false),
            ("Profile the importer", false, false)
        ]
        return entries.map { title, isProject, isSelected in
            let row = ThemedSurfaceView()
            row.translatesAutoresizingMaskIntoConstraints = false
            if isSelected {
                row.applySurface(fill: Design.Surface.selectionFill, radius: .control)
            }
            let label = NSTextField(labelWithString: title)
            label.translatesAutoresizingMaskIntoConstraints = false
            label.applyFont(isProject ? .caption : .body)
            // A selected row is drawn in the selection's own ink, as the real list draws it.
            label.textColor = isSelected
                ? Design.Ink.selection.label
                : (isProject ? Design.Text.secondary : Design.Text.label)
            let mark = GlyphView()
            let tinted = IdentityMarkInk.isTinted(for: NSAppearance.current)
            mark.slot = NSSize(width: AgentIconDefaults.pointSize, height: AgentIconDefaults.pointSize)
            if isProject {
                mark.image = GeneratedProjectIcon.image(for: title, tint: tinted ? IdentityMarkInk.ink : nil)
            } else {
                let image = AgentKind.claude.icon?.copy() as? NSImage
                if tinted { image?.isTemplate = true }
                mark.image = image
            }
            mark.tint = tinted
                ? (isSelected ? Design.Ink.selection.label : IdentityMarkInk.ink)
                : Design.Text.secondary
            row.addSubview(mark)
            row.addSubview(label)
            NSLayoutConstraint.activate([
                mark.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: Design.Spacing.small),
                mark.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                mark.widthAnchor.constraint(equalToConstant: AgentIconDefaults.pointSize),
                mark.heightAnchor.constraint(equalToConstant: AgentIconDefaults.pointSize),
                label.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -Design.Spacing.small),
                row.heightAnchor.constraint(equalToConstant: Layout.rowHeight),
                row.widthAnchor.constraint(equalToConstant: Layout.sidebarWidth - Design.Spacing.medium * 2),
                label.leadingAnchor.constraint(
                    equalTo: mark.trailingAnchor,
                    constant: Design.Spacing.small
                ),
                label.centerYAnchor.constraint(equalTo: row.centerYAnchor)
            ])
            let inset = NSView()
            inset.translatesAutoresizingMaskIntoConstraints = false
            inset.addSubview(row)
            NSLayoutConstraint.activate([
                row.topAnchor.constraint(equalTo: inset.topAnchor),
                row.bottomAnchor.constraint(equalTo: inset.bottomAnchor),
                row.leadingAnchor.constraint(equalTo: inset.leadingAnchor, constant: Design.Spacing.medium),
                inset.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: Design.Spacing.medium)
            ])
            return inset
        }
    }

    /// A pane on the broad ground — backdrop, pattern and particles — with a card and actions.
    private static func makeContent(theme: AppTheme, kind: AppTheme.VariantKind) -> NSView {
        let pane = ThemedSurfaceView()
        pane.translatesAutoresizingMaskIntoConstraints = false
        pane.applySurface(fill: Design.Surface.ground, radius: .fixed(0), pattern: .backdrop)

        let caption = NSTextField(labelWithString: "\(theme.name) · \(kind.rawValue)")
        caption.applyFont(.caption)
        caption.textColor = Design.Text.secondary

        let card = ThemedSurfaceView()
        card.applySurface(fill: Design.Surface.panel, radius: .panel, border: Design.Surface.border)
        // localization-ignore: sample copy drawn only into the agent's preview image
        let heading = NSTextField(labelWithString: "A card on the pane")
        heading.applyFont(.heading)
        heading.textColor = Design.Text.label
        // localization-ignore: sample copy drawn only into the agent's preview image
        let body = NSTextField(wrappingLabelWithString:
            "Body text sits here at the size a conversation reads. Secondary detail follows.")
        body.applyFont(.body)
        body.textColor = Design.Text.label
        // localization-ignore: sample copy drawn only into the agent's preview image
        let detail = NSTextField(labelWithString: "Updated just now · 3 files changed")
        detail.applyFont(.caption)
        detail.textColor = Design.Text.tertiary
        // localization-ignore: sample copy drawn only into the agent's preview image
        let primary = ThemedButton(title: "Continue", target: nil, action: nil)
        primary.emphasis = .primary
        // localization-ignore: sample copy drawn only into the agent's preview image
        let secondary = ThemedButton(title: "Cancel", target: nil, action: nil)
        let actions = NSStackView(views: [primary, secondary])
        actions.orientation = .horizontal
        actions.spacing = Design.Spacing.small

        let composer = ThemedTextField()
        composer.placeholderString = ThemeWording.composerPlaceholder(for: NSAppearance.current)
            ?? L10n.string("Write a message…")
        let cardStack = NSStackView(views: [heading, body, detail, composer, actions])
        cardStack.orientation = .vertical
        cardStack.alignment = .leading
        cardStack.spacing = Design.Spacing.small
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(cardStack)

        let column = NSStackView(views: [caption, card] + [mascotMoods()].compactMap { $0 })
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Design.Spacing.medium
        column.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(column)

        NSLayoutConstraint.activate([
            cardStack.topAnchor.constraint(equalTo: card.topAnchor, constant: Design.Spacing.inset),
            cardStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Design.Spacing.inset),
            cardStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Design.Spacing.inset),
            cardStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Design.Spacing.inset),
            body.widthAnchor.constraint(equalTo: cardStack.widthAnchor),
            composer.widthAnchor.constraint(equalTo: cardStack.widthAnchor),
            card.widthAnchor.constraint(equalTo: column.widthAnchor),
            column.topAnchor.constraint(
                equalTo: pane.topAnchor,
                constant: Layout.titlebarHeight + Design.Spacing.medium
            ),
            column.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: Design.Spacing.large),
            column.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -Design.Spacing.large)
        ])
        return pane
    }

    /// Where a running logo stream would be a moment after it began.
    private static func stampLogoPlume(in host: NSView, context: CGContext, appearance: NSAppearance) {
        guard let motion = SidebarAppearance.brand(for: appearance).motion,
              let particles = motion.particles,
              let logo = descendant(of: host, as: ThemeLogoView.self),
              !logo.isHidden else { return }
        let frame = logo.convert(logo.bounds, to: host)
        let unit = motion.spec.resolvedOrigin
        let origin = CGPoint(
            x: frame.minX + frame.width * CGFloat(unit.x),
            y: frame.maxY - frame.height * CGFloat(unit.y)
        )
        ThemeParticleStill.plume(
            particles: particles.spec,
            colors: particles.colors,
            sprites: particles.sprites,
            origin: origin,
            in: context,
            up: 1
        )
    }

    /// Where each mascot's pose stream would be a moment after it began.
    private static func stampMascotPlumes(in host: NSView, context: CGContext) {
        for figure in descendants(of: host, as: ThemeMascotView.self) where !figure.isHidden {
            guard let pose = figure.pose, let particles = pose.particles else { continue }
            let frame = figure.convert(figure.bounds, to: host)
            let unit = pose.spec.resolvedOrigin
            let origin = CGPoint(
                x: frame.minX + frame.width * CGFloat(unit.x),
                y: frame.maxY - frame.height * CGFloat(unit.y)
            )
            ThemeParticleStill.plume(
                particles: particles.spec,
                colors: particles.colors,
                sprites: particles.sprites,
                origin: origin,
                in: context,
                up: 1
            )
        }
    }

    /// The paired terminal palette as a few lines of a session, drawn along the pane's foot.
    private static func drawTerminal(theme: AppTheme, kind: AppTheme.VariantKind, in context: CGContext) {
        let palette = theme.variant(kind)?.terminalPalette ?? theme.terminalPalette
        let frame = CGRect(
            x: Layout.sidebarWidth + Design.Spacing.large,
            y: Design.Spacing.large,
            width: Layout.size.width - Layout.sidebarWidth - Design.Spacing.large * 2,
            height: Layout.terminalHeight
        )
        // Capture the terminal itself: caching its parent can produce coloured grounds with
        // no text. This is the shipping SwiftTerm glow underlay, including ANSI run colours.
        let terminal = TerminalView(
            frame: CGRect(origin: .zero, size: frame.size),
            font: Design.Typography.code()
        )
        let window = NSWindow(contentRect: terminal.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = terminal
        terminal.suspendsRenderingWhenNotVisible = false
        terminal.installColors(palette.asSwiftTermColors())
        terminal.nativeForegroundColor = palette.foreground
        terminal.nativeBoldForegroundColor = palette.boldForeground
        terminal.nativeBackgroundColor = palette.background
        terminal.textGlow = palette.glow?.textGlow
        terminal.feed(text: "\u{1B}[?25l\u{1B}[34m~/sample \u{1B}[32m❯ \u{1B}[0mgit status\r\n"
            + "\u{1B}[31mmodified: \u{1B}[0mSources/App.swift\r\n"
            + "\u{1B}[33mwarning: \u{1B}[0m2 files unstaged\r\n"
            + "\u{1B}[1mBuild succeeded\u{1B}[0m  \u{1B}[90m0 errors\u{1B}[0m")
        terminal.prepareFrameForSnapshot()
        guard let bitmap = terminal.bitmapImageRepForCachingDisplay(in: terminal.bounds) else { return }
        terminal.cacheDisplay(in: terminal.bounds, to: bitmap)
        terminal.cacheDisplay(in: terminal.bounds, to: bitmap)
        context.setFillColor(palette.background.cgColor)
        context.fill(frame)
        if let image = bitmap.cgImage { context.draw(image, in: frame) }
        withExtendedLifetime(window) {}
    }

    /// Every recorded surface, layer colour and font in the sample restated under the swapped
    /// palette — the scoped half of the app-wide sweep, which would reach the real window.
    private static func repaintTree(_ view: NSView) {
        AppThemeRefresh.repaint(view)
        for subview in view.subviews {
            repaintTree(subview)
        }
    }

    private static func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        view.subviews.flatMap { subview -> [T] in
            ((subview as? T).map { [$0] } ?? []) + descendants(of: subview, as: type)
        }
    }

    private static func descendant<T: NSView>(of view: NSView, as type: T.Type) -> T? {
        for subview in view.subviews {
            if let match = subview as? T { return match }
            if let nested = descendant(of: subview, as: type) { return nested }
        }
        return nil
    }
}
