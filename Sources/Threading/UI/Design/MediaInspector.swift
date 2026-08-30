import AppKit
import PDFKit
import QuickLookUI
import ThreadingExtensionKit

// MARK: - Media Inspector Model

enum MediaInspectorItemContent: Sendable, Equatable {
    case automatic
    case image
    case document
    /// A document that varies over time, drawn by the host's own renderer registry.
    ///
    /// Carried on the rail rather than left off it: a `.media` row missing from the collection
    /// has no visible symptom in the pane at all — the failure only appears when someone presses
    /// the arrow key and the animation they were just looking at is not there.
    case media(format: ExtensionMediaFormat)
}

/// One file the app-owned inspector can show.
///
/// The optional image is the already-decoded value a call site is drawing. Keeping it avoids a
/// second decode for a just-produced image and, more importantly, guarantees that inspection
/// begins with the exact pixels the user clicked. The URL remains authoritative for file actions.
struct MediaInspectorItem {
    let url: URL
    let title: String
    let image: NSImage?
    let content: MediaInspectorItemContent
    /// Stable session-attachment identity when the item came from that store. Annotation hosts
    /// use it instead of treating a mutable path as identity; other callers fall back to the URL.
    let annotationAssetID: String?

    init(
        url: URL,
        title: String? = nil,
        image: NSImage? = nil,
        content: MediaInspectorItemContent = .automatic,
        annotationAssetID: String? = nil
    ) {
        self.url = url
        self.title = title ?? url.lastPathComponent
        self.image = image
        self.content = content
        self.annotationAssetID = annotationAssetID
    }

    var isAvailable: Bool {
        url.isFileURL && FileManager.default.fileExists(atPath: url.path)
    }
}

/// A source can provide its surrounding collection so the inspector's arrow keys and thumbnail
/// rail move through the things already on screen rather than opening an isolated one-file view.
struct MediaInspectorSelection {
    let items: [MediaInspectorItem]
    let selectedIndex: Int

    init(items: [MediaInspectorItem], selectedIndex: Int) {
        self.items = items
        self.selectedIndex = selectedIndex
    }
}

enum MediaInspectorZoomMode: Equatable {
    case fit
    case actualSize
    case custom
}

// MARK: - Annotation Host

/// Who owns the marks made on a picture in the inspector.
///
/// **The inspector never owns them, and that is the whole point of the seam.** Opened from the
/// report sheet it is a second view of a list the sheet is already showing in its rail, and a
/// pin dropped at 400% has to appear in a field the user goes back to. Opened from anywhere else
/// — an attachment, a chart the agent drew, a browser baseline — there is no rail and no report,
/// and the marks are worth exactly one thing: handing them to the chat. Both are the same
/// gesture over the same picture, so the difference belongs in who is asked, not in a mode flag
/// inside the inspector.
///
/// A host is asked for the current marks each time an item is shown and told of every edit.
/// Publication is a separate explicit request: dismissing a view is never interpreted as
/// sending user-authored content. The legacy close notice remains a default no-op for hosts that
/// need teardown bookkeeping, not as a handoff path.
@MainActor
protocol MediaInspectorAnnotationHost: AnyObject {
    func annotations(for item: MediaInspectorItem) -> [ImageAnnotation]
    func inspector(
        didChange annotations: [ImageAnnotation],
        for item: MediaInspectorItem,
        image: NSImage?
    )
    func inspectorDidClose(
        with annotations: [ImageAnnotation],
        for item: MediaInspectorItem,
        image: NSImage?
    )
    func sharingState(for item: MediaInspectorItem) -> ImageAnnotationSharingState
    func showsChatActions(for item: MediaInspectorItem) -> Bool
    func canShareAnnotations(for item: MediaInspectorItem) -> Bool
    func inspectorDidRequestShare(for item: MediaInspectorItem, image: NSImage?)
    func inspectorDidRequestRemoveFromChat(for item: MediaInspectorItem)
}

extension MediaInspectorAnnotationHost {
    func inspectorDidClose(
        with annotations: [ImageAnnotation],
        for item: MediaInspectorItem,
        image: NSImage?
    ) {}

    func sharingState(for item: MediaInspectorItem) -> ImageAnnotationSharingState { .local }
    func showsChatActions(for item: MediaInspectorItem) -> Bool { false }
    func canShareAnnotations(for item: MediaInspectorItem) -> Bool { false }
    func inspectorDidRequestShare(for item: MediaInspectorItem, image: NSImage?) {}
    func inspectorDidRequestRemoveFromChat(for item: MediaInspectorItem) {}
}

enum ImageAnnotationSharingState: Equatable {
    case local
    case currentInChat
    case changedInChat
    case shared
    case changedSinceShared
}

// MARK: - Presentation

/// Presents one app-owned inspector per window, inside that window's themed content hierarchy.
///
/// No panel or popover is involved: the overlay follows the current theme live, does not steal
/// key-window status, and can restore focus to the exact source that opened it. System Quick Look
/// remains available from the action menu as the deliberate fallback for uncommon formats.
@MainActor
enum MediaInspectorPresenter {

    private static var sessions: [ObjectIdentifier: MediaInspectorSession] = [:]

    /// Who takes the marks when the opener named nobody.
    ///
    /// Installed by the application at startup rather than reached for from here: this file is a
    /// design component and knows nothing about sessions, composers or window controllers, and a
    /// default that imported them would drag the whole app into every fixture that opens an
    /// image. Nil — in a test, in the component gallery — simply leaves annotation unoffered.
    static var defaultAnnotationHost: ((NSWindow?) -> MediaInspectorAnnotationHost?)?

    @discardableResult
    static func present(
        _ selection: MediaInspectorSelection,
        from source: NSView,
        annotationHost: MediaInspectorAnnotationHost? = nil
    ) -> Bool {
        guard let window = source.window, window.contentView != nil else { return false }

        let available = selection.items.enumerated().filter { $0.element.isAvailable }
        guard !available.isEmpty else { return false }

        let requested = min(max(selection.selectedIndex, 0), selection.items.count - 1)
        let selectedURL = selection.items[requested].url.standardizedFileURL
        let items = available.map(\.element)
        let selectedIndex = items.firstIndex {
            $0.url.standardizedFileURL == selectedURL
        } ?? 0

        let key = ObjectIdentifier(window)
        sessions[key]?.close()

        let session = MediaInspectorSession(
            items: items,
            selectedIndex: selectedIndex,
            source: source,
            window: window,
            annotationHost: annotationHost ?? defaultAnnotationHost?(window),
            onClose: { sessions.removeValue(forKey: key) }
        )
        sessions[key] = session
        return true
    }

    @discardableResult
    static func present(
        _ item: MediaInspectorItem,
        from source: NSView,
        annotationHost: MediaInspectorAnnotationHost? = nil
    ) -> Bool {
        present(
            MediaInspectorSelection(items: [item], selectedIndex: 0),
            from: source,
            annotationHost: annotationHost
        )
    }

    static func dismiss(in window: NSWindow?) {
        guard let window else { return }
        sessions[ObjectIdentifier(window)]?.close()
    }

    static func isPresenting(in window: NSWindow?) -> Bool {
        guard let window else { return false }
        return sessions[ObjectIdentifier(window)] != nil
    }
}

@MainActor
private final class MediaInspectorSession {

    private weak var source: NSView?
    private weak var window: NSWindow?
    private weak var previousFirstResponder: NSResponder?
    private let inspector: MediaInspectorView
    private let onClose: () -> Void
    private var isClosed = false
    /// Held **strongly**, because the view's reference is weak and a host built on demand by
    /// `defaultAnnotationHost` has no other owner. Without this the chat host was deallocated
    /// between being created and being asked for the marks, and annotation quietly never
    /// appeared outside the report sheet. No cycle: nothing a host owns owns this session.
    private let annotationHost: MediaInspectorAnnotationHost?
    /// The surface and its scrim, held as the one thing so neither can be taken away alone.
    private var presentation: InWindowOverlay.Presentation?

    init(
        items: [MediaInspectorItem],
        selectedIndex: Int,
        source: NSView,
        window: NSWindow,
        annotationHost: MediaInspectorAnnotationHost?,
        onClose: @escaping () -> Void
    ) {
        self.source = source
        self.window = window
        previousFirstResponder = window.firstResponder
        self.onClose = onClose
        self.annotationHost = annotationHost
        inspector = MediaInspectorView(
            items: items,
            selectedIndex: selectedIndex,
            annotationHost: annotationHost
        )

        inspector.onDismiss = { [weak self] in self?.close() }
        // Below the window's own chrome, never over it — see `InWindowOverlay`. Pinned to the
        // content view's top, this header opened *under* the traffic lights. The scrim under it
        // dims what stays visible above, and clicking it is the same dismissal the close button
        // and Escape run.
        presentation = InWindowOverlay.install(
            inspector,
            in: window,
            onDismiss: { [weak self] in self?.close() }
        )
        window.makeFirstResponder(inspector.preferredFirstResponder)
        NSAccessibility.post(element: inspector, notification: .layoutChanged)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        inspector.prepareForRemoval()
        presentation?.remove()
        presentation = nil

        if let window {
            if let source, source.window === window {
                window.makeFirstResponder(source)
            } else if let previousFirstResponder {
                window.makeFirstResponder(previousFirstResponder)
            }
        }
        onClose()
    }
}

// MARK: - Inspector

/// The complete in-window media experience: title and file actions, native image interaction,
/// embedded document rendering, collection navigation, and a recognisable thumbnail rail.
final class MediaInspectorView: NSView, ThemedComponent {

    private let items: [MediaInspectorItem]
    private(set) var selectedIndex: Int
    private let canvas = MediaInspectorCanvas()
    private let documentView = MediaInspectorDocumentView()
    /// Built lazily: most inspections are images, and a player that never plays anything should
    /// not be one more view every lightbox lays out.
    private lazy var mediaPlayer: MediaDocumentPlayerView = {
        let player = MediaDocumentPlayerView(
            loader: { [weak self] _ in
                await MainActor.run {
                    guard let self,
                          let data = try? BoundedFileReader.read(
                              self.selectedItem.url,
                              maximumBytes: MediaDocumentLimits.default.maximumDocumentBytes
                          ) else {
                        return .failure(.unresolvedSource)
                    }
                    return .success(data)
                }
            },
            // The lightbox always has a file: every item it walks is one. A format whose renderer
            // reads its own — a movie, which is never read into memory here or anywhere — is
            // therefore playable in the same rail as the pictures it sits between.
            fileLoader: { [weak self] _ in
                await MainActor.run {
                    guard let self else { return .failure(.unresolvedSource) }
                    return .success(self.selectedItem.url)
                }
            }
        )
        player.isHidden = true
        addSubview(player)
        NSLayoutConstraint.activate([
            player.topAnchor.constraint(equalTo: canvas.topAnchor),
            player.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
            player.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
            player.bottomAnchor.constraint(lessThanOrEqualTo: canvas.bottomAnchor)
        ])
        return player
    }()
    private var hasInstalledMediaPlayer = false
    private let headerSeparator = SeparatorView()
    private let railSeparator = SeparatorView()
    private let railScrollView = ThemedScrollView()
    private let railStack = NSStackView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let zoomLabel = NSTextField(labelWithString: "")
    private let zoomModeControl = ThemedSegmentedControl()
    private var thumbnails: [MediaInspectorThumbnail] = []
    private var railSelectionNeedsReveal = false
    private var railHeightConstraint: NSLayoutConstraint?
    private var menuSession: AnyObject?
    private var themeRedraw: ThemeRedraw?
    private let appEvents = AppEventObservations()

    // MARK: - Annotation

    private weak var annotationHost: MediaInspectorAnnotationHost?
    private let annotationPane = ImageAnnotationPaneView()
    /// **Vertical, and stating so is load-bearing.** A `SeparatorView` reports its thickness on
    /// the axis it is drawn along and `noIntrinsicMetric` on the other. Left at the default
    /// horizontal, this rule had no width of its own while sitting between the canvas's trailing
    /// edge and the notes column — so Auto Layout was free to satisfy the chain by giving the
    /// rule the room and the canvas none. The inspector then drew a blank picture, in every
    /// inspection in the app, with no broken constraint to say why.
    private let annotationSeparator = SeparatorView(.vertical, role: .paneBoundary)
    private var annotationWidthConstraint: NSLayoutConstraint?
    private var annotations: [ImageAnnotation] = []

    /// Whether marking is currently on. Held here rather than read off the canvas because the
    /// column, the toggle and the canvas all have to agree, and the canvas is one of the three.
    private(set) var isAnnotating = false

    private lazy var annotateButton = ThemedIconButton(
        symbolName: "mappin.and.ellipse",
        accessibility: MediaInspectorAnnotationStrings.toggle,
        target: .toolbar,
        inkSource: .chrome
    )

    var onDismiss: (() -> Void)?

    private lazy var previousButton = ThemedIconButton(
        symbolName: "chevron.left",
        accessibility: L10n.string("Previous item"),
        target: .toolbar,
        inkSource: .chrome
    )
    private lazy var nextButton = ThemedIconButton(
        symbolName: "chevron.right",
        accessibility: L10n.string("Next item"),
        target: .toolbar,
        inkSource: .chrome
    )
    private lazy var actionsButton = ThemedIconButton(
        symbolName: "ellipsis",
        accessibility: L10n.string("Media actions"),
        target: .toolbar,
        inkSource: .chrome
    )
    private lazy var closeButton = ThemedIconButton(
        symbolName: "xmark",
        accessibility: L10n.string("Close inspector"),
        target: .toolbar,
        inkSource: .chrome
    )

    init(
        items: [MediaInspectorItem],
        selectedIndex: Int,
        annotationHost: MediaInspectorAnnotationHost? = nil
    ) {
        self.items = items
        self.selectedIndex = min(max(selectedIndex, 0), max(0, items.count - 1))
        self.annotationHost = annotationHost
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        themeRedraw = ThemeRedraw(self)
        setup()
        showSelectedItem()

        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in self?.applyTheme() }
        appEvents.observe(ProfileDidChange.self) { [weak self] _ in self?.applyTheme() }
        appEvents.observe(AccessibilityDisplayOptionsDidChange.self) { [weak self] _ in
            self?.applyTheme()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    var preferredFirstResponder: NSView {
        canvas.isHidden ? self : canvas
    }

    private var selectedItem: MediaInspectorItem { items[selectedIndex] }

    var showsCollectionRail: Bool { items.count > 1 && !railScrollView.isHidden }
    var collectionThumbnailCount: Int { thumbnails.count }

    private func setup() {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(L10n.string("Media inspector"))

        titleLabel.applyFont(.subheading)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.applyFont(.caption)
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        zoomLabel.applyFont(.caption)
        zoomLabel.alignment = .right
        zoomLabel.setContentHuggingPriority(.required, for: .horizontal)
        zoomLabel.translatesAutoresizingMaskIntoConstraints = false

        zoomModeControl.configure(
            titles: [L10n.string("Fit"), L10n.string("100%")],
            selectedIndex: 0
        )
        zoomModeControl.setAccessibilityLabel(L10n.string("Image size"))
        zoomModeControl.onSelect = { [weak self] index in
            if index == 0 { self?.canvas.fit() } else { self?.canvas.showActualSize() }
        }
        zoomModeControl.translatesAutoresizingMaskIntoConstraints = false

        previousButton.onPress = { [weak self] in self?.move(by: -1) }
        nextButton.onPress = { [weak self] in self?.move(by: 1) }
        actionsButton.presentsMenu = true
        actionsButton.onPress = { [weak self] in self?.presentActions() }
        closeButton.onPress = { [weak self] in self?.onDismiss?() }

        canvas.onDismiss = { [weak self] in self?.onDismiss?() }
        canvas.onPrevious = { [weak self] in self?.move(by: -1) }
        canvas.onNext = { [weak self] in self?.move(by: 1) }
        canvas.onZoomChange = { [weak self] mode, percentage in
            self?.zoomChanged(mode: mode, percentage: percentage)
        }

        railScrollView.hasHorizontalScroller = true
        railScrollView.hasVerticalScroller = false
        railScrollView.autohidesScrollers = true
        railScrollView.translatesAutoresizingMaskIntoConstraints = false
        railStack.orientation = .horizontal
        railStack.alignment = .centerY
        railStack.spacing = Design.Spacing.small
        railStack.setAccessibilityElement(true)
        railStack.setAccessibilityRole(.radioGroup)
        railStack.setAccessibilityLabel(L10n.string("Media items"))
        railStack.edgeInsets = NSEdgeInsets(
            top: Design.Spacing.small,
            left: Design.Spacing.inset,
            bottom: Design.Spacing.small,
            right: Design.Spacing.inset
        )
        if items.count > 1 {
            railScrollView.documentView = railStack
            // Installing a document view replaces its frame with the scroll view's initial
            // zero-sized viewport. Seed the honest content extent *after* that handoff, before
            // the stack receives its arranged subviews, so their fixed targets are never solved
            // against the transient zero width. `layout()` widens it to the viewport when needed.
            railStack.frame = NSRect(
                x: 0,
                y: 0,
                width: Design.Spacing.inset * 2
                    + CGFloat(items.count) * Design.Size.mediaInspectorThumbnail
                    + CGFloat(max(0, items.count - 1)) * Design.Spacing.small,
                height: Design.Size.mediaInspectorRailHeight
            )
        }

        setupAnnotating()

        for view in [canvas, documentView, headerSeparator, railSeparator, railScrollView,
                     titleLabel, detailLabel, zoomLabel, zoomModeControl, previousButton,
                     nextButton, annotateButton, actionsButton, closeButton,
                     annotationPane, annotationSeparator] {
            addSubview(view)
        }

        let railHeight = railScrollView.heightAnchor.constraint(
            equalToConstant: items.count > 1 ? Design.Size.mediaInspectorRailHeight : 0
        )
        railHeightConstraint = railHeight

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.large),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: Design.Spacing.medium),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: zoomLabel.leadingAnchor,
                constant: -Design.Spacing.medium
            ),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: Design.Spacing.hairline),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Spacing.inset),
            closeButton.centerYAnchor.constraint(
                equalTo: topAnchor,
                constant: Design.Size.inspectorHeaderHeight / 2
            ),
            actionsButton.trailingAnchor.constraint(
                equalTo: closeButton.leadingAnchor,
                constant: -Design.Spacing.tight
            ),
            actionsButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            annotateButton.trailingAnchor.constraint(
                equalTo: actionsButton.leadingAnchor,
                constant: -Design.Spacing.tight
            ),
            annotateButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            zoomModeControl.trailingAnchor.constraint(
                equalTo: annotateButton.leadingAnchor,
                constant: -Design.Spacing.medium
            ),
            zoomModeControl.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            zoomLabel.trailingAnchor.constraint(
                equalTo: zoomModeControl.leadingAnchor,
                constant: -Design.Spacing.small
            ),
            zoomLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),

            headerSeparator.topAnchor.constraint(
                equalTo: topAnchor,
                constant: Design.Size.inspectorHeaderHeight
            ),
            headerSeparator.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),

            railScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            railScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            railScrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            railHeight,
            railSeparator.leadingAnchor.constraint(equalTo: leadingAnchor),
            railSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),
            railSeparator.bottomAnchor.constraint(equalTo: railScrollView.topAnchor),

            canvas.topAnchor.constraint(equalTo: headerSeparator.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: annotationSeparator.leadingAnchor),
            canvas.bottomAnchor.constraint(equalTo: railSeparator.topAnchor),

            // A column of zero width with nothing in it is what "not annotating" looks like, so
            // the ordinary inspector keeps exactly the geometry it had: the separator lands on
            // the trailing edge and the canvas reaches it.
            annotationSeparator.topAnchor.constraint(equalTo: canvas.topAnchor),
            annotationSeparator.bottomAnchor.constraint(equalTo: canvas.bottomAnchor),
            annotationSeparator.trailingAnchor.constraint(
                equalTo: annotationPane.leadingAnchor
            ),
            annotationPane.topAnchor.constraint(equalTo: canvas.topAnchor),
            annotationPane.bottomAnchor.constraint(equalTo: canvas.bottomAnchor),
            annotationPane.trailingAnchor.constraint(equalTo: trailingAnchor),
            documentView.topAnchor.constraint(equalTo: canvas.topAnchor),
            documentView.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
            documentView.bottomAnchor.constraint(equalTo: canvas.bottomAnchor),

            previousButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.inset),
            previousButton.centerYAnchor.constraint(equalTo: canvas.centerYAnchor),
            // Against the canvas rather than the window, so opening the notes column does not
            // leave the next-item chevron sitting on top of the fields.
            nextButton.trailingAnchor.constraint(
                equalTo: canvas.trailingAnchor,
                constant: -Design.Spacing.inset
            ),
            nextButton.centerYAnchor.constraint(equalTo: canvas.centerYAnchor)
        ])

        rebuildRail()
        applyTheme()
    }

    // MARK: - Annotating

    private func setupAnnotating() {
        annotateButton.isHidden = annotationHost == nil
        annotateButton.onPress = { [weak self] in
            guard let self else { return }
            self.setAnnotating(!self.isAnnotating)
        }

        annotationPane.setCollapsed(true)
        let width = annotationPane.widthAnchor.constraint(equalToConstant: 0)
        width.isActive = true
        annotationWidthConstraint = width
        annotationPane.isHidden = true
        annotationSeparator.isHidden = true

        canvas.onAddAnnotation = { [weak self] point in self?.addAnnotation(at: point) }
        canvas.onSelectAnnotation = { [weak self] id in
            guard let self else { return }
            self.annotationPane.selectedAnnotationID = id
            if let id { self.annotationPane.focusNote(for: id) }
        }

        annotationPane.onNoteChange = { [weak self] id, note in
            self?.updateAnnotation(id: id) { $0.note = note }
        }
        annotationPane.onRemove = { [weak self] id in
            guard let self else { return }
            self.applyAnnotations(self.annotations.filter { $0.id != id })
        }
        annotationPane.onFocus = { [weak self] id in
            self?.canvas.selectedAnnotationID = id
        }
        annotationPane.onShare = { [weak self] in
            guard let self else { return }
            self.annotationHost?.inspectorDidRequestShare(
                for: self.selectedItem,
                image: self.canvas.image
            )
            self.refreshAnnotationPane()
        }
        annotationPane.onRemoveFromChat = { [weak self] in
            guard let self else { return }
            self.annotationHost?.inspectorDidRequestRemoveFromChat(for: self.selectedItem)
            self.refreshAnnotationPane()
        }
    }

    /// Turning marking on opens the column with it: a mode whose only visible sign is a lit
    /// toolbar button is a mode people leave on and then wonder why the picture keeps growing
    /// pins. The fields are the mode's own evidence.
    func setAnnotating(_ annotating: Bool) {
        guard annotationHost != nil else { return }
        isAnnotating = annotating
        canvas.isAnnotating = annotating
        annotateButton.isSelected = annotating
        if annotating {
            annotationWidthConstraint?.constant = Design.Size.mediaInspectorAnnotationColumnWidth
            annotationPane.setCollapsed(false)
            annotationPane.isHidden = false
        } else {
            annotationPane.setCollapsed(true)
            annotationPane.isHidden = true
            annotationWidthConstraint?.constant = 0
        }
        annotationSeparator.isHidden = !annotating
        if annotating { reloadAnnotationsFromHost() }
        needsLayout = true
    }

    private func reloadAnnotationsFromHost() {
        annotations = annotationHost?.annotations(for: selectedItem) ?? []
        canvas.annotations = annotations
        refreshAnnotationPane()
    }

    private func addAnnotation(at point: CGPoint) {
        guard annotations.count < ImageAnnotationDefaults.maximumCount else { return }
        let annotation = ImageAnnotation(point: point)
        applyAnnotations(annotations + [annotation])
        canvas.selectedAnnotationID = annotation.id
        annotationPane.selectedAnnotationID = annotation.id
        annotationPane.focusNote(for: annotation.id)
    }

    private func updateAnnotation(
        id: ImageAnnotation.ID,
        _ change: (inout ImageAnnotation) -> Void
    ) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        var updated = annotations
        change(&updated[index])
        applyAnnotations(updated)
    }

    private func applyAnnotations(_ updated: [ImageAnnotation]) {
        annotations = updated
        canvas.annotations = updated
        annotationHost?.inspector(
            didChange: updated,
            for: selectedItem,
            image: canvas.image
        )
        refreshAnnotationPane()
    }

    private func refreshAnnotationPane() {
        guard let annotationHost else { return }
        annotationPane.setAnnotations(
            annotations,
            sharingState: annotationHost.sharingState(for: selectedItem),
            showsChatActions: annotationHost.showsChatActions(for: selectedItem),
            canShare: annotationHost.canShareAnnotations(for: selectedItem)
        )
    }

    /// `elevated`, not `ground`: the ground is by definition what the window behind this surface
    /// is already filled with, so in a dark palette there was no tonal boundary at all between the
    /// two — the inspector's header simply continued the window's own. The role vocabulary already
    /// has the word for a container standing above a panel, and the scrim under this view supplies
    /// the rest of the separation.
    override func draw(_ dirtyRect: NSRect) {
        Design.Surface.elevated.setFill()
        bounds.fill()
    }

    override func layout() {
        super.layout()
        guard items.count > 1 else { return }
        let viewport = railScrollView.contentSize
        let desiredWidth = max(viewport.width, railStack.fittingSize.width)
        railStack.frame = NSRect(
            x: 0,
            y: 0,
            width: desiredWidth,
            height: viewport.height
        )
        // Changing an `NSStackView`'s document frame does not synchronously reposition its
        // arranged subviews. Settle them on the first real viewport layout; otherwise the first
        // click is the event that moves the filmstrip into its shipping positions.
        railStack.layoutSubtreeIfNeeded()
        revealSelectedThumbnailIfPossible()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onDismiss?()
            return
        }
        let characters = event.charactersIgnoringModifiers ?? ""
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        switch characters {
        case " ":
            onDismiss?()
        case String(UnicodeScalar(NSLeftArrowFunctionKey)!):
            move(by: -1)
        case String(UnicodeScalar(NSRightArrowFunctionKey)!):
            move(by: 1)
        case "z", "Z":
            canvas.toggleFitAndActualSize()
        case "+", "=":
            if modifiers.contains(.command) { canvas.zoomIn() } else { super.keyDown(with: event) }
        case "-" where modifiers.contains(.command):
            canvas.zoomOut()
        case "0" where modifiers.contains(.command):
            canvas.fit()
        default:
            super.keyDown(with: event)
        }
    }

    /// Escape is a property of the transient surface, not of whichever child happens to own
    /// focus. AppKit offers key equivalents through the view tree first, so this also covers the
    /// close button, segmented control, thumbnail rail, and the contained PDF/Quick Look views.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == 53 else {
            return super.performKeyEquivalent(with: event)
        }
        // The actions menu is the topmost transient layer and owns the first Escape. The next
        // one reaches the inspector, matching ordinary nested AppKit menus and popovers.
        guard menuSession == nil else { return false }
        onDismiss?()
        return true
    }

    func prepareForRemoval() {
        ThemedMenuPresenter.dismiss(menuSession)
        menuSession = nil
        documentView.close()
        if hasInstalledMediaPlayer {
            // The lightbox is going away, so its clock goes with it rather than running behind
            // a window nobody can see.
            mediaPlayer.setPresentationActive(false)
        }
    }

    private func showSelectedItem() {
        let item = selectedItem
        let isMedia: Bool
        if case .media = item.content { isMedia = true } else { isMedia = false }
        let image = item.image ?? (item.content == .document || isMedia
            ? nil
            : BoundedImageDecoder.image(at: item.url, policy: .userMedia))

        titleLabel.stringValue = item.title
        titleLabel.toolTip = item.url.path
        detailLabel.stringValue = detail(for: item, image: image)

        if hasInstalledMediaPlayer {
            mediaPlayer.setPresentationActive(isMedia)
            mediaPlayer.isHidden = !isMedia
        }

        if case .media(let format) = item.content {
            canvas.clear()
            canvas.isHidden = true
            documentView.close()
            documentView.isHidden = true
            zoomModeControl.isHidden = true
            zoomLabel.isHidden = true
            hasInstalledMediaPlayer = true
            mediaPlayer.isHidden = false
            mediaPlayer.setPresentationActive(true)
            // Opening a two-second animation playing is what an animation is; opening a movie
            // playing is the app making a noise in a room it cannot see. The registry states
            // which is which, so the lightbox and the pane cannot disagree about it.
            let autoplays = MediaDocumentRendererRegistry.autoplaysWhenHostOpens(format)
            mediaPlayer.update(document: ExtensionMediaDocument(
                id: "inspector",
                source: .sessionAttachment(item.url.lastPathComponent),
                format: format,
                playback: ExtensionMediaPlayback(
                    isPlaying: autoplays,
                    loop: autoplays ? .loop : .once
                ),
                accessibilityLabel: item.title
            ))
        } else if let image, image.isValid {
            documentView.clear()
            documentView.isHidden = true
            canvas.isHidden = false
            canvas.configure(image: image, title: item.title)
            zoomModeControl.isHidden = false
            zoomLabel.isHidden = false
        } else if item.content != .image {
            canvas.clear()
            canvas.isHidden = true
            documentView.isHidden = false
            _ = documentView.display(item.url)
            zoomModeControl.isHidden = true
            zoomLabel.isHidden = true
        } else {
            canvas.clear()
            canvas.isHidden = true
            documentView.close()
            documentView.isHidden = true
            zoomModeControl.isHidden = true
            zoomLabel.isHidden = true
        }

        previousButton.isEnabled = selectedIndex > 0
        nextButton.isEnabled = selectedIndex + 1 < items.count
        previousButton.isHidden = items.count < 2
        nextButton.isHidden = items.count < 2

        // Marks belong to the picture, so arrowing to the next one asks the host for *its*
        // marks. Carrying them across would draw one image's pins on another.
        annotateButton.isEnabled = !canvas.isHidden
        if canvas.isHidden, isAnnotating {
            setAnnotating(false)
        } else if annotationHost?.annotations(for: item).isEmpty == false, !isAnnotating {
            setAnnotating(true)
        } else if isAnnotating {
            reloadAnnotationsFromHost()
        }

        updateRailSelection()
        window?.makeFirstResponder(preferredFirstResponder)
        setAccessibilityLabel(L10n.format("Media inspector, %@", item.title))
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    func move(by offset: Int) {
        let target = selectedIndex + offset
        guard items.indices.contains(target) else { return }
        selectedIndex = target
        showSelectedItem()
    }

    private func zoomChanged(mode: MediaInspectorZoomMode, percentage: Int) {
        zoomLabel.stringValue = "\(percentage)%"
        switch mode {
        case .fit: zoomModeControl.selectedIndex = 0
        case .actualSize: zoomModeControl.selectedIndex = 1
        case .custom: break
        }
    }

    private func rebuildRail() {
        for thumbnail in thumbnails {
            railStack.removeArrangedSubview(thumbnail)
            thumbnail.removeFromSuperview()
        }
        let showsRail = items.count > 1
        railScrollView.isHidden = !showsRail
        railSeparator.isHidden = !showsRail
        guard showsRail else {
            thumbnails = []
            return
        }
        thumbnails = items.enumerated().map { index, item in
            let thumbnail = MediaInspectorThumbnail(item: item)
            thumbnail.onChoose = { [weak self] in
                self?.selectedIndex = index
                self?.showSelectedItem()
            }
            thumbnail.onMove = { [weak self] offset in
                guard let self else { return }
                let target = index + offset
                guard self.items.indices.contains(target) else { return }
                self.selectedIndex = target
                self.showSelectedItem()
                self.window?.makeFirstResponder(self.thumbnails[target])
            }
            railStack.addArrangedSubview(thumbnail)
            return thumbnail
        }
        updateRailSelection()
    }

    private func updateRailSelection() {
        for (index, thumbnail) in thumbnails.enumerated() {
            thumbnail.isSelected = index == selectedIndex
        }
        railSelectionNeedsReveal = true
        revealSelectedThumbnailIfPossible()
    }

    private func revealSelectedThumbnailIfPossible() {
        guard railSelectionNeedsReveal,
              thumbnails.indices.contains(selectedIndex),
              railScrollView.contentSize.width > 0,
              railScrollView.contentSize.height > 0 else { return }
        railStack.layoutSubtreeIfNeeded()
        railSelectionNeedsReveal = false
        railScrollView.contentView.scrollToVisible(thumbnails[selectedIndex].frame)
        railScrollView.reflectScrolledClipView(railScrollView.contentView)
    }

    private func detail(for item: MediaInspectorItem, image: NSImage?) -> String {
        var parts: [String] = []
        if items.count > 1 {
            parts.append(L10n.format("%lld of %lld", Int64(selectedIndex + 1), Int64(items.count)))
        }
        if let image {
            parts.append("\(Int(image.size.width)) × \(Int(image.size.height))")
        } else if !item.url.pathExtension.isEmpty {
            parts.append(item.url.pathExtension.uppercased())
        }
        if let bytes = try? item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }

    private func applyTheme() {
        titleLabel.textColor = Design.Text.label
        detailLabel.textColor = Design.Text.tertiary
        zoomLabel.textColor = Design.Text.secondary
        documentView.applyTheme()
        needsDisplay = true
    }

    private func presentActions() {
        guard menuSession == nil else { return }
        let item = selectedItem
        let image = canvas.isHidden ? nil : canvas.image
        var entries: [ThemedMenuEntry] = []

        if let image {
            entries.append(menuItem("Copy Image") { Self.copy(image: image) })
        } else {
            entries.append(menuItem("Copy File") { Self.copy(file: item.url) })
        }
        entries.append(menuItem("Copy File Name") { Self.copy(string: item.title) })
        entries.append(menuItem("Copy File Path") { Self.copy(path: item.url) })
        entries.append(.separator)
        entries.append(menuItem("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
        })
        entries.append(menuItem("Open in Default App") {
            if !NSWorkspace.shared.open(item.url) { SystemAlert.refuse() }
        })
        entries.append(.separator)
        entries.append(menuItem("Open in System Quick Look") {
            if !QuickLookPresenter.shared.present(item.url) { SystemAlert.refuse() }
        })

        menuSession = ThemedMenuPresenter.present(
            ThemedMenuPresentation(entries: entries, minimumWidth: 220),
            from: actionsButton,
            selectedEntryIndex: nil,
            onChoose: { _, item in item.onChoose?() },
            onDismiss: { [weak self] in self?.menuSession = nil }
        )
    }

    private func menuItem(_ title: String, action: @escaping () -> Void) -> ThemedMenuEntry {
        .item(ThemedMenuItem(title: L10n.string(title), onChoose: action))
    }

    private static func copy(image: NSImage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    private static func copy(file url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
    }

    private static func copy(string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private static func copy(path url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
        NSPasteboard.general.setString(url.path, forType: .string)
    }
}

// MARK: - Native Image Canvas

/// The inspector's image renderer: fit/actual/custom zoom, anchored magnification, drag-to-pan,
/// collection swipes, and keyboard/accessibility equivalents for every operation.
final class MediaInspectorCanvas: ThemedControl {

    private enum Interaction {
        static let zoomStep: CGFloat = 1.25
        static let minimumScale: CGFloat = 0.05
        static let maximumScale: CGFloat = 16
        static let swipeThreshold: CGFloat = 48
    }

    private(set) var image: NSImage?
    private(set) var zoomMode: MediaInspectorZoomMode = .fit
    private(set) var customScale: CGFloat = 1
    private(set) var panOffset: NSPoint = .zero
    private var imageTitle = ""
    private var dragOrigin: NSPoint?
    private var dragStartingOffset = NSPoint.zero
    /// Whether this press has already moved the picture — see `mouseUp`.
    private var didPanDuringDrag = false
    private var horizontalGesture: CGFloat = 0
    private var focusOrigin = KeyboardFocusOrigin()

    var onDismiss: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onZoomChange: ((MediaInspectorZoomMode, Int) -> Void)?

    // MARK: - Annotation

    /// The marks drawn over the picture, in the order they were made.
    var annotations: [ImageAnnotation] = [] {
        didSet {
            guard annotations != oldValue else { return }
            needsDisplay = true
        }
    }

    var selectedAnnotationID: ImageAnnotation.ID? {
        didSet {
            guard selectedAnnotationID != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Whether a click marks the picture. Off by default: the canvas's own gesture is zoom and
    /// pan, and every inspection in the app that has nothing to do with reporting keeps it.
    var isAnnotating = false {
        didSet {
            guard isAnnotating != oldValue else { return }
            window?.invalidateCursorRects(for: self)
        }
    }

    var onAddAnnotation: ((CGPoint) -> Void)?
    var onSelectAnnotation: ((ImageAnnotation.ID?) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    /// Whether the ring is being drawn — see `KeyboardFocusOrigin`. Readable so the suppression
    /// can be asserted as itself rather than only inferred from two renders.
    var showsKeyboardFocusRing: Bool { hasKeyboardFocus && focusOrigin.isFromKeyboard }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { focusArrived(from: NSApp.currentEvent) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            focusOrigin.resigned()
            needsDisplay = true
        }
        return resigned
    }

    /// Internal rather than private so a fixture can state the event that moved focus:
    /// `NSApp.currentEvent` is whatever the run loop last pulled off the queue, and an unshown
    /// test window pulls nothing.
    func focusArrived(from event: NSEvent?) {
        focusOrigin.arrived(from: event)
        needsDisplay = true
    }

    var viewportRect: NSRect {
        bounds.insetBy(dx: Design.Spacing.large, dy: Design.Spacing.large)
    }

    var fitScale: CGFloat {
        guard let image, image.size.width > 0, image.size.height > 0,
              viewportRect.width > 0, viewportRect.height > 0 else { return 1 }
        return min(1, min(
            viewportRect.width / image.size.width,
            viewportRect.height / image.size.height
        ))
    }

    var displayedScale: CGFloat {
        switch zoomMode {
        case .fit: fitScale
        case .actualSize: 1
        case .custom: customScale
        }
    }

    var imageRect: NSRect {
        guard let image else { return .zero }
        let scale = displayedScale
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        return NSRect(
            x: bounds.midX - size.width / 2 + panOffset.x,
            y: bounds.midY - size.height / 2 + panOffset.y,
            width: size.width,
            height: size.height
        )
    }

    func configure(image: NSImage, title: String) {
        self.image = image
        imageTitle = title
        fit()
        setAccessibilityLabel(title)
        setAccessibilityHelp(
            L10n.string("Drag to pan. Pinch or press Command plus and minus to zoom. Press Space to close.")
        )
        needsDisplay = true
    }

    func clear() {
        image = nil
        imageTitle = ""
        zoomMode = .fit
        customScale = 1
        panOffset = .zero
        needsDisplay = true
    }

    func fit() {
        zoomMode = .fit
        panOffset = .zero
        stateChanged()
    }

    func showActualSize() {
        zoomMode = .actualSize
        panOffset = .zero
        stateChanged()
    }

    func toggleFitAndActualSize() {
        if zoomMode == .fit { showActualSize() } else { fit() }
    }

    func zoomIn() {
        zoom(by: Interaction.zoomStep, around: NSPoint(x: bounds.midX, y: bounds.midY))
    }

    func zoomOut() {
        zoom(by: 1 / Interaction.zoomStep, around: NSPoint(x: bounds.midX, y: bounds.midY))
    }

    func zoom(by factor: CGFloat, around anchor: NSPoint) {
        guard image != nil, factor.isFinite, factor > 0 else { return }
        let oldScale = displayedScale
        guard oldScale > 0 else { return }
        let newScale = min(max(oldScale * factor, Interaction.minimumScale), Interaction.maximumScale)
        let centre = NSPoint(x: bounds.midX, y: bounds.midY)
        let imagePoint = NSPoint(
            x: (anchor.x - centre.x - panOffset.x) / oldScale,
            y: (anchor.y - centre.y - panOffset.y) / oldScale
        )
        panOffset = NSPoint(
            x: anchor.x - centre.x - imagePoint.x * newScale,
            y: anchor.y - centre.y - imagePoint.y * newScale
        )
        zoomMode = .custom
        customScale = newScale
        clampPan()
        stateChanged()
    }

    func pan(by delta: NSPoint) {
        guard canPan else { return }
        panOffset.x += delta.x
        panOffset.y += delta.y
        clampPan()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        clampPan()
        stateChanged(notifyAccessibility: false)
    }

    /// The clip is taken here rather than left to the view: a view's `draw(_:)` is no longer
    /// confined to its own bounds, and this one draws an image deliberately larger than itself at
    /// every zoom above fit. Unclipped, an image shown at 100% reached up out of the canvas and
    /// over the inspector's header — the file's name, its dimensions, the zoom control and the
    /// close button left standing on the picture with no band under them, which is what "100%
    /// breaks the window" looked like. `clipsToBounds` says the same thing in one word but is
    /// macOS 14, and this app runs on 13.
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()

        ThemedSurface.draw(bounds, fill: Design.Surface.panel)
        guard let image else { return }
        image.draw(
            in: imageRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )

        // Inside the same clip as the picture, unlike the report sheet's preview: here the
        // picture is deliberately larger than the canvas at any zoom above fit, and a pin on a
        // part currently panned off screen would otherwise be drawn over the header.
        ImageAnnotationMarks.draw(
            annotations,
            in: imageRect,
            isFlipped: isFlipped,
            selected: selectedAnnotationID
        )

        // Only under keyboard traversal: this control fills the inspector, so the ring is an
        // accent rectangle around the whole window rather than a hint about where focus is.
        guard showsKeyboardFocusRing else { return }
        drawKeyboardFocus(
            around: ThemedSurface.Shape(rect: bounds, radius: Design.Radius.panel)
        )
    }

    /// What the canvas is offering right now: place a mark, take hold of the picture, or step
    /// the zoom. The arrow with nothing loaded — an empty canvas is still an opaque plate. See
    /// `PointerClaiming`.
    override var restingPointer: NSCursor? {
        guard image != nil else { return .arrow }
        if isAnnotating { return .crosshair }
        if canPan { return .openHand }
        if #available(macOS 15.0, *) { return zoomMode == .fit ? .zoomIn : .zoomOut }
        return .pointingHand
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount >= 2 {
            toggleFitAndActualSize()
            return
        }
        dragOrigin = convert(event.locationInWindow, from: nil)
        dragStartingOffset = panOffset
        didPanDuringDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard canPan, let dragOrigin else { return }
        let point = convert(event.locationInWindow, from: nil)
        panOffset = dragStartingOffset
        pan(by: NSPoint(x: point.x - dragOrigin.x, y: point.y - dragOrigin.y))
        didPanDuringDrag = true
    }

    /// **A mark is a click, and panning is a drag — the mark is decided on the way up.**
    ///
    /// Both gestures start with the button going down on the same pixel, and a zoomed picture is
    /// exactly when a person both wants to pan *and* has a reason to mark a detail. Deciding on
    /// the way down would have made annotation mode drop a pin at the start of every pan; the
    /// first version did, and marking anything at 400% was impossible without also leaving a pin
    /// where the drag began.
    override func mouseUp(with event: NSEvent) {
        defer {
            dragOrigin = nil
            didPanDuringDrag = false
        }
        guard isAnnotating, !didPanDuringDrag, event.clickCount == 1, image != nil else { return }

        let point = convert(event.locationInWindow, from: nil)
        if let hit = ImageAnnotationGeometry.annotationID(
            at: point,
            among: annotations,
            in: imageRect,
            isFlipped: isFlipped
        ) {
            selectedAnnotationID = hit
            onSelectAnnotation?(hit)
            return
        }
        guard let normalized = ImageAnnotationGeometry.normalizedPoint(
            for: point,
            in: imageRect,
            isFlipped: isFlipped
        ) else {
            onSelectAnnotation?(nil)
            return
        }
        onAddAnnotation?(normalized)
    }

    override func magnify(with event: NSEvent) {
        let factor = max(0.1, 1 + event.magnification)
        zoom(by: factor, around: convert(event.locationInWindow, from: nil))
    }

    override func scrollWheel(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command) {
            zoom(
                by: exp(event.scrollingDeltaY / 100),
                around: convert(event.locationInWindow, from: nil)
            )
            return
        }

        if canPan, abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) {
            pan(by: NSPoint(x: event.scrollingDeltaX, y: event.scrollingDeltaY))
            return
        }

        if event.phase == .began { horizontalGesture = 0 }
        horizontalGesture += event.scrollingDeltaX
        if event.phase == .ended || event.momentumPhase == .ended {
            if horizontalGesture > Interaction.swipeThreshold {
                onPrevious?()
            } else if horizontalGesture < -Interaction.swipeThreshold {
                onNext?()
            }
            horizontalGesture = 0
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onDismiss?()
            return
        }
        let characters = event.charactersIgnoringModifiers ?? ""
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch characters {
        case " ":
            onDismiss?()
        case String(UnicodeScalar(NSLeftArrowFunctionKey)!):
            onPrevious?()
        case String(UnicodeScalar(NSRightArrowFunctionKey)!):
            onNext?()
        case "z", "Z":
            toggleFitAndActualSize()
        case "+", "=":
            if modifiers.contains(.command) { zoomIn() } else { super.keyDown(with: event) }
        case "-" where modifiers.contains(.command):
            zoomOut()
        case "0" where modifiers.contains(.command):
            fit()
        default:
            super.keyDown(with: event)
        }
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .image }
    override func accessibilityLabel() -> String? { imageTitle }
    override func accessibilityValue() -> Any? { "\(Int((displayedScale * 100).rounded()))%" }
    override func accessibilityPerformPress() -> Bool {
        toggleFitAndActualSize()
        return true
    }
    override func accessibilityPerformIncrement() -> Bool {
        zoomIn()
        return true
    }
    override func accessibilityPerformDecrement() -> Bool {
        zoomOut()
        return true
    }

    private var canPan: Bool {
        let rect = imageRect
        return rect.width > viewportRect.width || rect.height > viewportRect.height
    }

    private func clampPan() {
        guard let image else {
            panOffset = .zero
            return
        }
        let size = NSSize(
            width: image.size.width * displayedScale,
            height: image.size.height * displayedScale
        )
        let maximumX = max(0, (size.width - viewportRect.width) / 2)
        let maximumY = max(0, (size.height - viewportRect.height) / 2)
        panOffset.x = min(max(panOffset.x, -maximumX), maximumX)
        panOffset.y = min(max(panOffset.y, -maximumY), maximumY)
    }

    private func stateChanged(notifyAccessibility: Bool = true) {
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        onZoomChange?(zoomMode, Int((displayedScale * 100).rounded()))
        if notifyAccessibility {
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }
}

// MARK: - Document System-Chrome Boundary

/// PDFKit supplies the native document renderer; Quick Look supplies the embedded fallback for
/// formats Threading does not render itself. Their descendants are system-owned by definition,
/// so the exception is explicit and cannot leak to siblings in the inspector.
final class MediaInspectorDocumentView: NSView, ThemedComponent, SystemChromeBoundary {

    struct DisplayTiming {
        var prepareNanoseconds: UInt64 = 0
        var installNanoseconds: UInt64 = 0
        var presentNanoseconds: UInt64 = 0
    }

    private var pdfView: PDFView?
    /// Held only while Quick Look will still accept an item for it — see `discardQuickLookView`.
    private var quickLookView: QLPreviewView?
    /// What Quick Look has been asked to show, which outlives the renderer showing it: a document
    /// view is unparented by an ordinary tab switch, and the document has to come back with it.
    private var quickLookURL: URL?
    private let windowEvents = AppEventObservations()
    private var themeRedraw: ThemeRedraw?
    private(set) var latestDisplayTimingForTesting = DisplayTiming()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        themeRedraw = ThemeRedraw(self)

        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        pdfView?.frame = bounds
        quickLookView?.frame = bounds
    }

    override func draw(_ dirtyRect: NSRect) {
        Design.Surface.panel.setFill()
        bounds.fill()
    }

    /// A Quick Look renderer lives no longer than the window it was built in.
    ///
    /// `QLPreviewView` closes itself with its window — `shouldCloseWithWindow` is true by
    /// default — and a closed one does not *refuse* the next item, it aborts the process:
    /// `-[QLPreviewView setPreviewItem:]` raises "Trying to set a preview item on a closed
    /// preview view" through `_QLCrash`. Nothing about this view is transient, so ordinary tab
    /// handling reached that: an Attachments tab dragged into its own window and then closed
    /// hands the *same* controller back to the display panel, and the next attachment it was
    /// asked to preview killed the app.
    ///
    /// So the renderer is dropped both when the window announces its close and when this view
    /// leaves a window at all — the two arrive in an order AppKit does not promise, and either
    /// one alone leaves a hole. That makes `quickLookView != nil` mean "Quick Look will still
    /// take an item", which is the one thing every call below relies on.
    ///
    /// **The document is not dropped with it.** Unparenting is ordinary here — the display panel
    /// unparents a tab's controller whenever another tab is shown — so a renderer discarded on
    /// the way out is rebuilt on the way back in, from `quickLookURL`. Without that, switching
    /// away from Attachments and back would return a pane whose list still names a document over
    /// a preview area with nothing in it.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowEvents.removeAll()
        guard let window else {
            discardQuickLookView()
            return
        }
        windowEvents.observe(NSWindow.willCloseNotification, object: window) { [weak self] in
            self?.discardQuickLookView()
        }
        if let quickLookURL, quickLookView == nil {
            display(quickLookURL)
        }
    }

    @discardableResult
    func display(_ url: URL) -> Bool {
        var timing = DisplayTiming()
        defer { latestDisplayTimingForTesting = timing }
        clear()
        if url.pathExtension.lowercased() == "pdf" {
            let prepareStarted = DispatchTime.now().uptimeNanoseconds
            guard let document = PDFDocument(url: url) else { return false }
            timing.prepareNanoseconds = DispatchTime.now().uptimeNanoseconds - prepareStarted
            let installStarted = DispatchTime.now().uptimeNanoseconds
            let pdfView = installedPDFView()
            timing.installNanoseconds = DispatchTime.now().uptimeNanoseconds - installStarted
            let presentStarted = DispatchTime.now().uptimeNanoseconds
            pdfView.document = document
            pdfView.isHidden = false
            timing.presentNanoseconds = DispatchTime.now().uptimeNanoseconds - presentStarted
        } else {
            let installStarted = DispatchTime.now().uptimeNanoseconds
            guard let quickLookView = installedQuickLookView() else { return false }
            timing.installNanoseconds = DispatchTime.now().uptimeNanoseconds - installStarted
            let presentStarted = DispatchTime.now().uptimeNanoseconds
            quickLookView.previewItem = url as NSURL
            quickLookView.isHidden = false
            quickLookURL = url
            timing.presentNanoseconds = DispatchTime.now().uptimeNanoseconds - presentStarted
        }
        return true
    }

    func clear() {
        pdfView?.document = nil
        quickLookView?.previewItem = nil
        quickLookURL = nil
        pdfView?.isHidden = true
        quickLookView?.isHidden = true
    }

    func close() {
        clear()
        discardQuickLookView()
    }

    func applyTheme() {
        pdfView?.backgroundColor = Design.Surface.panel
        needsDisplay = true
    }

    func permitsSystemChrome(_ view: NSView) -> Bool {
        if let pdfView, belongs(view, to: pdfView) { return true }
        if let quickLookView, belongs(view, to: quickLookView) { return true }
        return false
    }

    var hasPDFRendererForTesting: Bool { pdfView != nil }
    var hasQuickLookRendererForTesting: Bool { quickLookView != nil }

    private func installedPDFView() -> PDFView {
        if let pdfView { return pdfView }
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.backgroundColor = Design.Surface.panel
        view.frame = bounds
        view.isHidden = true
        addSubview(view)
        pdfView = view
        return view
    }

    private func installedQuickLookView() -> QLPreviewView? {
        if let quickLookView { return quickLookView }
        guard let view = QLPreviewView(frame: bounds, style: .normal) else { return nil }
        view.autostarts = true
        view.isHidden = true
        addSubview(view)
        quickLookView = view
        return view
    }

    /// Forgets the renderer. It is dropped, **not** `close()`d, and that is the second half of
    /// the same lesson: `-[QLPreviewView close]` aborts through `_QLRaiseAssert` in `deactivate`
    /// when the view was never activated — a document previewed before the pane reached a window,
    /// which the attachments pane does on every cold open. Closing is Quick Look's own job here,
    /// since `shouldCloseWithWindow` is left true; ours is only to stop reusing what it closed.
    ///
    /// Dropping the reference is therefore the whole operation, and it must stay callable from
    /// inside `NSWindow.willCloseNotification` — where Quick Look's identical observer may have
    /// run first — without calling into Quick Look at all.
    private func discardQuickLookView() {
        guard let view = quickLookView else { return }
        quickLookView = nil
        view.removeFromSuperview()
    }

    private func belongs(_ view: NSView, to root: NSView) -> Bool {
        var candidate: NSView? = view
        while let current = candidate {
            if current === root { return true }
            if current === self { return false }
            candidate = current.superview
        }
        return false
    }
}

// MARK: - Collection Thumbnail

private final class MediaInspectorThumbnail: ThemedControl {

    private let item: MediaInspectorItem
    private let preview: NSImage?
    private var isTrackingPress = false
    private var isPressArmed = false
    var onChoose: (() -> Void)?
    var onMove: ((Int) -> Void)?
    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            needsDisplay = true
            setAccessibilityValue(isSelected)
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }

    init(item: MediaInspectorItem) {
        self.item = item
        let thumbnailPixels = Int(
            (Design.Size.mediaInspectorThumbnail * 2).rounded(.up)
        )
        var isThumbnailable = item.content != .document
        if case .media = item.content { isThumbnailable = false }
        preview = item.image ?? (!isThumbnailable
            ? nil
            : BoundedImageDecoder.thumbnail(
                at: item.url,
                policy: .thumbnail(maximumPixelDimension: thumbnailPixels)
            ))
            ?? NSWorkspace.shared.icon(forFile: item.url.path)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        toolTip = item.title
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Design.Size.mediaInspectorThumbnail),
            heightAnchor.constraint(equalToConstant: Design.Size.mediaInspectorThumbnail)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = ThemedSurface.draw(
            bounds,
            fill: isHovered || isPressArmed
                ? Design.Surface.controlHover
                : Design.Surface.controlResting,
            border: isSelected ? Design.Surface.accent : Design.Surface.border
        )
        if let preview, preview.size.width > 0, preview.size.height > 0 {
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            shape.path.addClip()
            let inset = bounds.insetBy(dx: Design.Spacing.tight, dy: Design.Spacing.tight)
            let scale = min(inset.width / preview.size.width, inset.height / preview.size.height)
            let rect = NSRect(
                x: inset.midX - preview.size.width * scale / 2,
                y: inset.midY - preview.size.height * scale / 2,
                width: preview.size.width * scale,
                height: preview.size.height * scale
            )
            preview.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        }
        drawKeyboardFocus(around: shape)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        isTrackingPress = true
        isPressArmed = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isTrackingPress else { return }
        let armed = bounds.contains(convert(event.locationInWindow, from: nil))
        guard armed != isPressArmed else { return }
        isPressArmed = armed
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let shouldChoose = isTrackingPress && isPressArmed
            && bounds.contains(convert(event.locationInWindow, from: nil))
        isTrackingPress = false
        isPressArmed = false
        needsDisplay = true
        if shouldChoose { onChoose?() }
    }

    override func performPrimaryAction() -> Bool {
        onChoose?()
        return true
    }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case String(UnicodeScalar(NSLeftArrowFunctionKey)!): onMove?(-1)
        case String(UnicodeScalar(NSRightArrowFunctionKey)!): onMove?(1)
        default: super.keyDown(with: event)
        }
    }

    override var restingPointer: NSCursor? { .pointingHand }

    override func accessibilityRole() -> NSAccessibility.Role? { .radioButton }
    override func accessibilityLabel() -> String? { item.title }
    override func accessibilityValue() -> Any? { isSelected }
    override func accessibilityPerformPress() -> Bool { performPrimaryAction() }
}
