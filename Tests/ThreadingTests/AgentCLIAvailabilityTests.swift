import AppKit
import XCTest
import os
@testable import Threading

/// A fresh Mac without `claude` used to meet its first chat as a launch-failure screen whose
/// primary action could not succeed: the composer defaulted to Claude Code whatever was
/// installed, nothing checked before a row was made, and onboarding's only help was a command to
/// paste elsewhere. These pin the shared installed-CLI answer and every surface that now acts on
/// it — and that an unknown answer changes nothing.
@MainActor
final class AgentCLIAvailabilityTests: XCTestCase {

    // MARK: - The Probe

    /// One PATH, every runtime: found ones by path, a native install sitting in `~/.local/bin`
    /// off the PATH, and npm, which three installers need.
    func testSnapshotResolvesEveryRuntimeAgainstOnePath() {
        let home = URL(fileURLWithPath: "/Users/fixture", isDirectory: true)
        let executables: Set<String> = [
            "/opt/homebrew/bin/codex",
            "/opt/homebrew/bin/npm",
            "/Users/fixture/.local/bin/claude"
        ]
        let snapshot = AgentCLIAvailability.snapshot(
            onPath: "/usr/bin:/opt/homebrew/bin",
            home: home,
            isExecutable: { executables.contains($0) }
        )

        XCTAssertEqual(snapshot.paths, [.codex: "/opt/homebrew/bin/codex"])
        XCTAssertTrue(snapshot.hasNodePackageManager)
        XCTAssertEqual(snapshot.installedOffPath, [.claude])
    }

    /// Before a probe answers, nothing is "missing" — every caller behaves as it did before.
    func testUnknownIsNeverMissing() {
        let availability = AgentCLIAvailability(probe: { _ in nil })

        XCTAssertEqual(availability.state(for: .claude), .unknown)
        XCTAssertFalse(availability.isKnownMissing(.claude))
        XCTAssertEqual(availability.preferredRuntime(given: .claude), .claude)
        XCTAssertTrue(availability.canRunInstaller(for: .codex), "an unknown npm blocked an install")
    }

    /// The user's choice stands whenever it can launch; a proven-missing one gives way only to an
    /// installed runtime, never to another missing one.
    func testPreferredRuntimeYieldsOnlyToAnInstalledOne() {
        let availability = AgentCLIAvailability(probe: { _ in nil })
        availability.setSnapshotForTesting(.init(paths: [.codex: "/bin/codex"]))

        XCTAssertEqual(availability.preferredRuntime(given: .claude), .codex)
        XCTAssertEqual(availability.preferredRuntime(given: .codex), .codex)

        availability.setSnapshotForTesting(.init())
        XCTAssertEqual(availability.preferredRuntime(given: .claude), .claude)
    }

    /// A request during a probe schedules exactly one more, so an install finishing mid-probe is
    /// never answered from before it; a shell that could not answer keeps the last real answer.
    func testRefreshCoalescesAndAShellFailureKeepsTheLastAnswer() {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let answers = OSAllocatedUnfairLock(initialState: [
            AgentCLIAvailability.Snapshot(paths: [.claude: "/bin/claude"]),
            nil
        ] as [AgentCLIAvailability.Snapshot?])
        let availability = AgentCLIAvailability(probe: { _ in
            calls.withLock { $0 += 1 }
            return answers.withLock { $0.isEmpty ? nil : $0.removeFirst() }
        }, shell: { "/bin/zsh" })

        let settled = expectation(description: "both refreshes settled")
        settled.expectedFulfillmentCount = 2
        availability.refresh { settled.fulfill() }
        availability.refresh { settled.fulfill() }
        wait(for: [settled], timeout: 5)

        XCTAssertEqual(calls.withLock { $0 }, 2, "the second request was dropped or duplicated")
        XCTAssertEqual(availability.state(for: .claude), .installed(path: "/bin/claude"))
    }

    // MARK: - The Install Sheet

    /// Nothing runs on open: the exact command is shown and Install is the confirmation.
    func testSheetShowsTheCommandAndWaitsForTheClick() {
        let sheet = AgentCLIInstallViewController(kind: .claude, availability: availability())
        _ = sheet.view

        XCTAssertEqual(sheet.phase, .ready)
        XCTAssertEqual(sheet.commandForTesting, "curl -fsSL https://claude.ai/install.sh | bash")
        XCTAssertEqual(sheet.primaryTitleForTesting, "Install")
        XCTAssertEqual(sheet.secondaryTitleForTesting, "Copy Command")
        XCTAssertEqual(ThemeBoundaryAudit.violations(in: sheet.view), [])
    }

    /// An npm installer on a Mac without npm says what it needs instead of failing with a second
    /// `command not found`.
    func testSheetAsksForNodeWhenAnNpmInstallerCannotRun() {
        let sheet = AgentCLIInstallViewController(
            kind: .codex,
            availability: availability(.init(hasNodePackageManager: false))
        )
        _ = sheet.view

        XCTAssertEqual(sheet.phase, .needsNode)
        XCTAssertEqual(sheet.primaryTitleForTesting, "Check Again")
        XCTAssertEqual(sheet.secondaryTitleForTesting, "Get Node.js")
    }

    /// The three outcomes after a run each lead somewhere different.
    func testSheetTellsTheThreeOutcomesApart() {
        let found = availability(.init(paths: [.claude: "/Users/me/.local/bin/claude"]))
        let sheet = AgentCLIInstallViewController(kind: .claude, availability: found)
        _ = sheet.view
        sheet.applyProbeForTesting(exitCode: 0)
        XCTAssertEqual(sheet.phase, .installed(path: "/Users/me/.local/bin/claude"))
        XCTAssertEqual(sheet.primaryTitleForTesting, "Done")

        let offPath = AgentCLIInstallViewController(
            kind: .claude,
            availability: availability(.init(installedOffPath: [.claude]))
        )
        _ = offPath.view
        offPath.applyProbeForTesting(exitCode: 0)
        XCTAssertEqual(offPath.phase, .installedOffPath)
        XCTAssertTrue(offPath.statusForTesting.contains(AgentCLIInstallLayout.pathExportLine))

        let unreachable = AgentCLIInstallViewController(kind: .claude, availability: availability())
        _ = unreachable.view
        unreachable.applyProbeForTesting(exitCode: 0)
        XCTAssertEqual(unreachable.phase, .finishedButNotFound)

        let failed = AgentCLIInstallViewController(kind: .claude, availability: availability())
        _ = failed.view
        failed.applyProbeForTesting(exitCode: 7)
        XCTAssertEqual(failed.phase, .failed(exitCode: 7))
        XCTAssertEqual(failed.primaryTitleForTesting, "Run Again")
    }

    // MARK: - The One-Shot Run

    /// The install sheet reads its outcome from the installer's own exit, so the one-shot run
    /// must end with the command — no shell resumed after it — and report its code, through the
    /// login shell's `-c`, with the source quoted once.
    func testOneShotRunEndsWithTheCommandAndReportsItsExitCode() {
        final class ExitProbe: TerminalSessionDelegate {
            let ended: XCTestExpectation
            var code: Int32?
            init(_ ended: XCTestExpectation) { self.ended = ended }
            func terminalSession(_ session: TerminalSession, didTerminateWithExitCode exitCode: Int32?) {
                code = exitCode
                ended.fulfill()
            }
        }
        var profile = TerminalProfile.default
        profile.shellPath = "/bin/sh"
        profile.shellArguments = []
        let session = TerminalSession(profile: profile, frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        let probe = ExitProbe(expectation(description: "one-shot run ended"))
        session.delegate = probe
        var output = Data()
        session.onRawOutput = { output.append($0) }

        session.startOneShot(
            source: "echo 'installer | ran' && exit 3",
            in: FileManager.default.temporaryDirectory,
            loginShell: "/bin/sh"
        )
        defer { session.terminate() }

        wait(for: [probe.ended], timeout: 10)
        XCTAssertEqual(probe.code, 3)
        XCTAssertTrue(String(decoding: output, as: UTF8.self).contains("installer | ran"))
    }

    // MARK: - Surfaces

    /// A refused send says what is missing, keeps the brief, and offers the install.
    func testRefusalToastOffersTheInstallAndKeepsTheBrief() {
        var installed = false
        let toast = SessionCoordinator.sessionStartMissingCLIToast(.codex) { installed = true }

        XCTAssertEqual(toast.message, "Codex isn’t installed")
        XCTAssertTrue(toast.detail?.contains("codex") == true)
        XCTAssertTrue(toast.detail?.contains("Your brief is still here.") == true)
        XCTAssertEqual(toast.actionTitle, "Install…")
        toast.action?()
        XCTAssertTrue(installed)
    }

    /// The failure screen leads with the install for a missing CLI, and only for that cause.
    func testFailureScreenLeadsWithTheInstallOnlyForAMissingCLI() {
        let container = TerminalContainerViewController(recovery: true)
        let missing = SessionLaunchFailure(
            origin: .preflight,
            summary: "The Claude Code command was not found on this Mac.",
            knownCause: SessionLaunchDiagnosis.Cause.executableMissing
        )
        let actions = container.launchFailureActions(missing, sessionID: SessionID(), kind: .claude)
        XCTAssertEqual(actions.map(\.title), ["Install Claude Code…", "Try Again", "Copy Details"])
        XCTAssertEqual(actions.first?.emphasis, .primary)

        let other = SessionLaunchFailure(origin: .preflight, summary: "Something else.")
        XCTAssertEqual(
            container.launchFailureActions(other, sessionID: SessionID(), kind: .claude).first?.title,
            "Try Again"
        )
    }

    /// Onboarding offers Install on exactly the missing runtimes, and with none installed says
    /// that one is all a chat needs.
    func testOnboardingOffersInstallOnlyWhereARuntimeIsMissing() {
        let page = OnboardingDiscoveryPageViewController(
            accountsProvider: { [] },
            availability: availability(.init(paths: [.codex: "/opt/homebrew/bin/codex"]))
        )
        _ = page.view
        page.view.layoutSubtreeIfNeeded()

        let installs = Set(descendants(of: page.view).compactMap {
            ($0 as? ThemedButton)?.accessibilityIdentifier()
        }.filter { $0.hasPrefix("onboarding.cli.install.") })
        XCTAssertEqual(installs, Set(AgentKind.allCases.filter { $0 != .codex }.map {
            "onboarding.cli.install.\($0.rawValue)"
        }))
        XCTAssertNotNil(descendants(of: page.view).first {
            $0.accessibilityIdentifier() == "onboarding.cli.summary"
        })
        XCTAssertEqual(ThemeBoundaryAudit.violations(in: page.view), [])
    }

    // MARK: - Rendered State

    /// The install sheet at rest and after a run whose install the PATH cannot reach, plus the
    /// onboarding card on a Mac with none installed, light and dark.
    func testRendersInstallSurfacesToImages() throws {
        guard let directoryPath = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"]
            .flatMap({ $0.isEmpty ? nil : $0 })
        else {
            throw XCTSkip("Set THREADING_RENDER_OUT to capture install evidence")
        }
        let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previousTheme = AppThemeLibrary.current
        AppThemeLibrary.apply(.system)
        defer { AppThemeLibrary.apply(previousTheme) }

        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            var images: [String: Data] = [:]
            appearance.performAsCurrentDrawingAppearance {
                let ready = AgentCLIInstallViewController(kind: .claude, availability: availability())
                images["agent-cli-install-ready"] = png(of: ready.view, appearance: appearance)

                let offPath = AgentCLIInstallViewController(
                    kind: .claude,
                    availability: availability(.init(installedOffPath: [.claude]))
                )
                _ = offPath.view
                offPath.applyProbeForTesting(exitCode: 0)
                images["agent-cli-install-off-path"] = png(of: offPath.view, appearance: appearance)

                let page = OnboardingDiscoveryPageViewController(
                    accountsProvider: { [] },
                    availability: availability(.init(hasNodePackageManager: false))
                )
                page.view.frame = NSRect(x: 0, y: 0, width: 720, height: 1_100)
                images["onboarding-cli-none-installed"] = png(of: page.view, appearance: appearance)
            }
            for (stem, data) in images {
                try data.write(to: directory.appendingPathComponent("\(stem)-\(name).png"))
            }
        }
    }

    // MARK: - Fixtures

    private func availability(
        _ snapshot: AgentCLIAvailability.Snapshot = .init(hasNodePackageManager: true)
    ) -> AgentCLIAvailability {
        let availability = AgentCLIAvailability(probe: { _ in snapshot }, shell: { "/bin/zsh" })
        availability.setSnapshotForTesting(snapshot)
        return availability
    }

    private func descendants(of root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func png(of view: NSView, appearance: NSAppearance) -> Data {
        let host = ThemedSurfaceView()
        host.applySurface(fill: Design.Surface.elevated, radius: .fixed(0))
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
        let size = view.frame.size.width > 0 && view.frame.size.height > 0
            ? view.frame.size
            : view.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = appearance
        AppThemeRefresh.repaint(host)
        host.layoutSubtreeIfNeeded()
        let representation = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: representation)
        return representation.representation(using: .png, properties: [:])!
    }
}
