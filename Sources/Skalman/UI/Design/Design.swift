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
        static let panel: CGFloat = 12
        /// Smaller containers nested inside a panel.
        static let control: CGFloat = 8

        /// Fully rounded, for pill-shaped controls of a known height.
        static func pill(height: CGFloat) -> CGFloat { height / 2 }
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
        static var controlResting: NSColor {
            .unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.5)
        }

        /// The same control under the pointer.
        static var controlHover: NSColor {
            .unemphasizedSelectedContentBackgroundColor
        }

        /// A container holding content, such as the prompt box.
        static var panel: NSColor {
            .textBackgroundColor.withAlphaComponent(0.4)
        }

        static var border: NSColor { .separatorColor }

        /// Draws attention to the one control that is ready to act.
        static var accent: NSColor { .controlAccentColor }
    }

    // MARK: - Chat

    /// The conversation surface: the user's turns as bubbles, the agent's as flowing text.
    enum Chat {
        /// A user bubble never spans the pane — a short reply in a full-width box reads as
        /// shouting, and a wide box makes the eye travel for nothing.
        static let bubbleMaxWidthFraction: CGFloat = 0.78

        /// The bubble fill: the user's accent, dropped well below full so its own text stays
        /// legible and it does not compete with the agent's reply for attention.
        static var bubbleFill: NSColor {
            .controlAccentColor.withAlphaComponent(0.22)
        }

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
        static var toolRowActive: NSColor {
            .unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.5)
        }

        /// The rule above a user's turn.
        ///
        /// Spacing alone still left the eye hunting, because the rows above and below it are
        /// themselves separated by space. A line is unambiguous, and at this weight it reads as
        /// a fold in the page rather than as a border drawn around something.
        static var turnDivider: NSColor { .separatorColor.withAlphaComponent(0.5) }

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
        static var keyword: NSColor { .systemPurple }
        static var type: NSColor { .systemTeal }
        static var string: NSColor { .systemOrange }
        static var number: NSColor { .systemBlue }
        static var comment: NSColor { .tertiaryLabelColor }
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
    func applySurface(fill: NSColor, radius: CGFloat, border: NSColor? = nil) {
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = radius
        layer?.backgroundColor = fill.cgColor

        if let border {
            layer?.borderWidth = 1
            layer?.borderColor = border.cgColor
        }
    }
}
