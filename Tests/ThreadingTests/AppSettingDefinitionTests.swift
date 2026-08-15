import XCTest
@testable import Threading

final class AppSettingDefinitionTests: XCTestCase {
    func testProductionDefinitionsAreCompleteAndPersistenceKeysStayUnique() {
        XCTAssertEqual(AppSettingDefinitions.issues, [])

        let definitions = AppSettingDefinitions.all
        XCTAssertEqual(Set(definitions.map(\.identity)).count, definitions.count)
        let keys = definitions.compactMap { $0.persistence?.key }
        XCTAssertEqual(Set(keys).count, keys.count)
    }

    func testSyntheticDuplicateKeyFailsTheCatalogueAudit() throws {
        let original = AppSettingDefinitions.definition("restoresLastSession")
        let duplicate = AppSettingDefinition(
            identity: "syntheticDuplicate",
            persistence: original.persistence,
            presentations: [],
            notification: .appSettingsChanged,
            remotePolicy: .hidden
        )

        let catalogue = AppSettingDefinitionCatalogue(
            definitions: AppSettingDefinitions.all + [duplicate]
        )
        XCTAssertTrue(
            catalogue.issues.contains("duplicate persistence key restoresLastSession")
        )
        XCTAssertNil(catalogue.registeredDefaults["restoresLastSession"])
    }

    func testSyntheticDuplicateAnchorFailsTheCatalogueAudit() {
        let first = AppSettingDefinition(
            identity: "first",
            persistence: nil,
            presentations: [
                AppSettingPresentation(
                    pageID: "general",
                    catalogueOrder: 0,
                    section: "Sessions",
                    rowAnchor: "Same row",
                    searchTerms: []
                )
            ],
            notification: .none,
            remotePolicy: .catalogueOnly
        )
        let second = AppSettingDefinition(
            identity: "second",
            persistence: nil,
            presentations: first.presentations,
            notification: .none,
            remotePolicy: .catalogueOnly
        )

        let catalogue = AppSettingDefinitionCatalogue(definitions: [first, second])
        XCTAssertTrue(catalogue.issues.contains("duplicate row anchor general/Same row"))
    }

    func testValidationRejectsWrongTypesUnknownCasesAndOutOfRangeValues() {
        XCTAssertTrue(
            AppSettingDefinitions.accepts(.integer(7), for: "sessionRestoreWindowDays")
        )
        XCTAssertFalse(
            AppSettingDefinitions.accepts(.integer(31), for: "sessionRestoreWindowDays")
        )
        XCTAssertFalse(
            AppSettingDefinitions.accepts(.string("7"), for: "sessionRestoreWindowDays")
        )
        XCTAssertTrue(
            AppSettingDefinitions.accepts(.string("recentlyUsed"), for: "sessionRestorePolicy")
        )
        XCTAssertFalse(
            AppSettingDefinitions.accepts(.string("forever"), for: "sessionRestorePolicy")
        )
    }

    func testEveryCurrentAndMigrationKeyKeepsItsStableSpelling() {
        let expected = Set([
            "appTextSize", "attentionAlertSound", "automaticUpdateChecksEnabled",
            "bypassesCodexHookTrust", "capturesPageBeforeAgentActions", "chatNameMorphStyle",
            "chromeFontFamily", "claudeRemoteControl", "claudeStartupSpeed",
            "codexStartupSpeed", "compactsSidebarTree", "confirmsBeforeClosingRunningSession",
            "conversationFontFamily", "convertsDroppedImages", "copiesTerminalSelection",
            "defaultAgentKind", "defaultPermissionMode", "didMigrateClosingConfirmation",
            "disabledAttachmentDetectionAgentKinds", "disabledAttentionAlerts",
            "disabledToolGroupIDs", "discoversAccountAvatars", "discoversProjectIcons",
            "followsCheckoutBranch", "githubAppClientID", "groupsLoneBranches",
            "groupsSessionsByBranch", "harmonizesTerminalBackgrounds", "hiddenNotices",
            "includesAttachmentsOutsideProject", "installsCodexHooks", "newChatOpeningMessage",
            "notifiesOnAttention", "playsAttentionAlertSound", "promptReturnKey",
            "readsClaudeLoginFromKeychain", "remoteAccessAllowsOwnerRelayFallback",
            "remoteAccessConnectionMode", "remoteAccessEnabled", "remoteAccessKeepsRelayReady",
            "remoteInputControlDefault", "reportsClaudeLifecycleEvents", "restoresLastSession",
            "restoresRunningSessions", "sessionRestoreLimit", "sessionRestorePolicy",
            "sessionRestoreWindowDays", "sidebarSessionOrder", "sidebarSessionOrderIsReversed",
            "silencesAllSounds", "soundEventChoices", "suppressedConfirmations",
            "suppressesClaudeStatusLine", "terminalBellSound", "usesContainedExtensionLauncher",
            "usesTerminalTitleInSidebar", "workingOrbStyle", "workspaceNavigatorSelection"
        ])
        let actual = Set(AppSettingDefinitions.all.compactMap { $0.persistence?.key })
        XCTAssertEqual(actual, expected)

        XCTAssertEqual(
            AppSettingDefinitions.key("legacyClosingConfirmation"),
            "confirmsBeforeClosingRunningSession"
        )
        XCTAssertEqual(
            AppSettingDefinitions.key("closingConfirmationMigration"),
            "didMigrateClosingConfirmation"
        )
        XCTAssertEqual(
            AppSettingDefinitions.key("legacyPlaysAttentionAlertSound"),
            "playsAttentionAlertSound"
        )
    }

    func testRegisteredDefaultsAreDerivedWithoutChangingAbsenceSemantics() {
        let defaults = AppSettingDefinitions.registeredDefaults
        XCTAssertEqual(defaults["restoresLastSession"] as? Bool, true)
        XCTAssertEqual(defaults["remoteAccessKeepsRelayReady"] as? Bool, false)
        XCTAssertEqual(defaults["appTextSize"] as? String, AppTextSize.standard.rawValue)

        XCTAssertNil(defaults["sessionRestorePolicy"])
        XCTAssertNil(defaults["attentionAlertSound"])
        XCTAssertNil(defaults["copiesTerminalSelection"])
        XCTAssertNil(defaults["defaultPermissionMode"])
    }

    @MainActor
    func testNavigationAndRemoteCatalogueRowsProjectFromDefinitions() {
        let authoredRows = AppSettingDefinitions.all.flatMap(\.presentations)
        XCTAssertEqual(authoredRows.count, 73)
        XCTAssertEqual(
            SettingsPages.builtIn.flatMap(\.entries).count,
            authoredRows.count
        )
        XCTAssertEqual(
            SettingsPages.page(id: SettingsPages.remoteAccessID)?.entries.map(\.title),
            authoredRows.filter { $0.pageID == SettingsPages.remoteAccessID }
                .map { L10n.string($0.rowAnchor) }
        )
        XCTAssertTrue(
            AppSettingDefinitions.all
                .filter { !$0.presentations.isEmpty }
                .allSatisfy { $0.remotePolicy != .hidden }
        )
    }

    func testCatalogueRowOrderRemainsWireCompatible() {
        let actual = Dictionary(grouping: AppSettingDefinitions.all.flatMap(\.presentations)) {
            $0.pageID
        }.mapValues { rows in
            rows.sorted { $0.catalogueOrder < $1.catalogueOrder }.map(\.rowAnchor)
        }
        XCTAssertEqual(actual["general"], [
            "New sessions use", "Name sessions after the agent's own title",
            "Group sessions by branch", "Compact tree", "Follow the checkout's branch",
            "Discover project icons", "Discover account avatars", "Claude sessions start in",
            "Codex sessions start in", "Add to every new chat",
            "Include files outside the project",
            "Keep the page as it was before each agent action",
            "Reopen the last session at launch", "Bring back at launch",
            "Counts as recently used", "Sessions brought back", "Hidden extension messages",
            "Notify when a session needs you", "Alert sound", "Sounds for each alert",
            "Bell sound", "Sounds for each bell", "Silence every sound",
            "New sessions start in", "Remote Control for new Claude sessions",
            "Report Claude turn and subagent activity",
            "Hide Claude's status line in Threading terminals", "Report Codex turn boundaries",
            "Skip Codex hook review", "Check for updates automatically"
        ])
        XCTAssertEqual(actual["keyboard"], [
            "When writing a prompt, press Return to", "Reset Shortcuts"
        ])
        XCTAssertEqual(actual["themes"], [
            "App theme", "Custom themes", "Classic skins", "Text size", "App font",
            "Conversation font"
        ])
        XCTAssertEqual(actual["profiles"], [
            "Font", "Style", "Blinking cursor", "Keep backgrounds in tune with the theme",
            "Lines kept", "Copy selected text to the clipboard",
            "Convert dropped images agents can't open"
        ])
        XCTAssertEqual(actual["motion"], ["Working indicator", "Chat name transition"])
        XCTAssertEqual(actual["usage-windows"], [
            "Open a window before I start", "I start at", "I stop at", "Days",
            "If the window has not reset", "When a session hits its usage limit"
        ])
        XCTAssertEqual(actual["remote-access"], [
            "Remote Access", "Connection", "Hosted Direct", "Owner Relay Fallback",
            "Keep Sharing Relay Ready", "New shared chats"
        ])
        XCTAssertEqual(actual["github"], ["Client ID", "gh CLI", "Git credential helper"])
        XCTAssertEqual(actual["privacy"], [
            "Files & Folders", "Notifications", "Accessibility", "Screen Recording",
            "Live usage from your Claude login"
        ])
        XCTAssertEqual(actual["advanced"], [
            "Settings", "Projects, sessions and caches", "First-launch walkthrough",
            "Run at next launch", "Reset settings", "Reset everything"
        ])
    }

    @MainActor
    func testListSettingsWireProjectsTheDefinitionCatalogue() throws {
        struct Payload: Decodable {
            struct Page: Decodable {
                struct Setting: Decodable {
                    let title: String
                    let section: String?
                }
                let id: String
                let settings: [Setting]
            }
            let pages: [Page]
        }

        let coordinator = AgentToolCoordinator(
            displayPaneController: DisplayPaneController(),
            visibleSessionID: { nil },
            setPaneVisible: { _ in },
            windowProvider: { nil }
        )
        let result = coordinator.listSettings()
        XCTAssertFalse(result.isError, result.text)

        let payload = try JSONDecoder().decode(Payload.self, from: Data(result.text.utf8))
        let general = try XCTUnwrap(payload.pages.first { $0.id == "general" })
        let definitions = AppSettingDefinitions.all.flatMap(\.presentations)
            .filter { $0.pageID == "general" }
            .sorted { $0.catalogueOrder < $1.catalogueOrder }
        XCTAssertEqual(general.settings.map(\.title), definitions.map { L10n.string($0.rowAnchor) })
        XCTAssertEqual(
            general.settings.map(\.section),
            definitions.map { $0.section.map { L10n.string($0) } }
        )
    }
}
