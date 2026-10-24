import AVFoundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Camera consent and capture are host-owned. iOS owns the viewfinder, retake and confirmation
/// controls; accepting a photo stages it in the caller's draft without saving to Photos.
struct MobileCameraCapture: View {
    let onCapture: (UIImage) -> Void
    let onDismiss: () -> Void
    @Environment(\.remoteTheme) private var theme
    @Environment(\.openURL) private var openURL
    @State private var access = MobileCameraAccess.request
    @State private var showsNotice = false

    var body: some View {
        ZStack {
            theme.ground.ignoresSafeArea()
            if access == .available {
                MobileSystemCamera { image in
                    if let image {
                        onCapture(image)
                        onDismiss()
                    } else {
                        access = .unreadable
                        showsNotice = true
                    }
                } onCancel: {
                    onDismiss()
                }
                .ignoresSafeArea()
            }
        }
        .task {
            var resolved = MobileCameraAccess.resolve(
                isAvailable: UIImagePickerController.isSourceTypeAvailable(.camera),
                authorization: AVCaptureDevice.authorizationStatus(for: .video)
            )
            if resolved == .request {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                resolved = granted ? .available : .denied
            }
            guard !Task.isCancelled else { return }
            access = resolved
            showsNotice = resolved != .available
        }
        .themedAlert(
            "Camera",
            message: access.message,
            isPresented: $showsNotice,
            actions: noticeActions
        )
    }

    private var noticeActions: [ThemedDialogAction] {
        var actions = [ThemedDialogAction("Cancel", role: .cancel, perform: onDismiss)]
        if access == .denied {
            actions.append(ThemedDialogAction("Open Settings") {
                onDismiss()
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            })
        }
        return actions
    }
}

enum MobileCameraAccess: Equatable {
    case request, available, unavailable, denied, restricted, unreadable

    static func resolve(isAvailable: Bool, authorization: AVAuthorizationStatus) -> Self {
        guard isAvailable else { return .unavailable }
        switch authorization {
        case .notDetermined: return .request
        case .authorized: return .available
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .restricted
        }
    }

    var message: String? {
        switch self {
        case .request, .available: return nil
        case .unavailable: return MobileL10n.string("The camera isn’t available on this device.")
        case .denied: return MobileL10n.string("Allow camera access in Settings to take a photo for your message.")
        case .restricted: return MobileL10n.string("Camera access is restricted on this device.")
        case .unreadable: return MobileL10n.string("The photo couldn’t be read. Please try again.")
        }
    }
}

/// The only camera picker construction boundary. Photo Library continues to use PHPicker and
/// never gains a library permission requirement from this separate capture workflow.
private struct MobileSystemCamera: UIViewControllerRepresentable {
    let onCapture: (UIImage?) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier]
        picker.cameraCaptureMode = .photo
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: MobileSystemCamera
        private var finished = false

        init(parent: MobileSystemCamera) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard !finished else { return }
            finished = true
            parent.onCapture(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            guard !finished else { return }
            finished = true
            parent.onCancel()
        }
    }
}

extension View {
    func mobileCameraCapture(isPresented: Binding<Bool>, tray: ComposerAttachmentTray?) -> some View {
        modifier(MobileCameraCapturePresentation(isPresented: isPresented, tray: tray))
    }
}

private struct MobileCameraCapturePresentation: ViewModifier {
    @Binding var isPresented: Bool
    let tray: ComposerAttachmentTray?
    @Environment(\.remoteTheme) private var theme

    func body(content: Content) -> some View {
        content.fullScreenCover(isPresented: $isPresented) {
            MobileCameraCapture { image in
                tray?.addCapturedImage(image)
            } onDismiss: {
                isPresented = false
            }
            .mobileTheme(theme)
        }
    }
}
