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
/// Applicability is deliberately *not* policy and stays at the call site. The four lifecycle
/// prompts also require `AgentRuntime.isRunning`: a dormant session has nothing to interrupt,
/// which is a fact about the session rather than a preference about the prompt.
enum ConfirmationPrompt: String, CaseIterable {

    // MARK: Session lifecycle

    // Four prompts that were one switch. Each interrupts a running agent and each is
    // recoverable — the conversation survives all four — which is what makes them the
    // repetitive ones worth being able to switch off.

    case closeRunningSession
    case archiveRunningSession
    case moveRunningSessionToAccount
    case continueRunningSessionWithAnotherProvider
    case switchRunningSessionSurface

    // MARK: Recoverable elsewhere

    case quitWithRunningAgents
    case removeExtension
    case revokeAllWebsiteAccess

    // MARK: Irreversible

    case removeProject
    case deleteSession
    case deleteArchivedSession
    case deleteAppTheme
    case deleteTerminalTheme
    case removeReclaimableDirectories
    case approveAgentStorageCleanup
    case resetAppData
    case clearBrowserWebsiteData
    case runDestructiveExtensionCommand

    // MARK: Security grants

    case grantBrowserOriginAccess
    case approveSensitiveBrowserAction
    case approveToolPermission
    case installUnsignedExtension
    case updateExtensionCapabilities
    case approveAgentExtensionInstall
    case shareChatLink

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

        case .archiveRunningSession:
            return .suppressible(Policy.Suppression(
                settingsTitle: L10n.string("Ask before archiving a running session"),
                settingsSubtitle: L10n.string(
                    "Archiving ends the agent and moves the session into Settings ▸ Archived, "
                        + "where it can be restored."
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
             .deleteSession,
             .deleteArchivedSession,
             .deleteAppTheme,
             .deleteTerminalTheme,
             .removeReclaimableDirectories,
             .approveAgentStorageCleanup,
             .clearBrowserWebsiteData,
             .runDestructiveExtensionCommand,
             // A reset keeps what it took, in a dated folder — but restoring it means quitting
             // and dragging directories back, so nothing in the app brings it back and the
             // alert must behave as though nothing does. It also restarts the app under the
             // user, which is the other reason Return belongs on Cancel here.
             .resetAppData:
            return .alwaysAsks(.irreversible)

        case .grantBrowserOriginAccess,
             .approveSensitiveBrowserAction,
             .approveToolPermission,
             .installUnsignedExtension,
             .updateExtensionCapabilities,
             .approveAgentExtensionInstall,
             .shareChatLink:
            return .alwaysAsks(.securityGrant)
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
        case .alwaysAsks(.securityGrant), .suppressible: return false
        }
    }

    /// Declaration order, which is the order the Confirmations card takes: the four that were
    /// one switch, then the two that joined them.
    static var suppressible: [ConfirmationPrompt] {
        allCases.filter { $0.suppression != nil }
    }

    /// What the single `confirmsBeforeClosingRunningSession` switch became. Listed here rather
    /// than inside the migration so the two cannot drift — a fifth lifecycle prompt added to
    /// this list is a deliberate edit next to the cases it names.
    static let closingConfirmationSuccessors: [ConfirmationPrompt] = [
        .closeRunningSession,
        .archiveRunningSession,
        .moveRunningSessionToAccount,
        .switchRunningSessionSurface
    ]
}
