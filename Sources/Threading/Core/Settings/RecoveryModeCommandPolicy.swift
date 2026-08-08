import Foundation

// MARK: - Recovery Mode Command Policy

/// Which of the app's commands still work in recovery.
///
/// **Asked only about `AppCommand`s.** The menu bar also carries items that are not commands at
/// all — About, Bring All to Front, the Help entries, the extension commands — and those are
/// untouched by construction rather than by being listed here.
///
/// The platform's own group is allowed wholesale rather than enumerated: `AppCommand.Group.system`
/// is already the answer to "is this the platform's or ours", and a recovery mode that could ever
/// disable Quit or Copy is a worse failure than any it is trying to contain. What is left is a
/// short list of ours that still means something when nothing has been started.
///
/// A refused command reads as unavailable rather than beeping at an advertised chord, which is
/// the treatment `validateMenuItem` already gives a checkout-less Open In.
enum RecoveryModeCommandPolicy {

    /// Ours that survive.
    ///
    /// The sidebar is on screen and is the evidence somebody in a crash loop came for, so its
    /// toggle and its three arrangement switches stay — all four act on settings rather than on a
    /// session, and the density one already works without a window. Checking for updates stays
    /// because a new build is a legitimate fix for a crash loop, and refusing to look for one
    /// would be the app deciding it cannot be repaired.
    private static let allowedAppCommands: Set<String> = [
        AppCommands.ID.toggleSidebar,
        AppCommands.ID.groupByBranch,
        AppCommands.ID.loneBranchHeadings,
        AppCommands.ID.compactTree,
        AppCommands.ID.checkForUpdates
    ]

    static func allows(commandID: String) -> Bool {
        if allowedAppCommands.contains(commandID) { return true }
        return AppCommands.command(id: commandID)?.group == .system
    }

    /// Every command this build refuses, so a test asserts the shape of the answer rather than
    /// transcribing the list a second time.
    static var refusedCommandIDs: [String] {
        AppCommands.all.map(\.id).filter { !allows(commandID: $0) }
    }
}
