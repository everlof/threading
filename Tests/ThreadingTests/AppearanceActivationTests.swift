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
    private let digest = String(repeating: "a", count: 64)

    private func pack(_ name: String, members: [String]) -> AppearancePack {
        AppearancePack(id: UUID(), recipeRevision: UUID(), name: name, themeID: "system",
                       extensions: members.map { .init(identifier: $0, contentDigest: digest) })
    }

    private func inventory(digest: String? = nil, suppressed: Bool = false) -> AppearanceActivationInventory {
        .init(themeIDs: ["system", "standalone"], extensions: Dictionary(uniqueKeysWithValues:
            [rain, shared, manual].map { ($0, .init(name: $0, contentDigest: digest ?? self.digest,
                unavailableReason: nil, requiredExtensionIDs: [], status: .running)) }),
              extensionsSuppressed: suppressed)
    }

    func testSwitchThenOffPreservesOnlyManualReasonsAndStandaloneTheme() async throws {
        let a = pack("A", members: [rain, shared]), b = pack("B", members: [shared])
        let initial = AppearanceActivationState(standaloneThemeID: "standalone",
            manuallyEnabledExtensionIDs: [manual], packs: [a, b])
        let persistence = AppearanceTestPersistence()
        var departing: [Set<String>] = []
        let service = AppearanceActivationService(state: initial, persistence: persistence,
            inventory: { self.inventory() }, reconcile: { before, after in
                departing.append(before.desiredExtensionIDs.subtracting(after.desiredExtensionIDs))
            })
        try await service.perform(.activatePack(a.id))
        XCTAssertEqual(service.state.desiredExtensionIDs, [manual, rain, shared])
        try await service.perform(.activatePack(b.id))
        XCTAssertEqual(departing.last, [rain], "shared runtime keeps its generation")
        try await service.perform(.deactivatePack(b.id))
        XCTAssertEqual(service.state.desiredExtensionIDs, [manual])
        XCTAssertEqual(service.state.selectedThemeID, "standalone")
        let stored = await persistence.writes
        XCTAssertEqual(stored.last, service.state)
        XCTAssertEqual(stored.count, 3)
    }

    func testKeepEnabledAndExplicitDisableHaveDifferentMeaning() throws {
        let pack = pack("Rain", members: [rain, shared])
        let active = AppearanceActivationState(standaloneThemeID: "standalone",
            manuallyEnabledExtensionIDs: [manual], packs: [pack], activePackID: pack.id)
        let kept = try active.changing(.setExtensionEnabled(rain, true))
        XCTAssertEqual(kept.activePackID, pack.id)
        XCTAssertEqual(try kept.changing(.deactivatePack(pack.id)).desiredExtensionIDs, [manual, rain])
        let disabled = try kept.changing(.setExtensionEnabled(rain, false))
        XCTAssertNil(disabled.activePackID)
        XCTAssertEqual(disabled.desiredExtensionIDs, [manual])
        let selected = try active.changing(.selectTheme("system"))
        XCTAssertNil(selected.activePackID, "choosing the same visible theme still releases the pack")
        XCTAssertEqual(selected.desiredExtensionIDs, [manual])
    }

    func testFailedCommitDoesNotPublishOrApplyAndConcurrentMutationsAreRefused() async throws {
        let initial = AppearanceActivationState(standaloneThemeID: "standalone", manuallyEnabledExtensionIDs: [])
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

    func testChangedReceiptsPrerequisitesAndRecoveryDoNotGrantEnablement() throws {
        let pack = pack("Rain", members: [rain])
        XCTAssertThrowsError(try inventory(digest: String(repeating: "b", count: 64))
            .validate(pack, manualExtensionIDs: []))
        XCTAssertThrowsError(try inventory(suppressed: true).validate(pack, manualExtensionIDs: []))
        let missingDependency = AppearanceActivationInventory(themeIDs: ["system"], extensions: [
            rain: .init(name: "Rain", contentDigest: digest, unavailableReason: nil,
                        requiredExtensionIDs: [shared], status: .stopped)
        ])
        XCTAssertThrowsError(try missingDependency.validate(pack, manualExtensionIDs: []))
        let active = AppearanceActivationState(standaloneThemeID: "standalone",
            manuallyEnabledExtensionIDs: [manual], packs: [pack], activePackID: pack.id)
        let repaired = try active.changing(.reconcileInventory(themeIDs: ["system"],
            extensionIDs: [manual], fallbackThemeID: "system"))
        XCTAssertNil(repaired.activePackID)
        XCTAssertEqual(repaired.desiredExtensionIDs, [manual])
        XCTAssertEqual(repaired.standaloneThemeID, "system")
        XCTAssertEqual(repaired.packs, [pack], "missing content does not erase the user's recipe")
    }

    func testRenamePreservesActivationAndIdentityButNewRecipeReleasesIt() throws {
        let pack = pack("Rain", members: [rain])
        let active = AppearanceActivationState(standaloneThemeID: "standalone",
            manuallyEnabledExtensionIDs: [], packs: [pack], activePackID: pack.id)
        let renamed = AppearancePack(id: pack.id, recipeRevision: pack.recipeRevision, name: "Storm",
                                     themeID: pack.themeID, extensions: pack.extensions)
        let next = try active.changing(.savePack(renamed))
        XCTAssertEqual(next.activePackID, pack.id)
        XCTAssertEqual(AppearanceCommandTarget.toggle(pack.id).commandID,
                       AppearanceCommandTarget.toggle(renamed.id).commandID)
        let edited = AppearancePack(id: pack.id, recipeRevision: UUID(), name: "Storm",
                                    themeID: pack.themeID, extensions: [])
        XCTAssertNil(try next.changing(.savePack(edited)).activePackID)
    }

    func testFileMigrationRestartAndCorruptionNeverReimportLegacyState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("appearance.json")
        let pack = pack("Rain", members: [rain])
        let legacy = AppearanceActivationState(standaloneThemeID: "standalone", manuallyEnabledExtensionIDs: [manual])
        let store = AppearanceActivationStore(url: url)
        let migrated = try await store.load(migrating: legacy)
        XCTAssertEqual(migrated, legacy)
        let active = try legacy.changing(.savePack(pack)).changing(.activatePack(pack.id))
        try await store.save(active)
        let restored = try await AppearanceActivationStore(url: url).load(migrating: legacy)
        XCTAssertEqual(restored, active)
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

    func testRecoveryReadsLegacyWithoutWritingAndAllowsExplicitOff() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("appearance.json")
        let legacy = AppearanceActivationState(standaloneThemeID: "system", manuallyEnabledExtensionIDs: [manual])
        let store = AppearanceActivationStore(url: url)
        let restored = try await store.load(migrating: legacy, persistMigration: false)
        XCTAssertEqual(restored, legacy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        try await store.save(legacy.changing(.setExtensionEnabled(manual, false)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testRealHostMenuRouteCommitsPackAndRefusesStaleCommand() async throws {
        let pack = pack("Rain", members: [rain])
        let state = AppearanceActivationState(standaloneThemeID: "system", manuallyEnabledExtensionIDs: [], packs: [pack])
        var projected: AppearanceActivationState?
        let service = AppearanceActivationService(state: state, persistence: AppearanceTestPersistence(),
            inventory: { self.inventory() }, reconcile: { _, next in projected = next })
        let host = AppearanceActivationHost(service: service, inventory: { self.inventory() })
        AppearanceCommands.refresh(host: host)
        defer { CommandRegistry.shared.replaceAppearanceCommands([]) }
        let delegate = AppDelegate()
        delegate.appearanceHost = host
        let id = AppearanceCommandTarget.activate(pack.id).commandID
        let item = NSMenuItem(title: "Activate", action: NSSelectorFromString("performHostMenuCommand:"), keyEquivalent: "")
        item.representedObject = id
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: delegate, from: item))
        for _ in 0..<200 where service.state.activePackID == nil { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(projected?.activePackID, pack.id)
        try await service.perform(.removePack(pack.id))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: delegate, from: item))
        await Task.yield()
        XCTAssertNil(service.state.activePackID)
        XCTAssertEqual(service.state.revision, 2)
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
            let packs = (0..<min(count, AppearancePack.maximumCount)).map { pack("Pack \($0)", members: [rain]) }
            let inventory = AppearanceActivationInventory(themeIDs: Set(themes.map { $0.id.rawValue }).union(["system"]),
                                                         extensions: self.inventory().extensions)
            let state = AppearanceActivationState(standaloneThemeID: "system", manuallyEnabledExtensionIDs: [], packs: packs)
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
            print("Appearance catalogue: \(count) themes, \(packs.count) packs, build+availability \(catalogDuration * 1000) ms; search \(searchDuration * 1000) ms")
        }
    }
}
