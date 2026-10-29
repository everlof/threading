import Foundation
@testable import CoreSlice

/// Run the production launch planner in the Linux core target. A host must consume this plan
/// before starting any agent; these cases pin the bounds and daemon-held identity exclusion.
func runStartupRestoreContracts() throws {
    let now = Date(timeIntervalSince1970: 1_000_000)
    func session(_ title: String, used secondsAgo: TimeInterval) -> AgentSession {
        var value = AgentSession(kind: .claude, title: title)
        value.lastTurnAt = now.addingTimeInterval(-secondsAgo)
        return value
    }

    let selected = session("selected", used: 60)
    let held = session("held", used: 120)
    let recent = session("recent", used: 180)
    let older = session("older", used: 240)
    let overflow = session("overflow", used: 300)
    let stale = session("stale", used: 3 * SessionRestoreDefaults.secondsPerDay)
    var archived = session("archived", used: 30)
    archived.isArchived = true
    let sessions = [overflow, stale, archived, recent, held, selected, older]

    let recorded = StartupSessionRelaunch.plan(
        policy: .runningAtLastQuit,
        recorded: [older.id, held.id, selected.id, archived.id],
        sessions: sessions,
        now: now,
        excluding: selected.id,
        heldByHost: [held.id]
    )
    try require(recorded.sessionIDs == [older.id],
                "last-quit plan excludes selected, held and archived identities")
    try require(recorded.outcomes[selected.id] == .restored,
                "selected session belongs to its visible restore path")
    try require(recorded.outcomes[held.id] == .reattached,
                "daemon-held session must not spawn a second provider")
    try require(recorded.outcomes[recent.id] == .notRunningAtLastQuit,
                "a dormant session was not in the recorded live set")
    try require(recorded.outcomes[archived.id] == nil,
                "archived session is absent from the launch ledger")

    let recentlyUsed = StartupSessionRelaunch.plan(
        policy: .recentlyUsed,
        recorded: [], sessions: sessions,
        windowDays: 1, limit: 4, now: now
    )
    try require(recentlyUsed.sessionIDs == [selected.id, held.id, recent.id, older.id],
                "recently-used relaunch is ordered and bounded before spawning")
    try require(recentlyUsed.outcomes[overflow.id] == .beyondLimit(limit: 4),
                "fifth recent session has a limit explanation")
    try require(recentlyUsed.outcomes[stale.id]
                == .outsideWindow(days: 1, lastUsedAt: stale.lastUsedAt),
                "stale session has a window explanation")

    let disabled = StartupSessionRelaunch.plan(
        policy: .nothing, recorded: [selected.id], sessions: sessions, now: now
    )
    try require(disabled.sessionIDs.isEmpty && disabled.outcomes[selected.id] == .restoreDisabled,
                "Nothing never starts a recorded session")
    print("PASS shared startup restore policy: last quit, held IDs, recent cap and Nothing")
}
