@testable import CoreSlice
import Foundation

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
    try database.save(ProjectsState(projects: [alpha, beta], selectedSessionID: older[0].id))

    let snapshot = try database.navigationSnapshot(recentSessionLimit: 2, recentTerminalLimit: 1)
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
    print("PASS bounded project navigation: indexed recent windows, counts, selection and partial-read fence")
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

    try fullRead()
    try navigationRead()
    try creationRead()
    var fullSamples: [Double] = []
    var navigationSamples: [Double] = []
    var creationSamples: [Double] = []
    for _ in 0..<5 {
        fullSamples.append(try measure(fullRead))
        navigationSamples.append(try measure(navigationRead))
        creationSamples.append(try measure(creationRead))
    }
    func summary(_ samples: [Double]) -> String {
        let sorted = samples.sorted()
        return String(format: "median %.1f ms, max %.1f ms", sorted[2], sorted[4])
    }
    print(String(format: "navigation stress fixture: 5,100 sessions in 2 projects, about 165-byte titles; save %.1f ms", fixtureMilliseconds))
    print("full graph read: \(summary(fullSamples)); bounded navigation: \(summary(navigationSamples))")
    print("new-agent creation read: \(summary(creationSamples))")
}
