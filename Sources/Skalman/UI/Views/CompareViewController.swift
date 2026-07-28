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

    /// Feeds the tab's loading affordance, same contract as Review's.
    var onLoadingChange: ((Bool) -> Void)?

    private var scrollView: ThemedScrollView!
    private var stack: NSStackView!
    private var placeholderLabel: NSTextField!
    private var compareView: ImageCompareView?

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

    private static let queue = DispatchQueue(label: "com.skalman.compare", qos: .userInitiated)

    /// What the two files turned out to be.
    enum Comparison {
        case images(old: NSImage?, new: NSImage?)
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

    // MARK: - Lifecycle

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.small
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(
            top: Design.Spacing.inset,
            left: Design.Spacing.inset,
            bottom: Design.Spacing.inset,
            right: Design.Spacing.inset
        )

        let clipView = FlippedClipView()
        clipView.drawsBackground = false

        scrollView = ThemedScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentView = clipView
        scrollView.documentView = stack
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        placeholderLabel = NSTextField(labelWithString: "")
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.applyFont(.body)
        placeholderLabel.textColor = Design.Text.tertiary
        placeholderLabel.alignment = .center
        placeholderLabel.lineBreakMode = .byWordWrapping
        placeholderLabel.maximumNumberOfLines = 0
        placeholderLabel.isHidden = true

        view.addSubview(scrollView)
        view.addSubview(placeholderLabel)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
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
        Self.queue.async { [weak self] in
            let comparison = Self.compare(oldPath: oldPath, newPath: newPath)
            DispatchQueue.main.async {
                guard let self, expected == self.generation else { return }
                self.isLoading = false
                self.render(comparison)
            }
        }
    }

    /// Classifies and reads the pair. On the comparison queue; everything returned is value
    /// data plus images, which are safe to build off the main thread.
    static func compare(oldPath: String, newPath: String) -> Comparison {
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
                old: NSImage(contentsOf: URL(fileURLWithPath: oldPath)),
                new: NSImage(contentsOf: URL(fileURLWithPath: newPath))
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
                L10n.string("These files are binary, and not images Skalman can compare.")
            )
        }
    }

    private static func textComparison(oldPath: String, newPath: String) -> Comparison {
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
        placeholderLabel.isHidden = true
        scrollView.isHidden = false

        switch comparison {
        case .message(let text):
            scrollView.isHidden = true
            placeholderLabel.isHidden = false
            placeholderLabel.stringValue = text

        case .images(let old, let new):
            guard old != nil || new != nil else {
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
                old: old.map { .init(image: $0, title: oldTitle) },
                new: new.map { .init(image: $0, title: newTitle) }
            )
            compare.onModeChange = { [weak self] mode in
                self?.compareMode = mode
                self?.onChange?()
            }
            compareView = compare
            stack.addArrangedSubview(compare)
            NSLayoutConstraint.activate([
                compare.leadingAnchor.constraint(
                    equalTo: stack.leadingAnchor, constant: Design.Spacing.inset
                ),
                compare.trailingAnchor.constraint(
                    equalTo: stack.trailingAnchor, constant: -Design.Spacing.inset
                ),
                // The scroll pane gives height no floor, so the canvas states its own: the
                // fitted height at the pane's width, capped like a review row.
                compare.heightAnchor.constraint(
                    equalToConstant: compare.preferredHeight(
                        forWidth: max(view.bounds.width - Design.Spacing.inset * 2, 200)
                    )
                )
            ])

        case .text(let files):
            addTextHeader()
            for file in files {
                for hunk in file.hunks {
                    let diff = DiffView(
                        gitLines: hunk.lines,
                        displayCap: DiffDefaults.displayCap,
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
                }
            }
        }
    }

    /// One caption naming the two sides, so the text diff says what it compares the way the
    /// image surface's tags do.
    private func addTextHeader() {
        let label = NSTextField(labelWithString: "\(oldTitle) → \(newTitle)")
        label.applyFont(.caption)
        label.textColor = Design.Text.secondary
        label.lineBreakMode = .byTruncatingMiddle
        stack.addArrangedSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(
                equalTo: stack.leadingAnchor, constant: Design.Spacing.inset
            ),
            label.trailingAnchor.constraint(
                lessThanOrEqualTo: stack.trailingAnchor, constant: -Design.Spacing.inset
            )
        ])
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
