import AppKit
import XCTest
@testable import Threading

/// The Remote Hosts page: the list, what each machine's state says, and the sentences a person acts
/// on when one refuses.
@MainActor
final class RemoteHostsSettingsTests: HostedStoreTestCase {

    private enum Render {
        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"], !override.isEmpty {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }
        static let size = NSSize(width: 760, height: 420)
    }

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: "/tmp/threading-hostpage-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    // MARK: - The page

    func testTheHostsPageIsRegisteredInTheAccessRun() throws {
        let page = try XCTUnwrap(SettingsPages.builtIn.first { $0.id == SettingsPages.remoteHostsID })
        XCTAssertEqual(page.title, L10n.string("Remote Hosts"))
        XCTAssertNil(page.hostPage, "a host is a machine and credentials; an extension adds no field to it")
        XCTAssertTrue(page.entries.isEmpty, "the page is records, not preferences")

        // Pages sharing a group must be contiguous: the sidebar draws one caption per run.
        let groups = SettingsPages.builtIn.map(\.group)
        let runs = groups.reduce(into: [String]()) { result, group in
            if result.last != group { result.append(group) }
        }
        XCTAssertEqual(Set(runs).count, runs.count, "a settings group was split into two runs")
        XCTAssertTrue(SettingsPages.sidebarItems.contains { $0.id == SettingsPages.remoteHostsID })
    }

    func testThePageListsHostsAndSaysWhenThereAreNone() throws {
        let store = RemoteHostStore(directory: directory)
        let controller = RemoteHostsPreferencesViewController(store: store)
        controller.loadView()
        controller.viewDidLoad()
        controller.viewWillAppear()
        XCTAssertEqual(controller.hostCountForTesting, 0)
        XCTAssertEqual(controller.rowCountForTesting, 2, "a note and the empty line")

        XCTAssertEqual(store.add(RemoteHostRecord.typed(label: "Pi", destination: "pi", sshConfigFile: "")), .applied)
        XCTAssertEqual(store.add(RemoteHostRecord.typed(label: "Box", destination: "box", sshConfigFile: "")), .applied)
        controller.viewWillAppear()
        XCTAssertEqual(controller.hostCountForTesting, 2)
        XCTAssertEqual(controller.rowCountForTesting, 3, "the note and one row per machine")

        controller.view.frame = NSRect(origin: .zero, size: Render.size)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(ThemeBoundaryAudit.violations(in: controller.view), [])
    }

    // MARK: - What a state says

    /// Each state says what it is and, when it refuses, what to do about it.
    func testEachStateSaysWhatItIsAndWhatToDoAboutIt() {
        let record = RemoteHostRecord.typed(label: "Pi", destination: "pi", sshConfigFile: "")

        let idle = RemoteHostPresentation.state(of: record, phase: .idle, step: nil)
        XCTAssertEqual(idle.label, RemoteHostsSettingsStrings.notChecked)
        XCTAssertTrue(idle.allowsChecking)
        XCTAssertNil(idle.detail)

        let downloading = RemoteHostPresentation.state(
            of: record,
            phase: .preparing,
            step: .fetchingComponents(0.42)
        )
        XCTAssertEqual(downloading.label, L10n.format("Downloading %lld%%", 42))
        XCTAssertFalse(downloading.allowsChecking, "checking again mid-download does nothing")

        let ready = RemoteHostPresentation.state(of: record, phase: .ready(context()), step: nil)
        XCTAssertEqual(ready.label, RemoteHostsSettingsStrings.ready)
        XCTAssertEqual(ready.color, Design.Status.positive)

        let broken = RemoteHostRecord.typed(label: "", destination: "-oProxyCommand=x", sshConfigFile: "")
        let unusable = RemoteHostPresentation.state(of: broken, phase: .idle, step: nil)
        XCTAssertEqual(unusable.label, RemoteHostsSettingsStrings.unusable)
        XCTAssertEqual(unusable.detail, ProjectExecutionHost.Problem.unsafeDestination.message)
        XCTAssertFalse(unusable.allowsChecking)
    }

    /// The failure that would otherwise send a person looking at their network: `ssh` runs in
    /// `BatchMode`, so a machine they have never connected to simply refuses.
    func testAnUnknownHostKeyIsExplainedRatherThanCalledUnreachable() {
        let failure = RemoteHostFailure(
            token: "unreachable",
            detail: "Host key verification failed.\r\nlost connection"
        )
        XCTAssertEqual(RemoteHostPresentation.guidance(for: failure), RemoteHostsSettingsStrings.unknownHostKey)
        XCTAssertTrue(RemoteHostsSettingsStrings.unknownHostKey.contains("known_hosts"))

        XCTAssertEqual(
            RemoteHostPresentation.guidance(for: RemoteHostFailure(token: "unreachable", detail: "Permission denied (publickey).")),
            RemoteHostsSettingsStrings.permissionDenied
        )
        XCTAssertEqual(
            RemoteHostPresentation.guidance(for: RemoteHostFailure(token: "noSystemd", detail: "systemctl was not found")),
            RemoteHostsSettingsStrings.noSystemd
        )
        // Anything else is reported in the host's own words rather than replaced by ours.
        XCTAssertEqual(
            RemoteHostPresentation.guidance(for: RemoteHostFailure(token: "unitStartFailed", detail: "Job failed. See journalctl.")),
            "Job failed. See journalctl."
        )
    }

    // MARK: - Choosing one on a project

    /// A project picks a machine from the list and names only its own folder — and a project set up
    /// before the list existed finds its machine adopted into it, already chosen.
    func testAProjectPicksAMachineAndNamesOnlyItsFolder() throws {
        let store = RemoteHostStore(directory: directory)
        let pi = RemoteHostRecord.typed(label: "Pi", destination: "pi", sshConfigFile: "")
        XCTAssertEqual(store.add(pi), .applied)

        let accessory = RemoteHostPromptAccessory(current: nil, store: store)
        XCTAssertEqual(accessory.records.map(\.displayName), ["Pi"])
        XCTAssertEqual(accessory.hostPopUp.numberOfItems, 2, "the machines, then Add Host…")
        XCTAssertEqual(accessory.hostPopUp.item(at: 1)?.title, L10n.string("Add Host…"))
        accessory.remoteDirectoryField.stringValue = "relative/path"
        XCTAssertFalse(accessory.validate(announcing: false))
        XCTAssertEqual(accessory.helperLabel.stringValue, ProjectExecutionHost.Problem.relativeRemoteDirectory.message)

        accessory.remoteDirectoryField.stringValue = "/home/me/app"
        XCTAssertTrue(accessory.validate(announcing: false))
        XCTAssertEqual(accessory.host, .on(pi, remoteDirectory: "/home/me/app"))
        XCTAssertEqual(accessory.host.hostID, pi.id)

        // The old shape: a destination on the project and no record for it yet.
        let legacy = ProjectExecutionHost(destination: "box", remoteDirectory: "/srv/app")
        let adopting = RemoteHostPromptAccessory(current: legacy, store: store)
        let adopted = try XCTUnwrap(store.host(naming: "box", sshConfigFile: nil), "the machine was not adopted")
        XCTAssertEqual(adopting.selectedRecord?.id, adopted.id)
        XCTAssertEqual(adopting.remoteDirectoryField.stringValue, "/srv/app")
    }

    // MARK: - Images

    func testRendersTheHostsPageToImages() throws {
        let store = RemoteHostStore(directory: directory)
        XCTAssertEqual(store.add(RemoteHostRecord.typed(label: "Pi in the hall", destination: "pi", sshConfigFile: "")), .applied)
        XCTAssertEqual(store.add(RemoteHostRecord.typed(label: "", destination: "me@hetzner.example", sshConfigFile: "")), .applied)

        try FileManager.default.createDirectory(at: Render.directory, withIntermediateDirectories: true)
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            let controller = RemoteHostsPreferencesViewController(store: store)
            controller.loadView()
            controller.viewDidLoad()
            controller.viewWillAppear()
            controller.view.appearance = appearance
            controller.view.frame = NSRect(origin: .zero, size: Render.size)
            AppThemeRefresh.repaint(controller.view)
            controller.view.layoutSubtreeIfNeeded()

            let host = controller.view
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.wantsLayer = true
            // The page draws on the window's ground, and a render resolves colours in the *test
            // process's* appearance unless it is told otherwise — which is how a light render comes
            // out on a dark ground.
            appearance.performAsCurrentDrawingAppearance {
                host.layer?.backgroundColor = Design.Surface.ground.cgColor
                host.cacheDisplay(in: host.bounds, to: rep)
            }
            let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try data.write(to: Render.directory.appendingPathComponent("remote-hosts-settings-\(name).png"))
        }
    }

    // MARK: - Helpers

    private func context() -> RemoteHostLaunchContext {
        RemoteHostLaunchContext(
            destination: RemoteHostDestination(alias: "pi", configFile: nil),
            facts: RemoteHostFacts(
                machine: "aarch64", home: "/home/me", user: "me", loginShell: "/bin/bash",
                hasSystemd: true, lingerEnabled: true, installedBinaries: [], activeInstances: [],
                claudePath: "/usr/bin/claude"
            ),
            localSocketPath: "/tmp/x.sock"
        )
    }
}
