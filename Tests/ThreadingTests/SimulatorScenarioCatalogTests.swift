import Foundation
import XCTest
@testable import Threading

final class SimulatorScenarioCatalogTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/repo", isDirectory: true)

    private func decode(_ json: String) -> SimulatorScenarioCatalog {
        SimulatorScenarioLoader.decode(Data(json.utf8), repositoryRoot: root)
    }

    /// A minimal valid file with the given scenarios.
    private func file(_ scenarios: String, apps: String = SimulatorScenarioCatalogTests.bothApps) -> String {
        #"{ "version": 1, "apps": \#(apps), "scenarios": [\#(scenarios)] }"#
    }

    private static let bothApps = #"""
        { "ios": { "bundleIdentifier": "com.example.app", "urlScheme": "example" },
          "android": { "package": "com.example.app", "activity": ".Scenes", "urlScheme": "example" } }
        """#

    // MARK: - The guide's example

    func testTheGuidesExampleDecodesWithoutProblems() throws {
        let catalog = decode(SimulatorScenarioGuide.example)
        XCTAssertEqual(catalog.diagnostics, [])
        XCTAssertEqual(catalog.scenarios.map(\.id), ["home/empty", "home/full-dark", "order/delivery"])
        let order = try XCTUnwrap(catalog.scenario(id: "order/delivery"))
        XCTAssertEqual(order.steps.count, 4)
        XCTAssertEqual(order.stepInterval, 1.5)
        XCTAssertEqual(order.androidExtras, [
            SimulatorLaunchExtra(key: "scene", value: .string("order")),
            SimulatorLaunchExtra(key: "step", value: .integer(0)),
        ], "a JSON number is an integer extra, not text")
        XCTAssertEqual(catalog.scenario(id: "home/full-dark")?.appearance, .dark)
    }

    func testTheReceiversNameWhatThreadingSends() {
        XCTAssertTrue(SimulatorScenarioGuide.iOSReceiver.contains(#""\#(SimulatorAppLinkDrop.notificationName)""#))
        XCTAssertTrue(SimulatorScenarioGuide.iOSReceiver.contains(#""\#(SimulatorAppLinkDrop.fileName)""#))
        XCTAssertTrue(SimulatorScenarioGuide.androidReceiver.contains(AndroidControlDefaults.singleTopFlag))
        let prompt = SimulatorScenarioGuide.agentPrompt(path: "/repo/.threading/scenarios.json")
        XCTAssertTrue(prompt.contains("/repo/.threading/scenarios.json"))
        XCTAssertTrue(prompt.contains(SimulatorScenarioGuide.example))
        XCTAssertTrue(prompt.contains(SimulatorScenarioGuide.iOSReceiver))
        XCTAssertTrue(prompt.contains("simulator_scenario"))
    }

    // MARK: - Launches and links

    func testEachPlatformGetsItsOwnLaunchAndALinkUnderItsScheme() throws {
        let catalog = decode(SimulatorScenarioGuide.example)
        let order = try XCTUnwrap(catalog.scenario(id: "order/delivery"))
        XCTAssertEqual(catalog.launch(order, on: .iOS),
                       .iOS(bundleIdentifier: "com.example.shop", arguments: ["-scene", "order", "-step", "0"]))
        XCTAssertEqual(catalog.launch(order, on: .android), .android(
            package: "com.example.shop", activity: ".DebugScenesActivity",
            extras: [SimulatorLaunchExtra(key: "scene", value: .string("order")),
                     SimulatorLaunchExtra(key: "step", value: .integer(0))]
        ))
        XCTAssertEqual(catalog.link(order, step: 2, on: .iOS),
                       .iOS(bundleIdentifier: "com.example.shop", url: URL(string: "exampleshop://debug/step?n=2")!))
        XCTAssertEqual(catalog.link(order, step: 2, on: .android)?.url, URL(string: "exampleshop://debug/step?n=2"))
        XCTAssertNil(catalog.link(order, step: 4, on: .iOS), "past the last step")
    }

    func testAScenarioIsOfferedOnlyOnThePlatformsItLaunches() {
        let catalog = decode(file(#"""
            { "id": "a", "group": "G", "title": "Both", "launch": { "ios": [], "android": {} } },
            { "id": "b", "group": "G", "title": "iOS only", "launch": { "ios": ["-x"] } }
            """#))
        XCTAssertEqual(catalog.diagnostics, [])
        XCTAssertEqual(catalog.scenarios(for: [.android]).map(\.id), ["a"])
        XCTAssertEqual(catalog.scenarios(for: [.iOS]).map(\.id), ["a", "b"])
        XCTAssertNil(catalog.launch(catalog.scenarios[1], on: .android))
    }

    func testExtrasKeepTheirJSONType() throws {
        let catalog = decode(file(#"""
            { "id": "a", "group": "G", "title": "T",
              "launch": { "android": { "flag": true, "count": 3, "big": 5000000000, "name": "x" } } }
            """#))
        XCTAssertEqual(catalog.diagnostics, [])
        XCTAssertEqual(try XCTUnwrap(catalog.scenarios.first?.androidExtras), [
            SimulatorLaunchExtra(key: "big", value: .integer(5_000_000_000)),
            SimulatorLaunchExtra(key: "count", value: .integer(3)),
            SimulatorLaunchExtra(key: "flag", value: .boolean(true)),
            SimulatorLaunchExtra(key: "name", value: .string("x")),
        ])
    }

    // MARK: - Refusals

    func testTheFileItselfMustBeVersionOneWithKnownFields() {
        XCTAssertEqual(decode(#"{ "version": 2, "apps": {"ios": {"bundleIdentifier": "a.b"}}, "scenarios": [] }"#)
            .diagnostics.map(\.code), [.unsupportedVersion])
        XCTAssertEqual(decode(#"{ "version": 1, "scenarios": [], "apps": {"ios": {"bundleIdentifier": "a.b"}}, "extra": 1 }"#)
            .diagnostics.map(\.code), [.unknownField])
        XCTAssertEqual(decode("[1]").diagnostics.map(\.code), [.malformedJSON])
        XCTAssertEqual(decode("{").diagnostics.map(\.code), [.malformedJSON])
    }

    func testAppsMustNameAnAppAndAnInAppScheme() {
        for apps in [
            "{}",
            #"{ "ios": { "bundleIdentifier": "com.example.app", "urlScheme": "https" } }"#,
            #"{ "ios": { "bundleIdentifier": "com.example.app", "urlScheme": "Example" } }"#,
            #"{ "android": { "package": "not a package" } }"#,
            #"{ "android": { "package": "com.example.app", "activity": "com.example/Main" } }"#,
            #"{ "watchos": { "bundleIdentifier": "com.example.app" } }"#,
        ] {
            XCTAssertEqual(decode(file("", apps: apps)).diagnostics.map(\.code), [.invalidApps], apps)
        }
    }

    func testABrokenScenarioIsReportedAndTheOthersAreStillOffered() {
        let catalog = decode(file(#"""
            { "id": "good", "group": "G", "title": "Good", "launch": { "ios": [] } },
            { "id": "Bad ID", "group": "G", "title": "Bad", "launch": { "ios": [] } },
            { "id": "no-launch", "group": "G", "title": "No launch" },
            { "id": "web-link", "group": "G", "title": "Web", "launch": { "ios": [] },
              "steps": [{ "title": "One" }, { "title": "Two", "link": "https://example.com" }] },
            { "id": "linkless", "group": "G", "title": "Linkless", "launch": { "ios": [] },
              "steps": [{ "title": "One", "link": "a" }, { "title": "Two" }] },
            { "id": "one-step", "group": "G", "title": "One step", "launch": { "ios": [] }, "steps": [{ "title": "One" }] },
            { "id": "slow", "group": "G", "title": "Slow", "launch": { "ios": [] }, "stepInterval": 60,
              "steps": [{ "title": "One" }, { "title": "Two", "link": "b" }] },
            { "id": "good", "group": "G", "title": "Again", "launch": { "ios": [] } }
            """#))
        XCTAssertEqual(catalog.scenarios.map(\.id), ["good"])
        XCTAssertEqual(catalog.diagnostics.map(\.code), [
            .invalidScenario, .invalidScenario, .invalidScenario, .invalidScenario, .invalidScenario,
            .invalidScenario, .duplicateID,
        ])
        XCTAssertTrue(catalog.diagnostics[0].message.contains("Scenario 2"), catalog.diagnostics[0].message)
    }

    func testStepLinksNeedASchemeOnEveryPlatformTheScenarioLaunches() {
        let apps = #"{ "ios": { "bundleIdentifier": "com.example.app", "urlScheme": "example" }, "android": { "package": "com.example.app" } }"#
        let catalog = decode(file(#"""
            { "id": "flow", "group": "G", "title": "Flow", "launch": { "ios": [], "android": {} },
              "steps": [{ "title": "One", "link": "s?n=0" }, { "title": "Two", "link": "s?n=1" }] },
            { "id": "ios-flow", "group": "G", "title": "iOS flow", "launch": { "ios": [] },
              "steps": [{ "title": "One", "link": "s?n=0" }, { "title": "Two", "link": "s?n=1" }] }
            """#, apps: apps))
        XCTAssertEqual(catalog.scenarios.map(\.id), ["ios-flow"])
        XCTAssertTrue(catalog.diagnostics.first?.message.contains("apps.android") == true)
    }

    func testTooManyScenariosIsRefusedBeforeAnyIsDecoded() {
        let one = #"{ "id": "s", "group": "G", "title": "T", "launch": { "ios": [] } }"#
        let many = Array(repeating: one, count: SimulatorScenarioDefaults.maximumScenarios + 1).joined(separator: ",")
        XCTAssertEqual(decode(file(many)).diagnostics.map(\.code), [.tooManyScenarios])
    }

    func testDiagnosticsStopAtTheirCap() {
        let bad = #"{ "id": "s", "group": "G", "title": "T" }"#
        let catalog = decode(file(Array(repeating: bad, count: 40).joined(separator: ",")))
        XCTAssertEqual(catalog.diagnostics.count, SimulatorScenarioDefaults.maximumDiagnostics)
    }

    // MARK: - Loading from a checkout

    func testAMissingFileIsAnEmptyCatalogue() throws {
        let checkout = try makeCheckout()
        defer { try? FileManager.default.removeItem(at: checkout) }
        let catalog = SimulatorScenarioLoader.load(repositoryRoot: checkout)
        XCTAssertFalse(catalog.fileExists)
        XCTAssertEqual(catalog.diagnostics, [])
        XCTAssertEqual(catalog.fileURL.lastPathComponent, "scenarios.json")
    }

    func testLoadsTheFileUnderTheThreadingFolder() throws {
        let checkout = try makeCheckout()
        defer { try? FileManager.default.removeItem(at: checkout) }
        try write(SimulatorScenarioGuide.example, to: checkout.appendingPathComponent(".threading/scenarios.json"))
        let catalog = SimulatorScenarioLoader.load(repositoryRoot: checkout)
        XCTAssertTrue(catalog.fileExists)
        XCTAssertEqual(catalog.scenarios.count, 3)
    }

    func testRefusesAFileThatLeadsOutOfTheCheckout() throws {
        let checkout = try makeCheckout()
        let outside = try makeCheckout()
        defer {
            try? FileManager.default.removeItem(at: checkout)
            try? FileManager.default.removeItem(at: outside)
        }
        try write(SimulatorScenarioGuide.example, to: outside.appendingPathComponent("scenarios.json"))
        try FileManager.default.createSymbolicLink(
            at: checkout.appendingPathComponent(".threading"), withDestinationURL: outside
        )
        let catalog = SimulatorScenarioLoader.load(repositoryRoot: checkout)
        XCTAssertEqual(catalog.diagnostics.map(\.code), [.unreadable])
        XCTAssertEqual(catalog.scenarios, [])
    }

    func testRefusesAnOversizedFile() throws {
        let checkout = try makeCheckout()
        defer { try? FileManager.default.removeItem(at: checkout) }
        try write(String(repeating: " ", count: SimulatorScenarioDefaults.maximumFileBytes + 1),
                  to: checkout.appendingPathComponent(".threading/scenarios.json"))
        XCTAssertEqual(SimulatorScenarioLoader.load(repositoryRoot: checkout).diagnostics.map(\.code), [.tooLarge])
    }

    private func makeCheckout() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scenario-checkout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}
