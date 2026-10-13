import Foundation
import XCTest
@testable import Threading

@MainActor
final class SimulatorScenarioControllerTests: XCTestCase {
    private static let iPhone = SimulatorDeviceID("AAAAAAAA-1111-2222-3333-444444444444")!
    private static let pixel = SimulatorDeviceID.androidEmulator(avdName: "Pixel_8")!

    private static let file = #"""
        { "version": 1,
          "apps": { "ios": { "bundleIdentifier": "com.example.app", "urlScheme": "example" },
                    "android": { "package": "com.example.app", "activity": ".Scenes", "urlScheme": "example" } },
          "scenarios": [
            { "id": "home", "group": "Home", "title": "Home", "launch": { "ios": ["-scene", "home"], "android": { "scene": "home" } } },
            { "id": "ios-only", "group": "Home", "title": "iOS only", "appearance": "dark", "launch": { "ios": ["-x"] } },
            { "id": "flow", "group": "Flows", "title": "Flow", "launch": { "ios": ["-scene", "flow"], "android": { "scene": "flow" } },
              "stepInterval": 0.5,
              "steps": [{ "title": "First", "link": "s?n=0" }, { "title": "Second", "link": "s?n=1" }, { "title": "Third", "link": "s?n=2" }] },
            { "id": "relaunch", "group": "Flows", "title": "Relaunch", "launch": { "ios": ["-scene", "r"] },
              "steps": [{ "title": "First" }, { "title": "Second", "link": "r?n=1" }] }
          ] }
        """#

    private func controller(
        _ targets: [FakeScenarioTarget], checkout: URL? = URL(fileURLWithPath: "/repo"),
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { _ in }
    ) -> SimulatorScenarioController {
        let catalog = SimulatorScenarioLoader.decode(Data(Self.file.utf8), repositoryRoot: URL(fileURLWithPath: "/repo"))
        let controller = SimulatorScenarioController(checkout: { checkout }, loader: { _ in catalog }, sleep: sleep)
        controller.targets = { targets }
        return controller
    }

    func testOpeningStartsEveryMemberThatCanShowTheScenarioWithItsOwnLaunch() async throws {
        let phone = FakeScenarioTarget(Self.iPhone)
        let android = FakeScenarioTarget(Self.pixel)
        let scenarios = controller([phone, android])

        let outcome = try await scenarios.open("home")

        XCTAssertEqual(phone.calls, [.launch(.iOS(bundleIdentifier: "com.example.app", arguments: ["-scene", "home"]), nil)])
        XCTAssertEqual(android.calls, [.launch(.android(
            package: "com.example.app", activity: ".Scenes", extras: [SimulatorLaunchExtra(key: "scene", value: .string("home"))]
        ), nil)])
        XCTAssertEqual(Set(outcome.devices), [Self.iPhone, Self.pixel])
        XCTAssertEqual(scenarios.session?.isOpening, false)

        _ = try await scenarios.open("ios-only")
        XCTAssertEqual(phone.calls.last, .launch(.iOS(bundleIdentifier: "com.example.app", arguments: ["-x"]), .dark))
        XCTAssertEqual(android.calls.count, 1, "a scenario without an Android launch leaves the Android device alone")
        XCTAssertEqual(scenarios.offeredScenarios.count, 4)
    }

    func testAStepReachesTheRunningAppByItsLinkAndTheFirstStepWithoutOneRelaunches() async throws {
        let phone = FakeScenarioTarget(Self.iPhone)
        let scenarios = controller([phone])

        _ = try await scenarios.open("flow")
        _ = try await scenarios.go(to: 2)
        XCTAssertEqual(phone.calls.last, .link(.iOS(bundleIdentifier: "com.example.app", url: URL(string: "example://s?n=2")!)))
        XCTAssertEqual(scenarios.session?.step, 2)

        _ = try await scenarios.open("relaunch", step: 1)
        XCTAssertEqual(phone.calls.suffix(2), [
            .launch(.iOS(bundleIdentifier: "com.example.app", arguments: ["-scene", "r"]), nil),
            .link(.iOS(bundleIdentifier: "com.example.app", url: URL(string: "example://r?n=1")!)),
        ])
        _ = try await scenarios.go(to: 0)
        XCTAssertEqual(phone.calls.last, .launch(.iOS(bundleIdentifier: "com.example.app", arguments: ["-scene", "r"]), nil),
                       "back to a first step that has no link starts the app again")
    }

    func testQuickStepsReachTheDeviceInTheOrderTheyWereAsked() async throws {
        let phone = FakeScenarioTarget(Self.iPhone)
        let scenarios = controller([phone])
        _ = try await scenarios.open("flow")
        // The first link is held on its way; the second, asked for meanwhile, must wait behind it.
        phone.holdsNextLink = true
        let first = Task { try await scenarios.go(to: 1) }
        try await waitUntil { phone.isHoldingLink }
        let second = Task { try await scenarios.go(to: 2) }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(phone.calls.count, 1, "nothing overtakes the held step")
        phone.releaseHeldLink()
        _ = try await (first.value, second.value)
        XCTAssertEqual(phone.calls.dropFirst().map(\.url?.absoluteString), ["example://s?n=1", "example://s?n=2"])
        XCTAssertEqual(scenarios.session?.step, 2)
    }

    func testPlayWalksToTheLastStepAndStopsThenStartsOverFromTheEnd() async throws {
        let phone = FakeScenarioTarget(Self.iPhone)
        let scenarios = controller([phone])
        _ = try await scenarios.open("flow")

        scenarios.togglePlay()
        XCTAssertEqual(scenarios.session?.isPlaying, true)
        try await waitUntil { scenarios.session?.isPlaying == false }
        XCTAssertEqual(scenarios.session?.step, 2)
        XCTAssertEqual(phone.calls.dropFirst().map(\.url?.absoluteString), ["example://s?n=1", "example://s?n=2"])

        scenarios.togglePlay()
        try await waitUntil { scenarios.session?.isPlaying == false }
        XCTAssertEqual(phone.calls.dropFirst(3).map(\.url?.absoluteString),
                       ["example://s?n=0", "example://s?n=1", "example://s?n=2"])
    }

    func testAManualStepStopsPlay() async throws {
        let phone = FakeScenarioTarget(Self.iPhone)
        // A pace that never elapses on its own: only the manual step moves the scenario.
        let scenarios = controller([phone], sleep: { _ in try await Task.sleep(for: .seconds(60)) })
        _ = try await scenarios.open("flow")
        scenarios.togglePlay()
        _ = try await scenarios.go(to: 1)
        XCTAssertEqual(scenarios.session?.isPlaying, false)
    }

    func testAFailingDeviceIsNamedAndStopsPlayWhileTheOthersStillMove() async throws {
        let phone = FakeScenarioTarget(Self.iPhone)
        let android = FakeScenarioTarget(Self.pixel)
        android.linkFailure = SimulatorControlError.applicationNotInstalled("com.example.app")
        let scenarios = controller([phone, android])
        _ = try await scenarios.open("flow")

        let outcome = try await scenarios.go(to: 1)

        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertTrue(outcome.failures[0].hasPrefix("Fake \(Self.pixel.rawValue): "), outcome.failures[0])
        XCTAssertEqual(scenarios.session?.failure, outcome.failures[0])
        XCTAssertEqual(phone.calls.last?.url?.absoluteString, "example://s?n=1")
    }

    func testOpeningOnOneDeviceStepsOnlyThatDevice() async throws {
        let phone = FakeScenarioTarget(Self.iPhone)
        let android = FakeScenarioTarget(Self.pixel)
        let scenarios = controller([phone, android])
        _ = try await scenarios.open("flow", on: Self.pixel)
        _ = try await scenarios.go(to: 1)
        XCTAssertEqual(phone.calls, [])
        XCTAssertEqual(android.calls.count, 2)
    }

    func testRefusalsSayWhatIsWrong() async {
        let scenarios = controller([FakeScenarioTarget(Self.iPhone)])
        await assertThrows(SimulatorScenarioError.unknownScenario("nope")) { _ = try await scenarios.open("nope") }
        await assertThrows(SimulatorScenarioError.noSuchStep(5, count: 3)) { _ = try await scenarios.open("flow", step: 5) }
        await assertThrows(SimulatorScenarioError.noScenarioOpen) { _ = try await scenarios.go(to: 1) }
        await assertThrows(SimulatorScenarioError.deviceNotInWorkspace) {
            _ = try await scenarios.open("home", on: Self.pixel)
        }
        let androidOnly = controller([FakeScenarioTarget(Self.pixel)])
        await assertThrows(SimulatorScenarioError.unsupported("iOS only")) { _ = try await androidOnly.open("ios-only") }
        let noCheckout = controller([FakeScenarioTarget(Self.iPhone)], checkout: nil)
        await assertThrows(SimulatorScenarioError.noCheckout) { _ = try await noCheckout.open("home") }
    }

    func testClosingForgetsTheScenarioAndLeavesTheAppAlone() async throws {
        let phone = FakeScenarioTarget(Self.iPhone)
        let scenarios = controller([phone])
        _ = try await scenarios.open("flow")
        scenarios.close()
        XCTAssertNil(scenarios.session)
        XCTAssertEqual(phone.calls.count, 1)
    }

    // MARK: - Helpers

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition())
    }

    private func assertThrows(
        _ expected: SimulatorScenarioError, file: StaticString = #filePath, line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as SimulatorScenarioError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("\(error)", file: file, line: line)
        }
    }
}

@MainActor
final class FakeScenarioTarget: SimulatorScenarioTarget {
    enum Call: Equatable {
        case launch(SimulatorAppLaunch, SimulatorScenarioAppearance?)
        case link(SimulatorAppLink)

        var url: URL? {
            guard case .link(let link) = self else { return nil }
            return link.url
        }
    }

    let scenarioDeviceID: SimulatorDeviceID?
    var scenarioDeviceName: String { "Fake \(scenarioDeviceID?.rawValue ?? "")" }
    private(set) var calls: [Call] = []
    var linkFailure: Error?
    /// Holds the next link until `releaseHeldLink`, so a test can ask for another meanwhile.
    var holdsNextLink = false
    private var heldLink: CheckedContinuation<Void, Never>?
    var isHoldingLink: Bool { heldLink != nil }

    func releaseHeldLink() {
        heldLink?.resume()
        heldLink = nil
    }

    init(_ deviceID: SimulatorDeviceID?) { scenarioDeviceID = deviceID }

    func launchScenarioApp(_ launch: SimulatorAppLaunch, appearance: SimulatorScenarioAppearance?) async throws {
        calls.append(.launch(launch, appearance))
    }

    func openScenarioLink(_ link: SimulatorAppLink) async throws {
        if holdsNextLink {
            holdsNextLink = false
            await withCheckedContinuation { heldLink = $0 }
        }
        if let linkFailure { throw linkFailure }
        calls.append(.link(link))
    }
}
