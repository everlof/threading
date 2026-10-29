@testable import CoreSlice
import Foundation

private enum TerminalMutationFailure: Error { case commitRefused }

func runNavigationContracts() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("threading-navigation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("projects.db")
    let database = try ProjectDatabase(url: url)
    defer { database.close() }

    let older = (0..<4).map { AgentSession(kind: .codex, title: "Older \($0)") }
    let newer = (0..<3).map { AgentSession(kind: .claude, title: "Newer \($0)") }
    var alpha = Project(name: "alpha", folderURL: root.appendingPathComponent("alpha"))
    alpha.sessions = older
    alpha.terminals = (0..<3).map { index in
        ProjectTerminal(id: TerminalID(), title: "Shell \(index)", customTitle: nil,
                        currentDirectory: alpha.folderPath, branch: nil, themeID: nil,
                        soundOverrides: nil, createdAt: Date())
    }
    var beta = Project(name: "beta", folderURL: root.appendingPathComponent("beta"))
    beta.sessions = newer
    beta.isExpanded = false
    try database.save(ProjectsState(projects: [alpha, beta], selectedSessionID: older[0].id))

    let snapshot = try database.navigationSnapshot(recentSessionLimit: 2, recentTerminalLimit: 1)
    try require(snapshot.projects.map(\.isExpanded) == [true, false], "navigation retains standing expansion")
    try require(snapshot.selectedSessionID == older[0].id, "navigation retains selected identity")
    try require(snapshot.projects.map(\.id) == [alpha.id, beta.id], "navigation preserves project order")
    try require(snapshot.projects.map(\.sessionCount) == [4, 3], "navigation counts all sessions")
    try require(snapshot.projects[0].terminalCount == 3, "navigation counts embedded terminals")
    try require(snapshot.projects[0].recentSessions.map(\.id) == [older[3].id, older[2].id],
                "navigation bounds the first project's session decode")
    try require(snapshot.projects[1].recentSessions.map(\.id) == [newer[2].id, newer[1].id],
                "navigation resets the indexed window for the next project")
    try require(snapshot.projects[0].recentTerminals.map(\.id) == [alpha.terminals[2].id],
                "navigation bounds returned terminal rows")

    do {
        try database.save(ProjectsState(projects: []))
        throw ContractFailure.failed("partial navigation authorized graph reconciliation")
    } catch ProjectDatabaseWriteError.partialReadRequiresFullLoad { }

    let raw = try SQLiteDatabase(path: url.path)
    defer { raw.close() }
    try raw.prepare("UPDATE session SET data = ? WHERE id = ?")
        .bind(1, "{ unreadable old session")
        .bind(2, older[0].id.uuidString)
        .run()
    let partial = try database.navigationSnapshot(recentSessionLimit: 2, recentTerminalLimit: 1)
    try require(partial.projects[0].recentSessions.map(\.id) == [older[3].id, older[2].id],
                "unreadable dormant row is not decoded for navigation")
    let beforeExpansion = try raw.prepare("SELECT data FROM project WHERE id = ?")
        .bind(1, alpha.id.uuidString)
    try require(try beforeExpansion.step(), "missing project before expansion")
    let originalProject = beforeExpansion.text(0)!
    beforeExpansion.finalize()
    try require(try database.updateProjectExpansion(id: alpha.id, expanded: false),
                "disclosure update failed with unreadable unrelated session")
    try require(try database.updateProjectExpansion(id: alpha.id, expanded: false),
                "idempotent disclosure update failed")
    try require(try !database.updateProjectExpansion(id: ProjectID(), expanded: true),
                "disclosure recreated a missing project")
    let changed = try database.navigationSnapshot(recentSessionLimit: 0, recentTerminalLimit: 0)
    try require(changed.projects.map(\.isExpanded) == [false, false], "disclosure did not persist")
    try require(changed.selectedSessionID == older[0].id, "disclosure changed runtime selection")
    try require(try database.updateProjectExpansion(id: alpha.id, expanded: true), "disclosure restore failed")
    let afterExpansion = try raw.prepare("SELECT data FROM project WHERE id = ?")
        .bind(1, alpha.id.uuidString)
    try require(try afterExpansion.step(), "missing project after expansion")
    let originalFields = try JSONSerialization.jsonObject(with: Data(originalProject.utf8)) as! NSDictionary
    let restoredFields = try JSONSerialization.jsonObject(with: Data(afterExpansion.text(0)!.utf8)) as! NSDictionary
    try require(originalFields.isEqual(restoredFields),
                "disclosure changed other project settings or terminals")
    afterExpansion.finalize()
    let projectRecords = try database.projectRecords()
    try require(projectRecords.map(\.project.id) == [alpha.id, beta.id],
                "terminal records retain project order without decoding sessions")
    try require(projectRecords.allSatisfy { $0.project.sessions.isEmpty },
                "terminal records loaded session payloads")
    try require(projectRecords[0].project.terminals.map(\.id) == alpha.terminals.map(\.id),
                "terminal attach cannot find saved terminals")
    var editedProject = projectRecords[1].project
    let shell = ProjectTerminal(id: TerminalID(), title: "New shell", customTitle: nil,
                                currentDirectory: editedProject.folderPath, branch: nil,
                                themeID: nil, soundOverrides: nil, createdAt: Date())
    editedProject.terminals.append(shell)
    try database.saveProject(editedProject, position: projectRecords[1].position)
    try require(try database.projectRecords()[1].project.terminals.last?.id == shell.id,
                "terminal creation did not persist after an unreadable unrelated session")
    do {
        _ = try database.load()
        throw ContractFailure.failed("authoritative load accepted unreadable session")
    } catch ProjectDatabaseLoadError.corruptRow { }
    let appended = AgentSession(kind: .claude, title: "New launch after an unreadable old row")
    try database.addSession(appended, to: beta.id, position: newer.count,
                            selectNewSession: true)
    let afterAppend = try database.navigationSnapshot(recentSessionLimit: 0, recentTerminalLimit: 0)
    try require(afterAppend.projects.map(\.sessionCount) == [4, 4],
                "indexed launch changed unrelated session counts")
    try require(afterAppend.selectedSessionID == appended.id,
                "indexed launch did not select its new session")
    try require(try database.sessionRecord(id: appended.id)?.session.id == appended.id,
                "indexed launch could not reopen its new row")
    try runArchivedNavigationContract()
    try runProviderArchiveStateContract()
    try runTerminalMutationContract()
    print("PASS bounded project navigation: indexed recent windows, counts, selection and partial-read fence")
}

private func runTerminalMutationContract() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("threading-terminal-mutation-\(UUID().uuidString)",
                              isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var refuseNextCommit = false
    let database = try ProjectDatabase(url: root.appendingPathComponent("projects.db"),
        transactionCommitPreflight: {
            guard refuseNextCommit else { return }
            refuseNextCommit = false
            throw TerminalMutationFailure.commitRefused
        })
    defer { database.close() }

    var project = Project(name: "terminal owner", folderURL: root)
    let first = ProjectTerminal(id: TerminalID(), title: "Shell", customTitle: nil,
                                currentDirectory: root.path, branch: nil, themeID: nil,
                                soundOverrides: nil, createdAt: Date())
    let second = ProjectTerminal(id: TerminalID(), title: "Other", customTitle: nil,
                                 currentDirectory: root.path, branch: nil, themeID: nil,
                                 soundOverrides: nil, createdAt: Date())
    project.terminals = [first, second]
    try database.save(ProjectsState(projects: [project]))
    try database.saveSelectedTerminalID(first.id)
    let wrongOwner = ProjectID()
    try require(try database.updateTerminal(id: first.id, in: wrongOwner, edit: { terminal in
        terminal.customTitle = "Wrong"
        return true
    }) == nil, "terminal edit accepted a stale owner")
    try require(try !database.removeTerminal(id: first.id, from: wrongOwner),
                "terminal removal accepted a stale owner")

    let directory = root.appendingPathComponent("moved").path
    try require(try database.updateTerminalDirectory(id: first.id, in: project.id,
        directory: directory, expectedCurrentDirectory: root.path),
        "directory report was not saved")
    let renamed = try database.updateTerminal(id: first.id, in: project.id) { terminal in
        terminal.customTitle = "Renamed"
        return true
    }
    try require(renamed?.changed == true && renamed?.terminal.customTitle == "Renamed",
                "terminal rename was not saved")
    try require(renamed?.terminal.currentDirectory == directory,
                "terminal rename overwrote a newer directory report")
    let unchanged = try database.updateTerminal(id: first.id, in: project.id) { terminal in
        terminal.customTitle != "Renamed"
    }
    try require(unchanged?.changed == false, "unchanged terminal edit rewrote the project")
    refuseNextCommit = true
    do {
        _ = try database.removeTerminal(id: first.id, from: project.id)
        throw ContractFailure.failed("refused terminal removal committed")
    } catch TerminalMutationFailure.commitRefused { }
    try require(try database.projectRecord(id: project.id)?.terminals.count == 2,
                "refused terminal removal deleted the durable row")
    try require(try database.navigationSnapshot(recentSessionLimit: 0,
        recentTerminalLimit: 0).selectedTerminal?.terminal.id == first.id,
        "refused terminal removal cleared its selection")
    try require(try database.removeTerminal(id: first.id, from: project.id),
                "terminal removal was not saved")
    let remaining = try database.projectRecord(id: project.id)?.terminals
    try require(remaining?.map(\.id) == [second.id],
                "terminal removal changed a sibling or kept the removed terminal")
    try require(try database.navigationSnapshot(recentSessionLimit: 0,
        recentTerminalLimit: 0).selectedTerminal == nil,
        "terminal removal left a dangling selected terminal")
    print("PASS targeted terminal mutation: owner, current payload, sibling and selection")
}

private func runArchivedNavigationContract() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("threading-archived-navigation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try ProjectDatabase(url: root.appendingPathComponent("projects.db"))
    defer { database.close() }

    var sessions = (0..<5).map { AgentSession(kind: .codex, title: "Chat \($0)") }
    sessions[1].synchronizeArchiveState(true)
    sessions[4].synchronizeArchiveState(true)
    var project = Project(name: "archive", folderURL: root)
    project.sessions = sessions
    try database.save(ProjectsState(projects: [project]))

    let snapshot = try database.navigationSnapshot(recentSessionLimit: 2, recentTerminalLimit: 0)
    try require(snapshot.projects[0].sessionCount == 3, "archived rows counted as sidebar rows")
    try require(snapshot.projects[0].recentSessions.map(\.id) == [sessions[3].id, sessions[2].id],
                "archived recent row displaced a visible conversation")
    try require(try database.sessionRecord(id: sessions[4].id)?.session.isArchived == true,
                "archived conversation was removed from durable storage")
    print("PASS archived sessions stay durable and leave the bounded navigator")
}

private func runProviderArchiveStateContract() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("threading-provider-archive-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let active = root.appendingPathComponent("sessions/2026/10/20", isDirectory: true)
    let archived = root.appendingPathComponent("archived_sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)

    let activeID = TranscriptID("019fd131-6e9a-7b02-90f2-c291334e6d83")
    let archivedID = TranscriptID("019f8e9e-5101-7033-922d-916884a443a7")
    let missingID = TranscriptID("019faf76-e5c4-7331-9832-fb6654e397cc")
    let ambiguousID = TranscriptID("019f99c1-98d4-7251-81d4-2ac20e834d30")
    for (directory, identifier) in [(active, activeID), (archived, archivedID),
                                    (active, ambiguousID), (archived, ambiguousID)] {
        let url = directory.appendingPathComponent(
            "rollout-2026-10-20T00-00-00-\(identifier.rawValue).jsonl")
        try Data().write(to: url)
    }
    let account = AgentAccount(provider: .codex, handle: .standard, configPath: root.path)
    guard let snapshot = ProviderArchiveSnapshot.read(
        account: account, sessionIDs: [activeID, archivedID, missingID, ambiguousID])
    else { throw ContractFailure.failed("Linux could not read provider archive directories") }
    try require(snapshot[activeID] == .active, "active provider rollout was missed")
    try require(snapshot[archivedID] == .archived, "archived provider rollout was missed")
    try require(snapshot[missingID] == .absent, "missing provider rollout was invented")
    try require(snapshot[ambiguousID] == .ambiguous, "duplicate provider rollout was guessed")
    let plan = ProviderArchiveReconciliationPlan.make(
        local: false, provider: true, lastSynchronized: false)
    try require(plan.synchronizedState && plan.providerTarget == nil,
                "external provider archive was not mirrored")
    print("PASS shared provider archive snapshot and reconciliation plan on Linux")
}

/// Opt-in matched read of the old startup path and the bounded navigator on one real store.
/// Fixture creation is timed separately so it cannot be mistaken for startup work.
func runNavigationStress() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("threading-navigation-stress-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try ProjectDatabase(url: root.appendingPathComponent("projects.db"))
    defer { database.close() }
    let title = String(repeating: "saved session title ", count: 8)
    var large = Project(name: "large", folderURL: root.appendingPathComponent("large"))
    large.sessions = (0..<5_000).map { AgentSession(kind: .codex, title: "\($0) \(title)") }
    var small = Project(name: "small", folderURL: root.appendingPathComponent("small"))
    small.sessions = (0..<100).map { AgentSession(kind: .codex, title: "\($0) \(title)") }

    let fixtureStart = DispatchTime.now().uptimeNanoseconds
    try database.save(ProjectsState(projects: [large, small]))
    let fixtureMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - fixtureStart) / 1_000_000

    func measure(_ action: () throws -> Void) throws -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try action()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }
    func fullRead() throws {
        let state = try database.load().state
        try require(state.projects.reduce(0) { $0 + $1.sessions.count } == 5_100,
                    "stress full read lost sessions")
    }
    func navigationRead() throws {
        let snapshot = try database.navigationSnapshot(recentSessionLimit: 512, recentTerminalLimit: 512)
        try require(snapshot.projects.map(\.sessionCount) == [5_000, 100],
                    "stress navigator counts changed")
        try require(snapshot.projects.map { $0.recentSessions.count } == [512, 100],
                    "stress navigator decoded outside its window")
    }
    func creationRead() throws {
        let snapshot = try database.navigationSnapshot(recentSessionLimit: 0, recentTerminalLimit: 0)
        try require(snapshot.projects.map(\.sessionCount) == [5_000, 100],
                    "stress creation counts changed")
        try require(snapshot.projects.allSatisfy { $0.recentSessions.isEmpty },
                    "stress creation decoded standing session payloads")
    }
    func terminalRead() throws {
        let records = try database.projectRecords()
        try require(records.map(\.project.id) == [large.id, small.id],
                    "stress terminal read changed project order")
        try require(records.allSatisfy { $0.project.sessions.isEmpty },
                    "stress terminal read decoded saved sessions")
    }

    try fullRead()
    try navigationRead()
    try creationRead()
    try terminalRead()
    var fullSamples: [Double] = []
    var navigationSamples: [Double] = []
    var creationSamples: [Double] = []
    var terminalSamples: [Double] = []
    for _ in 0..<5 {
        fullSamples.append(try measure(fullRead))
        navigationSamples.append(try measure(navigationRead))
        creationSamples.append(try measure(creationRead))
        terminalSamples.append(try measure(terminalRead))
    }
    func summary(_ samples: [Double]) -> String {
        let sorted = samples.sorted()
        return String(format: "median %.1f ms, max %.1f ms", sorted[2], sorted[4])
    }
    print(String(format: "navigation stress fixture: 5,100 sessions in 2 projects, about 165-byte titles; save %.1f ms", fixtureMilliseconds))
    print("full graph read: \(summary(fullSamples)); bounded navigation: \(summary(navigationSamples))")
    print("new-agent creation read: \(summary(creationSamples))")
    print("terminal project read: \(summary(terminalSamples))")
}
