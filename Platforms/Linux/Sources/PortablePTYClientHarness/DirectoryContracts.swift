#if os(Linux)
@testable import TerminalRuntime
import Foundation

func checkWorkingDirectoryReports() throws {
    let emulator = try PTYEmulator(columns: 80, rows: 24, localHostName: "local.test") { _ in }
    func report(_ value: String, historical: Bool = false) {
        emulator.feed(Data("\u{1b}]7;\(value)\u{7}".utf8), replaying: historical)
    }
    let path = "/tmp/日本語 spaced folder"
    let encoded = URL(fileURLWithPath: path).absoluteString
    report(encoded)
    try check(emulator.takeWorkingDirectoryUpdate() == path, "percent-encoded Unicode directory")
    try check(emulator.takeWorkingDirectoryUpdate() == nil, "directory update consumed twice")
    for local in ["file://localhost/tmp/local", "file://LOCAL.TEST/tmp/local", "/tmp/local"] {
        report(local)
        try check(emulator.takeWorkingDirectoryUpdate() == "/tmp/local", "local report refused")
    }
    for invalid in ["relative", "https://local.test/tmp", "file://remote.test/tmp",
                    "file://user@localhost/tmp", "file://localhost:22/tmp",
                    "file:///tmp?query", "file:///tmp#fragment", "file:relative",
                    "file:///tmp/%00bad", "file:///tmp/%0Abad", "//remote/path",
                    "/" + String(repeating: "x", count: 4096)] {
        report(invalid)
        try check(emulator.takeWorkingDirectoryUpdate() == nil, "invalid/locality report admitted: \(invalid.prefix(80))")
    }
    let historical = Array("\u{1b}]7;file:///old\u{7}".utf8)
    for split in 1..<historical.count {
        emulator.feed(Data(historical[..<split]), replaying: true)
        emulator.feed(Data(historical[split...]))
        try check(emulator.takeWorkingDirectoryUpdate() == nil, "historical prefix became live at \(split)")
    }
    report("file:///live")
    report("file:///historical", historical: true)
    try check(emulator.takeWorkingDirectoryUpdate() == "/live", "replay overwrote pending live directory")
    var flood = Data()
    for index in 0..<2000 { flood.append(Data("\u{1b}]7;file:///tmp/\(index)\u{7}".utf8)) }
    emulator.feed(flood)
    try check(emulator.takeWorkingDirectoryUpdate() == "/tmp/1999", "latest directory report not retained")
    try check(emulator.takeWorkingDirectoryUpdate() == nil, "directory flood created an event backlog")
    print("PASS live directory reports: local Unicode paths, remote/invalid/size rejection, replay boundaries and 2000-report coalescing")
}
#endif
