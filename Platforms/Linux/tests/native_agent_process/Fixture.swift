import Foundation
import Glibc
@testable import CoreSlice

@main
struct NativeAgentProcessFixture {
    static func main() async throws {
        try await Task.detached { try run() }.value
    }

    private static let nullStreams: [Int32: ChildDescriptorSource] = [0: .nullDevice, 1: .nullDevice, 2: .nullDevice]

    private static func run() throws {
        try checkDescriptors()
        try checkSignalsAndGroup()
        try checkReaping()
        try checkBoundedCapture()
        try checkPipeWriter()
        print("PASS shared native child: descriptor allowlist, working directory/environment, group signals, one reap, bounded output/deadline and partial pipe/EOF/EPIPE cleanup")
    }

    private static func checkDescriptors() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let leakPath = directory.appendingPathComponent("not-inherited").path
        let unexpected = open(leakPath, O_CREAT | O_RDWR, mode_t(0o600))
        precondition(unexpected >= 0)
        defer { _ = close(unexpected) }
        let pipe = try ChildPipe()
        let output = pipe.takeReadHandle()
        let script = """
        import os
        assert os.getcwd() == os.environ['EXPECTED_CWD']
        assert os.environ['VALUE'] == 'é 日本語'
        for number in os.listdir('/proc/self/fd'):
            try: path = os.readlink('/proc/self/fd/' + number)
            except FileNotFoundError: continue
            assert path != os.environ['LEAK_PATH'], (number, path)
            assert int(number) in (0, 1, 2, 9), (number, path)
        os.write(9, 'EXACT é 日本語'.encode())
        """
        let child = try ChildProcessSpawn.spawn(executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", script], environment: ["EXPECTED_CWD": directory.path, "VALUE": "é 日本語", "LEAK_PATH": leakPath],
            workingDirectory: directory, descriptors: [0: .nullDevice, 1: .nullDevice, 2: .nullDevice, 9: .inherited(pipe.writeEnd)])
        pipe.closeWriteEnd()
        let bytes = output.readDataToEndOfFile()
        precondition(child.waitUntilExit(timeout: 3) == .exited(0))
        precondition(String(decoding: bytes, as: UTF8.self) == "EXACT é 日本語")
        try output.close()
        precondition(ChildProcessSpawn.orderedDescriptorActions([0: 1, 1: 0]) == nil)
        do {
            _ = try ChildProcessSpawn.spawn(executableURL: URL(fileURLWithPath: "/bin/true"),
                arguments: ["bad\0argument"], environment: [:], workingDirectory: nil, descriptors: nullStreams)
            preconditionFailure("spawn accepted a truncated argument")
        } catch ChildSpawnError.invalidArgument {}
    }

    private static func checkSignalsAndGroup() throws {
        let child = try ChildProcessSpawn.spawn(executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"], environment: [:], workingDirectory: nil, descriptors: nullStreams)
        precondition(getpgid(child.processIdentifier) == child.processIdentifier)
        precondition(getpgid(child.processIdentifier) != getpgid(getpid()))
        child.terminate()
        precondition(child.waitUntilExit(timeout: 3) == .exited(128 + SIGTERM), "worker signal mask hid TERM")

        let pipe = try ChildPipe()
        let output = pipe.takeReadHandle()
        let script = "import subprocess, sys; child = subprocess.Popen(['/bin/sleep','30']); print(child.pid, flush=True); child.wait()"
        let parent = try ChildProcessSpawn.spawn(executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", script], environment: [:], workingDirectory: nil,
            descriptors: [0: .nullDevice, 1: .inherited(pipe.writeEnd), 2: .nullDevice])
        defer { parent.kill() }
        pipe.closeWriteEnd()
        var reported = Data()
        while reported.last != 10, let byte = try output.read(upToCount: 1), !byte.isEmpty { reported.append(byte) }
        let grandchild = pid_t(String(decoding: reported, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))!
        precondition(getpgid(grandchild) == parent.processIdentifier)
        parent.terminate()
        precondition(parent.waitUntilExit(timeout: 3) == .exited(128 + SIGTERM))
        let deadline = Date().addingTimeInterval(3)
        while isLive(grandchild), Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        precondition(!isLive(grandchild), "a grandchild survived the group signal")
        try output.close()
    }

    private static func isLive(_ pid: pid_t) -> Bool {
        guard let text = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let end = text.lastIndex(of: ")") else { return false }
        let state = text[text.index(after: end)...].split(separator: " ").first
        return state != "Z"
    }

    private static func checkReaping() throws {
        for _ in 0..<100 {
            let child = try ChildProcessSpawn.spawn(executableURL: URL(fileURLWithPath: "/bin/true"),
                arguments: [], environment: [:], workingDirectory: nil, descriptors: nullStreams)
            child.waitUntilExit()
            child.waitUntilExit()
            var callbacks = 0
            child.observeExit { status in precondition(status == 0); callbacks += 1 }
            precondition(callbacks == 1)
            var raw: Int32 = 0
            precondition(waitpid(child.processIdentifier, &raw, WNOHANG) == -1 && errno == ECHILD)
        }
        let deadline = Date().addingTimeInterval(2)
        while pidfdCount() > 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        precondition(pidfdCount() == 0, "cancelled exit sources retained pidfds")
    }

    private static func pidfdCount() -> Int {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd")) ?? []
        return entries.filter { (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/fd/\($0)")) == "anon_inode:[pidfd]" }.count
    }

    private static func pipeDescriptorCount() -> Int {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd")) ?? []
        return entries.filter {
            (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/fd/\($0)"))?.hasPrefix("pipe:[") == true
        }.count
    }

    private static func checkPipeWriter() throws {
        let baseline = pipeDescriptorCount()
        let payload = Data((0..<262_144).map { UInt8($0 % 251) })
        let pair = try ChildPipe()
        let writer = try SignalSafePipeWriter(descriptor: pair.takeWriteDescriptor())
        let completed = DispatchSemaphore(value: 0)
        writer.write(Data()) { completed.signal() }
        writer.write(payload) { completed.signal() }
        // Let the pipe fill before the reader starts; close must preserve the queued suffix.
        Thread.sleep(forTimeInterval: 0.05)
        writer.close(immediately: false)
        let received = LockedState(initialState: Data())
        let eof = DispatchSemaphore(value: 0)
        let reader = pair.takeReadHandle()
        DispatchQueue.global().async {
            let bytes = reader.readDataToEndOfFile()
            received.withLock { $0 = bytes }
            try? reader.close()
            eof.signal()
        }
        precondition(completed.wait(timeout: .now() + 3) == .success)
        precondition(completed.wait(timeout: .now() + 3) == .success)
        precondition(eof.wait(timeout: .now() + 3) == .success)
        precondition(received.withLock { $0 } == payload, "partial writes lost or repeated bytes")

        for _ in 0..<32 {
            let broken = try ChildPipe()
            broken.closeReadEnd()
            let writer = try SignalSafePipeWriter(descriptor: broken.takeWriteDescriptor())
            let settled = DispatchSemaphore(value: 0)
            writer.write(payload) { settled.signal() }
            precondition(settled.wait(timeout: .now() + 2) == .success, "EPIPE lost completion")
            writer.close(immediately: true)
        }
        let deadline = Date().addingTimeInterval(2)
        while pipeDescriptorCount() > baseline, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let finalCount = pipeDescriptorCount()
        precondition(finalCount == baseline, "writer retained descriptors")
    }

    private static func checkBoundedCapture() throws {
        let capture = try BoundedChildProcess.run(executable: "/usr/bin/python3",
            arguments: ["-c", "import os; os.write(1,b'A'*200000); os.write(2,b'Z')"], timeout: 3, maximumOutputBytes: 64)
        precondition(capture.termination == .exited(0) && capture.output.count == 64 && capture.outputWasTruncated)
        precondition(capture.output.last == Character("Z").asciiValue)
        let timed = try BoundedChildProcess.run(executable: "/usr/bin/python3",
            arguments: ["-c", "import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(30)"],
            timeout: 0.2, terminationGrace: 0.1, maximumOutputBytes: 64)
        precondition(timed.termination == .timedOut)
    }
}
