import Foundation
#if os(Linux)
@testable import CoreSlice
#else
@testable import Threading
#endif

// The same source runs in the Linux core harness and in Mac XCTest. It drives the production
// `AgentStreamTransport` against a real child process rather than in-process pipes alone, because
// what differs on Linux is corelibs' FileHandle readability, Process and main-queue delivery.

private enum StreamTransportContractFailure: Error { case failed(String) }

private func requireTransport(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw StreamTransportContractFailure.failed(message) }
}

private enum ContractDefaults {
    static let deadline: TimeInterval = 10
    static let errorCaptureBytes = 64 * 1_024
    static let errorFloodBytes = 300 * 1_024
    static let largeLineBytes = 1_048_576
    static let unicodeEcho = "héllo, räksmörgås 中文 👩🏽‍🚀"
}

/// What the transport delivered, recorded on the main actor where its callbacks run.
@MainActor
private final class TransportReceipt {
    var lines: [String] = []
    var malformedLines = 0
    var failures: [AgentStreamTransportFailure] = []
    var diagnostic: String?
}

/// Yields the main actor until `condition` holds, so the transport's main-queue deliveries run.
///
/// Awaiting is what services them on both platforms. Pumping `RunLoop.main` instead is not
/// portable: on Linux, corelibs' `run(mode:before:)` can wait in its descriptor poll well past
/// its limit date, even with a timer scheduled, until something else is enqueued.
@MainActor
private func pumpMain(until condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(ContractDefaults.deadline)
    while !condition() {
        guard Date() < deadline else { return false }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return true
}

@MainActor
private func requirePumped(_ condition: () -> Bool, _ message: String) async throws {
    guard await pumpMain(until: condition) else { throw StreamTransportContractFailure.failed(message) }
}

/// `{"n":1}` → `n:1`, `{"echo":"…"}` → `echo:…`, `{"blob":"…"}` → `blob:<length>`.
private func parseContractLine(_ data: Data) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    if let number = object["n"] as? Int { return "n:\(number)" }
    if let echo = object["echo"] as? String { return "echo:\(echo)" }
    if let blob = object["blob"] as? String { return "blob:\(blob.utf8.count)" }
    return nil
}

@MainActor
private func makeContractTransport(
    input: FileHandle, output: FileHandle, error: FileHandle,
    maximumLineBytes: Int = AgentStreamTransportDefaults.maximumLineBytes,
    receipt: TransportReceipt
) -> AgentStreamTransport<String> {
    AgentStreamTransport(
        label: "codes.threading.contracts.agent-stream",
        input: input, output: output, error: error,
        maximumLineBytes: maximumLineBytes,
        maximumErrorBytes: ContractDefaults.errorCaptureBytes,
        parser: { parseContractLine($0) },
        // No thread check: the transport enters each callback through
        // `MainActor.assumeIsolated`, which traps off the main actor. After an async main on
        // Linux that actor's queue runs on a dispatch worker, so `Thread.isMainThread` is false
        // there even for correct delivery.
        onLine: { receipt.lines.append($0) },
        onMalformedLine: { receipt.malformedLines += 1 },
        onFailure: { receipt.failures.append($0) }
    )
}

@MainActor
func runStreamTransportContracts() async throws {
    try await runChildProcessContract()
    try await runBoundedOutputContract()
    try await runDetachContract()
    print("PASS production agent stream transport: child process framing, 1 MiB line, stderr flood, "
          + "Unicode stdin echo, EOF diagnostic, output bound and detach")
}

/// One child exercises the transport's whole lifetime: fragmented and malformed lines, a line
/// larger than any pipe buffer, a stderr flood past the capture limit, an echoed stdin message
/// and the bounded diagnostic `finish` returns after the child closes its streams.
@MainActor
private func runChildProcessContract() async throws {
    let script = """
    printf '{"n":1}\\n{"n"'
    sleep 0.05
    printf ':2}\\nnot json\\n'
    head -c \(ContractDefaults.errorFloodBytes) /dev/zero | tr '\\000' x >&2
    printf '{"blob":"'
    head -c \(ContractDefaults.largeLineBytes) /dev/zero | tr '\\000' y
    printf '"}\\n'
    IFS= read -r line
    printf '%s\\n' "$line"
    """
    let input = Pipe(), output = Pipe(), error = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", script]
    process.standardInput = input
    process.standardOutput = output
    process.standardError = error

    let receipt = TransportReceipt()
    let transport = makeContractTransport(
        input: input.fileHandleForWriting, output: output.fileHandleForReading,
        error: error.fileHandleForReading, receipt: receipt)
    transport.start()
    try process.run()

    let blob = "blob:\(ContractDefaults.largeLineBytes)"
    try await requirePumped({ receipt.lines.count >= 3 },
                         "child lines did not arrive: \(receipt.lines)")
    try requireTransport(receipt.lines == ["n:1", "n:2", blob],
                         "fragmented and large lines lost order or content: \(receipt.lines)")
    try requireTransport(receipt.malformedLines == 1, "malformed line was not reported once")

    try requireTransport(transport.writeJSONObject(["echo": ContractDefaults.unicodeEcho]),
                         "writer refused an admitted message")
    try await requirePumped({ receipt.lines.count == 4 }, "stdin echo did not return")
    try requireTransport(receipt.lines.last == "echo:\(ContractDefaults.unicodeEcho)",
                         "Unicode stdin message changed in transit: \(receipt.lines)")

    transport.closeInput()
    try await requirePumped({ !process.isRunning }, "child did not exit after stdin EOF")
    try requireTransport(process.terminationStatus == 0, "child failed: \(process.terminationStatus)")
    transport.finish { receipt.diagnostic = $0 }
    try await requirePumped({ receipt.diagnostic != nil }, "finish did not return a diagnostic")
    let diagnostic = receipt.diagnostic ?? ""
    try requireTransport(diagnostic.utf8.count == ContractDefaults.errorCaptureBytes
                            && diagnostic.allSatisfy { $0 == "x" },
                         "stderr capture was not bounded to its limit: \(diagnostic.utf8.count) bytes")
    try requireTransport(receipt.failures.isEmpty, "unexpected transport failure: \(receipt.failures)")
    transport.detach()
}

/// A newline-free stream must fail at its stated bound instead of growing.
@MainActor
private func runBoundedOutputContract() async throws {
    let input = Pipe(), output = Pipe(), error = Pipe()
    let receipt = TransportReceipt()
    let transport = makeContractTransport(
        input: input.fileHandleForWriting, output: output.fileHandleForReading,
        error: error.fileHandleForReading, maximumLineBytes: 8, receipt: receipt)
    transport.start()
    try output.fileHandleForWriting.write(contentsOf: Data("123456789".utf8))
    try await requirePumped({ !receipt.failures.isEmpty }, "newline-free output was not bounded")
    try requireTransport(receipt.failures == [.outputLineTooLarge(9)],
                         "wrong bound failure: \(receipt.failures)")
    try requireTransport(!transport.writeJSONObject(["n": 1]), "a failed transport admitted a write")
    transport.detach()
}

/// Lines already parsed but not yet delivered must not reach a detached session.
@MainActor
private func runDetachContract() async throws {
    let input = Pipe(), output = Pipe(), error = Pipe()
    let receipt = TransportReceipt()
    let transport = makeContractTransport(
        input: input.fileHandleForWriting, output: output.fileHandleForReading,
        error: error.fileHandleForReading, receipt: receipt)
    transport.start()
    try output.fileHandleForWriting.write(contentsOf: Data("{\"n\":1}\n".utf8))
    transport.detach()
    let quiet = Date().addingTimeInterval(0.2)
    _ = await pumpMain { Date() >= quiet }
    try requireTransport(receipt.lines.isEmpty, "a detached transport delivered \(receipt.lines)")
}
