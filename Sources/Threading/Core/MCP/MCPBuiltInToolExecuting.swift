import Foundation

/// Typed application implementations available to built-in MCP declarations.
///
/// This is an execution boundary, not a second tool inventory: it contains no wire identity,
/// schema, grouping, presentation, or decoding policy. A declaration captures one of these
/// typed implementations when it constructs a command, so runtime dispatch never switches on
/// a string or erases an argument through `Any`.
@MainActor
protocol MCPBuiltInToolExecuting: AnyObject {
  func displayImage(_ arguments: DisplayImageArguments, for sessionID: SessionID) -> MCPToolResult
  func displayChart(_ arguments: DisplayChartArguments, for sessionID: SessionID) -> MCPToolResult
  func displayScene(_ arguments: DisplaySceneArguments, for sessionID: SessionID) -> MCPToolResult
  func displayHTML(_ arguments: DisplayHTMLArguments, for sessionID: SessionID) -> MCPToolResult
  func displayCompareFiles(
    _ arguments: DisplayCompareFilesArguments, for sessionID: SessionID
  ) -> MCPToolResult

  /// Asynchronous because it decodes: the frames are read off the main actor, and a tool that
  /// returned before they existed would return a sheet of nothing.
  func videoFrames(
    _ arguments: VideoFramesArguments, for sessionID: SessionID,
    completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
  )

  func browserNavigate(
    _ arguments: BrowserNavigateArguments, for sessionID: SessionID,
    completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
  )
  func browserHistory(
    _ arguments: BrowserHistoryArguments, for sessionID: SessionID,
    completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
  )
  func browserStop(
    for sessionID: SessionID,
    completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
  )
  func browserTabs(_ arguments: BrowserTabsArguments, for sessionID: SessionID) -> MCPToolResult
  func browserStorage(
    _ arguments: BrowserStorageArguments, for sessionID: SessionID,
    completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
  )
  func browserTrace(_ arguments: BrowserTraceArguments, for sessionID: SessionID) -> MCPToolResult
  func browserUpload(
    _ arguments: BrowserUploadArguments, for sessionID: SessionID,
    completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
  )
  func browserDownload(
    _ arguments: BrowserDownloadArguments, for sessionID: SessionID,
    completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
  )
  func browserResize(
    _ arguments: BrowserResizeArguments, for sessionID: SessionID,
    completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
  )
  func browserEmulate(
    _ arguments: BrowserEmulateArguments, for sessionID: SessionID,
    completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
  )
  func browserCapabilities(for sessionID: SessionID) -> MCPToolResult
  func browserRunIsolated(
    _ arguments: BrowserIsolatedRunArguments, for sessionID: SessionID,
    completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
  )
  func browserAttachChrome(
    _ arguments: BrowserAttachRunArguments, for sessionID: SessionID,
    completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
  )
  func browserSnapshot(
    _ arguments: BrowserSnapshotArguments, for sessionID: SessionID,
    completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
  )
  func browserAnnotations(
    for sessionID: SessionID,
    completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
  )
  func browserScreenshot(
    _ arguments: BrowserScreenshotArguments, for sessionID: SessionID,
    completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
  )
  func browserVisualCompare(
    _ arguments: BrowserVisualCompareArguments, for sessionID: SessionID,
    completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
  )
  func browserBaselines(
    _ arguments: BrowserBaselinesArguments, for sessionID: SessionID,
    completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
  )
  func browserQuery(
    _ arguments: BrowserSelectorArguments, for sessionID: SessionID,
    completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
  )
  func browserClick(
    _ arguments: BrowserClickArguments, for sessionID: SessionID,
    completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
  )
  func browserHover(
    _ arguments: BrowserTargetArguments, for sessionID: SessionID,
    completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
  )
  func browserDrag(
    _ arguments: BrowserDragArguments, for sessionID: SessionID,
    completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
  )
  func browserType(
    _ arguments: BrowserTypeArguments, for sessionID: SessionID,
    completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
  )
  func browserFillForm(
    _ arguments: BrowserFillFormArguments, for sessionID: SessionID,
    completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
  )
  func browserFillCredentials(
    _ arguments: BrowserFillCredentialsArguments, for sessionID: SessionID,
    completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
  )
  func browserSelect(
    _ arguments: BrowserSelectArguments, for sessionID: SessionID,
    completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
  )
  func browserSetChecked(
    _ arguments: BrowserSetCheckedArguments, for sessionID: SessionID,
    completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
  )
  func browserPressKey(
    _ arguments: BrowserKeyArguments, for sessionID: SessionID,
    completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
  )
  func browserScroll(
    _ arguments: BrowserScrollArguments, for sessionID: SessionID,
    completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
  )
  func browserWait(
    _ arguments: BrowserWaitArguments, for sessionID: SessionID,
    completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
  )
  func browserConsole(
    _ arguments: BrowserConsoleArguments, for sessionID: SessionID,
    completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
  )
  func browserNetwork(
    _ arguments: BrowserNetworkArguments, for sessionID: SessionID,
    completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
  )
  func browserPerformance(
    _ arguments: BrowserPerformanceArguments, for sessionID: SessionID,
    completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
  )
  func browserAccessibilityAudit(
    _ arguments: BrowserAccessibilityAuditArguments, for sessionID: SessionID,
    completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
  )

  func panelListTabs(for sessionID: SessionID) -> MCPToolResult
  func panelActivateTab(
    _ arguments: PanelActivateTabArguments, for sessionID: SessionID
  ) -> MCPToolResult
  func setProjectIcon(
    _ arguments: SetProjectIconArguments, for sessionID: SessionID,
    completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
  )
  func archiveSession(
    _ arguments: ArchiveSessionArguments, for sessionID: SessionID
  ) -> MCPToolResult
  func cancelSessionArchive(
    _ arguments: CancelSessionArchiveArguments, for sessionID: SessionID
  ) -> MCPToolResult
  func setSessionName(
    _ arguments: SetSessionNameArguments, for sessionID: SessionID
  ) -> MCPToolResult
  func listProjectSessions(for sessionID: SessionID) -> MCPToolResult
  func sendToSession(
    _ arguments: SendToSessionArguments, for sessionID: SessionID,
    completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
  )
  func watchSession(
    _ arguments: WatchSessionArguments, for sessionID: SessionID
  ) -> MCPToolResult
  func listAccounts(_ arguments: ListAccountsArguments, for sessionID: SessionID) -> MCPToolResult
  func sessionCost(_ arguments: SessionCostArguments, for sessionID: SessionID) -> MCPToolResult
  func resumeSession(
    _ arguments: ResumeSessionArguments, for sessionID: SessionID,
    completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
  )
  func spawnSession(
    _ arguments: SpawnSessionArguments, for sessionID: SessionID,
    completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
  )
  func moveSessionToAccount(
    _ arguments: MoveSessionToAccountArguments, for sessionID: SessionID,
    completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
  )
  func finishWorkspace(
    _ arguments: SessionReferenceArguments, for sessionID: SessionID
  ) -> MCPToolResult
  func adoptSession(_ arguments: AdoptSessionArguments, for sessionID: SessionID) -> MCPToolResult
  func releaseSession(
    _ arguments: ReleaseSessionArguments, for sessionID: SessionID
  ) -> MCPToolResult
  func subscribeToChildren(
    _ arguments: SubscribeToChildrenArguments, for sessionID: SessionID
  ) -> MCPToolResult
  func respondToPermission(
    _ arguments: RespondToPermissionArguments, for sessionID: SessionID
  ) -> MCPToolResult
  func listReclaimableStorage() -> MCPToolResult
  func suggestReclaimableLocation(
    _ arguments: SuggestReclaimableLocationArguments
  ) -> MCPToolResult
  func proposeStorageCleanup(
    _ arguments: StorageCleanupArguments,
    for sessionID: SessionID,
    completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
  )
  /// Supplied by whatever owns the sheets a repair ends in — the window, in the app. Nil for a
  /// host that has none, which is every test and the default below.
  var conversationRepairHandler: ConversationRepairHandler? { get }
  func listSettings() -> MCPToolResult
  func notifyUser(_ arguments: NotifyUserArguments, for sessionID: SessionID) -> MCPToolResult
  func listThemes(for sessionID: SessionID) -> MCPToolResult
  func setTheme(_ arguments: SetThemeArguments, for sessionID: SessionID) -> MCPToolResult
  func createTheme(_ arguments: CreateThemeArguments, for sessionID: SessionID) -> MCPToolResult
  func listAppThemes() -> MCPToolResult
  func getAppTheme(_ arguments: AppThemeReferenceArguments) -> MCPToolResult
  func setAppTheme(_ arguments: SetAppThemeArguments) -> MCPToolResult
  func createAppTheme(_ arguments: CreateAppThemeArguments) -> MCPToolResult
  func duplicateAppTheme(_ arguments: DuplicateAppThemeArguments) -> MCPToolResult
  func updateAppTheme(_ arguments: UpdateAppThemeArguments) -> MCPToolResult
  func extensionListComponents() -> MCPToolResult
  func extensionScaffoldProject(_ arguments: ExtensionScaffoldProjectArguments) -> MCPToolResult
  func extensionProposeInstall(
    _ arguments: ExtensionProposeInstallArguments,
    completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
  )
  func extensionDescribeComponent(
    _ arguments: ExtensionComponentReferenceArguments
  ) -> MCPToolResult
  func extensionValidateComponentPatch(
    _ arguments: ExtensionComponentPatchArguments
  ) -> MCPToolResult
  func extensionPreviewComponentPatch(
    _ arguments: ExtensionComponentPatchArguments, for sessionID: SessionID
  ) -> MCPToolResult
  func listIOSDiagnosticDevices() -> MCPToolResult
  func inspectIOSDiagnostics(
    _ arguments: IOSDiagnosticsInspectionArguments,
    completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
  )
}

// MARK: - Conversation Repair

/// What a recovery agent's report is handed to.
///
/// A closure rather than a second protocol: the handler needs a window, sheets and the session
/// coordinator, none of which belong to the type that serves tool calls — which is why
/// `AgentToolCoordinator` is documented as owning tool behaviour *without* owning the window.
typealias ConversationRepairHandler = @MainActor (
  ConversationRepairArguments,
  SessionID,
  @escaping @MainActor @Sendable (MCPToolResult) -> Void
) -> Void

extension MCPBuiltInToolExecuting {

  /// No handler means no host that can ask the user anything, so the tool refuses rather than
  /// silently doing nothing. Every conformer gets this; only the app supplies a handler.
  var conversationRepairHandler: ConversationRepairHandler? { nil }

  func proposeConversationRepair(
    _ arguments: ConversationRepairArguments,
    for sessionID: SessionID,
    completion: @escaping @MainActor @Sendable (MCPToolResult) -> Void
  ) {
    guard let conversationRepairHandler else {
      return completion(.failure(LaunchRecoveryStrings.notARecoveryChat))
    }
    conversationRepairHandler(arguments, sessionID, completion)
  }
}
