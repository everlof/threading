import AppKit
import ThreadingExtensionKit
import XCTest
@testable import Threading

/// An extension that ships a theme may bind its decorations to that theme. The registry answers
/// every lookup through the theme in force, tells only the affected components when the answer
/// moves, refuses a scope that could never apply, and the phone's projected backdrop follows the
/// same answer as the Mac's plane.
@MainActor
final class ComponentThemeScopeTests: XCTestCase {

    // MARK: - Fixtures

    private static let storm = "com.example.storm"
    private static let rain = "com.example.rain"

    private static func source(_ identifier: String) -> ComponentCustomizationSource {
        ComponentCustomizationSource(
            extensionIdentifier: identifier,
            processGeneration: "generation-\(identifier)",
            order: 0
        )
    }

    private static let backdrop = ExtensionNode.overlay(
        base: .image(.systemSymbol("cloud.fill"), role: .backdrop, accessibilityLabel: nil),
        overlay: .proceed
    )

    private static let surfaceBackdrop = ExtensionNode.overlay(
        base: .customSurface(
            .metal(ExtensionMetalSurface(
                shaderResource: "Resources/aurora.metal",
                preferredFramesPerSecond: 24
            )),
            accessibilityLabel: nil
        ),
        overlay: .proceed
    )

    private static let windowHook = ExtensionNode.stack(
        axis: .horizontal,
        spacing: .none,
        children: [.proceed, .text("Storm accessory", role: .detail)]
    )

    private let swatch = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
        NSColor.systemTeal.setFill()
        rect.fill()
        return true
    }

    /// A contributor the test moves by hand, for the cases that are about the registry's own
    /// bookkeeping rather than about the app's theme library.
    private final class Contributor {
        var identifier: String?
    }

    private func registry(
        contributor: Contributor? = nil
    ) throws -> ComponentCustomizationRegistry {
        let registry = contributor.map { box in
            ComponentCustomizationRegistry(
                themeScope: ComponentThemeScopeOracle { box.identifier }
            )
        } ?? ComponentCustomizationRegistry()
        for contract in [
            ThreadingComponentCatalog.sidebarBackdrop,
            ThreadingComponentCatalog.displayBackdrop,
            ThreadingComponentCatalog.composerBackdrop,
            ThreadingComponentCatalog.applicationMainWindow
        ] {
            try registry.register(contract)
        }
        return registry
    }

    private func hookOwners(
        _ registry: ComponentCustomizationRegistry,
        _ target: ExtensionComponentTarget = .sidebarBackdrop()
    ) -> [String] {
        registry.customization(for: target).hooks.map(\.extensionIdentifier)
    }

    private final class Changes {
        var posted: [Set<ExtensionComponentTarget>?] = []
        var last: Set<ExtensionComponentTarget>? { posted.last ?? nil }
    }

    private func recordChanges() -> (Changes, AppEventObservations) {
        let changes = Changes()
        let events = AppEventObservations()
        events.observe(ComponentCustomizationDidChange.self) { change in
            changes.posted.append(change.targets)
        }
        return (changes, events)
    }

    private static let mainWindowTarget = ExtensionComponentTarget(
        component: .applicationMainWindow,
        contractVersion: 1
    )

    // MARK: - The real theme library

    private var preservedTheme: AppTheme?
    private var preservedThemeID: String?
    private var preservedActivate: ((URL) -> Bool)?
    private var preservedDeactivate: ((URL) -> Void)?

    override func setUp() async throws {
        try await super.setUp()
        preservedTheme = AppThemeLibrary.current
        preservedThemeID = PreferenceStore.shared.string(forKey: "appThemeID")
        preservedActivate = ExtensionAppearanceRegistry.shared.activateFont
        preservedDeactivate = ExtensionAppearanceRegistry.shared.deactivateFont
        ExtensionAppearanceRegistry.shared.activateFont = { _ in true }
        ExtensionAppearanceRegistry.shared.deactivateFont = { _ in }
    }

    override func tearDown() async throws {
        ExtensionAppearanceRegistry.shared.replace(contributions: [])
        if let preservedActivate { ExtensionAppearanceRegistry.shared.activateFont = preservedActivate }
        if let preservedDeactivate { ExtensionAppearanceRegistry.shared.deactivateFont = preservedDeactivate }
        if let preservedThemeID {
            PreferenceStore.shared.set(preservedThemeID, forKey: "appThemeID")
        } else {
            PreferenceStore.shared.removeObject(forKey: "appThemeID")
        }
        if let preservedTheme { AppThemeLibrary.installResolved(preservedTheme) }
        try await super.tearDown()
    }

    /// Storm ships a theme and an `ownThemes` sidebar backdrop. Wearing Storm draws it, any
    /// other theme takes it down, Storm again puts it back — and a Duplicate to Edit copy of
    /// Storm is the person's own theme, which wears no extension's decorations.
    func testAScopedBackdropIsDrawnOnlyWithItsOwnTheme() throws {
        let stormTheme = try AppThemeEditing.duplicate(
            AppThemeStyles.cyberpunk,
            id: AppThemeID("ext.\(Self.storm).storm"),
            name: "Storm"
        )
        ExtensionAppearanceRegistry.shared.replace(contributions: [
            .init(
                extensionIdentifier: Self.storm,
                extensionName: "Storm",
                themes: [stormTheme],
                fontURLs: []
            )
        ])
        XCTAssertEqual(
            ExtensionAppearanceRegistry.shared.contributorIdentifier(forThemeID: stormTheme.id),
            Self.storm
        )
        let other = AppThemeStyles.threading
        AppThemeLibrary.installResolved(other)

        let registry = try registry()
        try registry.replacePatches(
            [.init(id: "dunes", target: .sidebarBackdrop(), hook: Self.backdrop, themeScope: .ownThemes)],
            from: Self.source(Self.storm)
        )
        let plane = ExtensionBackdropPlaneView(
            placement: .sidebar,
            lookup: registry.customization(for:),
            imageResolver: { [swatch] _, _ in swatch }
        )
        XCTAssertEqual(hookOwners(registry), [], "under another theme the backdrop is absent")
        XCTAssertFalse(plane.isDressed)

        AppThemeLibrary.installResolved(stormTheme)
        XCTAssertEqual(hookOwners(registry), [Self.storm])
        XCTAssertTrue(plane.isDressed, "the theme switch reaches the plane through the registry")

        AppThemeLibrary.installResolved(other)
        XCTAssertEqual(hookOwners(registry), [])
        XCTAssertFalse(plane.isDressed)

        AppThemeLibrary.installResolved(stormTheme)
        XCTAssertTrue(plane.isDressed, "back again with its theme")

        let copy = try AppThemeEditing.duplicate(
            stormTheme,
            id: AppThemeLibrary.makeCustomID(),
            name: "Storm Copy"
        )
        AppThemeLibrary.installResolved(copy)
        XCTAssertNil(ExtensionAppearanceRegistry.shared.contributorIdentifier(forThemeID: copy.id))
        XCTAssertEqual(hookOwners(registry), [], "a duplicated theme is a plain custom theme")
        XCTAssertFalse(plane.isDressed)
    }

    /// Removing the package takes its theme — and with it every reason to draw the backdrop.
    func testRemovingTheContributionTakesTheScopedBackdropDown() throws {
        let stormTheme = try AppThemeEditing.duplicate(
            AppThemeStyles.cyberpunk,
            id: AppThemeID("ext.\(Self.storm).storm"),
            name: "Storm"
        )
        let contribution = ExtensionAppearanceRegistry.Contribution(
            extensionIdentifier: Self.storm,
            extensionName: "Storm",
            themes: [stormTheme],
            fontURLs: []
        )
        ExtensionAppearanceRegistry.shared.replace(contributions: [contribution])
        AppThemeLibrary.installResolved(stormTheme)
        let registry = try registry()
        try registry.replacePatches(
            [.init(id: "dunes", target: .sidebarBackdrop(), hook: Self.backdrop, themeScope: .ownThemes)],
            from: Self.source(Self.storm)
        )
        XCTAssertEqual(hookOwners(registry), [Self.storm])

        let (changes, events) = recordChanges()
        ExtensionAppearanceRegistry.shared.replace(contributions: [])
        XCTAssertEqual(hookOwners(registry), [])
        XCTAssertTrue(
            changes.posted.contains { $0?.contains(.sidebarBackdrop()) == true },
            "the contribution change re-renders the backdrop target"
        )
        withExtendedLifetime(events) {}
    }

    // MARK: - The registry's own bookkeeping

    func testAnUnscopedDecorationIsUnchangedByEveryThemeSwitch() throws {
        let contributor = Contributor()
        let registry = try registry(contributor: contributor)
        try registry.replacePatches(
            [.init(id: "rain", target: .sidebarBackdrop(), hook: Self.backdrop)],
            from: Self.source(Self.rain)
        )
        let (changes, events) = recordChanges()

        for identifier in [nil, Self.storm, Self.rain, nil] {
            contributor.identifier = identifier
            registry.reevaluateThemeScope()
            XCTAssertEqual(hookOwners(registry), [Self.rain])
        }
        XCTAssertEqual(changes.posted.count, 0, "nothing scoped, nothing to re-render")
        withExtendedLifetime(events) {}
    }

    /// A theme switch re-renders exactly the targets whose `ownThemes` patches came or went:
    /// never an unscoped patch's target, never another extension's.
    func testAThemeSwitchPostsOnlyTheAffectedTargets() throws {
        let contributor = Contributor()
        let registry = try registry(contributor: contributor)
        try registry.replacePatches(
            [
                .init(id: "sidebar", target: .sidebarBackdrop(), hook: Self.backdrop, themeScope: .ownThemes),
                .init(id: "display", target: .displayBackdrop(), hook: Self.backdrop, themeScope: .ownThemes),
                .init(id: "composer", target: .composerBackdrop(), hook: Self.backdrop)
            ],
            from: Self.source(Self.storm)
        )
        try registry.replacePatches(
            [.init(id: "window", target: Self.mainWindowTarget, hook: Self.windowHook, themeScope: .ownThemes)],
            from: Self.source(Self.rain)
        )
        let (changes, events) = recordChanges()

        contributor.identifier = Self.storm
        registry.reevaluateThemeScope()
        XCTAssertEqual(changes.posted.count, 1)
        XCTAssertEqual(changes.last, [.sidebarBackdrop(), .displayBackdrop()])
        XCTAssertEqual(hookOwners(registry, .composerBackdrop()), [Self.storm])
        XCTAssertEqual(hookOwners(registry, Self.mainWindowTarget), [])

        contributor.identifier = Self.rain
        registry.reevaluateThemeScope()
        XCTAssertEqual(changes.last, [.sidebarBackdrop(), .displayBackdrop(), Self.mainWindowTarget])
        XCTAssertEqual(hookOwners(registry, Self.mainWindowTarget), [Self.rain])
        XCTAssertEqual(hookOwners(registry), [])

        contributor.identifier = nil
        registry.reevaluateThemeScope()
        XCTAssertEqual(changes.last, [Self.mainWindowTarget])

        let count = changes.posted.count
        registry.reevaluateThemeScope()
        XCTAssertEqual(changes.posted.count, count, "an unmoved answer posts nothing")
        withExtendedLifetime(events) {}
    }

    /// A Tune drag's ticks are unsaved previews of the same theme; only the settle is heard.
    func testALivePreviewTickIsIgnoredAndTheSettleIsHeard() throws {
        let contributor = Contributor()
        let registry = try registry(contributor: contributor)
        try registry.replacePatches(
            [.init(id: "sidebar", target: .sidebarBackdrop(), hook: Self.backdrop, themeScope: .ownThemes)],
            from: Self.source(Self.storm)
        )
        let (changes, events) = recordChanges()
        contributor.identifier = Self.storm

        NotificationCenter.default.post(
            AppThemeDidChange(themeID: AppThemeLibrary.current.id, isLivePreview: true)
        )
        XCTAssertEqual(changes.posted.count, 0)

        NotificationCenter.default.post(AppThemeDidChange(themeID: AppThemeLibrary.current.id))
        XCTAssertEqual(changes.posted.count, 1)
        XCTAssertEqual(changes.last, [.sidebarBackdrop()])
        withExtendedLifetime(events) {}
    }

    // MARK: - Publication

    /// The host refuses `ownThemes` from an extension that ships no theme, with the SDK's own
    /// sentence, and applies a manifest's declared floor to a patch that states nothing.
    func testThePublicationRouteRefusesAnImpossibleScopeAndAppliesTheManifestFloor() async throws {
        let registry = try registry(contributor: Contributor())
        let service = ExtensionHostService(
            registry: registry,
            baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:1/v1"))
        )

        let themeless = try client(
            service,
            identifier: Self.rain,
            scope: .always,
            contributesThemes: false
        )
        do {
            try await themeless.client.publishComponentPatches([
                .init(id: "dunes", target: .sidebarBackdrop(), hook: Self.backdrop, themeScope: .ownThemes)
            ])
            XCTFail("an `ownThemes` patch from an extension without a theme must be refused")
        } catch let error as ExtensionHostClientError {
            guard case .rejected(let status, let message) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(status, 422)
            XCTAssertTrue(message.contains("contributes none"), message)
        }
        XCTAssertEqual(registry.themeScopedPatchCounts(extensionIdentifier: Self.rain).total, 0)

        let bound = try client(
            service,
            identifier: Self.storm,
            scope: .ownThemes,
            contributesThemes: true
        )
        try await bound.client.publishComponentPatches([
            .init(id: "dunes", target: .sidebarBackdrop(), hook: Self.backdrop)
        ])
        let counts = registry.themeScopedPatchCounts(extensionIdentifier: Self.storm)
        XCTAssertEqual(counts.scoped, 1, "the manifest's floor scopes a patch that states nothing")
        XCTAssertEqual(counts.total, 1)
        for descriptor in [themeless.descriptor, bound.descriptor] {
            ExtensionHostDescriptorTransport.forget(descriptor: descriptor)
            close(descriptor)
        }
    }

    private func client(
        _ service: ExtensionHostService,
        identifier: String,
        scope: ExtensionComponentThemeScope,
        contributesThemes: Bool
    ) throws -> (client: ExtensionHostClient, descriptor: Int32) {
        let authorization = try XCTUnwrap(
            try service.authorize(
                extensionIdentifier: identifier,
                processGeneration: "generation-\(identifier)",
                order: 0,
                capabilities: [.componentCustomization],
                componentThemeScope: scope,
                contributesThemes: contributesThemes,
                transport: .descriptor
            ))
        let descriptor = try XCTUnwrap(authorization.childDescriptor)
        return (
            ExtensionHostClient(connection: ExtensionHostConnection(
                baseURL: ExtensionHostConnection.descriptorBaseURL,
                bearerToken: authorization.connection.bearerToken,
                descriptor: descriptor
            )),
            descriptor
        )
    }

    // MARK: - Review

    /// The install review says so when the manifest binds the decorations, and only then; an
    /// update says so when the binding moves either way.
    func testTheReviewSaysTheDecorationsFollowTheirThemes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("theme-scope-review-\(UUID().uuidString)")
        let stormTheme = try AppThemeEditing.duplicate(
            AppThemeStyles.cyberpunk,
            id: AppThemeID("ext.\(Self.storm).storm"),
            name: "Storm"
        )
        func manifest(_ scope: ExtensionComponentThemeScope) -> ExtensionManifest {
            ExtensionManifest(
                identifier: Self.storm,
                name: "Storm",
                version: scope == .ownThemes ? "2.0.0" : "1.0.0",
                runtime: .webAssembly,
                executable: "bin/storm.wasm",
                capabilities: [.componentCustomization, .themeProvider],
                themes: [.init(id: "storm", resource: "themes/storm.json")],
                componentThemeScope: scope
            )
        }
        func proposal(_ scope: ExtensionComponentThemeScope) -> ExtensionInstallProposal {
            ExtensionInstallProposal(bundle: ThreadingExtensionBundle(
                rootURL: root,
                executableURL: root.appendingPathComponent("bin/storm.wasm"),
                sourceURL: root.appendingPathComponent("Source", isDirectory: true),
                manifest: manifest(scope),
                themes: [.init(contributionID: "storm", theme: stormTheme)]
            ))
        }

        let bound = proposal(.ownThemes).message
        XCTAssertTrue(bound.contains("appear only while one of these themes is selected"), bound)
        XCTAssertTrue(bound.contains("Duplicate to Edit"))
        XCTAssertFalse(proposal(.always).message.contains("appear only while"))

        let narrowing = ExtensionUpdatePlan(installed: manifest(.always), candidate: manifest(.ownThemes))
        XCTAssertTrue(narrowing.confirmation(name: "Storm").message
            .contains("will appear only while one of its own themes is selected"))
        XCTAssertFalse(narrowing.requiresApproval, "a scope is presentation, not authority")
        let widening = ExtensionUpdatePlan(installed: manifest(.ownThemes), candidate: manifest(.always))
        XCTAssertTrue(widening.confirmation(name: "Storm").message
            .contains("no longer limited to its own themes"))
        XCTAssertFalse(ExtensionUpdatePlan(installed: manifest(.always), candidate: manifest(.always))
            .confirmation(name: "Storm").message.contains("own themes"))
    }

    // MARK: - The phone

    /// The phone's projected backdrop is read through the same resolved customization, so a
    /// scoped surface is offered exactly while its theme is in force.
    func testThePhoneBackdropFollowsTheSameScope() throws {
        let contributor = Contributor()
        let registry = try registry(contributor: contributor)
        try registry.replacePatches(
            [.init(id: "aurora", target: .sidebarBackdrop(), hook: Self.surfaceBackdrop, themeScope: .ownThemes)],
            from: Self.source(Self.storm)
        )
        let previous = ComponentCustomizationProviderSlot.shared.provider
        ComponentCustomizationProviderSlot.shared.provider = registry
        defer { ComponentCustomizationProviderSlot.shared.provider = previous }
        let root = FileManager.default.temporaryDirectory
        let resources: (String) -> (root: URL, generation: String)? = { identifier in
            identifier == Self.storm ? (root, "generation") : nil
        }

        XCTAssertNil(RemoteThemeAssets.surfaceHook(resourceRoot: resources))

        contributor.identifier = Self.storm
        registry.reevaluateThemeScope()
        let hook = try XCTUnwrap(RemoteThemeAssets.surfaceHook(resourceRoot: resources))
        XCTAssertEqual(hook.identifier, Self.storm)
        XCTAssertEqual(hook.specification.shaderResource, "Resources/aurora.metal")

        contributor.identifier = Self.rain
        registry.reevaluateThemeScope()
        XCTAssertNil(RemoteThemeAssets.surfaceHook(resourceRoot: resources))
    }
}
