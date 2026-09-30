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

    var named = AgentSession(kind: .codex, title: "Prompt title",
                             accountHandle: .named("codex-work"))
    named.agentTitle = "Agent title"
    named.customTitle = "My title — 日本語 👩🏽‍💻"
    func row(_ enabled: Bool = true) -> AgentSessionRowPresentation {
        AgentSessionRowPresentation(session: named, usesAgentTitle: enabled,
                                    untitledTitle: "Host fallback")
    }
    try require(row().id == named.id && row().kind == named.kind
                && row().accountHandle == named.accountHandle, "row retains typed identity")
    try require(row().title == named.customTitle && row(false).title == named.customTitle,
                "user title wins independently of preference")
    named.customTitle = ""
    try require(row().title == "Agent title" && row(false).title == "Prompt title",
                "agent-title preference controls precedence")
    named.agentTitle = ""
    try require(row().title == "Prompt title", "empty agent title falls through")
    named.title = ""
    try require(row().title == "Host fallback", "empty sources use host wording")
    try require(row() == .unnamed(id: named.id, kind: named.kind,
                                 accountHandle: named.accountHandle, untitledTitle: "Host fallback"),
                "newly admitted row matches unnamed stored row")
    named.customTitle = "  " + String(repeating: "日本語e\u{301}👩🏽‍💻", count: 80) + "\n"
    try require(row().title == named.customTitle, "renderer owns Unicode bounds and whitespace")
    print("PASS shared session row identity, title precedence and host presentation boundaries")
}
