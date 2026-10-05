import AppKit
import XCTest
@testable import Threading

private actor AppearanceTestPersistence: AppearanceActivationPersisting {
    var writes: [AppearanceActivationState] = []
    let fails: Bool
    let delay: UInt64
    init(fails: Bool = false, delay: UInt64 = 0) { self.fails = fails; self.delay = delay }
    func save(_ state: AppearanceActivationState) async throws {
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if fails { throw AppearanceActivationError.persistenceFailed }
        writes.append(state)
    }
}

@MainActor
final class AppearanceActivationTests: XCTestCase {
    private let rain = "com.example.rain"
    private let shared = "com.example.shared"
    private let manual = "com.example.manual"

    private func inventory(
        themeIDs: Set<String> = ["system", "standalone"],
        unavailable: String? = nil,
        suppressed: Bool = false
    ) -> AppearanceActivationInventory {
        .init(themeIDs: themeIDs, extensions: Dictionary(uniqueKeysWithValues: [rain, shared, manual].map {
            ($0, .init(name: $0, unavailableReason: $0 == unavailable ? "Invalid package" : nil))
        }), extensionsSuppressed: suppressed)
    }

    private func temporaryStoreURL() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("appearance.json")
    }

    func testThemeChoiceAndEnablementAreIndependentAndRepairedAgainstInventory() throws {
        let initial = AppearanceActivationState(themeID: "standalone", enabledExtensionIDs: [manual])
        let themed = try initial.changing(.selectTheme("system"))
        XCTAssertEqual(themed.themeID, "system")
        XCTAssertEqual(themed.enabledExtensionIDs, [manual], "a theme choice leaves extensions alone")
        XCTAssertEqual(themed.revision, 1)
        XCTAssertEqual(try themed.changing(.selectTheme("system")), themed, "a repeated choice writes nothing")

        let enabled = try themed.changing(.setExtensionEnabled(rain, true))
        XCTAssertEqual(enabled.enabledExtensionIDs, [manual, rain])
        XCTAssertEqual(enabled.themeID, "system", "enablement leaves the theme alone")
        XCTAssertEqual(try enabled.changing(.setExtensionEnabled(manual, false)).enabledExtensionIDs, [rain])

        let repaired = try enabled.changing(.reconcileInventory(
            themeIDs: ["standalone"], extensionIDs: [rain], fallbackThemeID: "standalone"
        ))
        XCTAssertEqual(repaired.themeID, "standalone", "a removed theme falls back")
        XCTAssertEqual(repaired.enabledExtensionIDs, [rain], "a removed extension loses its enablement")
        XCTAssertThrowsError(try initial.changing(.setExtensionEnabled("not an identifier", true)))
    }

    func testHeldBackOrUnavailableExtensionsCannotBeEnabledButCanAlwaysBeDisabled() async throws {
        var snapshot = inventory()
        let service = AppearanceActivationService(
            state: AppearanceActivationState(themeID: "system", enabledExtensionIDs: [manual]),
            persistence: AppearanceTestPersistence(), inventory: { snapshot }, reconcile: { _, _ in })
        XCTAssertNil(service.unavailableReason(for: .setExtensionEnabled(rain, true)))
        XCTAssertEqual(service.unavailableReason(for: .setExtensionEnabled("com.example.missing", true)),
                       AppearanceActivationError.extensionUnavailable("com.example.missing").localizedDescription)
        snapshot = inventory(unavailable: rain)
        XCTAssertEqual(service.unavailableReason(for: .setExtensionEnabled(rain, true)),
                       AppearanceActivationError.extensionUnavailable(rain).localizedDescription)
        snapshot = inventory(suppressed: true)
        XCTAssertEqual(service.unavailableReason(for: .setExtensionEnabled(rain, true)),
                       AppearanceActivationError.suppressed.localizedDescription)
        XCTAssertNil(service.unavailableReason(for: .setExtensionEnabled(manual, false)))
        try await service.perform(.setExtensionEnabled(manual, false))
        XCTAssertEqual(service.state.enabledExtensionIDs, [])
        XCTAssertEqual(service.unavailableReason(for: .selectTheme("missing")),
                       AppearanceActivationError.themeUnavailable.localizedDescription)
    }

    func testFailedCommitDoesNotPublishOrApplyAndConcurrentMutationsAreRefused() async throws {
        let initial = AppearanceActivationState(themeID: "standalone", enabledExtensionIDs: [])
        let persistence = AppearanceTestPersistence(fails: true, delay: 50_000_000)
        var reconciliations = 0, releases = 0
        let service = AppearanceActivationService(state: initial, persistence: persistence,
            inventory: { self.inventory() }, endMutation: { releases += 1 },
            reconcile: { _, _ in reconciliations += 1 })
        let operation = Task { try await service.perform(.selectTheme("system")) }
        while !service.isChanging { await Task.yield() }
        XCTAssertEqual(service.state, initial)
        XCTAssertNotNil(service.unavailableReason(for: .setExtensionEnabled(manual, true)))
        do { try await operation.value; XCTFail("save must fail") } catch {}
        XCTAssertEqual(service.state, initial)
        XCTAssertEqual(reconciliations, 0)
        XCTAssertEqual(releases, 1)
        XCTAssertFalse(service.isChanging)
    }

    func testCommittedChangesProjectInOrderAndPersistTheWholeState() async throws {
        let persistence = AppearanceTestPersistence()
        var projected: [AppearanceActivationState] = []
        let service = AppearanceActivationService(
            state: AppearanceActivationState(themeID: "standalone", enabledExtensionIDs: [manual]),
            persistence: persistence, inventory: { self.inventory() },
            reconcile: { _, next in projected.append(next) })
        try await service.perform(.setExtensionEnabled(rain, true))
        try await service.perform(.selectTheme("system"))
        try await service.perform(.selectTheme("system"))
        let stored = await persistence.writes
        XCTAssertEqual(stored.count, 2, "an unchanged choice is not written again")
        XCTAssertEqual(stored, projected)
        XCTAssertEqual(stored.last, service.state)
        XCTAssertEqual(service.state.enabledExtensionIDs, [manual, rain])
    }

    func testFileMigrationRestartAndCorruptionNeverReimportLegacyState() async throws {
        let url = temporaryStoreURL()
        let directory = url.deletingLastPathComponent()
        let legacy = AppearanceActivationState(themeID: "standalone", enabledExtensionIDs: [manual])
        let store = AppearanceActivationStore(url: url)
        let migrated = try await store.load(migrating: legacy)
        XCTAssertEqual(migrated, legacy)
        let changed = try legacy.changing(.selectTheme("system")).changing(.setExtensionEnabled(rain, true))
        try await store.save(changed)
        let restored = try await AppearanceActivationStore(url: url).load(migrating: legacy)
        XCTAssertEqual(restored, changed)
        try Data("broken".utf8).write(to: url)
        for _ in 0..<2 {
            do {
                _ = try await AppearanceActivationStore(url: url).load(migrating: legacy)
                XCTFail("corruption must not restore stale legacy choices")
            } catch {}
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files.filter { $0.contains("unreadable") }.count, 1)
    }

    /// The record exactly as a build with appearance packs wrote it, with a saved and an active
    /// pack. It loads without quarantine; the pack fields are dropped and never written back.
    func testRecordWrittenWhilePacksExistedLoadsAndDropsThem() async throws {
        let url = temporaryStoreURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let digest = String(repeating: "a", count: 64)
        let fixture = """
        {
          "formatVersion" : 1,
          "value" : {
            "activePackID" : "6F1C3C1E-2B0A-4B8E-9C55-0D7E1A4B2C3D",
            "formatVersion" : 1,
            "manuallyEnabledExtensionIDs" : [
              "\(manual)"
            ],
            "packs" : [
              {
                "extensions" : [
                  {
                    "contentDigest" : "\(digest)",
                    "identifier" : "\(rain)"
                  }
                ],
                "id" : "6F1C3C1E-2B0A-4B8E-9C55-0D7E1A4B2C3D",
                "name" : "Night Shift",
                "recipeRevision" : "0B7C2D9E-1F3A-4C5B-8D6E-7F8091A2B3C4",
                "themeID" : "cyberpunk"
              }
            ],
            "revision" : 11,
            "standaloneThemeID" : "custom-744b1d30-b37b-4098-8544-7ffb18b22f95"
          }
        }
        """
        try Data(fixture.utf8).write(to: url)
        let legacy = AppearanceActivationState(themeID: "system", enabledExtensionIDs: [])
        let store = AppearanceActivationStore(url: url)

        let loaded = try await store.load(migrating: legacy)
        XCTAssertEqual(loaded, AppearanceActivationState(
            revision: 11, themeID: "custom-744b1d30-b37b-4098-8544-7ffb18b22f95", enabledExtensionIDs: [manual]
        ), "the plain choices survive; the pack's theme and member are not adopted")
        let siblings = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertEqual(siblings.filter { $0.contains("unreadable") }, [], "an old record is not corrupt")

        try await store.save(loaded.changing(.selectTheme("system")))
        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let value = try XCTUnwrap(written["value"] as? [String: Any])
        XCTAssertEqual(Set(value.keys), ["formatVersion", "revision", "standaloneThemeID", "manuallyEnabledExtensionIDs", "packs"])
        XCTAssertEqual((value["packs"] as? [Any])?.count, 0, "an older build still finds the key it requires")
        XCTAssertEqual(value["standaloneThemeID"] as? String, "system")
        XCTAssertEqual(value["manuallyEnabledExtensionIDs"] as? [String], [manual])
        let reloaded = try await AppearanceActivationStore(url: url).load(migrating: legacy)
        XCTAssertEqual(reloaded.revision, 12)
        XCTAssertEqual(reloaded.themeID, "system")
    }

    func testRecoveryReadsLegacyWithoutWritingAndAllowsExplicitOff() async throws {
        let url = temporaryStoreURL()
        let legacy = AppearanceActivationState(themeID: "system", enabledExtensionIDs: [manual])
        let store = AppearanceActivationStore(url: url)
        let restored = try await store.load(migrating: legacy, persistMigration: false)
        XCTAssertEqual(restored, legacy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
        try await store.save(legacy.changing(.setExtensionEnabled(manual, false)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testRealHostMenuRouteCommitsThemeAndExtensionChoicesAndRefusesStaleCommand() async throws {
        let system = AppTheme.system.id.rawValue, cyberpunk = AppThemeStyles.cyberpunk.id.rawValue
        var snapshot = inventory(themeIDs: [system, cyberpunk])
        var projected: AppearanceActivationState?
        let service = AppearanceActivationService(
            state: AppearanceActivationState(themeID: system, enabledExtensionIDs: []),
            persistence: AppearanceTestPersistence(), inventory: { snapshot },
            reconcile: { _, next in projected = next })
        let host = AppearanceActivationHost(service: service, inventory: { snapshot })
        AppearanceCommands.refresh(host: host)
        defer { CommandRegistry.shared.replaceAppearanceCommands([]) }
        let delegate = AppDelegate()
        delegate.appearanceHost = host
        func invoke(_ target: AppearanceCommandTarget) throws {
            let item = NSMenuItem(title: "Appearance", action: NSSelectorFromString("performHostMenuCommand:"), keyEquivalent: "")
            item.representedObject = target.commandID
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: delegate, from: item))
        }

        try invoke(.theme(cyberpunk))
        for _ in 0..<200 where service.state.themeID != cyberpunk { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(projected?.themeID, cyberpunk)
        try invoke(.extensionEnabled(rain, true))
        for _ in 0..<200 where service.state.enabledExtensionIDs.isEmpty { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(projected?.enabledExtensionIDs, [rain])
        XCTAssertEqual(service.state.revision, 2)

        snapshot = inventory(themeIDs: [cyberpunk])
        try invoke(.theme(system))
        await Task.yield()
        XCTAssertEqual(service.state.themeID, cyberpunk, "a theme that went away is refused, not selected")
        XCTAssertEqual(service.state.revision, 2)
    }

    func testThemePickerListsOnlyThemesAndSelectsTheStoredChoice() {
        let picker = ThemedPopUp()
        AppThemePicker.populate(picker, selectedThemeID: AppThemeStyles.cyberpunk.id)
        var headers: [String] = []
        var values: [String] = []
        for entry in picker.entries {
            switch entry {
            case .header(let title): headers.append(title)
            case .item(let item):
                guard let value = item.representedValue as? String else {
                    return XCTFail("every row names a theme by its id: \(item.title)")
                }
                values.append(value)
            case .separator: break
            }
        }
        XCTAssertEqual(Set(values), Set(AppThemeLibrary.sections.flatMap(\.themes).map(\.id.rawValue)))
        XCTAssertEqual(values.count, Set(values).count, "no theme is offered twice")
        XCTAssertEqual(headers, AppThemeLibrary.sections.compactMap(\.title))
        XCTAssertEqual(picker.selectedItem?.representedValue as? String, AppThemeStyles.cyberpunk.id.rawValue)
    }

    func testCatalogueOffersThemesTerminalThemesAndExtensionSwitchesOnly() throws {
        let system = AppTheme.system.id.rawValue
        let snapshot = inventory(themeIDs: Set(AppThemeLibrary.all.map(\.id.rawValue)))
        let service = AppearanceActivationService(
            state: AppearanceActivationState(themeID: system, enabledExtensionIDs: [manual]),
            persistence: AppearanceTestPersistence(), inventory: { snapshot }, reconcile: { _, _ in })
        let host = AppearanceActivationHost(service: service, inventory: { snapshot })
        let commands = AppearanceCommands.catalog(host: host)
        let prefixes = ["appearance.theme.use.", "appearance.terminal-theme.use.",
                        "appearance.extension.enable.", "appearance.extension.disable."]
        for command in commands {
            XCTAssertNotNil(command.appearanceTarget)
            XCTAssertTrue(prefixes.contains { command.id.hasPrefix($0) }, command.id)
            XCTAssertFalse(command.title.contains("Pack"), command.title)
        }
        XCTAssertEqual(commands.filter { $0.id.hasPrefix("appearance.theme.use.") }.count, AppThemeLibrary.all.count)
        XCTAssertEqual(commands.filter { $0.id.hasPrefix("appearance.extension.") }.count, 6)
        let current = try XCTUnwrap(commands.first { $0.id == AppearanceCommandTarget.theme(system).commandID })
        XCTAssertEqual(current.detail, L10n.format("Current theme · %@", L10n.string("Built-in")))
        let enabled = try XCTUnwrap(commands.first { $0.id == AppearanceCommandTarget.extensionEnabled(manual, false).commandID })
        XCTAssertEqual(enabled.detail, L10n.string("Enabled"))
        let disabled = try XCTUnwrap(commands.first { $0.id == AppearanceCommandTarget.extensionEnabled(rain, true).commandID })
        XCTAssertEqual(disabled.title, L10n.format("Enable %@ Extension", rain))
        XCTAssertEqual(disabled.detail, L10n.string("Disabled"))
    }

    /// The palette is where theme and extension commands are found. The menu bar holds none of
    /// them visibly; an assigned shortcut rides a hidden View-menu carrier.
    func testViewMenuHoldsAppearanceCommandsOnlyAsHiddenShortcutCarriers() throws {
        let previousMainMenu = NSApp.mainMenu
        let previousWindowsMenu = NSApp.windowsMenu
        let previousHelpMenu = NSApp.helpMenu
        defer {
            NSApp.mainMenu = previousMainMenu
            NSApp.windowsMenu = previousWindowsMenu
            NSApp.helpMenu = previousHelpMenu
        }
        let snapshot = inventory(themeIDs: Set(AppThemeLibrary.all.map(\.id.rawValue)))
        let service = AppearanceActivationService(
            state: AppearanceActivationState(themeID: AppTheme.system.id.rawValue, enabledExtensionIDs: []),
            persistence: AppearanceTestPersistence(), inventory: { snapshot }, reconcile: { _, _ in })
        AppearanceCommands.refresh(host: AppearanceActivationHost(service: service, inventory: { snapshot }))
        defer { CommandRegistry.shared.replaceAppearanceCommands([]) }

        let delegate = AppDelegate()
        delegate.setupMenuBar()
        let view = try XCTUnwrap(NSApp.mainMenu?.items.compactMap(\.submenu).first { $0.title == MenuIdentifiers.viewMenu })
        XCTAssertNil(view.item(withTitle: L10n.string("Appearance")), "no empty Appearance submenu")
        let appearanceItems = view.items.filter { ($0.representedObject as? String)?.hasPrefix("appearance.") == true }
        XCTAssertEqual(appearanceItems, delegate.appearanceShortcutCarriersForTesting)
        for item in appearanceItems {
            XCTAssertTrue(item.isHidden)
            XCTAssertTrue(item.allowsKeyEquivalentWhenHidden)
            XCTAssertFalse(item.keyEquivalent.isEmpty, "only a bound command needs a carrier")
        }
    }

    func testTerminalScopeKeepsIdentityAndRefusesMissingTarget() {
        let scopes: [TerminalThemeCommandScope] = [.defaultTheme, .project(ProjectID()), .session(SessionID()), .terminal(TerminalID())]
        for scope in scopes { XCTAssertEqual(TerminalThemeCommandScope(id: scope.id), scope) }
        XCTAssertNil(TerminalThemeCommandScope(id: "current"))
        XCTAssertNotNil(TerminalThemeCommands.apply(themeID: TerminalThemeID.followsAppTheme.rawValue,
                                                  targetID: TerminalThemeCommandScope.session(SessionID()).id))
        XCTAssertNotNil(TerminalThemeCommands.apply(themeID: "missing", targetID: "default"))
    }

    func testCatalogueStressIsBoundedAndKeepsSpecificThemeSearchable() {
        for count in [100, 5_096] {
            let themes = (0..<count).map { index in
                AppTheme(id: AppThemeID("stress-\(index)"), name: "Stress \(index)", mode: .dark,
                         summary: nil, variants: AppThemeStyles.cyberpunk.variants)
            }
            let inventory = AppearanceActivationInventory(themeIDs: Set(themes.map { $0.id.rawValue }).union(["system"]),
                                                         extensions: self.inventory().extensions)
            let state = AppearanceActivationState(themeID: "system", enabledExtensionIDs: [])
            let service = AppearanceActivationService(state: state, persistence: AppearanceTestPersistence(),
                inventory: { inventory }, reconcile: { _, _ in })
            let host = AppearanceActivationHost(service: service, inventory: { inventory })
            let start = Date()
            let commands = AppearanceCommands.catalog(host: host, themes: themes)
            let descriptors = commands.map { command in
                command.hostDescriptor(shortcut: nil,
                    availability: command.appearanceTarget.flatMap { AppearanceCommands.unavailableReason($0, host: host) }
                        .map { .unavailable(reason: $0) } ?? .available)
            }
            let catalogDuration = Date().timeIntervalSince(start)
            let searchStart = Date()
            let results = HostCommandSearch.results(in: descriptors, matching: "Stress \(count - 1) Theme")
            let searchDuration = Date().timeIntervalSince(searchStart)
            XCTAssertEqual(results.first?.id, AppearanceCommandTarget.theme("stress-\(count - 1)").commandID)
            XCTAssertLessThanOrEqual(results.count, HostCommandSearch.maximumResults)
            XCTAssertEqual(Set(commands.map(\.id)).count, commands.count)
            XCTAssertLessThan(catalogDuration, 0.25, "catalogue work must remain bounded at the admitted inventory limit")
            print("Appearance catalogue: \(count) themes, build+availability \(catalogDuration * 1000) ms; search \(searchDuration * 1000) ms")
        }
    }
}
