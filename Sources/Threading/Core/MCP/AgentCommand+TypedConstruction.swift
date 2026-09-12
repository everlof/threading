import Foundation

/// Source-level construction conveniences for callers that already hold typed arguments.
///
/// Every method round-trips through the authoritative declaration decoder. These are not
/// registrations and carry no schema, routing, catalogue, or annotation metadata.
extension AgentCommand {
  private static func builtIn<Arguments: Encodable & Sendable>(
    _ tool: MCPBuiltInTool,
    _ arguments: Arguments
  ) -> AgentCommand {
    do {
      return try MCPBuiltInToolRegistry.command(for: tool, arguments: arguments)
    } catch {
      preconditionFailure("Could not construct \(tool.rawValue): \(error)")
    }
  }

  static func displayImage(_ value: DisplayImageArguments) -> Self { builtIn(.displayImage, value) }
  static func displayChart(_ value: DisplayChartArguments) -> Self { builtIn(.displayChart, value) }
  static func displayScene(_ value: DisplaySceneArguments) -> Self { builtIn(.displayScene, value) }
  static func displayHTML(_ value: DisplayHTMLArguments) -> Self { builtIn(.displayHTML, value) }
  static func displayCompareFiles(_ value: DisplayCompareFilesArguments) -> Self {
    builtIn(.displayCompareFiles, value)
  }
  static func conversationHistory(_ value: ConversationHistoryArguments) -> Self {
    builtIn(.conversationHistory, value)
  }
  static func browserNavigate(_ value: BrowserNavigateArguments) -> Self {
    builtIn(.browserNavigate, value)
  }
  static func browserHistory(_ value: BrowserHistoryArguments) -> Self {
    builtIn(.browserHistory, value)
  }
  static func browserStop(_ value: EmptyToolArguments) -> Self { builtIn(.browserStop, value) }
  static func browserTabs(_ value: BrowserTabsArguments) -> Self { builtIn(.browserTabs, value) }
  static func browserStorage(_ value: BrowserStorageArguments) -> Self {
    builtIn(.browserStorage, value)
  }
  static func browserTrace(_ value: BrowserTraceArguments) -> Self { builtIn(.browserTrace, value) }
  static func browserUpload(_ value: BrowserUploadArguments) -> Self {
    builtIn(.browserUpload, value)
  }
  static func browserDownload(_ value: BrowserDownloadArguments) -> Self {
    builtIn(.browserDownload, value)
  }
  static func browserResize(_ value: BrowserResizeArguments) -> Self {
    builtIn(.browserResize, value)
  }
  static func browserEmulate(_ value: BrowserEmulateArguments) -> Self {
    builtIn(.browserEmulate, value)
  }
  static func browserCapabilities(_ value: EmptyToolArguments) -> Self {
    builtIn(.browserCapabilities, value)
  }
  static func browserRunIsolated(_ value: BrowserIsolatedRunArguments) -> Self {
    builtIn(.browserRunIsolated, value)
  }
  static func browserAttachChrome(_ value: BrowserAttachRunArguments) -> Self {
    builtIn(.browserAttachChrome, value)
  }
  static func browserSnapshot(_ value: BrowserSnapshotArguments) -> Self {
    builtIn(.browserSnapshot, value)
  }
  static func browserAnnotations(_ value: EmptyToolArguments) -> Self {
    builtIn(.browserAnnotations, value)
  }
  static func browserScreenshot(_ value: BrowserScreenshotArguments) -> Self {
    builtIn(.browserScreenshot, value)
  }
  static func browserVisualCompare(_ value: BrowserVisualCompareArguments) -> Self {
    builtIn(.browserVisualCompare, value)
  }
  static func browserBaselines(_ value: BrowserBaselinesArguments) -> Self {
    builtIn(.browserBaselines, value)
  }
  static func browserQuery(_ value: BrowserSelectorArguments) -> Self {
    builtIn(.browserQuery, value)
  }
  static func browserClick(_ value: BrowserClickArguments) -> Self { builtIn(.browserClick, value) }
  static func browserHover(_ value: BrowserTargetArguments) -> Self { builtIn(.browserHover, value) }
  static func browserDrag(_ value: BrowserDragArguments) -> Self { builtIn(.browserDrag, value) }
  static func browserType(_ value: BrowserTypeArguments) -> Self { builtIn(.browserType, value) }
  static func browserFillForm(_ value: BrowserFillFormArguments) -> Self {
    builtIn(.browserFillForm, value)
  }
  static func browserFillCredentials(_ value: BrowserFillCredentialsArguments) -> Self {
    builtIn(.browserFillCredentials, value)
  }
  static func browserSelect(_ value: BrowserSelectArguments) -> Self {
    builtIn(.browserSelect, value)
  }
  static func browserSetChecked(_ value: BrowserSetCheckedArguments) -> Self {
    builtIn(.browserSetChecked, value)
  }
  static func browserPressKey(_ value: BrowserKeyArguments) -> Self {
    builtIn(.browserPressKey, value)
  }
  static func browserScroll(_ value: BrowserScrollArguments) -> Self {
    builtIn(.browserScroll, value)
  }
  static func browserWait(_ value: BrowserWaitArguments) -> Self { builtIn(.browserWait, value) }
  static func browserConsole(_ value: BrowserConsoleArguments) -> Self {
    builtIn(.browserConsole, value)
  }
  static func browserNetwork(_ value: BrowserNetworkArguments) -> Self {
    builtIn(.browserNetwork, value)
  }
  static func browserPerformance(_ value: BrowserPerformanceArguments) -> Self {
    builtIn(.browserPerformance, value)
  }
  static func browserAccessibilityAudit(_ value: BrowserAccessibilityAuditArguments) -> Self {
    builtIn(.browserAccessibilityAudit, value)
  }
  static func simulatorPrepare(_ value: SimulatorPrepareArguments) -> Self {
    builtIn(.simulatorPrepare, value)
  }
  static func simulatorInstallLaunch(_ value: SimulatorInstallLaunchArguments) -> Self {
    builtIn(.simulatorInstallLaunch, value)
  }
  static func simulatorScreenshot(_ value: SimulatorScreenshotArguments) -> Self {
    builtIn(.simulatorScreenshot, value)
  }
  static func simulatorTap(_ value: SimulatorTapArguments) -> Self {
    builtIn(.simulatorTap, value)
  }
  static func simulatorSwipe(_ value: SimulatorSwipeArguments) -> Self {
    builtIn(.simulatorSwipe, value)
  }
  static func simulatorTypeText(_ value: SimulatorTypeTextArguments) -> Self {
    builtIn(.simulatorTypeText, value)
  }
  static func simulatorPressButton(_ value: SimulatorPressButtonArguments) -> Self {
    builtIn(.simulatorPressButton, value)
  }
  static func panelListTabs(_ value: EmptyToolArguments) -> Self { builtIn(.panelListTabs, value) }
  static func panelActivateTab(_ value: PanelActivateTabArguments) -> Self {
    builtIn(.panelActivateTab, value)
  }
  static func setProjectIcon(_ value: SetProjectIconArguments) -> Self {
    builtIn(.setProjectIcon, value)
  }
  static func setSessionCheckout(_ value: SetSessionCheckoutArguments) -> Self {
    builtIn(.setSessionCheckout, value)
  }
  static func cancelSessionCheckoutMove(_ value: EmptyToolArguments = .init()) -> Self {
    builtIn(.cancelSessionCheckoutMove, value)
  }
  static func archiveSession(_ value: ArchiveSessionArguments) -> Self {
    builtIn(.archiveSession, value)
  }
  static func cancelSessionArchive(_ value: CancelSessionArchiveArguments) -> Self {
    builtIn(.cancelSessionArchive, value)
  }
  static func setSessionName(_ value: SetSessionNameArguments) -> Self {
    builtIn(.setSessionName, value)
  }
  static func listSessions(_ value: EmptyToolArguments) -> Self { builtIn(.listSessions, value) }
  static func sendToSession(_ value: SendToSessionArguments) -> Self {
    builtIn(.sendToSession, value)
  }
  static func watchSession(_ value: WatchSessionArguments) -> Self { builtIn(.watchSession, value) }
  static func listAccounts(_ value: ListAccountsArguments) -> Self { builtIn(.listAccounts, value) }
  static func sessionCost(_ value: SessionCostArguments) -> Self { builtIn(.sessionCost, value) }
  static func resumeSession(_ value: ResumeSessionArguments) -> Self { builtIn(.resumeSession, value) }
  static func spawnSession(_ value: SpawnSessionArguments) -> Self { builtIn(.spawnSession, value) }
  static func moveSessionToAccount(_ value: MoveSessionToAccountArguments) -> Self {
    builtIn(.moveSessionToAccount, value)
  }
  static func finishWorkspace(_ value: SessionReferenceArguments) -> Self {
    builtIn(.finishWorkspace, value)
  }
  static func adoptSession(_ value: AdoptSessionArguments) -> Self { builtIn(.adoptSession, value) }
  static func releaseSession(_ value: ReleaseSessionArguments) -> Self {
    builtIn(.releaseSession, value)
  }
  static func subscribeToChildren(_ value: SubscribeToChildrenArguments) -> Self {
    builtIn(.subscribeToChildren, value)
  }
  static func respondToPermission(_ value: RespondToPermissionArguments) -> Self {
    builtIn(.respondToPermission, value)
  }
  static func listReclaimableStorage(_ value: EmptyToolArguments) -> Self {
    builtIn(.listReclaimableStorage, value)
  }
  static func suggestReclaimableLocation(_ value: SuggestReclaimableLocationArguments) -> Self {
    builtIn(.suggestReclaimableLocation, value)
  }

  static func proposeStorageCleanup(_ value: StorageCleanupArguments) -> Self {
    builtIn(.proposeStorageCleanup, value)
  }
  static func listTriggerSources(_ value: EmptyToolArguments = .init()) -> Self {
    builtIn(.listTriggerSources, value)
  }
  static func listTriggers(_ value: EmptyToolArguments = .init()) -> Self {
    builtIn(.listTriggers, value)
  }
  static func listTriggerRuns(_ value: TriggerReferenceArguments) -> Self {
    builtIn(.listTriggerRuns, value)
  }
  static func createTriggerDraft(_ value: CreateTriggerDraftArguments) -> Self {
    builtIn(.createTriggerDraft, value)
  }
  static func proposeTriggerActivation(_ value: TriggerReferenceArguments) -> Self {
    builtIn(.proposeTriggerActivation, value)
  }
  static func reportTriggerAssessment(_ value: ReportTriggerAssessmentArguments) -> Self {
    builtIn(.reportTriggerAssessment, value)
  }
  static func reportTriggerResult(_ value: ReportTriggerResultArguments) -> Self {
    builtIn(.reportTriggerResult, value)
  }
  static func listSettings(_ value: EmptyToolArguments) -> Self { builtIn(.listSettings, value) }
  static func notifyUser(_ value: NotifyUserArguments) -> Self { builtIn(.notifyUser, value) }
  static func listThemes(_ value: ListThemesArguments) -> Self { builtIn(.listThemes, value) }
  static func setTheme(_ value: SetThemeArguments) -> Self { builtIn(.setTheme, value) }
  static func createTheme(_ value: CreateThemeArguments) -> Self { builtIn(.createTheme, value) }
  static func listAppThemes(_ value: EmptyToolArguments) -> Self { builtIn(.listAppThemes, value) }
  static func getAppTheme(_ value: AppThemeReferenceArguments) -> Self {
    builtIn(.getAppTheme, value)
  }
  static func setAppTheme(_ value: SetAppThemeArguments) -> Self { builtIn(.setAppTheme, value) }
  static func createAppTheme(_ value: CreateAppThemeArguments) -> Self {
    builtIn(.createAppTheme, value)
  }
  static func duplicateAppTheme(_ value: DuplicateAppThemeArguments) -> Self {
    builtIn(.duplicateAppTheme, value)
  }
  static func updateAppTheme(_ value: UpdateAppThemeArguments) -> Self {
    builtIn(.updateAppTheme, value)
  }
  static func extensionListComponents(_ value: EmptyToolArguments) -> Self {
    builtIn(.extensionListComponents, value)
  }
  static func extensionScaffoldProject(_ value: ExtensionScaffoldProjectArguments) -> Self {
    builtIn(.extensionScaffoldProject, value)
  }
  static func extensionProposeInstall(_ value: ExtensionProposeInstallArguments) -> Self {
    builtIn(.extensionProposeInstall, value)
  }
  static func extensionDescribeComponent(_ value: ExtensionComponentReferenceArguments) -> Self {
    builtIn(.extensionDescribeComponent, value)
  }
  static func extensionValidateComponentPatch(_ value: ExtensionComponentPatchArguments) -> Self {
    builtIn(.extensionValidateComponentPatch, value)
  }
  static func extensionPreviewComponentPatch(_ value: ExtensionComponentPatchArguments) -> Self {
    builtIn(.extensionPreviewComponentPatch, value)
  }
}
