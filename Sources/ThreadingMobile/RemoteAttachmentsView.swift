import AVFoundation
import AVKit
import PDFKit
import ThreadingRemoteKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit

/// Durable artifacts from the selected session, fetched on demand from the paired Mac.
struct RemoteAttachmentsView: View {
    let session: RemoteSessionSummaryDTO
    let client: RemoteClient
    var showsCloseButton = true

    @Environment(\.dismiss) private var dismiss
    @Environment(\.remoteTheme) private var theme
    @State private var attachments: [RemoteAttachmentDTO]?
    @State private var errorMessage: String?
    @State private var isLoading = false
    private let loadsRemotely: Bool
    /// Whether the paired Mac draws thumbnails (`RemoteRESTFeature.attachmentThumbnails`);
    /// the gallery's ledger asks for none otherwise.
    private let offersThumbnails: Bool
    /// Whether the paired Mac serves bounded authenticated byte ranges for movies.
    private let offersVideoStreaming: Bool

    init(
        session: RemoteSessionSummaryDTO,
        client: RemoteClient,
        showsCloseButton: Bool = true,
        offersThumbnails: Bool = false,
        offersVideoStreaming: Bool = false,
        initialAttachments: [RemoteAttachmentDTO]? = nil,
        loadsRemotely: Bool = true
    ) {
        self.session = session
        self.client = client
        self.showsCloseButton = showsCloseButton
        self.offersThumbnails = offersThumbnails
        self.offersVideoStreaming = offersVideoStreaming
        self.loadsRemotely = loadsRemotely
        _attachments = State(initialValue: initialAttachments)
    }

    var body: some View {
        Group {
            if isLoading, attachments == nil {
                MobileLoadingPlaceholder(MobileL10n.string("Finding attachments…"))
            } else if let errorMessage, attachments == nil {
                ContentUnavailableView {
                    Label("Couldn’t load attachments", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again") {
                        Task { await load() }
                    }
                }
            } else if attachments?.isEmpty != false {
                ContentUnavailableView {
                    Label("No attachments yet", systemImage: "paperclip")
                } description: {
                    Text("Images, documents, and HTML from this session will appear here.")
                }
            } else {
                List(attachments ?? []) { attachment in
                    // A row opens the gallery at itself: the rest of the list is a swipe away
                    // and in the ledger underneath, the way the Mac's inspector keeps a file's
                    // neighbours in its rail.
                    NavigationLink {
                        RemoteAttachmentGallery(
                            sessionID: session.id,
                            attachments: attachments ?? [],
                            initialID: attachment.id,
                            client: client,
                            offersThumbnails: offersThumbnails,
                            offersVideoStreaming: offersVideoStreaming
                        )
                    } label: {
                        RemoteAttachmentRow(attachment: attachment)
                    }
                    .themedSettingsRow(theme)
                }
                .listStyle(.plain)
                .themedSettingsPage(theme)
                .refreshable { await load() }
            }
        }
        .navigationTitle("Attachments")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(theme.surface, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            if showsCloseButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(MobileL10n.string("Close attachments"))
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
                .accessibilityLabel(MobileL10n.string("Refresh attachments"))
            }
        }
        .background(theme.ground)
        .task { await load() }
    }

    @MainActor
    private func load() async {
        guard loadsRemotely else { return }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            attachments = try await client.attachments(sessionID: session.id).attachments
            errorMessage = nil
        } catch {
            MobileDiagnostics.logDegraded(.attachmentList, error: error)
            errorMessage = error.localizedDescription
        }
    }
}

private struct RemoteAttachmentRow: View {
    let attachment: RemoteAttachmentDTO

    @Environment(\.remoteTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.title3)
                .foregroundStyle(theme.secondaryLabel)
                .frame(width: 30, height: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(attachment.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(theme.label)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(theme.tertiaryLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(minHeight: 52)
        .accessibilityElement(children: .combine)
    }

    /// Provenance leads when the host sent it: on a phone the list is the whole pane, and which
    /// side a file came from is the thing the path is least likely to say.
    private var detail: String {
        [originLabel, attachment.path, formattedSize]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// A host from before provenance existed sends nothing, and a guess would be worse than the
    /// row the phone has always shown.
    private var originLabel: String? {
        switch attachment.origin {
        case .user: return "You"
        case .agent: return "Agent"
        default: return nil
        }
    }

    private var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: attachment.byteCount, countStyle: .file)
    }

    private var iconName: String {
        RemoteAttachmentGlyph.name(for: attachment.kind)
    }
}

/// Resolves a notification's opaque attachment identity, then hands the normal attachment
/// preview the result. The route never carries a host path or URL.
struct RemoteAttachmentTargetView: View {
    let session: RemoteSessionSummaryDTO
    let attachmentID: String
    let client: RemoteClient
    var offersThumbnails = false
    var offersVideoStreaming = false

    @Environment(\.remoteTheme) private var theme
    @State private var attachment: RemoteAttachmentDTO?
    @State private var attachments: [RemoteAttachmentDTO] = []
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let attachment {
                // The notification named one attachment; the listing that resolved it is the
                // gallery's set, so the neighbours are a swipe away here as well.
                RemoteAttachmentGallery(
                    sessionID: session.id,
                    attachments: attachments.isEmpty ? [attachment] : attachments,
                    initialID: attachment.id,
                    client: client,
                    offersThumbnails: offersThumbnails,
                    offersVideoStreaming: offersVideoStreaming
                )
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Attachment unavailable", systemImage: "paperclip.badge.ellipsis")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again") {
                        self.errorMessage = nil
                        Task { await load() }
                    }
                }
            } else {
                MobileLoadingPlaceholder(MobileL10n.string("Opening attachment…"))
            }
        }
        .background(theme.ground)
        .task { await load() }
    }

    @MainActor
    private func load() async {
        do {
            let attachments = try await client.attachments(sessionID: session.id).attachments
            guard let matched = attachments.first(where: { $0.id == attachmentID }) else {
                attachment = nil
                errorMessage = MobileL10n.string(
                    "This captured attachment is no longer available on the Mac."
                )
                return
            }
            self.attachments = attachments
            attachment = matched
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            MobileDiagnostics.logDegraded(.attachmentMetadata, error: error)
            attachment = nil
            errorMessage = error.localizedDescription
        }
    }
}

/// One attachment under its own title — the shape a single preview takes when nothing else is
/// beside it. The gallery draws the same content as pages and owns the title itself.
struct RemoteAttachmentPreview: View {
    let sessionID: String
    let attachment: RemoteAttachmentDTO
    let client: RemoteClient
    private let initialData: Data?
    private let loadsRemotely: Bool
    private let offersVideoStreaming: Bool
    @Environment(\.remoteTheme) private var theme

    init(
        sessionID: String,
        attachment: RemoteAttachmentDTO,
        client: RemoteClient,
        initialData: Data? = nil,
        loadsRemotely: Bool = true,
        offersVideoStreaming: Bool = false
    ) {
        self.sessionID = sessionID
        self.attachment = attachment
        self.client = client
        self.initialData = initialData
        self.loadsRemotely = loadsRemotely
        self.offersVideoStreaming = offersVideoStreaming
    }

    var body: some View {
        RemoteAttachmentPreviewContent(
            sessionID: sessionID,
            attachment: attachment,
            client: client,
            initialData: initialData,
            loadsRemotely: loadsRemotely,
            offersVideoStreaming: offersVideoStreaming
        )
        .navigationTitle(attachment.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(theme.surface, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }
}

/// The preview itself, with no claim on the navigation bar.
struct RemoteAttachmentPreviewContent: View {
    let sessionID: String
    let attachment: RemoteAttachmentDTO
    let client: RemoteClient

    @Environment(\.remoteTheme) private var theme
    @State private var data: Data?
    @State private var errorMessage: String?
    @State private var didRecordUnavailablePreview = false
    @State private var loadGeneration = 0
    private let loadsRemotely: Bool
    private let offersVideoStreaming: Bool
    /// Whether this page is the one the gallery is showing. A page that becomes current asks
    /// again if it still holds nothing, which is what gives the attachment a person is actually
    /// looking at a live attempt after a swipe cancelled its first one.
    private let isCurrentPage: Bool
    /// Told the pixel size of a decoded image, for the gallery's detail line.
    private let onDecodedImageSize: ((CGSize) -> Void)?

    init(
        sessionID: String,
        attachment: RemoteAttachmentDTO,
        client: RemoteClient,
        initialData: Data? = nil,
        loadsRemotely: Bool = true,
        offersVideoStreaming: Bool = false,
        isCurrentPage: Bool = true,
        onDecodedImageSize: ((CGSize) -> Void)? = nil
    ) {
        self.sessionID = sessionID
        self.attachment = attachment
        self.client = client
        self.loadsRemotely = loadsRemotely
        self.offersVideoStreaming = offersVideoStreaming
        self.isCurrentPage = isCurrentPage
        self.onDecodedImageSize = onDecodedImageSize
        _data = State(initialValue: initialData)
    }

    var body: some View {
        Group {
            // Decided before any bytes move: the phone has no renderer for an archive, an
            // office document, or diagram source, and downloading one only to say "the image
            // could not be decoded" spends the attachment byte cap on a file it was never
            // going to show.
            if attachment.kind == .video {
                if offersVideoStreaming, isCurrentPage {
                    RemoteAttachmentVideoView(
                        sessionID: sessionID,
                        attachment: attachment,
                        client: client
                    )
                } else if offersVideoStreaming {
                    // Neighbour pages stay inert. AVPlayer probes as soon as it receives an item,
                    // so constructing players for pages beside the viewport would turn one movie
                    // the user chose into three active range streams.
                    unavailable("Swipe here to play this movie.")
                } else {
                    unavailable("This movie plays on your Mac.")
                }
            } else if attachment.kind == .media {
                // The renderer is host-owned, so the mirror is achievable — but a live player on
                // the phone needs a poster-frame or frame-stream endpoint the remote surface does
                // not have yet, and a silent blank card would be worse than a sentence.
                unavailable("This animation plays on your Mac.")
            } else if RemoteAttachmentPreviewLoad.excludesFromWholeFileLoad(attachment.kind) {
                unavailable("This file previews on your Mac.")
            } else if let data {
                if attachment.kind == .pdf {
                    RemotePDFView(data: data, backgroundColor: theme.uiColor(
                        "ground",
                        fallback: "#16181D"
                    ))
                } else if attachment.kind == .html {
                    RemoteHTMLView(
                        data: data,
                        backgroundColor: theme.uiColor("ground", fallback: "#16181D")
                    )
                } else if attachment.kind == .text {
                    ScrollView {
                        Text(String(decoding: data, as: UTF8.self))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(theme.label)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(MobileDesign.Spacing.large)
                    }
                } else if let image = UIImage(data: data) {
                    RemoteZoomableImageView(image: image, backgroundColor: theme.uiGround)
                } else {
                    unavailable("The image could not be decoded.")
                }
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Couldn’t open attachment", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again") {
                        Task { await load() }
                    }
                }
            } else {
                MobileLoadingPlaceholder(MobileL10n.string("Loading preview…"))
            }
        }
        .background(theme.ground)
        .task(id: isCurrentPage) { await load() }
    }

    private func reportImageSize(in data: Data) {
        guard let onDecodedImageSize, attachment.kind == .image,
              let image = UIImage(data: data) else { return }
        onDecodedImageSize(CGSize(
            width: image.size.width * image.scale,
            height: image.size.height * image.scale
        ))
    }

    @ViewBuilder
    private func unavailable(_ message: String) -> some View {
        ContentUnavailableView(
            "No preview",
            systemImage: unavailableIconName,
            description: Text(MobileL10n.string(message))
        )
    }

    private var unavailableIconName: String {
        RemoteAttachmentGlyph.name(for: attachment.kind)
    }

    @MainActor
    private func load() async {
        let decision = RemoteAttachmentPreviewLoad.decision(
            kind: attachment.kind,
            hasData: data != nil,
            loadsRemotely: loadsRemotely
        )
        switch decision {
        case .localFixture:
            if let data { reportImageSize(in: data) }
            return
        case .alreadyLoaded:
            return
        case .previewUnavailable:
            if !didRecordUnavailablePreview {
                MobileAttachmentPreviewLog.record(kind: attachment.kind, outcome: .skip)
                didRecordUnavailablePreview = true
            }
            return
        case .requestBytes:
            break
        }

        // Holding the bytes is the only state that ends the asking. `loadGeneration` does not
        // gate requests; it only stops an older overlapping completion from overwriting the
        // current attempt's UI after SwiftUI has already restarted the page task.
        loadGeneration += 1
        let generation = loadGeneration
        errorMessage = nil
        MobileAttachmentPreviewLog.record(kind: attachment.kind, outcome: .start)
        let client = self.client
        let sessionID = self.sessionID
        let attachmentID = attachment.id
        do {
            // Bounded alongside every other page the lazy scroller has materialised: a swipe
            // through a gallery is a queue of whole-file requests, not a burst of them.
            let fetched = try await MobileMediaDownloadLimiter.previews.run {
                try await client.attachmentData(sessionID: sessionID, id: attachmentID)
            }
            MobileAttachmentPreviewLog.record(kind: attachment.kind, outcome: .ok)
            guard generation == loadGeneration else { return }
            data = fetched
            errorMessage = nil
            reportImageSize(in: fetched)
        } catch {
            guard let message = RemoteAttachmentPreviewFailure.message(for: error) else {
                MobileAttachmentPreviewLog.record(kind: attachment.kind, outcome: .cancel)
                return
            }
            MobileAttachmentPreviewLog.record(kind: attachment.kind, outcome: .fail)
            MobileDiagnostics.record(.attachmentPreviewFailed, level: .warning, fields: [
                .kind: MobileAttachmentPreviewLog.kindToken(for: attachment.kind).rawValue,
                .code: MobileDiagnostics.errorCode(error),
                .detail: RemoteTransientTransportFailure.isTransient(error)
                    ? RemoteAttachmentThumbnailDefaults.transientDetail
                    : RemoteAttachmentThumbnailDefaults.terminalDetail,
                .transport: client.endpointKind.rawValue,
                .origin: MobileDiagnostics.originDigest(client.link.baseURL),
            ])
            MobileDiagnostics.logDegraded(.attachmentContent, error: error)
            guard generation == loadGeneration else { return }
            data = nil
            errorMessage = message
        }
    }
}

// MARK: - Movie playback

/// A movie player backed by the paired Mac's authenticated byte-range route.
///
/// The player is created only for the gallery page on screen. `AVPlayer` decides which bytes it
/// needs; `RemoteAttachmentVideoResourceLoader` turns each request into bounded authenticated
/// pieces and never owns the whole recording.
private struct RemoteAttachmentVideoView: View {
    @StateObject private var model: RemoteAttachmentVideoPlayerModel
    @Environment(\.remoteTheme) private var theme

    init(sessionID: String, attachment: RemoteAttachmentDTO, client: RemoteClient) {
        _model = StateObject(wrappedValue: RemoteAttachmentVideoPlayerModel(
            sessionID: sessionID,
            attachment: attachment,
            client: client
        ))
    }

    var body: some View {
        VideoPlayer(player: model.player)
            .background(theme.ground)
            .onDisappear { model.player.pause() }
            .accessibilityLabel(MobileL10n.string("Play %@", model.name))
    }
}

/// The full-screen Quick View opened from a draft attachment tile. It keeps the unsent file on
/// the phone: pictures use the staged pixels and movies use the tray's device-local AVAsset.
struct ComposerAttachmentQuickView: View {
    let item: ComposerAttachmentItem
    @Environment(\.dismiss) private var dismiss
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        NavigationStack {
            Group {
                if item.isMovie, let url = item.previewURL {
                    LocalAttachmentVideoView(url: url, name: item.name)
                } else if let image = item.thumbnail {
                    RemoteZoomableImageView(image: image, backgroundColor: theme.uiGround)
                } else {
                    ContentUnavailableView(
                        MobileL10n.string("Preview Unavailable"),
                        systemImage: item.systemImage
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.ground)
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(theme.surface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(MobileL10n.string("Close"))
                }
            }
        }
    }
}

private struct LocalAttachmentVideoView: View {
    let name: String
    @State private var player: AVPlayer

    init(url: URL, name: String) {
        self.name = name
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VideoPlayer(player: player)
            .onDisappear { player.pause() }
            .accessibilityLabel(MobileL10n.string("Play %@", name))
    }
}

@MainActor
private final class RemoteAttachmentVideoPlayerModel: ObservableObject {
    let player: AVPlayer
    let name: String
    private let resourceLoader: RemoteAttachmentVideoResourceLoader

    init(sessionID: String, attachment: RemoteAttachmentDTO, client: RemoteClient) {
        name = attachment.name
        let loader = RemoteAttachmentVideoResourceLoader(
            sessionID: sessionID,
            attachment: attachment,
            client: client
        )
        resourceLoader = loader
        player = AVPlayer(playerItem: AVPlayerItem(asset: loader.asset()))
        player.actionAtItemEnd = .pause
    }

    deinit {
        player.pause()
        resourceLoader.cancelAll()
    }
}

/// Bridges AVFoundation's custom-scheme requests to the ordinary authenticated `RemoteClient`.
/// A custom scheme is intentional: giving AVPlayer the HTTP URL directly would require putting
/// the bearer in a URL or relying on private header options. Here every range travels through the
/// same pinning delegate, protocol headers, device identity, and authorization path as REST.
private final class RemoteAttachmentVideoResourceLoader: NSObject,
    AVAssetResourceLoaderDelegate,
    @unchecked Sendable
{
    private final class TaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<Void, Never>?
        private var isCancelled = false

        func install(_ task: Task<Void, Never>) {
            lock.lock()
            self.task = task
            let shouldCancel = isCancelled
            lock.unlock()
            if shouldCancel { task.cancel() }
        }

        func cancel() {
            lock.lock()
            isCancelled = true
            let task = task
            lock.unlock()
            task?.cancel()
        }
    }

    private static let errorDomain = "RemoteAttachmentVideo"
    private let sessionID: String
    private let attachment: RemoteAttachmentDTO
    private let client: RemoteClient
    private let delegateQueue = DispatchQueue(label: "codes.threading.remote-video-loader")
    private let lock = NSLock()
    private var tasks: [ObjectIdentifier: TaskBox] = [:]

    init(sessionID: String, attachment: RemoteAttachmentDTO, client: RemoteClient) {
        self.sessionID = sessionID
        self.attachment = attachment
        self.client = client
    }

    func asset() -> AVURLAsset {
        let ext = URL(fileURLWithPath: attachment.name).pathExtension
        let suffix = ext.isEmpty ? "mp4" : ext
        let url = URL(string: "threading-attachment://movie/\(UUID().uuidString).\(suffix)")!
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(self, queue: delegateQueue)
        return asset
    }

    func cancelAll() {
        lock.lock()
        let values = Array(tasks.values)
        tasks.removeAll()
        lock.unlock()
        values.forEach { $0.cancel() }
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        let identifier = ObjectIdentifier(loadingRequest)
        let box = TaskBox()
        lock.lock()
        tasks[identifier] = box
        lock.unlock()

        let task = Task { [weak self, weak loadingRequest] in
            guard let self, let loadingRequest else { return }
            do {
                try await fill(loadingRequest)
                if !loadingRequest.isCancelled { loadingRequest.finishLoading() }
            } catch is CancellationError {
                // AVFoundation already owns cancellation; finishing a cancelled request is a
                // second terminal event and produces spurious player failures.
            } catch {
                if !loadingRequest.isCancelled {
                    loadingRequest.finishLoading(with: error)
                }
            }
            removeTask(identifier)
        }
        box.install(task)
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        let identifier = ObjectIdentifier(loadingRequest)
        lock.lock()
        let task = tasks.removeValue(forKey: identifier)
        lock.unlock()
        task?.cancel()
    }

    private func fill(_ request: AVAssetResourceLoadingRequest) async throws {
        if let information = request.contentInformationRequest {
            let ext = URL(fileURLWithPath: attachment.name).pathExtension
            information.contentType = UTType(filenameExtension: ext)?.identifier
                ?? UTType.movie.identifier
            information.contentLength = attachment.byteCount
            information.isByteRangeAccessSupported = true
        }
        guard let dataRequest = request.dataRequest else { return }

        let start = dataRequest.requestedOffset
        guard attachment.byteCount > 0, start >= 0, start < attachment.byteCount else {
            throw NSError(domain: Self.errorDomain, code: 1)
        }
        var offset = max(start, dataRequest.currentOffset)
        let requestedEnd: Int64
        if dataRequest.requestsAllDataToEndOfResource {
            requestedEnd = attachment.byteCount
        } else {
            let available = attachment.byteCount - start
            let length = min(Int64(dataRequest.requestedLength), available)
            requestedEnd = start + length
        }
        guard offset >= start, offset < requestedEnd else {
            throw NSError(domain: Self.errorDomain, code: 1)
        }

        while offset < requestedEnd {
            try Task.checkCancellation()
            if request.isCancelled { throw CancellationError() }
            let length = min(
                requestedEnd - offset,
                Int64(RemoteAttachmentVideo.maximumChunkBytes)
            )
            let upper = offset + length
            let data = try await client.attachmentVideoData(
                sessionID: sessionID,
                id: attachment.id,
                range: offset ..< upper,
                totalBytes: attachment.byteCount
            )
            guard !data.isEmpty else {
                throw NSError(domain: Self.errorDomain, code: 2)
            }
            dataRequest.respond(with: data)
            offset += Int64(data.count)
        }
    }

    private func removeTask(_ identifier: ObjectIdentifier) {
        lock.lock()
        tasks.removeValue(forKey: identifier)
        lock.unlock()
    }
}

#if DEBUG
/// Deterministic detail fixtures exercise the app's real preview renderers without networking or
/// exposing a developer-machine path to the simulator. Production attachment detail continues to
/// load the chosen opaque attachment ID from the paired Mac.
struct RemoteAttachmentPreviewDemo: View {
    let kind: RemoteAttachmentKind

    /// Every kind the demo knows, in the order the ledger shows them; the one asked for is
    /// the page on screen, so a capture of any kind also shows its neighbours.
    static let kinds: [RemoteAttachmentKind] = [
        .image, .pdf, .html, .text, .archive, .media, .video
    ]

    var body: some View {
        RemoteAttachmentGallery(
            sessionID: "workspace-demo",
            attachments: Self.kinds.map { Self.attachment(for: $0) },
            initialID: Self.attachment(for: kind).id,
            client: RemoteClient(link: RemoteConnectionLink(
                baseURL: URL(string: "https://workspace.invalid")!,
                token: "attachment-preview"
            )!),
            offersThumbnails: false,
            offersVideoStreaming: false,
            initialData: Dictionary(uniqueKeysWithValues: Self.kinds.compactMap { kind in
                Self.previewData(for: kind).map { (Self.attachment(for: kind).id, $0) }
            }),
            // The Mac draws thumbnails; the demo has no Mac, so the image's own bytes stand in
            // for its thumbnail and every other cell shows its glyph.
            seedThumbnails: Dictionary(uniqueKeysWithValues: [RemoteAttachmentKind.image].compactMap { kind in
                Self.previewData(for: kind).flatMap(UIImage.init(data:)).map {
                    (Self.attachment(for: kind).id, $0)
                }
            }),
            loadsRemotely: false
        )
    }

    private static func attachment(for kind: RemoteAttachmentKind) -> RemoteAttachmentDTO {
        switch kind {
        case .pdf:
            .init(path: "artifacts/threading-ui-review.pdf", name: "threading-ui-review.pdf", kind: .pdf, byteCount: 842_761, origin: .agent)
        case .html:
            .init(path: "reports/ui-evidence.html", name: "ui-evidence.html", kind: .html, byteCount: 32_914, origin: .agent)
        case .archive:
            .init(path: "exports/diagnostics.zip", name: "diagnostics.zip", kind: .archive, byteCount: 1_204_981, origin: .user)
        case .media:
            .init(path: "animations/loading.lottie", name: "loading.lottie", kind: .media, byteCount: 24_618, origin: .agent)
        case .video:
            .init(path: "recordings/keyboard-lifecycle.mp4", name: "keyboard-lifecycle.mp4", kind: .video, byteCount: 18_204_517, origin: .agent)
        case .text:
            .init(path: "artifacts/keyboard-lifecycle.txt", name: "keyboard-lifecycle.txt", kind: .text, byteCount: 1_284, origin: .agent)
        default:
            .init(path: "screenshots/keyboard-dismissed.png", name: "keyboard-dismissed.png", kind: .image, byteCount: 184_320, origin: .user)
        }
    }

    private static func previewData(for kind: RemoteAttachmentKind) -> Data? {
        switch kind {
        case .pdf: return Self.pdfData()
        case .html:
            return Data("""
            <!doctype html><meta name=\"viewport\" content=\"width=device-width\">
            <style>
            body{background:#090d16;color:#e9fff8;font:16px -apple-system;padding:24px}
            article{background:#151936;border:1px solid #2f986e;border-radius:18px;padding:22px}
            h1{font-size:24px} code{color:#00f29d} li{margin:10px 0}
            </style><article><h1>Keyboard lifecycle review</h1>
            <p>The generated evidence confirms:</p><ul><li>focus waits for <code>keyboardDidShow</code></li>
            <li>dismissal waits for <code>keyboardDidHide</code></li><li>the composer returns to its baseline</li></ul></article>
            """.utf8)
        case .text:
            return Data("""
            Keyboard lifecycle verification
            ===============================

            ✓ Focus waits for keyboardDidShow.
            ✓ Dismissal waits for keyboardDidHide.
            ✓ The composer returns to its original visual anchor.

            Tested on the compact and regular iPhone layouts.
            """.utf8)
        case .archive: return nil
        default: return UIImage(named: "AppIconPreviewDefault")?.pngData()
        }
    }

    private static func pdfData() -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            for page in 1...3 {
                context.beginPage()
                UIColor(red: 0.04, green: 0.06, blue: 0.10, alpha: 1).setFill()
                context.cgContext.fill(bounds)
                "Threading UI review · \(page)/3".draw(
                    at: CGPoint(x: 48, y: 54),
                    withAttributes: [
                        .font: UIFont.systemFont(ofSize: 30, weight: .bold),
                        .foregroundColor: UIColor.white,
                    ]
                )
                let pageBody = [
                    "Keyboard lifecycle\n\n✓ Composer restored\n✓ Evidence captured\n✓ Private paths omitted",
                    "Conversation layout\n\n✓ Tool rows compact\n✓ Dynamic type preserved\n✓ Latest control visible",
                    "Attachment previews\n\n✓ Images scale to fit\n✓ HTML loads locally\n✓ PDF pages swipe horizontally",
                ][page - 1]
                pageBody.draw(
                    in: CGRect(x: 48, y: 126, width: 516, height: 220),
                    withAttributes: [
                        .font: UIFont.systemFont(ofSize: 18),
                        .foregroundColor: UIColor(red: 0.72, green: 0.92, blue: 0.86, alpha: 1),
                    ]
                )
            }
        }
    }
}
#endif

private final class RemoteHTMLPreviewView: UIView, WKNavigationDelegate {
    let webView: WKWebView
    private let placeholder = UILabel()

    override init(frame: CGRect) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: frame)
        webView.isOpaque = false
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.text = MobileL10n.string("Rendering preview…")
        placeholder.font = .preferredFont(forTextStyle: .subheadline)
        placeholder.textAlignment = .center
        addSubview(webView)
        addSubview(placeholder)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        placeholder.isHidden = true
    }

    func update(backgroundColor: UIColor) {
        self.backgroundColor = backgroundColor
        webView.backgroundColor = backgroundColor
        webView.scrollView.backgroundColor = backgroundColor
        placeholder.textColor = .secondaryLabel
    }
}

private struct RemoteHTMLView: UIViewRepresentable {
    let data: Data
    let backgroundColor: UIColor

    final class Coordinator {
        var data: Data?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> RemoteHTMLPreviewView {
        RemoteHTMLPreviewView()
    }

    func updateUIView(_ view: RemoteHTMLPreviewView, context: Context) {
        view.update(backgroundColor: backgroundColor)
        guard context.coordinator.data != data else { return }
        context.coordinator.data = data
        view.webView.loadHTMLString(String(decoding: data, as: UTF8.self), baseURL: nil)
    }
}

private final class RemoteZoomableImageScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 4
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        bouncesZoom = true
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        if zoomScale == minimumZoomScale { imageView.frame = bounds }
    }

    func update(image: UIImage, backgroundColor: UIColor) {
        self.backgroundColor = backgroundColor
        imageView.image = image
        setNeedsLayout()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    @objc private func toggleZoom(_ recognizer: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        let targetScale = min(2, maximumZoomScale)
        let point = recognizer.location(in: imageView)
        let size = CGSize(width: bounds.width / targetScale, height: bounds.height / targetScale)
        zoom(to: CGRect(
            x: point.x - size.width / 2,
            y: point.y - size.height / 2,
            width: size.width,
            height: size.height
        ), animated: true)
    }
}

private struct RemoteZoomableImageView: UIViewRepresentable {
    let image: UIImage
    let backgroundColor: UIColor

    func makeUIView(context: Context) -> RemoteZoomableImageScrollView {
        RemoteZoomableImageScrollView()
    }

    func updateUIView(_ view: RemoteZoomableImageScrollView, context: Context) {
        view.update(image: image, backgroundColor: backgroundColor)
    }
}

private struct RemotePDFView: UIViewRepresentable {
    let data: Data
    let backgroundColor: UIColor

    final class Coordinator {
        var data: Data?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePage
        view.displayDirection = .horizontal
        view.displaysPageBreaks = true
        view.usePageViewController(true, withViewOptions: [
            UIPageViewController.OptionsKey.interPageSpacing: 12,
        ])
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        view.backgroundColor = backgroundColor
        if context.coordinator.data != data {
            context.coordinator.data = data
            view.document = PDFDocument(data: data)
        }
    }
}
