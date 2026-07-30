import ApplicationServices
import CoreGraphics
import Foundation
import UserNotifications

// MARK: - Status

/// Whether the OS currently lets Threading do one thing.
///
/// `askedWhenNeeded` is not an "unknown" fallback. Two of these grants have no API that reads
/// them without also requesting them, so probing one to fill in a status label would raise a
/// system prompt the user never asked for by opening a settings page. Saying plainly that the
/// grant is taken at the moment it is needed is worth more than a status that costs a prompt.
enum SystemPrivacyStatus: Equatable {
    case allowed
    case notAllowed
    case askedWhenNeeded

    /// The word shown beside the indicator. Status is never carried by colour alone.
    var label: String {
        switch self {
        case .allowed: return L10n.string("Allowed")
        case .notAllowed: return L10n.string("Not allowed")
        case .askedWhenNeeded: return L10n.string("Asked when needed")
        }
    }
}

// MARK: - Permissions

/// The OS grants Threading can hold, what each is for, and where the user changes it.
///
/// Worth stating in one place rather than at each call site, for two reasons.
///
/// TCC attributes a directly spawned child process to the responsible parent. A grant the user
/// gives Threading is therefore exercised by every agent CLI and companion executable it launches:
/// the entry that must be approved in System Settings says "Threading" even when the process
/// reading the file is Claude or Codex. That is the single most surprising thing about this
/// app's permissions and it had been written down nowhere.
///
/// And the grants differ in how they are obtained. Two are System Settings toggles the user
/// flips themselves, one is an in-app prompt, one arrives unannounced the first time a path is
/// touched. A screen that lists them without saying which is which teaches the wrong model.
enum SystemPrivacyPermission: String, CaseIterable, Sendable {
    case filesAndFolders
    case notifications
    case accessibility
    case screenRecording

    var title: String {
        switch self {
        case .filesAndFolders: return L10n.string("Files & Folders")
        case .notifications: return L10n.string("Notifications")
        case .accessibility: return L10n.string("Accessibility")
        case .screenRecording: return L10n.string("Screen Recording")
        }
    }

    var symbol: String {
        switch self {
        case .filesAndFolders: return "folder"
        case .notifications: return "bell"
        case .accessibility: return "figure.wave"
        case .screenRecording: return "rectangle.inset.filled.and.person.filled"
        }
    }

    /// Why Threading wants it, in the user's terms rather than the API's.
    var purpose: String {
        switch self {
        case .filesAndFolders:
            return L10n.string(
                "Agents read and edit the files in your projects. macOS asks separately for the "
                    + "Desktop, Documents and Downloads folders, and for external and network "
                    + "volumes — a project anywhere else needs no grant at all."
            )
        case .notifications:
            return L10n.string(
                "Tells you when a session finishes a turn or stops on an approval. Turn the "
                    + "feature off in General settings and this grant is never used."
            )
        case .accessibility:
            return L10n.string(
                "Only for an extension companion that controls the pointer or keyboard. "
                    + "Threading itself never asks for it."
            )
        case .screenRecording:
            return L10n.string(
                "Only for an extension companion that captures the screen. The built-in "
                    + "interface inspector draws from Threading's own view tree and needs nothing."
            )
        }
    }

    /// How the grant is actually obtained — the part a status word alone cannot convey.
    var howItIsGranted: String {
        switch self {
        case .filesAndFolders:
            return L10n.string(
                "macOS asks the first time a project in one of those locations is read."
            )
        case .notifications:
            return L10n.string("Threading asks the first time a session has something to say.")
        case .accessibility, .screenRecording:
            return L10n.string(
                "You allow Threading in System Settings, then reload the extension."
            )
        }
    }

    /// The System Settings pane that owns this grant.
    ///
    /// Notifications is not under Privacy & Security — it is its own settings extension — so
    /// this is a per-case URL rather than one base with an anchor appended.
    var settingsURL: URL? {
        switch self {
        case .filesAndFolders:
            return URL(string: Self.privacyPane + "Privacy_FilesAndFolders")
        case .notifications:
            return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        case .accessibility:
            return URL(string: Self.privacyPane + "Privacy_Accessibility")
        case .screenRecording:
            return URL(string: Self.privacyPane + "Privacy_ScreenCapture")
        }
    }

    /// Whether the grant can be read without requesting it. See `SystemPrivacyStatus`.
    var isStatusReadable: Bool {
        switch self {
        case .accessibility, .screenRecording, .notifications: return true
        case .filesAndFolders: return false
        }
    }

    private static let privacyPane = "x-apple.systempreferences:com.apple.preference.security?"
}

// MARK: - Reading

/// Reads the grants that can be read without prompting.
///
/// The system calls are injected for the same reason `SystemExtensionCompanionPermissionAuthorizer`
/// injects its own: a test must not report whatever the developer's machine happens to have
/// approved, and must never reach a real `UNUserNotificationCenter` on a test host.
struct SystemPrivacyStatusReader {

    private let accessibilityTrusted: () -> Bool
    private let screenRecordingAllowed: () -> Bool
    private let notificationStatus: (@escaping (SystemPrivacyStatus) -> Void) -> Void

    init(
        accessibilityTrusted: @escaping () -> Bool = {
            // Deliberately the option-free call: the prompting variant is used when a companion
            // needs the grant, never to populate a label.
            AXIsProcessTrusted()
        },
        screenRecordingAllowed: @escaping () -> Bool = {
            CGPreflightScreenCaptureAccess()
        },
        notificationStatus: @escaping (@escaping (SystemPrivacyStatus) -> Void) -> Void = {
            completion in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                completion(SystemPrivacyStatus(settings.authorizationStatus))
            }
        }
    ) {
        self.accessibilityTrusted = accessibilityTrusted
        self.screenRecordingAllowed = screenRecordingAllowed
        self.notificationStatus = notificationStatus
    }

    /// Every status at once, delivered on the main queue.
    ///
    /// One entry point rather than a synchronous accessor plus an asynchronous one: notification
    /// settings are only available through a callback, and a page that refreshed three rows
    /// immediately and a fourth a moment later would flicker on every appearance.
    func load(completion: @escaping ([SystemPrivacyPermission: SystemPrivacyStatus]) -> Void) {
        var statuses: [SystemPrivacyPermission: SystemPrivacyStatus] = [
            .filesAndFolders: .askedWhenNeeded,
            .accessibility: accessibilityTrusted() ? .allowed : .notAllowed,
            .screenRecording: screenRecordingAllowed() ? .allowed : .notAllowed
        ]

        notificationStatus { status in
            statuses[.notifications] = status
            if Thread.isMainThread {
                completion(statuses)
            } else {
                DispatchQueue.main.async { completion(statuses) }
            }
        }
    }
}

// MARK: - Mapping

extension SystemPrivacyStatus {

    /// `.provisional` delivers quietly rather than not at all, so it reads as allowed here; the
    /// distinction matters to the notification code, not to someone auditing what Threading can
    /// do. (`.ephemeral` is an App Clip state and does not exist on macOS.)
    init(_ authorization: UNAuthorizationStatus) {
        switch authorization {
        case .authorized, .provisional:
            self = .allowed
        case .denied:
            self = .notAllowed
        case .notDetermined:
            self = .askedWhenNeeded
        @unknown default:
            self = .askedWhenNeeded
        }
    }
}
