import AppKit

/// A theme rendered as a small image: its ground, a prompt in its text colour, and a band of
/// its ANSI hues.
///
/// It exists because every place a theme is *chosen* — a menu item, a list row — otherwise
/// offers only its name, and a name says nothing about what the theme looks like. Drawn rather
/// than composed from views so the same compact preview can be painted by a themed dropdown row
/// or a list without either rebuilding a miniature terminal hierarchy.
@MainActor
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

    private enum AppLayout {
        static let radiusFraction: CGFloat = 0.12
        static let sidebarFraction: CGFloat = 0.3
        static let padFraction: CGFloat = 0.09
        static let barHeightFraction: CGFloat = 0.07
        static let firstBarFraction: CGFloat = 0.55
        static let secondBarFraction: CGFloat = 0.38
        static let sidebarBarFraction: CGFloat = 0.55
        static let chipWidthFraction: CGFloat = 0.24
        static let chipHeightFraction: CGFloat = 0.1
        /// Four palette squares along the bottom of the content area — the terminal the theme
        /// pairs with, said in the fewest possible pixels.
        static let hueSideFraction: CGFloat = 0.09
    }

    /// Beside a name in a menu, where the row is one line tall.
    static func menuSwatch(for theme: TerminalTheme) -> NSImage {
        make(for: theme, size: Layout.menuSize, showsPrompt: false)
    }

    /// An *app* theme as a miniature window: its ground, its sidebar, two lines of its ink, its
    /// accent, and a hint of the terminal palette it pairs with.
    ///
    /// Exists for the same reason the terminal swatches do — everywhere an app theme is chosen
    /// there is otherwise only a name — but drawn as a window because that is what an app theme
    /// paints. Resolved for a stated appearance so a grid of tiles can show every theme as it
    /// would look *if chosen*, not filtered through the theme currently applied.
    static func appSwatch(for theme: AppTheme, size: NSSize, appearance: NSAppearance) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            appearance.performAsCurrentDrawingAppearance {
                drawAppSwatch(for: theme, appearance: appearance, in: rect)
            }
            return true
        }
        // Not a template: the whole point is the theme's own colours.
        image.isTemplate = false
        return image
    }

    private static func drawAppSwatch(
        for theme: AppTheme,
        appearance: NSAppearance,
        in rect: NSRect
    ) {
        let radius = rect.height * AppLayout.radiusFraction
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        path.addClip()

        theme.resolved(.ground, appearance: appearance).setFill()
        rect.fill()

        // The sidebar band, divided from the content the way the real window is — under System
        // the two surfaces share a colour and the divider is what says "sidebar" at all.
        let sidebarWidth = rect.width * AppLayout.sidebarFraction
        let sidebar = NSRect(x: rect.minX, y: rect.minY, width: sidebarWidth, height: rect.height)
        theme.resolved(.surface, appearance: appearance).setFill()
        sidebar.fill()
        theme.resolved(.divider, appearance: appearance).setFill()
        NSRect(x: sidebar.maxX, y: rect.minY, width: 1, height: rect.height).fill()

        let pad = rect.height * AppLayout.padFraction
        let barHeight = rect.height * AppLayout.barHeightFraction

        func bar(x: CGFloat, y: CGFloat, width: CGFloat, colour: NSColor) {
            colour.setFill()
            NSBezierPath(
                roundedRect: NSRect(x: x, y: y, width: width, height: barHeight),
                xRadius: barHeight / 2,
                yRadius: barHeight / 2
            ).fill()
        }

        // Two rows in the sidebar, two lines and an accent chip in the content: the fewest
        // marks that still read as "a window wearing this theme".
        let secondary = theme.resolved(.secondaryLabel, appearance: appearance)
        bar(
            x: sidebar.minX + pad,
            y: rect.maxY - pad - barHeight,
            width: sidebarWidth * AppLayout.sidebarBarFraction,
            colour: secondary
        )
        bar(
            x: sidebar.minX + pad,
            y: rect.maxY - pad * 2 - barHeight * 2,
            width: sidebarWidth * AppLayout.sidebarBarFraction * 0.75,
            colour: secondary
        )

        let content = NSRect(
            x: sidebar.maxX + pad,
            y: rect.minY + pad,
            width: rect.maxX - sidebar.maxX - pad * 2,
            height: rect.height - pad * 2
        )
        bar(
            x: content.minX,
            y: content.maxY - barHeight,
            width: content.width * AppLayout.firstBarFraction,
            colour: theme.resolved(.label, appearance: appearance)
        )
        bar(
            x: content.minX,
            y: content.maxY - pad - barHeight * 2,
            width: content.width * AppLayout.secondBarFraction,
            colour: secondary
        )

        let chipHeight = rect.height * AppLayout.chipHeightFraction
        theme.resolved(.accent, appearance: appearance).setFill()
        NSBezierPath(
            roundedRect: NSRect(
                x: content.minX,
                y: content.maxY - pad * 2 - barHeight * 2 - chipHeight,
                width: content.width * AppLayout.chipWidthFraction,
                height: chipHeight
            ),
            xRadius: chipHeight / 2,
            yRadius: chipHeight / 2
        ).fill()

        let palette = theme.terminalPalette(for: appearance)
        let hues = [palette.red, palette.green, palette.blue, palette.brightMagenta]
        let side = rect.height * AppLayout.hueSideFraction
        for (index, hue) in hues.enumerated() {
            hue.setFill()
            NSRect(
                x: content.minX + (side + side / 2) * CGFloat(index),
                y: content.minY,
                width: side,
                height: side
            ).fill()
        }

        theme.resolved(.border, appearance: appearance).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    /// In a list of themes, where there is room for the prompt that makes it read as a terminal.
    static func listSwatch(for theme: TerminalTheme) -> NSImage {
        make(for: theme, size: Layout.listSize, showsPrompt: true)
    }

    static func make(for theme: TerminalTheme, size: NSSize, showsPrompt: Bool) -> NSImage {
        let border = Design.Surface.border
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

            border.setStroke()
            path.lineWidth = 1
            path.stroke()

            return true
        }

        // Not a template: the whole point is the theme's own colours, which tinting would flatten.
        image.isTemplate = false
        return image
    }
}
