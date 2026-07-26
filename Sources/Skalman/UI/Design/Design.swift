import AppKit

/// The app's design tokens.
///
/// Every measurement, weight and surface colour used by Skalman's own views comes from here,
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
enum Design {

    // MARK: - Spacing

    /// A 2/4/6/10/16/24/32 scale. Anything between these is almost always a mistake.
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
        /// Height of the prompt box and anything else that reads as a primary input.
        static let inputHeight: CGFloat = 44

        /// How far a growing input climbs before it scrolls instead. Roughly eight lines:
        /// enough for a paragraph, short of taking the pane over.
        static let inputMaxHeight: CGFloat = 180
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
        /// radius, the visible extent of the blur), pinned to that by `AppThemeTests`.
        static let glowGutter: CGFloat = 20
    }

    // MARK: - Typography

    /// A small semantic scale. Feature code chooses what text *does*, never an AppKit point
    /// size. Keeping even code, counters, placeholders, and decorative emoji here prevents a
    /// screen assembled from individually reasonable but mutually inconsistent 10/11/12/13pt
    /// decisions.
    enum Typography {
        /// The one emphasised string in a view — a project name, a pane title.
        static func heading() -> NSFont { .systemFont(ofSize: 20, weight: .semibold) }
        /// A compact title inside an otherwise empty content pane.
        static func placeholderTitle() -> NSFont { .systemFont(ofSize: 15, weight: .medium) }
        /// Supporting detail directly beneath a heading, such as a path.
        static func subheading() -> NSFont { .systemFont(ofSize: 12, weight: .regular) }
        /// Editable and readable content.
        static func body() -> NSFont { .systemFont(ofSize: 13, weight: .regular) }
        /// A project, pane, or toolbar title at body scale.
        static func emphasizedBody() -> NSFont { .systemFont(ofSize: 13, weight: .semibold) }
        /// Strong body copy used only by legacy form section labels.
        static func strongBody() -> NSFont { .systemFont(ofSize: 13, weight: .bold) }
        /// Labels on controls.
        static func control() -> NSFont { .systemFont(ofSize: 12, weight: .medium) }
        /// A quieter control label, such as a sidebar session.
        static func controlRegular() -> NSFont { .systemFont(ofSize: 12, weight: .regular) }
        /// Section headings and other quiet, small type.
        static func caption() -> NSFont { .systemFont(ofSize: 11, weight: .semibold) }
        /// Metadata and secondary copy that should not carry caption emphasis.
        static func detail(weight: NSFont.Weight = .regular) -> NSFont {
            .systemFont(ofSize: 11, weight: weight)
        }

        /// Tool subjects, paths, diffs, and other code-shaped content.
        static func code(weight: NSFont.Weight = .regular) -> NSFont {
            .monospacedSystemFont(ofSize: 11, weight: weight)
        }

        /// Inline code that must share the body's line box.
        static func inlineCode() -> NSFont {
            .monospacedSystemFont(ofSize: 12, weight: .regular)
        }

        /// A code sample inside the compact theme-preview card.
        static func previewCode() -> NSFont {
            .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        }

        /// Dense process metadata and compact hexadecimal values.
        static func compactCode() -> NSFont {
            .monospacedSystemFont(ofSize: 10, weight: .regular)
        }

        /// A compact tool identifier; deliberately halfway between code and metadata.
        static func compactToolName() -> NSFont {
            .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        }

        /// Numeric labels use fixed-width digits without making the surrounding prose code.
        static func numericBody() -> NSFont {
            .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        }

        static func numericControl() -> NSFont {
            .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        }

        static func numericDetail(weight: NSFont.Weight = .regular) -> NSFont {
            .monospacedDigitSystemFont(ofSize: 11, weight: weight)
        }

        /// Markdown headings scale from the caller's semantic body font while font construction
        /// remains inside the typography boundary.
        static func markdownHeading(from base: NSFont) -> NSFont {
            .systemFont(ofSize: base.pointSize + 3, weight: .semibold)
        }

        /// Emoji rendered as an application control mark, not prose.
        static func accountEmoji() -> NSFont { .systemFont(ofSize: 16) }
        static func emojiPickerCell() -> NSFont { .systemFont(ofSize: 19) }
    }

    // MARK: - Symbols

    enum Symbol {
        /// Beside a control's label.
        static let control: CGFloat = 11
        /// Disclosure chevrons, which should read as a hint rather than a control.
        static let chevron: CGFloat = 8

        static func configuration(_ pointSize: CGFloat, weight: NSFont.Weight = .regular)
            -> NSImage.SymbolConfiguration {
            .init(pointSize: pointSize, weight: weight)
        }
    }

    // MARK: - Surface

    /// Fills and borders, all derived from system colours so light and dark both work and
    /// the accent colour is the user's own.
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

        /// A container above a panel — a popover, a floating card.
        static var elevated: NSColor { AppThemePalette.color(.elevated) }

        static var border: NSColor {
            Accessibility.color(.border, increasedContrastAlphaFloor: 0.70)
        }

        /// A rule between rows, quieter than a border around them.
        static var divider: NSColor {
            Accessibility.color(.divider, increasedContrastAlphaFloor: 0.60)
        }

        /// The window's own backdrop.
        static var ground: NSColor { AppThemePalette.color(.ground) }

        /// Large structural areas — the sidebar.
        static var background: NSColor { AppThemePalette.color(.surface) }

        /// Draws attention to the one control that is ready to act.
        static var accent: NSColor { AppThemePalette.color(.accent) }

        /// A selected row inside app-owned chrome.
        static var selection: NSColor { AppThemePalette.color(.selection) }
    }

    // MARK: - Text

    /// The four label tiers, as roles rather than as system colours.
    ///
    /// These exist because the app made 150 direct calls to `NSColor.secondaryLabelColor` and
    /// friends — more than ten times the number of surface tokens — so a theme that reached
    /// only the surfaces would have repainted the containers and left every word in them alone.
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

        /// Surfaces cut from `base`, for a ground the theme does not own.
        init(
            base: NSColor,
            label: NSColor,
            secondary: NSColor,
            tertiary: NSColor,
            quaternary: NSColor
        ) {
            let increased = Accessibility.increasesContrast
            self.init(
                base: base,
                label: label,
                secondary: secondary,
                tertiary: tertiary,
                quaternary: quaternary,
                surface: base.withAlphaComponent(increased ? 0.22 : 0.14),
                surfaceHover: base.withAlphaComponent(increased ? 0.34 : 0.24),
                border: base.withAlphaComponent(increased ? 0.52 : 0.30)
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
            border: NSColor
        ) {
            self.base = base
            self.label = label
            self.secondary = secondary
            self.tertiary = tertiary
            self.quaternary = quaternary
            self.surface = surface
            self.surfaceHover = surfaceHover
            self.border = border
        }

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
                border: Design.Surface.border
            )
        }
    }

    // MARK: - Status

    /// What a session's state is drawn in, and what a result that went wrong is drawn in.
    enum Status {
        static var positive: NSColor { AppThemePalette.color(.statusPositive) }
        static var warning: NSColor { AppThemePalette.color(.statusWarning) }
        static var negative: NSColor { AppThemePalette.color(.statusNegative) }
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

        /// A surface materialising over content — the dropdown unfolding from its chip.
        static var appear: TimeInterval { reducesMotion ? 0 : 0.16 }

        /// The same surface leaving. Quicker than `appear`: arriving is information the eye
        /// follows, leaving is a decision already made.
        static var vanish: TimeInterval { reducesMotion ? 0 : 0.12 }

        /// One beat of a menu's confirmation blink — the chosen row flickering once before
        /// the panel fades, the acknowledgement every platform menu gives.
        static var confirmBeat: TimeInterval { reducesMotion ? 0 : 0.05 }

        /// The pause a repeating demonstration holds a finished state before starting the next
        /// — long enough to read the name that just arrived, short enough that a hovered row
        /// does not look finished.
        ///
        /// A caller guards on `reducesMotion` before scheduling rather than reading a zero hold
        /// as a cadence: a demonstration whose animation has already been collapsed is not a
        /// faster demonstration, it is a flicker, and the honest reduced form is to hold the
        /// name still.
        static var demonstrationHold: TimeInterval { reducesMotion ? 0 : 0.9 }
    }

    // MARK: - Accessibility

    /// The system display preferences that change how app-owned chrome must be drawn.
    ///
    /// AppKit adapts its own controls automatically. Our controls deliberately replace that
    /// chrome, so these preferences are design inputs just like the active theme. Test
    /// overrides keep the behavior deterministic without changing the user's Mac settings.
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
            NSColor(name: NSColor.Name("skalman.accessible.\(role.rawValue)")) { _ in
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
        label.attributedStringValue = text
        // Assigning attributed text turns wrapping back on, and a wrapping field has no
        // intrinsic *width* at all — it is a height-for-width view, which Auto Layout is free
        // to squash to nothing. Single-line mode gives it a definite width again.
        label.usesSingleLineMode = true
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }
}

// MARK: - View Helpers

/// The semantic corner a recorded surface should resolve on every theme change.
///
/// This is deliberately not a `CGFloat`. A theme may give several roles the same numeric
/// radius — Swiss makes panel, control, and pill corners all zero — so recovering the role by
/// comparing numbers loses information. Keeping the role lets a later theme resolve each one
/// independently.
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
        glow: Bool = false
    ) {
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = radius.current
        layer?.backgroundColor = fill.cgColor

        if let border {
            layer?.borderWidth = borderWidth ?? Design.Radius.border
            layer?.borderColor = border.cgColor
        } else {
            // Surface state is replaceable. A focused control that loses focus must not keep
            // the previous state's accent ring merely because the next state has no border.
            layer?.borderWidth = 0
            layer?.borderColor = nil
        }

        applyThemeGlow(glow)
        recordSurface(
            fill: fill,
            border: border,
            borderWidth: borderWidth,
            radius: radius,
            glow: glow
        )
    }

    private func applyThemeGlow(_ wantsGlow: Bool) {
        guard wantsGlow, let spec = AppThemePalette.current.material.glow else {
            // Cleared rather than skipped: switching *away* from a glowing theme has to take
            // the halo with it, and a layer keeps its shadow until told otherwise.
            layer?.shadowOpacity = 0
            return
        }

        layer?.masksToBounds = false
        layer?.shadowColor = AppThemePalette.current.resolved(spec.role).cgColor
        layer?.shadowRadius = spec.radius
        layer?.shadowOpacity = Float(spec.opacity)
        layer?.shadowOffset = CGSize(width: spec.offsetX, height: spec.offsetY)
    }
}
