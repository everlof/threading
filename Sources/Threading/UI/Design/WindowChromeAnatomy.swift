import AppKit

// MARK: - Caption Button Anatomy

/// Everything one caption-button family states about itself, in one row of one table.
///
/// `WindowChromeButton` had grown a per-family switch for each thing a family could vary —
/// slot size, plate recipe, antialiasing, press behaviour, glyph alphabet, cluster spacing —
/// so a new family cost an edit in every switch and a fix to one switch was invisible to its
/// siblings (Aqua's resting gems were drawing the generic vector glyph because one arm of the
/// glyph dispatch fell through — found the day the dispatch became this table). The
/// interpreter stays singular, the tab strip's "every" lesson; this table is the one place
/// the families differ. A new `ButtonGlyphStyle` case is a new row here plus its artwork in
/// `WindowChromeCaptionArtwork`, and nothing else.
///
/// The measurements in each row are measured period metrics, deliberately not `Design`
/// tokens: a caption slot is period hardware rather than app vocabulary. Promoting the slot
/// and the Aqua gel tints to authored `WindowChromeStyle` fields is the recorded follow-up in
/// `docs/architecture/window-chrome.md`; until then a custom theme picks a family and gets
/// its measured anatomy.
struct WindowChromeCaptionAnatomy {

    /// Whether the family is pixel art. A pixel family draws with antialiasing off — its
    /// plates and figures were bitmaps, and every edge in them is one hard pixel; smoothing
    /// turns those into gray halos, which reads as a soft, faded imitation however correct
    /// the colours are. Compared against a real screenshot side by side, this is the single
    /// largest difference.
    enum Rendering {
        case pixel
        case smooth
    }

    /// The plate under the figure — the part of the family that answers hover, press, and
    /// the window's key state.
    enum Plate {
        enum GelRecipe: Equatable {
            case cheetah
            case tiger
        }

        /// No plate: bare glyphs in the band's own ink, lifted on hover the way a toolbar
        /// button is.
        case none
        /// The theme's control surface, so the glyph reads on the plate rather than on the
        /// band. `hoverLifts` raises the resting fill to `elevated` on hover (the Windows
        /// plates do; Platinum's and OPENSTEP's boxes answer only the press).
        case control(hoverLifts: Bool)
        /// Cut from the band gradient's first stop, which is what makes the box read as part
        /// of the band while the raised edge keeps it independently pressable.
        /// `dimsWithWindow` follows the inactive gradient when the window resigns key (BeOS's
        /// tab boxes and Intuition's gadgets do; 4Dwm's plates keep their olive).
        /// `pressedUsesControlHover` swaps the fill for the pressed control surface instead
        /// of keeping the band's colour under a sunken edge.
        case band(dimsWithWindow: Bool, pressedUsesControlHover: Bool)
        /// Aqua's coloured glass, drawn per role by the button's gel painter. Cheetah and
        /// Tiger share the semantic traffic-light family but not the same glass construction.
        case gel(GelRecipe)
        /// Nothing at rest, and the cell inverted under the pointer: the band's ink becomes
        /// the fill and the band's ground becomes the figure. This is how a terminal has
        /// marked the cell you are on since it was the only thing it could do, and it is the
        /// one plate whose *glyph* ink is decided by the plate rather than by `glyphInk`.
        case reverseVideo
    }

    /// Where the figure's ink comes from.
    enum GlyphInk {
        /// The theme's label ink — the plate is an application surface.
        case label
        /// The band's stated ink, dimmed with the window — the figure sits on the band.
        case band
        /// A fixed ink the family owns (Aqua's near-black on glass).
        case fixed(NSColor)
    }

    /// How the figures draw.
    enum Alphabet {
        /// The generic vector alphabet — shapes, never a font's rendition of them.
        case vector
        /// Aqua's thin round-capped strokes, shown on the gel.
        case aquaGel
        /// One-bit artwork from `WindowChromeCaptionArtwork`, rendered on the pixel grid.
        case bitmap((WindowChromeButton.Role, _ restored: Bool) -> WindowChromeCaptionArtwork.Bitmap)
    }

    /// The button's fixed slot. Nil means the generic takeover slot
    /// (`Design.Size.windowButtonWidth/Height`).
    let slotSize: NSSize?
    let rendering: Rendering
    let plate: Plate
    /// An extra one-point rule of the border role around the plate — 4Dwm's workstation
    /// outline, not an extra theme-specific surface.
    let outlinedInBorder: Bool
    let glyphInk: GlyphInk
    /// Aqua shows its figures only under the pointer; every other family wears them always.
    let glyphsRequireHover: Bool
    /// Raised bitmap-era controls move their figure with the pressed face. This is one
    /// physical-button rule shared by the hard retro families; leaving the glyph behind made
    /// the bevel invert while its contents appeared painted on the window.
    let pressedGlyphOffset: NSPoint
    /// Spacing between clustered buttons in the band. The pixel families abut at a hairline;
    /// Aqua's gems keep the period's visible gap.
    let clusterSpacing: CGFloat
    /// Optical displacement of the complete operation cluster inside the title band. Most
    /// families centre their hit targets; Win95/98 seats the 14px plates against the bottom
    /// of its 18px caption, leaving the measured four rows of caption/frame above them.
    let clusterVerticalOffset: CGFloat
    /// Optional grouping gap before Close. The Windows caption is not three evenly spaced
    /// buttons: Minimize and Maximize share an edge, followed by a two-pixel break and Close.
    let closeGroupSpacing: CGFloat?
    /// Insets from the authored title-band edge to each operation cluster. Most families use
    /// the app's tight spacing; Platinum's split 14px slots sit at asymmetric native frame
    /// coordinates, two pixels from the leading edge and three from the trailing edge.
    let leadingEdgeInset: CGFloat
    let trailingEdgeInset: CGFloat
    /// Gap from the leading identity/button cluster to a leading-aligned caption. Unlike app
    /// content spacing this is frame hardware: 4Dwm seats its italic title only four pixels
    /// from the window-menu plate.
    let titleGap: CGFloat
    /// Optical displacement of the caption text. Platinum's Charcoal baseline sits one
    /// native pixel above modern Geneva's geometric centre.
    let titleVerticalOffset: CGFloat
    /// Horizontal optical displacement of the caption text. A fallback font can have the
    /// right advance and still carry different side bearings from the historical face.
    let titleHorizontalOffset: CGFloat
    let alphabet: Alphabet

    init(
        slotSize: NSSize?,
        rendering: Rendering,
        plate: Plate,
        outlinedInBorder: Bool,
        glyphInk: GlyphInk,
        glyphsRequireHover: Bool,
        pressedGlyphOffset: NSPoint,
        clusterSpacing: CGFloat,
        titleGap: CGFloat,
        alphabet: Alphabet,
        clusterVerticalOffset: CGFloat = 0,
        closeGroupSpacing: CGFloat? = nil,
        leadingEdgeInset: CGFloat = Design.Spacing.tight,
        trailingEdgeInset: CGFloat = Design.Spacing.tight,
        titleVerticalOffset: CGFloat = 0,
        titleHorizontalOffset: CGFloat = 0
    ) {
        self.slotSize = slotSize
        self.rendering = rendering
        self.plate = plate
        self.outlinedInBorder = outlinedInBorder
        self.glyphInk = glyphInk
        self.glyphsRequireHover = glyphsRequireHover
        self.pressedGlyphOffset = pressedGlyphOffset
        self.clusterSpacing = clusterSpacing
        self.clusterVerticalOffset = clusterVerticalOffset
        self.closeGroupSpacing = closeGroupSpacing
        self.leadingEdgeInset = leadingEdgeInset
        self.trailingEdgeInset = trailingEdgeInset
        self.titleGap = titleGap
        self.titleVerticalOffset = titleVerticalOffset
        self.titleHorizontalOffset = titleHorizontalOffset
        self.alphabet = alphabet
    }

    /// Whether any part of the plate follows the window's key state — the catalogue sweep
    /// asks this to know which families must change pixels on `resignKey`.
    var plateFollowsKeyState: Bool {
        if case .band(dimsWithWindow: true, _) = plate { return true }
        return false
    }

    /// A recipe's figure follows the optical centre of its plate rather than blindly using
    /// the slot centre. Cheetah's odd-width glass is deliberately seated half a point toward
    /// the trailing edge inside its even-width hit target; its hover-only mark moves with it.
    var glyphOpticalOffset: NSPoint {
        if case .gel(.cheetah) = plate { return NSPoint(x: 0.5, y: 0) }
        // The Marlett figures sit one physical pixel above the geometric centre of their
        // 14px plates. Keeping that bias here aligns all three roles without distorting the
        // bitmap canvases that also encode Minimize's left/floor bias.
        if case .control = plate,
           slotSize == NSSize(width: 16, height: 14),
           clusterSpacing == 0,
           closeGroupSpacing != nil {
            return NSPoint(x: 0, y: 1)
        }
        return .zero
    }

    // MARK: - The Table

    @MainActor
    static func of(_ style: WindowChromeStyle.TitleBar.ButtonGlyphStyle?) -> WindowChromeCaptionAnatomy {
        switch style ?? .plain {
        case .plain:
            return WindowChromeCaptionAnatomy(
                slotSize: nil,
                rendering: .smooth,
                plate: .none,
                outlinedInBorder: false,
                glyphInk: .band,
                glyphsRequireHover: false,
                pressedGlyphOffset: .zero,
                clusterSpacing: Design.Spacing.hairline,
                titleGap: Design.Spacing.medium,
                alphabet: .vector
            )
        case .squares:
            // The default Win95/98 non-client metrics are not the generic takeover slot:
            // a caption button is 16×14 inside an 18px title bar. The former 18×16 plates
            // were visibly too broad beside the original even before comparing the marks.
            return WindowChromeCaptionAnatomy(
                slotSize: NSSize(width: 16, height: 14),
                rendering: .pixel,
                plate: .control(hoverLifts: true),
                outlinedInBorder: false,
                glyphInk: .label,
                glyphsRequireHover: false,
                pressedGlyphOffset: NSPoint(x: 1, y: -1),
                clusterSpacing: 0,
                titleGap: Design.Spacing.medium,
                alphabet: .bitmap(WindowChromeCaptionArtwork.windows98),
                clusterVerticalOffset: 2,
                closeGroupSpacing: Design.Spacing.hairline
            )
        case .platinum:
            // Platinum's three title boxes are 13–14px squares inside a 20px bar. Reusing
            // the generic 18x16 workstation plate consumed far too much of the pinstripe
            // field. The boxes are the same silver as the band and are separated by their
            // inset edge, not by a coloured fill; press reverses the edge through the
            // ordinary surface interpreter, preserving the one lighting model used
            // everywhere else.
            return WindowChromeCaptionAnatomy(
                slotSize: NSSize(width: 14, height: 14),
                rendering: .pixel,
                plate: .control(hoverLifts: false),
                outlinedInBorder: false,
                glyphInk: .label,
                glyphsRequireHover: false,
                pressedGlyphOffset: NSPoint(x: 1, y: -1),
                clusterSpacing: Design.Spacing.hairline,
                titleGap: Design.Spacing.medium,
                alphabet: .bitmap(WindowChromeCaptionArtwork.platinum),
                // The 14px hit slot sits two pixels above AppKit's geometric centre in the
                // source-tight 17px title band. A positive offset had put both caption boxes
                // two scanlines below the Appearance reference.
                clusterVerticalOffset: -1,
                leadingEdgeInset: 0,
                trailingEdgeInset: 1,
                titleVerticalOffset: -1
            )
        case .beOS:
            // The yellow tab is 19px high in the native R5 crop and seats compact, nearly square
            // boxes — cut from the tab itself, not from the gray application surface. That
            // shared yellow is what makes them read as part of the tab while the raised edge
            // keeps each operation independently pressable.
            return WindowChromeCaptionAnatomy(
                slotSize: NSSize(width: 16, height: 14),
                rendering: .pixel,
                plate: .band(dimsWithWindow: true, pressedUsesControlHover: false),
                outlinedInBorder: false,
                glyphInk: .band,
                glyphsRequireHover: false,
                pressedGlyphOffset: NSPoint(x: 1, y: -1),
                clusterSpacing: Design.Spacing.hairline,
                titleGap: Design.Spacing.tight,
                alphabet: .bitmap(WindowChromeCaptionArtwork.beOS),
                clusterVerticalOffset: 1,
                leadingEdgeInset: 2,
                trailingEdgeInset: 3,
                titleVerticalOffset: 1,
                titleHorizontalOffset: 1
            )
        case .openStep:
            // OPENSTEP is the one family whose period hardware *is* the generic slot: 18×16
            // gray plates seated in the black title band. They keep the application
            // material's hard directional light in both key states; only the surrounding
            // band changes when the window resigns key.
            return WindowChromeCaptionAnatomy(
                slotSize: nil,
                rendering: .pixel,
                plate: .control(hoverLifts: false),
                outlinedInBorder: false,
                glyphInk: .label,
                glyphsRequireHover: false,
                pressedGlyphOffset: NSPoint(x: 1, y: -1),
                clusterSpacing: Design.Spacing.hairline,
                titleGap: Design.Spacing.medium,
                alphabet: .bitmap(WindowChromeCaptionArtwork.openStep),
                trailingEdgeInset: 3
            )
        case .irix:
            // 4Dwm's end plates occupy 24×22 hit cells inside the 32px stepped frame. The
            // keyed renderer owns their native dithered resting pixels as part of the band;
            // these metrics keep the live semantic hit regions over those exact cells.
            return WindowChromeCaptionAnatomy(
                slotSize: NSSize(width: 24, height: 22),
                rendering: .pixel,
                plate: .band(dimsWithWindow: false, pressedUsesControlHover: true),
                outlinedInBorder: true,
                glyphInk: .label,
                glyphsRequireHover: false,
                pressedGlyphOffset: NSPoint(x: 1, y: -1),
                clusterSpacing: Design.Spacing.hairline,
                titleGap: Design.Spacing.tight,
                alphabet: .bitmap(WindowChromeCaptionArtwork.irix),
                clusterVerticalOffset: -3,
                leadingEdgeInset: 8,
                trailingEdgeInset: 8
            )
        case .amiga:
            // Intuition gadgets consume almost the full compact 18px title strip; the generic slot
            // made the same figures float in the blue rather than partition it. This is the
            // source-proportional component measure (the surviving captures are not native 1x).
            // The active blue is both the band and each gadget's plate; inactive gadgets fall
            // back to the Workbench gray with the rest of the title. Hard black/white bevel edges
            // and one-bit figures do all the separation.
            return WindowChromeCaptionAnatomy(
                slotSize: NSSize(width: 18, height: 16),
                rendering: .pixel,
                plate: .band(dimsWithWindow: true, pressedUsesControlHover: false),
                outlinedInBorder: false,
                glyphInk: .label,
                glyphsRequireHover: false,
                pressedGlyphOffset: NSPoint(x: 1, y: -1),
                clusterSpacing: Design.Spacing.hairline,
                titleGap: Design.Spacing.medium,
                alphabet: .bitmap(WindowChromeCaptionArtwork.amiga)
            )
        case .aqua:
            // Cheetah's traffic lights are 13px gems in a 22px pinstriped title band —
            // coloured glass, not flat semantic dots, with figures that appear only under
            // the pointer.
            return WindowChromeCaptionAnatomy(
                slotSize: NSSize(width: 14, height: 14),
                rendering: .smooth,
                plate: .gel(.cheetah),
                outlinedInBorder: false,
                glyphInk: .fixed(NSColor(calibratedWhite: 0.05, alpha: 0.72)),
                glyphsRequireHover: true,
                pressedGlyphOffset: .zero,
                clusterSpacing: 8,
                titleGap: Design.Spacing.medium,
                alphabet: .aquaGel
            )
        case .aquaTiger:
            // Tiger kept the 14px traffic-light slots but replaced Cheetah's almost equatorial
            // white band with a tighter specular cap and a darker circular rim. Keeping this
            // as its own authored family prevents a correction to one Aqua generation from
            // silently regressing the other.
            return WindowChromeCaptionAnatomy(
                slotSize: NSSize(width: 14, height: 14),
                rendering: .smooth,
                plate: .gel(.tiger),
                outlinedInBorder: false,
                glyphInk: .fixed(NSColor(calibratedWhite: 0.05, alpha: 0.72)),
                glyphsRequireHover: true,
                pressedGlyphOffset: .zero,
                clusterSpacing: 7,
                titleGap: Design.Spacing.medium,
                alphabet: .aquaGel
            )
        case .tui:
            // A caption cell rather than a caption button. The slot is two character cells
            // wide at the theme's own 12pt mono (SF Mono's advance is 7.2pt) and one line
            // tall, so the three operations read as `─ □ ✕` set in the title's own face and
            // sit on the same baseline grid as everything else the theme draws. The figures
            // are hairlines: a terminal has one pen width, and the two-pixel Marlett stems
            // borrowed at first made the cluster heavier than the title beside it.
            return WindowChromeCaptionAnatomy(
                slotSize: NSSize(width: 15, height: 15),
                rendering: .pixel,
                plate: .reverseVideo,
                outlinedInBorder: false,
                glyphInk: .band,
                glyphsRequireHover: false,
                pressedGlyphOffset: .zero,
                // One cell of air between operations, which is what separates them in a
                // status line. Abutting them made the three inverted cells read as one bar.
                clusterSpacing: Design.Spacing.small,
                titleGap: Design.Spacing.medium,
                alphabet: .bitmap(WindowChromeCaptionArtwork.tui),
                leadingEdgeInset: Design.Spacing.medium,
                trailingEdgeInset: Design.Spacing.medium
            )
        }
    }
}

// MARK: - Caption Artwork

/// The one-bit caption figures, as readable source artwork rather than drawing code.
///
/// Windows 98's Marlett reconstruction proved the shape: a bitmap the component tests can pin
/// exactly beats a `dot()`/`frame()` painter whose figure exists only as arithmetic — the
/// four other pixel families each carried their own private copy of that mini-DSL, and their
/// figures could not be asserted at all. Every family is now data over one legend, rendered
/// by one rasteriser:
///
///   `#` the figure's ink  ·  `o` white  ·  `+` the control face  ·  `.` clear
///
/// Most families are pure `#`/`.`; Workbench's Intuition gadgets are the three-colour
/// exception, deliberately using black, white, and Workbench gray rather than a modern
/// monochrome icon.
enum WindowChromeCaptionArtwork {

    struct Bitmap: Equatable {
        let rowsTopToBottom: [String]
        /// The em the figure is centred in. A figure shorter than its canvas sits on the
        /// canvas floor — Minimize's sill shares Maximize's nine-pixel Marlett cell rather
        /// than centring like a generic dash.
        let canvasHeight: Int

        init(rowsTopToBottom: [String], canvasHeight: Int? = nil) {
            self.rowsTopToBottom = rowsTopToBottom
            self.canvasHeight = canvasHeight ?? rowsTopToBottom.count
        }

        var width: Int { rowsTopToBottom.first?.count ?? 0 }
    }

    /// Draws a bitmap on the pixel grid: whole-pixel cells, bottom row on the canvas floor.
    /// An odd bitmap cannot have equal whole-pixel margins in an even-width button. The
    /// originals made the same one-pixel choice; bias top/leading and keep every cell whole.
    @MainActor
    static func draw(_ bitmap: Bitmap, in rect: NSRect, ink: NSColor) {
        let height = CGFloat(bitmap.rowsTopToBottom.count)
        let originX = floor(rect.midX - CGFloat(bitmap.width) / 2)
        let originY = floor(rect.midY - CGFloat(bitmap.canvasHeight) / 2)

        for (rowIndex, row) in bitmap.rowsTopToBottom.enumerated() {
            let y = originY + height - 1 - CGFloat(rowIndex)
            for (column, cell) in row.enumerated() {
                let color: NSColor?
                switch cell {
                case "#": color = ink
                case "o": color = .white
                case "+": color = Design.Surface.controlResting
                default: color = nil
                }
                guard let color else { continue }
                color.setFill()
                NSRect(x: originX + CGFloat(column), y: y, width: 1, height: 1).fill()
            }
        }
    }

    /// Win95/98 caption marks reconstructed from the Marlett figures Windows used for its
    /// non-client buttons: `r`'s close mark has two-pixel stair steps, `1` is a nine-pixel
    /// window with a two-pixel title rail, and `0` is a six-by-two sill. The previous
    /// seven-point canvas and single-pixel diagonals were crisp but visibly too small and
    /// too light.
    static func windows98(_ role: WindowChromeButton.Role, restored: Bool) -> Bitmap {
        switch role {
        case .windowMenu:
            return Bitmap(rowsTopToBottom: ["#######", "#######"])
        case .minimize:
            return Bitmap(
                // Marlett's six-pixel sill is left-biased inside an eight-pixel cell. The
                // cell, not an arbitrary optical nudge in the painter, preserves the source
                // position beside the odd-width Maximize figure.
                rowsTopToBottom: ["######..", "######.."],
                canvasHeight: 9
            )
        case .close:
            return Bitmap(rowsTopToBottom: [
                "##....##",
                ".##..##.",
                "..####..",
                "...##...",
                "..####..",
                ".##..##.",
                "##....##"
            ])
        case .zoom where restored:
            return Bitmap(rowsTopToBottom: [
                "..########",
                "..########",
                "..#......#",
                "########.#",
                "########.#",
                "#......#.#",
                "#......#.#",
                "#......#..",
                "########.."
            ])
        case .zoom:
            return Bitmap(rowsTopToBottom: [
                "#########",
                "#########",
                "#.......#",
                "#.......#",
                "#.......#",
                "#.......#",
                "#.......#",
                "#.......#",
                "#########"
            ])
        case .depth:
            return Bitmap(rowsTopToBottom: [
                "..########",
                "..#......#",
                "..#......#",
                "########.#",
                "#......#.#",
                "#......#.#",
                "#......#..",
                "########.."
            ])
        }
    }

    /// The Platinum window-frame figures. Deliberately not the Windows caption glyphs
    /// recoloured: Close is a small inset box, WindowShade is a pair of rules, and Zoom is
    /// the offset-window figure, on the eight-point grid the 1× originals targeted.
    static func platinum(_ role: WindowChromeButton.Role, restored: Bool) -> Bitmap {
        switch role {
        case .windowMenu:
            return Bitmap(rowsTopToBottom: [
                "........",
                "........",
                "........",
                ".######.",
                ".######.",
                "........",
                "........",
                "........"
            ])
        case .close:
            return Bitmap(rowsTopToBottom: [
                "........",
                ".######.",
                ".#....#.",
                ".#....#.",
                ".#....#.",
                ".#....#.",
                ".######.",
                "........"
            ])
        case .minimize:
            return Bitmap(rowsTopToBottom: [
                ".######.",
                "........",
                ".######.",
                "........",
                "........",
                "........",
                "........",
                "........"
            ])
        case .zoom where !restored:
            return Bitmap(rowsTopToBottom: [
                "########",
                "########",
                "#......#",
                "#......#",
                "#......#",
                "#......#",
                "#......#",
                "########"
            ])
        case .zoom, .depth:
            return offsetWindowsFigure
        }
    }

    /// BeOS's caption figures: tiny bitmap marks inside a raised yellow plate. Close is a
    /// solid stop box; Zoom is the two-level window figure shown at the other end of the
    /// tab. They intentionally do not borrow the Windows cross/maximize alphabet.
    static func beOS(_ role: WindowChromeButton.Role, restored: Bool) -> Bitmap {
        switch role {
        case .windowMenu:
            return platinum(.windowMenu, restored: false)
        case .close:
            return Bitmap(rowsTopToBottom: [
                "........",
                "........",
                "..####..",
                "..####..",
                "..####..",
                "..####..",
                "........",
                "........"
            ])
        case .minimize:
            return Bitmap(rowsTopToBottom: [
                "........",
                "........",
                "........",
                "........",
                "........",
                ".######.",
                ".######.",
                "........"
            ])
        case .zoom where !restored:
            return Bitmap(rowsTopToBottom: [
                "........",
                ".######.",
                ".######.",
                ".#....#.",
                ".#....#.",
                ".#....#.",
                ".######.",
                "........"
            ])
        case .zoom, .depth:
            return offsetWindowsFigure
        }
    }

    /// OPENSTEP 4.2's title figures: a nested-square miniaturize mark and the sharply
    /// aliased diagonal close figure from the NeXT window frame, as one-bit workstation
    /// drawing rather than a modern SF Symbol. Zoom borrows the nested-window alphabet —
    /// OPENSTEP does not normally expose it, but an authored theme may.
    static func openStep(_ role: WindowChromeButton.Role, restored: Bool) -> Bitmap {
        switch role {
        case .windowMenu:
            return platinum(.windowMenu, restored: false)
        case .minimize:
            return Bitmap(rowsTopToBottom: [
                "........",
                ".######.",
                ".#.####.",
                ".#.#.##.",
                ".#.####.",
                ".#....#.",
                ".######.",
                "........"
            ])
        case .close:
            return Bitmap(rowsTopToBottom: [
                "........",
                ".#....#.",
                "..#..#..",
                "...##...",
                "...##...",
                "..#..#..",
                ".#....#.",
                "........"
            ])
        case .zoom:
            return Bitmap(rowsTopToBottom: [
                "........",
                ".######.",
                ".######.",
                ".#....#.",
                ".#....#.",
                ".#....#.",
                ".######.",
                "........"
            ])
        case .depth:
            return Bitmap(rowsTopToBottom: [
                "........",
                "..#####.",
                "..#...#.",
                "###...#.",
                "#.#...#.",
                "#.#####.",
                "#.......",
                "#####..."
            ])
        }
    }

    /// The deliberately tiny 4Dwm figures visible in original IRIX 6.5 captures: a broad
    /// dash for the Window menu, a two-pixel minimization mark, and an outlined maximize
    /// box. The close diagonal shares OPENSTEP's construction without its heavier centre.
    static func irix(_ role: WindowChromeButton.Role, restored: Bool) -> Bitmap {
        switch role {
        case .windowMenu:
            return platinum(.windowMenu, restored: false)
        case .minimize:
            return Bitmap(rowsTopToBottom: [
                "........",
                "........",
                "........",
                "...##...",
                "...##...",
                "........",
                "........",
                "........"
            ])
        case .close:
            return openStep(.close, restored: false)
        case .zoom where !restored:
            return Bitmap(rowsTopToBottom: [
                "........",
                ".######.",
                ".#....#.",
                ".#....#.",
                ".#....#.",
                ".#....#.",
                ".######.",
                "........"
            ])
        case .zoom, .depth:
            return offsetWindowsFigure
        }
    }

    /// Workbench 3.1's Intuition gadget alphabet on its original grid. Close is the small
    /// upright inset lozenge — not a cross or a filled stop box; Zoom is the single recessed
    /// window; Depth is the unmistakable pair of overlapping windows at the far right.
    /// Workbench has no standard minimize gadget, but authored mixtures still need a
    /// coherent member of this family.
    static func amiga(_ role: WindowChromeButton.Role, restored: Bool) -> Bitmap {
        switch role {
        case .windowMenu:
            return Bitmap(rowsTopToBottom: [
                "..........",
                "..........",
                "..........",
                "..........",
                "..######..",
                "..######..",
                "..........",
                "..........",
                "..........",
                ".........."
            ])
        case .close:
            return Bitmap(rowsTopToBottom: [
                "..........",
                "...#####..",
                "...#o++#..",
                "...#o++#..",
                "...#o++#..",
                "...#o++#..",
                "...#o++#..",
                "...#ooo#..",
                "...#####..",
                ".........."
            ])
        case .minimize:
            return Bitmap(rowsTopToBottom: [
                "..........",
                "..........",
                "..######..",
                "..#oooo#..",
                "..#o##o#..",
                "..#o##o#..",
                "..#oooo#..",
                "..######..",
                "..........",
                ".........."
            ])
        case .zoom:
            return Bitmap(rowsTopToBottom: [
                "..........",
                ".########.",
                ".#o++####.",
                ".#o++oo##.",
                ".#o++####.",
                ".#o+++++#.",
                ".#o+++++#.",
                ".#oooooo#.",
                ".########.",
                ".........."
            ])
        case .depth:
            return Bitmap(rowsTopToBottom: [
                "..........",
                ".#######..",
                ".#o++++#..",
                ".#o#######",
                ".#o#o++++#",
                ".#o#o++++#",
                ".###o++++#",
                "...#ooooo#",
                "...#######",
                ".........."
            ])
        }
    }

    /// The text-mode caption cells: `─`, `□` and `✕` drawn as one-pixel figures on a seven-
    /// column cell, plus `≡` for the operations menu and the offset-windows pair for Restore.
    ///
    /// Hairlines throughout, which is the whole difference between this family and the
    /// desktop-era ones above it. Those systems drew their marks with a two-pixel pen because
    /// their captions were raised hardware and a thin figure disappeared into the bevel;
    /// a terminal has one pen, and borrowing Marlett's stems here made a cluster visibly
    /// heavier than the title it sits beside.
    static func tui(_ role: WindowChromeButton.Role, restored: Bool) -> Bitmap {
        switch role {
        case .windowMenu:
            return Bitmap(rowsTopToBottom: [
                "#######",
                ".......",
                "#######",
                ".......",
                "#######"
            ])
        case .minimize:
            // One rule on the cell's centre line, not a sill on its floor: `─` is a
            // box-drawing character and sits where the box's edge would run.
            return Bitmap(rowsTopToBottom: ["#######"])
        case .close:
            return Bitmap(rowsTopToBottom: [
                "#.....#",
                ".#...#.",
                "..#.#..",
                "...#...",
                "..#.#..",
                ".#...#.",
                "#.....#"
            ])
        case .zoom where !restored:
            return Bitmap(rowsTopToBottom: [
                "#######",
                "#.....#",
                "#.....#",
                "#.....#",
                "#.....#",
                "#.....#",
                "#######"
            ])
        case .zoom, .depth:
            return Bitmap(rowsTopToBottom: [
                "..######",
                "..#....#",
                "######.#",
                "#....#.#",
                "#....#.#",
                "#....###",
                "#....#..",
                "######.."
            ])
        }
    }

    /// The "two offset windows" Restore/Depth figure four families share. One statement,
    /// because it used to exist as five private copies of the same arithmetic — which is
    /// exactly how a fix to one would have missed the other four.
    private static let offsetWindowsFigure = Bitmap(rowsTopToBottom: [
        "........",
        "..#####.",
        "..#...#.",
        "#####.#.",
        "#.#.#.#.",
        "#.#####.",
        "#...#...",
        "#####..."
    ])
}

// MARK: - Bevel Edge

/// The classic raised two-ring edge, drawn from the material's bevel roles.
///
/// Shared by `WindowChromeFrameView` (the window's outer edge) and `WindowTitleBandView`
/// (the BeOS tab's edge) so the two are provably the same construction — each previously
/// carried a private, character-identical `ring()` copy, the erosion this file exists to
/// stop. `ThemedSurface.drawBevelled` remains the canonical construction for control-sized
/// surfaces; this is its window-edge sibling, where the ring is painted directly on the
/// band or frame ground rather than around a filled surface.
enum WindowChromeBevelEdge {

    @MainActor
    static func drawRaisedRings(around rect: NSRect) {
        let colors = BevelArtwork.edgeColors(
            highlight: Design.Surface.bevelHighlight,
            shadow: Design.Surface.bevelShadow,
            sunken: false
        )
        ring(rect, topLeft: colors.topLeftOuter, bottomRight: colors.bottomRightOuter)
        ring(
            rect.insetBy(dx: 1, dy: 1),
            topLeft: colors.topLeftInner,
            bottomRight: colors.bottomRightInner
        )
    }

    @MainActor
    private static func ring(_ box: NSRect, topLeft: NSColor, bottomRight: NSColor) {
        bottomRight.setFill()
        NSRect(x: box.maxX - 1, y: box.minY, width: 1, height: box.height).fill()
        NSRect(x: box.minX, y: box.minY, width: box.width, height: 1).fill()
        topLeft.setFill()
        NSRect(x: box.minX, y: box.maxY - 1, width: box.width - 1, height: 1).fill()
        NSRect(x: box.minX, y: box.minY + 1, width: 1, height: box.height - 1).fill()
    }
}
