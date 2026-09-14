import Foundation

/// A built-in command understood by the application.
///
/// This closed identity feeds `MCPBuiltInToolRegistry`, where its single declaration owns
/// decoding, schema, annotations, grouping, catalogue presentation, and typed execution. A newly
/// added case cannot be admitted until that declaration is complete, while provider tools remain
/// open-ended and use `MCPJSONValue` through the external route.
enum MCPBuiltInTool: CaseIterable, Sendable {
  case displayImage
  case displayChart
  case displayScene
  case displayHTML
  case displayCompareFiles
  case videoFrames
  case conversationHistory
  case browserNavigate
  case browserHistory
  case browserStop
  case browserTabs
  case browserStorage
  case browserTrace
  case browserUpload
  case browserDownload
  case browserResize
  case browserEmulate
  case browserCapabilities
  case browserRunIsolated
  case browserAttachChrome
  case browserSnapshot
  case browserAnnotations
  case browserScreenshot
  case browserVisualCompare
  case browserBaselines
  case browserQuery
  case browserClick
  case browserHover
  case browserDrag
  case browserType
  case browserFillForm
  case browserFillCredentials
  case browserSelect
  case browserSetChecked
  case browserPressKey
  case browserScroll
  case browserWait
  case browserConsole
  case browserNetwork
  case browserPerformance
  case browserAccessibilityAudit
  case deviceLogPrepare
  case simulatorPrepare
  case simulatorInstallLaunch
  case simulatorScreenshot
  case simulatorSnapshot
  case simulatorAnnotations
  case simulatorTap
  case simulatorSwipe
  case simulatorTypeText
  case simulatorPressButton
  case panelListTabs
  case panelActivateTab
  case setProjectIcon
  case setSessionCheckout
  case createSessionWorktree
  case cancelSessionCheckoutMove
  case archiveSession
  case cancelSessionArchive
  case setSessionName
  case listSessions
  case sendToSession
  case watchSession
  case listAccounts
  case sessionCost
  case resumeSession
  case spawnSession
  case moveSessionToAccount
  case finishWorkspace
  case adoptSession
  case releaseSession
  case subscribeToChildren
  case respondToPermission
  case listReclaimableStorage
  case suggestReclaimableLocation
  case proposeStorageCleanup
  case proposeConversationRepair
  case listTriggerSources
  case listTriggers
  case listTriggerRuns
  case createTriggerDraft
  case proposeTriggerActivation
  case reportTriggerAssessment
  case reportTriggerResult
  case listSettings
  case notifyUser
  case listThemes
  case setTheme
  case createTheme
  case listAppThemes
  case getAppTheme
  case setAppTheme
  case createAppTheme
  case duplicateAppTheme
  case updateAppTheme
  case extensionListComponents
  case extensionScaffoldProject
  case extensionProposeInstall
  case extensionDescribeComponent
  case extensionValidateComponentPatch
  case extensionPreviewComponentPatch
  case listIOSDiagnosticDevices
  case inspectIOSDiagnostics

  enum Family: String, CaseIterable, Sendable {
    case continuation
    case display
    case browser
    case simulator
    case deviceLog
    case panel
    case project
    case session
    case workspace
    case supervision
    case storage
    case triggers
    case notifications
    case appearance
    case settings
    case extensionAuthoring
  }

  /// Compatibility projection for call sites that need the stable wire spelling. The spelling
  /// itself is authored only by this tool's complete declaration.
  var rawValue: String {
    guard let declaration = MCPBuiltInToolRegistry.descriptor(for: self) else {
      preconditionFailure("Missing built-in declaration for \(self)")
    }
    return declaration.definition.name
  }

  init?(rawValue: String) {
    guard let tool = MCPBuiltInToolRegistry.descriptor(named: rawValue)?.tool else { return nil }
    self = tool
  }

  /// Family and behavior hints are projections of the complete declaration. They are not
  /// authored on the identity a second time.
  var family: Family {
    guard let declaration = MCPBuiltInToolRegistry.descriptor(for: self) else {
      preconditionFailure("Missing built-in declaration for \(self)")
    }
    return declaration.family
  }

  var annotations: MCPToolAnnotations {
    guard let declaration = MCPBuiltInToolRegistry.descriptor(for: self) else {
      preconditionFailure("Missing built-in declaration for \(self)")
    }
    return declaration.annotations
  }

}
