import os
import XCTest
@testable import Threading

final class AppSettingDefinitionTests: XCTestCase {
    private struct PersistenceCompatibility: Equatable {
        let key: String
        let valueType: AppSettingValueType
    }

    func testProductionDefinitionsAreCompleteAndPersistenceKeysStayUnique() {
        XCTAssertEqual(AppSettingDefinitions.issues, [])

        let definitions = AppSettingDefinitions.all
        XCTAssertEqual(Set(definitions.map(\.identity)).count, definitions.count)
        let keys = definitions.compactMap { $0.persistence?.key }
        XCTAssertEqual(Set(keys).count, keys.count)
    }

    func testEveryClosedPersistedIdentityIsErasedExactlyOnce() {
        let erased = AppSettingDefinitions.persistedDescriptors
        let counts = Dictionary(grouping: erased, by: \.identity).mapValues(\.count)

        XCTAssertEqual(Set(counts.keys), Set(AppSettingIdentity.allCases))
        XCTAssertTrue(counts.values.allSatisfy { $0 == 1 })
        XCTAssertEqual(erased.count, AppSettingIdentity.allCases.count)
    }

    func testErasedPersistedCatalogueIsOnlyTheTypedDescriptorProjection() {
        let projected = AppSettingDefinitions.persistedDescriptors.map(\.definition)
        let persistedCatalogue = AppSettingDefinitions.all.filter { $0.persistence != nil }

        XCTAssertEqual(persistedCatalogue, projected)
        XCTAssertEqual(
            projected.map(\.identity),
            AppSettingDefinitions.persistedDescriptors.map { $0.identity.rawValue }
        )
        XCTAssertTrue(projected.allSatisfy { $0.persistence != nil })
    }

    func testSyntheticDuplicateKeyFailsTheCatalogueAudit() throws {
        let original = AppSettingDefinitions.restoresLastSession.definition
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

    func testTypedValidationRejectsUnknownCasesAndOutOfRangeValues() {
        XCTAssertTrue(AppSettingDefinitions.sessionRestoreWindowDays.accepts(7))
        XCTAssertFalse(AppSettingDefinitions.sessionRestoreWindowDays.accepts(31))
        XCTAssertTrue(AppSettingDefinitions.sessionRestorePolicy.accepts("recentlyUsed"))
        XCTAssertFalse(AppSettingDefinitions.sessionRestorePolicy.accepts("forever"))
    }

    func testLocalDiagnosticsIsAbsentAndOffUntilThePersonOptsIn() throws {
        let suiteName = "AppSettingDefinitionTests.localDiagnostics.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertNil(defaults.object(forKey: "localDiagnosticsEnabled"))
        XCTAssertEqual(AppSettingDefinitions.localDiagnosticsEnabled.read(from: defaults), false)

        XCTAssertTrue(AppSettingDefinitions.localDiagnosticsEnabled.write(true, to: defaults))
        XCTAssertEqual(AppSettingDefinitions.localDiagnosticsEnabled.read(from: defaults), true)
    }

    @MainActor
    func testMacNotificationActivityWindowDefaultsToTwoMinutesAndPersistsEveryChoice() throws {
        let suiteName = "AppSettingDefinitionTests.notificationActivity.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)

        XCTAssertNil(
            defaults.persistentDomain(forName: suiteName)?[
                "remoteNotificationMacActivityWindow"
            ]
        )
        XCTAssertEqual(settings.remoteNotificationMacActivityWindow, .twoMinutes)
        XCTAssertEqual(settings.remoteNotificationMacActivityWindow.seconds, 120)

        let expected: [(MacNotificationActivityWindow, TimeInterval)] = [
            (.off, 0), (.oneMinute, 60), (.twoMinutes, 120),
            (.fiveMinutes, 300), (.tenMinutes, 600),
        ]
        for (choice, seconds) in expected {
            settings.remoteNotificationMacActivityWindow = choice
            XCTAssertEqual(settings.remoteNotificationMacActivityWindow, choice)
            XCTAssertEqual(settings.remoteNotificationMacActivityWindow.seconds, seconds)
        }
    }

    func testEveryPersistedIdentityKeepsItsStableKeyAndValueType() {
        let expected: [AppSettingIdentity: PersistenceCompatibility] = [
            .defaultAgentKind: .init(key: "defaultAgentKind", valueType: .string),
            .githubAppClientID: .init(key: "githubAppClientID", valueType: .string),
            .restoresLastSession: .init(key: "restoresLastSession", valueType: .boolean),
            .restoresRunningSessions: .init(key: "restoresRunningSessions", valueType: .boolean),
            .sessionRestorePolicy: .init(key: "sessionRestorePolicy", valueType: .string),
            .sessionRestoreWindowDays: .init(key: "sessionRestoreWindowDays", valueType: .integer),
            .sessionRestoreLimit: .init(key: "sessionRestoreLimit", valueType: .integer),
            .newChatOpeningPrefix: .init(key: "newChatOpeningPrefix", valueType: .string),
            // The suffix shipped first and keeps its original key.
            .newChatOpeningSuffix: .init(key: "newChatOpeningMessage", valueType: .string),
            .legacyClosingConfirmation: .init(
                key: "confirmsBeforeClosingRunningSession",
                valueType: .boolean
            ),
            .suppressedConfirmations: .init(
                key: "suppressedConfirmations",
                valueType: .stringArray
            ),
            .hiddenNotices: .init(key: "hiddenNotices", valueType: .stringArray),
            .closingConfirmationMigration: .init(
                key: "didMigrateClosingConfirmation",
                valueType: .boolean
            ),
            .usesAgentTitleInSidebar: .init(
                key: "usesTerminalTitleInSidebar",
                valueType: .boolean
            ),
            .groupsSessionsByBranch: .init(key: "groupsSessionsByBranch", valueType: .boolean),
            .groupsLoneBranches: .init(key: "groupsLoneBranches", valueType: .boolean),
            .compactsSidebarTree: .init(key: "compactsSidebarTree", valueType: .boolean),
            .followsCheckoutBranch: .init(key: "followsCheckoutBranch", valueType: .boolean),
            .sidebarSessionOrder: .init(key: "sidebarSessionOrder", valueType: .string),
            .sidebarSessionOrderIsReversed: .init(
                key: "sidebarSessionOrderIsReversed",
                valueType: .boolean
            ),
            .previewsSidebarChats: .init(key: "previewsSidebarChats", valueType: .boolean),
            .nativeSidebarGroupByFact: .init(
                key: "nativeSidebarGroupByFact",
                valueType: .string
            ),
            .nativeSidebarSortByFact: .init(
                key: "nativeSidebarSortByFact",
                valueType: .string
            ),
            .promptReturnKey: .init(key: "promptReturnKey", valueType: .string),
            .discoversProjectIcons: .init(key: "discoversProjectIcons", valueType: .boolean),
            .discoversAccountAvatars: .init(key: "discoversAccountAvatars", valueType: .boolean),
            .harmonizesTerminalBackgrounds: .init(
                key: "harmonizesTerminalBackgrounds",
                valueType: .boolean
            ),
            .convertsDroppedImages: .init(key: "convertsDroppedImages", valueType: .boolean),
            .copiesTerminalSelection: .init(key: "copiesTerminalSelection", valueType: .boolean),
            .notifiesOnAttention: .init(key: "notifiesOnAttention", valueType: .boolean),
            .disabledAttentionAlerts: .init(
                key: "disabledAttentionAlerts",
                valueType: .stringArray
            ),
            .legacyPlaysAttentionAlertSound: .init(
                key: "playsAttentionAlertSound",
                valueType: .boolean
            ),
            .attentionAlertSound: .init(key: "attentionAlertSound", valueType: .string),
            .terminalBellSound: .init(key: "terminalBellSound", valueType: .string),
            .soundEventChoices: .init(
                key: "soundEventChoices",
                valueType: .stringDictionary
            ),
            .silencesAllSounds: .init(key: "silencesAllSounds", valueType: .boolean),
            .disabledAttachmentDetectionAgentKinds: .init(
                key: "disabledAttachmentDetectionAgentKinds",
                valueType: .stringArray
            ),
            .includesAttachmentsOutsideProject: .init(
                key: "includesAttachmentsOutsideProject",
                valueType: .boolean
            ),
            .capturesPageBeforeAgentActions: .init(
                key: "capturesPageBeforeAgentActions",
                valueType: .boolean
            ),
            .sessionCheckoutAuthorityPolicy: .init(
                key: "sessionCheckoutAuthorityPolicy",
                valueType: .string
            ),
            .disabledToolGroupIDs: .init(key: "disabledToolGroupIDs", valueType: .stringArray),
            .usesContainedExtensionLauncher: .init(
                key: "usesContainedExtensionLauncher",
                valueType: .boolean
            ),
            .usesMCPStdioBridge: .init(
                key: "mcpStdioBridgeEnabled",
                valueType: .boolean
            ),
            .ptyHostEnabled: .init(
                key: "ptyHostEnabled",
                valueType: .boolean
            ),
            .prependsCommandLineToolsToPATH: .init(
                key: "prependsCommandLineToolsToPATH",
                valueType: .boolean
            ),
            .workspaceNavigatorSelection: .init(
                key: "workspaceNavigatorSelection",
                valueType: .data
            ),
            .reportsClaudeLifecycleEvents: .init(
                key: "reportsClaudeLifecycleEvents",
                valueType: .boolean
            ),
            .installsCodexHooks: .init(key: "installsCodexHooks", valueType: .boolean),
            .readsClaudeLoginFromKeychain: .init(
                key: "readsClaudeLoginFromKeychain",
                valueType: .boolean
            ),
            .suppressesClaudeStatusLine: .init(
                key: "suppressesClaudeStatusLine",
                valueType: .boolean
            ),
            .bypassesCodexHookTrust: .init(key: "bypassesCodexHookTrust", valueType: .boolean),
            .claudeRemoteControl: .init(key: "claudeRemoteControl", valueType: .string),
            .claudeTerminalRenderer: .init(key: "claudeTerminalRenderer", valueType: .string),
            .claudeStartupSpeed: .init(key: "claudeStartupSpeed", valueType: .string),
            .codexStartupSpeed: .init(key: "codexStartupSpeed", valueType: .string),
            .defaultPermissionMode: .init(key: "defaultPermissionMode", valueType: .string),
            .localDiagnosticsEnabled: .init(
                key: "localDiagnosticsEnabled",
                valueType: .boolean
            ),
            .remoteAccessEnabled: .init(key: "remoteAccessEnabled", valueType: .boolean),
            .remoteNotificationMacActivityWindow: .init(
                key: "remoteNotificationMacActivityWindow",
                valueType: .string
            ),
            .remoteAccessDoorMigration: .init(
                key: "didMigrateRemoteAccessDoors",
                valueType: .boolean
            ),
            .remoteAccessPublicChannelMigration: .init(
                key: "didClearRemoteAccessForPublicChannel",
                valueType: .boolean
            ),
            .remoteAccessTailscaleEnabled: .init(
                key: "remoteAccessTailscaleEnabled",
                valueType: .boolean
            ),
            .remoteAccessTailscaleServeEnabled: .init(
                key: "remoteAccessTailscaleServeEnabled",
                valueType: .boolean
            ),
            .remoteAccessListenerPort: .init(
                key: "remoteAccessListenerPort",
                valueType: .integer
            ),
            .remoteViewportLeaseGraceSeconds: .init(
                key: "remoteViewportLeaseGraceSeconds",
                valueType: .integer
            ),
            .remoteAccessDoors: .init(
                key: "remoteAccessDoors",
                valueType: .stringArray
            ),
            .remoteAccessAdvertisedHostname: .init(
                key: "remoteAccessAdvertisedHostname",
                valueType: .string
            ),
            .remoteHostedServiceEnvironment: .init(
                key: "remoteHostedServiceEnvironment",
                valueType: .string
            ),
            .remoteAccessDiscoveryEnabled: .init(
                key: "remoteAccessDiscoveryEnabled",
                valueType: .boolean
            ),
            .remoteInputControlDefault: .init(
                key: "remoteInputControlDefault",
                valueType: .string
            ),
            .phoneReportWorkspace: .init(
                key: "phoneReportWorkspace",
                valueType: .string
            ),
            .automaticUpdateChecksEnabled: .init(
                key: "automaticUpdateChecksEnabled",
                valueType: .boolean
            ),
            .preventsIdleSystemSleepWhileAgentsWork: .init(
                key: "preventsIdleSystemSleepWhileAgentsWork",
                valueType: .boolean
            ),
            .workingOrbStyle: .init(key: "workingOrbStyle", valueType: .string),
            .chatNameMorphStyle: .init(key: "chatNameMorphStyle", valueType: .string),
            .chromeFontFamily: .init(key: "chromeFontFamily", valueType: .string),
            .conversationFontFamily: .init(key: "conversationFontFamily", valueType: .string),
            .appTextSize: .init(key: "appTextSize", valueType: .string),
            .remoteAccessKeepAwake: .init(key: "remoteAccessKeepAwake", valueType: .string),
            .updateChannelSubscription: .init(
                key: "updateChannelSubscription", valueType: .string
            ),
            .sourceControlProviderConnections: .init(
                key: "sourceControlProviderConnections", valueType: .data
            )
        ]

        XCTAssertEqual(Set(expected.keys), Set(AppSettingIdentity.allCases))
        var actual: [AppSettingIdentity: PersistenceCompatibility] = [:]
        for descriptor in AppSettingDefinitions.persistedDescriptors {
            guard let persistence = descriptor.definition.persistence else {
                XCTFail("Persisted descriptor \(descriptor.identity.rawValue) has no persistence")
                continue
            }
            actual[descriptor.identity] = .init(
                key: persistence.key,
                valueType: persistence.valueType
            )
        }
        XCTAssertEqual(actual, expected)
    }

    @MainActor
    func testProductionGithubClientIDWriteCannotBypassDeclaredByteBound() throws {
        let suite = "AppSettingDefinitionTests.github.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)

        let observed = OSAllocatedUnfairLock(
            initialState: (count: 0, changedSettings: Set<String>?.none)
        )
        let observer = NotificationCenter.default.addObserver(
            forName: AppSettingsDidChange.name,
            object: nil,
            queue: nil
        ) { notification in
            let changedSettings =
                (notification.object as? AppSettingsDidChange)?.changedSettings
            observed.withLock {
                $0.count += 1
                $0.changedSettings = changedSettings
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        settings.githubAppClientID = "truthful-client-id"
        XCTAssertEqual(settings.githubAppClientID, "truthful-client-id")
        var snapshot = observed.withLock { $0 }
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot.changedSettings, [AppSettingIdentity.githubAppClientID.rawValue])

        settings.githubAppClientID = String(repeating: "é", count: 513)
        XCTAssertEqual(settings.githubAppClientID, "truthful-client-id")
        snapshot = observed.withLock { $0 }
        XCTAssertEqual(snapshot.count, 1, "rejected writes must not announce a change")
    }

    @MainActor
    func testRemoteMutationProjectsOwnerPolicyAndFailsClosed() throws {
        let suite = "AppSettingDefinitionTests.remote.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let remote = LiveRemoteSettingsMutator(appSettings: settings)

        XCTAssertEqual(
            remote.applyAppSetting(
                identity: "remoteInputControlDefault",
                value: .string("focusedOwner")
            ),
            .applied
        )
        XCTAssertEqual(settings.remoteInputControlDefault, .focusedOwner)

        XCTAssertEqual(
            remote.applyAppSetting(identity: "remoteAccessEnabled", value: .boolean(true)),
            .notMutable,
            "transport lifecycle settings require coordinator sequencing"
        )
        XCTAssertFalse(settings.remoteAccessEnabled)

        XCTAssertEqual(
            remote.applyAppSetting(identity: "githubAppClientID", value: .string("x")),
            .notMutable
        )
        XCTAssertEqual(settings.githubAppClientID, "")

        XCTAssertEqual(
            remote.applyAppSetting(
                identity: "remoteInputControlDefault",
                value: .string("allDoorsOpen")
            ),
            .invalidValue
        )
        XCTAssertEqual(settings.remoteInputControlDefault, .focusedOwner)

        XCTAssertEqual(
            remote.applyAppSetting(
                identity: "remoteInputControlDefault",
                value: .boolean(true)
            ),
            .invalidValue
        )
        XCTAssertEqual(
            remote.applyAppSetting(
                identity: "remoteInputControlDefualt",
                value: .string("collaborative")
            ),
            .unknownSetting
        )
    }

    func testRegisteredDefaultsAreDerivedWithoutChangingAbsenceSemantics() {
        let defaults = AppSettingDefinitions.registeredDefaults
        XCTAssertEqual(defaults["restoresLastSession"] as? Bool, true)
        XCTAssertEqual(defaults["remoteAccessTailscaleEnabled"] as? Bool, false)
        // The retired connection mode seeds nothing: its keys are read once by the migration
        // and then deleted, so registering a default for one would re-create it every launch.
        XCTAssertNil(defaults["remoteAccessConnectionMode"])
        XCTAssertNil(defaults["remoteAccessAllowsOwnerRelayFallback"])
        XCTAssertNil(defaults["remoteAccessKeepsRelayReady"])
        XCTAssertEqual(defaults["remoteAccessTailscaleServeEnabled"] as? Bool, false)
        // Opt-in false is an absence semantic, not a seeded key: the person's first write is
        // distinguishable from a registered default.
        XCTAssertNil(defaults["localDiagnosticsEnabled"])
        // The LAN door is the shipped exposure now that the listener presents a pinned
        // identity, and the seed is what makes an existing install pick it up.
        XCTAssertEqual(
            defaults["remoteAccessDoors"] as? [String],
            [RemoteAccessDoor.lan.rawValue]
        )
        // The migration marker is deliberately unseeded: `containsValue` answers for a
        // registered default too, so seeding it would mark every install already migrated.
        XCTAssertNil(defaults["didMigrateRemoteAccessDoors"])
        XCTAssertNil(defaults["didClearRemoteAccessForPublicChannel"])
        XCTAssertEqual(defaults["preventsIdleSystemSleepWhileAgentsWork"] as? Bool, false)
        XCTAssertEqual(defaults["appTextSize"] as? String, AppTextSize.standard.rawValue)

        XCTAssertNil(defaults["sessionRestorePolicy"])
        XCTAssertNil(defaults["attentionAlertSound"])
        XCTAssertNil(defaults["copiesTerminalSelection"])
        XCTAssertNil(defaults["defaultPermissionMode"])
    }

    @MainActor
    func testNavigationAndRemoteCatalogueRowsProjectFromDefinitions() {
        let authoredRows = AppSettingDefinitions.all.flatMap(\.presentations)
#if DEBUG || THREADING_INTERNAL
        XCTAssertEqual(authoredRows.count, 90)
#else
        XCTAssertEqual(authoredRows.count, 89)
#endif
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
            "Sort sessions by", "Sort direction", "Show five chats per project",
            "Group sessions by branch", "Compact tree", "Follow the checkout's branch",
            "Discover project icons", "Discover account avatars", "Claude sessions start in",
            "Codex sessions start in", "Before the task you write",
            "After the task you write",
            "Include files outside the project",
            "Keep the page as it was before each agent action",
            "Reopen the last session at launch", "Bring back at launch",
            "Stop idle agents after", "Keep idle agents running", "Hidden extension messages",
            "Notify when a session needs you", "Alert sound", "Sounds for each alert",
            "Bell sound", "Sounds for each bell", "Silence every sound",
            "New sessions start in", "Remote Control for new Claude sessions",
            "Report Claude turn and subagent activity",
            "Hide Claude's status line in Threading terminals",
            "Scrolling in new Claude terminals", "Report Codex turn boundaries",
            "Skip Codex hook review", "Updates you receive",
            "Check for updates automatically",
            "Keep this Mac awake while agents work"
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
        XCTAssertEqual(actual["tools"], ["Agents may move chats between checkouts"])
        XCTAssertEqual(actual["usage-windows"], [
            "Open a window before I start", "I start at", "I stop at", "Days",
            "If the window has not reset", "When a session hits its usage limit"
        ])
        // The mode and its two relay switches are gone; the ways in are rows of their own, and
        // the browser convenience is a row under the tailnet one rather than a way in. The
        // sign-in row is last because it is the one row on this page that is not a stored
        // setting, so it is surfaced rather than persisted and cannot be interleaved.
        XCTAssertEqual(actual["remote-access"], [
            "Remote Access", "Keep this Mac awake", "This network", "Tailscale",
            "Open in a browser on your tailnet", "Mac activity window", "New shared chats",
            "Reports from your phone", "Hosted Direct"
        ])
        // A public build's page has no Hosted Direct sign-in, so its catalogue does not promise
        // one; every other row is the same on every channel.
        let publicRemoteAccess = AppSettingDefinitions.definitions(on: .release)
            .flatMap(\.presentations)
            .filter { $0.pageID == "remote-access" }
            .sorted { $0.catalogueOrder < $1.catalogueOrder }
            .map(\.rowAnchor)
        XCTAssertEqual(publicRemoteAccess, [
            "Remote Access", "Keep this Mac awake", "This network", "Tailscale",
            "Open in a browser on your tailnet", "Mac activity window", "New shared chats",
            "Reports from your phone"
        ])
        XCTAssertEqual(
            AppSettingDefinitions.definitions(on: .dev),
            AppSettingDefinitions.all,
            "a hosted test bundle is a development build, and must list what one lists"
        )
        XCTAssertEqual(actual["github"], ["Client ID", "gh CLI", "Git credential helper"])
        XCTAssertEqual(actual["privacy"], [
            "Files & Folders", "Notifications", "Accessibility", "Screen Recording",
            "Live usage from your Claude login"
        ])
        // The background host's rows are ordered after Start Over
        // deliberately: the page reads as "where things are, how to start over, and what is still
        // running when Threading is not". The two command-line-tool rows close it out, because
        // reaching the daemon from a terminal is the last thing in that sentence. Internal builds
        // then append the deliberately secluded developer-only service identity.
        var expectedAdvanced = [
            "Allow paired-iPhone checkups", "Settings", "Projects, sessions and caches",
            "First-launch walkthrough", "Run at next launch", "Reset settings",
            "Reset everything", "Background host", "Turn off the background host",
            "Command line tool", "Tools in Threading's terminals"
        ]
#if DEBUG || THREADING_INTERNAL
        expectedAdvanced.append("Hosted service")
#endif
        XCTAssertEqual(actual["advanced"], expectedAdvanced)
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
