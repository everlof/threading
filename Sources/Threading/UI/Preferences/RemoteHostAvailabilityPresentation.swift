import AppKit

/// Host-owned configuration truth. A successful SSH connection never manufactures a startup
/// guarantee, and a failed check never silently relabels the previous reading as current.
@MainActor
enum RemoteHostAvailabilityPresentation {
    static func startup(_ value: RemoteHostAvailability.Startup) -> String {
        switch value {
        case .unknown: L10n.string("Autostart: Not checked")
        case .automatic: L10n.string("Autostart: Configured")
        case .manual: L10n.string("Autostart: Manual start required")
        }
    }

    static func sleep(_ value: RemoteHostAvailability.Sleep) -> String {
        switch value {
        case .unknown: L10n.string("Sleep: Not checked")
        case .maySleep: L10n.string("Sleep: Automatic sleep enabled")
        case .idleDisabled: L10n.string("Sleep: Idle timers disabled")
        }
    }

    static func warning(_ facts: RemoteHostAvailability) -> String? {
        if facts.startup == .manual {
            return L10n.string("This host needs manual startup after a restart.")
        }
        if facts.sleep == .maySleep {
            return L10n.string("This host can sleep while remote work is running.")
        }
        return nil
    }

    static func freshness(_ check: RemoteHostAvailabilityCheck) -> String {
        if check.isChecking { return L10n.string("Checking startup and sleep settings…") }
        guard let date = check.checkedAt else {
            return check.failed ? L10n.string("Could not check startup and sleep settings. Try Check again.")
                : L10n.string("Check this host to read its startup and sleep settings.")
        }
        let timestamp = DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .short)
        return check.failed
            ? L10n.format("Check failed. Last known settings: %@.", timestamp)
            : L10n.format("Last checked: %@. Check again after changing settings.", timestamp)
    }

    static func summary(_ check: RemoteHostAvailabilityCheck) -> String {
        [startup(check.facts.startup), sleep(check.facts.sleep), freshness(check)].joined(separator: "\n")
    }

    static var help: HelpTopic {
        SettingsUI.help("Host availability", "Connection status describes whether the host answers now. Autostart describes its service configuration after a restart; it does not power on the computer. Sleep settings are checked separately. Closing a lid or choosing Sleep can still interrupt work. A reboot ends running agent processes; reopen saved chats to resume their conversations.")
    }

    static func showSetup(for facts: RemoteHostAvailability, in window: NSWindow?) {
        let text: String
        switch facts.platform {
        case .wsl:
            text = L10n.string("On Windows, run the Threading WSL startup installer in Administrator PowerShell as the account that owns Ubuntu. It creates the background task named Threading WSL Host. Check that the task is enabled and starts at boot, not only at sign-in. In Windows Settings ▸ System ▸ Power & battery, review the sleep timers for plugged-in and battery power. Then return here and choose Check.")
        case .linux:
            text = L10n.string("On the Linux host, enable its installed Threading service to start at boot and enable linger for the account that runs it. Use the existing installer or service manager; do not restart a daemon holding active chats. Review the host’s power settings separately, then return here and choose Check.")
        case .unknown:
            text = L10n.string("Choose Check to identify this host and read its startup settings. If the host cannot be reached, start it manually and check again. Threading does not infer that an unreachable host is asleep or powered off.")
        }
        guard facts.platform == .wsl, let window else {
            NoticeAlert.show(NoticeRequest(title: L10n.string("Startup and sleep settings"), message: text), in: window)
            return
        }
        let request = ChoiceRequest(
            prompt: .saveRemoteHostSetup,
            title: L10n.string("Startup and sleep settings"),
            message: text,
            options: [ConfirmationOption(title: L10n.string("Save Windows Setup…"))],
            cancelTitle: L10n.string("Close"),
            style: .informational
        )
        ConfirmationAlert.choose(request, in: window) { choice in
            guard choice == 0 else { return }
            saveWindowsSetup(in: window)
        }
    }

    private static func saveWindowsSetup(in window: NSWindow) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "install-wsl-startup.ps1"
        panel.message = L10n.string("Save this installer and run it in Administrator PowerShell on the Windows host.")
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let destination = panel.url else { return }
            Task {
                let error = await Task.detached(priority: .utility) { () -> String? in
                    do {
                        guard let source = RemoteHostWindowsSetup.resourceURL else {
                            return L10n.string("The Windows startup installer is missing from this app.")
                        }
                        try Data(contentsOf: source).write(to: destination, options: .atomic)
                        return nil
                    } catch { return error.localizedDescription }
                }.value
                if let error {
                    NoticeAlert.show(NoticeRequest(title: L10n.string("Could not save Windows setup"), message: error), in: window)
                }
            }
        }
    }
}

enum RemoteHostWindowsSetup {
    static var resourceURL: URL? {
        Bundle.main.url(forResource: "install-wsl-startup", withExtension: "ps1", subdirectory: "RemoteHosts")
            ?? Bundle.main.url(forResource: "install-wsl-startup", withExtension: "ps1")
    }
}
