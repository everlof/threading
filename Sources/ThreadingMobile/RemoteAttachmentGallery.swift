import SwiftUI
import ThreadingRemoteKit
import UIKit

// MARK: - Detail

/// The line under a gallery's title: where this attachment stands in the set, its pixels when
/// they are known, and its size — the Mac inspector's detail, in the Mac's order.
enum RemoteAttachmentGalleryDetail {
    static let separator = " · "

    static func text(index: Int, count: Int, pixelSize: CGSize?, byteCount: Int64) -> String {
        var parts: [String] = []
        if count > 1 {
            parts.append(MobileL10n.string("%lld of %lld", Int64(index + 1), Int64(count)))
        }
        if let pixelSize, pixelSize.width > 0, pixelSize.height > 0 {
            parts.append("\(Int(pixelSize.width)) × \(Int(pixelSize.height))")
        }
        parts.append(ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file))
        return parts.joined(separator: separator)
    }

    /// Which kinds the Mac can draw a thumbnail of. Everything else keeps its glyph in the
    /// ledger and costs the link nothing.
    static func hasThumbnail(kind: RemoteAttachmentKind) -> Bool {
        kind == .image || kind == .pdf
    }
}

// MARK: - Gallery

/// One attachment at a time, with the others a swipe away and a ledger of them underneath.
///
/// The Mac's inspector shows a file with its neighbours in a rail below it; this is that screen
/// on a phone. The pages are a horizontal paging scroll of the same previews the single
/// attachment screen draws, built lazily so a session with a hundred attachments mounts the
/// one on screen and its neighbours, and the ledger is a lazy row of thumbnails that asks the
/// Mac for each as it scrolls into view.
struct RemoteAttachmentGallery: View {
    let sessionID: String
    let attachments: [RemoteAttachmentDTO]
    let client: RemoteClient
    @Environment(\.remoteTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var thumbnails: RemoteAttachmentThumbnailStore
    @State private var currentID: String?
    @State private var pixelSizes: [String: CGSize] = [:]
    private let initialData: [String: Data]
    private let loadsRemotely: Bool

    init(
        sessionID: String,
        attachments: [RemoteAttachmentDTO],
        initialID: String,
        client: RemoteClient,
        offersThumbnails: Bool,
        initialData: [String: Data] = [:],
        seedThumbnails: [String: UIImage] = [:],
        loadsRemotely: Bool = true
    ) {
        self.sessionID = sessionID
        self.attachments = attachments
        self.client = client
        self.initialData = initialData
        self.loadsRemotely = loadsRemotely
        _currentID = State(initialValue: initialID)
        _thumbnails = StateObject(wrappedValue: RemoteAttachmentThumbnailStore(
            isOffered: offersThumbnails,
            seed: seedThumbnails,
            fetch: { id in
                try await client.attachmentThumbnail(sessionID: sessionID, id: id)
            }
        ))
    }

    private var current: RemoteAttachmentDTO? {
        attachments.first { $0.id == currentID } ?? attachments.first
    }

    private var currentIndex: Int {
        attachments.firstIndex { $0.id == current?.id } ?? 0
    }

    var body: some View {
        VStack(spacing: 0) {
            pages
            if attachments.count > 1 {
                ledger
            }
        }
        .background(theme.ground)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(theme.surface, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                RemoteAttachmentGalleryTitle(
                    title: current?.name ?? "",
                    detail: current.map { attachment in
                        RemoteAttachmentGalleryDetail.text(
                            index: currentIndex,
                            count: attachments.count,
                            pixelSize: pixelSizes[attachment.id],
                            byteCount: attachment.byteCount
                        )
                    } ?? ""
                )
            }
        }
    }

    private var pages: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(attachments) { attachment in
                    RemoteAttachmentPreviewContent(
                        sessionID: sessionID,
                        attachment: attachment,
                        client: client,
                        initialData: initialData[attachment.id],
                        loadsRemotely: loadsRemotely,
                        onDecodedImageSize: { size in pixelSizes[attachment.id] = size }
                    )
                    // A page is the scroller's whole viewport, both ways: a preview sized to
                    // its content left the ledger standing in the middle of the screen.
                    .containerRelativeFrame([.horizontal, .vertical])
                    .id(attachment.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $currentID)
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The Mac inspector's rail: every attachment as a thumbnail, the current one outlined,
    /// kept in view as the pages move, and a tap on any of them going there.
    private var ledger: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: MobileDesign.Spacing.small) {
                    ForEach(attachments) { attachment in
                        RemoteAttachmentLedgerCell(
                            attachment: attachment,
                            thumbnail: thumbnails.image(for: attachment.id),
                            isSelected: attachment.id == current?.id
                        )
                        .id(attachment.id)
                        .onTapGesture {
                            withAnimation(reduceMotion ? nil : .easeInOut(
                                duration: MobileDesign.Motion.ledgerScroll
                            )) {
                                currentID = attachment.id
                            }
                        }
                        .task {
                            await thumbnails.load(
                                id: attachment.id,
                                hasThumbnail: RemoteAttachmentGalleryDetail.hasThumbnail(
                                    kind: attachment.kind
                                )
                            )
                        }
                    }
                }
                .padding(.horizontal, MobileDesign.Spacing.inset)
                .padding(.vertical, MobileDesign.Spacing.small)
            }
            // A horizontal scroller is as flexible vertically as the pages are, and a stack
            // splits the height between two flexible children: the ledger stood in the middle
            // of the screen with half the height to itself. Its height is its cells'.
            .frame(height: MobileDesign.Size.attachmentLedgerCell + MobileDesign.Spacing.small * 2)
            .background(theme.surface)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(theme.border)
                    .frame(height: theme.borderWidth)
            }
            .onChange(of: currentID, initial: true) { _, id in
                guard let id else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(
                    duration: MobileDesign.Motion.ledgerScroll
                )) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
        .accessibilityLabel(MobileL10n.string("Attachments"))
    }
}

/// A two-line title for the bar: the name, morphing as the pages move, over the detail.
private struct RemoteAttachmentGalleryTitle: View {
    let title: String
    let detail: String
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        VStack(spacing: MobileDesign.Spacing.hairline) {
            MobileMorphingTitle(
                title: title,
                textStyle: .headline,
                weight: .semibold,
                textColor: theme.uiLabel,
                groundColor: theme.uiSurface,
                alignment: .center
            )
            .frame(maxWidth: .infinity)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(theme.secondaryLabel)
                .lineLimit(1)
                .monospacedDigit()
        }
        .frame(
            idealWidth: MobileDesign.Size.navigationTitleWidth,
            maxWidth: MobileDesign.Size.navigationTitleWidth
        )
        .accessibilityElement(children: .combine)
    }
}

/// One cell of the ledger: the Mac's thumbnail when it has one, else the kind's glyph on the
/// control plate, outlined in the accent when it is the page on screen.
private struct RemoteAttachmentLedgerCell: View {
    let attachment: RemoteAttachmentDTO
    let thumbnail: UIImage?
    let isSelected: Bool
    @Environment(\.remoteTheme) private var theme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
                .fill(theme.controlResting)
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: RemoteAttachmentGlyph.name(for: attachment.kind))
                    .font(.title3)
                    .foregroundStyle(theme.secondaryLabel)
            }
        }
        .frame(
            width: MobileDesign.Size.attachmentLedgerCell,
            height: MobileDesign.Size.attachmentLedgerCell
        )
        .clipShape(RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: theme.controlRadius, style: .continuous)
                .strokeBorder(
                    isSelected ? theme.accent : theme.border,
                    lineWidth: isSelected ? MobileDesign.Size.badgeStroke : theme.borderWidth
                )
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(attachment.name)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The one glyph per attachment kind, shared by the list row, the ledger and the empty preview.
enum RemoteAttachmentGlyph {
    static func name(for kind: RemoteAttachmentKind) -> String {
        switch kind {
        case .pdf: "doc.richtext"
        case .html: "safari"
        case .archive: "archivebox"
        case .text: "doc.plaintext"
        case .document: "doc.text"
        case .diagram: "point.3.connected.trianglepath.dotted"
        case .media: "play.rectangle"
        case .video: "film"
        default: "photo"
        }
    }
}
