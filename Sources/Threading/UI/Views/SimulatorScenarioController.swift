import Foundation

/// A workspace member a scenario can drive: one adopted device behind its own lease.
@MainActor
protocol SimulatorScenarioTarget: AnyObject, Sendable {
    var scenarioDeviceID: SimulatorDeviceID? { get }
    var scenarioDeviceName: String { get }
    func launchScenarioApp(_ launch: SimulatorAppLaunch, appearance: SimulatorScenarioAppearance?) async throws
    func openScenarioLink(_ link: SimulatorAppLink) async throws
}

enum SimulatorScenarioError: LocalizedError, Equatable {
    case noCheckout
    case noFile
    case unknownScenario(String)
    case noDevice
    case deviceNotInWorkspace
    case unsupported(String)
    case noSuchStep(Int, count: Int)
    case noScenarioOpen

    var errorDescription: String? {
        switch self {
        case .noCheckout:
            return L10n.string("This session has no checkout to read scenarios from.")
        case .noFile:
            return L10n.format("This checkout has no %@.", SimulatorScenarioDefaults.relativePath)
        case .unknownScenario(let id):
            return L10n.format("No scenario has the ID “%@”.", id)
        case .noDevice:
            return L10n.string("Adopt a device in the Simulator workspace first.")
        case .deviceNotInWorkspace:
            return L10n.string("That device is not in this Simulator workspace.")
        case .unsupported(let title):
            return L10n.format("No device in this workspace can open “%@”.", title)
        case .noSuchStep(let step, let count):
            return count == 0
                ? L10n.format("This scenario has no steps, so step %lld does not exist.", Int64(step))
                : L10n.format("Step %lld does not exist; this scenario has steps 0–%lld.", Int64(step), Int64(count - 1))
        case .noScenarioOpen:
            return L10n.string("No scenario is open in this workspace.")
        }
    }
}

/// What the Simulator workspace knows about its checkout's scenarios and the one it is showing.
///
/// One per workspace. The file is read off the main actor when the workspace is shown and again
/// when its menu opens, so an edit is picked up without a watcher; it is one bounded file. Device
/// work is serialized: a quick run of Next presses reaches every device in order. Applying a
/// scenario to several members runs them side by side, so an iPhone and an Android phone change
/// together.
@MainActor
final class SimulatorScenarioController {
    struct Session: Equatable {
        let id: UUID
        let scenario: SimulatorScenario
        /// The catalogue the scenario was opened from, so a reload while it runs cannot change
        /// what its steps mean.
        let source: SimulatorScenarioCatalog
        let deviceIDs: [SimulatorDeviceID]
        var step: Int
        var isPlaying: Bool
        var isOpening: Bool
        var failure: String?

        var isAtFirstStep: Bool { step == 0 }
        var isAtLastStep: Bool { step >= scenario.steps.count - 1 }
    }

    /// The result an agent receives: which devices took the change, and what failed where.
    struct Outcome: Equatable, Sendable {
        let scenario: SimulatorScenario
        let step: Int?
        let devices: [SimulatorDeviceID]
        let failures: [String]
    }

    private(set) var catalog: SimulatorScenarioCatalog?
    private(set) var session: Session?
    var onChange: (() -> Void)?
    /// The members a scenario can reach, in workspace order. Set by the workspace.
    var targets: () -> [any SimulatorScenarioTarget] = { [] }

    private let checkout: @MainActor () -> URL?
    private let loader: @Sendable (URL) async -> SimulatorScenarioCatalog
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var tail: Task<[String], Never>?
    private var playTask: Task<Void, Never>?
    private var loadGeneration = 0

    init(
        checkout: @escaping @MainActor () -> URL?,
        loader: @escaping @Sendable (URL) async -> SimulatorScenarioCatalog = SimulatorScenarioController.loadDetached,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.checkout = checkout
        self.loader = loader
        self.sleep = sleep
    }

    nonisolated static func loadDetached(_ workingDirectory: URL) async -> SimulatorScenarioCatalog {
        await Task.detached(priority: .userInitiated) {
            SimulatorScenarioLoader.load(
                repositoryRoot: SimulatorScenarioLoader.repositoryRoot(forWorkingDirectory: workingDirectory)
            )
        }.value
    }

    // MARK: - Catalogue

    /// The platforms of the members that hold a device.
    var memberPlatforms: Set<SimulatorScenarioPlatform> {
        Set(targets().compactMap { $0.scenarioDeviceID.map { SimulatorScenarioPlatform($0.platform) } })
    }

    /// What the menu lists: the scenarios some member can open.
    var offeredScenarios: [SimulatorScenario] {
        catalog?.scenarios(for: memberPlatforms) ?? []
    }

    /// Whether the workspace shows its Scenarios button: something to open, or a file whose
    /// problems its author needs to see.
    var isAvailable: Bool {
        !offeredScenarios.isEmpty || catalog?.diagnostics.isEmpty == false
    }

    /// Reads the checkout's file again. Off the main actor; a later call wins over an earlier one
    /// still reading.
    @discardableResult
    func reload() async -> SimulatorScenarioCatalog? {
        loadGeneration += 1
        let generation = loadGeneration
        guard let directory = checkout() else {
            if catalog != nil { catalog = nil; onChange?() }
            return nil
        }
        let loaded = await loader(directory)
        guard generation == loadGeneration else { return catalog }
        if loaded != catalog {
            catalog = loaded
            onChange?()
        }
        return loaded
    }

    // MARK: - Driving devices

    /// Starts the app in the scenario on every member that can show it, or only on `deviceID`,
    /// then goes to `step` when one is named.
    @discardableResult
    func open(_ scenarioID: String, step: Int? = nil, on deviceID: SimulatorDeviceID? = nil) async throws -> Outcome {
        if catalog == nil { await reload() }
        guard checkout() != nil else { throw SimulatorScenarioError.noCheckout }
        guard let catalog, catalog.fileExists else { throw SimulatorScenarioError.noFile }
        guard let scenario = catalog.scenario(id: scenarioID) else {
            throw SimulatorScenarioError.unknownScenario(scenarioID)
        }
        if let step, !scenario.steps.indices.contains(step), !(step == 0 && !scenario.hasSteps) {
            throw SimulatorScenarioError.noSuchStep(step, count: scenario.steps.count)
        }
        var members = targets().filter { $0.scenarioDeviceID != nil }
        guard !members.isEmpty else { throw SimulatorScenarioError.noDevice }
        if let deviceID {
            members = members.filter { $0.scenarioDeviceID == deviceID }
            guard !members.isEmpty else { throw SimulatorScenarioError.deviceNotInWorkspace }
        }
        let launches = members.compactMap { member -> (any SimulatorScenarioTarget, SimulatorAppLaunch)? in
            guard let device = member.scenarioDeviceID,
                  let launch = catalog.launch(scenario, on: SimulatorScenarioPlatform(device.platform)) else { return nil }
            return (member, launch)
        }
        guard !launches.isEmpty else { throw SimulatorScenarioError.unsupported(scenario.displayTitle) }

        stopPlaying(notify: false)
        let id = UUID()
        session = Session(
            id: id, scenario: scenario, source: catalog, deviceIDs: launches.compactMap { $0.0.scenarioDeviceID },
            step: 0, isPlaying: false, isOpening: true, failure: nil
        )
        onChange?()
        let appearance = scenario.appearance
        let failures = await enqueue {
            await Self.perform(launches) { member, launch in
                try await member.launchScenarioApp(launch, appearance: appearance)
            }
        }
        guard session?.id == id else {
            return Outcome(scenario: scenario, step: nil, devices: [], failures: failures)
        }
        session?.isOpening = false
        session?.failure = failures.first
        onChange?()
        let devices = launches.compactMap { $0.0.scenarioDeviceID }
        if let step, step > 0, failures.isEmpty {
            return try await advance(to: step, keepPlaying: false)
        }
        return Outcome(scenario: scenario, step: scenario.hasSteps ? 0 : nil, devices: devices, failures: failures)
    }

    /// Takes every device the scenario was opened on to that step: by its link while the app
    /// runs, or by starting the app again for a first step that has none.
    @discardableResult
    func go(to step: Int) async throws -> Outcome {
        stopPlaying(notify: false)
        return try await advance(to: step, keepPlaying: false)
    }

    func next() {
        guard let session, !session.isAtLastStep else { return }
        Task { _ = try? await go(to: session.step + 1) }
    }

    func previous() {
        guard let session, !session.isAtFirstStep else { return }
        Task { _ = try? await go(to: session.step - 1) }
    }

    /// Plays the remaining steps at the scenario's pace. At the last step it starts over.
    func togglePlay() {
        guard let current = session, current.scenario.hasSteps else { return }
        if current.isPlaying {
            stopPlaying(notify: true)
            return
        }
        session?.isPlaying = true
        onChange?()
        let id = current.id
        playTask = Task { [weak self] in
            if current.isAtLastStep { _ = try? await self?.advance(to: 0, keepPlaying: true) }
            while let self, let playing = self.session, playing.id == id, playing.isPlaying, !playing.isAtLastStep {
                do { try await self.sleep(playing.scenario.stepInterval) } catch { return }
                guard !Task.isCancelled, self.session?.id == id, self.session?.isPlaying == true else { return }
                _ = try? await self.advance(to: playing.step + 1, keepPlaying: true)
            }
            guard let self, self.session?.id == id, self.session?.isPlaying == true else { return }
            self.session?.isPlaying = false
            self.onChange?()
        }
    }

    /// Forgets the scenario. The app stays as it is.
    func close() {
        stopPlaying(notify: false)
        guard session != nil else { return }
        session = nil
        onChange?()
    }

    // MARK: - Private

    private func advance(to step: Int, keepPlaying: Bool) async throws -> Outcome {
        guard let current = session else { throw SimulatorScenarioError.noScenarioOpen }
        let scenario = current.scenario
        guard scenario.steps.indices.contains(step) else {
            throw SimulatorScenarioError.noSuchStep(step, count: scenario.steps.count)
        }
        session?.step = step
        session?.failure = nil
        if !keepPlaying { session?.isPlaying = false }
        onChange?()

        let source = current.source
        let members = targets().filter { member in
            member.scenarioDeviceID.map(current.deviceIDs.contains) == true
        }
        let actions = members.compactMap { member -> (any SimulatorScenarioTarget, StepAction)? in
            guard let platform = member.scenarioDeviceID.map({ SimulatorScenarioPlatform($0.platform) }) else { return nil }
            if let link = source.link(scenario, step: step, on: platform) { return (member, .link(link)) }
            if let launch = source.launch(scenario, on: platform) { return (member, .launch(launch)) }
            return nil
        }
        let appearance = scenario.appearance
        let failures = await enqueue {
            await Self.perform(actions) { member, action in
                switch action {
                case .link(let link): try await member.openScenarioLink(link)
                case .launch(let launch): try await member.launchScenarioApp(launch, appearance: appearance)
                }
            }
        }
        if session?.id == current.id, session?.step == step, let failure = failures.first {
            session?.failure = failure
            session?.isPlaying = false
            onChange?()
        }
        return Outcome(scenario: scenario, step: step, devices: actions.compactMap { $0.0.scenarioDeviceID },
                       failures: failures)
    }

    private enum StepAction: Sendable {
        case link(SimulatorAppLink)
        case launch(SimulatorAppLaunch)
    }

    private func stopPlaying(notify: Bool) {
        playTask?.cancel()
        playTask = nil
        guard session?.isPlaying == true else { return }
        session?.isPlaying = false
        if notify { onChange?() }
    }

    /// Runs after everything already queued, so devices see steps in the order they were asked.
    private func enqueue(_ work: @escaping @MainActor () async -> [String]) async -> [String] {
        let previous = tail
        let task = Task { @MainActor in
            _ = await previous?.value
            return await work()
        }
        tail = task
        return await task.value
    }

    /// Every member at once; the failures name their device.
    private static func perform<Action: Sendable>(
        _ work: [(any SimulatorScenarioTarget, Action)],
        _ body: @escaping @MainActor @Sendable (any SimulatorScenarioTarget, Action) async throws -> Void
    ) async -> [String] {
        await withTaskGroup(of: String?.self) { group in
            for (member, action) in work {
                group.addTask { @MainActor in
                    do {
                        try await body(member, action)
                        return nil
                    } catch {
                        return L10n.format("%1$@: %2$@", member.scenarioDeviceName, error.localizedDescription)
                    }
                }
            }
            var failures: [String] = []
            for await failure in group { if let failure { failures.append(failure) } }
            return failures
        }
    }
}
