import AppKit
import ThreadingPluginKit

/// Hosts one native plugin's view.
///
/// The host owns placement, lifetime, trust and the theme; the plugin owns everything inside the
/// rectangle it is given. That split is the whole tier, and it is the same one `.media` already
/// uses for content whose pixels move on their own.
///
/// A plugin that will not load is a *state*, not an absence: the pane says which refusal happened,
/// because "the plugin did not appear" is not a diagnosis and this is the one tier where the
/// operating system offers no error of its own.
@MainActor
final class NativePluginPaneViewController: NSViewController {

    typealias VerifyPlugin = @Sendable (URL) -> Result<
        NativePluginCatalog.VerifiedCandidate,
        PluginLoadFailure
    >

    private enum Metrics {
        static let messageWidth: CGFloat = 320
    }

    let bundleURL: URL
    let owningSessionID: SessionID?
    private(set) var loaded: ThreadingNativePlugin?
    private(set) var refusal: PluginLoadFailure?
    private let appEvents = AppEventObservations()
    private let loadPlugin: ((URL) -> Result<ThreadingNativePlugin, PluginLoadFailure>)?
    private let verifyPlugin: VerifyPlugin
    private let managedOffer: NativePluginManagedOffer?
    /// A saved tab can name a different bundle at the same install filename after an update.
    /// Check its verified identity before the principal class is mapped.
    private let expectedBundleIdentifier: String?
    private let expectedInstalledIdentity: PluginLoader.PluginIdentity?
    /// A host-selected capability for verified first-party Device Logs. Third-party plugins do
    /// not receive Threading's managed executable merely because they share this loading tier.
    private let managedIPhoneToolPath: String?
    /// Plugin-specific routing attached to the latest reveal. Kept separately from placement so
    /// changing a target cannot rewrite the session/project identity the host owns.
    private var activationArguments: [String: String]
    private var verifiedCandidate: NativePluginCatalog.VerifiedCandidate?
    private(set) var verifiedBundleIdentifier: String?
    private var loadTask: Task<Void, Never>?
    private var onDemandInstallable = false
    private var isInstallingOnDemand = false
    var onTitleChange: (() -> Void)?
    /// Installed by the pane host, so a tool reveals its section in the window and dock that
    /// actually own this loaded plugin instance.
    var onRevealSection: ((String) -> Bool)?
    private(set) var paneSection: String?
    private var paneSectionTitle: String?
    private var sectionOwner: NativePluginPaneViewController?
    private var sectionObservers: [UUID: () -> Void] = [:]
    private var sectionChildren: [UUID: WeakPane] = [:]
    private let sectionObserverID = UUID()
    private var visibilityGeneration = 0
    private final class WeakPane {
        weak var value: NativePluginPaneViewController?
        init(_ value: NativePluginPaneViewController) { self.value = value }
    }
    private struct SectionOwnerKey: Hashable {
        let bundlePath: String
        let sessionID: SessionID
        let identity: PluginLoader.PluginIdentity?
    }
    private static var sectionOwners: [SectionOwnerKey: WeakPane] = [:]
    private static var sectionOwnerInsertions = 0

    /// Resolves signed static metadata from the worker's cache without inspecting a bundle on main.
    static func forBundle(
        _ bundleURL: URL,
        sessionID: SessionID,
        section: String? = nil,
        expectedIdentifier: String? = nil
    ) -> NativePluginPaneViewController? {
        if let pane = CommandRegistry.shared.nativePluginPane(at: bundleURL) {
            let selected = section ?? pane.primarySection
            guard pane.contains(selected) else { return nil }
            let managedSections = NativePluginManagedOffer.paneOffer(at: bundleURL)?.paneSections ?? []
            let titles = Dictionary(uniqueKeysWithValues: pane.sections.map { declared in
                let localizedKey = managedSections.first {
                    $0.identifier == declared.identifier
                }?.titleKey
                return (declared.identifier, localizedKey.map { L10n.string($0) } ?? declared.title)
            })
            return sectioned(
                bundleURL: bundleURL, sessionID: sessionID, section: selected,
                primarySection: pane.primarySection, titles: titles,
                managedIPhoneToolPath: pane.pluginIdentifier == NativePluginManagedOffer.deviceLogs.identifier
                    ? Pymobiledevice3ManagedTool.executable().path : nil,
                expectedBundleIdentifier: expectedIdentifier ?? pane.pluginIdentifier,
                expectedInstalledIdentity: pane.verifiedInstalledIdentity
            )
        }
        let managedOffer = NativePluginManagedOffer.paneOffer(at: bundleURL)
        if managedOffer?.paneSections.isEmpty == false,
           CommandRegistry.shared.hasScannedNativePlugin(at: bundleURL) {
            return nil // Installed first-party sections must agree with their signed declaration.
        }
        guard let offer = managedOffer,
              let primarySection = offer.primaryPaneSection else {
            guard section == nil else { return nil }
            return NativePluginPaneViewController(
                bundleURL: bundleURL, owningSessionID: sessionID,
                expectedBundleIdentifier: expectedIdentifier
            )
        }
        let selectedSection = section ?? primarySection
        guard offer.containsPaneSection(selectedSection) else { return nil }
        let titles = Dictionary(uniqueKeysWithValues: offer.paneSections.map {
            ($0.identifier, $0.title)
        })
        return sectioned(
            bundleURL: bundleURL,
            sessionID: sessionID,
            section: selectedSection,
            primarySection: primarySection,
            titles: titles,
            managedIPhoneToolPath: offer.identifier == NativePluginManagedOffer.deviceLogs.identifier
                ? Pymobiledevice3ManagedTool.executable().path : nil,
            expectedBundleIdentifier: expectedIdentifier ?? offer.identifier
        )
    }

    /// Sections of one pane share the verified plugin instance and its live resources. The host
    /// supplies their visible names; the plugin supplies the views behind the section ids.
    static func sectioned(
        bundleURL: URL,
        sessionID: SessionID,
        section: String,
        primarySection: String,
        titles: [String: String],
        managedIPhoneToolPath: String? = nil,
        expectedBundleIdentifier: String? = nil,
        expectedInstalledIdentity: PluginLoader.PluginIdentity? = nil
    ) -> NativePluginPaneViewController {
        // Session count is unbounded. Reap dead weak entries in batches rather than walking the
        // whole owner table whenever a user opens another section tab.
        if sectionOwnerInsertions >= 64 {
            sectionOwners = sectionOwners.filter { $0.value.value != nil }
            sectionOwnerInsertions = 0
        }
        let key = SectionOwnerKey(
            bundlePath: bundleURL.standardizedFileURL.path,
            sessionID: sessionID,
            identity: expectedInstalledIdentity
        )
        let selectedSection = titles[section] == nil ? primarySection : section
        let owner: NativePluginPaneViewController
        if let existing = sectionOwners[key]?.value {
            owner = existing
        } else {
            var arguments = ["hostPaneSections": "true"]
            if managedIPhoneToolPath != nil { arguments["stream"] = primarySection }
            owner = NativePluginPaneViewController(bundleURL: bundleURL, owningSessionID: sessionID,
                managedIPhoneToolPath: managedIPhoneToolPath,
                expectedBundleIdentifier: expectedBundleIdentifier,
                expectedInstalledIdentity: expectedInstalledIdentity,
                activationArguments: arguments)
            owner.paneSection = primarySection
            owner.paneSectionTitle = titles[primarySection]
            sectionOwners[key] = WeakPane(owner)
            sectionOwnerInsertions += 1
        }
        guard selectedSection != primarySection else { return owner }
        let sibling = NativePluginPaneViewController(
            bundleURL: bundleURL, owningSessionID: sessionID,
            expectedBundleIdentifier: expectedBundleIdentifier,
            expectedInstalledIdentity: expectedInstalledIdentity
        )
        sibling.paneSection = selectedSection
        sibling.paneSectionTitle = titles[selectedSection]
        sibling.sectionOwner = owner
        owner.sectionChildren[sibling.sectionObserverID] = WeakPane(sibling)
        return sibling
    }

    /// A section can be docked elsewhere while its shared owner keeps the plugin loaded. Route a
    /// tool to that section's actual tab host, falling back to the owner's host for a new tab.
    func revealToolSection(_ identifier: String) -> Bool {
        let owner = sectionOwner ?? self
        if let sibling = owner.sectionChildren.values.first(where: {
            $0.value?.paneSection == identifier
        })?.value {
            return sibling.onRevealSection?(identifier) == true
        }
        return owner.onRevealSection?(identifier) == true
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        visibilityGeneration += 1
        if let paneSection { loaded?.setPaneSectionPresented?(identifier: paneSection, presented: true) }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        visibilityGeneration += 1
        let generation = visibilityGeneration
        // Reparenting during one drop is not a capture stop/start. A real hide settles on the
        // next main turn; reappearing in the destination cancels this pending visibility edge.
        DispatchQueue.main.async { [weak self] in
            guard let self, visibilityGeneration == generation, let paneSection else { return }
            loaded?.setPaneSectionPresented?(identifier: paneSection, presented: false)
        }
    }

    private func installSection() {
        guard let owner = sectionOwner, let paneSection else { return }
        loaded = owner.loaded
        refusal = owner.refusal
        onDemandInstallable = owner.onDemandInstallable
        isInstallingOnDemand = owner.isInstallingOnDemand
        view.subviews.forEach { $0.removeFromSuperview() }
        if let pane = loaded?.makePaneSectionView?(identifier: paneSection) {
            install(pane)
            loaded?.setPaneSectionPresented?(identifier: paneSection, presented: view.window != nil)
        } else if let refusal { install(refusalView(refusal)) }
        onTitleChange?()
    }

    /// The plugin's own identity once it loads, so a crash-quarantine policy can name it rather
    /// than pointing at a path.
    var pluginIdentifier: String? { loaded?.pluginIdentifier }

    /// A signed static declaration can persist its route before the pane maps plugin code.
    var declaredBundleIdentifier: String? { expectedBundleIdentifier }

    /// What the tab calls it. Verified bundle metadata replaces the filename once inspection
    /// finishes, so a refusal is still named without rereading a mutable install path on main.
    var displayName: String {
        if let paneSectionTitle { return paneSectionTitle }
        return verifiedCandidate?.bundle.displayName ?? managedOffer?.name ?? L10n.string("Plugin")
    }

    struct ApprovalRequest: Equatable {
        let identity: PluginLoader.PluginIdentity
        let displayName: String
    }

    /// The identity and name are a pair from one verified build. Keeping this derivation separate
    /// also makes the replacement-between-verification-and-approval regression observable.
    var approvalRequest: ApprovalRequest? {
        guard let bundle = verifiedCandidate?.bundle,
              let identity = bundle.identity else { return nil }
        return ApprovalRequest(
            identity: identity,
            displayName: bundle.displayName
        )
    }

    /// Injected so a test can place a pane in a project without reaching the shared store, and
    /// defaulted so no call site has to care. `nil` from the closure means "not resolvable", which
    /// is a pane with no project rather than an error: a plugin that only draws needs neither.
    private let resolveStore: () -> ProjectStore?

    init(
        bundleURL: URL,
        owningSessionID: SessionID?,
        managedIPhoneToolPath: String? = nil,
        expectedBundleIdentifier: String? = nil,
        expectedInstalledIdentity: PluginLoader.PluginIdentity? = nil,
        activationArguments: [String: String] = [:],
        resolveStore: @escaping () -> ProjectStore? = { ProjectStore.shared },
        loadPlugin: ((URL) -> Result<ThreadingNativePlugin, PluginLoadFailure>)? = nil,
        verifyPlugin: @escaping VerifyPlugin = { url in
            NativePluginCatalog.verify(
                url,
                isBundled: NativePluginCatalog.isBundled(url)
            )
        }
    ) {
        self.bundleURL = bundleURL
        self.owningSessionID = owningSessionID
        self.managedOffer = NativePluginManagedOffer.at(bundleURL)
        self.managedIPhoneToolPath = managedIPhoneToolPath
        self.expectedBundleIdentifier = expectedBundleIdentifier
        self.expectedInstalledIdentity = expectedInstalledIdentity
        self.activationArguments = activationArguments
        self.resolveStore = resolveStore
        self.loadPlugin = loadPlugin
        self.verifyPlugin = verifyPlugin
        super.init(nibName: nil, bundle: nil)
        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in
            guard let self, sectionOwner == nil, let plugin = loaded else { return }
            plugin.apply(theme: NativePluginCatalog.theme())
        }
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        loadTask?.cancel()
        // The tools go with the pane: they act on a stream and a view that are about to be gone.
        MainActor.assumeIsolated {
            if let paneSection {
                loaded?.setPaneSectionPresented?(identifier: paneSection, presented: false)
            }
            sectionOwner?.sectionObservers.removeValue(forKey: sectionObserverID)
            sectionOwner?.sectionChildren.removeValue(forKey: sectionObserverID)
            NativePluginRuntime.shared.deregister(self)
        }
    }

    override func loadView() {
        view = NSView()
        loadViewContents()
    }

    private func loadViewContents() {
        if let sectionOwner {
            _ = sectionOwner.view
            sectionOwner.sectionObservers[sectionObserverID] = { [weak self] in self?.installSection() }
            installSection()
            return
        }
        if let loadPlugin {
            finish(loadPlugin(bundleURL))
            return
        }
        if let verifiedCandidate {
            load(verifiedCandidate)
            return
        }

        let bundleURL = bundleURL
        let verifyPlugin = verifyPlugin
        let managedOffer = managedOffer
        loadTask = Task { [weak self] in
            let (canInstall, verification) = await Task.detached(priority: .userInitiated) {
                (
                    Self.canInstallOnDemand(at: bundleURL, offer: managedOffer),
                    verifyPlugin(bundleURL)
                )
            }.value
            guard let self, !Task.isCancelled else { return }
            onDemandInstallable = canInstall
            switch verification {
            case .failure(let failure):
                finish(.failure(failure))
            case .success(let candidate):
                load(candidate)
            }
        }
    }

    private func load(_ candidate: NativePluginCatalog.VerifiedCandidate) {
        if let expectedBundleIdentifier,
           candidate.bundleIdentifier != expectedBundleIdentifier {
            finish(.failure(.buildChanged(identifier: expectedBundleIdentifier)))
            return
        }
        if let expectedInstalledIdentity,
           candidate.bundle.identity != expectedInstalledIdentity {
            finish(.failure(.buildChanged(identifier: expectedBundleIdentifier ?? bundleURL.lastPathComponent)))
            return
        }
        verifiedBundleIdentifier = candidate.bundleIdentifier
        let result = NativePluginCatalog.load(candidate)

        // Mapping reserves one canonical candidate for an installed identity. Reopened panes may
        // have verified a redundant staging copy before finding it; retain the canonical object
        // and let the redundant copy schedule its cleanup off-main. An unapproved candidate is
        // deliberately retained because its exact identity and name back the approval prompt.
        if !candidate.isBundled,
           let identity = candidate.bundle.identity,
           let canonical = NativePluginCatalog.cachedInstalledCandidate(identity: identity) {
            verifiedCandidate = canonical
        } else if candidate.isBundled || requiresApproval(result) {
            verifiedCandidate = candidate
        } else {
            verifiedCandidate = nil
        }
        finish(result)
        // A manual plugin has no trusted identifier to persist until verification finishes.
        // Notify the host even for an approval refusal whose visible title stayed the same.
        onTitleChange?()
    }

    private func requiresApproval(
        _ result: Result<ThreadingNativePlugin, PluginLoadFailure>
    ) -> Bool {
        guard case .failure(let failure) = result,
              case .notApproved = failure else { return false }
        return true
    }

    private func finish(_ result: Result<ThreadingNativePlugin, PluginLoadFailure>) {
        loadTask = nil
        switch result {
        case .success(let plugin):
            guard let pane = plugin.makePaneView?(context: context()) else {
                let failure = PluginLoadFailure.capabilityUnavailable(name: "pane")
                loaded = nil
                refusal = failure
                install(refusalView(failure))
                return
            }
            loaded = plugin
            refusal = nil
            NativePluginRuntime.shared.register(plugin, controller: self, sessionID: owningSessionID)
            install(pane)
            plugin.apply(theme: NativePluginCatalog.theme())
            if let paneSection {
                plugin.setPaneSectionPresented?(identifier: paneSection, presented: view.window != nil)
            }
        case .failure(let failure):
            loaded = nil
            refusal = failure
            install(refusalView(failure))
        }
        sectionObservers.values.forEach { $0() }
    }

    /// Rebuilds through the full loader boundary. Used after an approval and kept internal so a
    /// regression test can prove a successful retry replaces both the refusal view and its state.
    func reloadPresentation() {
        loadTask?.cancel()
        loadTask = nil
        NativePluginRuntime.shared.deregister(self)
        loaded = nil
        refusal = nil
        view.subviews.forEach { $0.removeFromSuperview() }
        loadViewContents()
    }

    /// Reveals the already-loaded plugin with a more specific subject without rebuilding it.
    /// If verification is still in flight, the arguments are retained and the first pane is made
    /// with the newest target instead.
    func activate(arguments: [String: String]) {
        activationArguments.merge(arguments) { _, newest in newest }
        if let paneSection { activationArguments["stream"] = paneSection }
        loaded?.activatePane?(context: context())
    }

    /// What the plugin is told. Narrow and versioned on purpose: never a session, a project, a
    /// store or a window. If a plugin needs to know something, it gets a name here first.
    ///
    /// The names live in `NativePluginPlacement` rather than being spelled here, so the host and a
    /// plugin author read them from one place.
    private func context() -> PluginContext {
        var arguments = placement().arguments
        arguments.merge(activationArguments) { _, activation in activation }
        return PluginContext(theme: NativePluginCatalog.theme(), arguments: arguments)
    }

    /// Where the pane is, resolved from the session that owns it.
    ///
    /// The checkout comes from the session's *working* directory rather than its project's folder,
    /// because the two differ exactly when the session opted into a managed workspace. A plugin
    /// handed the project folder would read the wrong tree for every draft-worktree session, which
    /// presents as stale content rather than as a wrong path.
    private func placement() -> NativePluginPlacement {
        let toolPath: String?
        if let candidate = verifiedCandidate,
           candidate.isBundled || candidate.isManaged,
           (candidate.bundle.identity?.bundleIdentifier
                ?? Bundle(url: candidate.bundleURL)?.bundleIdentifier)
                == NativePluginCatalog.deviceLogsIdentifier {
            toolPath = managedIPhoneToolPath
        } else {
            toolPath = nil
        }
        guard let owningSessionID else {
            return NativePluginPlacement(pymobiledevice3Path: toolPath)
        }
        let store = resolveStore()
        let project = store?.project(forSessionID: owningSessionID)
        return NativePluginPlacement(
            sessionID: owningSessionID,
            projectID: project?.id,
            projectName: project?.name,
            checkoutPath: store?.workingDirectory(forSessionID: owningSessionID),
            pymobiledevice3Path: toolPath
        )
    }

    private func install(_ content: NSView) {
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.topAnchor.constraint(equalTo: view.topAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func refusalView(_ failure: PluginLoadFailure) -> NSView {
        let offer = managedOffer
        let canInstall = onDemandInstallable && Self.isRepairableInstallFailure(failure)
        let message: String
        if onDemandInstallable, let offer, case .quarantined = failure {
            message = L10n.format("%@ is paused after a crash while loading.", offer.name)
        } else if canInstall, let offer {
            message = L10n.format(
                "%@ is available as a download or update of about %@.",
                offer.name, offer.approximateDownloadSize
            )
        } else {
            message = L10n.format("This plugin was not loaded: %@", failure.description)
        }
        let label = NSTextField(wrappingLabelWithString: message)
        label.alignment = .center
        label.textColor = Design.Text.secondary
        label.applyFont(.detail())
        label.preferredMaxLayoutWidth = Metrics.messageWidth

        let host = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: Metrics.messageWidth),
        ])

        // A gate with nothing that opens it is a locked door. "Not approved" is the one refusal the
        // user can answer, so it is the one that comes with a way to answer it — here, where they
        // are already looking, rather than in a settings page they would have to be told about.
        if case .quarantined = failure {
            let retry = ThemedButton()
            retry.title = L10n.string("Retry This Plugin")
            retry.emphasis = .primary
            retry.target = self
            retry.action = #selector(retryCrashQuarantinedPlugin)
            retry.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(retry)
            NSLayoutConstraint.activate([
                retry.topAnchor.constraint(equalTo: label.bottomAnchor, constant: Design.Spacing.medium),
                retry.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            ])
        } else if canInstall, let offer {
            let install = ThemedButton()
            install.title = isInstallingOnDemand
                ? L10n.string("Installing…")
                : L10n.format("Install %@…", offer.name)
            install.isEnabled = !isInstallingOnDemand
            install.emphasis = .primary
            install.target = self
            install.action = #selector(installOnDemandPlugin)
            install.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(install)
            NSLayoutConstraint.activate([
                install.topAnchor.constraint(equalTo: label.bottomAnchor, constant: Design.Spacing.medium),
                install.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            ])
        } else if case .notApproved = failure {
            let allow = ThemedButton()
            allow.title = L10n.string("Allow This Plugin…")
            allow.emphasis = .primary
            allow.target = self
            allow.action = #selector(askAboutThisPlugin)
            allow.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(allow)
            NSLayoutConstraint.activate([
                allow.topAnchor.constraint(equalTo: label.bottomAnchor, constant: Design.Spacing.medium),
                allow.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            ])
        }
        return host
    }

    private nonisolated static func isRepairableInstallFailure(_ failure: PluginLoadFailure) -> Bool {
        switch failure {
        case .unreadableBundle, .signatureInvalid, .buildChanged:
            return true
        case .noPrincipalClass, .wrongProtocol, .apiVersionMismatch, .capabilityUnavailable,
                .notApproved, .quarantined:
            return false
        @unknown default:
            return false
        }
    }

    private nonisolated static func canInstallOnDemand(
        at bundleURL: URL,
        offer: NativePluginManagedOffer?
    ) -> Bool {
        guard offer != nil else { return false }
        if NativePluginManagedPaths.ownedVersion(
            for: bundleURL, in: NativePluginManagedPaths.directory
        ) != nil { return true }
        return !FileManager.default.fileExists(atPath: bundleURL.path)
            && (try? FileManager.default.destinationOfSymbolicLink(
                atPath: bundleURL.path
            )) == nil
    }

    @objc private func retryCrashQuarantinedPlugin() {
        let owner = sectionOwner ?? self
        guard case .quarantined(let identifier) = owner.refusal else { return }
        NativePluginCatalog.retryCrashQuarantined(identifier: identifier)
        owner.reloadPresentation()
    }

    @objc private func installOnDemandPlugin() {
        let owner = sectionOwner ?? self
        guard owner.onDemandInstallable,
              let offer = owner.managedOffer,
              owner.refusal.map(Self.isRepairableInstallFailure) == true,
              !owner.isInstallingOnDemand else { return }
        owner.isInstallingOnDemand = true
        if let refusal = owner.refusal {
            owner.view.subviews.forEach { $0.removeFromSuperview() }
            owner.install(owner.refusalView(refusal))
            owner.sectionObservers.values.forEach { $0() }
        }
        Task { @MainActor [weak owner] in
            do {
                _ = try await NativePluginManagedInstaller.install(
                    identifier: offer.identifier
                )
                owner?.isInstallingOnDemand = false
                owner?.reloadPresentation()
            } catch {
                guard let owner else { return }
                owner.isInstallingOnDemand = false
                if let refusal = owner.refusal {
                    owner.view.subviews.forEach { $0.removeFromSuperview() }
                    owner.install(owner.refusalView(refusal))
                    owner.sectionObservers.values.forEach { $0() }
                }
                if let window = owner.view.window {
                    let alert = ThemedAlert(error: error)
                    alert.messageText = L10n.format("Couldn’t Install %@", offer.name)
                    alert.informativeText = error.localizedDescription
                    alert.beginSheetModal(for: window)
                }
            }
        }
    }

    /// Asks, records, and reloads if the answer was yes.
    ///
    /// The question is asked against the *identity* the loader read, not the path: approving a
    /// plugin has to mean the bytes that were described, or an update inherits an answer nobody
    /// gave it.
    @objc private func askAboutThisPlugin() {
        // The default loading path already read and signature-validated this identity on its
        // worker. Never repeat Security-framework or bundle I/O from a button action on main.
        guard let request = approvalRequest else { return }
        NativePluginApprovalPrompt.ask(
            about: request.identity,
            named: request.displayName,
            in: view.window
        ) { [weak self] approved in
            guard let self, approved else { return }
            // Rebuild the pane the ordinary way rather than patching it: loading is what registers
            // the plugin's tools, and half-loading it would advertise tools nothing can run.
            self.reloadPresentation()
        }
    }
}
