import AppKit

// MARK: - Row Anchors

/// How a settings row is found again after a search named it: every row `SettingsUI` builds is
/// tagged with an identifier derived from its localized title, and the reveal walks the built
/// page for that tag.
///
/// The title *is* the anchor — not a parallel set of stable ids — because the catalogue
/// (`SettingsEntry`) already has to state the title the row draws, and a second id per row is a
/// second thing to drift. `SettingsAnchorResolutionTests` builds each indexed page and fails on
/// an entry whose title resolves to no tagged row.
@MainActor
enum SettingsRowAnchor {

    private static let prefix = "settings.anchor."

    static func identifier(forTitle title: String) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier(prefix + title)
    }

    /// Tags a built row so `find` can answer for it. Inert for an empty title: an untitled row
    /// is not a destination.
    static func tag(_ view: NSView, title: String) {
        guard !title.isEmpty else { return }
        view.identifier = identifier(forTitle: title)
    }

    /// The first row carrying the title's tag, depth-first in the page's own order — which for
    /// a page that repeats a title is the row the catalogue listed first, too. Bounded by the
    /// page: a settings form is a small fixed tree, and this runs once per click, never per
    /// keystroke.
    static func find(title: String, in root: NSView) -> NSView? {
        let identifier = identifier(forTitle: title)
        return firstView(withIdentifier: identifier, in: root)
    }

    /// The row `title` names, bringing it onto the page first if a surface owns it but is not
    /// currently showing it.
    ///
    /// `find` answers about the tree as it stands, which is the honest question for a test about
    /// tagging. This is the question a *reveal* is asking, and the two stopped being the same
    /// question when a page grew a run of segments: Remote Access shows one way in's rows and the
    /// other choices' rows do not exist, while the catalogue still promises every switch on the
    /// page. Without this, a search result for the tailnet's browser option opened the page and
    /// did nothing else.
    ///
    /// Bounded and rare: it runs once per click, and each surface answers by trying its own
    /// small fixed set of panels.
    static func locate(title: String, in root: NSView) -> NSView? {
        if let found = find(title: title, in: root) { return found }
        for surface in revealingSurfaces(in: root)
        where surface.prepareToReveal(title: title) {
            root.layoutSubtreeIfNeeded()
            if let found = find(title: title, in: root) { return found }
        }
        return nil
    }

    private static func revealingSurfaces(in root: NSView) -> [SettingsRowRevealing] {
        var found: [SettingsRowRevealing] = []
        if let surface = root as? SettingsRowRevealing { found.append(surface) }
        for child in root.subviews {
            found.append(contentsOf: revealingSurfaces(in: child))
        }
        return found
    }

    private static func firstView(
        withIdentifier identifier: NSUserInterfaceItemIdentifier,
        in root: NSView
    ) -> NSView? {
        if root.identifier == identifier { return root }
        for child in root.subviews {
            if let found = firstView(withIdentifier: identifier, in: child) {
                return found
            }
        }
        return nil
    }
}

// MARK: - Surfaces That Hide Their Own Rows

/// A view that owns settings rows it is not currently showing.
///
/// The ways-in run on Remote Access is the first and, so far, the only one: three choices share a
/// card, the selected choice's rows are built and the other two choices' rows do not exist. That
/// is the point of the run, and it is also a promise the settings catalogue keeps making about
/// rows the reveal can no longer see. So the surface is asked to bring one on screen before
/// `SettingsRowAnchor.locate(title:in:)` gives up.
///
/// An implementation answers by *trying*, not by holding a second list of the titles it owns: a
/// list would be one more thing to drift from the rows themselves, which is the failure this
/// whole file exists to prevent.
@MainActor
protocol SettingsRowRevealing: NSView {
    /// Brings the row `title` names onto the page. Returns whether anything changed.
    func prepareToReveal(title: String) -> Bool
}

// MARK: - Reveal

/// What happens after a search result that names a setting is clicked and its page is on
/// screen: scroll the row to the middle of the pane, stand the search-match wash on it, and
/// say so to assistive technology.
///
/// A page that cannot answer — a table-backed inventory, a page an extension rebuilt into a
/// virtual list — degrades to what clicking a result always did: the page is open. No error,
/// because the click still did most of its job.
@MainActor
enum SettingsRowReveal {

    /// Scrolls to and marks the row `title` names, if the built page carries its anchor.
    static func reveal(title: String, in pageRoot: NSView) {
        // The page was installed this turn; without a layout pass every frame below is zero.
        pageRoot.layoutSubtreeIfNeeded()

        guard let row = SettingsRowAnchor.locate(title: title, in: pageRoot),
              let scrollView = enclosingScrollView(of: row),
              let documentView = scrollView.documentView else { return }

        let rowRect = row.convert(row.bounds, to: documentView)
        scroll(scrollView, toCentre: rowRect)

        let wash = RevealHighlightView(frame: rowRect)
        documentView.addSubview(wash, positioned: .above, relativeTo: nil)
        wash.flash { [weak wash] in
            wash?.removeFromSuperview()
        }

        NSAccessibility.post(
            element: row,
            notification: .announcementRequested,
            userInfo: [
                .announcement: L10n.format("Showing “%@”", title),
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }

    // MARK: - Private Methods

    private static func enclosingScrollView(of view: NSView) -> NSScrollView? {
        var candidate = view.superview
        while let current = candidate {
            if let scrollView = current as? NSScrollView { return scrollView }
            candidate = current.superview
        }
        return nil
    }

    /// Centres the rect in the clip view, clamped to the document, on the standard transition.
    private static func scroll(_ scrollView: NSScrollView, toCentre rect: NSRect) {
        let clipView = scrollView.contentView
        guard let documentView = scrollView.documentView else { return }

        let visibleHeight = clipView.bounds.height
        let maximumY = max(0, documentView.frame.height - visibleHeight)
        let target = NSPoint(
            x: clipView.bounds.origin.x,
            y: min(max(0, rect.midY - visibleHeight / 2), maximumY)
        )

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Design.Motion.standard
            context.allowsImplicitAnimation = true
            clipView.animator().setBoundsOrigin(target)
            scrollView.reflectScrolledClipView(clipView)
        }
    }
}
