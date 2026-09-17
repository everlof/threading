import Foundation

/// Which of Threading's tools reach an agent running on a remote execution host.
///
/// A remote agent's tool calls cross back to this Mac through the forwarded bridge socket, and the
/// app executes them here. That is exactly right for a tool whose inputs are all in the call — a
/// chart, a web page, a session's name — and wrong for one that reads or writes a *path*, because
/// the path the agent names is on its host, and this Mac would resolve it against its own disk:
/// at best a missing file, at worst a different file that happens to live at the same path. So a
/// remote session is offered only the tools answered **true** here, and the same answer gates every
/// call (`MCPToolCatalog.definitions(for:)` and `admits(_:for:)` both read it).
///
/// The switch is exhaustive on purpose: a new built-in does not compile until someone decides
/// whether it can reach a remote host. Extension-provided tools never do, because nothing about
/// their arguments is known. See `docs/feature-drafts/remote-execution-hosts.md`, slice 4.
enum MCPRemoteSessionToolScope {

    static func reaches(_ tool: MCPBuiltInTool) -> Bool {
        switch tool {
        // Inputs carried whole in the call, drawn in this Mac's panel.
        case .displayChart, .displayScene, .displayHTML:
            return true
        // A path the agent names is a path on its host.
        case .displayImage, .displayCompareFiles, .videoFrames:
            return false

        case .conversationHistory:
            return true

        // The browser opens http and https only (`BrowserAccessPolicy`), so a page is the same
        // page wherever the agent runs. `localhost` is this Mac's, which the instructions say.
        case .browserNavigate, .browserHistory, .browserStop, .browserTabs, .browserStorage,
             .browserResize, .browserEmulate, .browserCapabilities, .browserSnapshot,
             .browserAnnotations, .browserScreenshot, .browserVisualCompare, .browserBaselines,
             .browserQuery, .browserClick, .browserHover, .browserDrag, .browserType,
             .browserFillForm, .browserFillCredentials, .browserSelect, .browserSetChecked,
             .browserPressKey, .browserScroll, .browserWait, .browserConsole, .browserNetwork,
             .browserPerformance, .browserAccessibilityAudit:
            return true
        // Each moves a file across this Mac's disk, or attaches to one of its processes.
        case .browserUpload, .browserDownload, .browserTrace, .browserRunIsolated, .browserAttachChrome:
            return false

        // A simulator and a device log are this Mac's; an app a Linux host built cannot be
        // installed on either, and there is nothing to inspect without one.
        case .deviceLogPrepare, .simulatorPrepare, .simulatorInstallLaunch, .simulatorScreenshot,
             .simulatorSnapshot, .simulatorAnnotations, .simulatorWait, .simulatorTap, .simulatorSwipe,
             .simulatorTypeText, .simulatorPressButton, .listIOSDiagnosticDevices, .inspectIOSDiagnostics:
            return false

        case .panelListTabs, .panelActivateTab:
            return true

        // A checkout, a worktree and a project icon are files on this Mac.
        case .setProjectIcon, .setSessionCheckout, .createSessionWorktree, .cancelSessionCheckoutMove:
            return false

        case .archiveSession, .cancelSessionArchive, .setSessionName:
            return true

        case .listSessions, .sendToSession, .watchSession:
            return true

        // Supervision starts, moves and costs sessions by reading and launching on this Mac.
        case .listAccounts, .sessionCost, .resumeSession, .spawnSession, .moveSessionToAccount,
             .finishWorkspace, .adoptSession, .releaseSession, .subscribeToChildren, .respondToPermission:
            return false

        case .listReclaimableStorage, .suggestReclaimableLocation, .proposeStorageCleanup,
             .proposeConversationRepair:
            return false

        case .listTriggerSources, .listTriggers, .listTriggerRuns, .createTriggerDraft,
             .proposeTriggerActivation, .reportTriggerAssessment, .reportTriggerResult:
            return false

        case .listSettings, .notifyUser, .copyToClipboard:
            return true

        case .listThemes, .setTheme, .createTheme, .listAppThemes, .getAppTheme, .setAppTheme,
             .createAppTheme, .duplicateAppTheme, .updateAppTheme:
            return true

        case .extensionListComponents, .extensionScaffoldProject, .extensionProposeInstall,
             .extensionDescribeComponent, .extensionValidateComponentPatch,
             .extensionPreviewComponentPatch:
            return false
        }
    }

    /// Appended to a remote session's server instructions. Written for the model, like the rest
    /// of them: what is different, and what to do about it.
    static let instructions = """
        This session runs on a remote host, and Threading's tools run on the user's Mac. Pass \
        content, not file paths: a path on this host means nothing there. The browser's \
        localhost is the Mac's, not this host's. Tools that need files on the Mac are not \
        offered.
        """

    static func reaches(toolNamed name: String) -> Bool {
        guard let tool = MCPBuiltInTool(rawValue: name) else { return false }
        return reaches(tool)
    }

    @MainActor
    static func isRemote(_ sessionID: SessionID) -> Bool {
        ProjectStore.shared.sessionRunsOnRemoteHost(sessionID)
    }
}
