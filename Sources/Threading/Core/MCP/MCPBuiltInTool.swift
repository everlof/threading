import Foundation

/// A built-in command understood by the application.
///
/// This closed identity feeds `MCPBuiltInToolRegistry`, where decoding, schema, annotations,
/// grouping, catalog presentation, and execution become one admitted descriptor. A newly added
/// case must therefore be classified before it compiles, while provider tools remain open-ended
/// and use `MCPJSONValue` through `.unknown`.
enum MCPBuiltInTool: String, CaseIterable, Sendable {
  case displayImage = "display_image"
  case displayChart = "display_chart"
  case displayScene = "display_scene"
  case displayHTML = "display_html"
  case displayCompareFiles = "display_compare_files"
  case conversationHistory = "conversation_history"
  case browserNavigate = "browser_navigate"
  case browserHistory = "browser_history"
  case browserStop = "browser_stop"
  case browserTabs = "browser_tabs"
  case browserStorage = "browser_storage"
  case browserTrace = "browser_trace"
  case browserUpload = "browser_upload"
  case browserDownload = "browser_download"
  case browserResize = "browser_resize"
  case browserEmulate = "browser_emulate"
  case browserCapabilities = "browser_capabilities"
  case browserRunIsolated = "browser_run_isolated"
  case browserAttachChrome = "browser_attach_chrome"
  case browserSnapshot = "browser_snapshot"
  case browserAnnotations = "browser_annotations"
  case browserScreenshot = "browser_screenshot"
  case browserVisualCompare = "browser_visual_compare"
  case browserBaselines = "browser_baselines"
  case browserQuery = "browser_query"
  case browserClick = "browser_click"
  case browserHover = "browser_hover"
  case browserDrag = "browser_drag"
  case browserType = "browser_type"
  case browserFillForm = "browser_fill_form"
  case browserFillCredentials = "browser_fill_credentials"
  case browserSelect = "browser_select"
  case browserSetChecked = "browser_set_checked"
  case browserPressKey = "browser_press_key"
  case browserScroll = "browser_scroll"
  case browserWait = "browser_wait"
  case browserConsole = "browser_console"
  case browserNetwork = "browser_network"
  case browserPerformance = "browser_performance"
  case browserAccessibilityAudit = "browser_accessibility_audit"
  case panelListTabs = "panel_list_tabs"
  case panelActivateTab = "panel_activate_tab"
  case setProjectIcon = "set_project_icon"
  case archiveSession = "archive_session"
  case cancelSessionArchive = "cancel_session_archive"
  case setSessionName = "set_session_name"
  case listSessions = "list_sessions"
  case sendToSession = "send_to_session"
  case watchSession = "watch_session"
  case listReclaimableStorage = "list_reclaimable_storage"
  case proposeStorageCleanup = "propose_storage_cleanup"
  case listSettings = "list_settings"
  case notifyUser = "notify_user"
  case listThemes = "list_themes"
  case setTheme = "set_theme"
  case createTheme = "create_theme"
  case listAppThemes = "list_app_themes"
  case getAppTheme = "get_app_theme"
  case setAppTheme = "set_app_theme"
  case createAppTheme = "create_app_theme"
  case duplicateAppTheme = "duplicate_app_theme"
  case updateAppTheme = "update_app_theme"
  case extensionListComponents = "extension_list_components"
  case extensionScaffoldProject = "extension_scaffold_project"
  case extensionProposeInstall = "extension_propose_install"
  case extensionDescribeComponent = "extension_describe_component"
  case extensionValidateComponentPatch = "extension_validate_component_patch"
  case extensionPreviewComponentPatch = "extension_preview_component_patch"

  enum Family: String, CaseIterable, Sendable {
    case continuation
    case display
    case browser
    case panel
    case project
    case session
    case workspace
    case storage
    case notifications
    case appearance
    case settings
    case extensionAuthoring
  }

  /// Drives both capability availability and catalog validation.
  var family: Family {
    switch self {
    case .conversationHistory: return .continuation
    case .displayImage, .displayChart, .displayScene, .displayHTML, .displayCompareFiles:
      return .display
    case .browserNavigate, .browserHistory, .browserStop, .browserTabs, .browserStorage,
      .browserTrace, .browserUpload, .browserDownload, .browserResize, .browserEmulate,
      .browserCapabilities, .browserRunIsolated, .browserAttachChrome, .browserSnapshot,
      .browserAnnotations,
      .browserScreenshot, .browserVisualCompare, .browserBaselines, .browserQuery, .browserClick,
      .browserHover, .browserDrag, .browserType, .browserFillForm, .browserFillCredentials,
      .browserSelect,
      .browserSetChecked, .browserPressKey, .browserScroll, .browserWait, .browserConsole,
      .browserNetwork, .browserPerformance, .browserAccessibilityAudit:
      return .browser
    case .panelListTabs, .panelActivateTab: return .panel
    case .setProjectIcon: return .project
    case .archiveSession, .cancelSessionArchive, .setSessionName: return .session
    case .listSessions, .sendToSession, .watchSession: return .workspace
    case .listReclaimableStorage, .proposeStorageCleanup: return .storage
    case .listSettings: return .settings
    case .notifyUser: return .notifications
    case .listThemes, .setTheme, .createTheme, .listAppThemes, .getAppTheme, .setAppTheme,
      .createAppTheme, .duplicateAppTheme, .updateAppTheme:
      return .appearance
    case .extensionListComponents, .extensionScaffoldProject, .extensionProposeInstall,
      .extensionDescribeComponent, .extensionValidateComponentPatch,
      .extensionPreviewComponentPatch:
      return .extensionAuthoring
    }
  }

  /// Conservative MCP behavior hints. Any tool with an action-dependent write is classified as
  /// mutating; clients must never infer safety from the least consequential action it supports.
  var annotations: MCPToolAnnotations {
    switch self {
    case .conversationHistory, .browserCapabilities, .browserSnapshot, .browserAnnotations,
      .browserScreenshot, .browserVisualCompare, .browserQuery, .browserConsole,
      .browserNetwork, .browserPerformance, .browserAccessibilityAudit, .panelListTabs,
      .listSessions,
      .listReclaimableStorage, .listSettings, .listThemes, .listAppThemes, .getAppTheme,
      .extensionListComponents, .extensionDescribeComponent,
      .extensionValidateComponentPatch:
      return MCPToolAnnotations(
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: family == .browser
      )

    case .browserStorage, .browserTrace, .browserBaselines, .proposeStorageCleanup,
      .extensionProposeInstall, .archiveSession:
      return MCPToolAnnotations(
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: false,
        openWorldHint: family == .browser
      )

    case .cancelSessionArchive:
      return MCPToolAnnotations(
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
      )

    case .setSessionName:
      return MCPToolAnnotations(
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
      )

    case .displayImage, .displayChart, .displayScene, .displayHTML, .displayCompareFiles,
      .browserNavigate,
      .browserHistory, .browserStop, .browserTabs, .browserUpload, .browserDownload,
      .browserResize, .browserEmulate, .browserRunIsolated, .browserAttachChrome,
      .browserClick, .browserHover,
      .browserDrag, .browserType, .browserFillForm, .browserFillCredentials,
      .browserSelect, .browserSetChecked,
      .browserPressKey, .browserScroll, .browserWait, .panelActivateTab, .setProjectIcon,
      .notifyUser, .sendToSession, .watchSession, .setTheme, .createTheme, .setAppTheme,
      .createAppTheme,
      .duplicateAppTheme, .updateAppTheme, .extensionScaffoldProject,
      .extensionPreviewComponentPatch:
      return MCPToolAnnotations(
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: false,
        // `send_to_session` reaches beyond this session's own surfaces: it starts or extends
        // a turn in another agent process, which is a resource outside this call's world.
        // `watch_session` writes nothing now and leads to exactly that message later, so it
        // is classified by what it causes rather than by what the call itself does.
        openWorldHint: family == .browser || self == .notifyUser || self == .sendToSession
          || self == .watchSession
      )
    }
  }
}
