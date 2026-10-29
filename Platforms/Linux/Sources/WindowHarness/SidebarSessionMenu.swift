#if os(Linux)
import AppKit
@testable import CoreSlice

/// Semantic session-row commands for the shared anchored menu surface. The
/// session and project identities stay with the open menu; a click revalidates both before a
/// mutation, even if the outline has recycled the row under the pointer.
@MainActor
struct SidebarSessionMenu {
    enum Command: String {
        case pin
        case archive
        case close
        case snooze
        case snoozeChoice
        case customSnooze
        case unsnooze
        case openIn
        case openInChoice
        case rename
        case copy
        case copyAgentID
        case copyThreadingID
        case copyWorktreePath
        case back
    }

    enum Page { case actions, snooze, openIn, copy }

    let sessionID: String
    let projectID: String
    let worktreePath: String
    let agentSessionID: String?
    let customTitle: String?
    let displayTitle: String
    let openInApps: [LinuxExternalApp]
    var isPinned: Bool
    var isSnoozed: Bool
    var isRunning: Bool
    let canResume: Bool
    let snoozeMoments: [SnoozeWallClockMoments.Moment]
    var page: Page = .actions
    var selected = 0

    var entries: [ThemedMenuEntry] {
        switch page {
        case .actions:
            var configuration = SidebarSessionMenuContent.Configuration()
            configuration.isPinned = isPinned
            configuration.isSnoozed = isSnoozed
            configuration.isRunning = isRunning
            configuration.snoozeSubmenu = isSnoozed ? [] : snoozeEntries
            configuration.copy = copyConfiguration
            if !openInApps.isEmpty {
                configuration.sections.identityPrefix.append(.item(ThemedMenuItem(title: "Open in",
                    image: ThemedMenuIcon.symbol("arrow.up.forward.app"),
                    representedValue: Command.openIn.rawValue, submenu: openInEntries)))
            }
            return SidebarSessionMenuContent.entries(configuration)
        case .openIn: return openInEntries
        case .copy: return copyEntries
        case .snooze: return snoozeEntries
        }
    }

    private var snoozeEntries: [ThemedMenuEntry] {
        SidebarSessionMenuContent.snoozeEntries(
            moments: snoozeMoments,
            prelude: [
                .item(ThemedMenuItem(title: "‹  Snooze",
                                       representedValue: Command.back.rawValue)),
                .separator
            ]
        )
    }

    private var openInEntries: [ThemedMenuEntry] {
        [.item(ThemedMenuItem(title: "‹  Open in", representedValue: Command.back.rawValue)),
         .separator] + openInApps.map { app in
            .item(ThemedMenuItem(title: app.name,
                representedValue: Command.openInChoice.rawValue + ":" + app.id))
         }
    }

    private var copyEntries: [ThemedMenuEntry] {
        SidebarSessionMenuContent.copyEntries(copyConfiguration,
                                               actions: SidebarSessionMenuContent.Actions())
    }

    private var copyConfiguration: SidebarSessionMenuContent.Copy {
        var copy = SidebarSessionMenuContent.Copy()
        copy.hasAgentID = agentSessionID != nil
        copy.hasWorktreePath = true
        copy.prelude = [
            .item(ThemedMenuItem(title: "‹  Copy", representedValue: Command.back.rawValue)),
            .separator
        ]
        return copy
    }

    func command(at index: Int) -> Command? {
        guard entries.indices.contains(index), let value = entries[index].item?.representedValue as? String
        else { return nil }
        if value.hasPrefix(Command.openInChoice.rawValue + ":") { return .openInChoice }
        if value.hasPrefix(Command.snoozeChoice.rawValue + ":") { return .snoozeChoice }
        return Command(rawValue: value)
    }

    func snoozeDeadline(at index: Int) -> Date? {
        guard page == .snooze, entries.indices.contains(index),
              let value = entries[index].item?.representedValue as? String,
              value.hasPrefix(Command.snoozeChoice.rawValue + ":"),
              let momentIndex = Int(value.dropFirst(Command.snoozeChoice.rawValue.count + 1)),
              snoozeMoments.indices.contains(momentIndex) else { return nil }
        return snoozeMoments[momentIndex].date
    }

    func openInApp(at index: Int) -> LinuxExternalApp? {
        guard page == .openIn, entries.indices.contains(index),
              let value = entries[index].item?.representedValue as? String,
              value.hasPrefix(Command.openInChoice.rawValue + ":") else { return nil }
        let id = String(value.dropFirst(Command.openInChoice.rawValue.count + 1))
        return openInApps.first { $0.id == id }
    }

    mutating func revealCloseForRunningSession() {
        guard !isRunning else { return }
        isRunning = true
        guard case .actions = page,
              let closeIndex = entries.firstIndex(where: {
                  $0.item?.representedValue as? String == Command.close.rawValue
              }) else { return }
        if selected >= closeIndex { selected += 1 }
    }

    mutating func openIn() {
        page = .openIn
        selected = 2
    }

    mutating func openSnooze() {
        page = .snooze
        selected = 2
    }

    mutating func openCopy() {
        page = .copy
        selected = 2
    }

    mutating func returnToActions() {
        let returningFrom = page
        page = .actions
        let command: Command = switch returningFrom {
        case .snooze: .snooze
        case .openIn: .openIn
        case .copy, .actions: .copy
        }
        selected = entries.firstIndex(where: {
            $0.item?.representedValue as? String == command.rawValue
        }) ?? 0
    }
}
#endif
