@testable import CoreSlice
@testable import ThreadingPTYClient
import Foundation
import ThreadingPTYHostKit

func runBindingContracts() throws {
    var binding = PTYHostConnectionBinding()
    let uuid = UUID()
    let first = PTYHostSessionIdentity.agentSession(SessionID(uuid))
    let other = PTYHostSessionIdentity(.projectTerminal(TerminalID(uuid)))
    do {
        try binding.requireInputBinding()
        throw ContractFailure.failed("unbound input admitted")
    } catch PTYHostClientError.notBound { }
    let attach = PTYHostFrame.attach(PTYHostAttach(id: first))
    let originalReservation = try binding.prepare(attach)
    try binding.requireInputBinding()
    do {
        try binding.prepare(.attach(PTYHostAttach(id: other)))
        throw ContractFailure.failed("second stream admitted")
    } catch PTYHostClientError.alreadyBound(let bound) { try require(bound == first, "binding identity") }
    let wrong: [PTYHostFrame] = [
        .resize(PTYHostResize(id: other, grid: PTYHostGrid(cols: 80, rows: 24))),
        .detach(PTYHostDetach(id: other, screenSeed: Data(), modeSeed: Data(), ringOffset: 0)),
        .closeInput(PTYHostCloseInput(id: other)), .kill(PTYHostKill(id: other, escalate: false))
    ]
    for frame in wrong {
        do {
            try binding.prepare(frame)
            throw ContractFailure.failed("cross-kind same-UUID control admitted")
        } catch PTYHostClientError.sessionMismatch(let bound, let target) {
            try require(bound == first && target == other, "typed mismatch identities")
        }
    }
    binding.received(.spawnRefused(PTYHostSpawnRefused(id: other, reason: .capacity)))
    try require(binding.session == first, "unrelated refusal released binding")
    binding.received(.spawnRefused(PTYHostSpawnRefused(id: first, reason: .capacity)))
    try require(binding.session == nil, "matching refusal retained binding")
    let nextReservation = try binding.prepare(.attach(PTYHostAttach(id: other)))
    binding.sendingFailed(originalReservation)
    try require(binding.session == other, "older send failure released newer binding")
    binding.sendingFailed(nextReservation)
    try require(binding.session == nil, "failed attachment retained binding")
    let firstAttempt = try binding.prepare(attach)
    binding.received(.spawnRefused(PTYHostSpawnRefused(id: first, reason: .capacity)))
    let retry = try binding.prepare(attach)
    binding.sendingFailed(firstAttempt)
    try require(binding.session == first, "old failure released same-session retry")
    binding.sendingFailed(retry)
    try require(binding.session == nil, "retry failure retained binding")
    print("PASS shared PTY binding: input admission, typed identity, refusal and failed-send ordering")
}
