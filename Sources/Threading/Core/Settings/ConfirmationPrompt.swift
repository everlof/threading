import Foundation

// MARK: - Confirmation Prompt

/// Every question the app stops to ask, and — required of each — whether the user may switch
/// it off.
///
/// The register exists because the alternative is a reflex: another `NSAlert` with two buttons,
/// no decision about whether the interruption was earned, and no way to stop it. `policy` below
/// is an exhaustive `switch` with no `default:` and no defaulted value, so a case added here
/// does not compile until somebody has answered the question — and the answer is a type rather
/// than a `Bool`, because a `Bool` records which way it went and not that anyone chose.
/// `.suppressible` has to carry the Settings row that turns the prompt back on, so a prompt
/// cannot be silenced with nowhere to un-silence it; `.alwaysAsks` has to name *which* kind of
/// irrevocability it is claiming, and that name is what decides whether Return activates the
/// action or Cancel.
///
/// Raw values are the stored suppressed set and must not be renamed: a rename un-suppresses a
/// prompt somebody switched off, which reads as the setting having been ignored — which is why
/// `ConfirmationPromptTests` holds them to a written-down list rather than asking nicely in a
/// comment. Moving a case the other way — `.suppressible` to `.alwaysAsks` — is the more
/// dangerous edit, and `AppSettings.asks(before:)` is what covers it: it consults the policy
/// rather than the stored set alone, so a stale raw value cannot keep a newly non-negotiable
/// prompt silent.
///
/// Applicability is deliberately *not* policy and stays at the call site. The lifecycle prompts
/// also require `AgentRuntime.isRunning`: a dormant session has nothing to interrupt, which is a
/// fact about the session rather than a preference about the prompt.
enum ConfirmationPrompt: String, CaseIterable {

    // MARK: Session lifecycle

    // Prompts that were one switch. Each interrupts a running agent and each is recoverable —
    // the conversation survives all of them — which is what makes them the repetitive ones
    // worth being able to switch off.
    //
    // **Archiving is deliberately not among them any more**, and the case was removed rather
    // than left switched off: it is the one action here whose whole effect can be put back by
    // pressing something, so it acts, reports, and offers an undo instead of asking first
    // (`SessionCoordinator.archiveToast`). A prompt is right where the way back is a *different*
    // action the user would have to know to take; it is wrong where the way back can be handed
    // to them. Anything added below should be read against that line before it earns a case.

    case closeRunningSession
    case moveRunningSessionToAccount
    case continueRunningSessionWithAnotherProvider
    case switchRunningSessionSurface

    /// What to do about a repair an agent proposes for a broken conversation. Not a lifecycle
    /// prompt — nothing is running — but it belongs beside them because the subject is one
    /// session and the answer changes what that session is.
    case conversationRepairOutcome

    // MARK: Recoverable elsewhere

    case quitWithRunningAgents
    /// The same moment, asked differently: `threading-ptyd` is holding sessions, so quitting is a
    /// choice between two quits rather than a confirmation of one. Its own case because a choice
    /// cannot be suppressible — see `.policy` below and `ConfirmationAlert.choose`.
    case quitWithBackgroundSessions
    case removeExtension
    case revokeAllWebsiteAccess
    case revokeAllManagerRoles
    case storeTestCredential

    // MARK: Irreversible

    case removeProject
    case revokeChatAccess
    case revokePairedDevice
    case deleteHostedServiceAccount
    // Both change what a paired phone trusts. A reset unpairs every device that did not hear
    // the announcement; activating a rotation unpairs only the devices that have not connected
    // since one was announced. Neither can be undone by pressing anything here — the way back
    // is on the other device, with a camera.
    case resetRemoteAccessIdentity
    case activateRemoteAccessIdentityRotation
    case deleteSession
    case deleteArchivedSession
    case deleteAppTheme
    case deleteTerminalTheme
    case removeBrowserBaseline
    case removeReclaimableDirectories
    case approveAgentStorageCleanup
    case resetAppData
    case clearBrowserWebsiteData
    case runDestructiveExtensionCommand
    case runProjectScript
    case stopSessionProcess
    case takeOverSingleInstanceLock
    case endOrphanedAgentProcesses

    // MARK: Security grants

    case grantBrowserOriginAccess
    case approveSensitiveBrowserAction
    case approveToolPermission
    case approveSessionCheckoutMove
    case installUnsignedExtension
    case updateExtensionCapabilities
    case approveAgentExtensionInstall
    case shareChatLink
    case approveSystemPermissionPrompt
    case conferManagerRole
    case controlSimulatorDevice
    case linkDeviceLogTap
    case runNativePlugin

    // MARK: Software updates

    case installUpdate
    case installUpdateAndRelaunch

    // MARK: - Policy

    enum Policy {

        /// Switchable off, and the payload is the row that switches it back on.
        case suppressible(Suppression)

        /// Asked every time, and the reason says what makes that non-negotiable.
        case alwaysAsks(Reason)

        /// The Settings ▸ General row. Carried in the case rather than computed beside it,
        /// because an optional computed title can be `nil` and a payload cannot be absent —
        /// a suppressible prompt with no row is a switch the user cannot find.
        struct Suppression {
            let settingsTitle: String
            let settingsSubtitle: String
        }

        enum Reason {

            /// Nothing brings it back. Return activates Cancel and the action is marked
            /// destructive — the rule `ExtensionCommandInvoker` already applied by hand to
            /// exactly one alert, stated once for all of them. The chord that dismisses a
            /// dialog must not also be the one that deletes.
            case irreversible

            /// It hands something outside Threading a capability it did not have: a website, a
            /// tool call, an unreviewed extension, another person. Return deliberately stays
            /// on the affirmative button, unlike the branch above — the agent is blocked while
            /// the sheet is up, approving is the common answer, and every grant here is scoped
            /// and revocable from Settings. What must never happen is the *grant* becoming
            /// invisible, which is exactly what a "Don't ask again" box on this branch is.
            case securityGrant

            /// The question is new each time it appears: a software update names a version
            /// that did not exist when the last answer was given, so a remembered answer
            /// would approve something sight unseen — which is automatic installation, a
            /// capability this app deliberately does not offer (`AppUpdater.apply`). Return
            /// stays on the affirmative: nothing on this branch is destructive, and declining
            /// is one Escape away.
            case newQuestionEachTime
        }
    }

    /// No default and no `default:` — this switch is the whole point of the file. Adding a case
    /// above breaks the build here, which is the only moment anyone is guaranteed to be
    /// thinking about the question.
    var policy: Policy {
        switch self {

        case .closeRunningSession:
            return .suppressible(Policy.Suppression(
                settingsTitle: L10n.string("Ask before closing a running session"),
                settingsSubtitle: L10n.string(
                    "Closing ends the agent and keeps the session in the sidebar to resume."
                )
            ))

        case .moveRunningSessionToAccount:
            return .suppressible(Policy.Suppression(
                settingsTitle: L10n.string("Ask before moving a running chat to another account"),
                settingsSubtitle: L10n.string(
                    "The agent restarts under the other account and resumes the conversation. "
                        + "Anything it is working on right now is interrupted."
                )
            ))

        case .continueRunningSessionWithAnotherProvider:
            return .suppressible(Policy.Suppression(
                settingsTitle: L10n.string(
                    "Ask before continuing a running chat with another provider"
                ),
                settingsSubtitle: L10n.string(
                    "The current agent stops. A new session receives a read-only snapshot, "
                        + "while the original conversation stays resumable."
                )
            ))

        case .switchRunningSessionSurface:
            return .suppressible(Policy.Suppression(
                settingsTitle: L10n.string("Ask before switching a running chat's interface"),
                settingsSubtitle: L10n.string(
                    "The agent restarts on the other surface and resumes the conversation. "
                        + "Anything it is working on right now is interrupted."
                )
            ))

        case .quitWithRunningAgents:
            return .suppressible(Policy.Suppression(
                settingsTitle: L10n.string("Ask before quitting with agents running"),
                settingsSubtitle: L10n.string(
                    "Quitting ends every running agent. The conversations are kept and resume "
                        + "on the next launch; only the turn in flight is lost."
                )
            ))

        case .removeExtension:
            return .suppressible(Policy.Suppression(
                settingsTitle: L10n.string("Ask before removing an extension"),
                settingsSubtitle: L10n.string(
                    "The package moves to Threading's recoverable Removed directory rather than "
                        + "being deleted."
                )
            ))

        case .revokeAllWebsiteAccess:
            return .suppressible(Policy.Suppression(
                settingsTitle: L10n.string("Ask before revoking all website access"),
                settingsSubtitle: L10n.string(
                    "Agents have to ask for each site again. Nothing you own is lost."
                )
            ))

        case .removeProject,
             // Not "irreversible" because the person is gone forever — it is that the way back
             // is a *different* action the owner has to know to take. Their invitation was
             // single-use, so the link they hold is spent: letting them back in means sharing
             // the chat again and getting the new link to them. Return therefore belongs on
             // Cancel, next to a Revoke button sitting inches from a name.
             .revokeChatAccess,
             // Re-pairing is possible, but only by scanning a new one-time owner code. Treat
             // revocation like the corresponding guest action: Return belongs on Cancel.
             .revokePairedDevice,
             .deleteHostedServiceAccount,
             .resetRemoteAccessIdentity,
             .activateRemoteAccessIdentityRotation,
             .deleteSession,
             .deleteArchivedSession,
             .deleteAppTheme,
             .deleteTerminalTheme,
             .removeBrowserBaseline,
             .removeReclaimableDirectories,
             .approveAgentStorageCleanup,
             .clearBrowserWebsiteData,
             .runDestructiveExtensionCommand,
             .runProjectScript,
             // A SIGTERM'd process can be started again, but not from anything in the app —
             // the way back is the agent's or the user's own next command — so the alert
             // behaves as though nothing brings it back: Return on Cancel, the verb on a
             // destructive button.
             .stopSessionProcess,
             // The other instance is ended outright and whatever it had in flight goes with
             // it, so nothing in the app brings it back — and this is the one prompt the user
             // meets before there is an app to bring anything back *in*. It can never be
             // switched off for the same reason `approveSystemPermissionPrompt` cannot:
             // suppressed, it would silently kill a running Threading on every launch that
             // found a slow one.
             .takeOverSingleInstanceLock,
             // The agent processes a crashed launch left behind, ended so the lock descriptor
             // they inherited is released. Each is verified on its recorded identity first, and
             // each is somebody's conversation: whatever it was mid-turn on is gone. It sits on
             // the same branch as the takeover above and for the same reason.
             .endOrphanedAgentProcesses,
             // Regranting authority is possible, but the complete supervision graph this
             // operation closes has no one-step restore in the app. Default to Cancel like
             // the other broad removals whose recovery requires rebuilding state by hand.
             .revokeAllManagerRoles,
             // A reset keeps what it took, in a dated folder — but restoring it means quitting
             // and dragging directories back, so nothing in the app brings it back and the
             // alert must behave as though nothing does. It also restarts the app under the
             // user, which is the other reason Return belongs on Cancel here.
             .resetAppData:
            return .alwaysAsks(.irreversible)

        case .grantBrowserOriginAccess,
             .approveSensitiveBrowserAction,
             .approveToolPermission,
             .approveSessionCheckoutMove,
             .installUnsignedExtension,
             .updateExtensionCapabilities,
             .approveAgentExtensionInstall,
             .shareChatLink,
             .conferManagerRole,
             .controlSimulatorDevice,
             // Linking the log tap gives an app's output a capability it did not have: whatever
             // it prints stops being ephemeral and is published into the device's unified log,
             // where it persists and leaves in a sysdiagnose or a log archive. Rebuilding without
             // the tap stops new lines; it cannot unwrite the ones already there.
             .linkDeviceLogTap,
             // Approving a plugin is the moment arbitrary code gains the right to run inside
             // Threading, unsandboxed, with the files and permissions the user granted the app.
             // Nothing about it is reversible by removing a file afterwards, and it is the one
             // grant where a suppressed prompt would mean a folder became an install path.
             .runNativePlugin,
             // Storing a test credential is the moment an origin gains the right to be signed
             // in to unattended, so it belongs with the other grants rather than with the
             // reversible edits: removing the entry later does not un-ring whatever an agent
             // did with it. It is scoped to one origin and revocable in Settings ▸ Tools,
             // which is exactly the shape this branch describes.
             .storeTestCredential,
             // The capability here is macOS's to give, not Threading's — but the thing being
             // handed out is the same: a program gets to reach past the app for something the
             // user has not agreed to yet. It cannot be switched off for a reason the other
             // grants only share by choice: switching it off would restore the unexplained
             // system dialog, which is the bug rather than the quieter setting.
             .approveSystemPermissionPrompt:
            return .alwaysAsks(.securityGrant)

        case .installUpdate, .installUpdateAndRelaunch:
            return .alwaysAsks(.newQuestionEachTime)

        // Two different quits, and a remembered answer would have to be one of them. The sibling
        // above *is* suppressible, because "quit anyway" is a single answer worth remembering;
        // this question names a set of agents that did not exist when the last answer was given
        // and asks which of them should go on working, which is a new question every time — the
        // same reason an update's version makes its prompt new. The user's switch on the sibling
        // is still honoured, at the call site, and it resolves to the recoverable answer: nothing
        // is stopped without somebody asking for it. Return stays on the affirmative, and the
        // affirmative here is the one that destroys nothing.
        case .quitWithBackgroundSessions:
            return .alwaysAsks(.newQuestionEachTime)

        // Each repair is a different agent's account of a different broken conversation, and the
        // decision is about *that* account — what it says it found, what it says it changed.
        // There is no answer to remember: a box saying "always accept what an agent proposes
        // about my conversations" is the setting this deliberately cannot have.
        case .conversationRepairOutcome:
            return .alwaysAsks(.newQuestionEachTime)
        }
    }

    // MARK: - Derived

    /// The settings row, when there is one. `nil` is the type-level statement that this prompt
    /// cannot be switched off, and it is what `AppSettings` and `ConfirmationAlert` both read
    /// rather than re-deriving the distinction.
    var suppression: Policy.Suppression? {
        switch policy {
        case .suppressible(let suppression): return suppression
        case .alwaysAsks: return nil
        }
    }

    /// Whether Return activates Cancel rather than the action.
    var defaultsToCancel: Bool {
        switch policy {
        case .alwaysAsks(.irreversible): return true
        case .alwaysAsks(.securityGrant), .alwaysAsks(.newQuestionEachTime), .suppressible:
            return false
        }
    }

    /// Declaration order, which is the order the Confirmations card takes: the lifecycle
    /// prompts that were one switch, then the ones that joined them.
    static var suppressible: [ConfirmationPrompt] {
        allCases.filter { $0.suppression != nil }
    }

    /// What the single `confirmsBeforeClosingRunningSession` switch became. Listed here rather
    /// than inside the migration so the two cannot drift — a lifecycle prompt added to or taken
    /// off this list is a deliberate edit next to the cases it names. Archiving was here until
    /// it stopped asking altogether; a user who had switched the old bool off simply carries
    /// that answer onto the prompts that still exist.
    static let closingConfirmationSuccessors: [ConfirmationPrompt] = [
        .closeRunningSession,
        .moveRunningSessionToAccount,
        .switchRunningSessionSurface
    ]
}
