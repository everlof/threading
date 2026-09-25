@testable import CoreSlice
import Foundation

func runCreationContracts() throws {
    for kind in AgentKind.allCases {
        guard let record = AgentSessionCreation.makeRecord(kind: kind, usesNativeUI: true) else {
            throw ContractFailure.failed("fresh session refused for \(kind)")
        }
        try require(record.title.isEmpty && !record.hasLaunched, "fresh record defaults")
        try require(record.usesNativeUI == kind.supportsNativeUI, "surface capability clamp")
        try require(record.resumeState == .initial(for: kind), "provider resume initialization")
        try require((AgentSessionCreation.makeRecord(kind: kind, accountHandle: .named("work")) != nil)
                    == kind.supportsAccounts, "account admission")
        try require((AgentSessionCreation.makeRecord(kind: kind, permissionMode: .manual) != nil)
                    == kind.supportsPermissionModes, "permission admission")
    }
    let id = SessionID()
    guard let handoff = ConversationHandoff(endpoints: [
        ConversationHandoffEndpoint(sessionID: SessionID(), kind: .claude, model: nil, title: nil),
        ConversationHandoffEndpoint(sessionID: id, kind: .codex, model: nil, title: nil)
    ]) else { throw ContractFailure.failed("handoff fixture") }
    try require(AgentSessionCreation.makeRecord(kind: .codex, handoff: handoff) == nil, "wrong handoff ID refused")
    try require(AgentSessionCreation.makeRecord(kind: .grok, handoff: handoff, id: id) == nil, "wrong handoff runtime refused")
    try require(AgentSessionCreation.makeRecord(kind: .codex, handoff: handoff, id: id)?.handoff == handoff,
                "valid handoff retained")
    print("PASS shared fresh-session creation: capabilities, defaults and handoff admission")

    guard var launched = AgentSessionCreation.makeRecord(kind: .codex) else {
        throw ContractFailure.failed("Codex launch record fixture")
    }
    launched.lastExitCode = 9
    let launchedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let plan = AgentLaunchPlan(executable: "/bin/sh", arguments: [], resumeState: .awaitingIdentifier)
    AgentLaunchRecording.apply(plan, to: &launched, at: launchedAt)
    try require(launched.hasLaunched && launched.lastActiveAt == launchedAt,
                "launch transition records execution")
    try require(launched.lastExitCode == nil && launched.resumeState == plan.resumeState,
                "launch transition follows plan and clears stale exit")
    print("PASS shared terminal launch recording")
}
