import PDFKit
import ThreadingRemoteKit
import SwiftUI
import UIKit
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

    init(
        session: RemoteSessionSummaryDTO,
        client: RemoteClient,
        showsCloseButton: Bool = true,
        initialAttachments: [RemoteAttachmentDTO]? = nil,
        loadsRemotely: Bool = true
    ) {
        self.session = session
        self.client = client
        self.showsCloseButton = showsCloseButton
        self.loadsRemotely = loadsRemotely
        _attachments = State(initialValue: initialAttachments)
    }

    var body: some View {
        Group {
            if isLoading, attachments == nil {
                VStack(spacing: 14) {
                    ProgressView()
                    Text("Finding attachments…")
                        .foregroundStyle(theme.secondaryLabel)
                }
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
                    NavigationLink {
                        RemoteAttachmentPreview(
                            sessionID: session.id,
                            attachment: attachment,
                            client: client
                        )
                    } label: {
                        RemoteAttachmentRow(attachment: attachment)
                    }
                    .listRowBackground(theme.surface)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
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
                    .accessibilityLabel("Close attachments")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
                .accessibilityLabel("Refresh attachments")
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
        case "user": return "You"
        case "agent": return "Agent"
        default: return nil
        }
    }

    private var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: attachment.byteCount, countStyle: .file)
    }

    private var iconName: String {
        switch attachment.kind {
        case "pdf": "doc.richtext"
        case "html": "safari"
        case "archive": "archivebox"
        case "document": "doc.text"
        case "diagram": "point.3.connected.trianglepath.dotted"
        case "media": "play.rectangle"
        default: "photo"
        }
    }
}

/// Resolves a notification's opaque attachment identity, then hands the normal attachment
/// preview the result. The route never carries a host path or URL.
struct RemoteAttachmentTargetView: View {
    let session: RemoteSessionSummaryDTO
    let attachmentID: String
    let client: RemoteClient

    @Environment(\.remoteTheme) private var theme
    @State private var attachment: RemoteAttachmentDTO?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let attachment {
                RemoteAttachmentPreview(
                    sessionID: session.id,
                    attachment: attachment,
                    client: client
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
                VStack(spacing: 14) {
                    ProgressView()
                    Text("Opening attachment…")
                        .foregroundStyle(theme.secondaryLabel)
                }
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

struct RemoteAttachmentPreview: View {
    let sessionID: String
    let attachment: RemoteAttachmentDTO
    let client: RemoteClient

    @Environment(\.remoteTheme) private var theme
    @State private var data: Data?
    @State private var errorMessage: String?
    @State private var isLoading = false
    private let loadsRemotely: Bool

    init(
        sessionID: String,
        attachment: RemoteAttachmentDTO,
        client: RemoteClient,
        initialData: Data? = nil,
        loadsRemotely: Bool = true
    ) {
        self.sessionID = sessionID
        self.attachment = attachment
        self.client = client
        self.loadsRemotely = loadsRemotely
        _data = State(initialValue: initialData)
    }

    var body: some View {
        Group {
            // Decided before any bytes move: the phone has no renderer for an archive, an
            // office document, or diagram source, and downloading one only to say "the image
            // could not be decoded" spends the attachment byte cap on a file it was never
            // going to show.
            if attachment.kind == "media" {
                // The renderer is host-owned, so the mirror is achievable — but a live player on
                // the phone needs a poster-frame or frame-stream endpoint the remote surface does
                // not have yet, and a silent blank card would be worse than a sentence.
                unavailable("This animation plays on your Mac.")
            } else if Self.previewsOnMacOnly.contains(attachment.kind) {
                unavailable("This file previews on your Mac.")
            } else if let data {
                if attachment.kind == "pdf" {
                    RemotePDFView(data: data, backgroundColor: theme.uiColor(
                        "ground",
                        fallback: "#16181D"
                    ))
                } else if attachment.kind == "html" {
                    RemoteHTMLView(
                        data: data,
                        backgroundColor: theme.uiColor("ground", fallback: "#16181D")
                    )
                } else if attachment.kind == "text" {
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
                VStack(spacing: 14) {
                    ProgressView()
                    Text("Loading preview…")
                        .foregroundStyle(theme.secondaryLabel)
                }
            }
        }
        .navigationTitle(attachment.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(theme.surface, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .background(theme.ground)
        .task { await load() }
    }

    @ViewBuilder
    private func unavailable(_ message: String) -> some View {
        ContentUnavailableView(
            "No preview",
            systemImage: unavailableIconName,
            description: Text(MobileL10n.string(message))
        )
    }

    private static let previewsOnMacOnly: Set<String> = [
        "archive", "document", "diagram", "media"
    ]

    private var unavailableIconName: String {
        switch attachment.kind {
        case "pdf": "doc.richtext"
        case "html": "safari"
        case "archive": "archivebox"
        case "text": "doc.plaintext"
        case "document": "doc.text"
        case "diagram": "point.3.connected.trianglepath.dotted"
        case "media": "play.rectangle"
        default: "photo"
        }
    }

    @MainActor
    private func load() async {
        // The body never renders these kinds, so their bytes are never asked for.
        guard !Self.previewsOnMacOnly.contains(attachment.kind) else { return }
        guard loadsRemotely else { return }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            data = try await client.attachmentData(
                sessionID: sessionID,
                id: attachment.id
            )
            errorMessage = nil
        } catch {
            MobileDiagnostics.logDegraded(.attachmentContent, error: error)
            data = nil
            errorMessage = error.localizedDescription
        }
    }
}

#if DEBUG
/// Deterministic detail fixtures exercise the app's real preview renderers without networking or
/// exposing a developer-machine path to the simulator. Production attachment detail continues to
/// load the chosen opaque attachment ID from the paired Mac.
struct RemoteAttachmentPreviewDemo: View {
    let kind: String

    var body: some View {
        RemoteAttachmentPreview(
            sessionID: "workspace-demo",
            attachment: attachment,
            client: RemoteClient(link: RemoteConnectionLink(
                baseURL: URL(string: "https://workspace.invalid")!,
                token: "attachment-preview"
            )!),
            initialData: previewData,
            loadsRemotely: false
        )
    }

    private var attachment: RemoteAttachmentDTO {
        switch kind {
        case "pdf":
            .init(path: "artifacts/threading-ui-review.pdf", name: "threading-ui-review.pdf", kind: "pdf", byteCount: 842_761, origin: "agent")
        case "html":
            .init(path: "reports/ui-evidence.html", name: "ui-evidence.html", kind: "html", byteCount: 32_914, origin: "agent")
        case "archive":
            .init(path: "exports/diagnostics.zip", name: "diagnostics.zip", kind: "archive", byteCount: 1_204_981, origin: "user")
        case "media":
            .init(path: "animations/loading.lottie", name: "loading.lottie", kind: "media", byteCount: 24_618, origin: "agent")
        case "text":
            .init(path: "artifacts/keyboard-lifecycle.txt", name: "keyboard-lifecycle.txt", kind: "text", byteCount: 1_284, origin: "agent")
        default:
            .init(path: "screenshots/keyboard-dismissed.png", name: "keyboard-dismissed.png", kind: "image", byteCount: 184_320, origin: "user")
        }
    }

    private var previewData: Data? {
        switch kind {
        case "pdf": return Self.pdfData()
        case "html":
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
        case "text":
            return Data("""
            Keyboard lifecycle verification
            ===============================

            ✓ Focus waits for keyboardDidShow.
            ✓ Dismissal waits for keyboardDidHide.
            ✓ The composer returns to its original visual anchor.

            Tested on the compact and regular iPhone layouts.
            """.utf8)
        case "archive": return nil
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
