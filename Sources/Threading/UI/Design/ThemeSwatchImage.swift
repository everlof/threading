import AppKit

/// A theme rendered as a small image: its ground, a prompt in its text colour, and a band of
/// its ANSI hues.
///
/// It exists because every place a theme is *chosen* — a menu item, a list row — otherwise
/// offers only its name, and a name says nothing about what the theme looks like. Drawn rather
/// than composed from views so the same compact preview can be painted by a themed dropdown row
/// or a list without either rebuilding a miniature terminal hierarchy.
enum ThemeSwatchImage {

    private enum Layout {
        static let menuSize = NSSize(width: 22, height: 14)
        static let listSize = NSSize(width: 44, height: 28)
        static let radiusFraction: CGFloat = 0.18
        /// The band of ANSI colour down the trailing edge, as a fraction of the width. Kept
        /// narrow: it is there to say what the palette is *like*, and at half the chip four
        /// saturated bands stop reading as a terminal and start reading as a colour picker.
        static let stripeFraction: CGFloat = 0.3
        static let promptFraction: CGFloat = 0.44
    }

    /// Beside a name in a menu, where the row is one line tall.
    static func menuSwatch(for theme: TerminalTheme) -> NSImage {
        make(for: theme, size: Layout.menuSize, showsPrompt: false)
    }

    /// In a list of themes, where there is room for the prompt that makes it read as a terminal.
    static func listSwatch(for theme: TerminalTheme) -> NSImage {
        make(for: theme, size: Layout.listSize, showsPrompt: true)
    }

    static func make(for theme: TerminalTheme, size: NSSize, showsPrompt: Bool) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            let radius = rect.height * Layout.radiusFraction
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            path.addClip()

            theme.background.setFill()
            path.fill()

            // Four hues over the theme's own ground: enough to tell a warm palette from a cold
            // one at this size, where sixteen would be a smear.
            let hues = [theme.red, theme.green, theme.blue, theme.brightMagenta]
            let stripeWidth = rect.width * Layout.stripeFraction
            let bandHeight = rect.height / CGFloat(hues.count)

            for (index, colour) in hues.enumerated() {
                colour.setFill()
                NSRect(
                    x: rect.maxX - stripeWidth,
                    y: rect.maxY - bandHeight * CGFloat(index + 1),
                    width: stripeWidth,
                    height: bandHeight
                ).fill()
            }

            if showsPrompt {
                let pointSize = rect.height * Layout.promptFraction
                let prompt = NSAttributedString(
                    string: "$_",
                    attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: pointSize, weight: .medium),
                        .foregroundColor: theme.foreground
                    ]
                )
                let size = prompt.size()
                prompt.draw(at: NSPoint(
                    x: rect.minX + pointSize * 0.5,
                    y: rect.midY - size.height / 2
                ))
            }

            Design.Surface.border.setStroke()
            path.lineWidth = 1
            path.stroke()

            return true
        }

        // Not a template: the whole point is the theme's own colours, which tinting would flatten.
        image.isTemplate = false
        return image
    }
}
