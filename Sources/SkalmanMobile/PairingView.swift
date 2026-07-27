import SkalmanRemoteKit
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
                VStack(spacing: 22) {
                    scannerCard

                    HStack(spacing: 12) {
                        Rectangle().fill(theme.divider).frame(height: theme.borderWidth)
                        Text("or paste a private link")
                            .font(.caption)
                            .foregroundStyle(theme.secondaryLabel)
                        Rectangle().fill(theme.divider).frame(height: theme.borderWidth)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        TextField("https://…/#private-link", text: $linkText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .padding(14)
                            .background(
                                theme.panel,
                                in: RoundedRectangle(cornerRadius: theme.controlRadius)
                            )

                        HStack {
                            Button("Paste") {
                                linkText = UIPasteboard.general.string ?? ""
                            }
                            .buttonStyle(.bordered)

                            Spacer()

                            Button {
                                pair(linkText)
                            } label: {
                                if isConnecting {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text("Connect")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(theme.accent)
                            .foregroundStyle(theme.ground)
                            .disabled(isConnecting || linkText.isEmpty)
                        }
                    }

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(theme.negative)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Text("For your own Mac, open Skalman → Settings → Remote Access and scan the pairing code. You can also paste a one-chat link someone shared with you. Owner pairing can manage your Mac; a shared-chat link never can.")
                        .font(.footnote)
                        .foregroundStyle(theme.secondaryLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(20)
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
            .background(theme.ground)
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
            .frame(height: 310)
            .clipShape(RoundedRectangle(cornerRadius: theme.panelRadius))
            .overlay(alignment: .bottom) {
                Label("Scan the code shown on your Mac", systemImage: "qrcode")
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

    private func pair(_ text: String) {
        guard let link = RemoteConnectionLink(string: text),
              link.baseURL.scheme?.lowercased() == "https" else {
            errorMessage = "That isn’t a valid secure Skalman private link."
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
