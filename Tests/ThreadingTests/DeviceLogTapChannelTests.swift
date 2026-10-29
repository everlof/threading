import XCTest
@testable import Threading

final class DeviceLogTapChannelTests: XCTestCase {
    func testCompiledTapPreservesDescriptorsAndLabelsTheirOriginalChannels() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tap-channels-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let resource = try XCTUnwrap(Bundle.main.url(forResource: "threading_log_tap", withExtension: "c.txt"))
        try Data(contentsOf: resource).write(to: directory.appendingPathComponent("tap.c"))
        let source = directory.appendingPathComponent("probe.c")
        try Self.probe.write(to: source, atomically: true, encoding: .utf8)
        let executable = directory.appendingPathComponent("probe")
        let compilation = try BoundedChildProcess.run(
            executable: "/usr/bin/xcrun", arguments: ["clang", "-Wall", "-Werror", source.path, "-o", executable.path],
            timeout: 30, maximumOutputBytes: 4_096
        )
        XCTAssertEqual(compilation.termination, .exited(0), String(decoding: compilation.output, as: UTF8.self))
        guard compilation.termination == .exited(0) else { return }
        let records = directory.appendingPathComponent("records.txt")
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "THREADING_LOG_TAP_INSTALLED")
        environment["THREADING_TAP_TEST_OUTPUT"] = records.path
        let result = try BoundedChildProcess.run(
            executable: executable.path, arguments: [], environment: environment,
            timeout: 5, maximumOutputBytes: 1_024, output: .standardOutput
        )
        XCTAssertEqual(result.termination, .exited(0))
        XCTAssertEqual(String(decoding: result.output, as: UTF8.self), "STDOUT_SENTINEL\n",
                       "stderr must retain its own descriptor rather than be redirected to stdout")
        let captured = try String(contentsOf: records, encoding: .utf8)
        XCTAssertEqual(Set(captured.split(separator: "\n").map(String.init)), [
            "[stdout] STDOUT_SENTINEL", "[stderr] STDERR_SENTINEL",
        ])
    }

    /// Replace only os_log's sink: the actual shipping constructor, pipes and pumps run intact.
    private static let probe = #"""
    #include <os/log.h>
    #include <stdarg.h>
    #include <fcntl.h>
    #include <string.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <unistd.h>
    static void capture_log(const char *format, ...) {
        if (strncmp(format, "[stdout] ", 9) != 0 && strncmp(format, "[stderr] ", 9) != 0) return;
        va_list args;
        va_start(args, format);
        const char *message = va_arg(args, const char *);
        va_end(args);
        char result[512];
        int count = snprintf(result, sizeof(result), "%.8s %s\n", format, message);
        int fd = open(getenv("THREADING_TAP_TEST_OUTPUT"), O_WRONLY | O_CREAT | O_APPEND, 0600);
        if (fd >= 0) { write(fd, result, (size_t)count); close(fd); }
    }
    #undef os_log
    #define os_log(log, format, ...) capture_log(format, ##__VA_ARGS__)
    #include "tap.c"
    int main(void) {
        write(STDOUT_FILENO, "STDOUT_SENTINEL\n", 16);
        write(STDERR_FILENO, "STDERR_SENTINEL\n", 16);
        for (int attempt = 0; attempt < 100; attempt++) {
            int fd = open(getenv("THREADING_TAP_TEST_OUTPUT"), O_RDONLY);
            char buffer[128] = {0};
            if (fd >= 0) { read(fd, buffer, sizeof(buffer) - 1); close(fd); }
            if (strstr(buffer, "STDOUT_SENTINEL") && strstr(buffer, "STDERR_SENTINEL")) return 0;
            usleep(10000);
        }
        return 1;
    }
    """#
}
