import ThreadingRemoteKit
import SwiftUI
import UIKit
import VisionKit

/// What this app will act on, whichever door the payload came through.
///
/// Three doors reach the accept path: the QR scanner, the paste field, and a `threading://` URL
/// the operating system delivers because somebody tapped an invitation. `RemoteInvitation` in
/// `ThreadingRemoteKit` is the only parser any of them use; this adds the one rule that is the
/// application's rather than the wire's — a private door must be `https`, because pairing over
/// plain HTTP would hand the bearer to the network the invitation was sent across.
enum MobileInvitationRoute {
    case hostedPairing(HostedPairingLink)
    case connection(RemoteConnectionLink)

    init?(payload: String) {
        switch RemoteInvitation(payload: payload) {
        case .hostedPairing(let hosted):
            self = .hostedPairing(hosted)
        case .connection(let link) where link.baseURL.scheme?.lowercased() == "https":
            self = .connection(link)
        default:
            return nil
        }
    }

    init?(url: URL) {
        self.init(payload: url.absoluteString)
    }
}

struct PairingView: View {
    @EnvironmentObject private var model: RemoteAppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.remoteTheme) private var theme
    @State private var linkText = ""
    @State private var errorMessage: String?
    @State private var isConnecting = false
    @State private var showsLinkHelp = false
    @FocusState private var linkIsFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: MobileDesign.Spacing.inset) {
                    scannerCard

                    linkCard

                    if scannedPinnedIdentity {
                        pinnedIdentityNote
                    }

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(theme.negative)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    DisclosureGroup(isExpanded: $showsLinkHelp) {
                        pairingHelp
                            .padding(.top, MobileDesign.Spacing.medium)
                    } label: {
                        Label("About private links", systemImage: "lock.shield")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(theme.secondaryLabel)
                    }
                    .tint(theme.accent)
                    .padding(.horizontal, MobileDesign.Spacing.tight)

                    Button {
                        dismiss()
                        model.startDemo()
                    } label: {
                        Text("No Mac nearby? Try the demo.")
                            .font(.footnote.weight(.medium))
                            .frame(maxWidth: .infinity, minHeight: MobileDesign.Size.minimumTapTarget)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.secondaryLabel)
                }
                .padding(MobileDesign.Spacing.inset)
            }
            .navigationTitle("Add Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(theme.surface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .background(theme.ground.ignoresSafeArea())
        }
        .presentationDetents([.large])
        // A tapped invitation opens this screen with its payload already in hand. It is shown in
        // the field rather than accepted invisibly, so a failure has somewhere to be reported and
        // the person can see what they are about to join.
        .task(id: model.pendingInvitation) {
            guard let pending = model.takePendingInvitation() else { return }
            linkText = pending
            pair(pending)
        }
    }

    @ViewBuilder
    private var scannerCard: some View {
        if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
            QRCodeScanner { value in
                guard !isConnecting else { return }
                linkText = value
                pair(value)
            }
            .frame(height: 236)
            .clipShape(RoundedRectangle(cornerRadius: theme.panelRadius))
            .overlay(alignment: .bottom) {
                Label("Scan the code on your Mac", systemImage: "qrcode")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(theme.elevated, in: Capsule())
                    .padding(14)
            }
        } else {
            VStack(spacing: MobileDesign.Spacing.small) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 30, weight: .light))
                Text("Scan a QR code")
                    .font(.subheadline.weight(.semibold))
                Text("Camera scanning isn’t available here. Paste a secure link below.")
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryLabel)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 132)
            .background(theme.panel, in: RoundedRectangle(cornerRadius: theme.panelRadius))
            .overlay {
                RoundedRectangle(cornerRadius: theme.panelRadius)
                    .stroke(theme.border, lineWidth: theme.borderWidth)
            }
        }
    }

    private var linkCard: some View {
        let connectIsDisabled = isConnecting || linkText.isEmpty
        return VStack(alignment: .leading, spacing: MobileDesign.Spacing.medium) {
            Label("Paste a link", systemImage: "link")
                .font(.headline)

            Text("Use the private link from your Mac or an invited chat.")
                .font(.footnote)
                .foregroundStyle(theme.secondaryLabel)

            HStack(spacing: MobileDesign.Spacing.small) {
                TextField("https://…", text: $linkText)
                    .focused($linkIsFocused)
                    .mobileUIEvidenceKeyboardFocus($linkIsFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .padding(.horizontal, 14)
                    .frame(minHeight: MobileDesign.Size.minimumTapTarget)
                    .background(
                        theme.controlResting,
                        in: RoundedRectangle(cornerRadius: theme.controlRadius)
                    )

                Button {
                    linkText = UIPasteboard.general.string ?? ""
                } label: {
                    Image(systemName: "doc.on.clipboard")
                        .frame(
                            width: MobileDesign.Size.minimumTapTarget,
                            height: MobileDesign.Size.minimumTapTarget
                        )
                        .background(
                            theme.controlResting,
                            in: RoundedRectangle(cornerRadius: theme.controlRadius)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Paste")
            }

            Button {
                pair(linkText)
            } label: {
                HStack {
                    if isConnecting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Connect", systemImage: "arrow.right")
                    }
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(
                    connectIsDisabled ? theme.controlHover : theme.accent,
                    in: RoundedRectangle(cornerRadius: theme.controlRadius)
                )
                .foregroundStyle(
                    connectIsDisabled ? theme.secondaryLabel : theme.ground
                )
            }
            .buttonStyle(.plain)
            .disabled(connectIsDisabled)
        }
        .padding(MobileDesign.Spacing.inset)
        .background(theme.panel, in: RoundedRectangle(cornerRadius: theme.panelRadius))
        .overlay {
            RoundedRectangle(cornerRadius: theme.panelRadius)
                .stroke(theme.border, lineWidth: theme.borderWidth)
        }
    }

    /// Whether the code in hand names a certificate, which is what the note below states.
    ///
    /// Read from the link rather than from the scanner, so a pasted link says the same thing a
    /// photographed one does.
    private var scannedPinnedIdentity: Bool {
        RemoteConnectionLink(string: linkText)?.pinnedFingerprintCode != nil
    }

    /// One line, at the moment it is true and before anything is trusted.
    ///
    /// A code that carries a fingerprint is a promise this app can keep exactly: it will accept
    /// this Mac's own certificate and nothing else, with no certificate authority in the path.
    /// Saying so here is the only place the person can weigh it, and the detail beside the Mac
    /// in Choose Mac shows the same code for comparing against the Mac's settings page.
    private var pinnedIdentityNote: some View {
        Label(
            MobileL10n.string("This iPhone will trust only this Mac’s identity."),
            systemImage: "checkmark.shield"
        )
        .font(.footnote)
        .foregroundStyle(theme.secondaryLabel)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, MobileDesign.Spacing.tight)
    }

    private var pairingHelp: some View {
        VStack(alignment: .leading, spacing: MobileDesign.Spacing.medium) {
            PairingHelpRow(
                symbol: "laptopcomputer",
                title: "Your Mac",
                detail: "Open Threading → Settings → Remote Access to show its pairing code."
            )
            PairingHelpRow(
                symbol: "bubble.left",
                title: "Shared chat",
                detail: "A shared link opens one chat and can never manage your Mac."
            )
        }
        .padding(.horizontal, MobileDesign.Spacing.tight)
    }

    private func pair(_ text: String) {
        guard let route = MobileInvitationRoute(payload: text) else {
            errorMessage = MobileL10n.string(
                "That isn’t a valid secure Threading private link."
            )
            return
        }
        switch route {
        case .hostedPairing(let hostedLink):
            beginPairing {
                try await model.pair(hostedLink, displayName: UIDevice.current.name)
            }
        case .connection(let link):
            beginPairing {
                try await model.pair(link, displayName: UIDevice.current.name)
            }
        }
    }

    private func beginPairing(_ operation: @escaping @MainActor () async throws -> Void) {
        isConnecting = true
        errorMessage = nil
        Task {
            do {
                try await operation()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isConnecting = false
            }
        }
    }
}

private struct PairingHelpRow: View {
    @Environment(\.remoteTheme) private var theme
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: MobileDesign.Spacing.medium) {
            Image(systemName: symbol)
                .foregroundStyle(theme.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: MobileDesign.Spacing.hairline) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct QRCodeScanner: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: true,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(
        _ uiViewController: DataScannerViewController,
        coordinator: Coordinator
    ) {
        uiViewController.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onScan: (String) -> Void
        private var delivered = false

        init(onScan: @escaping (String) -> Void) {
            self.onScan = onScan
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard !delivered else { return }
            for item in addedItems {
                guard case .barcode(let barcode) = item,
                      let value = barcode.payloadStringValue else {
                    continue
                }
                delivered = true
                onScan(value)
                return
            }
        }
    }
}
