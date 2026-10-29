import AppKit
#if os(Linux)
@testable import CoreSlice
#endif

/// The Attachments card uses one row order and one explanation on both desktop hosts.
/// Hosts supply controls only when they also provide the scanner and page behavior.
@MainActor
enum AttachmentSettingsStructure {
    struct Help {
        let title: String
        let paragraphs: [String]

        var topic: HelpTopic {
            HelpTopic(title: L10n.string(title),
                      paragraphs: paragraphs.map { L10n.string($0) })
        }
    }

    struct Row {
        let title: String
        let subtitle: String?
        let help: Help?
    }

    struct Controls {
        let detection: [AgentKind: NSView]
        let outsideProject: NSView?
        let beforeActionCapture: NSView?
    }

    static func card(controls: Controls,
                     makeRow: (Row, NSView) -> NSView) -> SettingsCard {
        let detectionRows = AgentKind.allCases.compactMap { kind -> NSView? in
            guard let control = controls.detection[kind] else { return nil }
            return makeRow(Row(title: "Detect attachments from \(kind.displayName)",
                               subtitle: nil, help: nil), control)
        }
        let outsideProject = controls.outsideProject.map { control in
            makeRow(Row(
                title: "Include files outside the project",
                subtitle: "Lists paths from anywhere, copying each one in.",
                help: Help(title: "Include files outside the project", paragraphs: [
                    "Detected paths are normally kept to the session's own project, because a "
                        + "paired phone can fetch anything in the list and printed text is not a "
                        + "handoff. Images you attach or the agent shows are never affected."
                ])), control)
        }
        let beforeActionCapture = controls.beforeActionCapture.map { control in
            makeRow(Row(
                title: "Keep the page as it was before each agent action",
                subtitle: "Lets an agent ask what its own browser click changed.",
                help: Help(title: "Keep the page as it was before each agent action", paragraphs: [
                    "The agent compares the page with a picture taken just before its action. "
                        + "The pictures stay in memory for the chat and are never added to your "
                        + "visual baselines.",
                    "Off by default because every page-changing tool call then costs a "
                        + "screenshot. It covers the agent's own actions only, not your clicks or "
                        + "a page updating itself."
                ])), control)
        }
        return SettingsCard(rows: detectionRows + [outsideProject, beforeActionCapture].compactMap { $0 })
    }
}
