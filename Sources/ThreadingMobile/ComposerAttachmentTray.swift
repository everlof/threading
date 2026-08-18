import Foundation
import ThreadingRemoteKit
import UIKit
import UniformTypeIdentifiers

// MARK: - Item

/// One file staged beside the draft, and how far it has got.
struct ComposerAttachmentItem: Identifiable, Equatable {

    /// Where the transfer is. The composer reads this rather than a boolean because "attached"
    /// and "on the Mac" are different states, and pressing send between them would lose the file.
    enum State: Equatable {
        case uploading(fraction: Double)
        /// The Mac has the whole file and minted this id. Only these may be named by a prompt.
        case ready(uploadID: String)
        case failed
    }

    /// Device-local, and deliberately not the upload id: an item exists in the strip before the
    /// Mac has agreed to anything, and has to be removable during that time.
    let id: UUID
    let name: String
    /// Drawn in the strip. Nil for a document, which gets its type's glyph instead — rendering a
    /// PDF's first page here would decode a whole document to fill a 52-point square.
    let thumbnail: UIImage?
    let systemImage: String
    var state: State = .uploading(fraction: 0)

    init(id: UUID = UUID(), name: String, thumbnail: UIImage?, systemImage: String) {
        self.id = id
        self.name = name
        self.thumbnail = thumbnail
        self.systemImage = systemImage
    }

    var uploadID: String? {
        if case .ready(let id) = state { return id }
        return nil
    }

    var isSettled: Bool {
        if case .uploading = state { return false }
        return true
    }
}

// MARK: - Tray

/// The files staged beside one session's draft, and the uploads carrying them to the Mac.
///
/// Uploading starts when the file is picked, not when send is pressed. That is the whole reason
/// this is a separate object: a phone photo takes a moment to travel, and doing it at send time
/// would put that wait between the person and their message every single time. Started at pick
/// time, the transfer is usually finished before anyone stops typing.
///
/// Nothing here reaches a session. A staged upload sits on the Mac until a prompt names it or
/// the Mac reaps it, so abandoning a draft — or the app being killed mid-transfer — leaves no
/// half-attached file in somebody's conversation.
///
/// Plain observation rather than `ObservableObject`, because the composer that owns it is a
/// `UIViewController`: `onChange` fires on the main actor after any mutation, and the strip
/// rebuilds from `items`. That rebuild is wholesale on purpose — the list is capped at
/// `RemoteAttachmentUploadLimits.maximumPerMessage`, a small fixed bound, which is exactly the
/// case the scaling rules leave to a retained stack.
@MainActor
final class ComposerAttachmentTray {

    // MARK: - Properties

    private(set) var items: [ComposerAttachmentItem] = [] {
        didSet { onChange?() }
    }

    /// The most recent refusal, for the composer to show and clear. Kept apart from the items'
    /// own `.failed` state: a file that could not even be read never became an item.
    private(set) var notice: String? {
        didSet { onChange?() }
    }

    var onChange: (() -> Void)?

    /// Ids to name in the next prompt, in the order they were attached.
    var readyUploadIDs: [String] { items.compactMap(\.uploadID) }
    /// Whether send should wait. A draft with a picture still in flight is not ready to go.
    var isSettling: Bool { items.contains { !$0.isSettled } }
    var isEmpty: Bool { items.isEmpty }
    var canAcceptMore: Bool { items.count < RemoteAttachmentUploadLimits.maximumPerMessage }

    private let client: RemoteClient
    private let sessionID: String
    private var uploads: [UUID: Task<Void, Never>] = [:]

    // MARK: - Initialization

    init(client: RemoteClient, sessionID: String) {
        self.client = client
        self.sessionID = sessionID
    }

    deinit {
        uploads.values.forEach { $0.cancel() }
    }

    // MARK: - Public Methods

    /// Stages one file's bytes and starts carrying them over.
    ///
    /// The caller has already read the file, because the two sources differ in how: a photo comes
    /// out of the picker as transferable data, a document from behind a security-scoped URL. Both
    /// arrive here as bytes and a type, which is all the upload cares about.
    func add(data: Data, name: String, type: UTType) {
        guard canAcceptMore else {
            notice = MobileL10n.string("That is as many files as one message can carry.")
            return
        }
        guard let prepared = ComposerAttachmentPayload.prepared(
            data: data,
            name: name,
            type: type
        ) else {
            notice = MobileL10n.string("Threading can’t send that file.")
            return
        }

        let item = ComposerAttachmentItem(
            name: prepared.name,
            thumbnail: prepared.thumbnail,
            systemImage: prepared.systemImage
        )
        notice = nil
        items.append(item)
        upload(prepared, for: item.id)
    }

    /// Removes one staged file. A transfer still running is cancelled rather than waited on: the
    /// Mac reaps whatever arrived, so there is nothing on its side to undo.
    func remove(_ id: UUID) {
        uploads.removeValue(forKey: id)?.cancel()
        items.removeAll { $0.id == id }
    }

    /// Clears the strip once a prompt carrying these has been accepted.
    func clear() {
        uploads.values.forEach { $0.cancel() }
        uploads.removeAll()
        items.removeAll()
        notice = nil
    }

    func clearNotice() {
        notice = nil
    }

    /// A file the picker offered and the app could not read. It never became an item, so it has
    /// no chip to carry a failed state — the notice is the only place it can be said.
    func reportUnreadableFile() {
        notice = MobileL10n.string("That file couldn’t be read.")
    }

    // MARK: - Private Methods

    private func upload(_ payload: ComposerAttachmentPayload, for id: UUID) {
        uploads[id] = Task { [weak self] in
            guard let self else { return }
            do {
                let uploadID = try await client.uploadAttachment(
                    sessionID: sessionID,
                    name: payload.name,
                    mediaType: payload.type.identifier,
                    data: payload.data,
                    onProgress: { [weak self] fraction in
                        Task { @MainActor in
                            self?.update(id, to: .uploading(fraction: fraction))
                        }
                    }
                )
                guard !Task.isCancelled else { return }
                update(id, to: .ready(uploadID: uploadID))
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                update(id, to: .failed)
                notice = MobileL10n.string("%@ couldn’t be sent to your Mac.", payload.name)
            }
            uploads.removeValue(forKey: id)
        }
    }

    private func update(_ id: UUID, to state: ComposerAttachmentItem.State) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        // A settled item is never walked backwards by a progress callback that arrived late.
        if items[index].isSettled, case .uploading = state { return }
        items[index].state = state
    }
}

// MARK: - Payload

/// A file reduced to what the wire takes: bytes, a name, a type, and something to draw.
struct ComposerAttachmentPayload {
    let data: Data
    let name: String
    let type: UTType
    let thumbnail: UIImage?
    let systemImage: String

    /// Prepares one picked file, re-encoding a photo that is larger than an agent can use.
    ///
    /// A phone camera produces something like 4000 points on its long edge and several megabytes
    /// of HEIC. Nothing downstream benefits: what an agent is being shown is a screenshot, a
    /// whiteboard, a photo of a screen. Re-encoding to a bounded JPEG turns a transfer measured in
    /// tens of seconds on a hotel connection into one that finishes while the person is still
    /// typing — and it is why a single request is the normal case rather than the lucky one.
    ///
    /// A file already inside the bound goes over untouched, so a screenshot keeps its exact
    /// pixels and a PNG stays a PNG. Only an oversized photo is ever re-encoded, and only when
    /// the re-encode actually comes out smaller.
    static func prepared(data: Data, name: String, type: UTType) -> ComposerAttachmentPayload? {
        guard !data.isEmpty,
              data.count <= RemoteAttachmentUploadLimits.maximumBytesPerFile else { return nil }

        if type.conforms(to: .image), let image = UIImage(data: data) {
            return imagePayload(data: data, name: name, type: type, image: image)
        }

        // The host re-derives the extension it will write from this type and then refuses
        // anything its attachments pane could not show. Asking the same question here means a
        // refusal is immediate and says something, instead of arriving as a failed transfer.
        guard type.preferredFilenameExtension != nil else { return nil }
        return ComposerAttachmentPayload(
            data: data,
            name: name,
            type: type,
            thumbnail: nil,
            systemImage: glyph(for: type)
        )
    }

    private static func imagePayload(
        data: Data,
        name: String,
        type: UTType,
        image: UIImage
    ) -> ComposerAttachmentPayload {
        let limit = RemoteAttachmentUploadClientDefaults.downscaledMaximumDimension
        let isOversized = max(image.size.width, image.size.height) > limit
            || data.count > RemoteAttachmentUploadClientDefaults.chunkBytes

        if isOversized,
           let reduced = image.scaled(toLongestEdge: limit),
           let jpeg = reduced.jpegData(
               compressionQuality: RemoteAttachmentUploadClientDefaults.downscaledCompressionQuality
           ), jpeg.count < data.count {
            return ComposerAttachmentPayload(
                data: jpeg,
                name: (name as NSString).deletingPathExtension + ".jpg",
                type: .jpeg,
                thumbnail: reduced,
                systemImage: "photo"
            )
        }

        return ComposerAttachmentPayload(
            data: data,
            name: name,
            type: type,
            thumbnail: image,
            systemImage: "photo"
        )
    }

    private static func glyph(for type: UTType) -> String {
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .html) { return "chevron.left.forwardslash.chevron.right" }
        return "doc"
    }
}

private extension UIImage {
    /// Aspect-preserving reduction at scale 1, so the pixel size is the size asked for rather
    /// than that multiplied by the device's scale factor — which on a 3× phone would have made
    /// every "downscaled" photo three times the intended edge.
    func scaled(toLongestEdge limit: CGFloat) -> UIImage? {
        let longest = max(size.width, size.height)
        guard longest > 0 else { return nil }
        let factor = min(1, limit / longest)
        let target = CGSize(width: size.width * factor, height: size.height * factor)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

// MARK: - Strip

/// The row of staged files above the draft box.
///
/// Horizontal and scrolling rather than wrapping: the composer is already the tallest thing on
/// screen once the keyboard is up, and a second row of thumbnails would push the conversation out
/// of sight. One picture is the common case and costs one row either way.
@MainActor
final class ComposerAttachmentStripView: UIView {

    // MARK: - Properties

    /// Removing is the only thing a chip does, so the strip needs one callback and no delegate.
    var onRemove: ((UUID) -> Void)?

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private var theme: RemoteThemePalette?
    private var renderedItems: [ComposerAttachmentItem] = []

    // MARK: - Initialization

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public Methods

    /// Rebuilds the strip for `items`.
    ///
    /// Wholesale, and bounded by `maximumPerMessage`: at most eight chips exist, so diffing them
    /// would be more machinery than the work it saves. The early return keeps a progress tick —
    /// which arrives many times per file — from rebuilding anything when nothing visible moved.
    func update(items: [ComposerAttachmentItem], theme: RemoteThemePalette) {
        guard self.theme != theme || items != renderedItems else { return }
        self.theme = theme
        renderedItems = items

        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for item in items {
            let chip = ComposerAttachmentChipView(item: item, theme: theme)
            chip.onRemove = { [weak self] in self?.onRemove?(item.id) }
            stack.addArrangedSubview(chip)
        }
        isHidden = items.isEmpty
    }

    // MARK: - Private Methods

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = MobileDesign.Spacing.small

        addSubview(scrollView)
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
            heightAnchor.constraint(equalToConstant: ComposerAttachmentMetrics.stripHeight),
        ])
    }
}

// MARK: - Chip

@MainActor
private final class ComposerAttachmentChipView: UIView {

    var onRemove: (() -> Void)?

    private let plate = UIView()
    /// The stroke is its own drawn view rather than `layer.borderColor`: a `CGColor` on a layer
    /// is frozen at assignment and stops following the theme, which is the rule the mobile
    /// boundary lint enforces.
    private let outline = MobileThemeOutlineView()
    private let imageView = UIImageView()
    private let glyphView = UIImageView()
    private let progressTrack = UIView()
    private let progressFill = UIView()
    private let removeButton = UIButton(type: .system)
    private var progressWidth: NSLayoutConstraint!

    init(item: ComposerAttachmentItem, theme: RemoteThemePalette) {
        super.init(frame: .zero)
        setup(theme: theme)
        apply(item, theme: theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup(theme: RemoteThemePalette) {
        translatesAutoresizingMaskIntoConstraints = false

        plate.translatesAutoresizingMaskIntoConstraints = false
        plate.backgroundColor = theme.uiControlResting
        plate.layer.cornerRadius = theme.controlRadius
        plate.layer.cornerCurve = .continuous
        plate.clipsToBounds = true
        addSubview(plate)

        outline.translatesAutoresizingMaskIntoConstraints = false
        outline.isUserInteractionEnabled = false
        addSubview(outline)

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        plate.addSubview(imageView)

        glyphView.translatesAutoresizingMaskIntoConstraints = false
        glyphView.contentMode = .center
        glyphView.tintColor = theme.uiSecondaryLabel
        plate.addSubview(glyphView)

        // A hairline the width of what has arrived, rather than a spinner over the picture: the
        // point of showing a thumbnail is recognising which file this is, and a spinner in front
        // of it takes that away for the whole transfer.
        progressTrack.translatesAutoresizingMaskIntoConstraints = false
        progressTrack.backgroundColor = .clear
        plate.addSubview(progressTrack)
        progressFill.translatesAutoresizingMaskIntoConstraints = false
        progressTrack.addSubview(progressFill)

        removeButton.translatesAutoresizingMaskIntoConstraints = false
        removeButton.setImage(
            UIImage(systemName: "xmark.circle.fill"),
            for: .normal
        )
        removeButton.tintColor = theme.uiLabel
        removeButton.addAction(
            UIAction { [weak self] _ in self?.onRemove?() },
            for: .touchUpInside
        )
        addSubview(removeButton)

        progressWidth = progressFill.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            plate.leadingAnchor.constraint(equalTo: leadingAnchor),
            plate.bottomAnchor.constraint(equalTo: bottomAnchor),
            plate.widthAnchor.constraint(equalToConstant: ComposerAttachmentMetrics.thumbnail),
            plate.heightAnchor.constraint(equalToConstant: ComposerAttachmentMetrics.thumbnail),

            outline.leadingAnchor.constraint(equalTo: plate.leadingAnchor),
            outline.trailingAnchor.constraint(equalTo: plate.trailingAnchor),
            outline.topAnchor.constraint(equalTo: plate.topAnchor),
            outline.bottomAnchor.constraint(equalTo: plate.bottomAnchor),

            imageView.leadingAnchor.constraint(equalTo: plate.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: plate.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: plate.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: plate.bottomAnchor),
            glyphView.centerXAnchor.constraint(equalTo: plate.centerXAnchor),
            glyphView.centerYAnchor.constraint(equalTo: plate.centerYAnchor),

            progressTrack.leadingAnchor.constraint(equalTo: plate.leadingAnchor),
            progressTrack.trailingAnchor.constraint(equalTo: plate.trailingAnchor),
            progressTrack.bottomAnchor.constraint(equalTo: plate.bottomAnchor),
            progressTrack.heightAnchor.constraint(
                equalToConstant: ComposerAttachmentMetrics.progressHeight
            ),
            progressFill.leadingAnchor.constraint(equalTo: progressTrack.leadingAnchor),
            progressFill.topAnchor.constraint(equalTo: progressTrack.topAnchor),
            progressFill.bottomAnchor.constraint(equalTo: progressTrack.bottomAnchor),
            progressWidth,

            // The glyph is small; the target it answers to is not. It hangs past the plate's
            // corner so it never covers the picture it belongs to.
            removeButton.centerXAnchor.constraint(equalTo: plate.trailingAnchor),
            removeButton.centerYAnchor.constraint(equalTo: plate.topAnchor),
            removeButton.widthAnchor.constraint(
                equalToConstant: ComposerAttachmentMetrics.removeTarget
            ),
            removeButton.heightAnchor.constraint(
                equalToConstant: ComposerAttachmentMetrics.removeTarget
            ),
            trailingAnchor.constraint(equalTo: removeButton.trailingAnchor),
            topAnchor.constraint(equalTo: removeButton.topAnchor),
        ])
    }

    private func apply(_ item: ComposerAttachmentItem, theme: RemoteThemePalette) {
        imageView.image = item.thumbnail
        imageView.isHidden = item.thumbnail == nil
        glyphView.isHidden = item.thumbnail != nil
        glyphView.image = UIImage(
            systemName: item.systemImage,
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: ComposerAttachmentMetrics.documentGlyph
            )
        )

        let strokeColor: UIColor
        switch item.state {
        case .uploading(let fraction):
            strokeColor = theme.uiBorder
            progressFill.backgroundColor = theme.uiAccent
            progressWidth.constant = ComposerAttachmentMetrics.thumbnail
                * CGFloat(max(0.02, min(1, fraction)))
        case .ready:
            strokeColor = theme.uiBorder
            progressWidth.constant = 0
        case .failed:
            // A refused file says so on the chip itself. The composer's notice line carries the
            // sentence; the outline is what lets someone find which of eight it is about.
            strokeColor = theme.uiNegative
            progressFill.backgroundColor = theme.uiNegative
            progressWidth.constant = ComposerAttachmentMetrics.thumbnail
        }
        outline.update(
            color: strokeColor,
            radius: theme.controlRadius,
            width: theme.borderWidth,
            glow: nil
        )

        isAccessibilityElement = true
        accessibilityLabel = Self.accessibilityLabel(for: item)
        removeButton.accessibilityLabel = MobileL10n.string("Remove %@", item.name)
    }

    private static func accessibilityLabel(for item: ComposerAttachmentItem) -> String {
        switch item.state {
        case .uploading:
            return MobileL10n.string("%@, sending", item.name)
        case .ready:
            return MobileL10n.string("%@, attached", item.name)
        case .failed:
            return MobileL10n.string("%@, couldn’t be sent", item.name)
        }
    }
}

// MARK: - Constants

enum ComposerAttachmentMetrics {
    static let thumbnail: CGFloat = 52
    /// The plate plus the half of the remove target that hangs above it.
    static let stripHeight: CGFloat = 66
    static let progressHeight: CGFloat = 3
    static let documentGlyph: CGFloat = 20
    static let removeTarget: CGFloat = 28
}
