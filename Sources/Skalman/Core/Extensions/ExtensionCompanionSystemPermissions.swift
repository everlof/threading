import ApplicationServices
import CoreGraphics
import Foundation
import SkalmanExtensionKit

enum ExtensionCompanionSystemPermissionError: LocalizedError {
    case screenCaptureDenied
    case inputControlDenied

    var errorDescription: String? {
        switch self {
        case .screenCaptureDenied:
            return "Screen Recording is not allowed. macOS attributes a directly supervised "
                + "companion to Skalman, so allow Skalman in System Settings → Privacy & "
                + "Security → Screen & System Audio Recording, then reload the extension."
        case .inputControlDenied:
            return "Accessibility is not allowed. macOS attributes a directly supervised "
                + "companion to Skalman, so allow Skalman in System Settings → Privacy & "
                + "Security → Accessibility, then reload the extension."
        }
    }
}

/// Requests only the OS grants represented by a companion's reviewed capability set.
///
/// App Sandbox entitlements remain attached to the separately signed companion. TCC makes a
/// different decision for a process directly spawned and supervised by an app: Screen Recording
/// and Accessibility are attributed to the responsible parent. Keeping that policy explicit at
/// the host boundary avoids a child attempting an unpromptable request and makes the Settings
/// entry the user must approve match the diagnostic they see.
@MainActor
protocol ExtensionCompanionSystemPermissionAuthorizing {
    func authorize(
        capabilities: Set<ExtensionCompanionCapability>
    ) throws
}

struct SystemExtensionCompanionPermissionAuthorizer:
    ExtensionCompanionSystemPermissionAuthorizing
{
    private let screenCapturePreflight: () -> Bool
    private let screenCaptureRequest: () -> Bool
    private let accessibilityRequest: () -> Bool

    init(
        screenCapturePreflight: @escaping () -> Bool = {
            CGPreflightScreenCaptureAccess()
        },
        screenCaptureRequest: @escaping () -> Bool = {
            CGRequestScreenCaptureAccess()
        },
        accessibilityRequest: @escaping () -> Bool = {
            let options = [
                kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
            ] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }
    ) {
        self.screenCapturePreflight = screenCapturePreflight
        self.screenCaptureRequest = screenCaptureRequest
        self.accessibilityRequest = accessibilityRequest
    }

    func authorize(
        capabilities: Set<ExtensionCompanionCapability>
    ) throws {
        if capabilities.contains(.screenCapture),
           !screenCapturePreflight(),
           !screenCaptureRequest() {
            throw ExtensionCompanionSystemPermissionError.screenCaptureDenied
        }

        if capabilities.contains(.inputControl),
           !accessibilityRequest() {
            throw ExtensionCompanionSystemPermissionError.inputControlDenied
        }
    }
}
