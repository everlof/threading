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
        static let turnSpacing: CGFloat = 16

        /// The fixed-width column a tool row's glyph sits in, so rows align down the edge.
        static let toolIconWidth: CGFloat = 16
    }

    // MARK: - Motion

    enum Motion {
        /// Long enough to read as movement, short enough not to be waited on.
        static let quick: TimeInterval = 0.15
        static let standard: TimeInterval = 0.2
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
