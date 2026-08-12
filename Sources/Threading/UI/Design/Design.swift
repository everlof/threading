import AppKit
import CoreText

/// The app's design tokens.
///
/// Every measurement, weight and surface colour used by Threading's own views comes from here,
/// so new UI inherits the established look by reaching for a token rather than inventing a
/// number. Values are deliberately few: a small scale that gets reused reads as deliberate,
/// where a large one reads as noise.
///
/// The vocabulary this encodes:
///
/// - **Flat over bezelled.** Controls are pills and panels with a subtle fill, not framed
///   form fields. Stock `NSPopUpButton`/`NSBox` bezels are heavier than anything here and
///   pull attention away from content.
/// - **Quiet until relevant.** Surfaces rest below full opacity and lift on hover; controls
///   offering a single option hide rather than showing a dead menu.
/// - **Content leads.** One element per view carries emphasis — usually the thing being
///   typed into or read. Everything else is secondary or tertiary label colour.
@MainActor
enum Design {

    // MARK: - Spacing

    /// A 2/4/6/10/12/20/32 scale. Anything between these is almost always a mistake.
    enum Spacing {
        /// Between a label and the line directly under it.
        static let hairline: CGFloat = 2
        static let tight: CGFloat = 4
        /// Between sibling controls in a row, such as chips.
        static let small: CGFloat = 6
        /// Between stacked elements inside one group.
        static let medium: CGFloat = 10
        /// Inside a container, between its edge and its content.
        static let inset: CGFloat = 12
        /// Between groups that belong to the same section.
        static let large: CGFloat = 20
        /// Between a view's content and the edge of its pane.
        static let pane: CGFloat = 32
    }

    // MARK: - Radius

    @MainActor
    enum Radius {
        /// Panels, prompt boxes, anything holding content.
        ///
        /// Read from the current theme rather than fixed, because a style's silhouette carries
        /// as much of its identity as its palette — Swiss Minimalist is hard edges, and two
        /// themes sharing one geometry read as one app in two tints. The System theme returns
        /// exactly the values these were.
        static var panel: CGFloat { AppThemePalette.current.material.panelRadius }
        /// Smaller containers nested inside a panel.
        static var control: CGFloat { AppThemePalette.current.material.controlRadius }

        /// Hairline in most themes; a style may draw heavier rules.
        static var border: CGFloat {
            let themed = AppThemePalette.current.material.borderWidth
            return Accessibility.increasesContrast ? max(themed, 2) : themed
        }

        /// The border around compact controls. It inherits the structural rule weight unless
        /// the material states a separate measured control construction.
        static var controlBorder: CGFloat {
            let themed = AppThemePalette.current.material.resolvedControlBorderWidth
            return Accessibility.increasesContrast ? max(themed, 2) : themed
        }

        /// The control radius, kept a *rounded rect* at small sizes.
        ///
        /// A corner radius is only a corner while it is a fraction of the side. `control` is 8
        /// under the System theme, which on a 16pt square — a tab's × — is half the side, so it
        /// drew as a disc while the 20pt `+` beside it drew as a rounded square. Same token, two
        /// silhouettes, and no call site said anything about a circle. Anything comfortably
        /// larger than the radius is unaffected, so this changes small controls only.
        static func control(fitting size: CGSize) -> CGFloat {
            min(control, min(size.width, size.height) * cornerFitFraction)
        }

        /// How much of the shorter side a corner may take before the shape stops reading as a
        /// rounded rect. A third is the point at which a 16pt square still has flat edges.
        static let cornerFitFraction: CGFloat = 1.0 / 3.0

        /// Fully rounded, for pill-shaped controls of a known height.
        /// Fully rounded — unless a style says otherwise.
        ///
        /// A pill is a shape decision, and a theme that squares every panel and leaves five
        /// pills floating on it has two conventions on one screen. Swiss Minimalist squares
        /// its chips for the same reason it squares its cards: the grid is the idea. System
        /// keeps `height / 2` exactly.
        static func pill(height: CGFloat) -> CGFloat {
            AppThemePalette.current.isSystem ? height / 2 : min(height / 2, control)
        }
    }

    // MARK: - Size

    enum Size {
        /// Height of a pill control. Also drives its corner radius.
        static let chipHeight: CGFloat = 26
        /// Closed height of a compact chooser, authored by the active material.
        static var choiceHeight: CGFloat {
            AppThemePalette.current.material(
                for: NSApplication.shared.effectiveAppearance
            ).choiceHeight
        }
        /// A selected destination in a horizontal strip or a sidebar.
        static let tabHeight: CGFloat = 28
        static let sidebarTabHeight: CGFloat = 30
        static let tabIconSlot: CGFloat = 16

        /// The × on a tab, and anything else that raises a surface around a small mark.
        ///
        /// Sized so the hover surface has room *around* the glyph: at 16 the drawn mark filled
        /// its box to within a point and the highlight read as a smudge on the character rather
        /// than as a target under the pointer. It also matches `DisplayPaneDefaults.buttonSize`,
        /// which is the `+` at the other end of the same tab row.
        static let tabCloseTarget: CGFloat = 20

        /// An icon button nested inside another control — a tab's ×, a sidebar row's ⋯.
        ///
        /// The same target as `tabCloseTarget`, named for the role rather than for one of the
        /// places that has it: a row's `⋯` and a tab's `×` are the same control at the same size,
        /// and were 16 and 20 only because each was sized where it was used. The glyph is stated
        /// beside it so the padding between them — `(target - glyph) / 2` — is a decision taken
        /// once here rather than arithmetic at a call site. See `ThemedIconButton.Target`.
        static let inlineButtonTarget: CGFloat = tabCloseTarget
        static let inlineButtonGlyph: CGFloat = 12

        /// Compact controls floating in the transparent window toolbar.
        static let toolbarButtonWidth: CGFloat = 30
        static let toolbarButtonHeight: CGFloat = 28

        /// A single navigation action floating over scrollable content.
        ///
        /// Larger than an inline or toolbar target because it has no row around it to extend
        /// the hit area, and shared by Git Review and Native Chat so the same down-arrow never
        /// arrives at two sizes.
        static let floatingNavigationTarget: CGFloat = 40

        /// The chevron half of a split control — narrower than the press it is welded to.
        ///
        /// The two halves are not equals: one takes the action, the other offers the exceptions,
        /// and a chevron given the same 30 points as the icon reads as a second button that
        /// happens to be touching the first. Still comfortably above the pointer target the rest
        /// of the chrome uses, because it is full toolbar height. See `SplitIconButtonView`.
        static let splitMenuWidth: CGFloat = 24

        /// The split-menu half beside a compact composer send glyph. This pair is smaller than
        /// toolbar chrome because it lives inside the prompt footer rather than standing alone.
        static let compactSubmitHeight: CGFloat = 18
        static let compactSplitMenuWidth: CGFloat = 12

        /// A chrome-takeover window's own buttons — close, minimize, zoom — in the app-drawn
        /// title band. Wider than tall, the proportion every windowing system's buttons share,
        /// and sized to sit inside the band's default 28 points with air above and below.
        static let windowButtonWidth: CGFloat = 18
        static let windowButtonHeight: CGFloat = 16
        /// Height of a single-line text field — see `ThemedTextField`.
        ///
        /// Its own step rather than `chipHeight`, which it borrowed for as long as a field was
        /// "a chip you can type in". A chip holds a word at rest; a field holds a *caret*, and
        /// the theme's rule around it is two points thick on each side, so at 26 the twenty
        /// points left inside were carrying a thirteen-point face with barely three points of
        /// air above and below it — the text read as wedged against the border rather than set
        /// in a box. 32 leaves the same air a row of the list has.
        static let fieldHeight: CGFloat = 32

        /// Height of the prompt box and anything else that reads as a primary input.
        static let inputHeight: CGFloat = 44

        /// How far a growing input climbs before it scrolls instead. Roughly eight lines:
        /// enough for a paragraph, short of taking the pane over.
        static let inputMaxHeight: CGFloat = 180

        /// An image waiting in a prompt. Large enough to recognise the screenshot, still small
        /// enough for several to read as attachments rather than as the prompt's main content.
        static let promptAttachmentThumbnail: CGFloat = 80

        /// The title-and-controls band of an app-owned in-window inspector — the media one and
        /// the expanded comparison alike, so the two transient surfaces open at one height.
        static let inspectorHeaderHeight: CGFloat = 52

        /// A recognisable member of the inspector's collection rail.
        static let mediaInspectorThumbnail: CGFloat = 56

        /// The rail around those thumbnails, including its vertical breathing room.
        static let mediaInspectorRailHeight: CGFloat = 72

        /// Widest a column of content grows before it becomes hard to scan.
        static let readableWidth: CGFloat = 620

        /// The bottom band of a pane, holding its footer controls — see `PaneFooterView`.
        ///
        /// Deeper than the controls it holds, and deliberately: the band used to sit inside
        /// AppKit's own inset sidebar panel, which supplied a margin of its own below it.
        /// Flush to the window, that margin is the band's to provide — 32 put the row a few
        /// points off the window's rounded bottom corner, which reads as content about to
        /// fall out of the pane.
        static let footerHeight: CGFloat = 48

        /// The room a panel's halo needs inside any clipping ancestor.
        ///
        /// A theme's glow is a layer shadow, and a shadow spills *past* the view that casts
        /// it — so a scroll view whose edge coincides with a panel's edge cuts the halo off
        /// flat on that side, which is invisible in the code that set the shadow. Any host
        /// that clips and holds glowing panels budgets this much space between the panel and
        /// the clip edge. The gutter is constant across themes — layout never changes with
        /// the theme — and is sized to the widest glow any stock style states (twice its
        /// radius, the visible extent of the blur, plus its travel), pinned to that by
        /// `AppThemeTests`. Forty-eight is the measured Clay card shadow: a 16-point travel
        /// followed by a 16-point Core Animation radius (the 32px CSS blur it mirrors).
        static let glowGutter: CGFloat = 48
    }

    // MARK: - Typography

    /// A small semantic scale. Feature code chooses what text *does*, never an AppKit point
    /// size. Keeping even code, counters, placeholders, and decorative emoji here prevents a
    /// screen assembled from individually reasonable but mutually inconsistent 10/11/12/13pt
    /// decisions.
    @MainActor
    enum Typography {

        /// Which surface a font is being asked for, since two of them may be set differently.
        ///
        /// The terminal has always had its own font through `TerminalProfile`, so a natively
        /// rendered conversation — the same surface by a different transport — gets the same
        /// say. Everything else is chrome. This is a *parameter on the one transform*, not a
        /// second `Typography`: a parallel namespace would be two copies of twenty factories
        /// that have to keep agreeing.
        enum FontSurface {
            case chrome
            case conversation
        }

        /// Resolves the user's semantic text-size preference in the one place point sizes enter
        /// the design system. This reaches prose, code, aligned numerics, marks, and every
        /// host-rendered extension node while leaving an explicit terminal profile untouched.
        private static func scaled(_ pointSize: CGFloat) -> CGFloat {
            let material = AppThemePalette.current.material(
                for: NSApplication.shared.effectiveAppearance
            )
            return pointSize * material.textScale * AppSettings.appTextSize.scale
        }

        /// A prose font, resolved through the four layers that may have an opinion about it.
        ///
        /// This is the whole of the typeface interpreter, and the order is the design:
        ///
        /// 1. **The surface's own override** — `conversationFontFamily`, for the conversation.
        /// 2. **The app-wide override** — `chromeFontFamily`. A user who set only this gets it
        ///    everywhere, which is why the conversation falls through to it rather than to the
        ///    theme: "set the app in Iowan" should not leave the thread in SF.
        /// 3. **The theme's own family**, where it names one — a theme may be more specific than
        ///    the four classes its brief states.
        /// 4. **The theme's typeface class**, which is what a brief actually states.
        ///
        /// Every family lookup can fail, and none of them is an error: a family lives on the
        /// machine rather than in the document or the defaults, so a theme authored elsewhere or
        /// a font the user removed simply falls to the next layer. Failing *down* the list rather
        /// than to SF matters — a removed conversation font should leave the thread wearing the
        /// app's override, not reset it two layers.
        ///
        /// Code factories deliberately do not route through here — code is monospaced under
        /// every style — and numeric factories keep SF's monospaced digits, because a usage
        /// column that stops aligning is a higher price than a serif digit is worth.
        private static func prose(
            _ font: NSFont,
            surface: FontSurface = .chrome,
            headingStyle: AppTheme.Material.HeadingStyle? = nil,
            buttonStyle: AppTheme.Material.ButtonStyle? = nil
        ) -> NSFont {
            for family in overrideFamilies(for: surface) {
                if let resolved = inFamily(family, like: font) { return resolved }
            }

            // The **application's** appearance, not the ambient drawing one, for the same
            // reason `AppTheme.terminalPalette` anchors there: a font is consumed as data — a
            // label keeps the `NSFont` it was handed — from setup code and notification
            // handlers, where the ambient appearance is whatever AppKit last had in hand. An
            // adaptive theme whose variants state different faces would otherwise resolve the
            // wrong variant at build time. Radii and glow stay ambient: they are read while
            // drawing, where the ambient appearance is the right question.
            let material = AppThemePalette.current.material(
                for: NSApplication.shared.effectiveAppearance
            )
            if let headingStyle {
                if let family = headingStyle.fontFamily,
                   let resolved = inFamily(family, like: font) {
                    return resolved
                }
                if let typeface = headingStyle.typeface {
                    guard typeface != .standard else { return font }
                    if let descriptor = font.fontDescriptor.withDesign(typeface.systemDesign),
                       let themed = NSFont(descriptor: descriptor, size: font.pointSize) {
                        return themed
                    }
                }
            }
            if let buttonStyle {
                if let family = buttonStyle.fontFamily,
                   let resolved = inFamily(family, like: font) {
                    return resolved
                }
                if let typeface = buttonStyle.typeface {
                    guard typeface != .standard else { return font }
                    if let descriptor = font.fontDescriptor.withDesign(typeface.systemDesign),
                       let themed = NSFont(descriptor: descriptor, size: font.pointSize) {
                        return themed
                    }
                }
            }
            for family in material.fontFamilies {
                if let resolved = inFamily(family, like: font) { return resolved }
            }

            guard material.typeface != .standard else { return font }
            guard let descriptor = font.fontDescriptor.withDesign(material.typeface.systemDesign),
                  let themed = NSFont(descriptor: descriptor, size: font.pointSize) else {
                return font
            }
            return themed
        }

        /// Builds a display role before family resolution so its authored weight and slant
        /// survive a named-family substitution. User family overrides still win in `prose`;
        /// the theme is choosing display grammar, not overruling the reader's font choice.
        private static func heading(
            pointSize: CGFloat,
            defaultWeight: NSFont.Weight,
            surface: FontSurface
        ) -> NSFont {
            let style = AppThemePalette.current.material(
                for: NSApplication.shared.effectiveAppearance
            ).headingStyle
            var font = NSFont.systemFont(
                ofSize: pointSize,
                weight: style?.fontWeight?.appKitWeight ?? defaultWeight
            )
            if style?.italic == true {
                var traits = font.fontDescriptor.symbolicTraits
                traits.insert(.italic)
                let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
                if let italic = NSFont(descriptor: descriptor, size: font.pointSize) {
                    font = italic
                }
            }
            return prose(font, surface: surface, headingStyle: style)
        }

        /// The same font in another family, keeping its size, weight and slant — or `nil` when
        /// the family cannot answer, which is what lets the caller fall to the next layer.
        ///
        /// **Built from explicit attributes rather than `fontDescriptor.withFamily(_:)`**, and
        /// both halves of that were measured on macOS 26 rather than assumed. Asking a *system*
        /// font's descriptor for another family does nothing at all — the `NSCTFontUIUsage`
        /// attribute outranks the family, so `.systemFont(13).fontDescriptor.withFamily("Baskerville")`
        /// resolves back to `.AppleSystemUIFont` — which would have made every override look
        /// like it silently did not work. And an unknown family through that route hands back a
        /// *fallback* rather than `nil`, so there would be nothing to detect and nothing to fall
        /// through from. A descriptor built from `.family` + `.traits` does both correctly: it
        /// resolves `Baskerville-SemiBold` for a semibold ask, and returns `nil` for a family
        /// that is not installed.
        ///
        /// Italic is tried and then dropped, because a family that has no italic face is a
        /// reason to lose the slant, not a reason to lose the family the user chose.
        private static func inFamily(_ family: String, like font: NSFont) -> NSFont? {
            let source = font.fontDescriptor
            var weight: NSNumber?
            if let sourceTraits = source.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any] {
                weight = sourceTraits[.weight] as? NSNumber
            }

            if source.symbolicTraits.contains(.italic),
               let slanted = resolve(family: family, weight: weight, italic: true, size: font.pointSize) {
                return slanted
            }
            return resolve(family: family, weight: weight, italic: false, size: font.pointSize)
        }

        /// Matching a descriptor against the installed families is not free, and the drawn
        /// controls ask from `draw(_:)` — under an override family that is a fontd round trip
        /// per redraw. The answer for (family, weight, slant, size) depends only on what is
        /// installed, never on a theme or an override, so a hit needs no invalidating. Only
        /// successes are kept: a miss stays a live question, which is what lets a family that
        /// is installed mid-run be found the next time the sweep asks for it.
        /// Typography is main-actor isolated with the rest of the design system, so this cache
        /// has one owner. A lock plus `nonisolated(unsafe)` made the compiler unable to prove the
        /// confinement that every caller already obeyed.
        private static var familyCache: [String: NSFont] = [:]

        private static func resolve(
            family: String,
            weight: NSNumber?,
            italic: Bool,
            size: CGFloat
        ) -> NSFont? {
            let key = "\(family)|\(size)|\(weight?.doubleValue ?? .nan)|\(italic)"
            if let cached = familyCache[key] { return cached }

            var traits: [NSFontDescriptor.TraitKey: Any] = [:]
            if let weight { traits[.weight] = weight }
            if italic { traits[.symbolic] = NSFontDescriptor.SymbolicTraits.italic.rawValue }
            var attributes: [NSFontDescriptor.AttributeName: Any] = [.family: family]
            if !traits.isEmpty { attributes[.traits] = traits }
            let resolved = NSFont(descriptor: NSFontDescriptor(fontAttributes: attributes), size: size)

            if let resolved { familyCache[key] = resolved }
            return resolved
        }

        /// The user's overrides for a surface, nearest first.
        ///
        /// An empty string is screened out rather than resolved: `setOrRemove` never writes
        /// one, but a defaults value written by hand or by a migration would otherwise be
        /// handed to the descriptor matcher, whose answer for `""` is not a documented `nil`.
        private static func overrideFamilies(for surface: FontSurface) -> [String] {
            let chrome = AppSettings.chromeFontFamily
            let families: [String?]
            switch surface {
            case .chrome:
                families = [chrome]
            case .conversation:
                families = [AppSettings.conversationFontFamily, chrome]
            }
            return families.compactMap { $0 }.filter { !$0.isEmpty }
        }

        /// The one emphasised string in a view — a project name, a pane title.
        static func heading(surface: FontSurface = .chrome) -> NSFont {
            heading(pointSize: scaled(20), defaultWeight: .semibold, surface: surface)
        }
        /// A compact title inside an otherwise empty content pane.
        static func placeholderTitle(surface: FontSurface = .chrome) -> NSFont { prose(.systemFont(ofSize: scaled(15), weight: .medium), surface: surface) }
        /// Supporting detail directly beneath a heading, such as a path.
        static func subheading(surface: FontSurface = .chrome) -> NSFont { prose(.systemFont(ofSize: scaled(12), weight: .regular), surface: surface) }
        /// Editable and readable content.
        static func body(surface: FontSurface = .chrome) -> NSFont { prose(.systemFont(ofSize: scaled(13), weight: .regular), surface: surface) }
        /// A project, pane, or toolbar title at body scale.
        static func emphasizedBody(surface: FontSurface = .chrome) -> NSFont { prose(.systemFont(ofSize: scaled(13), weight: .semibold), surface: surface) }
        /// Strong body copy used only by legacy form section labels.
        static func strongBody(surface: FontSurface = .chrome) -> NSFont { prose(.systemFont(ofSize: scaled(13), weight: .bold), surface: surface) }
        /// The one-bit question mark drawn into a period requester's fixed-size indexed artwork.
        /// This is generated chrome rather than prose, so its source-matched face does not scale.
        static func classicRequesterMark() -> NSFont {
            .systemFont(ofSize: 22, weight: .bold)
        }
        /// Labels on controls. Buttons may ask for the weight their material authors; other
        /// controls keep the historical medium default.
        static func control(
            weight: NSFont.Weight = .medium,
            surface: FontSurface = .chrome
        ) -> NSFont {
            prose(.systemFont(ofSize: scaled(12), weight: weight), surface: surface)
        }
        /// Action-label typography may follow a display face without changing other controls.
        /// The user's chrome-family preference is still resolved first by `prose`.
        static func button(
            style: AppTheme.Material.ButtonStyle,
            surface: FontSurface = .chrome
        ) -> NSFont {
            prose(
                .systemFont(
                    ofSize: scaled(12) * style.fontScale,
                    weight: style.fontWeight.appKitWeight
                ),
                surface: surface,
                buttonStyle: style
            )
        }
        /// A quieter control label, such as a sidebar session.
        static func controlRegular(surface: FontSurface = .chrome) -> NSFont { prose(.systemFont(ofSize: scaled(12), weight: .regular), surface: surface) }
        /// Section headings and other quiet, small type.
        static func caption(surface: FontSurface = .chrome) -> NSFont { prose(.systemFont(ofSize: scaled(11), weight: .semibold), surface: surface) }
        /// Metadata and secondary copy that should not carry caption emphasis.
        static func detail(
            weight: NSFont.Weight = .regular,
            surface: FontSurface = .chrome
        ) -> NSFont {
            prose(.systemFont(ofSize: scaled(11), weight: weight), surface: surface)
        }

        /// The sidebar's wordmark — the app's name, or whatever a theme's sidebar brand says
        /// instead.
        ///
        /// A brand-stated family is the one place a *theme* outranks the user's font override:
        /// the wordmark is identity rather than prose, and a chrome that ships its own name in
        /// its own face should not read in Iowan because the user set body text there. It
        /// still degrades like every family — absent from this machine means the recipe falls
        /// through to `prose`, whose layers answer as they always do.
        static func wordmark(
            family: String? = nil,
            size: CGFloat? = nil,
            weight: NSFont.Weight = .semibold
        ) -> NSFont {
            let base = NSFont.systemFont(ofSize: scaled(size ?? 13), weight: weight)
            if let family, !family.isEmpty, let resolved = inFamily(family, like: base) {
                return resolved
            }
            return prose(base)
        }

        /// Tool subjects, paths, diffs, and other code-shaped content.
        static func code(weight: NSFont.Weight = .regular) -> NSFont {
            .monospacedSystemFont(ofSize: scaled(11), weight: weight)
        }

        /// Inline code that must share the body's line box.
        static func inlineCode() -> NSFont {
            .monospacedSystemFont(ofSize: scaled(12), weight: .regular)
        }

        /// A code sample inside the compact theme-preview card.
        static func previewCode() -> NSFont {
            .monospacedSystemFont(ofSize: scaled(11.5), weight: .regular)
        }

        /// Dense process metadata and compact hexadecimal values.
        static func compactCode() -> NSFont {
            .monospacedSystemFont(ofSize: scaled(10), weight: .regular)
        }

        /// A compact tool identifier; deliberately halfway between code and metadata.
        static func compactToolName() -> NSFont {
            .monospacedSystemFont(ofSize: scaled(10.5), weight: .regular)
        }

        /// Numeric labels use fixed-width digits without making the surrounding prose code.
        static func numericDisplay() -> NSFont {
            .monospacedDigitSystemFont(ofSize: scaled(30), weight: .semibold)
        }

        static func numericBody() -> NSFont {
            .monospacedDigitSystemFont(ofSize: scaled(13), weight: .regular)
        }

        static func numericControl(weight: NSFont.Weight = .regular) -> NSFont {
            .monospacedDigitSystemFont(ofSize: scaled(12), weight: weight)
        }

        static func numericDetail(weight: NSFont.Weight = .regular) -> NSFont {
            .monospacedDigitSystemFont(ofSize: scaled(11), weight: weight)
        }

        /// Markdown headings scale from the caller's semantic body font while font construction
        /// remains inside the typography boundary.
        static func markdownHeading(from base: NSFont, surface: FontSurface = .chrome) -> NSFont {
            markdownHeading(fromPointSize: base.pointSize, surface: surface)
        }

        /// The same scaling from a size alone, which is what a recorded `FontRole` can carry: a
        /// role is re-resolved after the theme moved, so holding the old *font* would scale the
        /// new heading from the previous typeface's metrics.
        static func markdownHeading(
            fromPointSize base: CGFloat,
            surface: FontSurface = .chrome
        ) -> NSFont {
            heading(
                pointSize: base + scaled(3),
                defaultWeight: .semibold,
                surface: surface
            )
        }

        /// The height `NSString.draw(in:)` actually lays a single line out at, so a rect built
        /// from it **centres** the words instead of top-aligning them in slack.
        ///
        /// This is the number to place drawn text with, never `boundingRectForFont.height`.
        /// That rect is the union of the family's glyph extremes and runs well past the line
        /// box — SF 12 reports 14.79 against a 15pt line, so a rect centred on it looked right
        /// and shipped, while Baskerville reports 15.66 against 14 and Geneva 24.41 against 16.
        /// `draw(in:)` sets its line down from the rect's *top*, so every one of those extra
        /// points lifts the text: under Platinum, whose Charcoal falls back to Geneva, a menu
        /// row's title sat 4pt above the icon and the checkmark beside it, which are centred.
        ///
        /// Asked of the layout manager rather than computed from the metrics, for the reason
        /// `ThemedButton.shortcutRectTop` asks it for the baseline: the offsets drawing uses
        /// are not always `ascender - descender + leading`. Geneva's is 16 where that
        /// arithmetic says 17, and half a point of that lands back in the same place.
        static func lineHeight(of font: NSFont) -> CGFloat {
            ceil(NSLayoutManager().defaultLineHeight(for: font))
        }

        /// Emoji rendered as an application control mark, not prose.
        static func accountEmoji() -> NSFont { .systemFont(ofSize: scaled(16)) }
        static func emojiPickerCell() -> NSFont { .systemFont(ofSize: scaled(19)) }

        /// Every family the process can currently resolve — the list the font pickers and the
        /// MCP authoring gate offer.
        ///
        /// CoreText rather than `NSFontManager`, and probed rather than assumed (2026-07-27):
        /// `NSFontManager.availableFontFamilies` snapshots on first access and never sees a
        /// font an enabled extension registers afterwards, while
        /// `CTFontManagerCopyAvailableFontFamilyNames` is live in both directions — a family
        /// appears on enable and leaves on disable, which is exactly what the pickers must
        /// show. Dot-prefixed families are the system's hidden faces and are filtered the way
        /// `NSFontManager` already filters them.
        static var availableFamilies: [String] {
            ((CTFontManagerCopyAvailableFontFamilyNames() as? [String]) ?? [])
                .filter { !$0.hasPrefix(".") }
                .sorted()
        }
    }

    // MARK: - Symbols

    enum Symbol {
        /// Beside a control's label.
        static let control: CGFloat = 11
        /// A top-level toolbar action, whose 16pt slot an 11pt glyph underfilled — the toolbar
        /// read as a row of marks smaller and lighter than every control below it.
        static let toolbar: CGFloat = 13
        /// Disclosure chevrons, which should read as a hint rather than a control.
        static let chevron: CGFloat = 8

        /// `.medium`, because glyphs are weighed against the text beside them and the anchor
        /// is its stem: SF 13 regular's is ~1.25pt, which is what an 11pt `.medium` symbol
        /// strokes at — measured by rasterising, not read off a table. `.regular` strokes at
        /// 1.0pt, so every icon in the chrome sat *below* the weight of its own label; on a 1×
        /// display that is a single antialiased pixel. Callers with a reason still state their
        /// own weight — the chevron is `.semibold` because at 8pt even medium reads faint.
        static func configuration(_ pointSize: CGFloat, weight: NSFont.Weight = .medium)
            -> NSImage.SymbolConfiguration {
            .init(pointSize: pointSize, weight: weight)
        }

        /// The share of a control's height that its glyph takes.
        ///
        /// Three-fifths, which is what the chrome already holds without having said so: the
        /// toolbar button is a 16pt slot in 28 points and the inline one 12 in 20, both within
        /// a point of it. Stated as a *ratio* because a control's height is not always ours —
        /// `Design.Size.choiceHeight` is authored by the theme and editable from 14 to 44 — and
        /// a glyph that keeps a fixed slot inside a control that does not reads as a mark
        /// floating in a box at one end of that range and as one wedged into it at the other.
        static let glyphFraction: CGFloat = 0.6

        /// The glyph slot inside a control `height` points tall, on the pixel grid.
        static func slot(inControlOfHeight height: CGFloat) -> CGFloat {
            (height * glyphFraction).rounded()
        }

        /// The optical size a slot's mark is configured at.
        ///
        /// `image(_:slot:pointSize:)` only ever configures *down*, so the point size states the
        /// weight the mark should carry and the slot caps its size. A slot at or above the
        /// toolbar's takes the toolbar's heavier optical size; anything smaller takes the one
        /// that sits beside a label. Without this a promoted button drew its old 11pt mark in a
        /// slot half again as wide, which is a lighter stroke in a larger control — the
        /// opposite of what growing it was for.
        static func pointSize(forSlot slot: CGFloat) -> CGFloat {
            slot >= Size.tabIconSlot ? toolbar : control
        }

        /// A symbol sized so its rendered form fits `slot` — by *configuring* smaller, never by
        /// scaling the render.
        ///
        /// A symbol's natural size is its own: at the 11pt configuration `gearshape` renders
        /// 14×14 and the sidebar's arrange glyph 15×14, so a 12pt slot was shrinking finished
        /// renders by a fifth — which thins the stroke below what the configuration chose and
        /// drops it off the pixel grid. Re-configuring at the fitted point size keeps the
        /// weight compensation SF's optical sizes exist to provide. Symbols already inside the
        /// slot keep their nominal size; nothing is ever configured *up*.
        static func image(
            _ symbolName: String,
            slot: CGFloat,
            pointSize: CGFloat,
            weight: NSFont.Weight = .medium
        ) -> NSImage? {
            func rendered(at size: CGFloat) -> NSImage? {
                NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                    .withSymbolConfiguration(configuration(size, weight: weight))
            }
            guard let nominal = rendered(at: pointSize) else { return nil }
            let widest = max(nominal.size.width, nominal.size.height)
            guard widest > slot else { return nominal }
            return rendered(at: pointSize * slot / widest)
        }
    }

    // MARK: - Charts

    /// Shared geometry for dense time-series surfaces. These belong here rather than in the
    /// Usage feature because the chart is a reusable design-system component and every future
    /// dashboard should inherit the same plot rhythm, hit target, and bounded render budget.
    enum Chart {
        static let preferredHeight: CGFloat = 260
        static let axisLeading: CGFloat = 64
        static let axisTrailing: CGFloat = Spacing.inset
        static let axisTop: CGFloat = Spacing.large
        static let axisBottom: CGFloat = 28
        static let gridLineCount = 5
        static let xLabelCount = 4
        static let lineWidth: CGFloat = 2
        static let systemLineWidth: CGFloat = 1.6
        static let projectionLineWidth: CGFloat = 1.5
        static let markerLineWidth: CGFloat = 1
        static let systemAreaOpacity: CGFloat = 0.12
        static let themedAreaOpacity: CGFloat = 0.08
        static let systemStackedBandOpacity: CGFloat = 0.58
        static let themedStackedBandOpacity: CGFloat = 0.50
        static let spectrumBandOpacity: CGFloat = 0.92
        static let spectrumColumnWidth: CGFloat = 6
        static let spectrumColumnGap: CGFloat = 2
        static let spectrumCellHeight: CGFloat = 4
        static let spectrumCellGap: CGFloat = 2
        static let spectrumPeakHeight: CGFloat = 2
        static let pointRadius: CGFloat = 3
        static let selectedPointRadius: CGFloat = 5

        /// A ranking chart's leading gutter holds words rather than formatted numbers, so it is
        /// wider than the value axis it replaces.
        static let categoryAxisLeading: CGFloat = 108
        /// The floor a chart is still readable at, and the ceiling a ranking may grow to before
        /// its bands compress instead. Sixty categories at a comfortable row height would be a
        /// two-thousand-point row in a conversation, which is a scroll, not a chart.
        static let minimumCardHeight: CGFloat = 160
        static let maximumCardHeight: CGFloat = 720
        static let rankingRowHeight: CGFloat = 32
        static let legendHeight: CGFloat = 16
        static let legendSwatch: CGFloat = 8
        /// The share of a category band a bar group occupies. The remainder is the gap that says
        /// the bands are separate categories rather than one continuous run.
        static let barBandFraction: CGFloat = 0.72
        static let barGap: CGFloat = 2
        /// Enough tint that a bar reads as a measured quantity rather than as an outline. Below
        /// roughly a quarter it washes out on a light ground, where the fill is competing with
        /// white rather than sitting on black.
        static let barFillOpacity: CGFloat = 0.3
        /// Bars round at the growing end only, and barely. A fully rounded bar reads as a pill
        /// floating above the axis rather than as a quantity measured from it, and the control
        /// radius — sized for a button — is far too generous at a bar's width.
        static let barRadius: CGFloat = 3
        /// A bar thinner than this has no room for its own number, and printing one anyway
        /// overlaps the bar beside it.
        static let barValueLabelThickness: CGFloat = 26
        /// Axis labels are thinned in whole steps below these widths, so a resize drops whole
        /// categories rather than shuffling which names happen to fit.
        static let minimumCategoryLabelWidth: CGFloat = 48
        static let minimumCategoryBand: CGFloat = 16
        static let tooltipInset = Spacing.medium
        static let tooltipOffset = Spacing.inset
        static let tooltipMaxWidth: CGFloat = 180
        static let maximumRenderedPoints = 240
        static let maximumRenderedMarkers = 120

        static var style: AppTheme.Material.ChartStyle {
            AppThemePalette.current.material.chartStyle
        }

        /// The categorical ramp remains platform-adaptive for ordinary charts. A spectrum
        /// material instead uses its own authored neon/status vocabulary, keeping the analyzer
        /// coherent with player chrome without a feature view naming that theme.
        @MainActor
        static func color(for style: ThemedChartSeriesStyle) -> NSColor {
            switch style {
            case .primary, .projection:
                return Design.Surface.accent
            case .positive:
                return Design.Status.positive
            case .warning:
                return Design.Status.warning
            case .negative:
                return Design.Status.negative
            case .categorical(let index) where self.style == .spectrum:
                let ramp = [
                    Design.Surface.accent,
                    Design.Status.warning,
                    Design.Syntax.type,
                    Design.Status.negative,
                    Design.Syntax.keyword,
                    Design.Syntax.string
                ]
                return ramp[((index % ramp.count) + ramp.count) % ramp.count]
            case .categorical(let index):
                return Design.Categorical.hue(at: index).color
            }
        }
    }

    enum UsageDashboard {
        static let metricCardHeight: CGFloat = 76
        static let breakdownHeight: CGFloat = 300
        static let breakdownRowHeight: CGFloat = 48
        static let coverageRowHeight: CGFloat = 54
        static let minimumContentWidth: CGFloat = 560
        static let tabControlWidth: CGFloat = 280
        static let consumptionSummaryWidth: CGFloat = 276
        static let rangeControlWidth: CGFloat = 148
        static let metricControlWidth: CGFloat = 144
    }

    // MARK: - Surface

    /// Fills and borders, all derived from system colours so light and dark both work and
    /// the accent colour is the user's own.
    @MainActor
    enum Surface {
        /// A control at rest. Below full opacity so a row of them stays quiet.
        static var controlResting: NSColor {
            Accessibility.color(.controlResting, increasedContrastAlphaFloor: 0.16)
        }

        /// The same control under the pointer.
        static var controlHover: NSColor {
            Accessibility.color(.controlHover, increasedContrastAlphaFloor: 0.24)
        }

        /// A container holding content, such as the prompt box.
        static var panel: NSColor { AppThemePalette.color(.panel) }

        /// A writable/value well. Modern themes derive this from their panel; period themes may
        /// state the native field colour independently from the surrounding chrome.
        static var field: NSColor { AppThemePalette.color(.fieldSurface) }

        /// A container above a panel — a popover, a floating card.
        static var elevated: NSColor { AppThemePalette.color(.elevated) }

        /// An anchored floating surface. Usually the elevated colour, but independently
        /// authorable for period components such as a pale Windows infotip.
        static var floating: NSColor { AppThemePalette.color(.floatingSurface) }

        static var border: NSColor {
            Accessibility.color(.border, increasedContrastAlphaFloor: 0.70)
        }

        /// The lit and shaded edges of a bevelled surface. Only ever drawn under a material
        /// that states a bevel — see `SurfaceBevel`.
        static var bevelHighlight: NSColor { AppThemePalette.color(.bevelHighlight) }
        static var bevelShadow: NSColor { AppThemePalette.color(.bevelShadow) }

        /// A rule between rows, quieter than a border around them — and *held* quieter.
        ///
        /// Quieter is enforced rather than hoped for. Most stock themes attenuate their
        /// `divider` role by hand, but nothing made a loud one do it: Neo Brutalism stated
        /// full label ink under a 3pt rule weight, and every rule in the window drew as a
        /// black bar 2.5× the stem of the text beside it. So the authored ink is capped at
        /// `Material.ruleInkCeiling` — thickness × ink stays within the budget one body stem
        /// costs — and never *raised*: a theme quieter than its ceiling keeps its own value.
        /// Resolved inside a dynamic colour so a live theme switch, an appearance flip and
        /// Increase Contrast each take the decision again; under Increase Contrast the
        /// ceiling yields to the floor, because contrast asked for is contrast given.
        static var divider: NSColor {
            NSColor(name: NSColor.Name("threading.surface.divider")) { appearance in
                let authored = AppThemePalette.current.resolved(.divider, appearance: appearance)
                guard let resolved = authored.usingColorSpace(.sRGB) else { return authored }
                if Accessibility.increasesContrast {
                    return resolved.withAlphaComponent(max(resolved.alphaComponent, 0.60))
                }
                let ceiling = AppThemePalette.current.material(for: appearance).ruleInkCeiling
                return resolved.withAlphaComponent(min(resolved.alphaComponent, ceiling))
            }
        }

        /// The window's own backdrop.
        static var ground: NSColor { AppThemePalette.color(.ground) }

        /// Large structural areas — the sidebar.
        static var background: NSColor { AppThemePalette.color(.surface) }

        /// Draws attention to the one control that is ready to act.
        static var accent: NSColor { AppThemePalette.color(.accent) }

        /// A quiet accent ground: tracks and washes that belong to the accent but must sit
        /// behind full-strength accent ink.
        static var accentMuted: NSColor { AppThemePalette.color(.accentMuted) }

        // A selected row inside app-owned chrome is deliberately **not** a token here.
        //
        // It was, and every consumer then chose its own foreground against a fill it had taken on
        // its own: `Design.Text.label` over Windows 98's 90% navy (1.47:1), `Design.Text.selected`
        // — an ink measured against the opaque accent — over Christmas's 20% wash (1.76:1). A fill
        // available without its ink is a fill that will be handed unreadable content, so the role
        // is vended by `SelectionSurface`, which cannot give one without the other.

        /// What an **emphasized** selection is actually filled with — the ground anything drawn
        /// *inside* a selected row has to read against.
        ///
        /// Not `selection` above, which is the theme's role for a selected row at rest:
        /// `SidebarHoverRowView` paints the accent while its window is in front, and under
        /// **System** hands the fill back to AppKit entirely. Stated once here so a control
        /// sitting in the row need know neither fact. See `Design.Ink.selection`.
        static var selectionFill: NSColor {
            AppThemePalette.current.isSystem ? .selectedContentBackgroundColor : accent
        }

        /// The ground behind the run of a string a search matched.
        ///
        /// Derived from the accent rather than authored per theme: a match is the one thing on
        /// the surface the reader asked for, which is what the accent already means everywhere
        /// else. It is held well back, because an opaque accent behind a word reads as a button
        /// rather than as a find — and resolved *inside* a dynamic colour so a live theme
        /// switch, an appearance flip and Increase Contrast each take the decision again. The
        /// alpha is replaced rather than scaled, matching every other derived role here.
        static var searchMatch: NSColor {
            NSColor(name: NSColor.Name("threading.surface.searchMatch")) { _ in
                let accent = AppThemePalette.current.resolved(.accent)
                let alpha = Accessibility.increasesContrast
                    ? Opacity.searchMatchGroundIncreasedContrast
                    : Opacity.searchMatchGround
                return (accent.usingColorSpace(.sRGB) ?? accent).withAlphaComponent(alpha)
            }
        }

        /// The wash over the page component the next annotation pin will describe.
        ///
        /// Derived from the accent for the same reason the search ground is: the accent already
        /// means "the one thing you are aiming at" everywhere else in the window, and an
        /// annotation target is that sentence said over a web page. Resolved inside a dynamic
        /// colour so a live theme switch, an appearance flip and Increase Contrast each get to
        /// answer again.
        static var annotationTarget: NSColor {
            NSColor(name: NSColor.Name("threading.surface.annotationTarget")) { _ in
                let accent = AppThemePalette.current.resolved(.accent)
                let alpha = Accessibility.increasesContrast
                    ? Opacity.annotationTargetGroundIncreasedContrast
                    : Opacity.annotationTargetGround
                return (accent.usingColorSpace(.sRGB) ?? accent).withAlphaComponent(alpha)
            }
        }

        /// The ground under the row a drag would land on.
        ///
        /// The third of the same sentence: the accent means "the one thing you are aiming at",
        /// and here the pointer is holding something that will land on it. Held as far back as
        /// `annotationTarget`, and for the same reason — this covers a row the reader still has
        /// to *read*, since which picture is under the pointer is the whole question the
        /// affordance answers. An opaque plate answers it by hiding it, which is how the first
        /// version of the attachments drop came to draw a saturated slab over the row it was
        /// naming, louder than the window's own selection two rows above.
        static var dropTarget: NSColor {
            NSColor(name: NSColor.Name("threading.surface.dropTarget")) { _ in
                let accent = AppThemePalette.current.resolved(.accent)
                let alpha = Accessibility.increasesContrast
                    ? Opacity.annotationTargetGroundIncreasedContrast
                    : Opacity.annotationTargetGround
                return (accent.usingColorSpace(.sRGB) ?? accent).withAlphaComponent(alpha)
            }
        }

        /// The composer's well while a drag it can take is over it.
        ///
        /// The same sentence as `dropTarget` — the accent means "the one thing you are aiming
        /// at", and the pointer is holding something that will land here — but composited over
        /// the field fill rather than left translucent, because `applySurface` records exactly
        /// one fill per surface and a wash laid on as a second layer would be a theme colour
        /// frozen outside the record. Held to the same quiet alpha as the row wash: a draft may
        /// be under the pointer, and the tint has to answer *where this lands* without covering
        /// what is already written.
        static var fieldDropTarget: NSColor {
            NSColor(name: NSColor.Name("threading.surface.fieldDropTarget")) { _ in
                let palette = AppThemePalette.current
                let field = palette.resolved(.fieldSurface)
                let accent = palette.resolved(.accent)
                let alpha = Accessibility.increasesContrast
                    ? Opacity.annotationTargetGroundIncreasedContrast
                    : Opacity.annotationTargetGround
                let base = field.usingColorSpace(.sRGB) ?? field
                let wash = accent.usingColorSpace(.sRGB) ?? accent
                return base.blended(withFraction: alpha, of: wash) ?? base
            }
        }

        /// The hover the pointer earns over a *picture* — the display panel's image, an
        /// attachment's thumbnail.
        ///
        /// `controlHover` is the theme's hover hue and cannot be used here directly, which is the
        /// one place in the app that distinction matters. Every other hover fill is drawn *under*
        /// its content, so an opaque role is right there and is what most themes ship:
        /// `unemphasizedSelectedContentBackgroundColor` under System, `#D0D0D0` under Windows 98,
        /// `#D8B4FE` under Lavender — all alpha 1. Laid over a picture the same fill is not a wash
        /// but a lid, and hovering an attachment replaced the image with a flat rectangle.
        ///
        /// So the hue stays the theme's and the alpha becomes ours, stated rather than inherited.
        /// Resolved inside a dynamic colour so a live theme switch, an appearance flip and
        /// Increase Contrast each get to answer again.
        static var imageHoverWash: NSColor {
            NSColor(name: NSColor.Name("threading.surface.imageHoverWash")) { _ in
                let hover = AppThemePalette.current.resolved(.controlHover)
                let alpha = Accessibility.increasesContrast
                    ? Opacity.imageHoverWashIncreasedContrast
                    : Opacity.imageHoverWash
                return (hover.usingColorSpace(.sRGB) ?? hover).withAlphaComponent(alpha)
            }
        }

        /// The wash a covering surface lays over the window it opened in — see `InWindowOverlay`.
        ///
        /// Deliberately *not* derived from a theme role, and the only fill here that says so.
        /// Every authored shade in this app is a bevel's edge — Windows 98 states `#808080`,
        /// Platinum `#777777`, BeOS `#747474` — and a mid-grey wash barely dims a light window
        /// while it visibly *lifts* a dark one. A scrim is not a colour a palette picks; it is
        /// light taken away, which is black at a stated alpha under every theme and both
        /// appearances. What the theme keeps is the thing standing in front of it: a covering
        /// surface fills with `elevated`, so the tonal step between the two moves with the palette
        /// while the wash behind it stays a wash.
        ///
        /// Resolved inside a dynamic colour so a live theme switch, an appearance flip and
        /// Increase Contrast each get to answer again.
        static var overlayScrim: NSColor {
            NSColor(name: NSColor.Name("threading.surface.overlayScrim")) { _ in
                NSColor(
                    white: 0,
                    alpha: Accessibility.increasesContrast
                        ? Opacity.overlayScrimIncreasedContrast
                        : Opacity.overlayScrim
                )
            }
        }
    }

    // MARK: - Text

    /// The four label tiers, as roles rather than as system colours.
    ///
    /// These exist because the app made 150 direct calls to `NSColor.secondaryLabelColor` and
    /// friends — more than ten times the number of surface tokens — so a theme that reached
    /// only the surfaces would have repainted the containers and left every word in them alone.
    @MainActor
    enum Text {
        static var label: NSColor { AppThemePalette.color(.label) }
        static var secondary: NSColor { AppThemePalette.color(.secondaryLabel) }
        static var tertiary: NSColor {
            Accessibility.color(
                .tertiaryLabel,
                increasedContrastRole: .secondaryLabel
            )
        }
        static var quaternary: NSColor {
            Accessibility.color(
                .quaternaryLabel,
                increasedContrastRole: .tertiaryLabel
            )
        }

        /// Text over an emphasized selection.
        ///
        /// System keeps AppKit's own answer because its source-list fill is also AppKit's. A
        /// styled theme draws its own accent selection, so the foreground is measured against
        /// that accent rather than inherited from the user's unrelated system accent.
        static var selected: NSColor {
            guard !AppThemePalette.current.isSystem else {
                return .alternateSelectedControlTextColor
            }
            return on(Design.Surface.accent).label
        }

        /// The label tiers that read on an *arbitrary* ground, for the one place a role cannot
        /// answer: a surface the app theme does not own.
        ///
        /// The terminal pane paints the whole window with the *terminal* palette's background, so
        /// the colour runs to the window's edges instead of meeting the chrome in a hard seam —
        /// which is the effect worth keeping. The cost is that everything sitting on it, the
        /// toolbar above all, is over a colour the chrome knows nothing about. Reading
        /// `Design.Text.label` there is how a light app theme came to write a near-black title
        /// across a dark terminal.
        ///
        /// Fixed neutrals rather than theme roles, deliberately: the answer has to come from the
        /// ground it is drawn on. Which of black and white is used is decided by *measuring* both
        /// against that ground rather than by a luminance threshold, so a mid-tone terminal gets
        /// the one that actually reads rather than the one a constant guessed at.
        static func on(_ background: NSColor) -> Design.Ink {
            let light = ThemeContrast.ratio(.white, background) >= ThemeContrast.ratio(.black, background)
            let base: NSColor = light ? .white : .black
            // The tiers are further apart on a dark ground than a light one: black fades to
            // nothing on paper long before white does on ink.
            let increased = Accessibility.increasesContrast
            return Design.Ink(
                base: base,
                label: base.withAlphaComponent(increased ? 1 : (light ? 0.95 : 0.88)),
                secondary: base.withAlphaComponent(increased ? 0.82 : (light ? 0.70 : 0.62)),
                tertiary: base.withAlphaComponent(increased ? 0.68 : (light ? 0.50 : 0.44)),
                quaternary: base.withAlphaComponent(increased ? 0.54 : (light ? 0.32 : 0.28))
            )
        }
    }

    // MARK: - Ink

    /// Every colour a drawn component needs, resolved against **one** of the window's two grounds.
    ///
    /// Originally this answered only for the backdrop — a ground the theme does not own — where
    /// reading `Design.Text` is wrong by the amount the two palettes differ. It now also answers
    /// for the chrome (`Ink.chrome`), and that is what lets a component appear on either ground
    /// without being written twice. A tab in the display pane and the same tab in the toolbar
    /// differ in *where their colours come from* and in nothing else, so that is the only thing
    /// they state; see `InkSource`.
    @MainActor
    struct Ink {

        /// The tone every derived value here is cut from: white over a dark ground, black over a
        /// light one. Held so each tier and surface is *the base at an opacity* rather than a
        /// dimming of the tier above it — `withAlphaComponent` replaces alpha rather than scaling
        /// it, and chaining it reads as a scale that it is not.
        let base: NSColor

        let label: NSColor
        let secondary: NSColor
        let tertiary: NSColor
        let quaternary: NSColor

        /// A control surface that reads on the same ground — the pill behind the usage summary,
        /// the card floating at the pane's corner, a tab.
        ///
        /// **Derived over a ground the theme does not own, stated over one it does.** Cut from
        /// `base` there is right for the backdrop and only there: the chrome's own resting fill is
        /// its label colour at a far lower opacity, which over a backdrop of the opposite tone is
        /// either invisible or a bright smear. But on the chrome itself the theme already states
        /// these three roles, and a component deriving its own would sit at a weight no other
        /// control in the window uses.
        let surface: NSColor
        let surfaceHover: NSColor
        let border: NSColor

        /// A rule *between* things, as against the border *around* one.
        ///
        /// Distinct because only the chrome distinguishes them: there the theme states both
        /// roles and `Design.Surface.divider` holds the rule to the ink budget, so a rule and
        /// a border genuinely differ. Over a backdrop the ink is derived from the ground, and
        /// the derived border already sits inside the budget at any weight the gates allow —
        /// so it is the same value under a second name, and the name is what a call site
        /// drawing a rule states.
        let rule: NSColor

        /// Surfaces cut from `base`, for a ground the theme does not own.
        init(
            base: NSColor,
            label: NSColor,
            secondary: NSColor,
            tertiary: NSColor,
            quaternary: NSColor
        ) {
            let increased = Accessibility.increasesContrast
            let border = base.withAlphaComponent(increased ? 0.52 : 0.30)
            self.init(
                base: base,
                label: label,
                secondary: secondary,
                tertiary: tertiary,
                quaternary: quaternary,
                surface: base.withAlphaComponent(increased ? 0.22 : 0.14),
                surfaceHover: base.withAlphaComponent(increased ? 0.34 : 0.24),
                border: border,
                rule: border
            )
        }

        /// Surfaces stated outright, for a ground that already has roles of its own.
        init(
            base: NSColor,
            label: NSColor,
            secondary: NSColor,
            tertiary: NSColor,
            quaternary: NSColor,
            surface: NSColor,
            surfaceHover: NSColor,
            border: NSColor,
            rule: NSColor
        ) {
            self.base = base
            self.label = label
            self.secondary = secondary
            self.tertiary = tertiary
            self.quaternary = quaternary
            self.surface = surface
            self.surfaceHover = surfaceHover
            self.border = border
            self.rule = rule
        }

        /// The **emphasized selection's fill**, as an `Ink` — what a control nested inside a
        /// selected row draws from.
        ///
        /// A sidebar row's `⋯` and archive take the chrome's ink, which is right up to the moment
        /// the row is selected: the theme then lays a block of accent under them, and the chrome's
        /// secondary label is measured against a ground that is no longer there. Under Botanical
        /// that is a dark green glyph on a dark green fill — the buttons read as holes in the row
        /// the title beside them has already inverted out of.
        ///
        /// Mirrors `Design.Text.selected`, and for its reason: under **System** the fill is
        /// AppKit's own, so the ink is measured against AppKit's; a styled theme paints its own
        /// accent, so the ink is measured against that.
        static var selection: Ink { Text.on(Design.Surface.selectionFill) }

        /// The chrome's own ground, as an `Ink`.
        ///
        /// Computed on every access rather than stored, for the reason `ThemedControl` draws in
        /// `draw(_:)` at all: a role resolves to a different colour after a theme switch, and a
        /// value captured once would keep the old one.
        static var chrome: Ink {
            Ink(
                base: Design.Text.label,
                label: Design.Text.label,
                secondary: Design.Text.secondary,
                tertiary: Design.Text.tertiary,
                quaternary: Design.Text.quaternary,
                surface: Design.Surface.controlResting,
                surfaceHover: Design.Surface.controlHover,
                border: Design.Surface.border,
                rule: Design.Surface.divider
            )
        }
    }

    // MARK: - Status

    /// What a session's state is drawn in, and what a result that went wrong is drawn in.
    enum Status {
        static var positive: NSColor { readable(.statusPositive) }
        static var warning: NSColor { readable(.statusWarning) }
        static var negative: NSColor { readable(.statusNegative) }

        /// Status roles are frequently words, not decoration. Preserve the authored hue, but
        /// move it only as far as needed to read on both bare and structural app surfaces.
        /// System green is intentionally vivid rather than body-text-safe in light mode; using
        /// it verbatim made "CI passed" a 1.5:1 label.
        private static func readable(_ role: AppThemeRole) -> NSColor {
            NSColor(name: NSColor.Name("threading.status.\(role.rawValue)")) { appearance in
                let theme = AppThemePalette.current
                let authored = theme.resolved(role, appearance: appearance)
                let ground = theme.resolved(.ground, appearance: appearance)
                let surface = theme.resolved(.surface, appearance: appearance)
                return authored
                    .legible(on: ground, ratio: 4.5)
                    .legible(on: surface, ratio: 4.5)
            }
        }
    }

    // MARK: - Categorical

    /// Hues that exist to tell things *apart* rather than to say what they are — the git graph's
    /// lanes, and anything else that needs N distinguishable colours with no meaning attached.
    ///
    /// The one place system colours are used directly rather than through a role, and the reason
    /// is that a role answers "what is this", which is exactly what a lane does not have. They
    /// adapt to light and dark on their own, and are ordered so neighbouring entries are never
    /// near-hues. A theme may want its own ramp one day; this is where it would go.
    enum Categorical {

        /// A hue and the word for it.
        ///
        /// The name is not decoration: a colour that only exists as pixels cannot appear in a
        /// legend, a tooltip or a report pasted into a chat, and "the third one" is not a
        /// thing anyone can point at. The name lives *beside* the colour so the two cannot
        /// drift — a ramp reordered without its words is a legend that lies.
        struct Hue: Equatable {
            let name: String
            let color: NSColor
        }

        static let hues: [Hue] = [
            Hue(name: "Blue", color: .systemBlue),
            Hue(name: "Orange", color: .systemOrange),
            Hue(name: "Purple", color: .systemPurple),
            Hue(name: "Teal", color: .systemTeal),
            Hue(name: "Pink", color: .systemPink),
            Hue(name: "Indigo", color: .systemIndigo)
        ]

        static let ramp: [NSColor] = hues.map(\.color)

        /// The hue for an index that may run past the ramp, cycling. Every caller that
        /// colours an unbounded sequence — graph lanes, hierarchy depths — needs this, and
        /// each wrote its own `% count` before.
        static func hue(at index: Int) -> Hue {
            hues[((index % hues.count) + hues.count) % hues.count]
        }
    }

    // MARK: - Diff

    enum Diff {
        static var added: NSColor { AppThemePalette.color(.diffAdded) }
        static var removed: NSColor { AppThemePalette.color(.diffRemoved) }
    }

    // MARK: - Chat

    /// The conversation surface: the user's turns as bubbles, the agent's as flowing text.
    enum Chat {
        /// A user bubble never spans the pane — a short reply in a full-width box reads as
        /// shouting, and a wide box makes the eye travel for nothing.
        static let bubbleMaxWidthFraction: CGFloat = 0.78

        /// The bubble fill: the user's accent, dropped well below full so its own text stays
        /// legible and it does not compete with the agent's reply for attention.
        static var bubbleFill: NSColor { AppThemePalette.color(.accentMuted) }

        /// Vertical gap between one turn and the next.
        ///
        /// Wider than a gap between rows *within* a turn by enough to read as a boundary: a
        /// conversation rendered at the old 16pt was one uniform column, and where an exchange
        /// began could only be worked out by reading it.
        static let turnSpacing: CGFloat = 30

        /// The fixed-width column a tool row's glyph sits in, so rows align down the edge.
        static let toolIconWidth: CGFloat = 16

        /// A tool row at rest: **nothing**.
        ///
        /// A working turn is mostly tool rows — a real Codex rollout ran twenty consecutively —
        /// and twenty filled slabs read as the conversation's content rather than as its
        /// scaffolding, burying the sentences between them. They are the record of what was
        /// done, not what was said. This is the design system's own "quiet until relevant" rule
        /// applied to the row that needed it most.
        static var toolRowResting: NSColor { .clear }

        /// Under the pointer, or opened: now it is the thing being looked at.
        static var toolRowActive: NSColor { AppThemePalette.color(.controlResting) }

        /// The rule above a user's turn.
        ///
        /// Spacing alone still left the eye hunting, because the rows above and below it are
        /// themselves separated by space. A line is unambiguous, and at this weight it reads as
        /// a fold in the page rather than as a border drawn around something.
        static var turnDivider: NSColor { AppThemePalette.color(.divider) }

        static let turnDividerHeight: CGFloat = 1
    }

    // MARK: - Syntax

    /// Colours for highlighted code, in diffs and wherever else source is shown.
    ///
    /// Four hues and a dimming, not a full theme. A diff row already carries a coloured wash
    /// and a gutter sign saying what happened to the line; a palette with a hue per grammar
    /// rule competes with that, and the thing being read stops being the change.
    ///
    /// Two colours are deliberately *not* here: red and green. Both mean removed and added
    /// throughout this app, and a red string literal inside a green added line says two
    /// contradictory things at once. Comments take no hue at all — a dimmed label is the
    /// design system's "quiet until relevant" applied to the code that was already annotation.
    enum Syntax {
        static var keyword: NSColor { AppThemePalette.color(.syntaxKeyword) }
        static var type: NSColor { AppThemePalette.color(.syntaxType) }
        static var string: NSColor { AppThemePalette.color(.syntaxString) }
        static var number: NSColor { AppThemePalette.color(.syntaxNumber) }
        static var comment: NSColor { AppThemePalette.color(.syntaxComment) }
    }

    // MARK: - Motion

    @MainActor
    enum Motion {
        /// A deterministic seam for behavior and render tests. Production always follows the
        /// user's macOS accessibility preference.
        static var reduceMotionOverrideForTesting: Bool?

        static var reducesMotion: Bool {
            reduceMotionOverrideForTesting
                ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }

        /// Long enough to read as movement, short enough not to be waited on.
        ///
        /// Callers keep one path and one final state. Under Reduce Motion the transition is
        /// immediate rather than requiring every feature to remember a separate accessibility
        /// branch.
        static var quick: TimeInterval { reducesMotion ? 0 : 0.15 }
        static var standard: TimeInterval { reducesMotion ? 0 : 0.2 }

        /// No motion at all — a state applied rather than transitioned. For routes that
        /// resolve "should this move?" themselves (an off-screen window, a caller that said
        /// not to) and still run their animation group so `animator()` proxies apply the
        /// change immediately instead of reaching for AppKit's default quarter second.
        static let immediate: TimeInterval = 0

        /// A surface materialising over content — the dropdown unfolding from its chip.
        static var appear: TimeInterval { reducesMotion ? 0 : 0.16 }

        /// The same surface leaving. Quicker than `appear`: arriving is information the eye
        /// follows, leaving is a decision already made.
        static var vanish: TimeInterval { reducesMotion ? 0 : 0.12 }

        /// A card travelling into or out of a pane's corner — the toast rising over the
        /// pane's lower edge, the deck behind it stepping forward when the front card goes.
        ///
        /// Longer than `appear`, because a fade materialises in place while a slide has the
        /// card's own height to cover, and at `appear`'s length the trip reads as a pop
        /// rather than an arrival. Well short of `handoff`, which carries an object across
        /// a whole pane and must stay readable as the same object for the length of it; a
        /// card entering at a corner only has to read as *coming from somewhere*.
        static var travel: TimeInterval { reducesMotion ? 0 : 0.3 }

        /// One beat of a menu's confirmation blink — the chosen row flickering once before
        /// the panel fades, the acknowledgement every platform menu gives.
        static var confirmBeat: TimeInterval { reducesMotion ? 0 : 0.05 }

        /// One surface handing an element over to the next — the composer's box travelling to
        /// where the conversation replies from.
        ///
        /// The longest transition here, and deliberately: `appear` and `vanish` are a surface
        /// materialising or leaving in one place, while this carries an object across the whole
        /// pane and has to stay readable as *the same box* for the length of the trip. Below
        /// about a third of a second the move reads as a jump cut, which is the swap it
        /// replaced; much beyond it the pane feels held while nothing is being decided.
        static var handoff: TimeInterval { reducesMotion ? 0 : 0.35 }

        /// How long a scrollbar that fades itself stays up after the scrolling that revealed
        /// it — macOS's own beat, long enough to reach the thumb that just appeared.
        ///
        /// Not collapsed under Reduce Motion, unlike the fade either side of it: a hold is not
        /// movement, and a scrollbar that vanishes the instant a gesture ends is harder to
        /// use, not calmer.
        static let scrollerHold: TimeInterval = 1.1

        /// The pause a repeating demonstration holds a finished state before starting the next
        /// — long enough to read the name that just arrived, short enough that a hovered row
        /// does not look finished.
        ///
        /// A caller guards on `reducesMotion` before scheduling rather than reading a zero hold
        /// as a cadence: a demonstration whose animation has already been collapsed is not a
        /// faster demonstration, it is a flicker, and the honest reduced form is to hold the
        /// name still.
        static var demonstrationHold: TimeInterval { reducesMotion ? 0 : 0.9 }

        // MARK: Name transitions

        /// How much of a LabelMorph preset's own recommended per-character duration a name
        /// transition here actually takes.
        ///
        /// The package recommends what shows an effect off — one large title, watched. These
        /// play on a sidebar row while an agent works, where the morph acknowledges a rename
        /// rather than being the thing you came to look at, and every other transition in the
        /// app lands in 0.15–0.2s. At the preset's full length a rename read as a wait.
        static let nameMorphTempo: Double = 0.65

        /// The whole cascade a name transition is allowed, however long the name.
        ///
        /// A per-character stagger multiplies out: at the default preset's 45ms a 26-character
        /// session title took 1.7s to settle, so a *longer* name looked slower rather than
        /// merely longer — and sidebar names are sentences. Budgeting the cascade rather than
        /// the step holds a transition near half a second at any length, and leaves the step as
        /// the preset asked for it whenever the name is short enough to fit inside the budget.
        static let nameMorphCascade: TimeInterval = 0.3

        // MARK: Brand mark

        /// The Threading mark stitching itself in on launch: the shield outline draws first,
        /// the six strands follow, the core lands last. One-shot — a launch flourish is not a
        /// perpetual animation — and all four collapse to the finished mark under Reduce
        /// Motion, so the reduced launch is simply the logo being there.
        static var brandOutlineDraw: TimeInterval { reducesMotion ? 0 : 0.5 }
        static var brandStrandDraw: TimeInterval { reducesMotion ? 0 : 0.38 }
        /// The beat between one strand starting and the next; six strands land inside the
        /// outline's own draw.
        static var brandStrandStagger: TimeInterval { reducesMotion ? 0 : 0.06 }
        static var brandCorePop: TimeInterval { reducesMotion ? 0 : 0.18 }

        /// Hover turns the mark from continuous ink into particles travelling on the same
        /// canonical paths. These are cadences rather than transition durations: they repeat
        /// only while the pointer is over the brand row, and no animation is constructed at
        /// rest or under Reduce Motion.
        static var brandParticleWeaveCycle: TimeInterval { reducesMotion ? 0 : 1.45 }
        static var brandParticleBreathCycle: TimeInterval { reducesMotion ? 0 : 1.8 }
        /// Weave answers an ordinary pass immediately. Rotation is earned by a deliberate
        /// dwell, late enough that crossing the sidebar never turns the brand into ambient
        /// motion, but soon enough to reward someone inspecting the implied box.
        static var brandParticleHoverHold: TimeInterval { reducesMotion ? 0 : 0.9 }
        /// Once that dwell is earned, the complete particle box makes one perspective turn.
        /// It is distinct from Orbit's planar strand-step: the dots keep weaving locally while
        /// their shared parent turns in depth.
        static var brandParticleBoxTurnCycle: TimeInterval { reducesMotion ? 0 : 2.8 }
        /// Exactly one strand-step per cycle keeps the rotating particle mark seamless: its
        /// six-fold silhouette at the end is the silhouette it had at the beginning.
        static var brandParticleOrbitCycle: TimeInterval { reducesMotion ? 0 : 2.4 }
        /// The outer dots answer a press first; this is the whole outer-to-core cascade.
        static var brandParticlePressCascade: TimeInterval { reducesMotion ? 0 : 0.1 }
    }

    // MARK: - Opacity

    enum Opacity {
        /// The emphasis retained by a control that cannot currently be operated.
        ///
        /// This is deliberately one recipe for the whole control, not a dim title beside a
        /// saturated plate. The latter says both "unavailable" and "primary action" at once,
        /// which is how disabled switches, checked boxes and submit buttons drifted apart.
        /// Components with historically authored disabled gadgets may keep those explicit
        /// materials; modern drawn controls multiply every surface and mark by this amount.
        static let disabledControl: CGFloat = 0.42

        /// A dragged tab while the pointer is over another pane that will take it: still
        /// visible where it came from, clearly on its way out.
        static let dragAway: CGFloat = 0.5

        /// How much accent sits behind a matched run. Measured against the panel a settings
        /// result and an import row both stand on: below this the find is easy to read past,
        /// and above it a row of matches reads as a row of filled controls.
        static let searchMatchGround: CGFloat = 0.28

        /// The same ground under Increase Contrast, where a faint tint is the first thing to go.
        static let searchMatchGroundIncreasedContrast: CGFloat = 0.5

        /// How much accent covers the page component an annotation is about to land on.
        ///
        /// Held further back than a search match, because this tints a whole component rather
        /// than a run of text and it lies over a page the app did not draw: the point is to say
        /// *which* element is under the pointer while leaving it legible enough to aim at. The
        /// outline carries the weight; the wash only says where the outline's edges belong.
        static let annotationTargetGround: CGFloat = 0.16

        /// The same wash under Increase Contrast, where the outline alone would be doing all
        /// the work over an arbitrary page.
        static let annotationTargetGroundIncreasedContrast: CGFloat = 0.34

        /// How much of the theme's hover colour lies over a picture the pointer is on.
        ///
        /// Near the annotation ground, and for the same reason: this covers content the app did
        /// not draw and whose whole purpose is to be looked at. The pointer cursor and the accent
        /// outline say the picture is a control; the wash only warms what they surround.
        static let imageHoverWash: CGFloat = 0.16

        /// The same wash under Increase Contrast, where a faint tint is the first thing to go.
        static let imageHoverWashIncreasedContrast: CGFloat = 0.34

        /// How much of the window a covering surface takes away behind it.
        ///
        /// Measured against the strip that stays visible beside an open inspector — the app's own
        /// header band above it, which is the only part of the window a full-height surface does
        /// not cover. Below this the band and the inspector's own header still read as two rows
        /// of one window's chrome, which is the bug the scrim exists for; far above it the strip
        /// goes to a black bar and the window reads as broken rather than as busy behind a modal.
        static let overlayScrim: CGFloat = 0.4

        /// The same wash under Increase Contrast, where the separation it draws is exactly what
        /// was asked for.
        static let overlayScrimIncreasedContrast: CGFloat = 0.6
    }

    // MARK: - Accessibility

    /// The system display preferences that change how app-owned chrome must be drawn.
    ///
    /// AppKit adapts its own controls automatically. Our controls deliberately replace that
    /// chrome, so these preferences are design inputs just like the active theme. Test
    /// overrides keep the behavior deterministic without changing the user's Mac settings.
    @MainActor
    enum Accessibility {
        static var increaseContrastOverrideForTesting: Bool?
        static var differentiateWithoutColorOverrideForTesting: Bool?

        static var increasesContrast: Bool {
            increaseContrastOverrideForTesting
                ?? NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        }

        static var differentiatesWithoutColor: Bool {
            differentiateWithoutColorOverrideForTesting
                ?? NSWorkspace.shared.accessibilityDisplayShouldDifferentiateWithoutColor
        }

        /// Focus is an interaction state, not decoration. Increase Contrast makes its outline
        /// heavier even when a theme deliberately keeps ordinary borders fine.
        static var focusRingWidth: CGFloat { increasesContrast ? 3 : 2 }

        /// Resolves an app-theme role at draw time and optionally strengthens translucent
        /// affordances under Increase Contrast. Opaque authored colours keep their hue; only a
        /// faint role's alpha is raised.
        static func color(
            _ role: AppThemeRole,
            increasedContrastRole: AppThemeRole? = nil,
            increasedContrastAlphaFloor: CGFloat? = nil
        ) -> NSColor {
            NSColor(name: NSColor.Name("threading.accessible.\(role.rawValue)")) { _ in
                let resolvedRole = increasesContrast ? increasedContrastRole ?? role : role
                let color = AppThemePalette.current.resolved(resolvedRole)
                guard increasesContrast,
                      let floor = increasedContrastAlphaFloor,
                      let resolved = color.usingColorSpace(.sRGB)
                else { return color }

                return resolved.withAlphaComponent(max(resolved.alphaComponent, floor))
            }
        }
    }
}

// MARK: - Label Helpers

extension NSTextField {

    /// A label carrying pre-attributed text — a `+N −M` counter, or anything else whose runs
    /// are coloured individually.
    ///
    /// Built from the string *first*, deliberately. A field created empty measures itself
    /// empty, and Auto Layout keeps that measurement: assigning `attributedStringValue`
    /// afterwards changes what is drawn without changing what was measured, so the label lays
    /// out four points wide and draws nothing at all. Every review-pane counter did exactly
    /// that until this existed.
    static func label(attributed text: NSAttributedString) -> NSTextField {
        let label = NSTextField(labelWithString: text.string)
        // The field draws its single line on the *field's* baseline, not the string's. Left on
        // the 13pt default a field of 11pt runs put its glyphs a little over two points below
        // the baseline it reports — so its descender all but touched the bottom of its own box,
        // and anything centred beside it (the git card's branch mark) read high against words
        // that were themselves sitting low. Adopting the string's metrics costs nothing: the
        // measured size is the string's either way, only the drawing moves.
        label.font = text.tallestFont ?? label.font
        label.attributedStringValue = text
        // Assigning attributed text turns wrapping back on, and a wrapping field has no
        // intrinsic *width* at all — it is a height-for-width view, which Auto Layout is free
        // to squash to nothing. Single-line mode gives it a definite width again.
        label.usesSingleLineMode = true
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }
}

extension NSAttributedString {

    /// The font that needs the most room, which is the one a single line has to be laid out for:
    /// a mixed string — a heading followed by its count, code inside prose — is only fully
    /// visible if the line box fits its tallest run.
    var tallestFont: NSFont? {
        var tallest: NSFont?
        enumerateAttribute(.font, in: NSRange(location: 0, length: length)) { value, _, _ in
            guard let font = value as? NSFont else { return }
            guard let current = tallest else { return tallest = font }
            if font.ascender - font.descender > current.ascender - current.descender {
                tallest = font
            }
        }
        return tallest
    }
}

// MARK: - View Helpers

/// The semantic corner a recorded surface should resolve on every theme change.
///
/// This is deliberately not a `CGFloat`. A theme may give several roles the same numeric
/// radius — Swiss makes panel, control, and pill corners all zero — so recovering the role by
/// comparing numbers loses information. Keeping the role lets a later theme resolve each one
/// independently.
@MainActor
enum SurfaceRadius {
    case panel
    case control
    case pill(height: CGFloat)
    case fixed(CGFloat)

    var current: CGFloat {
        switch self {
        case .panel: return Design.Radius.panel
        case .control: return Design.Radius.control
        case .pill(let height): return Design.Radius.pill(height: height)
        case .fixed(let value): return value
        }
    }

    /// The default edge weight follows the surface's semantic scale, not its numeric radius.
    /// A zero-radius Bauhaus panel is still structural; a fixed-radius swatch is still a control.
    var defaultBorderWidth: CGFloat {
        if case .panel = self { return Design.Radius.border }
        return Design.Radius.controlBorder
    }
}

/// How an applied or drawn surface participates in a bevel material (`Material.bevel`).
///
/// Recorded like `SurfaceRadius` — as a role rather than a result — so the theme sweep
/// re-resolves it: switching to a bevel theme raises every automatic surface, and switching
/// away strips every edge. A bevel only ever draws on a surface whose resolved corner is
/// square; a rectilinear edge treatment has no honest answer for a rounded offset curve, so a
/// disc or pill under a bevel material simply keeps its flat border.
@MainActor
enum SurfaceBevel: Equatable {
    /// What nearly every call site means without saying so: raised under a bevel material,
    /// exactly today's flat surface otherwise.
    case automatic
    /// Inset wells — text fields, the editor's scroll well — which read as carved into the
    /// surface rather than resting on it. Stated by the component, never guessed.
    case sunken
    /// Never bevelled: swatches, indicators, anything whose edge *is* its content.
    case none
}

/// Whether a broad applied surface participates in the theme's backdrop treatment.
///
/// Participation is explicit because the same `ground` colour can fill both a whole pane and a
/// compact find bar. Only the former is the page-like field measured in the reference styles;
/// inferring from colour or radius would eventually wallpaper a nested control.
@MainActor
enum SurfacePattern: Equatable {
    case none
    case backdrop
}

/// A theme-authored repeating treatment behind a broad app surface.
///
/// Drawn by a layer rather than baked into the fill so colours can re-resolve on a live theme or
/// appearance switch and the repeat can follow a resized pane without stretching. The layer is
/// inserted under bevel artwork and every child view; it never becomes control decoration.
private final class ThemeBackdropPatternLayer: CALayer {
    var kind: AppTheme.Material.BackdropPattern.Kind = .dots
    var ink: CGColor = NSColor.clear.cgColor
    var spacing: CGFloat = 20
    var markWidth: CGFloat = 1

    override init() {
        super.init()
        needsDisplayOnBoundsChange = true
        masksToBounds = true
    }

    override init(layer: Any) {
        if let layer = layer as? ThemeBackdropPatternLayer {
            kind = layer.kind
            ink = layer.ink
            spacing = layer.spacing
            markWidth = layer.markWidth
        }
        super.init(layer: layer)
        needsDisplayOnBoundsChange = true
        masksToBounds = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func draw(in context: CGContext) {
        guard bounds.width > 0, bounds.height > 0, spacing > 0, markWidth > 0 else { return }
        context.setFillColor(ink)
        context.setStrokeColor(ink)
        context.setLineWidth(markWidth)

        switch kind {
        case .dots:
            var y: CGFloat = 0
            while y <= bounds.height {
                var x: CGFloat = 0
                while x <= bounds.width {
                    context.fillEllipse(
                        in: CGRect(
                            x: x - markWidth / 2,
                            y: y - markWidth / 2,
                            width: markWidth,
                            height: markWidth
                        )
                    )
                    x += spacing
                }
                y += spacing
            }

        case .grid:
            var x: CGFloat = 0
            while x <= bounds.width {
                context.move(to: CGPoint(x: x, y: 0))
                context.addLine(to: CGPoint(x: x, y: bounds.height))
                x += spacing
            }
            var y: CGFloat = 0
            while y <= bounds.height {
                context.move(to: CGPoint(x: 0, y: y))
                context.addLine(to: CGPoint(x: bounds.width, y: y))
                y += spacing
            }
            context.strokePath()

        case .diagonalGrid:
            var origin = -bounds.height
            while origin <= bounds.width + bounds.height {
                context.move(to: CGPoint(x: origin, y: 0))
                context.addLine(to: CGPoint(x: origin + bounds.height, y: bounds.height))
                context.move(to: CGPoint(x: origin, y: bounds.height))
                context.addLine(to: CGPoint(x: origin + bounds.height, y: 0))
                origin += spacing
            }
            context.strokePath()

        case .perspectiveGrid:
            // The reference starts from a regular square grid, doubles its width, then tips it
            // away from the viewer. Reconstruct the visible result directly: horizontal rows
            // compress toward a horizon while the verticals converge on its centre. Keeping it
            // vector-drawn means a custom theme gets the same perspective at every pane size.
            let horizonY = bounds.height * 0.62
            let vanishingX = bounds.midX
            context.saveGState()
            context.clip(
                to: CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: horizonY)
            )

            var endpoint = bounds.minX - bounds.width
            while endpoint <= bounds.maxX + bounds.width {
                context.move(to: CGPoint(x: endpoint, y: bounds.minY))
                context.addLine(to: CGPoint(x: vanishingX, y: horizonY))
                endpoint += spacing
            }

            var row = bounds.minY
            var rowGap = spacing
            while row < horizonY - 1, rowGap >= 2 {
                context.move(to: CGPoint(x: bounds.minX, y: row))
                context.addLine(to: CGPoint(x: bounds.maxX, y: row))
                row += rowGap
                rowGap *= 0.93
            }
            context.strokePath()
            context.restoreGState()
        }
    }
}

/// An exterior-only companion layer for one half of a material shadow.
///
/// A transparent `CALayer` with only a `shadowPath` sounds like a shape-only caster, but Core
/// Animation composites that shadow above its parent's background. A centred opaque shadow
/// therefore fills the whole face it is meant to sit behind — Cyberpunk's dark cards became
/// lime slabs with pale text. This layer draws the shadow into an expanded transparent canvas
/// and clears the caster's interior afterwards, leaving only the pixels outside the surface.
///
/// Drawn controls use the same layer for their primary shadow: shadowing the control's own layer
/// makes its title and glyph cast depth. The expanded canvas follows autoresizing, so a path
/// configured before Auto Layout cannot retain the surface's construction-time width.
private final class ThemeShadowLayer: CALayer {
    private var horizontalInset: CGFloat = 0
    private var verticalInset: CGFloat = 0
    private var haloColor = NSColor.clear.cgColor
    private var haloRadius: CGFloat = 0
    private var haloOffset = CGSize.zero

    var surfaceRadius: CGFloat = 0 {
        didSet {
            setNeedsLayout()
            setNeedsDisplay()
        }
    }

    override init() {
        super.init()
        needsDisplayOnBoundsChange = true
        drawsAsynchronously = false
        masksToBounds = false
    }

    override init(layer: Any) {
        let source = layer as? ThemeShadowLayer
        super.init(layer: layer)
        if let source {
            horizontalInset = source.horizontalInset
            verticalInset = source.verticalInset
            haloColor = source.haloColor
            haloRadius = source.haloRadius
            haloOffset = source.haloOffset
            surfaceRadius = source.surfaceRadius
        }
        needsDisplayOnBoundsChange = true
        drawsAsynchronously = false
        masksToBounds = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        needsDisplayOnBoundsChange = true
        drawsAsynchronously = false
        masksToBounds = false
    }

    func configure(
        hostBounds: CGRect,
        surfaceRadius: CGFloat,
        color: CGColor,
        radius: CGFloat,
        opacity: Float,
        offset: CGSize
    ) {
        horizontalInset = ceil(abs(offset.width) + radius * 2 + 1)
        verticalInset = ceil(abs(offset.height) + radius * 2 + 1)
        haloColor = color.copy(alpha: color.alpha * CGFloat(opacity)) ?? color
        haloRadius = radius
        haloOffset = offset
        self.surfaceRadius = surfaceRadius

        frame = CGRect(
            x: hostBounds.minX - horizontalInset,
            y: hostBounds.minY - verticalInset,
            width: hostBounds.width + horizontalInset * 2,
            height: hostBounds.height + verticalInset * 2
        )
        autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        contentsScale = NSScreen.main?.backingScaleFactor ?? 2

        // Retain the ordinary shadow properties as inspectable geometry, but draw the halo
        // ourselves. `shadowOpacity == 0` is load-bearing: allowing Core Animation to draw the
        // same path would put its interior wash back above the face.
        shadowColor = color
        shadowRadius = radius
        shadowOpacity = 0
        shadowOffset = offset
        updateSurfacePath()
        setNeedsDisplay()
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        updateSurfacePath()
        setNeedsDisplay()
    }

    override func draw(in context: CGContext) {
        let path = makeSurfacePath()

        context.saveGState()
        context.setShadow(offset: haloOffset, blur: haloRadius, color: haloColor)
        context.setFillColor(NSColor.black.cgColor)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()

        // The caster exists only to manufacture the outside shadow. Removing its exact face
        // after the blur leaves the host's authored fill and every label above it untouched.
        context.saveGState()
        context.setBlendMode(.clear)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
    }

    private var surfaceRect: CGRect {
        CGRect(
            x: horizontalInset,
            y: verticalInset,
            width: max(0, bounds.width - horizontalInset * 2),
            height: max(0, bounds.height - verticalInset * 2)
        )
    }

    private func makeSurfacePath() -> CGPath {
        let rect = surfaceRect
        let radius = min(max(0, surfaceRadius), min(rect.width, rect.height) / 2)
        return CGPath(
            roundedRect: rect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )
    }

    private func updateSurfacePath() {
        shadowPath = makeSurfacePath()
    }
}

extension NSView {

    /// Applies a rounded, filled surface using the design tokens.
    ///
    /// Uses `.continuous` corners, which is what macOS itself draws; the default circular
    /// curve looks subtly wrong beside system controls at these radii.
    /// Applies a rounded, filled surface using the design tokens — and remembers what it was
    /// given, so `AppThemeRefresh` can resolve the same colours again when the theme changes.
    ///
    /// The remembering is here rather than at the call sites because a `CGColor` is frozen at
    /// assignment: a themed colour handed to a layer stops being themed the moment it lands.
    /// Every one of this method's callers gets the re-apply for free.
    /// `glow: true` marks a surface as a *panel* — the theme's halo, if it has one, is drawn
    /// behind it. Off by default, because a glow on twenty colour swatches is a mistake and on
    /// a settings card is the point.
    func applySurface(
        fill: NSColor,
        radius: SurfaceRadius,
        border: NSColor? = nil,
        borderWidth: CGFloat? = nil,
        glow: Bool = false,
        controlGlow: Bool = false,
        pattern: SurfacePattern = .none,
        bevel: SurfaceBevel = .automatic
    ) {
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = radius.current

        // A bevel replaces the flat border outright — two edge colours and a hairline would
        // be three lines around one surface. The hard construction is square; soft relief
        // follows a rounded silhouette instead (see `AppTheme.Bevel.Style`).
        let bevelSpec = AppThemePalette.current.material.bevel
        let bevelSupportsCorner = bevelSpec?.style == .soft || radius.current == 0
        let bevelActive = bevelSpec != nil && bevel != .none && bevelSupportsCorner

        // Frozen in the view's **own** effective appearance rather than the thread's ambient
        // drawing appearance, which from setup code and notification handlers is whatever
        // AppKit last had in hand — the trap that froze a light window's cards dark. See
        // `applyLayerBackground`.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = fill.cgColor

            applyThemeBackdropPattern(pattern == .backdrop, radius: radius.current)

            applyThemeBevel(
                bevelActive ? bevel : nil,
                spec: bevelSpec,
                radius: radius.current,
                isPanel: { if case .panel = radius { return true } else { return false } }()
            )

            if let border, !bevelActive {
                layer?.borderWidth = borderWidth ?? radius.defaultBorderWidth
                layer?.borderColor = border.cgColor
            } else {
                // Surface state is replaceable. A focused control that loses focus must not
                // keep the previous state's accent ring merely because the next state has no
                // border.
                layer?.borderWidth = 0
                layer?.borderColor = nil
            }

            if controlGlow {
                applyThemeControlGlow(true, radius: radius.current)
            } else {
                applyThemeGlow(glow)
            }
        }
        recordSurface(
            fill: fill,
            border: border,
            borderWidth: borderWidth,
            radius: radius,
            glow: glow,
            controlGlow: controlGlow,
            pattern: pattern,
            bevel: bevel
        )
    }

    private func applyThemeBackdropPattern(_ participates: Bool, radius: CGFloat) {
        let name = "threading.backdropPattern"
        let existing = layer?.sublayers?.first { $0.name == name }
        guard participates,
              let spec = AppThemePalette.current.material.backdropPattern,
              let layer else {
            existing?.removeFromSuperlayer()
            return
        }

        let patternLayer: ThemeBackdropPatternLayer
        if let existing = existing as? ThemeBackdropPatternLayer {
            patternLayer = existing
        } else {
            existing?.removeFromSuperlayer()
            patternLayer = ThemeBackdropPatternLayer()
            patternLayer.name = name
            patternLayer.frame = layer.bounds
            patternLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            layer.insertSublayer(patternLayer, at: 0)
        }

        patternLayer.kind = spec.kind
        patternLayer.ink = AppThemePalette.current.resolved(spec.role).cgColor
        patternLayer.opacity = Float(spec.opacity)
        patternLayer.spacing = spec.spacing
        patternLayer.markWidth = spec.lineWidth
        patternLayer.cornerRadius = radius
        patternLayer.contentsScale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        patternLayer.setNeedsDisplay()
    }

    /// Installs, updates, or strips the two-tone edge a bevel material asks for.
    ///
    /// Cleared rather than skipped when `participation` is nil — switching *away* from a
    /// bevel theme has to take every edge with it, the `applyThemeGlow` rule.
    ///
    /// Hard relief is drawn directly in a resizing layer so the compositor cannot stretch a
    /// one-point cap into a broad gray band. Soft relief remains a nine-part bitmap because its
    /// fixed caps contain a real blur. Both freeze their resolved colours like any recorded
    /// layer colour and are re-frozen by the theme sweep, which re-runs the whole application.
    private func applyThemeBevel(
        _ participation: SurfaceBevel?,
        spec: AppTheme.Bevel?,
        radius: CGFloat,
        isPanel: Bool
    ) {
        let name = "threading.bevel"
        let existing = layer?.sublayers?.first { $0.name == name }
        guard let participation, let spec, spec.width > 0, let layer else {
            existing?.removeFromSuperlayer()
            return
        }

        if spec.style == .hard {
            let hardLayer: ThemeHardBevelLayer
            if let existing = existing as? ThemeHardBevelLayer {
                hardLayer = existing
            } else {
                existing?.removeFromSuperlayer()
                hardLayer = ThemeHardBevelLayer()
                hardLayer.name = name
                hardLayer.frame = layer.bounds
                hardLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
                layer.addSublayer(hardLayer)
            }
            let quietPanelEdge = isPanel
            hardLayer.contentsScale = window?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor
                ?? BevelArtwork.scale
            hardLayer.isGeometryFlipped = layer.isGeometryFlipped
            hardLayer.configure(
                edgeWidth: quietPanelEdge ? BevelArtwork.softEdgeWidth : spec.width,
                colors: BevelArtwork.edgeColors(
                    highlight: Design.Surface.bevelHighlight,
                    shadow: Design.Surface.bevelShadow,
                    sunken: participation == .sunken,
                    soft: quietPanelEdge
                )
            )
            return
        }

        // The live clay reference mixes its inner relief: broad cards carry a recessed,
        // blurred edge inside an otherwise raised outer shadow, while compact controls carry
        // the opposite puff. Soft relief remains a nine-patch because its fixed caps contain a
        // genuine blur; hard pixel edges above are drawn at the destination size so no sampler
        // can ever enlarge their one-pixel rings.
        let softSunken = participation == .sunken || isPanel
        let image = SoftBevelArtwork.ninePatch(
            radius: radius,
            edgeWidth: spec.width,
            highlight: Design.Surface.bevelHighlight,
            shadow: Design.Surface.bevelShadow,
            sunken: softSunken,
            broad: softSunken
        )
        let contentsScale = SoftBevelArtwork.scale
        let contentsCenter = SoftBevelArtwork.contentsCenter(
            radius: radius,
            edgeWidth: spec.width,
            broad: softSunken
        )

        guard let image else {
            existing?.removeFromSuperlayer()
            return
        }

        let softExisting = existing is ThemeHardBevelLayer ? nil : existing
        if existing is ThemeHardBevelLayer {
            existing?.removeFromSuperlayer()
        }
        let bevelLayer = softExisting ?? CALayer()
        bevelLayer.name = name
        bevelLayer.frame = layer.bounds
        bevelLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        bevelLayer.contentsGravity = .resize
        bevelLayer.contentsScale = contentsScale
        bevelLayer.contentsCenter = contentsCenter
        bevelLayer.minificationFilter = .linear
        bevelLayer.magnificationFilter = .linear
        bevelLayer.contents = image
        if softExisting == nil {
            layer.addSublayer(bevelLayer)
        }
    }

    private func applyThemeGlow(_ wantsGlow: Bool) {
        applyThemeShadow(
            wantsGlow ? AppThemePalette.current.material.glow : nil,
            radius: layer?.cornerRadius ?? 0,
            primaryCompanionName: nil,
            highlightName: "threading.glow.highlight"
        )
    }

    /// Gives a drawn control the tighter shadow its material states. Drawn controls cannot use
    /// `applySurface` without freezing their live state, so they call this from `draw(_:)`; the
    /// explicit path keeps the title and glyph from becoming shadow casters themselves.
    func applyThemeControlGlow(_ wantsGlow: Bool, radius: CGFloat) {
        applyThemeControlGlow(
            wantsGlow ? AppThemePalette.current.material.controlGlow : nil,
            radius: radius
        )
    }

    /// Applies an explicit authored shadow while retaining the compact-control layer names.
    /// Buttons use this to select between CTA depth and neutral panel relief without changing
    /// the shadow renderer or making the face's title and glyph into casters.
    func applyThemeControlGlow(_ glow: AppTheme.Glow?, radius: CGFloat) {
        applyThemeShadow(
            glow,
            radius: radius,
            primaryCompanionName: "threading.controlGlow.primary",
            highlightName: "threading.controlGlow.highlight"
        )
    }

    private func applyThemeShadow(
        _ spec: AppTheme.Glow?,
        radius: CGFloat,
        primaryCompanionName: String?,
        highlightName: String
    ) {
        let existingPrimary = primaryCompanionName.flatMap { name in
            layer?.sublayers?.first { $0.name == name }
        }
        let existingHighlight = layer?.sublayers?.first { $0.name == highlightName }
        guard let spec else {
            // Cleared rather than skipped: switching *away* from a glowing theme has to take
            // the halo with it, and a layer keeps its shadow until told otherwise.
            layer?.shadowOpacity = 0
            layer?.shadowPath = nil
            existingPrimary?.removeFromSuperlayer()
            existingHighlight?.removeFromSuperlayer()
            return
        }

        guard let layer else { return }
        layer.masksToBounds = false
        if let primaryCompanionName {
            // A drawn control's layer contains its title and glyph. Even with a shadow path,
            // shadowing that layer lets those marks participate in Core Animation's source and
            // the duplicate ink is visible through translucent control fills. A transparent,
            // path-only sibling casts precisely the face silhouette instead.
            layer.shadowOpacity = 0
            layer.shadowPath = nil

            let primaryLayer: ThemeShadowLayer
            if let existing = existingPrimary as? ThemeShadowLayer {
                primaryLayer = existing
            } else {
                existingPrimary?.removeFromSuperlayer()
                primaryLayer = ThemeShadowLayer()
                primaryLayer.name = primaryCompanionName
                layer.insertSublayer(primaryLayer, at: 0)
            }
            primaryLayer.configure(
                hostBounds: layer.bounds,
                surfaceRadius: radius,
                color: AppThemePalette.current.resolved(spec.role).cgColor,
                radius: spec.radius,
                opacity: Float(spec.opacity),
                offset: CGSize(width: spec.offsetX, height: spec.offsetY)
            )
        } else {
            existingPrimary?.removeFromSuperlayer()
            layer.shadowColor = AppThemePalette.current.resolved(spec.role).cgColor
            layer.shadowRadius = spec.radius
            layer.shadowOpacity = Float(spec.opacity)
            layer.shadowOffset = CGSize(width: spec.offsetX, height: spec.offsetY)
            layer.shadowPath = nil
        }

        guard let highlight = spec.highlight else {
            existingHighlight?.removeFromSuperlayer()
            return
        }

        let highlightLayer: ThemeShadowLayer
        if let existing = existingHighlight as? ThemeShadowLayer {
            highlightLayer = existing
        } else {
            existingHighlight?.removeFromSuperlayer()
            highlightLayer = ThemeShadowLayer()
            highlightLayer.name = highlightName
            layer.insertSublayer(highlightLayer, at: 0)
        }
        highlightLayer.configure(
            hostBounds: layer.bounds,
            surfaceRadius: radius,
            color: AppThemePalette.current.resolved(highlight.role).cgColor,
            radius: highlight.radius,
            opacity: Float(highlight.opacity),
            offset: CGSize(width: highlight.offsetX, height: highlight.offsetY)
        )
    }
}

// MARK: - Hard Bevel Layer

/// Destination-sized classic edge drawing.
///
/// A hard bevel is four fixed pixel runs, so treating it as an image is needless risk: a
/// `contentsCenter` or compositor sampling disagreement can turn the cap into a broad gradient.
/// This layer redraws the exact rings in its current bounds. Soft relief remains bitmap-backed
/// because its blur genuinely needs fixed caps.
private final class ThemeHardBevelLayer: CALayer {
    private var edgeWidth: CGFloat = 1
    private var topLeftOuter = NSColor.white.cgColor
    private var topLeftInner = NSColor.white.cgColor
    private var bottomRightOuter = NSColor.black.cgColor
    private var bottomRightInner = NSColor.gray.cgColor

    override init() {
        super.init()
        needsDisplayOnBoundsChange = true
        drawsAsynchronously = false
    }

    override init(layer: Any) {
        super.init(layer: layer)
        guard let source = layer as? ThemeHardBevelLayer else { return }
        edgeWidth = source.edgeWidth
        topLeftOuter = source.topLeftOuter
        topLeftInner = source.topLeftInner
        bottomRightOuter = source.bottomRightOuter
        bottomRightInner = source.bottomRightInner
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        needsDisplayOnBoundsChange = true
        drawsAsynchronously = false
    }

    @MainActor
    func configure(edgeWidth: CGFloat, colors: BevelArtwork.EdgeColors) {
        self.edgeWidth = edgeWidth
        topLeftOuter = colors.topLeftOuter.cgColor
        topLeftInner = colors.topLeftInner.cgColor
        bottomRightOuter = colors.bottomRightOuter.cgColor
        bottomRightInner = colors.bottomRightInner.cgColor
        setNeedsDisplay()
    }

    override func draw(in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setAllowsAntialiasing(false)
        context.setShouldAntialias(false)

        let outer = max(1, (edgeWidth / 2).rounded(.down))
        let widths = (outer: outer, inner: max(0, edgeWidth - outer))
        func ring(
            _ rect: CGRect,
            width: CGFloat,
            topLeft: CGColor,
            bottomRight: CGColor
        ) {
            guard width > 0, rect.width > 0, rect.height > 0 else { return }
            let visualTopY = isGeometryFlipped ? rect.minY : rect.maxY - width
            let visualBottomY = isGeometryFlipped ? rect.maxY - width : rect.minY

            context.setFillColor(bottomRight)
            context.fill(CGRect(
                x: rect.maxX - width,
                y: rect.minY,
                width: width,
                height: rect.height
            ))
            context.fill(CGRect(
                x: rect.minX,
                y: visualBottomY,
                width: rect.width,
                height: width
            ))
            context.setFillColor(topLeft)
            context.fill(CGRect(
                x: rect.minX,
                y: visualTopY,
                width: max(0, rect.width - width),
                height: width
            ))
            context.fill(CGRect(
                x: rect.minX,
                y: isGeometryFlipped ? rect.minY : rect.minY + width,
                width: width,
                height: max(0, rect.height - width)
            ))
        }

        ring(
            bounds,
            width: widths.outer,
            topLeft: topLeftOuter,
            bottomRight: bottomRightOuter
        )
        ring(
            bounds.insetBy(dx: widths.outer, dy: widths.outer),
            width: widths.inner,
            topLeft: topLeftInner,
            bottomRight: bottomRightInner
        )
    }
}

// MARK: - Bevel Artwork

/// The one description of how a bevelled edge is built, shared by the destination-sized layer
/// path (`applyThemeBevel`), its artwork tests, and the draw path (`ThemedSurface`).
///
/// The construction is the classic `DrawEdge` one, not a mitre: **two square-cornered
/// rings**, the dark side owning both mixed corners (its right column runs the full height,
/// its bottom row the full width), so raised reads as a plate lit from the window's
/// top-leading corner. A first version drew a single two-point band with 45° mitred corners,
/// and every control looked like it was *casting a shadow* rather than standing proud — soft,
/// smeared, and outward. The period look is crisp because its four edge colours are four
/// distinct values: sheen and highlight on the lit side, frame-dark and shadow on the shaded
/// one, inverted exactly for sunken.
@MainActor
enum BevelArtwork {

    /// Rendered at retina scale whatever the display: a bevel is a hard-edged figure, and one
    /// backing scale keeps its rings identical across screens.
    static let scale: CGFloat = 2

    /// The stretchable middle's size in points — the smallest square `contentsCenter` can
    /// scale from without sampling the ring.
    static let stretchableCore: CGFloat = 2

    /// The four edge colours, derived from the theme's two roles: the sheen is the highlight
    /// pulled slightly toward the surface, the frame is the shadow pulled nearly to black —
    /// the classic `3DLIGHT`/`WINDOWFRAME` pair, stated as derivations so a theme authors
    /// two colours and gets four.
    struct EdgeColors {
        let topLeftOuter: NSColor
        let topLeftInner: NSColor
        let bottomRightOuter: NSColor
        let bottomRightInner: NSColor
    }

    /// `soft` is the panel variant: one point of highlight against one point of plain
    /// shadow, no near-black frame line. The period reserves the heavy two-ring build for
    /// *controls*; a large surface wearing it draws its edges as long dark bars across the
    /// window — which is exactly how it read here before the distinction existed.
    static func edgeColors(
        highlight: NSColor,
        shadow: NSColor,
        sunken: Bool,
        soft: Bool = false
    ) -> EdgeColors {
        // Both derivations were checked against a real 98 screenshot by sampling pixels:
        // the sheen lands on the measured #DEDEDE, and the frame line is *pure black* —
        // a first pass derived it at #131313, which is precisely the kind of almost that
        // reads as "the shadow is off" without the eye saying why.
        // 98.css names this rail #DFDFDF beneath a white highlight. An eighth-step toward
        // black lands on that exact byte; -0.12 rounded to #E0 and made every classic raised
        // face one value too bright despite the construction otherwise matching pixel-for-pixel.
        let sheen = highlight.lightened(by: -0.125)
        let frame = soft ? shadow : shadow.lightened(by: -1)
        return sunken
            ? EdgeColors(
                topLeftOuter: shadow,
                topLeftInner: frame,
                bottomRightOuter: highlight,
                bottomRightInner: sheen
            )
            : EdgeColors(
                topLeftOuter: highlight,
                topLeftInner: sheen,
                bottomRightOuter: frame,
                bottomRightInner: shadow
            )
    }

    /// A panel's edge width is the soft build's own: one point, whatever the material says
    /// buttons wear.
    static let softEdgeWidth: CGFloat = 1

    /// How a total edge width splits into the two rings: the outer takes the first point,
    /// the inner whatever remains (a one-point bevel is outer ring only).
    static func ringWidths(for edgeWidth: CGFloat) -> (outer: CGFloat, inner: CGFloat) {
        let outer = max(1, (edgeWidth / 2).rounded(.down))
        return (outer, max(0, edgeWidth - outer))
    }

    static func ninePatch(
        edgeWidth: CGFloat,
        highlight: NSColor,
        shadow: NSColor,
        sunken: Bool,
        soft: Bool = false
    ) -> CGImage? {
        let edgeWidth = soft ? softEdgeWidth : edgeWidth
        let side = edgeWidth * 2 + stretchableCore
        let pixels = Int(side * scale)
        guard pixels > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: pixels,
                  height: pixels,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        context.scaleBy(x: scale, y: scale)
        let bounds = CGRect(x: 0, y: 0, width: side, height: side)
        let colors = edgeColors(highlight: highlight, shadow: shadow, sunken: sunken, soft: soft)
        let widths = soft ? (outer: edgeWidth, inner: 0) : ringWidths(for: edgeWidth)

        // CG's origin is bottom-left, so "top" is maxY. The interior is never painted —
        // the fill beneath shows through the nine-patch's transparent middle.
        func ring(_ rect: CGRect, width: CGFloat, topLeft: NSColor, bottomRight: NSColor) {
            guard width > 0 else { return }
            context.setFillColor(bottomRight.cgColor)
            context.fill(CGRect(x: rect.maxX - width, y: rect.minY, width: width, height: rect.height))
            context.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: width))
            context.setFillColor(topLeft.cgColor)
            context.fill(CGRect(x: rect.minX, y: rect.maxY - width, width: rect.width - width, height: width))
            context.fill(CGRect(x: rect.minX, y: rect.minY + width, width: width, height: rect.height - width))
        }

        ring(bounds, width: widths.outer,
             topLeft: colors.topLeftOuter, bottomRight: colors.bottomRightOuter)
        ring(bounds.insetBy(dx: widths.outer, dy: widths.outer), width: widths.inner,
             topLeft: colors.topLeftInner, bottomRight: colors.bottomRightInner)

        return context.makeImage()
    }
}

// MARK: - Soft Bevel Artwork

/// The rounded counterpart to `BevelArtwork`: two blurred inset shadows rather than a painted
/// border. One enters from the top-leading edge and the other from the bottom-trailing edge;
/// raised controls put light first, while wells and broad cards reverse them. That mixed inner
/// relief is what the live clay reference actually uses. A narrow ring made the same recipe read
/// as a lavender outline, especially around a large corner. The middle stays transparent so
/// layer-backed panels and live-drawn controls keep their own fill and content untouched.
@MainActor
enum SoftBevelArtwork {

    static let scale: CGFloat = 2
    private static let stretchableCore: CGFloat = 2

    private static func metrics(edgeWidth: CGFloat, broad: Bool) -> (travel: CGFloat, blur: CGFloat) {
        // The source's compact controls use 4/8 and its cards use 6/12. Core Graphics' shadow
        // blur is the Gaussian radius, approximately half CSS's box-shadow blur value.
        let travel = edgeWidth * (broad ? 2 : 4 / 3)
        return (travel, travel)
    }

    private static func geometry(
        radius: CGFloat,
        edgeWidth: CGFloat,
        broad: Bool
    ) -> (fixed: CGFloat, side: CGFloat) {
        let metric = metrics(edgeWidth: edgeWidth, broad: broad)
        // Keep every blurred pixel in a fixed cap. Stretching through an inset fade would make
        // the long edges softer than the corners that join them.
        let fadeExtent = metric.travel + metric.blur * 2
        let fixed = max(fadeExtent, radius)
        return (fixed, fixed * 2 + stretchableCore)
    }

    static func contentsCenter(radius: CGFloat, edgeWidth: CGFloat, broad: Bool) -> CGRect {
        let geometry = geometry(radius: radius, edgeWidth: edgeWidth, broad: broad)
        return CGRect(
            x: geometry.fixed / geometry.side,
            y: geometry.fixed / geometry.side,
            width: stretchableCore / geometry.side,
            height: stretchableCore / geometry.side
        )
    }

    static func ninePatch(
        radius: CGFloat,
        edgeWidth: CGFloat,
        highlight: NSColor,
        shadow: NSColor,
        sunken: Bool,
        broad: Bool
    ) -> CGImage? {
        let geometry = geometry(radius: radius, edgeWidth: edgeWidth, broad: broad)
        let pixels = Int((geometry.side * scale).rounded(.up))
        guard pixels > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: pixels,
                  height: pixels,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        context.scaleBy(x: scale, y: scale)
        let bounds = CGRect(x: 0, y: 0, width: geometry.side, height: geometry.side)
        drawInsetRelief(
            in: context,
            bounds: bounds,
            visualTopY: bounds.maxY,
            visualBottomY: bounds.minY,
            radius: radius,
            edgeWidth: edgeWidth,
            highlight: highlight,
            shadow: shadow,
            sunken: sunken,
            broad: broad
        )
        return context.makeImage()
    }

    static func draw(
        shape: ThemedSurface.Shape,
        edgeWidth: CGFloat,
        highlight: NSColor,
        shadow: NSColor,
        sunken: Bool
    ) {
        guard let graphics = NSGraphicsContext.current else { return }
        let context = graphics.cgContext
        context.saveGState()
        defer { context.restoreGState() }

        let visualTopY = graphics.isFlipped ? shape.rect.minY : shape.rect.maxY
        let visualBottomY = graphics.isFlipped ? shape.rect.maxY : shape.rect.minY
        drawInsetRelief(
            in: context,
            bounds: shape.rect,
            visualTopY: visualTopY,
            visualBottomY: visualBottomY,
            radius: shape.radius,
            edgeWidth: edgeWidth,
            highlight: highlight,
            shadow: shadow,
            sunken: sunken,
            broad: sunken
        )
    }

    private static func drawInsetRelief(
        in context: CGContext,
        bounds: CGRect,
        visualTopY: CGFloat,
        visualBottomY: CGFloat,
        radius: CGFloat,
        edgeWidth: CGFloat,
        highlight: NSColor,
        shadow: NSColor,
        sunken: Bool,
        broad: Bool
    ) {
        let outerRadius = min(max(0, radius), min(bounds.width, bounds.height) / 2)
        let metric = metrics(edgeWidth: edgeWidth, broad: broad)
        let visualDown: CGFloat = visualBottomY > visualTopY ? 1 : -1
        let topLeading = sunken ? shadow : highlight
        let bottomTrailing = sunken ? highlight : shadow

        // An inset shadow is the shadow of the *outside* of the rounded rectangle falling into
        // its clipped interior. This gives the corner a true blurred offset curve: no coloured
        // ring to run around the whole corner, and no hard inner boundary where a fade ends.
        func inset(_ color: NSColor, offset: CGSize) {
            guard color.alphaComponent > 0 else { return }
            context.saveGState()
            defer { context.restoreGState() }

            let silhouette = CGPath(
                roundedRect: bounds,
                cornerWidth: outerRadius,
                cornerHeight: outerRadius,
                transform: nil
            )
            context.addPath(silhouette)
            context.clip()
            context.setShadow(offset: offset, blur: metric.blur, color: color.cgColor)

            let reach = max(bounds.width, bounds.height) + metric.travel + metric.blur * 4
            let outside = bounds.insetBy(dx: -reach, dy: -reach)
            // Keep the opaque caster itself beyond the clipped silhouette. Sharing the exact
            // antialiased curve leaked a one-device-pixel dark seam before its shadow began —
            // precisely the hard outline this construction exists to remove.
            let casterGap: CGFloat = 1 / scale
            let casterHole = bounds.insetBy(dx: -casterGap, dy: -casterGap)
            let caster = CGMutablePath()
            caster.addRect(outside)
            caster.addRoundedRect(
                in: casterHole,
                cornerWidth: outerRadius + casterGap,
                cornerHeight: outerRadius + casterGap
            )
            context.addPath(caster)
            // The opaque caster is outside the silhouette and therefore outside the clip; only
            // its soft shadow enters the surface. The even-odd hole is the rounded surface.
            context.setFillColor(NSColor.black.cgColor)
            context.drawPath(using: .eoFill)
        }

        inset(
            topLeading,
            offset: CGSize(width: metric.travel, height: visualDown * metric.travel)
        )
        inset(
            bottomTrailing,
            offset: CGSize(width: -metric.travel, height: -visualDown * metric.travel)
        )
    }
}
