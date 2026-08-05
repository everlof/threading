import ThreadingRemoteKit
import SwiftUI
import UIKit
import VisionKit

struct PairingView: View {
    @EnvironmentObject private var model: RemoteAppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.remoteTheme) private var theme
    @State private var linkText = ""
    @State private var errorMessage: String?
    @State private var isConnecting = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: MobileDesign.Spacing.large) {
                    scannerCard

                    linkCard

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(theme.negative)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    pairingHelp
                }
                .padding(MobileDesign.Spacing.large)
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
    }

    @ViewBuilder
    private var scannerCard: some View {
        if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
            QRCodeScanner { value in
                guard !isConnecting else { return }
                linkText = value
                pair(value)
            }
            .frame(height: 286)
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
            VStack(spacing: 14) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 44, weight: .light))
                Text("QR scanning isn’t available on this device.")
                    .font(.headline)
                    Text("Paste an owner pairing link or a shared-chat link below.")
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryLabel)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 230)
            .background(theme.panel, in: RoundedRectangle(cornerRadius: theme.panelRadius))
            .remoteThemeGlow(theme)
        }
    }

    private var linkCard: some View {
        VStack(alignment: .leading, spacing: MobileDesign.Spacing.medium) {
            Label("Use a link", systemImage: "link")
                .font(.headline)

            Text("Paste a pairing link, or a chat link someone shared with you.")
                .font(.subheadline)
                .foregroundStyle(theme.secondaryLabel)

            HStack(spacing: MobileDesign.Spacing.small) {
                TextField("https://…", text: $linkText)
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
                .background(theme.accent, in: Capsule())
                .foregroundStyle(theme.ground)
            }
            .buttonStyle(.plain)
            .disabled(isConnecting || linkText.isEmpty)
            .opacity(isConnecting || linkText.isEmpty ? 0.45 : 1)
        }
        .padding(MobileDesign.Spacing.inset)
        .background(theme.panel, in: RoundedRectangle(cornerRadius: theme.panelRadius))
        .overlay {
            RoundedRectangle(cornerRadius: theme.panelRadius)
                .stroke(theme.border, lineWidth: theme.borderWidth)
        }
        .remoteThemeGlow(theme)
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
        guard let link = RemoteConnectionLink(string: text),
              link.baseURL.scheme?.lowercased() == "https" else {
            errorMessage = MobileL10n.string(
                "That isn’t a valid secure Threading private link."
            )
            return
        }
        isConnecting = true
        errorMessage = nil
        Task {
            do {
                try await model.pair(link, displayName: UIDevice.current.name)
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
