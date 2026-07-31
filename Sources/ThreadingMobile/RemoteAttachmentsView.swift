import PDFKit
import ThreadingRemoteKit
import SwiftUI
import UIKit

/// Images and PDFs the selected agent mentioned, fetched on demand from the paired Mac.
struct RemoteAttachmentsView: View {
    let session: RemoteSessionSummaryDTO
    let client: RemoteClient
    var showsCloseButton = true

    @Environment(\.dismiss) private var dismiss
    @Environment(\.remoteTheme) private var theme
    @State private var attachments: [RemoteAttachmentDTO]?
    @State private var errorMessage: String?
    @State private var isLoading = false

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
                    Text("Images and PDFs mentioned by this session will appear here.")
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
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            attachments = try await client.attachments(sessionID: session.id).attachments
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct RemoteAttachmentRow: View {
    let attachment: RemoteAttachmentDTO

    @Environment(\.remoteTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: attachment.kind == "pdf" ? "doc.richtext" : "photo")
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
}

private struct RemoteAttachmentPreview: View {
    let sessionID: String
    let attachment: RemoteAttachmentDTO
    let client: RemoteClient

    @Environment(\.remoteTheme) private var theme
    @State private var data: Data?
    @State private var errorMessage: String?
    @State private var isLoading = false

    var body: some View {
        Group {
            if let data {
                if attachment.kind == "pdf" {
                    RemotePDFView(data: data, backgroundColor: theme.uiColor(
                        "ground",
                        fallback: "#16181D"
                    ))
                } else if let image = UIImage(data: data) {
                    ScrollView([.horizontal, .vertical]) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: image.size.width, maxHeight: image.size.height)
                            .padding(12)
                    }
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
            systemImage: attachment.kind == "pdf" ? "doc.richtext" : "photo",
            description: Text(MobileL10n.string(message))
        )
    }

    @MainActor
    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            data = try await client.attachmentData(
                sessionID: sessionID,
                path: attachment.path
            )
            errorMessage = nil
        } catch {
            data = nil
            errorMessage = error.localizedDescription
        }
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
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
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
