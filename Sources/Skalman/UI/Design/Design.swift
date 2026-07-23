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
        static var border: CGFloat { AppThemePalette.current.material.borderWidth }

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
        /// Height of the prompt box and anything else that reads as a primary input.
        static let inputHeight: CGFloat = 44

        /// How far a growing input climbs before it scrolls instead. Roughly eight lines:
        /// enough for a paragraph, short of taking the pane over.
        static let inputMaxHeight: CGFloat = 180
        /// Widest a column of content grows before it becomes hard to scan.
        static let readableWidth: CGFloat = 620
    }

    // MARK: - Typography

    /// A four-step scale. Sizes are paired with a weight, since the two only work together.
    enum Typography {
        /// The one emphasised string in a view — a project name, a pane title.
        static func heading() -> NSFont { .systemFont(ofSize: 20, weight: .semibold) }
        /// Supporting detail directly beneath a heading, such as a path.
        static func subheading() -> NSFont { .systemFont(ofSize: 12, weight: .regular) }
        /// Editable and readable content.
        static func body() -> NSFont { .systemFont(ofSize: 13, weight: .regular) }
        /// Labels on controls.
        static func control() -> NSFont { .systemFont(ofSize: 12, weight: .medium) }
        /// Section headings and other quiet, small type.
        static func caption() -> NSFont { .systemFont(ofSize: 11, weight: .semibold) }
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
        static var controlResting: NSColor { AppThemePalette.color(.controlResting) }

        /// The same control under the pointer.
        static var controlHover: NSColor { AppThemePalette.color(.controlHover) }

        /// A container holding content, such as the prompt box.
        static var panel: NSColor { AppThemePalette.color(.panel) }

        /// A container above a panel — a popover, a floating card.
        static var elevated: NSColor { AppThemePalette.color(.elevated) }

        static var border: NSColor { AppThemePalette.color(.border) }

        /// A rule between rows, quieter than a border around them.
        static var divider: NSColor { AppThemePalette.color(.divider) }

        /// The window's own backdrop.
        static var ground: NSColor { AppThemePalette.color(.ground) }

        /// Large structural areas — the sidebar.
        static var background: NSColor { AppThemePalette.color(.surface) }

        /// Draws attention to the one control that is ready to act.
        static var accent: NSColor { AppThemePalette.color(.accent) }
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
        static var tertiary: NSColor { AppThemePalette.color(.tertiaryLabel) }
        static var quaternary: NSColor { AppThemePalette.color(.quaternaryLabel) }

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
            return Design.Ink(
                base: base,
                label: base.withAlphaComponent(light ? 0.95 : 0.88),
                secondary: base.withAlphaComponent(light ? 0.70 : 0.62),
                tertiary: base.withAlphaComponent(light ? 0.50 : 0.44),
                quaternary: base.withAlphaComponent(light ? 0.32 : 0.28)
            )
        }
    }

    // MARK: - Ink

    /// The four label tiers, resolved against a ground the theme does not own.
    ///
    /// Handed to a `BackdropOverlay` rather than read from `Design.Text`, which answers for the
    /// chrome's ground and is wrong over the window's backdrop by exactly the amount the two
    /// palettes differ.
    struct Ink {

        /// The tone every value here is cut from: white over a dark ground, black over a light
        /// one. Held so each tier and surface is *the base at an opacity* rather than a dimming
        /// of the tier above it — `withAlphaComponent` replaces alpha rather than scaling it, and
        /// chaining it reads as a scale that it is not.
        let base: NSColor

        let label: NSColor
        let secondary: NSColor
        let tertiary: NSColor
        let quaternary: NSColor

        /// A control surface that reads on the same ground — the pill behind the usage summary,
        /// the card floating at the pane's corner.
        ///
        /// Derived rather than taken from `Design.Surface`, for the same reason as the ink: the
        /// chrome's resting fill is *its* label colour held at 8%, which over a backdrop of the
        /// opposite tone is either invisible or a bright smear.
        var surface: NSColor { base.withAlphaComponent(0.14) }
        var surfaceHover: NSColor { base.withAlphaComponent(0.24) }
        var border: NSColor { base.withAlphaComponent(0.30) }
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
        static let ramp: [NSColor] = [
            .systemBlue, .systemOrange, .systemPurple, .systemTeal, .systemPink, .systemIndigo
        ]
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
        /// Long enough to read as movement, short enough not to be waited on.
        static let quick: TimeInterval = 0.15
        static let standard: TimeInterval = 0.2
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
        radius: CGFloat,
        border: NSColor? = nil,
        glow: Bool = false
    ) {
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = radius
        layer?.backgroundColor = fill.cgColor

        if let border {
            layer?.borderWidth = Design.Radius.border
            layer?.borderColor = border.cgColor
        }

        applyThemeGlow(glow)
        recordSurface(fill: fill, border: border, radius: radius, glow: glow)
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
        layer?.shadowOffset = .zero
    }
}
