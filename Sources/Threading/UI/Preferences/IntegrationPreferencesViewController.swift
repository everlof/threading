import AppKit

/// Integration preferences: how Threading plugs into each agent CLI it launches — the hooks that
/// report activity, Claude's own Remote Control bridge and terminal renderer, and Codex's hook
/// review.
///
/// These were four one-row sections at the bottom of General, each captioned with a provider's
/// name. They are one subject — what Threading writes into, or asks of, a CLI's own
/// configuration — and they belong with the agents rather than with how the app behaves. A
/// section per provider says whose configuration each switch touches.
final class IntegrationPreferencesViewController: NSViewController {

    // MARK: - Controls

    private let remoteControlPopUp = ThemedPopUp()
    private let terminalRendererPopUp = ThemedPopUp()
    private let claudeHookToggle = ThemedToggle()
    private let statusLineToggle = ThemedToggle()
    private let codexHookToggle = ThemedToggle()
    private let codexHookTrustToggle = ThemedToggle()

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        setupControls()
        setupLayout()
    }

    // MARK: - Setup

    private func setupControls() {
        for value in ClaudeRemoteControl.allCases {
            remoteControlPopUp.addItem(
                ThemedMenuItem(title: value.settingsTitle, representedValue: value)
            )
        }
        remoteControlPopUp.selectItem(
            at: ClaudeRemoteControl.allCases.firstIndex(of: AppSettings.shared.claudeRemoteControl) ?? 0
        )
        remoteControlPopUp.target = self
        remoteControlPopUp.action = #selector(remoteControlChanged)
        SettingsUI.preferControlWidth(remoteControlPopUp)

        for value in ClaudeTerminalRenderer.allCases {
            terminalRendererPopUp.addItem(
                ThemedMenuItem(title: value.settingsTitle, representedValue: value)
            )
        }
        terminalRendererPopUp.selectItem(
            at: ClaudeTerminalRenderer.allCases
                .firstIndex(of: AppSettings.shared.claudeTerminalRenderer) ?? 0
        )
        terminalRendererPopUp.target = self
        terminalRendererPopUp.action = #selector(terminalRendererChanged)
        SettingsUI.preferControlWidth(terminalRendererPopUp)

        configure(claudeHookToggle,
                  isOn: AppSettings.shared.reportsClaudeLifecycleEvents,
                  action: #selector(claudeHookChanged))
        configure(statusLineToggle,
                  isOn: AppSettings.shared.suppressesClaudeStatusLine,
                  action: #selector(statusLineChanged))
        configure(codexHookToggle,
                  isOn: AppSettings.shared.installsCodexHooks,
                  action: #selector(codexHookChanged))
        configure(codexHookTrustToggle,
                  isOn: AppSettings.shared.bypassesCodexHookTrust,
                  action: #selector(codexHookTrustChanged))
        codexHookTrustToggle.isEnabled = AppSettings.shared.installsCodexHooks
    }

    private func configure(_ toggle: ThemedToggle, isOn: Bool, action: Selector) {
        toggle.state = isOn ? .on : .off
        toggle.target = self
        toggle.action = action
    }

    private func setupLayout() {
        let page = SettingsUI.page(title: "Integration", sections: [
            SettingsUI.section("Claude Code", claudeCard()),
            SettingsUI.section("Codex", codexCard())
        ])

        page.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: view.topAnchor),
            page.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    /// Claude's Remote Control is Claude's own bridge — not Threading's Remote Access, which has
    /// its own page — so the row says so, and its first choice defers to the account's own
    /// setting rather than deciding for it.
    ///
    /// The renderer row is named after the scroller rather than after Claude's word for the
    /// renderer, because that is the difference a user is choosing: on the main screen the
    /// transcript lands in this app's terminal, where its scrollbar, its find bar and a paired
    /// iPhone can all reach it; on the alternate screen Claude keeps and scrolls its own.
    private func claudeCard() -> SettingsCard {
        SettingsCard(rows: [
            SettingsUI.row(
                title: "Report Claude turn and subagent activity",
                subtitle: "Never edits your Claude configuration. Applies on the next start.",
                help: SettingsUI.help(
                    "Report Claude turn and subagent activity",
                    "Uses a session-only settings file. Off removes Threading's lifecycle hooks "
                        + "from Terminal; Native permission prompts keep working. Applies on the "
                        + "next start or resume."
                ),
                control: claudeHookToggle
            ),
            SettingsUI.row(
                title: "Hide Claude's status line in Threading terminals",
                subtitle: "The status card and usage pill already show what it says.",
                help: SettingsUI.help(
                    "Hide Claude's status line in Threading terminals",
                    "Threading's status card and usage pill already show the model, effort, "
                        + "branch and rate limits, so the line under the composer mostly repeats "
                        + "them. This hides it in sessions Threading launches — your own "
                        + "terminals keep it — while your status-line command still runs with its "
                        + "output discarded, so anything it feeds (like a usage cache) keeps "
                        + "working. Applies on the next start or resume."
                ),
                control: statusLineToggle
            ),
            SettingsUI.row(
                title: "Remote Control for new Claude sessions",
                subtitle: "Claude's own bridge to claude.ai, not Threading's Remote Access.",
                help: SettingsUI.help(
                    "Remote Control for new Claude sessions",
                    "Claude's own bridge to claude.ai and the Claude mobile app, separate from "
                        + "Threading's Remote Access. Following leaves it to the account's own "
                        + "/config. A single chat can still be set on or off from its ⋯ menu."
                ),
                control: remoteControlPopUp
            ),
            SettingsUI.row(
                title: "Scrolling in new Claude terminals",
                subtitle: "Where Claude's transcript lands in a terminal.",
                help: SettingsUI.help(
                    "Scrolling in new Claude terminals",
                    "Claude can draw its interface on the terminal's alternate screen and scroll "
                        + "its own transcript, or on the main screen so the transcript lands in "
                        + "Threading's scrollback — where this app's scrolling, find bar and a "
                        + "paired iPhone can reach it.",
                    "Following leaves the choice to Claude, which defaults to its own. A single "
                        + "chat can still be set from its ⋯ menu, and the choice applies from "
                        + "that chat's next launch."
                ),
                control: terminalRendererPopUp
            )
        ])
    }

    /// Two switches rather than one, because they are separate decisions and only the second
    /// has a security cost: installing writes entries to a file the user owns, while skipping
    /// review un-gates every hook in that folder rather than only ours.
    private func codexCard() -> SettingsCard {
        SettingsCard(rows: [
            SettingsUI.row(
                title: "Report Codex turn boundaries",
                subtitle: "Adds Threading's entries to each account's hooks.json.",
                help: SettingsUI.help(
                    "Report Codex turn boundaries",
                    "Adds Threading's entries to each Codex account's hooks.json, so sessions "
                        + "show exact activity instead of guessing from output. Your existing "
                        + "entries are kept."
                ),
                control: codexHookToggle
            ),
            SettingsUI.row(
                title: "Skip Codex hook review",
                subtitle: "Runs every hook in the config folder unreviewed.",
                help: SettingsUI.help(
                    "Skip Codex hook review",
                    "Codex will not run a hook until you approve its text once. Skipping that "
                        + "runs every hook in the config folder unreviewed, including any an agent "
                        + "adds later. Leave off and approve once in Codex."
                ),
                control: codexHookTrustToggle
            )
        ])
    }

    // MARK: - Actions

    /// A running Claude process has already loaded its settings file, so changing this is
    /// intentionally a next-launch choice rather than pretending to detach hooks mid-turn.
    @objc private func claudeHookChanged() {
        AppSettings.shared.reportsClaudeLifecycleEvents = claudeHookToggle.state == .on
    }

    /// Same next-launch rule as the hooks above, for the same reason: the override rides the
    /// per-session settings file a running Claude has already read.
    @objc private func statusLineChanged() {
        AppSettings.shared.suppressesClaudeStatusLine = statusLineToggle.state == .on
    }

    /// Takes effect on the next launch of each session that has not chosen for itself: the value
    /// is read when the settings file is written, so a running conversation keeps whatever it
    /// connected with until it is relaunched.
    @objc private func remoteControlChanged() {
        guard let value = remoteControlPopUp.selectedItem?.representedValue
            as? ClaudeRemoteControl else { return }
        AppSettings.shared.claudeRemoteControl = value
    }

    /// Applies from each session's next launch, and to existing sessions only where they have
    /// made no choice of their own. The CLI reads the answer once, while it starts.
    @objc private func terminalRendererChanged() {
        guard let value = terminalRendererPopUp.selectedItem?.representedValue
            as? ClaudeTerminalRenderer else { return }
        AppSettings.shared.claudeTerminalRenderer = value
    }

    /// Switching off also removes what was installed, rather than leaving inert entries in a
    /// file the user owns — an off switch that leaves its traces behind is not off.
    @objc private func codexHookChanged() {
        let isOn = codexHookToggle.state == .on
        AppSettings.shared.installsCodexHooks = isOn
        codexHookTrustToggle.isEnabled = isOn

        for account in AgentAccountDiscovery.accounts(for: .codex) {
            if isOn {
                CodexHookInstaller.install(inCodexHome: account.configPath)
            } else {
                CodexHookInstaller.uninstall(fromCodexHome: account.configPath)
            }
        }
    }

    @objc private func codexHookTrustChanged() {
        AppSettings.shared.bypassesCodexHookTrust = codexHookTrustToggle.state == .on
    }
}
