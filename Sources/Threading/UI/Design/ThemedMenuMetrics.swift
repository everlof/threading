import AppKit

// MARK: - Geometry

@MainActor
public enum ThemedMenuLayout {
    /// Modern popovers float off their opener. A classic dropdown is the other half of its
    /// control and starts on the control's edge, as a Win32 popup menu does.
    public static var gap: CGFloat { ThemedMenuMetrics.usesClassicGrammar ? 0 : Design.Spacing.tight }
    public static let screenInset: CGFloat = Design.Spacing.small
    /// The tallest panel a window may carry — a share of the window rather than a flat number.
    /// The cap was a flat 360, set when the longest menu was half its eventual size; by the
    /// time the session row's menu had grown, it overflowed that cap in every ordinarily sized
    /// window, which made scrolling the *normal* state and put Delete Session below the fold
    /// on every right-click. A menu's ceiling is the window it serves: a tall window shows the
    /// whole list, and the floor keeps a cramped window exactly where the flat cap left it.
    public static let maximumHeightRatio: CGFloat = 0.75
    public static let maximumHeightFloor: CGFloat = 360
    public static let maximumWidth: CGFloat = 440

    public static func maximumHeight(in bounds: NSRect) -> CGFloat {
        max(maximumHeightFloor, bounds.height * maximumHeightRatio)
    }

    /// How few rows a panel may be squeezed to before it stops being a list at all.
    ///
    /// The room beside a control is the room its window has, and a small window has almost
    /// none: a pop-up in a dialog sized to its own two lines of text opened a list of
    /// ninety-six quarter hours **one and a half rows tall**, which says "there is more here"
    /// and nothing else — not one answer the user could have been looking for was on screen.
    /// Four rows is where a dropdown starts reading as a list; below that the panel stops
    /// respecting the control's edge and takes the window instead (see `frame`), which is what
    /// a platform menu does on a screen too short to hold it.
    public static let minimumVisibleRows: CGFloat = 4

    public static var minimumUsefulHeight: CGFloat {
        ThemedMenuMetrics.verticalOuterInset * 2 + ThemedMenuMetrics.rowHeight * minimumVisibleRows
    }

    /// `whenClipped` is given the clamped height and answers with the one to use, which is how
    /// a panel that cannot show every row ends on half a row instead of on a clean edge. It is
    /// passed in rather than read from the entries so this stays plain geometry a test can call;
    /// `ThemedMenuMetrics.clippedHeight(for:atMost:)` is what every caller hands it.
    public static func frame(
        anchor: NSRect,
        desiredSize: NSSize,
        in bounds: NSRect,
        flipped: Bool,
        gap: CGFloat = ThemedMenuLayout.gap,
        whenClipped: (CGFloat) -> CGFloat = { $0 }
    ) -> NSRect {
        let width = min(desiredSize.width, max(0, bounds.width - screenInset * 2))
        let x = min(
            max(anchor.minX, bounds.minX + screenInset),
            max(bounds.minX + screenInset, bounds.maxX - screenInset - width)
        )

        let roomBefore: CGFloat
        let roomAfter: CGFloat
        if flipped {
            roomBefore = anchor.minY - bounds.minY - gap - screenInset
            roomAfter = bounds.maxY - anchor.maxY - gap - screenInset
        } else {
            roomBefore = bounds.maxY - anchor.maxY - gap - screenInset
            roomAfter = anchor.minY - bounds.minY - gap - screenInset
        }

        let opensAfter = roomAfter >= min(desiredSize.height, maximumHeight(in: bounds))
            || roomAfter >= roomBefore
        let available = max(0, opensAfter ? roomAfter : roomBefore)
        // The side is chosen against the clamped height, then the peek is taken out of it:
        // shortening a panel never changes which side it had room on.
        let ceiling = min(desiredSize.height, maximumHeight(in: bounds))
        // Neither side of the control can hold a readable list, so the panel stops clearing the
        // control and lies over it instead — every row the window can show, rather than the
        // sliver the gap below the control left. See `minimumUsefulHeight`.
        let overlapsAnchor = min(ceiling, available) < min(ceiling, minimumUsefulHeight)
        let clamped = overlapsAnchor
            ? min(ceiling, max(0, bounds.height - screenInset * 2))
            : min(ceiling, available)
        let height = clamped < desiredSize.height ? whenClipped(clamped) : clamped

        var y: CGFloat
        if flipped {
            y = opensAfter ? anchor.maxY + gap : anchor.minY - gap - height
        } else {
            y = opensAfter ? anchor.minY - gap - height : anchor.maxY + gap
        }
        if overlapsAnchor {
            // Slid back inside the window from wherever the control put it, so the panel keeps
            // the edge it was opened from while staying whole.
            y = min(
                max(y, bounds.minY + screenInset),
                max(bounds.minY + screenInset, bounds.maxY - screenInset - height)
            )
        }
        return NSRect(x: x, y: y, width: width, height: height)
    }

    /// How far a submenu tucks under its parent panel's edge. Panels that merely touched read
    /// as two unrelated windows; the platform's own submenus overlap for the same reason.
    public static var submenuOverlap: CGFloat {
        switch ThemedMenuMetrics.appearance {
        case .windows98: return 5
        case .automatic: return gap
        default: return 2
        }
    }

    /// Where a submenu panel lands: beside its parent panel, its first row level with the row
    /// that opened it. To the right until there is no room, then mirrored to the left; clamped
    /// vertically the way the root panel is.
    ///
    /// `firstRowInset` is the panel's own padding above its first row
    /// (`ThemedMenuMetrics.outerInset`), passed in so this stays plain geometry a test can call.
    public static func submenuFrame(
        parentPanel: NSRect,
        rowFrame: NSRect,
        desiredSize: NSSize,
        in bounds: NSRect,
        flipped: Bool,
        firstRowInset: CGFloat,
        whenClipped: (CGFloat) -> CGFloat = { $0 }
    ) -> NSRect {
        let width = min(desiredSize.width, maximumWidth, max(0, bounds.width - screenInset * 2))
        var x = parentPanel.maxX - submenuOverlap
        if x + width > bounds.maxX - screenInset {
            x = parentPanel.minX - width + submenuOverlap
        }
        x = min(max(x, bounds.minX + screenInset), bounds.maxX - screenInset - width)

        let clamped = min(
            desiredSize.height,
            maximumHeight(in: bounds),
            max(0, bounds.height - screenInset * 2)
        )
        let height = clamped < desiredSize.height ? whenClipped(clamped) : clamped
        let y: CGFloat
        if flipped {
            y = min(
                max(rowFrame.minY - firstRowInset, bounds.minY + screenInset),
                bounds.maxY - screenInset - height
            )
        } else {
            let top = min(
                max(rowFrame.maxY + firstRowInset, bounds.minY + screenInset + height),
                bounds.maxY - screenInset
            )
            y = top - height
        }
        return NSRect(x: x, y: y, width: width, height: height)
    }
}

/// The dropdown's column geometry. Internal rather than file-private so the columns can be
/// pinned by a test: a preview hosted in a row and a title drawn in one have to start at the
/// same place, and that is an arithmetic claim rather than something a render shows.
@MainActor
public enum ThemedMenuMetrics {
    /// Menus have their own authored anatomy. A chooser and the menu it opens are related, but
    /// Platinum's paired-arrow field does not imply its menu frame or row rhythm, and three
    /// workstation families all use a down-arrow popup while drawing different menus.
    public static var appearance: AppTheme.Material.MenuAppearance {
        AppThemePalette.current.material.menuAppearance
    }

    public static var usesClassicGrammar: Bool {
        appearance.isHistorical
    }

    /// Between the panel's edge and its rows, so a highlighted row's capsule floats inside
    /// the panel instead of grazing its border.
    public static var outerInset: CGFloat {
        switch appearance {
        case .platinum: return 1
        case .automatic: return Design.Spacing.small
        default: return 2
        }
    }

    /// The same, at the panel's two **ends**, where its corner is.
    ///
    /// A menu is a rounded panel whose rows are a scroll view's, and neither clips the other: the
    /// panel's corner lives on a layer that must keep its halo, and the rows are drawn inside a
    /// frame that was inset by the same 6pt at the ends as at the sides. Under a broad corner
    /// those 6pt are *outside* the silhouette — Botanical's 40pt corner has not curved past them
    /// until 19pt down — so a highlighted first or last row drew its fill past the panel's own
    /// border. Reported from a render as the inner fill protruding through the outer edge.
    ///
    /// So the rows start where the corner has finished. Every theme whose corner is at or under
    /// the margin keeps `outerInset` exactly, which is all of them but Botanical (19) and
    /// Claymorphism (14).
    public static var verticalOuterInset: CGFloat {
        let margin = outerInset
        let reach = Design.Radius.edgeReach(of: Design.Radius.panel, clearing: margin)
        return max(margin, reach.rounded(.up))
    }
    public static var rowHeight: CGFloat {
        switch appearance {
        case .platinum: return 19
        case .windows98: return 21
        case .automatic: return 28
        default: return 18
        }
    }
    /// Taller than the ink it holds, and deliberately so: a title and its subtitle are drawn as
    /// one centred block, so everything above this beyond that block becomes the gap to the row
    /// stacked against it. At 42 the two gaps came out ~18pt within a pair against ~24pt between
    /// them and the pairs did not read as pairs; 46 buys a little over 2:1, which is the point at
    /// which proximity does the grouping on its own — no rules, no alternating fill, both of
    /// which would have fought the hover pill this row draws at full bleed.
    /// Raised from 31 for the classic grammars once `subtitleGap` opened the pair: at 31 the two
    /// lines already filled all but 2.5pt of the slot, so the gap *between* two rows was narrower
    /// than the gap inside one and the column read as evenly spaced single lines rather than as
    /// pairs — the same fault 46 was chosen to avoid on the modern side.
    public static var subtitleRowHeight: CGFloat { usesClassicGrammar ? 36 : 46 }

    /// Between a title and the subtitle under it.
    ///
    /// It used to be nothing at all, on the argument that a line box already carries the font's
    /// own leading. That holds for the modern face and fails for the classic ones, whose line
    /// boxes are drawn tight around the glyphs: the two lines touched, and a name with its
    /// reading immediately beneath read as one wrapped sentence rather than as a heading and its
    /// detail. Small enough that the pair still groups by proximity against the row's own margins.
    public static var subtitleGap: CGFloat { Design.Spacing.hairline }
    /// How far a row's fill sits inside its own slot, so two *adjacent* filled rows are parted
    /// by a hairline rather than meeting.
    ///
    /// Rows are stacked edge to edge, and a fill drawn at the row's full height therefore shares
    /// an edge with the row above it. One filled row never showed this; two adjacent ones did —
    /// the two capsules fused into a single pinched blob, with their corner radii reading as a
    /// dent in one shape instead of the gap between two. A menu still gets there whenever a
    /// parent row holds the menu path while the pointer is on the row directly under it, during
    /// the grace its submenu is given to close.
    ///
    /// Half a hairline each side, so the gap the pair opens is the whole one. Same arithmetic,
    /// and the same 1pt, as the sidebar's `hoverHighlightInsetY`.
    public static var fillInset: CGFloat {
        usesClassicGrammar ? 0 : Design.Spacing.hairline / 2
    }
    /// A separator's slot. Sized so the gap it opens between two rows' text reads as the
    /// ordinary inter-row rhythm plus the rule — at the old 9pt the rule crowded whichever
    /// row's fill it sat against and the spacing read as unequal.
    public static var separatorHeight: CGFloat {
        appearance == .platinum ? 2 : (usesClassicGrammar ? 9 : 13)
    }
    /// The strip across the top echoing what has been typed while the menu is open.
    public static var filterHeaderHeight: CGFloat { usesClassicGrammar ? 18 : 22 }
    /// How far a filtered-out row's ink drops. Dimmed rather than hidden, so the menu keeps
    /// its shape while the user types and nothing moves under the pointer.
    public static let filteredOutDimming: CGFloat = 0.4
    /// A row that cannot be chosen at all.
    public static let disabledDimming: CGFloat = 0.45
    /// The wash a *disabled* row shows under the pointer — feedback that the hover was
    /// seen, well short of the fill that says "choosable".
    public static let disabledHoverWash: CGFloat = 0.4
    /// A row's own leading and trailing padding — also where the checkmark sits, which was
    /// previously drawn 4pt from the row's edge and read as pinned to the panel's side.
    public static var contentInset: CGFloat {
        appearance == .windows98 ? 5 : (usesClassicGrammar ? 4 : Design.Spacing.medium)
    }
    public static var checkSize: CGFloat { usesClassicGrammar ? 8 : 10 }
    /// The checkmark column: glyph plus the gap to whatever follows it.
    public static var leadingSlot: CGFloat {
        checkSize + (usesClassicGrammar ? 3 : Design.Spacing.small)
    }
    /// A row's leading mark — the **slot**, which caps the artwork rather than sizing it.
    ///
    /// It was 14, and that was a cap below what a symbol beside a label already renders at: SF
    /// configured at `Design.Symbol.control` comes out around 14–15pt, so most glyphs were being
    /// shrunk a little past their configuration, which thins the stroke off the weight the
    /// optical size chose and off the pixel grid with it. One icon in a menu of words absorbs
    /// that; a whole column of them does not, and the column is what these menus now have.
    /// `Design.Size.tabIconSlot` is the same slot every other mark-that-names-something in the
    /// chrome sits in.
    public static var imageSize: CGFloat { Design.Size.tabIconSlot }
    public static var imageSlot: CGFloat {
        imageSize + (usesClassicGrammar ? 3 : Design.Spacing.small)
    }
    /// A live preview's column. The orb is the widest thing that goes in it and states its own
    /// 20pt footprint, so the slot is that plus the gap to whatever follows — the same shape as
    /// the image column one size up, rather than a second guess at it.
    public static var previewSize: CGFloat { usesClassicGrammar ? 16 : 20 }
    public static var previewSlot: CGFloat {
        previewSize + (usesClassicGrammar ? 3 : Design.Spacing.tight)
    }

    /// The chevron marking a row that opens a submenu, and the column it sits in — trailing,
    /// where the platform's own submenu arrow lives.
    public static var submenuChevronSize: CGFloat {
        appearance == .windows98 ? 6 : (usesClassicGrammar ? 7 : 8)
    }
    public static var submenuTrailingInset: CGFloat {
        appearance == .windows98 ? 4 : contentInset
    }
    public static var submenuChevronSlot: CGFloat {
        submenuChevronSize + (usesClassicGrammar ? 4 : Design.Spacing.small)
    }

    /// The hover-revealed action's glyph, and the column it sits in — the outermost trailing one,
    /// outside the submenu chevron, because it is the only thing on a row that is *pressed* and a
    /// press wants the edge rather than a slot between two others.
    ///
    /// Smaller than a row's leading mark (`imageSize`): that column names what a row is and is
    /// read down the menu as a column, while this one is a control on a single row and is drawn
    /// only where the pointer already is.
    public static var accessorySize: CGFloat { usesClassicGrammar ? 11 : 13 }
    public static var accessorySlot: CGFloat {
        accessorySize + (usesClassicGrammar ? 4 : Design.Spacing.small)
    }
    /// How far past its glyph the press still lands. A 13pt symbol is a 13pt target, which is
    /// under half of what a pointer is aimed with; the padding is invisible and the difference
    /// between a control and a dare. It never reaches past the glyph's own column, so the row
    /// beside it keeps every pixel a press on the *row* can land on.
    public static var accessoryHitPadding: CGFloat { Design.Spacing.tight }
    /// What a press takes off the accessory's ink — the same answer `ThemedButton` gives a press,
    /// an alpha step rather than a second surface. A plate was drawn here first and was invisible:
    /// the row under it is *already* filled with `controlHover`, because the accessory only ever
    /// appears on the row the pointer or the highlight is on, so the press painted the hover fill
    /// over itself. Ink is the only channel this glyph has left, and it is enough.
    public static let accessoryPressedDimming: CGFloat = 0.55

    /// Reserved on the image column's terms — only when some row in this menu carries one — and
    /// then on **every** row of it. A slot that appeared with the pointer would reflow the title
    /// underneath it, so the width is spent whether or not the row draws anything in it.
    public static func hasAccessoryColumn(_ entries: [ThemedMenuEntry]) -> Bool {
        entries.contains { entry in
            guard case .item(let item) = entry else { return false }
            return item.accessory != nil
        }
    }

    public static var titleFont: NSFont {
        if appearance == .platinum {
            return Design.Typography.control(weight: .bold)
        }
        let font = usesClassicGrammar
            ? Design.Typography.controlRegular()
            : Design.Typography.control()
        guard appearance == .windows98 else { return font }

        // The shell's nominal eight-point menu face was rasterised at the 96-dpi logical
        // scale, while AppKit's point maps directly to a backing pixel in this 1x evidence
        // fixture. The 10/9 correction turns the theme's authored 9.6pt control role into the
        // measured 10.67px GDI raster without bypassing either the user's text-size preference
        // or the resolved MS Sans Serif/W95FA fallback family.
        return NSFont(
            descriptor: font.fontDescriptor,
            size: font.pointSize * 10 / 9
        ) ?? font
    }

    /// Classic GDI placed the menu face one device pixel below AppKit's centred line box.
    /// Keep this on the anatomy axis: a custom theme choosing Win98 menus inherits the same
    /// baseline, while a different menu family under the Win98 palette does not.
    public static var titleBaselineOffset: CGFloat {
        appearance == .windows98 ? -1 : 0
    }

    /// Win32 seats a 16px menu bitmap one device pixel above AppKit's geometric centre.
    public static var imageBaselineOffset: CGFloat {
        appearance == .windows98 ? 1 : 0
    }

    public static var panelFill: NSColor {
        usesClassicGrammar ? Design.Surface.controlResting : Design.Surface.elevated
    }

    public static var panelHasGlow: Bool { appearance == .automatic }

    /// The image column is reserved only when some item actually carries an image. Reserving
    /// it always left an 18pt hole between checkmark and title in every icon-less menu.
    public static func hasImageColumn(_ entries: [ThemedMenuEntry]) -> Bool {
        entries.contains { entry in
            guard case .item(let item) = entry else { return false }
            return item.image != nil
        }
    }

    /// Reserved on the image column's terms: only when some row actually opens a submenu, so a
    /// menu of plain actions keeps its trailing edge tight against the longest title.
    public static func hasSubmenuColumn(_ entries: [ThemedMenuEntry]) -> Bool {
        entries.contains { entry in
            guard case .item(let item) = entry else { return false }
            return item.submenu != nil
        }
    }

    /// Reserved on the same terms as the image column, and only for a preview that sits *beside*
    /// a title — one placed in the title's own slot occupies a column that already exists.
    public static func hasPreviewColumn(_ entries: [ThemedMenuEntry]) -> Bool {
        entries.contains { entry in
            guard case .item(let item) = entry else { return false }
            return item.preview?.placement == .leading
        }
    }

    // MARK: - Metric Columns

    /// The font every metric column is drawn and measured in. Tabular by role: a column of
    /// proportional digits is only accidentally a column, and `27%` over `81%` misaligning by
    /// the width of a `2` is the whole reason the numbers left the subtitle.
    public static var metricFont: NSFont {
        usesClassicGrammar ? titleFont : Design.Typography.numericDetail()
    }

    /// The bar between a column's name and its value. Wide enough that two readings differing
    /// by ten points differ visibly — the 14pt meter under `AccountMarkImage` could only ever
    /// carry a hue, which the value's own tint already said.
    public static var metricBarWidth: CGFloat { usesClassicGrammar ? 22 : 28 }

    /// The air around the rule between the columns and the trailing detail. Wider than the gap
    /// between two columns, because what it parts is a change of *kind* rather than the next
    /// window: readings and the countdown are not the same sort of fact, and at an equal gap
    /// `99%` and `7d · 5d 3h` ran together as one line of numbers.
    public static var metricDividerGap: CGFloat { Design.Spacing.inset }
    public static var metricDividerWidth: CGFloat { Design.Radius.border }
    /// Thick enough to hold a status hue at this size without becoming a second row of content.
    public static var metricBarHeight: CGFloat { Design.Spacing.tight - 1 }
    /// Inside a column: name, bar, value.
    public static var metricInnerGap: CGFloat { Design.Spacing.tight }
    /// Between one column and the next, and between the last one and the trailing detail. Wider
    /// than the inner gap, so a column reads as one group rather than as three loose runs.
    public static var metricColumnGap: CGFloat { Design.Spacing.medium }
    /// Below this a fill is shorter than its own cap and draws as a dot at the track's head.
    public static let metricMinimumFraction = 0.02
    /// How much of its ink an empty track keeps — of `tertiary` normally, and of a classic
    /// selection band's own label ink over a band, where an unrelated grey cannot be measured
    /// against the band's solid fill.
    public static let metricTrackOpacity: CGFloat = 0.45

    /// A 440-point menu cannot carry a provider-sized union of metric columns. Three preserves
    /// the common account pair plus one additional window while leaving a readable title slot.
    /// Callers keep omitted values in the row's bounded subtitle/tooltip projection.
    public static let maximumMetricColumns = 3

    /// The columns this menu reserves, in first-seen order.
    ///
    /// A union across every row rather than per row: a plan metering one window and a plan
    /// metering two must put their shared `7d` reading in the same place, which is exactly the
    /// comparison that a per-row layout destroys. The empty cell that leaves on the shorter
    /// plan's row is not a hole — it says that plan has no window there.
    public static func metricColumns(_ entries: [ThemedMenuEntry]) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for entry in entries {
            guard case .item(let item) = entry else { continue }
            for metric in item.metrics where seen.insert(metric.label).inserted {
                ordered.append(metric.label)
                if ordered.count == maximumMetricColumns { return ordered }
            }
        }
        return ordered
    }

    /// One width for every column, measured from the widest name and the widest value anywhere
    /// in the menu. Equal columns rather than each sized to its own content, because unequal
    /// ones put the second column's bar at a different offset on rows whose first column is
    /// absent — and a bar that moves sideways between rows cannot be compared by length.
    public static func metricColumnWidth(_ entries: [ThemedMenuEntry]) -> CGFloat {
        let admitted = Set(metricColumns(entries))
        let all = entries.flatMap { entry -> [ThemedMenuMetric] in
            guard case .item(let item) = entry else { return [] }
            return item.metrics.filter { admitted.contains($0.label) }
        }
        guard !all.isEmpty else { return 0 }

        let font = metricFont
        let label = all.map { ceil($0.label.size(withAttributes: [.font: font]).width) }.max() ?? 0
        let value = all.map { ceil($0.value.size(withAttributes: [.font: font]).width) }.max() ?? 0
        return label + metricInnerGap + metricBarWidth + metricInnerGap + value
    }

    /// The trailing detail's own column, measured from the longest one present.
    public static func trailingDetailWidth(_ entries: [ThemedMenuEntry]) -> CGFloat {
        entries.compactMap { entry -> CGFloat? in
            guard case .item(let item) = entry,
                  let detail = item.trailingDetail,
                  !detail.isEmpty else { return nil }
            return ceil(detail.size(withAttributes: [.font: metricFont]).width)
        }.max() ?? 0
    }

    /// Everything the columns take out of a row's width, including the gaps between them.
    ///
    /// Reserved off the *title's* width rather than added to the panel's, once the panel is at
    /// its cap. That inversion is the point: today's rows overflow, and the segment that loses
    /// its characters is the countdown — `7d resets in 5d 1…`, a sentence claiming to be
    /// complete. A name is the one thing on this row a reader can still recognise from its
    /// first half, so the name is what gives way and the numbers never do.
    public static func metricReservation(_ entries: [ThemedMenuEntry]) -> CGFloat {
        let columns = metricColumns(entries)
        let columnWidth = metricColumnWidth(entries)
        let detail = trailingDetailWidth(entries)
        var total: CGFloat = 0
        if !columns.isEmpty {
            total += CGFloat(columns.count) * columnWidth
                + CGFloat(columns.count - 1) * metricColumnGap
        }
        if detail > 0 {
            total += (total > 0 ? metricDividerGap * 2 + metricDividerWidth : 0) + detail
        }
        return total > 0 ? total + metricColumnGap : 0
    }

    /// Where a row's **first line** sits inside a slot of `height`, measured from the slot's
    /// bottom edge.
    ///
    /// Everything on that line is placed against it — the checkmark, the mark, the title and its
    /// qualifier, the metric columns, the trailing detail, the submenu chevron. Each of those was
    /// centred on the row instead, which is right for a single-line row and wrong for every row
    /// beside one: a title with a subtitle is placed as a centred *block*, so its line sits above
    /// the row's middle while the mark next to it sank to between the two lines, and a
    /// neighbouring row with no subtitle put its title where this row's ink is not.
    ///
    /// `reservesSubtitleLine` is the *run's* answer, not the row's, which is what keeps a row
    /// without a subtitle on its neighbours' line rather than in the middle of its own slot.
    public static func firstLineCenter(inRowOf height: CGFloat, reservesSubtitleLine: Bool) -> CGFloat {
        guard reservesSubtitleLine else { return height / 2 }
        let subtitleHeight = Design.Typography.lineHeight(of: Design.Typography.detail())
        return height / 2 + (subtitleGap + subtitleHeight) / 2
    }

    /// A section head is a *label*, not a quiet row: `caption` is the app's semibold 11pt
    /// heading role, which is what keeps it from reading as a disabled choice in a menu whose
    /// rows are 13pt.
    public static var headerFont: NSFont {
        usesClassicGrammar ? titleFont : Design.Typography.caption()
    }

    /// A section head's slot: its line, plus the air that makes it belong to what follows it
    /// rather than sitting between two groups equally.
    public static var headerHeight: CGFloat { usesClassicGrammar ? 20 : 30 }
    /// How much of that slot is above the line. More above than below, so the header reads as
    /// attached to the rows under it — the same proximity argument `subtitleRowHeight` makes
    /// for a title and its subtitle.
    public static var headerTopInset: CGFloat { usesClassicGrammar ? 8 : 14 }

    public static var shortcutGap: CGFloat { usesClassicGrammar ? 8 : Design.Spacing.large }

    public static let amigaCommandCapWidth: CGFloat = 13
    public static let amigaCommandCapGap: CGFloat = 2

    /// The exact visible spelling for a chord under this menu grammar.
    ///
    /// Windows and Workbench keep their authored command-key forms for the ordinary ⌘ chord;
    /// every other chord uses the platform glyph spelling so additional modifiers are never
    /// hidden or guessed from one bare key.
    public static func shortcutText(_ shortcut: KeyboardShortcut) -> String {
        if appearance == .windows98, shortcut.modifiers == .command {
            return "Ctrl+" + KeyboardShortcut.keyDisplay(shortcut.key)
        }
        return shortcut.displayString
    }

    public static func usesAmigaCommandCap(_ shortcut: KeyboardShortcut) -> Bool {
        appearance == .amiga && shortcut.modifiers == .command
    }

    /// One shared trailing column, measured from the widest complete chord. Workbench draws its
    /// ordinary command modifier as artwork rather than a font character, so the fixed key cap
    /// participates in the same measurement as the following Topaz key.
    public static func shortcutColumnWidth(_ entries: [ThemedMenuEntry]) -> CGFloat {
        entries.compactMap { entry -> CGFloat? in
            guard case .item(let item) = entry,
                  let shortcut = item.resolvedShortcut else { return nil }
            if usesAmigaCommandCap(shortcut) {
                let key = KeyboardShortcut.keyDisplay(shortcut.key)
                let keyWidth = ceil(key.size(withAttributes: [.font: titleFont]).width)
                return amigaCommandCapWidth + amigaCommandCapGap + keyWidth
            }
            return ceil(shortcutText(shortcut).size(withAttributes: [.font: titleFont]).width)
        }.max() ?? 0
    }

    /// How a panel's rows carry their marks, which is the one thing that decides where every
    /// title in it begins.
    ///
    /// The old answer was "always leave room for a checkmark", and it cost twice. An
    /// icon-less menu of plain actions — which is most of them — began every title 16pt inside
    /// the panel behind a gutter nothing was ever drawn in, which is the difference between a
    /// column of names and a column of names that looks like it lost its icons. And it made
    /// icons unaffordable: added behind a gutter that was always reserved, a glyph and its
    /// title started 48pt in and the panel grew to hold a column of air.
    ///
    /// So a mark column is reserved only where something is going in it, and a check and an
    /// icon **share** that column — which is what Win32 has always done, and what the row
    /// drawing already assumed by putting the check at `contentInset`. Only a menu where one
    /// row carries *both* needs two, and one exists: Open in marks the preferred app in a list
    /// where every row wears that app's own icon.
    public enum CheckColumn {
        /// No row in this panel is marked.
        case none
        /// Marks and icons share one leading column, because no row has both.
        case shared
        /// A column of its own, before the icons — some row carries a mark *and* an icon.
        case separate
    }

    /// What this panel's marks need, before the appearance has its say.
    ///
    /// A row is marked by its own `isSelected` or by the index the presenter opened on; the rows
    /// are built to treat those identically, so the measurement has to as well — a menu whose
    /// only mark came from the presenter measured itself without one and drew the check into
    /// the first title.
    public static func checkColumn(
        _ entries: [ThemedMenuEntry],
        selectedEntryIndex: Int? = nil
    ) -> CheckColumn {
        var marked = false
        for (index, entry) in entries.enumerated() {
            guard let item = entry.item else { continue }
            guard item.isSelected || index == selectedEntryIndex else { continue }
            if item.image != nil { return .separate }
            marked = true
        }
        return marked ? .shared : .none
    }

    /// The same answer under the anatomy the current theme authors.
    ///
    /// The historical families do not negotiate this. Platinum and Workbench draw independent
    /// mark and icon columns whether or not either is occupied — an icon-less System 7 Help
    /// menu still starts its titles after the mark column — and Win32 draws exactly one, which
    /// a row fills with its check *or* its bitmap. Both are part of the anatomy those
    /// reconstructions are measured against, so only the modern menu asks the entries.
    public static func resolved(_ column: CheckColumn) -> CheckColumn {
        switch appearance {
        case .platinum, .amiga: return .separate
        case .windows98: return .shared
        default: return column
        }
    }

    /// Where a row's leading mark begins — its icon, or its check where the two share a column.
    public static func markInset(checkColumn: CheckColumn) -> CGFloat {
        contentInset + (resolved(checkColumn) == .separate ? leadingSlot : 0)
    }

    /// The leading mark column's width: the icon's slot where the panel has icons, else the
    /// mark's own, else nothing at all.
    public static func markWidth(checkColumn: CheckColumn, hasImageColumn: Bool) -> CGFloat {
        if hasImageColumn { return imageSlot }
        return resolved(checkColumn) == .shared ? leadingSlot : 0
    }

    /// Where a row's content begins, per column, so a *drawn* title and a *hosted* preview land
    /// in the same place. A preview replaces the text rather than joining it, and a column of
    /// names that shifted sideways when one of them animated would read as a layout bug in the
    /// menu rather than as the transition it is demonstrating.
    public static func previewInset(checkColumn: CheckColumn, hasImageColumn: Bool) -> CGFloat {
        markInset(checkColumn: checkColumn)
            + markWidth(checkColumn: checkColumn, hasImageColumn: hasImageColumn)
    }

    public static func titleInset(
        checkColumn: CheckColumn,
        hasImageColumn: Bool,
        hasPreviewColumn: Bool
    ) -> CGFloat {
        let previewColumn = hasPreviewColumn ? previewSlot : 0
        if appearance == .windows98 {
            // One column, and the preview shares it rather than following it — the native
            // cascade has a single leading slot whatever goes in it.
            return contentInset + max(
                markWidth(checkColumn: checkColumn, hasImageColumn: hasImageColumn),
                previewColumn
            )
        }
        return previewInset(checkColumn: checkColumn, hasImageColumn: hasImageColumn)
            + previewColumn
    }

    /// Every entry's height, in one pass over the whole menu.
    ///
    /// **A row's height is not its own business.** Asked entry by entry, a row with a second
    /// line is 46 and one without is 28 — and a group of logins where three carry a scoped
    /// window and two do not then has two rhythms stacked directly on top of each other, which
    /// reads as a spacing defect rather than as rows that happen to differ. It is the same
    /// argument `subtitleRowHeight` already makes one level down: proximity does the grouping,
    /// and proximity cannot do it if the gaps are not equal.
    ///
    /// So the unit is a **run** — consecutive rows, delimited by separators and section heads —
    /// and every row in a run takes the tallest kind in that run. The delimiters are what keep
    /// this from flattening the whole app's menus into one tall rhythm: the project menu's two
    /// actions sit after a separator, so they stay short while the projects above them keep the
    /// height their paths need. A change of height across a rule or a heading is explained by
    /// the rule or the heading; a change of height between two adjacent rows is not.
    public static func heights(for entries: [ThemedMenuEntry]) -> [CGFloat] {
        var heights = [CGFloat](repeating: 0, count: entries.count)
        var run: [Int] = []
        let hasSubtitle = entries.map { $0.item?.subtitle?.isEmpty == false }

        func closeRun() {
            guard !run.isEmpty else { return }
            let tall = run.contains { hasSubtitle[$0] }
            for index in run { heights[index] = tall ? subtitleRowHeight : rowHeight }
            run.removeAll()
        }

        for (index, entry) in entries.enumerated() {
            switch entry {
            case .separator:
                closeRun()
                heights[index] = separatorHeight
            case .header:
                closeRun()
                heights[index] = headerHeight
            case .item:
                run.append(index)
            }
        }
        closeRun()
        return heights
    }

    public static func height(for entries: [ThemedMenuEntry]) -> CGFloat {
        heights(for: entries).reduce(verticalOuterInset * 2, +)
    }

    /// The height to settle on when a panel cannot show every row: the tallest one within
    /// `limit` that cuts a row across the middle.
    ///
    /// A clamped menu is free to land on a row boundary, and one that does looks like the whole
    /// menu. The session row's menu grew past `ThemedMenuLayout.maximumHeight` and ended on a
    /// clean edge, so Copy Session ID and Delete Session were simply not there as far as the
    /// screen was concerned — the scroller only appears while the pointer is inside the panel,
    /// which is too late to tell someone the list continues. Half a row is the signal that
    /// reads before anything is touched, and it costs nothing but the half row.
    ///
    /// Only items are cut. A separator sliced down its middle reads as a stray rule against the
    /// panel's edge rather than as a row with more below it, so one is carried whole into the
    /// hidden part and the item above it does the peeking.
    public static func clippedHeight(for entries: [ThemedMenuEntry], atMost limit: CGFloat) -> CGFloat {
        let budget = limit - verticalOuterInset * 2
        var consumed: CGFloat = 0
        var peeked: CGFloat?

        for (entry, height) in zip(entries, heights(for: entries)) {
            if case .item = entry {
                let candidate = consumed + height / 2
                guard candidate <= budget else { break }
                peeked = candidate
            }
            consumed += height
        }

        // Nothing fits even half a row — a panel shortened to that would say less than the
        // clamped one does. Keep the limit and let the scroller carry it.
        guard let peeked else { return limit }
        return peeked + verticalOuterInset * 2
    }

    /// `selectedEntryIndex` participates because it is one of the two ways a row is marked, and
    /// the panel's width has to reserve the same columns the rows will draw in. Measured without
    /// it, a menu whose only mark comes from the presenter drew its check into the title.
    public static func width(
        for entries: [ThemedMenuEntry],
        minimum: CGFloat,
        selectedEntryIndex: Int? = nil
    ) -> CGFloat {
        let text = entries.compactMap { entry -> CGFloat? in
            guard case .item(let item) = entry else { return nil }
            let title = ceil(titleLine(of: item).size(
                withAttributes: [.font: titleFont]
            ).width)
            let subtitle = ceil((item.subtitle ?? "").size(
                withAttributes: [.font: Design.Typography.detail()]
            ).width)
            return max(title, subtitle)
        }.max() ?? 0

        let imageColumn = hasImageColumn(entries) ? imageSlot : 0
        let previewColumn = hasPreviewColumn(entries) ? previewSlot : 0
        let chevronColumn = hasSubmenuColumn(entries) ? submenuChevronSlot : 0
        let accessoryColumn = hasAccessoryColumn(entries) ? accessorySlot : 0
        let shortcutColumn = shortcutColumnWidth(entries)
        let marks = checkColumn(entries, selectedEntryIndex: selectedEntryIndex)
        let markColumn = markWidth(checkColumn: marks, hasImageColumn: imageColumn > 0)
        let ownCheckColumn = resolved(marks) == .separate ? leadingSlot : 0
        let leadingColumns = appearance == .windows98
            ? max(markColumn, previewColumn)
            : ownCheckColumn + markColumn + previewColumn
        let content = outerInset * 2 + contentInset * 2
            + leadingColumns + text + chevronColumn + accessoryColumn
            + metricReservation(entries)
            + (shortcutColumn > 0 ? shortcutGap + shortcutColumn : 0)
        return min(max(minimum, content), ThemedMenuLayout.maximumWidth)
    }

    /// The title as it is drawn: the name, and the qualifier that shares its line.
    public static func titleLine(of item: ThemedMenuItem) -> String {
        guard let detail = item.titleDetail, !detail.isEmpty else { return item.title }
        return item.title + titleDetailGap + detail
    }

    /// Between a title and the qualifier after it. Wider than a word space, so the pair reads as
    /// a name and its footnote rather than as a two-word name.
    public static let titleDetailGap = "   "
}
