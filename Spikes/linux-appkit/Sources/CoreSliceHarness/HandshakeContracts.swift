@testable import CoreSlice
import Foundation
import ThreadingPTYHostKit

func runHandshakeContracts() throws {
    func wire(_ frame: PTYHostFrame) throws -> PTYHostWireFrame {
        PTYHostWireFrame(kind: .control, payload: try JSONEncoder().encode(frame))
    }
    let decode: (Data) -> PTYHostFrame? = { try? JSONDecoder().decode(PTYHostFrame.self, from: $0) }
    var handshake = PTYHostHandshake()
    let prefix = PTYHostWireFrame(kind: .output, payload: Data("before".utf8))
    try require(try handshake.accept([prefix], decodeControl: decode, admit: { _, _ in }) == nil,
                "output cannot finish hello")
    let hello = PTYHostHello(build: "fixture", pid: 1)
    let batch = [try wire(.hello(hello)),
                 PTYHostWireFrame(kind: .output, flags: PTYHostFramingDefaults.standardErrorFlag, payload: Data("stderr".utf8)),
                 try wire(.lost(PTYHostLost(ids: [], since: Date(timeIntervalSince1970: 1)))),
                 PTYHostWireFrame(kind: .control, payload: Data("{\"type\":\"future-fixture\"}".utf8)),
                 PTYHostWireFrame(kind: .output, payload: Data("after".utf8))]
    var admissions = 0
    guard let result = try handshake.accept(batch, decodeControl: decode, admit: { _, compatibility in
        try require(compatibility == .compatible, "hello compatibility")
        admissions += 1
    }) else { throw ContractFailure.failed("hello did not complete") }
    let tags = result.pending.map { delivery -> String in
        switch delivery {
        case .output(let bytes, let stderr): return "\(stderr):\(String(decoding: bytes, as: UTF8.self))"
        case .control: return "control"
        }
    }
    try require(admissions == 1 && tags == ["false:before", "true:stderr", "control", "false:after"],
                "hello batch order, stderr distinction and additive control skip")
    var refused = PTYHostHandshake()
    do {
        _ = try refused.accept([wire(.helloRefused(PTYHostHelloRefusal(compatibility: .peerTooOld, update: .app)))],
                               decodeControl: decode, admit: { _, _ in })
        throw ContractFailure.failed("hello refusal admitted")
    } catch PTYHostClientError.incompatible(let value) {
        try require(value == .selfTooOld, "daemon refusal perspective")
    }
    var bounded = PTYHostHandshake(maximumBytes: 16)
    let empty = PTYHostWireFrame(kind: .output, payload: Data())
    _ = try bounded.accept([empty, empty], decodeControl: decode, admit: { _, _ in })
    do {
        _ = try bounded.accept([empty], decodeControl: decode, admit: { _, _ in })
        throw ContractFailure.failed("empty-frame flood escaped aggregate bound")
    } catch PTYHostClientError.handshakeBufferOverflow(let bytes) {
        try require(bytes == 24, "headers count toward the aggregate bound")
    }
    print("PASS shared handshake: ordered hello batch, stderr, additive controls, refusal perspective and aggregate bound")
}
