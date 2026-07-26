import XCTest
import SkalmanExtensionKit
@testable import Skalman

/// The rules behind the info panel that are decisions rather than readings: how a bind address
/// is classified, which port survives when one server reports several, and when a finding is
/// worth saying *where* it came from.
final class SessionInfoTests: XCTestCase {

    // MARK: - Helpers

    private func port(
        _ number: UInt16,
        address: String,
        pid: pid_t = 1,
        command: String = "node",
        isIPv6: Bool = false
    ) -> ListeningPort {
        ListeningPort(port: number, pid: pid, command: command, address: address, isIPv6: isIPv6)
    }

    // MARK: - Process Table

    /// The process list is sized from the kernel's own count rather than a fixed buffer.
    ///
    /// `proc_listallpids` returns how many pids it wrote, and a *full* buffer looks exactly like
    /// a machine with that many processes — so a fixed 4096 truncated silently on a busy machine
    /// and the panel reported a short list as though it were the whole one. Asked against the
    /// real kernel, because the bug was in the sizing and a mocked table would size itself.
    func testTheProcessListIsWholeRatherThanBufferSized() {
        let pids = ProcessUtility.liveProcessIdentifiers()

        // This process is in it, which is the cheapest proof the walk ran at all.
        XCTAssertTrue(pids.contains(getpid()), "the test's own process is missing from the table")

        // Every entry is a real pid: the tail of an over-allocated buffer is zeros, and returning
        // those as processes is how a padded read becomes a wrong answer.
        XCTAssertFalse(pids.contains(where: { $0 <= 0 }), "the list carries buffer padding")
        XCTAssertEqual(Set(pids).count, pids.count, "the list repeats a pid")

        // A macOS session runs well over a hundred processes; a list at exactly a round buffer
        // size is the truncation signature this replaced.
        XCTAssertGreaterThan(pids.count, 20, "the table came back implausibly short")
        XCTAssertNotEqual(pids.count, 4096, "the list is exactly the old fixed buffer size")
    }

    /// The table and the child walk answer from the same reading, so a session's process count
    /// cannot depend on which of them was asked.
    func testTheProcessTableAgreesWithTheChildWalk() {
        let table = ProcessUtility.processTable()
        XCTAssertNotNil(table[getpid()], "the table is missing this process")

        let parent = getppid()
        let childrenOfParent = Set(ProcessUtility.getProcessChildren(forPid: parent))
        let tableChildren = Set(
            table.values.filter { $0.parentPid == parent }.map(\.pid)
        )

        // A process may start or exit between the two reads; the agreement that matters is that
        // this process is a child of its own parent in both.
        XCTAssertTrue(childrenOfParent.contains(getpid()))
        XCTAssertTrue(tableChildren.contains(getpid()))
    }

    // MARK: - Interface Classification

    /// The wildcard addresses mean "every interface", which is the exposure worth naming: the
    /// same port number is a private dev server on loopback and a reachable one here.
    func testWildcardAddressesAreAllInterfaces() {
        XCTAssertEqual(PortInterface(address: "0.0.0.0"), .allInterfaces)
        XCTAssertEqual(PortInterface(address: "::"), .allInterfaces)
    }

    func testLoopbackAddressesAreLocalhost() {
        XCTAssertEqual(PortInterface(address: "127.0.0.1"), .localhost)
        XCTAssertEqual(PortInterface(address: "::1"), .localhost)
    }

    /// The whole 127/8 block is loopback, not just `127.0.0.1` — servers do bind `127.0.0.53`
    /// and friends, and calling those "a specific address" would misreport them as reachable
    /// from outside.
    func testWholeLoopbackBlockIsLocalhost() {
        XCTAssertEqual(PortInterface(address: "127.0.0.53"), .localhost)
        XCTAssertEqual(PortInterface(address: "127.1.2.3"), .localhost)
    }

    func testRoutableAddressIsReportedLiterally() {
        XCTAssertEqual(PortInterface(address: "192.168.1.20"), .address("192.168.1.20"))
    }

    /// An IPv4-mapped IPv6 address describes an IPv4 endpoint, so it is classified by the
    /// address it carries rather than by its notation — otherwise a loopback socket written the
    /// long way reads as a routable one.
    func testIPv4MappedAddressesAreClassifiedByWhatTheyCarry() {
        XCTAssertEqual(PortInterface(address: "::ffff:127.0.0.1"), .localhost)
        XCTAssertEqual(PortInterface(address: "::ffff:0.0.0.0"), .allInterfaces)
    }

    // MARK: - Reachability

    /// Only a port localhost can actually reach is offered as a link. Handing over a URL that
    /// cannot connect is worse than showing none.
    func testOnlyLocallyReachablePortsOfferAURL() {
        XCTAssertNotNil(port(3000, address: "0.0.0.0").localURL)
        XCTAssertNotNil(port(3000, address: "127.0.0.1").localURL)
        XCTAssertNil(port(3000, address: "192.168.1.20").localURL)

        XCTAssertEqual(
            port(5173, address: "127.0.0.1").localURL?.absoluteString,
            "http://localhost:5173"
        )
    }

    // MARK: - Deduplication

    /// A pre-forking server hands the same listening descriptor to every worker, so a dozen pids
    /// each report the port. One row is the honest rendering, and the master — the lowest pid —
    /// is the one worth naming.
    func testPreforkedWorkersCollapseToTheMasterProcess() {
        let ports = [
            port(8000, address: "0.0.0.0", pid: 940),
            port(8000, address: "0.0.0.0", pid: 941),
            port(8000, address: "0.0.0.0", pid: 939)
        ]

        let result = SessionInfoGrouping.deduplicated(ports)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.pid, 939)
    }

    /// A dual-stack listener reports one port on two addresses. The broader binding wins,
    /// because "reachable from anywhere" is the fact that matters and the narrower row would
    /// under-report the exposure.
    func testBroaderBindingWinsOverLoopback() {
        let result = SessionInfoGrouping.deduplicated([
            port(4000, address: "127.0.0.1", pid: 10),
            port(4000, address: "0.0.0.0", pid: 11)
        ])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.interface, .allInterfaces)
    }

    func testPortsAreOrderedByNumber() {
        let result = SessionInfoGrouping.deduplicated([
            port(9229, address: "127.0.0.1"),
            port(3000, address: "0.0.0.0"),
            port(61921, address: "127.0.0.1")
        ])

        XCTAssertEqual(result.map(\.port), [3000, 9229, 61921])
    }

    // MARK: - Grouping

    /// One origin means there is nothing to tell apart, and a lone "Agent" heading over the only
    /// list on screen labels a distinction that does not exist.
    func testASingleOriginProducesOneUnnamedGroup() {
        let snapshot = SessionInfoSnapshot(
            processGroups: [SessionProcessGroup(origin: .agent, processes: [
                SessionProcess(pid: 1, command: "claude", memoryBytes: 0, cpuPercent: nil)
            ])],
            portGroups: [SessionPortGroup(origin: .agent, ports: [port(3000, address: "0.0.0.0")])]
        )

        XCTAssertFalse(snapshot.namesProcessOrigins)
        XCTAssertFalse(snapshot.namesPortOrigins)
    }

    /// Two origins is exactly when the distinction is the point: a port opened by the shell you
    /// typed in is a different fact from one the agent opened.
    func testTwoOriginsAreNamed() {
        let groups = SessionInfoGrouping.groups(
            agent: [port(3000, address: "0.0.0.0")],
            shell: [port(8080, address: "127.0.0.1")]
        )

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.map(\.0), [.agent, .shell])

        let snapshot = SessionInfoSnapshot(
            processGroups: [],
            portGroups: groups.map { SessionPortGroup(origin: $0.0, ports: $0.1) }
        )
        XCTAssertTrue(snapshot.namesPortOrigins)
    }

    /// An origin that contributed nothing is dropped rather than shown empty — a shell that is
    /// open but listening on nothing must not turn the panel into two headings, one of them blank.
    func testAnEmptyOriginIsDropped() {
        let groups = SessionInfoGrouping.groups(
            agent: [port(3000, address: "0.0.0.0")],
            shell: [] as [ListeningPort]
        )

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.0, .agent)
    }

    /// A shell-only finding is still named by its own origin rather than defaulting to "Agent".
    func testShellOnlyKeepsItsOwnOrigin() {
        let groups = SessionInfoGrouping.groups(
            agent: [] as [ListeningPort],
            shell: [port(8080, address: "127.0.0.1")]
        )

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.0, .shell)
    }

    // MARK: - Extension Runtime Boundary

    @MainActor
    func testExtensionRuntimeSnapshotIsSessionScopedAndBounded() {
        let longCommand = String(repeating: "n", count: 200)
        let processes = (1...300).map { index in
            SessionProcess(
                pid: pid_t(index),
                command: longCommand,
                memoryBytes: UInt64(index),
                cpuPercent: Double(index)
            )
        }
        let ports = (1...160).map { index in
            ListeningPort(
                port: UInt16(index),
                pid: pid_t(index),
                command: longCommand,
                address: String(repeating: "a", count: 100),
                isIPv6: false
            )
        }
        let native = SessionInfoSnapshot(
            processGroups: [
                .init(origin: .agent, processes: Array(processes.prefix(200))),
                .init(origin: .shell, processes: Array(processes.dropFirst(200)))
            ],
            portGroups: [
                .init(origin: .agent, ports: Array(ports.prefix(100))),
                .init(origin: .shell, ports: Array(ports.dropFirst(100)))
            ]
        )

        let exposed = LiveExtensionHostSnapshotProvider.extensionRuntimeSnapshot(
            sessionID: "session-1",
            snapshot: native
        )

        XCTAssertEqual(exposed.sessionID, "session-1")
        XCTAssertEqual(
            exposed.processGroups.flatMap(\.processes).count,
            ExtensionSessionRuntimeLimits.maximumProcesses
        )
        XCTAssertEqual(
            exposed.portGroups.flatMap(\.ports).count,
            ExtensionSessionRuntimeLimits.maximumPorts
        )
        XCTAssertEqual(exposed.processGroups.map(\.origin), [.agent, .shell])
        XCTAssertEqual(exposed.portGroups.map(\.origin), [.agent, .shell])
        XCTAssertEqual(
            exposed.processGroups.first?.processes.first?.command.count,
            ExtensionSessionRuntimeLimits.maximumCommandLength
        )
        XCTAssertEqual(
            exposed.portGroups.first?.ports.first?.address.count,
            ExtensionSessionRuntimeLimits.maximumAddressLength
        )
    }

    // MARK: - Process Formatting

    /// A percentage needs two readings to exist. Printing `0%` for "not yet measured" would
    /// claim a measurement that was never taken, and a busy process would read as idle.
    func testAnUnmeasuredProcessDoesNotClaimZero() {
        let process = SessionProcess(pid: 1, command: "node", memoryBytes: 0, cpuPercent: nil)
        XCTAssertEqual(process.formattedCPU, "—")

        let measured = SessionProcess(pid: 1, command: "node", memoryBytes: 0, cpuPercent: 0)
        XCTAssertEqual(measured.formattedCPU, "0%")
    }
}
