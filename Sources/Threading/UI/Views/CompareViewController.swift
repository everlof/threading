import AppKit
import ImageIO

/// The Compare tab: two files against each other — images on the interactive compare surface,
/// text as a native diff.
///
/// The controller is built cheap and loads nothing until `refresh(force:)`, which is when the
/// tab is actually shown — the pane's deferred rule, same as Review. What the pair *is* is
/// decided from the bytes, not the caller's claim: both sides text → `git diff --no-index`,
/// both sides images → `ImageCompareView`, anything else → an honest sentence.
final class CompareViewController: NSViewController {

    // MARK: - Properties

    let sessionID: SessionID
    let oldPath: String
    let newPath: String
    let oldTitle: String
    let newTitle: String

    private(set) var compareMode: ImageCompareMode

    /// Called when the user picks a different mode, so the pane can persist the tab with it.
    var onChange: (() -> Void)?

    /// Feeds the tab's loading affordance, same contract as Review's — including the deinit
    /// rule: a controller torn down mid-load lowers what it raised, or the row spins forever.
    var onLoadingChange: (@MainActor @Sendable (Bool) -> Void)?

    private lazy var stack: NSStackView = {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.small
        stack.translatesAutoresizingMaskIntoConstraints = false
        // No top inset: the gap under the header row is the scroll view's, so the comparison
        // starts where a reader's eye already is rather than an inset lower than the row above.
        stack.edgeInsets = NSEdgeInsets(
            top: 0,
            left: Design.Spacing.inset,
            bottom: Design.Spacing.inset,
            right: Design.Spacing.inset
        )
        return stack
    }()
    private lazy var scrollView: ThemedScrollView = {
        let clipView = FlippedClipView()
        clipView.drawsBackground = false
        let scroll = ThemedScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.contentView = clipView
        scroll.documentView = stack
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        return scroll
    }()
    private lazy var placeholderLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.applyFont(.body)
        label.textColor = Design.Text.tertiary
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.isHidden = true
        return label
    }()

    /// The tab's controls, above the scroll view rather than inside it.
    ///
    /// Git Review's shape, one tab along: a chip at the leading edge, the actions at the
    /// trailing one, no band and no hairline — the pane's own header is the tab strip a few
    /// points above, and a second banded header under it would read as chrome about chrome. What
    /// makes this row belong to the *comparison* is that it is inset like the content and scrolls
    /// with nothing.
    ///
    /// The mode chip and the expand button in it are the compare surface's own
    /// (`ImageCompareView.hostControls`), not copies: below the canvas they were part of the
    /// scrolled content and left the screen exactly when a tall screenshot had been read far
    /// enough to want another mode.
    ///
    /// A `ControlRowView` rather than a stack, because a stack made this row wrong in both
    /// axes: the chip stood six points taller than the two buttons beside it, and the actions
    /// sat against the chip instead of at the pane's trailing edge — the caption was doing duty
    /// as a spring and an empty label is not one. The row states the height its members take
    /// and pins its two runs to opposite edges, so neither is a thing this file decides.
    private lazy var headerRow = ControlRowView(
        scale: ImageCompareView.controlScale,
        leading: [captionLabel],
        trailing: [exportButton]
    )

    /// Names the pair where the surface does not name it itself — a text diff, or a message.
    private lazy var captionLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.applyFont(.caption)
        label.textColor = Design.Text.secondary
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }()

    private lazy var exportButton: ThemedIconButton = {
        let button = ThemedIconButton(
            symbolName: "square.and.arrow.up",
            accessibility: L10n.string("Export comparison"),
            target: .inline,
            inkSource: .chrome
        )
        button.toolTip = L10n.string("Export comparison")
        button.onPress = { [weak self] in self?.exportComparison() }
        button.isHidden = true
        return button
    }()

    private var compareView: ImageCompareView?

    /// What the last read turned out to be, kept so the export can be built from the same answer
    /// the body was drawn from rather than by reading both files a second time.
    private var lastComparison: Comparison?

    /// Held while the save sheet is up; released from its own completion.
    private var exportSession: CompareExportPanel?

    /// The canvas's height, which is a function of the pane's width and so is recomputed
    /// whenever that changes rather than being read once as the body is built.
    private var compareHeightConstraint: NSLayoutConstraint?

    private var hasLoaded = false
    /// Stale async results are dropped by generation, not cancelled — the read is already
    /// running.
    private var generation = 0
    private var isLoading = false {
        didSet {
            guard isLoading != oldValue else { return }
            onLoadingChange?(isLoading)
        }
    }

    private static let queue = DispatchQueue(label: "codes.threading.compare", qos: .userInitiated)

    /// What the two files turned out to be.
    enum Comparison: @unchecked Sendable {
        case images(old: Data?, new: Data?)
        case text([GitFileDiff])
        case message(String)
    }

    // MARK: - Initialization

    init(
        sessionID: SessionID,
        oldPath: String,
        newPath: String,
        oldTitle: String?,
        newTitle: String?,
        mode: ImageCompareMode
    ) {
        self.sessionID = sessionID
        self.oldPath = oldPath
        self.newPath = newPath
        self.oldTitle = oldTitle ?? (oldPath as NSString).lastPathComponent
        self.newTitle = newTitle ?? (newPath as NSString).lastPathComponent
        self.compareMode = mode
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        // Same rule as Review: torn down mid-load, the raise this controller made is one
        // nothing else can lower — the read's completion holds the controller weakly and
        // dies with it.
        if isLoading {
            let onLoadingChange = onLoadingChange
            Task { @MainActor in
                onLoadingChange?(false)
            }
        }
    }

    // MARK: - Lifecycle

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.addSubview(headerRow)
        view.addSubview(scrollView)
        view.addSubview(placeholderLabel)

        NSLayoutConstraint.activate([
            // The toolbar insets the safe area; pinning to the view's own top would slide the
            // row under it. Git Review's margin, so the two tabs start on one line.
            headerRow.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor, constant: Design.Spacing.inset
            ),
            headerRow.leadingAnchor.constraint(
                equalTo: view.leadingAnchor, constant: Design.Spacing.inset
            ),
            headerRow.trailingAnchor.constraint(
                equalTo: view.trailingAnchor, constant: -Design.Spacing.inset
            ),
            scrollView.topAnchor.constraint(
                equalTo: headerRow.bottomAnchor, constant: Design.Spacing.small
            ),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            placeholderLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            placeholderLabel.widthAnchor.constraint(
                lessThanOrEqualTo: view.widthAnchor, constant: -Design.Spacing.pane
            )
        ])
    }

    /// The pane's width is only known here, and it changes every time the divider moves.
    override func viewDidLayout() {
        super.viewDidLayout()
        updateCompareHeight()
    }

    /// The height the canvas needs at the width it currently has.
    ///
    /// Written only when it actually changes: this runs on every layout pass, and assigning a
    /// constant marks the view dirty, so writing an unchanged value would lay the pane out
    /// again on the next pass and never stop.
    private func updateCompareHeight() {
        guard let compareView, let compareHeightConstraint else { return }

        // The canvas is pinned an inset in from each of the stack's own edges, and the stack is
        // the scroll view's width. The floor only keeps the ratio divisible — it is not a
        // minimum anyone chose. (It used to be 200, which described a pane the panel no longer
        // has to be: below that width every image was fitted as though there were more room
        // than there is.)
        let available = max(view.bounds.width - Design.Spacing.inset * 2, 1)
        let height = compareView.preferredHeight(forWidth: available)

        guard abs(compareHeightConstraint.constant - height) > 0.5 else { return }
        compareHeightConstraint.constant = height
    }

    // MARK: - Public Methods

    /// Reads the pair and builds the body. Runs no I/O until first called, and only re-reads
    /// when forced — the files a comparison was asked about rarely change under it, and a
    /// watched re-read would cost the reader their place for nothing.
    func refresh(force: Bool) {
        // A tab that has never been shown has no body to build into — and nothing read while
        // unseen is the pane's rule anyway. The first show calls again.
        guard isViewLoaded else { return }
        guard force || !hasLoaded else { return }
        hasLoaded = true
        generation += 1
        let expected = generation
        isLoading = true

        let oldPath = oldPath
        let newPath = newPath
        Self.queue.async {
            let comparison = Self.compare(oldPath: oldPath, newPath: newPath)
            Task { @MainActor [weak self] in
                guard let self, expected == self.generation else { return }
                self.isLoading = false
                self.render(comparison)
            }
        }
    }

    /// Classifies and reads the pair. On the comparison queue; everything returned is value
    /// data, which is safe to carry back to the main actor where AppKit images are built.
    nonisolated static func compare(oldPath: String, newPath: String) -> Comparison {
        let oldKind = CompareFileClassifier.classify(path: oldPath)
        let newKind = CompareFileClassifier.classify(path: newPath)

        switch (oldKind, newKind) {
        case (.missing, .missing):
            return .message(L10n.string("Neither file exists any more."))
        case (.missing, _), (_, .missing):
            let gone = oldKind == .missing ? oldPath : newPath
            return .message(
                L10n.format("No such file: %@", (gone as NSString).lastPathComponent)
            )
        case (.tooLarge, _), (_, .tooLarge):
            return .message(
                L10n.format(
                    "One side is larger than the %@ the comparison reads.",
                    ByteCountFormatter.string(
                        fromByteCount: Int64(CompareDefaults.maximumBytes),
                        countStyle: .file
                    )
                )
            )
        case (.image, .image):
            return .images(
                old: try? BoundedFileReader.read(
                    URL(fileURLWithPath: oldPath),
                    maximumBytes: CompareDefaults.maximumBytes
                ),
                new: try? BoundedFileReader.read(
                    URL(fileURLWithPath: newPath),
                    maximumBytes: CompareDefaults.maximumBytes
                )
            )
        case (.text, .text):
            return textComparison(oldPath: oldPath, newPath: newPath)
        case (.image, .text), (.text, .image):
            return .message(
                L10n.string(
                    "One side is an image and the other is text — there is no comparison to draw."
                )
            )
        default:
            return .message(
                L10n.string("These files are binary, and not images Threading can compare.")
            )
        }
    }

    nonisolated private static func textComparison(
        oldPath: String,
        newPath: String
    ) -> Comparison {
        do {
            let data = try GitProcess.run(
                GitReviewCommands.compareFiles(oldPath: oldPath, newPath: newPath),
                in: URL(fileURLWithPath: (oldPath as NSString).deletingLastPathComponent),
                acceptedExitCodes: [0, 1]
            )
            let files = GitDiffParser.files(fromUnifiedDiff: GitDiffParser.decode(data))
            guard files.contains(where: { !$0.hunks.isEmpty }) else {
                return .message(L10n.string("The files are identical."))
            }
            return .text(files)
        } catch let failure as GitFailure {
            return .message(failure.localizedDescription)
        } catch {
            return .message(error.localizedDescription)
        }
    }

    // MARK: - Private Methods

    private func render(_ comparison: Comparison) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        compareView = nil
        lastComparison = comparison
        placeholderLabel.isHidden = true
        scrollView.isHidden = false
        updateHeader(for: comparison)

        switch comparison {
        case .message(let text):
            scrollView.isHidden = true
            placeholderLabel.isHidden = false
            placeholderLabel.stringValue = text

        case .images(let old, let new):
            let oldImage = old.flatMap(NSImage.init(data:))
            let newImage = new.flatMap(NSImage.init(data:))
            guard oldImage != nil || newImage != nil else {
                scrollView.isHidden = true
                placeholderLabel.isHidden = false
                placeholderLabel.stringValue = L10n.string(
                    "Neither image could be read."
                )
                return
            }
            let compare = ImageCompareView(frame: .zero)
            compare.translatesAutoresizingMaskIntoConstraints = false
            compare.mode = compareMode
            compare.configure(
                old: oldImage.map { .init(image: $0, title: oldTitle) },
                new: newImage.map { .init(image: $0, title: newTitle) }
            )
            compare.onModeChange = { [weak self] mode in
                self?.compareMode = mode
                // Side by side fits each image into half the width, so the height the canvas
                // wants changes with the mode as well as with the pane.
                self?.updateCompareHeight()
                self?.onChange?()
            }
            // The surface's own controls move up into this tab's header, which is also what
            // stops the surface reserving a row for them under the canvas. The row sizes them
            // to itself as they arrive, so they stand level with each other and with the
            // caption whatever height the current theme gives a chooser.
            let controls = compare.hostControls()
            headerRow.configure(
                leading: [controls.mode, captionLabel],
                trailing: [exportButton, controls.expansion]
            )

            compareView = compare
            stack.addArrangedSubview(compare)

            // The scroll pane gives height no floor, so the canvas states its own: the fitted
            // height at the pane's width, capped like a review row.
            //
            // **Kept, and recomputed.** It used to be a constant read from `view.bounds.width`
            // as the body was built — before the pane had been laid out at all on the first
            // build — and never touched again. The canvas then held that one height for the
            // rest of its life: dragging the divider changed the width the images were fitted
            // into while the box around them stayed put, which is the compare tab "not
            // resizing". A height that comes from a width has to be recomputed when the width
            // changes; see `viewDidLayout`.
            let height = compare.heightAnchor.constraint(equalToConstant: 0)
            compareHeightConstraint = height

            NSLayoutConstraint.activate([
                compare.leadingAnchor.constraint(
                    equalTo: stack.leadingAnchor, constant: Design.Spacing.inset
                ),
                compare.trailingAnchor.constraint(
                    equalTo: stack.trailingAnchor, constant: -Design.Spacing.inset
                ),
                height
            ])
            updateCompareHeight()

        case .text(let files):
            // The old cap applied once per hunk, so a generated diff with thousands of tiny
            // hunks still built thousands of text views and constraint pairs on the main
            // thread. One comparison gets one global display budget and one view. `comparison`
            // remains complete in `lastComparison`, so export still carries every hunk and line.
            let display = Self.displayedTextLines(in: files)
            let diff = DiffView(
                gitLines: display.lines,
                displayCap: display.lines.count,
                path: newPath,
                wraps: true
            )
            diff.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(diff)
            NSLayoutConstraint.activate([
                diff.leadingAnchor.constraint(
                    equalTo: stack.leadingAnchor, constant: Design.Spacing.inset
                ),
                diff.trailingAnchor.constraint(
                    equalTo: stack.trailingAnchor, constant: -Design.Spacing.inset
                )
            ])

            if display.hasMore {
                let note = NSTextField(wrappingLabelWithString: L10n.format(
                    "Showing the first %lld diff lines. Export the comparison for the complete diff.",
                    Int64(display.lines.count)
                ))
                note.translatesAutoresizingMaskIntoConstraints = false
                note.applyFont(.caption)
                note.textColor = Design.Text.tertiary
                stack.addArrangedSubview(note)
                NSLayoutConstraint.activate([
                    note.leadingAnchor.constraint(
                        equalTo: stack.leadingAnchor, constant: Design.Spacing.inset
                    ),
                    note.trailingAnchor.constraint(
                        equalTo: stack.trailingAnchor, constant: -Design.Spacing.inset
                    )
                ])
            }
        }
    }

    /// Takes at most the pane's complete line budget without first flattening or copying the
    /// unbounded diff. Line numbers stay attached to each source line, so hunk/file boundaries
    /// remain legible as jumps even though they no longer allocate separate views.
    private static func displayedTextLines(
        in files: [GitFileDiff]
    ) -> (lines: [GitDiffLine], hasMore: Bool) {
        var lines: [GitDiffLine] = []
        lines.reserveCapacity(DiffDefaults.displayCap)

        for file in files {
            for hunk in file.hunks where !hunk.lines.isEmpty {
                let remaining = DiffDefaults.displayCap - lines.count
                guard remaining > 0 else { return (lines, true) }
                lines.append(contentsOf: hunk.lines.prefix(remaining))
                if hunk.lines.count > remaining { return (lines, true) }
            }
        }
        return (lines, false)
    }

    /// What the header says about the comparison under it.
    ///
    /// The caption names the pair only where nothing else does. An image comparison already
    /// tags both sides on the surface, and repeating the two filenames a line above them in a
    /// pane this narrow is two-thirds of a row spent saying nothing new — so there the caption
    /// is empty and serves as the row's slack, holding the chip at one edge and the actions at
    /// the other.
    private func updateHeader(for comparison: Comparison) {
        // Whatever the last comparison hosted is not this one's: a re-read that turns a pair of
        // images into a message would otherwise leave its mode chip in the header, switching the
        // mode of a surface that no longer exists. `render` puts the new one back.
        headerRow.configure(leading: [captionLabel], trailing: [exportButton])

        switch comparison {
        case .images:
            captionLabel.stringValue = ""
        case .text, .message:
            captionLabel.stringValue = "\(oldTitle) → \(newTitle)"
        }
        exportButton.isHidden = !canExport(comparison)
    }

    /// Whether there is a comparison to send anyone. A message is the app explaining why there
    /// is not one, and exporting that would be exporting the explanation.
    private func canExport(_ comparison: Comparison) -> Bool {
        switch comparison {
        case .images(let old, let new): return old != nil || new != nil
        case .text(let files): return !files.isEmpty
        case .message: return false
        }
    }

    // MARK: - Public Methods — Export

    /// Whether this tab has a comparison worth sending — what the tab's own menu asks before it
    /// offers the command.
    var canExportComparison: Bool {
        lastComparison.map(canExport) ?? false
    }

    /// Asks where to write the comparison, then writes it.
    ///
    /// Everything after the panel closes happens off the main thread: base64 of two 64 MB images
    /// and a deflate pass are not work to do between two frames, and the sheet is already gone by
    /// then — there is nothing on screen waiting for it but the file appearing.
    func exportComparison() {
        guard let comparison = lastComparison, canExport(comparison) else {
            SystemAlert.refuse()
            return
        }
        let export = Self.makeExport(
            comparison,
            oldPath: oldPath,
            newPath: newPath,
            oldTitle: oldTitle,
            newTitle: newTitle,
            mode: compareMode
        )
        guard let export else {
            SystemAlert.refuse()
            return
        }

        exportSession = CompareExportPanel.present(
            suggestedName: export.suggestedFileName,
            from: view
        ) { [weak self] url, format in
            self?.exportSession = nil
            Self.queue.async {
                let outcome = Result {
                    try CompareExportPackager.data(for: export, format: format).write(
                        to: url, options: .atomic
                    )
                }
                guard case .failure(let error) = outcome else { return }
                Task { @MainActor in
                    let alert = ThemedAlert(error: error)
                    alert.messageText = L10n.string("Could Not Export Comparison")
                    alert.runModal()
                }
            }
        }
    }

    /// Freezes what is on screen into the value the packager works from.
    ///
    /// `nonisolated` and static because none of it is the view's: it reads the bytes the
    /// comparison already produced, asks ImageIO what they are, and hands back a `Sendable`
    /// value — which is what lets the packaging run off the main actor without the controller
    /// following it there.
    nonisolated static func makeExport(
        _ comparison: Comparison,
        oldPath: String,
        newPath: String,
        oldTitle: String,
        newTitle: String,
        mode: ImageCompareMode,
        at date: Date = Date()
    ) -> CompareExport? {
        let body: CompareExport.Body
        switch comparison {
        case .message:
            return nil
        case .images(let old, let new):
            let oldSide = old.flatMap {
                imageSide($0, title: oldTitle, path: oldPath)
            }
            let newSide = new.flatMap {
                imageSide($0, title: newTitle, path: newPath)
            }
            guard oldSide != nil || newSide != nil else { return nil }
            body = .images(old: oldSide, new: newSide)
        case .text(let files):
            guard !files.isEmpty else { return nil }
            body = .text(
                files: files,
                old: textSide(title: oldTitle, path: oldPath),
                new: textSide(title: newTitle, path: newPath)
            )
        }
        return CompareExport(
            oldTitle: oldTitle,
            newTitle: newTitle,
            mode: mode,
            body: body,
            exportedAt: date
        )
    }

    nonisolated private static func imageSide(
        _ data: Data,
        title: String,
        path: String
    ) -> CompareExport.ImageSide? {
        let name = (path as NSString).lastPathComponent
        guard let readable = CompareExportImageType.webReadable(data, fileName: name),
              let pixelSize = CompareExportImageType.pixelSize(of: readable.data)
        else { return nil }
        return CompareExport.ImageSide(
            title: title,
            fileName: readable.fileName,
            data: readable.data,
            pixelSize: pixelSize,
            mediaType: readable.mediaType
        )
    }

    /// The source file itself, for the archive. A side that has since been deleted is simply
    /// absent — the diff beside it is still the comparison that was made.
    nonisolated private static func textSide(title: String, path: String) -> CompareExport.TextSide? {
        guard let data = try? BoundedFileReader.read(
            URL(fileURLWithPath: path),
            maximumBytes: CompareDefaults.maximumBytes
        ) else { return nil }
        return CompareExport.TextSide(
            title: title,
            fileName: (path as NSString).lastPathComponent,
            data: data
        )
    }
}

// MARK: - Classification

enum CompareDefaults {
    /// The most a comparison reads per side. Matches the display panel's image cap: the
    /// comparison should not refuse what `display_image` accepts.
    static var maximumBytes: Int { MCPDefaults.maximumImageBytes }
}

/// Decides what a file is from its bytes — git's own NUL heuristic for binary, an actual
/// decode for image — rather than trusting an extension.
enum CompareFileClassifier {

    enum Kind: Equatable {
        case missing
        case tooLarge
        case text
        case image
        case binary
    }

    static func classify(path: String) -> Kind {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true else {
            return .missing
        }
        guard (values.fileSize ?? 0) <= CompareDefaults.maximumBytes else {
            return .tooLarge
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .missing }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: GitReviewDefaults.binarySniffBytes)) ?? Data()

        guard head.contains(0) else { return .text }
        // Binary. An image is one CGImageSource recognises — decoding the first frame's
        // properties, not trusting the file name.
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            return .binary
        }
        return .image
    }
}
