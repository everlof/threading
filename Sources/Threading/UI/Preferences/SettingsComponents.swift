import AppKit
import ThreadingExtensionKit

// MARK: - Settings UI Kit

/// Building blocks for the settings pages, so every page reads as one slick, consistent form in
/// the app's design language: grouped rounded cards of rows, quiet section captions, flat
/// controls. The modern macOS-Settings shape, expressed in `Design` tokens rather than stock
/// form chrome.
@MainActor
enum SettingsUI {

    /// A whole page: caption+card sections stacked in a flipped scroll view, top-aligned, so a
    /// short page sits at the top and a long one scrolls.
    @MainActor
    static func page(
        _ sections: [NSView],
        hostPage: ExtensionHostSettingsPage? = nil
    ) -> NSView {
        let extensionSections = hostPage.map {
            ExtensionSettingsRenderer.hostSectionModels(for: $0)
        } ?? []
        if !extensionSections.isEmpty {
            return ExtensionSettingsListView(
                baseSections: sections,
                extensionSections: extensionSections
            )
        }

        let stack = NSStackView(views: sections)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.large
        stack.translatesAutoresizingMaskIntoConstraints = false

        let document = SettingsFlippedView()
        document.addSubview(stack)

        let scrollView = ThemedScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),

            // The column keeps `Design.Size.glowGutter` clear of the scroll view's edges: a
            // card's halo is a layer shadow, and the scroll view clips at its own bounds, so
            // a card pinned flush to them loses its glow on that side — cut off flat, while
            // the vertical spill survives in the section spacing. The top and bottom padding
            // double as the gutter for the first and last card.
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: Design.Spacing.large),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: Design.Size.glowGutter),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -Design.Size.glowGutter),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -Design.Spacing.large)
        ])

        // Every section fills the column, so cards and their rows share one width — otherwise a
        // card with no stretchy row (a lone field, a full-width preview) hugs its content and
        // sits narrower than the rest.
        for section in sections {
            section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        return scrollView
    }

    /// A page under a fixed header: the title, an optional one-line summary and the page-level
    /// actions stay put while the sections scroll beneath them.
    ///
    /// Every page used to draw its title as the first row *inside* the scroll, so the one line
    /// saying where you are was the first thing to leave the screen — on the pages long enough
    /// to need it most. The header also gives a page's primary action (Import…, Rescan) a seat
    /// that does not scroll away with the content it acts on.
    @MainActor
    static func page(
        title: String,
        summary: String? = nil,
        actions: [NSView] = [],
        sections: [NSView],
        hostPage: ExtensionHostSettingsPage? = nil,
        localizes: Bool = true
    ) -> NSView {
        fixedHeaderPage(
            title: title,
            summary: summary,
            actions: actions,
            body: page(sections, hostPage: hostPage),
            localizes: localizes
        )
    }

    /// The fixed settings header above an already-virtualized scrolling body.
    ///
    /// `page(_:hostPage:)` owns a retained stack and therefore must not wrap a table-backed page:
    /// doing so would introduce nested scrolling and forfeit the table's viewport. This sibling
    /// entry point keeps the exact same header geometry while leaving row ownership with AppKit.
    static func listPage(
        title: String,
        summary: String? = nil,
        actions: [NSView] = [],
        body: NSView,
        localizes: Bool = true
    ) -> SettingsPageView {
        fixedHeaderPage(
            title: title,
            summary: summary,
            actions: actions,
            body: body,
            localizes: localizes
        )
    }

    /// Pins a settings destination into its pane. **The one place that arrangement exists.**
    ///
    /// It is a shared function rather than five constraints written twice because the two
    /// copies drifted, and the drift is what "it doesn't look as your image" was: the render
    /// tests pinned a page to a bare view's four edges and photographed that, while the shell
    /// centred it under a cap in a window. A picture of a layout nobody has is worse than no
    /// picture, so the fixture and the app now install the page through the same call and there
    /// is nothing left to keep in step by hand.
    ///
    /// The cap itself keeps the Settings canvas still while its contents change. It includes the
    /// glow gutters the page pads itself with, so cards and the Usage dashboard share the same
    /// visible edges.
    ///
    /// The page states its own preferred width and only uses one-way inequalities against the
    /// pane. An equality such as `page.width == pane.width - margins`, even below required, gives
    /// the split view a preferred pane width stronger than its holding priority. Settings then
    /// keeps the workspace pane at exactly the canvas plus its margins while the sidebar absorbs
    /// every extra point. A width ceiling preserves the inset in a narrow pane without letting
    /// content choose the pane's measure.
    ///
    /// - Parameter top: where the page starts, for a pane with a header strip above it. The
    ///   host's own top edge when there is none.
    /// - Parameter width: the canvas this page keeps. The shared Settings measure unless a
    ///   destination states its own — the Triggers workspace is a page in this same pane with a
    ///   narrower composition, and the priorities above are the part neither page should redecide.
    @discardableResult
    static func install(
        page content: NSView,
        in host: NSView,
        top: NSLayoutYAxisAnchor? = nil,
        width pageWidth: CGFloat = SettingsUIDefaults.pageWidth
    ) -> [NSLayoutConstraint] {
        content.translatesAutoresizingMaskIntoConstraints = false
        if content.superview !== host { host.addSubview(content) }

        // Keep a comfortable inset when the pane can afford it, but do not make either page edge
        // equal to the pane. Only a <= relationship may mention the host's width here: content
        // inside a split item must never supply that item's preferred measure.
        let insetWidth = content.widthAnchor.constraint(
            lessThanOrEqualTo: host.widthAnchor,
            constant: -Design.Spacing.large * 2
        )
        // One point above ordinary content compression. At the same 750 priority, a page whose
        // readable labels wanted their intrinsic width could spend this ceiling instead and
        // consume the narrow pane's entire margin. The shell owns that boundary; content then
        // resolves its own lower-level compression inside the canvas it was actually given.
        insetWidth.priority = NSLayoutConstraint.Priority(
            NSLayoutConstraint.Priority.defaultHigh.rawValue + 1
        )

        // One step below the inset ceiling, the canvas states its own stable measure. This keeps
        // pages with little intrinsic content from collapsing to their fitting size after the
        // pane grows wider than the cap.
        let preferred = content.widthAnchor.constraint(equalToConstant: pageWidth)
        preferred.priority = NSLayoutConstraint.Priority(
            NSLayoutConstraint.Priority.defaultHigh.rawValue - 1
        )

        let constraints = [
            insetWidth,
            preferred,
            content.topAnchor.constraint(equalTo: top ?? host.topAnchor),
            content.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            content.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: pageWidth),
            // This required ceiling deliberately has no negative inset. AppKit constructs some
            // hosts at zero width; the optional inset may yield there, while required constraints
            // remain satisfiable and the page can never escape the pane.
            content.widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor)
        ]
        NSLayoutConstraint.activate(constraints)
        return constraints
    }

    private static func fixedHeaderPage(
        title: String,
        summary: String?,
        actions: [NSView],
        body: NSView,
        localizes: Bool
    ) -> SettingsPageView {
        let header = pageHeader(
            title: title,
            summary: summary,
            actions: actions,
            localizes: localizes
        )
        return SettingsPageView(
            header: header.view,
            summaryField: header.summaryField,
            body: body
        )
    }

    /// The fixed band above a page's scroll: title leading, actions trailing, the optional
    /// summary under the title in the secondary colour.
    private static func pageHeader(
        title: String,
        summary: String?,
        actions: [NSView],
        localizes: Bool
    ) -> (view: NSView, summaryField: NSTextField?) {
        let heading = heading(title, localizes: localizes)
        // The header's trailing actions are operable content; a long destination summary must
        // truncate before it pushes them—or the page and its scrolling body—past the pane.
        // `lineBreakMode` only chooses *how* a field shortens after Auto Layout gives it less
        // room. The low resistance is what permits that smaller width in the first place.
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var labelViews: [NSView] = [heading]
        var summaryField: NSTextField?
        if let summary {
            let line = NSTextField(labelWithString: localized(summary, if: localizes))
            line.applyFont(.subheading)
            line.textColor = Design.Text.secondary
            line.lineBreakMode = .byTruncatingTail
            line.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            labelViews.append(line)
            summaryField = line
        }

        let labels = NSStackView(views: labelViews)
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = Design.Spacing.hairline
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = Design.Spacing.medium
        row.addArrangedSubview(labels)

        for action in actions {
            action.setContentHuggingPriority(.required, for: .horizontal)
            row.addArrangedSubview(action)
        }

        return (row, summaryField)
    }

    /// A collapsible card: a disclosure header carrying the section's name, an optional
    /// trailing summary, and one decision-level control, with the detail rows built in only
    /// while expanded.
    ///
    /// The caller keeps the expansion state (a view state, not a preference — Storage's fold
    /// set the pattern) and chooses the update boundary: a small retained page may rebuild its
    /// card, while a large page uses `disclosureHeader` and inserts only its virtual detail rows.
    @MainActor
    static func disclosureCard(
        title: String,
        subtitle: String? = nil,
        summary: String? = nil,
        summaryColor: NSColor? = nil,
        control: NSView? = nil,
        isExpanded: Bool,
        localizes: Bool = true,
        accessibilityIdentifier: String? = nil,
        onToggle: @escaping (Bool) -> Void,
        detailRows: [NSView] = []
    ) -> NSView {
        let header = disclosureHeader(
            title: title,
            subtitle: subtitle,
            summary: summary,
            summaryColor: summaryColor,
            control: control,
            isExpanded: isExpanded,
            localizes: localizes,
            accessibilityIdentifier: accessibilityIdentifier,
            onToggle: onToggle
        )

        return SettingsCard(rows: [header] + (isExpanded ? detailRows : []))
    }

    /// The header portion of `disclosureCard`, for a card whose detail rows are owned by a
    /// virtual table rather than retained in one stack.
    static func disclosureHeader(
        title: String,
        subtitle: String? = nil,
        summary: String? = nil,
        summaryColor: NSColor? = nil,
        control: NSView? = nil,
        isExpanded: Bool,
        localizes: Bool = true,
        accessibilityIdentifier: String? = nil,
        onToggle: @escaping (Bool) -> Void
    ) -> NSView {
        let disclosure = disclosureRow(
            title: title,
            subtitle: subtitle,
            summary: summary,
            summaryColor: summaryColor,
            isExpanded: isExpanded,
            localizes: localizes,
            accessibilityIdentifier: accessibilityIdentifier,
            onToggle: onToggle
        )

        let header: NSView
        if let control {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.distribution = .fill
            row.spacing = Design.Spacing.medium
            row.edgeInsets = NSEdgeInsets(
                top: 0, left: 0, bottom: 0, right: Design.Spacing.inset
            )
            disclosure.setContentHuggingPriority(.defaultLow, for: .horizontal)
            holdsItsWidth(control)
            row.addArrangedSubview(disclosure)
            row.addArrangedSubview(control)
            header = row
        } else {
            header = disclosure
        }

        return header
    }

    /// A bare disclosure row, for a fold *inside* a card — Storage's "N smaller directories"
    /// tail — where `disclosureCard` would nest a card in a card.
    @MainActor
    static func disclosureRow(
        title: String,
        subtitle: String? = nil,
        summary: String? = nil,
        summaryColor: NSColor? = nil,
        isExpanded: Bool,
        localizes: Bool = true,
        accessibilityIdentifier: String? = nil,
        onToggle: @escaping (Bool) -> Void
    ) -> ThemedDisclosureRow {
        let titleLabel = NSTextField(labelWithString: localized(title, if: localizes))
        titleLabel.applyFont(.body)
        titleLabel.textColor = Design.Text.label
        // A long title (Storage's "project · worktree" pair) truncates rather than pushing:
        // an incompressible single-line label's width travels out through the stacks and it
        // is the page's own pins that end up broken, not the label.
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var labelViews: [NSView] = [titleLabel]
        if let subtitle {
            let sub = NSTextField(
                wrappingLabelWithString: localized(subtitle, if: localizes)
            )
            sub.applyFont(.subheading)
            sub.textColor = Design.Text.secondary
            labelViews.append(sub)
        }

        let labels = NSStackView(views: labelViews)
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = Design.Spacing.hairline
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let content = NSStackView()
        content.orientation = .horizontal
        content.alignment = .centerY
        content.distribution = .fill
        content.spacing = Design.Spacing.medium
        content.addArrangedSubview(labels)

        if let summary {
            let trailing = NSTextField(labelWithString: localized(summary, if: localizes))
            trailing.applyFont(.subheading)
            trailing.textColor = summaryColor ?? Design.Text.secondary
            trailing.setContentHuggingPriority(.required, for: .horizontal)
            trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
            content.addArrangedSubview(trailing)
        }

        let disclosure = ThemedDisclosureRow(content: content, isExpanded: isExpanded)
        disclosure.onToggle = onToggle
        disclosure.setAccessibilityLabel(localized(title, if: localizes))
        if let accessibilityIdentifier {
            disclosure.setAccessibilityIdentifier(accessibilityIdentifier)
        }
        SettingsRowAnchor.tag(disclosure, title: localized(title, if: localizes))
        return disclosure
    }

    /// A titled section: a quiet caption above a card. Pass nil to omit the caption.
    static func section(
        _ title: String?,
        _ content: NSView,
        localizesTitle: Bool = true
    ) -> NSView {
        var views: [NSView] = []
        if let title { views.append(caption(title, localizes: localizesTitle)) }
        views.append(content)

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.small
        content.translatesAutoresizingMaskIntoConstraints = false
        content.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
        content.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        return stack
    }

    /// The heading for a page — larger than a caption, the one emphasised string.
    static func heading(_ text: String, localizes: Bool = true) -> NSTextField {
        let label = NSTextField(labelWithString: localized(text, if: localizes))
        label.applyFont(.heading)
        label.textColor = Design.Text.label
        return label
    }

    static func caption(_ text: String, localizes: Bool = true) -> NSTextField {
        let label = NSTextField(
            labelWithString: localized(text, if: localizes).localizedUppercase
        )
        label.applyFont(.caption)
        label.textColor = Design.Text.tertiary
        return label
    }

    /// Explanatory text beneath a card, in the secondary colour.
    static func note(_ text: String, localizes: Bool = true) -> NSTextField {
        let label = NSTextField(
            wrappingLabelWithString: localized(text, if: localizes)
        )
        label.applyFont(.subheading)
        label.textColor = Design.Text.secondary
        return label
    }

    // MARK: - Rows

    /// A row inside a card: a title (with optional secondary line) leading, a control trailing.
    ///
    /// `subtitleField` hands back the secondary label so a caller whose subtitle changes — the
    /// App theme card, whose line describes the chosen theme — can update it in place rather
    /// than rebuild the row.
    static func row(
        title: String,
        subtitle: String? = nil,
        help: HelpTopic? = nil,
        control: NSView? = nil,
        subtitleField: inout NSTextField?,
        localizes: Bool = true,
        highlighting query: String? = nil
    ) -> NSView {
        // A blank query is not a search, and neither is a whitespace one: both have to leave the
        // row exactly the plain row it would otherwise have been, or every ordinary settings page
        // pays for a highlight nobody asked for.
        let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = (trimmed?.isEmpty == false) ? trimmed : nil

        let displayTitle = localized(title, if: localizes)
        let titleLabel = label(
            displayTitle,
            role: .body,
            ink: { Design.Text.label },
            highlighting: query
        )
        // A control is the operable half of the row, so narrow layouts must make the title
        // yield before they move that control beyond the card. Plain `NSTextField` labels keep
        // AppKit's 750 horizontal resistance and an unbounded single-line width by default;
        // one long title was therefore strong enough to break the row's trailing pin at 420pt,
        // clipping every control on the General page. Search-match labels use the same column
        // and need the same pressure contract.
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if let titleLabel = titleLabel as? NSTextField {
            titleLabel.lineBreakMode = .byTruncatingTail
        }

        var labelViews: [NSView] = [titleLabel]
        var highlighted: [NSView] = query == nil ? [] : [titleLabel]
        if let subtitle {
            let text = localized(subtitle, if: localizes)
            if let query {
                let sub = label(
                    text,
                    role: .subheading,
                    ink: { Design.Text.secondary },
                    highlighting: query
                )
                labelViews.append(sub)
                highlighted.append(sub)
            } else {
                let sub = wrappingSubtitle(text)
                labelViews.append(sub)
                subtitleField = sub
            }
        }

        let row = assemble(labelViews, highlighted, help: help, control: control)
        // The tag a search result's reveal finds the row by — see `SettingsRowAnchor`.
        SettingsRowAnchor.tag(row, title: displayTitle)
        return row
    }

    /// One of a row's two lines: a plain label, or a `SearchMatchLabel` when the row is being
    /// shown as a search result and has to say which of its words the query accounts for.
    ///
    /// The highlighted line does not wrap where the plain subtitle does, and the difference is
    /// the content rather than an oversight: a settings page's subtitle is a sentence explaining
    /// a control, while a result's is a short list of the terms that matched. A list is better
    /// truncated than run onto a second line under a row the reader is scanning past.
    private static func label(
        _ text: String,
        role: Design.FontRole,
        ink: @escaping () -> NSColor,
        highlighting query: String?
    ) -> NSView {
        guard let query else {
            let label = NSTextField(labelWithString: text)
            label.applyFont(role)
            label.textColor = ink()
            return label
        }

        let label = SearchMatchLabel(role: role, ink: ink)
        label.show(text, matching: query)
        return label
    }

    /// The row's geometry, shared by both paths above so a highlighted row and a plain one
    /// cannot drift apart.
    private static func assemble(
        _ labelViews: [NSView],
        _ highlighted: [NSView],
        help: HelpTopic? = nil,
        control: NSView?
    ) -> NSView {
        var labelViews = labelViews
        if let help, let title = labelViews.first {
            labelViews[0] = titleLine(title, help: help)
        }
        let labels = NSStackView(views: labelViews)
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = Design.Spacing.hairline
        fill(labels)

        // The labels take the row's slack, rather than a spacer taking it.
        //
        // A wrapping subtitle has no intrinsic *width* — the trap this project has already hit
        // once — so it cannot argue for any. Against a spacer that was willing to grow, it lost
        // every time and collapsed to its narrowest wrap: measured, the App theme row's
        // description wrapped to the same six lines at 420pt and at 620pt, with most of the row
        // empty beside it. The control still sits trailing, because the row fills its width
        // either way; what changed is which view absorbs what is left over.
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // A highlighted line is single-line where the plain subtitle wraps, so it *has* an
        // intrinsic width and will happily claim more of the row than there is. Capping it at the
        // label column turns that claim back into a truncation — the same slack, spent the same
        // way, whether or not a search is running.
        for view in highlighted {
            view.trailingAnchor.constraint(lessThanOrEqualTo: labels.trailingAnchor).isActive = true
        }

        guard let control else {
            let row = NSStackView(views: [labels])
            row.orientation = .horizontal
            row.distribution = .fill
            return padded(row)
        }
        holdsItsWidth(control)
        return padded(SettingsAdaptiveControlRow(labels: labels, control: control))
    }

    /// A wrapping secondary line, and the two things that decide how wide it comes out.
    ///
    /// A wrapping `NSTextField` hugs horizontally at `.defaultLow`, which is *exactly* the
    /// priority the label column above it uses to claim the row's slack. Two constraints at 250
    /// wanting opposite things is not a layout, it is a coin toss, and the layout engine spent it
    /// differently depending on how many passes the tree had been through: a page laid out once
    /// in a detached fixture gave every subtitle the column, and the same page in a window gave
    /// each one its own fitting width and left the rest of the card empty beside it. The render
    /// tests photographed the first and Remote Access shipped the second.
    ///
    /// So the label states outright that it has no opinion about its own width, and `fill`
    /// pins it to the column. Either alone would settle today's arrangement; together they leave
    /// nothing for a later layout pass to decide.
    private static func wrappingSubtitle(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.applyFont(.subheading)
        label.textColor = Design.Text.secondary
        label.setContentHuggingPriority(.init(1), for: .horizontal)
        return label
    }

    /// Pins every wrapping line in a label column to the column's own width, with a floor.
    ///
    /// The pin is what settles the tie: a wrapping label hugs at `.defaultLow`, which is the
    /// priority the column itself claims the row's slack at, and a tie is not a layout.
    ///
    /// The floor is the squeezed pane's half of the same problem. A row's trailing control keeps
    /// its width by contract, so in a 420-point pane the label column can be left with almost
    /// nothing, and a subtitle pinned to *that* wraps one character per line for eleven lines,
    /// which is worse than the truncation it replaced. So the pin is a preference and the floor
    /// outranks it: the words stay readable, and the row's own required edges are still free to
    /// break the floor rather than push a control out of its card.
    ///
    /// The floor is stated at `.defaultHigh` and is therefore *above* a control measure a page
    /// declares as a preference. That is the intended order. A control that must keep its width
    /// says so at `.required` and wins; a control whose 380 points are a wish yields them to the
    /// sentence beside it, which is the trade a narrow pane should make.
    private static func fill(_ labels: NSStackView) {
        for view in labels.arrangedSubviews {
            guard let field = view as? NSTextField, field.cell?.wraps == true else { continue }
            let pin = field.widthAnchor.constraint(equalTo: labels.widthAnchor)
            pin.priority = NSLayoutConstraint.Priority(
                NSLayoutConstraint.Priority.defaultLow.rawValue + 1
            )
            let floor = field.widthAnchor.constraint(
                greaterThanOrEqualToConstant: SettingsUIDefaults.minimumTextWidth
            )
            floor.priority = .defaultHigh
            NSLayoutConstraint.activate([pin, floor])
        }
    }

    /// A row's title with the "?" that carries what used to be its third and fourth sentences.
    ///
    /// The mark sits beside the *last glyph of the title*, not beside its click target: a
    /// `HelpPopoverButton` holds its press surface around a smaller mark, so the gap a container
    /// asks for has that padding subtracted out of it — rule 9 of the theme boundary, said once
    /// here rather than at every row that grows a "?".
    private static func titleLine(_ title: NSView, help: HelpTopic) -> NSView {
        let button = HelpPopoverButton(topic: help)
        let line = NSStackView(views: [title, button])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.distribution = .fill
        line.spacing = max(0, Design.Spacing.small - button.opticalHorizontalInset)
        // The title yields to the mark rather than pushing it out of the row, the same contract
        // `row(title:subtitle:control:)` states one screen down.
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return line
    }

    /// Two things on a row's trailing edge as one control — a reading and the button that acts on
    /// it, Storage's size beside its Remove.
    ///
    /// It exists because a composite control is a *stack view*, and the row cannot say to a stack
    /// what it says to every other control: a stack has no intrinsic content size, so
    /// `setContentHuggingPriority` describes nothing about it, and its own `huggingPriority`
    /// starts low. The group is then exactly as willing to take the row's spare width as the
    /// label column beside it, and which of the two gets it is the layout engine's choice rather
    /// than the row's. Storage's rows shipped like that, and the choice went both ways: in a
    /// fixed-width fixture the group sat on the trailing edge, while in the real scrolling page
    /// all three groups floated mid-card, each at a different distance because each row's own
    /// size string set where its group began. The Usage dashboard met the same fault and parked
    /// an inert spacer beside its header controls; this says it once, in the kit that builds rows.
    static func controlGroup(
        _ views: [NSView],
        spacing: CGFloat = Design.Spacing.medium
    ) -> NSStackView {
        let group = NSStackView(views: views)
        group.orientation = .horizontal
        group.alignment = .centerY
        // A reading beside its button is two kinds of thing and takes the row's own spacing; a
        // pair of sibling buttons is one control and may ask for the tighter step.
        group.spacing = spacing
        holdsItsWidth(group)
        return group
    }

    /// The trailing half of a row keeps its fitting width, so the labels absorb the slack — the
    /// contract `assemble` documents, stated for a stack as well as for a plain control.
    private static func holdsItsWidth(_ control: NSView) {
        control.setContentHuggingPriority(.required, for: .horizontal)
        // The line above said nothing to a stack: `setContentHuggingPriority` is an `NSView`
        // property a stack view does not lay out by, which the composer's column had already
        // found out the hard way. `huggingPriority` is the one it reads, and it starts at 250 —
        // the same willingness to grow the label column has. Nothing else is touched: a stack's
        // clipping resistance is already required — measured for `ControlRowView`, see
        // `design-system.md` — so the group keeps its content width under pressure and the row's
        // own labels are what give.
        (control as? NSStackView)?.setHuggingPriority(.required, for: .horizontal)
    }

    /// The common case — no caller needs the subtitle back.
    static func row(
        title: String,
        subtitle: String? = nil,
        help: HelpTopic? = nil,
        control: NSView? = nil,
        localizes: Bool = true,
        highlighting query: String? = nil
    ) -> NSView {
        var ignored: NSTextField?
        return row(
            title: title,
            subtitle: subtitle,
            help: help,
            control: control,
            subtitleField: &ignored,
            localizes: localizes,
            highlighting: query
        )
    }

    /// A settings row whose explanation keeps the card's full readable width and whose control
    /// sits on a second, trailing-aligned line. Use this when the control and the sentence each
    /// need more than half of the constrained pane: forcing both into `row` can keep every edge
    /// technically inside the card while wrapping the explanation a few words at a time.
    static func stackedControlRow(
        title: String,
        subtitle: String,
        control: NSView,
        subtitleField: inout NSTextField?,
        localizes: Bool = true
    ) -> NSView {
        let displayTitle = localized(title, if: localizes)
        let titleLabel = NSTextField(labelWithString: displayTitle)
        titleLabel.applyFont(.body)
        titleLabel.textColor = Design.Text.label
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let subtitleLabel = wrappingSubtitle(localized(subtitle, if: localizes))
        subtitleField = subtitleLabel
        let labels = NSStackView(views: [titleLabel, subtitleLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = Design.Spacing.hairline
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        fill(labels)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        holdsItsWidth(control)
        let controlLine = NSStackView(views: [spacer, control])
        controlLine.orientation = .horizontal
        controlLine.alignment = .centerY
        controlLine.distribution = .fill

        let column = NSStackView(views: [labels, controlLine])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Design.Spacing.medium
        NSLayoutConstraint.activate([
            labels.widthAnchor.constraint(equalTo: column.widthAnchor),
            controlLine.widthAnchor.constraint(equalTo: column.widthAnchor)
        ])

        let result = padded(column)
        SettingsRowAnchor.tag(result, title: displayTitle)
        return result
    }

    /// A control that spans the row's full width, such as a text field with a Choose button.
    static func fullRow(_ content: NSView) -> NSView {
        padded(content)
    }

    /// An explanatory row: a symbol, a title, and a wrapping detail line. No control.
    ///
    /// Two pages had grown their own copy of this — Remote Access's "Sharing & Security" and
    /// Privacy's attribution notes — and both copies carried the same layout bug, because the
    /// bug is in the shape rather than in either call site. A horizontal stack left on
    /// `.gravityAreas` does not assign its leftover width, and a wrapping label has no intrinsic
    /// width to claim it with; whether the row filled the card came down to whether the detail
    /// string happened to be long enough. Rendered side by side, two rows in one card wrapped
    /// into a third of the width while their neighbours spanned it.
    ///
    /// `.fill` plus the label column's low hugging names the view that absorbs the slack, which
    /// is the same fix `row(title:subtitle:control:)` documents one screen up.
    static func detailRow(
        symbol name: String,
        title: String,
        detail: String,
        help: HelpTopic? = nil,
        localizes: Bool = true
    ) -> NSView {
        let image = NSImageView(image: symbolImage(name))
        image.imageScaling = .scaleProportionallyDown
        image.contentTintColor = Design.Text.secondary
        image.translatesAutoresizingMaskIntoConstraints = false

        let titleField = NSTextField(labelWithString: localized(title, if: localizes))
        titleField.applyFont(.body)
        titleField.textColor = Design.Text.label

        let detailField = wrappingSubtitle(localized(detail, if: localizes))

        let heading: NSView = help.map { titleLine(titleField, help: $0) } ?? titleField
        let labels = NSStackView(views: [heading, detailField])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = Design.Spacing.hairline
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        fill(labels)

        let row = NSStackView(views: [image, labels])
        row.orientation = .horizontal
        row.alignment = .top
        row.distribution = .fill
        row.spacing = Design.Spacing.medium

        NSLayoutConstraint.activate([
            image.widthAnchor.constraint(equalToConstant: Design.Symbol.control + 2),
            image.heightAnchor.constraint(equalTo: image.widthAnchor)
        ])
        let container = padded(row)
        SettingsRowAnchor.tag(container, title: localized(title, if: localizes))
        return container
    }

    /// The settings pages' symbol, at the shared control size.
    static func symbolImage(_ name: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(Design.Symbol.configuration(Design.Symbol.control))
            ?? NSImage()
    }

    private static func padded(_ content: NSView) -> NSView {
        let container = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)

        // A row is full-bleed inside its `SettingsCard`, so the card's corner is what decides how
        // far in this column of labels can start — see `Design.Spacing.inset(inside:)`. Every row
        // asks the same question, which is what keeps the column straight down a card whose first
        // and last rows are the only ones the curve actually reaches.
        let sideMargins = [
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Design.Spacing.inset),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Design.Spacing.inset)
        ]
        NSLayoutConstraint.activate(sideMargins + [
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: Design.Spacing.medium),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Design.Spacing.medium),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: SettingsUIDefaults.rowHeight)
        ])
        container.holdAtContentInset(sideMargins)

        return container
    }

    // MARK: - Controls

    static func toggle(isOn: Bool, target: AnyObject, action: Selector) -> ThemedToggle {
        let control = ThemedToggle()
        control.state = isOn ? .on : .off
        control.target = target
        control.action = action
        return control
    }

    static func popUp(target: AnyObject, action: Selector, width: CGFloat = SettingsUIDefaults.controlWidth) -> ThemedPopUp {
        let popUp = ThemedPopUp()
        popUp.target = target
        popUp.action = action
        preferControlWidth(popUp, width: width)
        return popUp
    }

    static func textField(target: AnyObject, action: Selector, width: CGFloat = SettingsUIDefaults.controlWidth) -> ThemedTextField {
        let field = ThemedTextField()
        field.applyFont(.body)
        field.target = target
        field.action = action
        preferControlWidth(field, width: width)
        return field
    }

    /// Gives a form control its regular measure without making that measure the page's minimum.
    ///
    /// Settings deliberately supports a squeezed canvas. A required 220-point control beside a
    /// readable label made the control wider than the row, and Auto Layout answered the conflict
    /// by widening the scroll document past its clip view. The row then looked cropped even
    /// though all of its own edges were constrained. The measure is a preference one point below
    /// ordinary content compression: controls keep their intrinsic readable width, but the extra
    /// air yields before the row or page can escape the pane.
    static func preferControlWidth(
        _ control: NSView,
        width: CGFloat = SettingsUIDefaults.controlWidth
    ) {
        control.translatesAutoresizingMaskIntoConstraints = false
        let preferred = control.widthAnchor.constraint(equalToConstant: width)
        preferred.priority = NSLayoutConstraint.Priority(
            NSLayoutConstraint.Priority.defaultHigh.rawValue - 1
        )
        // A pop-up's intrinsic width includes its complete selected title. That title is useful
        // room at the regular measure, not a second minimum: the closed control truncates it and
        // the menu still presents every choice in full. Keep the label column's readable floor
        // one point above both width claims.
        control.setContentCompressionResistancePriority(preferred.priority, for: .horizontal)
        preferred.isActive = true
    }

    /// A quiet push button in the app's flat style.
    static func button(
        _ title: String,
        target: AnyObject,
        action: Selector,
        localizes: Bool = true
    ) -> ThemedButton {
        let button = ThemedButton(
            title: localized(title, if: localizes),
            target: target,
            action: action
        )
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    private static func localized(_ text: String, if localizes: Bool) -> String {
        localizes ? L10n.string(text) : text
    }
}

// MARK: - Fixed Settings Page

/// A settings page whose title band stays fixed above a caller-owned body.
///
/// The summary field is retained so a live page can update its count without replacing the
/// header — or, transitively, the scrolling view and all of its visible rows.
final class SettingsPageView: NSView {
    private let summaryField: NSTextField?

    init(header: NSView, summaryField: NSTextField?, body: NSView) {
        self.summaryField = summaryField
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let separator = SeparatorView()
        for child in [header, separator, body] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: Design.Spacing.large),
            // The title aligns to the panels, whose halo gutter is held inside the scroll clip.
            header.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: Design.Size.glowGutter
            ),
            header.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -Design.Size.glowGutter
            ),

            separator.topAnchor.constraint(
                equalTo: header.bottomAnchor,
                constant: Design.Spacing.medium
            ),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),

            body.topAnchor.constraint(equalTo: separator.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    func updateSummary(_ text: String) {
        summaryField?.stringValue = text
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - Settings Card

/// A rounded panel that stacks rows with hairline dividers between them — the container every
/// group of settings sits in.
final class SettingsCard: NSView {

    init(rows: [NSView]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        applySurface(
            fill: Design.Surface.panel,
            radius: .panel,
            border: Design.Surface.border,
            glow: true
        )

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        // The stack goes in first, so every anchor below shares an ancestor at activation —
        // constraining a view before it is in the hierarchy raises an exception AppKit swallows,
        // leaving the card silently unbuilt.
        addSubview(stack)
        // The two ends are where the card's corner is still sweeping, and the row there pads
        // itself by `medium` — enough under a 10pt corner, and half of what a 40pt one asks. The
        // card pays the difference, so the first row's title clears the curve by the same margin
        // as the column beside it, and the rhythm *between* rows is untouched.
        let endPadding = Design.Spacing.inset - Design.Spacing.medium
        let ends = [
            stack.topAnchor.constraint(equalTo: topAnchor, constant: endPadding),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -endPadding)
        ]
        NSLayoutConstraint.activate(ends + [
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        holdAtContentInset(ends, less: Design.Spacing.medium)

        for (index, row) in rows.enumerated() {
            if index > 0 {
                let divider = NSView()
                divider.wantsLayer = true
                divider.applyLayerBackground(Design.Surface.border)
                divider.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(divider)
                // Starting on the label column, so it stays there when a broad corner moves the
                // column in.
                let start = divider.leadingAnchor.constraint(
                    equalTo: stack.leadingAnchor,
                    constant: Design.Spacing.inset
                )
                NSLayoutConstraint.activate([
                    divider.heightAnchor.constraint(equalToConstant: 1),
                    start,
                    divider.trailingAnchor.constraint(equalTo: stack.trailingAnchor)
                ])
                holdAtContentInset([start])
            }

            row.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: stack.trailingAnchor)
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - Adaptive Control Row

/// A row's words beside its control while both fit, and the control on a line of its own when
/// they do not.
///
/// Beside was the only arrangement, and a narrow pane paid for it in words: the control keeps its
/// width by contract, so a three-way choice or a sign-in button beside a sentence left the label
/// column a hundred points, the title truncated to "Keep this…" and the subtitle broke the
/// readable floor `fill` states, because the row's required edges outrank it. Remote Access's
/// Connection card in a 420-point pane showed both at once, and so did every page with a wide
/// control. `stackedControlRow` already had the right shape, but only as a choice a page makes
/// once for every width.
///
/// So the row chooses by its own width: beside while the label column keeps
/// `SettingsUIDefaults.minimumTextWidth` next to the control at its narrowest, and stacked —
/// words across the row, control trailing beneath them, the `stackedControlRow` shape — when it
/// cannot. The row's width comes from its card and not from its arrangement, so the choice cannot
/// feed back into itself, and a pane dragged wider puts the control back beside the words.
///
/// Structural only: it draws nothing and chooses no styling.
final class SettingsAdaptiveControlRow: NSView {
    private let labels: NSView
    private let control: NSView
    private let stack = NSStackView()
    private let labelsSpanTheRow: NSLayoutConstraint
    private(set) var isStacked = false

    init(labels: NSView, control: NSView) {
        self.labels = labels
        self.control = control
        labelsSpanTheRow = labels.widthAnchor.constraint(equalTo: stack.widthAnchor)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        // `.gravityAreas` (the default) may leave unused room after the arranged views. That is
        // invisible with a long subtitle, whose fitting width happens to consume the row, but a
        // short title beside a fixed-width control clusters at the leading edge and wraps its
        // subtitle one word per line. `.fill` makes the low-hugging label column absorb the row's
        // slack and keeps the control on the trailing edge.
        stack.distribution = .fill
        stack.spacing = Design.Spacing.medium
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(labels)
        stack.addArrangedSubview(control)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        arrange(stacked: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The narrowest this row can be with the control beside its words.
    var besideWidth: CGFloat {
        SettingsUIDefaults.minimumTextWidth + Design.Spacing.medium + Self.narrowestWidth(of: control)
    }

    override func layout() {
        // A row not yet given a width has nothing to decide with.
        if bounds.width > 0 {
            let stacked = bounds.width < besideWidth
            if stacked != isStacked {
                arrange(stacked: stacked)
                needsLayout = true
            }
        }
        super.layout()
    }

    /// Stacked, the words take the row and the control keeps the trailing edge every other row's
    /// control is on.
    ///
    /// The order matters. "The words span the row" beside a horizontal run that also holds a
    /// control is unsatisfiable, and `NSStackView` rebuilds its own constraints lazily, on its
    /// next constraint pass rather than when its orientation is set. So the span goes before the
    /// run turns horizontal, and comes only after the vertical run's constraints actually exist:
    /// activated straight after setting the orientation, it met the old horizontal ones and
    /// AppKit broke a constraint to recover, once per row per switch.
    private func arrange(stacked: Bool) {
        isStacked = stacked
        if stacked {
            stack.orientation = .vertical
            stack.alignment = .trailing
            stack.updateConstraintsForSubtreeIfNeeded()
            labelsSpanTheRow.isActive = true
        } else {
            labelsSpanTheRow.isActive = false
            stack.orientation = .horizontal
            stack.alignment = .centerY
        }
    }

    /// The width a control will not give up: what it draws, or a width it requires.
    ///
    /// Not `fittingSize` for a control that has an intrinsic width, because that honours the
    /// *preferred* measure `SettingsUI.preferControlWidth` states and would stack a row whose
    /// control is only wishing for 380 points — the wish is what a narrow pane is meant to take
    /// back first. A composite control, a stack, has no intrinsic width, and its fitting size is
    /// its members' own.
    static func narrowestWidth(of control: NSView) -> CGFloat {
        let intrinsic = control.intrinsicContentSize.width
        let drawn = intrinsic == NSView.noIntrinsicMetric ? control.fittingSize.width : intrinsic
        let required = control.constraints
            .filter {
                $0.firstItem === control && $0.firstAttribute == .width && $0.secondItem == nil
                    && $0.relation != .lessThanOrEqual && $0.priority == .required
            }
            .map(\.constant)
            .max() ?? 0
        return max(drawn, required)
    }
}

// MARK: - Flipped View

/// Top-left origin, so a short page anchors to the top of a tall scroll view.
final class SettingsFlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Settings UI Defaults

enum SettingsUIDefaults {
    static let rowHeight: CGFloat = 44
    static let controlWidth: CGFloat = 220
    static let wideSegmentedControlWidth: CGFloat = 380
    /// Three one- or two-word choices, such as Remote Access's Off / Plugged in / Always.
    static let compactSegmentedControlWidth: CGFloat = 260

    /// The narrowest a wrapping line in a row may be squeezed before it stops being words.
    /// Measured rather than chosen: under the System theme a subheading fits about four short
    /// words on a line at this width, which is the point where a sentence still reads as one.
    static let minimumTextWidth: CGFloat = 180

    /// The one width every settings destination asks its pane for: the shared content canvas
    /// plus the halo gutter `SettingsUI.page` keeps clear on either side. Stated here so the
    /// pane, every page fixture and extension-provided settings agree without a per-page choice.
    static var pageWidth: CGFloat {
        Design.Size.settingsContentWidth + Design.Size.glowGutter * 2
    }
}
