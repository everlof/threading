#if os(Linux)
import AppKit
@testable import CoreSlice

/// Semantic session-row commands for the Linux host's anchored production menu rows. The
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
    var firstVisible = 0

    var entries: [ThemedMenuEntry] {
        switch page {
        case .actions:
            let copyItems = copyEntries
            var rows: [ThemedMenuEntry] = [
                .item(ThemedMenuItem(title: isPinned ? "Unpin" : "Pin",
                    image: ThemedMenuIcon.symbol(isPinned ? "pin.slash" : "pin"),
                    representedValue: Command.pin.rawValue)),
                isSnoozed
                    ? .item(ThemedMenuItem(title: "Unsnooze",
                        image: ThemedMenuIcon.symbol("bell"),
                        representedValue: Command.unsnooze.rawValue))
                    : .item(ThemedMenuItem(title: "Snooze",
                        image: ThemedMenuIcon.symbol("moon.zzz"),
                        representedValue: Command.snooze.rawValue,
                        submenu: snoozeEntries)),
                .item(ThemedMenuItem(title: "Archive", image: ThemedMenuIcon.symbol("archivebox"),
                    representedValue: Command.archive.rawValue))
            ]
            if isRunning {
                rows.append(.item(ThemedMenuItem(title: "Close Session",
                    image: ThemedMenuIcon.symbol("stop.circle"),
                    representedValue: Command.close.rawValue)))
            }
            rows.append(.separator)
            if !openInApps.isEmpty {
                rows.append(.item(ThemedMenuItem(title: "Open in",
                    image: ThemedMenuIcon.symbol("arrow.up.forward.app"),
                    representedValue: Command.openIn.rawValue, submenu: openInEntries)))
            }
            rows.append(.item(ThemedMenuItem(title: "Rename Session…",
                image: ThemedMenuIcon.symbol("pencil"),
                representedValue: Command.rename.rawValue)))
            rows.append(
                .item(ThemedMenuItem(title: "Copy", image: ThemedMenuIcon.symbol("doc.text"),
                    representedValue: Command.copy.rawValue, submenu: copyItems)))
            return rows
        case .openIn: return openInEntries
        case .copy: return copyEntries
        case .snooze: return snoozeEntries
        }
    }

    private var snoozeEntries: [ThemedMenuEntry] {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        let presets: [ThemedMenuEntry] = snoozeMoments.enumerated().map { index, moment in
            let clock = formatter.string(from: moment.date)
            let title: String
            let detail: String?
            switch moment.kind {
            case .inAnHour: title = "In an hour"; detail = clock
            case .tomorrowMorning: title = "Tomorrow at \(clock)"; detail = nil
            case .mondayMorning: title = "Monday at \(clock)"; detail = nil
            }
            return .item(ThemedMenuItem(title: title, subtitle: detail,
                representedValue: Command.snoozeChoice.rawValue + ":\(index)"))
        }
        return [.item(ThemedMenuItem(title: "‹  Snooze", representedValue: Command.back.rawValue)),
                .separator] + presets + [
                    .separator,
                    .item(ThemedMenuItem(title: "Custom time…",
                        image: ThemedMenuIcon.symbol("calendar"),
                        representedValue: Command.customSnooze.rawValue))
                ]
    }

    private var openInEntries: [ThemedMenuEntry] {
        [.item(ThemedMenuItem(title: "‹  Open in", representedValue: Command.back.rawValue)),
         .separator] + openInApps.map { app in
            .item(ThemedMenuItem(title: app.name,
                representedValue: Command.openInChoice.rawValue + ":" + app.id))
         }
    }

    private var copyEntries: [ThemedMenuEntry] {
        var rows: [ThemedMenuEntry] = [
            .item(ThemedMenuItem(title: "‹  Copy", representedValue: Command.back.rawValue)),
            .separator
        ]
        if agentSessionID != nil {
            rows.append(.item(ThemedMenuItem(title: "Agent Session ID",
                representedValue: Command.copyAgentID.rawValue)))
        }
        rows.append(.item(ThemedMenuItem(title: "Threading ID",
            representedValue: Command.copyThreadingID.rawValue)))
        rows.append(.item(ThemedMenuItem(title: "Worktree Path",
            representedValue: Command.copyWorktreePath.rawValue)))
        return rows
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
        if firstVisible >= closeIndex { firstVisible += 1 }
    }

    mutating func openIn() {
        page = .openIn
        selected = 2
        firstVisible = 0
    }

    mutating func openSnooze() {
        page = .snooze
        selected = 2
        firstVisible = 0
    }

    mutating func openCopy() {
        page = .copy
        selected = 2
        firstVisible = 0
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
        firstVisible = 0
    }
}
#endif
