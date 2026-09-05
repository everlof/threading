import AppKit
import XCTest
@testable import Threading

/// The complete account-setup storybook in the two shipping hosts that use it.
///
/// Each state is rendered in System light and dark. Onboarding is mounted inside the real flow
/// footer, while Settings uses the production page/controller at its shared 396-point width.
/// Fixtures never inspect the developer's accounts or start an authentication process.
@MainActor
final class AccountSetupRenderTests: XCTestCase {

    private enum Render {
        static let onboardingSize = NSSize(width: 760, height: 560)
        static let settingsSize = NSSize(width: SettingsUIDefaults.pageWidth, height: 900)

        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
               !override.isEmpty {
                return URL(fileURLWithPath: override, isDirectory: true)
            }
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }
    }

    private struct OnboardingStory {
        let name: String
        let accounts: [AgentAccount]
        let state: AgentAccountSetupState
    }

    private struct SettingsStory {
        let name: String
        let accounts: [AgentAccount]
        let state: AgentAccountSetupState
    }

    override func tearDown() {
        AppThemePalette.set(.system)
        super.tearDown()
    }

    func testChoiceShowsEverySupportedAgentAndOnlyMeasuredLoginActions() {
        let controller = AccountSetupCardViewController(
            coordinator: AgentAccountSetupCoordinator(initialState: .choice)
        )
        let views = descendants(of: controller.view)
        let text = Set(views.compactMap { ($0 as? NSTextField)?.stringValue })

        XCTAssertTrue(AgentKind.allCases.allSatisfy { text.contains($0.displayName) })
        let setupButtons = views.compactMap { $0 as? ThemedButton }.filter {
            $0.accessibilityIdentifier().hasPrefix("account-setup.choose.")
        }
        XCTAssertEqual(
            Set(setupButtons.map { $0.accessibilityIdentifier() }),
            ["account-setup.choose.claude", "account-setup.choose.codex"]
        )
    }

    func testRendersEveryAccountSetupStateInOnboardingAndSettings() throws {
        try FileManager.default.createDirectory(
            at: Render.directory,
            withIntermediateDirectories: true
        )
        AppThemePalette.set(.system)

        let work = fixtureAccount(
            provider: .claude,
            handle: "claude-work",
            path: "/Users/dev/.claude-work",
            name: "Work"
        )
        let personal = fixtureAccount(
            provider: .codex,
            handle: "codex-personal",
            path: "/Users/dev/.codex-personal",
            name: "Personal",
            enabled: false
        )
        let newContext = AgentAccountSetupContext(
            provider: .claude,
            displayName: "Consulting",
            handle: .named("claude-consulting"),
            configPath: "/Users/dev/.claude-consulting",
            isReconnect: false
        )
        let reconnectContext = AgentAccountSetupContext(
            provider: .codex,
            displayName: personal.displayName,
            handle: personal.handle,
            configPath: personal.configPath,
            isReconnect: true
        )

        // The moment the person can act on: the CLI has printed the link it also handed to a
        // browser, and Claude Code's flow ends with a code coming back the other way.
        let claudePrompt = AgentAccountSignInPrompt(
            url: URL(string: "https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&response_type=code&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&state=P1bhsNKBpbv78wuI2BrpJZ9tnICmoy")!,
            acceptsPastedCode: true
        )
        let codexPrompt = AgentAccountSignInPrompt(
            url: URL(string: "https://auth.openai.com/oauth/authorize?response_type=code&client_id=app_EMoamEEZ73f0CkXaXp7hrann&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback")!,
            acceptsPastedCode: false
        )

        let onboardingStories = [
            OnboardingStory(name: "empty-choice", accounts: [], state: .choice),
            OnboardingStory(name: "single-choice", accounts: [work], state: .choice),
            OnboardingStory(name: "multiple-choice", accounts: [work, personal], state: .choice),
            OnboardingStory(name: "naming", accounts: [], state: .naming(.claude)),
            OnboardingStory(name: "running", accounts: [], state: .running(newContext, prompt: nil)),
            OnboardingStory(
                name: "running-with-link",
                accounts: [],
                state: .running(newContext, prompt: claudePrompt)
            ),
            OnboardingStory(
                name: "missing-cli",
                accounts: [],
                state: .failed(
                    provider: .claude,
                    attemptedName: "Consulting",
                    context: newContext,
                    failure: .cliMissing
                )
            ),
            OnboardingStory(
                name: "verification-failed",
                accounts: [],
                state: .failed(
                    provider: .codex,
                    attemptedName: "Personal",
                    context: nil,
                    failure: .verificationFailed
                )
            ),
            OnboardingStory(name: "success", accounts: [work], state: .succeeded(work))
        ]
        let settingsStories = [
            SettingsStory(name: "empty-choice", accounts: [], state: .choice),
            SettingsStory(name: "multiple-choice", accounts: [work, personal], state: .choice),
            SettingsStory(
                name: "reconnect-running",
                accounts: [work, personal],
                state: .running(reconnectContext, prompt: nil)
            ),
            SettingsStory(
                name: "reconnect-running-with-link",
                accounts: [work, personal],
                state: .running(reconnectContext, prompt: codexPrompt)
            )
        ]

        var written = 0
        for story in onboardingStories {
            for (appearanceName, suffix) in appearances {
                let data = try XCTUnwrap(onboardingImage(story, appearance: appearanceName))
                try data.write(to: Render.directory.appendingPathComponent(
                    "account-setup-onboarding-\(story.name)-\(suffix).png"
                ))
                written += 1
            }
        }
        for story in settingsStories {
            for (appearanceName, suffix) in appearances {
                let data = try XCTUnwrap(settingsImage(story, appearance: appearanceName))
                try data.write(to: Render.directory.appendingPathComponent(
                    "account-setup-settings-\(story.name)-\(suffix).png"
                ))
                written += 1
            }
        }

        print("Rendered \(written) account-setup surfaces to \(Render.directory.path)")
        XCTAssertEqual(written, (onboardingStories.count + settingsStories.count) * 2)
    }

    private var appearances: [(NSAppearance.Name, String)] {
        [(.aqua, "light"), (.darkAqua, "dark")]
    }

    private func fixtureAccount(
        provider: AgentKind,
        handle: String,
        path: String,
        name: String,
        enabled: Bool = true
    ) -> AgentAccount {
        AgentAccount(
            provider: provider,
            handle: .named(handle),
            configPath: path,
            displayName: name,
            isEnabled: enabled
        )
    }

    private func onboardingImage(
        _ story: OnboardingStory,
        appearance name: NSAppearance.Name
    ) throws -> Data? {
        let appearance = try XCTUnwrap(NSAppearance(named: name))
        var data: Data?
        appearance.performAsCurrentDrawingAppearance {
            let coordinator = AgentAccountSetupCoordinator(initialState: story.state)
            let page = OnboardingDiscoveryPageViewController(
                accountsProvider: { story.accounts },
                cliResults: [
                    AgentCLIProbe.Result(executable: "claude", resolvedPath: "/usr/local/bin/claude"),
                    AgentCLIProbe.Result(executable: "codex", resolvedPath: "/usr/local/bin/codex"),
                    AgentCLIProbe.Result(executable: "grok", resolvedPath: "/usr/local/bin/grok"),
                    AgentCLIProbe.Result(executable: "opencode", resolvedPath: "/usr/local/bin/opencode"),
                    AgentCLIProbe.Result(executable: "agent", resolvedPath: "/usr/local/bin/agent")
                ],
                setupCoordinator: coordinator
            )
            let flow = OnboardingFlowViewController(pages: [page], onFinish: {})
            data = png(
                of: flow.view,
                size: Render.onboardingSize,
                appearance: appearance,
                background: AppThemePalette.current.resolved(.ground, appearance: appearance)
            )
        }
        return data
    }

    private func settingsImage(
        _ story: SettingsStory,
        appearance name: NSAppearance.Name
    ) throws -> Data? {
        let appearance = try XCTUnwrap(NSAppearance(named: name))
        var data: Data?
        appearance.performAsCurrentDrawingAppearance {
            let coordinator = AgentAccountSetupCoordinator(initialState: story.state)
            let controller = AccountsPreferencesViewController(
                accountsProvider: { story.accounts },
                setupCoordinator: coordinator
            )
            _ = controller.view
            controller.viewWillAppear()
            data = png(
                of: controller.view,
                size: Render.settingsSize,
                appearance: appearance,
                background: NSColor.windowBackgroundColor
            )
        }
        return data
    }

    private func png(
        of content: NSView,
        size: NSSize,
        appearance: NSAppearance,
        background: NSColor
    ) -> Data? {
        let host = NSView(frame: NSRect(origin: .zero, size: size))
        host.appearance = appearance
        content.appearance = appearance
        content.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: host.topAnchor),
            content.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
        AppThemeRefresh.repaint(host)
        host.layoutSubtreeIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.wantsLayer = true
        host.layer?.backgroundColor = background.cgColor
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}
