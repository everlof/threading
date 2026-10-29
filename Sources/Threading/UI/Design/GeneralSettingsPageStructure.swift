import AppKit

/// The General page's section order, rows, and explanatory copy on both desktop hosts.
/// Hosts supply controls and mutations; the same composition places every available group.
@MainActor
enum GeneralSettingsPageStructure {
    struct Help {
        let title: String
        let paragraphs: [String]
    }

    struct Row {
        let title: String
        let subtitle: String?
        let help: Help?

        init(_ title: String, _ subtitle: String? = nil, help: Help? = nil) {
            self.title = title
            self.subtitle = subtitle
            self.help = help
        }
    }

    struct Startup {
        let restoresSession: NSView
        let policy: NSView?
    }

    struct IdleAgents {
        let window: NSView
        let limit: NSView
    }

    struct SoftwareUpdates {
        let channel: NSView
        let automaticChecks: NSView
    }

    struct Machine {
        let preventsIdleSleep: NSView
        let shellPath: NSView
    }

    struct Controls {
        var startup: Startup?
        var idleAgents: IdleAgents?
        let confirmations: NSView
        var softwareUpdates: SoftwareUpdates?
        var agentTools: NSView?
        var machine: Machine?
    }

    static func sections(
        controls: Controls,
        machineTitle: String,
        row: (Row, NSView) -> NSView,
        section: (String?, Help?, NSView) -> NSView
    ) -> [NSView] {
        func card(_ entries: [(Row, NSView)]) -> SettingsCard {
            SettingsCard(rows: entries.map { row($0.0, $0.1) })
        }

        var result: [NSView] = []
        if let startup = controls.startup {
            var startupRows = [(Row("Reopen the last session at launch"),
                                startup.restoresSession)]
            if let policy = startup.policy {
                startupRows.append((Row("Bring back at launch",
                                        "Which sessions are running again when Threading opens.",
                                        help: Help(title: "Bring back at launch", paragraphs: [
                                            "Sessions resume in the background, one at a time, and are already running "
                                                + "when you open them. Everything else stays dormant and resumes when you "
                                                + "open it."
                                        ])), policy))
            }
            result.append(section("Startup", nil, card(startupRows)))
        }

        if let idle = controls.idleAgents {
            result.append(section("Idle Agents", nil, card([
                (Row("Stop idle agents after", "Counted from your latest turn or visit.",
                     help: Help(title: "Stop idle agents after", paragraphs: [
                        "Counts from the latest submitted turn or local view. Opening a dormant "
                            + "conversation resumes it and refreshes this timer."
                     ])), idle.window),
                (Row("Keep idle agents running", "The most recently used keep running.",
                     help: Help(title: "Keep idle agents running", paragraphs: [
                        "Most recent first. Unfinished, non-resumable, visible, or remotely viewed "
                            + "work is never stopped by this limit."
                     ])), idle.limit)
            ])))
        }

        result.append(section("Confirmations", Help(title: "Confirmations", paragraphs: [
            "Only interruptions you can safely stop are listed. Anything that deletes "
                + "something for good, or grants access to a website, a tool, an "
                + "extension or another person, always asks."
        ]), controls.confirmations))

        if let updates = controls.softwareUpdates {
            result.append(section("Software Updates", nil, card([
                (Row("Updates you receive", "Betas arrive earlier and may be rough.",
                     help: Help(title: "Updates you receive", paragraphs: [
                        "Stable is the finished release and needs no action. Betas arrive earlier "
                            + "and may be rough; switching back here returns you to stable at the "
                            + "next release.",
                        "Nightly is a separate feed you join by installing a nightly build, and "
                            + "leave by downloading a stable build yourself, because a nightly's date "
                            + "version is higher than any release."
                     ])), updates.channel),
                (Row("Check for updates automatically",
                     "Once a day, for the app and each installed agent.",
                     help: Help(title: "Check for updates automatically", paragraphs: [
                        "Threading checks GitHub for the app and each installed agent's official "
                            + "release source. App updates use Sparkle after you agree; agent updates "
                            + "run in a visible terminal only when you choose Update.",
                        "Off stops both background checks — Help ▸ Check for Updates… still checks "
                            + "the app."
                     ])), updates.automaticChecks)
            ])))
        }

        if let agentTools = controls.agentTools {
            result.append(section(nil, nil, agentTools))
        }

        if let machine = controls.machine {
            result.append(section(machineTitle, nil, card([
                (Row("Keep this Mac awake while agents work",
                     "While a turn is running or waiting for your answer.",
                     help: Help(title: "Keep this Mac awake while agents work", paragraphs: [
                        "Prevents idle system sleep while an agent turn is active or waiting for "
                            + "your answer. The display may turn off, and closing a MacBook’s lid can "
                            + "still put it to sleep."
                     ])), machine.preventsIdleSleep),
                (Row("Shell path", "For shell sessions and project tool discovery."),
                 machine.shellPath)
            ])))
        }

        return result
    }
}
