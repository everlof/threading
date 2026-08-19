import Network
import os
import XCTest
import ThreadingRemoteKit
@testable import Threading

/// A port the kernel has just handed out and been given back.
///
/// The listener's port is sticky now, so a test that took the shipped default would fight the
/// app the developer is running, and a hard-coded number would fight the next test. Asking the
/// kernel is the only answer that is true on the machine running the test.
enum FreeLocalPort {
    static func take() -> UInt16 {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = INADDR_ANY.bigEndian
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return RemoteAccessDefaults.defaultListenerPort }
        defer { close(descriptor) }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return RemoteAccessDefaults.defaultListenerPort }
        var resolved = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let read = withUnsafeMutablePointer(to: &resolved) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard read == 0 else { return RemoteAccessDefaults.defaultListenerPort }
        return UInt16(bigEndian: resolved.sin_port)
    }

    /// A port that is free right now and that nothing else is likely to take mid-test.
    ///
    /// Deliberately below the kernel's ephemeral range. A port the kernel just handed out is one
    /// it is also handing to every outbound socket on the machine, and that raced: a `URLSession`
    /// connection took the port between the check and the bind twice in one run.
    static let quietRange: ClosedRange<UInt16> = 20_000...39_000

    static func quiet() -> UInt16? {
        for _ in 0..<40 {
            let candidate = UInt16.random(in: quietRange)
            if isFree(port: candidate) { return candidate }
        }
        return nil
    }

    static func isFree(port: UInt16) -> Bool {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr(RemoteAccessDefaults.host)
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bound == 0
    }
}

/// The listener half of the private-network transport: a sticky, configurable port, and one
/// listener per door rather than one listener bound to everything.
///
/// These boot the real `RemoteAccessServer` against real sockets. Nothing here orders a window on
/// screen, so it stays in the fast level. The colliding sockets are real `NWListener`s too: a
/// mocked collision would prove the fallback logic and not the thing that actually goes wrong,
/// which is what the kernel says when a port is taken.
@MainActor
final class RemoteListenerDoorTests: HostedStoreTestCase {

    /// A LAN address the test can genuinely bind. `::1` is assignable on every Mac while
    /// `127.0.0.2` is not, and the door rules classify by interface name, so an address reported
    /// on `en9` is the LAN door's whatever the address happens to be. That keeps the test off the
    /// developer's real Wi-Fi, which is neither stable nor present on a build machine.
    private static let lanAddress = RemoteNetworkAddress(
        interfaceName: "en9",
        address: "::1",
        isIPv6: true
    )
    private static let tailscaleAddress = RemoteNetworkAddress(
        interfaceName: "utun9",
        address: "100.100.1.1"
    )
    private static let vpnAddress = RemoteNetworkAddress(
        interfaceName: "utun8",
        address: "10.8.0.2"
    )

    private var server: RemoteAccessServer!
    private var identityStore: RemoteAccessIdentityStore!
    private var identityDirectory: URL!
    private var appSettings: AppSettings!
    private var appSettingsDefaults: UserDefaults!
    private var appSettingsSuiteName: String!
    /// A copy shares the same allocation, so the closure the server holds reads whatever the
    /// test writes. This is how an interface arrives and goes away mid-test.
    private let addresses = OSAllocatedUnfairLock<[RemoteNetworkAddress]>(initialState: [])
    private var occupied: [NWListener] = []

    override func setUp() {
        super.setUp()
        appSettingsSuiteName = "RemoteListenerDoorTests.\(UUID().uuidString)"
        appSettingsDefaults = UserDefaults(suiteName: appSettingsSuiteName)!
        appSettings = AppSettings(defaults: appSettingsDefaults)
        addresses.withLock { $0 = [] }
        let source = addresses
        let identity = RemoteIdentityTestStore.make(label: "RemoteListenerDoorTests")
        identityStore = identity.store
        identityDirectory = identity.directory
        server = RemoteAccessServer(
            services: RemoteAccessCoordinator.makeServerServices(appSettings: appSettings),
            addressSource: { source.withLock { $0 } },
            identityProvider: identity.store
        )
        // A hosted test runs inside the shipping app, so an unredirected journal call would
        // append door transitions to the developer's own support journal.
        server.recordListenerDiagnostic = { _, _, _ in }
    }

    override func tearDown() {
        server?.stop()
        server = nil
        RemoteIdentityTestStore.erase(identityDirectory)
        identityDirectory = nil
        identityStore = nil
        for listener in occupied { listener.cancel() }
        occupied.removeAll()
        if let appSettingsSuiteName {
            appSettingsDefaults?.removePersistentDomain(forName: appSettingsSuiteName)
        }
        appSettingsDefaults = nil
        appSettings = nil
        super.tearDown()
    }

    // MARK: - Port

    func testConfiguredPortIsHonouredAndStaysTheSameAcrossRestarts() throws {
        let port = try quietPort()
        let configuration = RemoteListenerConfiguration(preferredPort: port)

        XCTAssertEqual(start(configuration), .listening(port: port))
        XCTAssertEqual(server.port, port, "the configured port is the port taken")

        for restart in 1...3 {
            server.stop()
            XCTAssertNil(server.port, "a stopped listener publishes no port")
            XCTAssertEqual(
                start(configuration),
                .listening(port: port),
                "restart \(restart) must land on the same port, or every paired phone re-pairs"
            )
        }
    }

    func testACollisionWalksTheRangeInOrderAndReportsThePortItTook() throws {
        let first = try occupiedRun(occupying: 2, keepingFree: 2)
        let range = first...(first + 3)

        let outcome = start(RemoteListenerConfiguration(
            preferredPort: first,
            fallbackRange: range
        ))

        XCTAssertEqual(
            outcome,
            .listening(port: first + 2),
            "the walk is in order, so the first free port in the range is the one taken"
        )
        XCTAssertEqual(server.port, first + 2, "the port reported is the port actually bound")
    }

    func testAFullRangeIsANamedFailureRatherThanAnEphemeralPort() throws {
        let first = try occupiedRun(occupying: 3, keepingFree: 0)
        let range = first...(first + 2)

        let outcome = start(RemoteListenerConfiguration(
            preferredPort: first,
            fallbackRange: range
        ))

        XCTAssertEqual(outcome, .failed(.portRangeInUse))
        XCTAssertNil(
            server.port,
            "an exhausted range must not silently become an ephemeral port, which is the bug"
        )
        XCTAssertEqual(server.listenerStatus.state(of: .loopback), .off)
    }

    func testThePortPlanTriesTheConfiguredPortAndThenTheFixedRange() {
        XCTAssertEqual(
            RemoteListenerPortPlan.candidates(preferred: 8760, range: 8760...8763),
            [8760, 8761, 8762, 8763],
            "the shipped default and the range share their first port, which is not tried twice"
        )
        XCTAssertEqual(
            RemoteListenerPortPlan.candidates(preferred: 9000, range: 8760...8762),
            [9000, 8760, 8761, 8762],
            "a moved port is tried first, then the range both ends know"
        )
        XCTAssertEqual(
            RemoteListenerPortPlan.candidates(preferred: 80, range: 8760...8761),
            [8760, 8761],
            "a privileged port is not a candidate"
        )
    }

    // MARK: - Doors

    func testLoopbackIsBoundCleartextAndIsNotAdvertised() throws {
        let port = try quietPort()
        XCTAssertEqual(start(RemoteListenerConfiguration(preferredPort: port)), .listening(port: port))

        let status = server.listenerStatus
        XCTAssertEqual(
            status.state(of: .loopback),
            .bound([RemoteListenerBinding(
                door: .loopback,
                address: RemoteListenerSet.loopbackAddress,
                port: port
            )])
        )
        XCTAssertFalse(
            RemoteAccessDoor.loopback.requiresTLS,
            "the Hosted bridge and Serve talk plain HTTP to loopback"
        )
        XCTAssertEqual(
            httpStatus(host: "127.0.0.1", port: port),
            200,
            "loopback answers plain HTTP"
        )
        XCTAssertEqual(
            RemoteAccessCoordinator.doorEndpoints(status, advertisedHostname: ""),
            [],
            "loopback reaches this Mac only, so it is never a route another device is offered"
        )
    }

    func testEnablingAndDisablingTheLanDoorRebuildsOnlyThatDoorsListeners() throws {
        let port = try quietPort()
        addresses.withLock { $0 = [Self.lanAddress, Self.tailscaleAddress] }
        XCTAssertEqual(start(RemoteListenerConfiguration(preferredPort: port)), .listening(port: port))

        let loopbackIdentity = server.listenerIdentities[RemoteListenerSet.loopbackAddress]
        XCTAssertNotNil(loopbackIdentity)
        XCTAssertNil(server.listenerIdentities[Self.lanAddress], "no door is on by default")

        server.updateDoors([.lan])
        waitUntil("the lan door binds") { self.server.listenerStatus.state(of: .lan).bindings.count == 1 }
        let lanIdentity = server.listenerIdentities[Self.lanAddress]
        XCTAssertNotNil(lanIdentity)
        XCTAssertEqual(
            server.listenerIdentities[RemoteListenerSet.loopbackAddress],
            loopbackIdentity,
            "turning a door on must not rebuild the loopback listener under the bridge using it"
        )
        XCTAssertEqual(server.port, port, "and it must not move the port")

        server.updateDoors([])
        waitUntil("the lan door closes") { self.server.listenerStatus.state(of: .lan) == .off }
        XCTAssertNil(server.listenerIdentities[Self.lanAddress])
        XCTAssertEqual(
            server.listenerIdentities[RemoteListenerSet.loopbackAddress],
            loopbackIdentity,
            "turning a door off must not rebuild loopback either"
        )
        XCTAssertEqual(
            httpStatus(host: "127.0.0.1", port: port),
            200,
            "loopback is still serving after both door changes"
        )
    }

    func testADoorListenerThatFailedIsRebuiltOnTheNextRefresh() throws {
        let port = try quietPort()
        addresses.withLock { $0 = [Self.lanAddress] }
        // Something else already holds the LAN address at the port the door will want.
        guard let squatter = tryOccupy(host: Self.lanAddress.address, port: port) else {
            throw XCTSkip("Could not hold \(Self.lanAddress.address):\(port) to stage the collision")
        }
        occupied.append(squatter)

        XCTAssertEqual(start(RemoteListenerConfiguration(preferredPort: port)), .listening(port: port))
        server.updateDoors([.lan])
        waitUntil("the lan door reports the collision") {
            self.server.listenerStatus.state(of: .lan) == .notReachable(.portInUse)
        }

        // The squatter leaves. Nothing about the door selection changes; only the world did.
        let released = expectation(description: "the squatter has let go")
        squatter.stateUpdateHandler = { state in
            if case .cancelled = state { released.fulfill() }
        }
        squatter.cancel()
        occupied.removeAll { $0 === squatter }
        wait(for: [released], timeout: 5)

        // A refresh is what an interface change triggers; a door is never toggled here. The
        // kernel can hold the port for a moment after the close, so the refresh is repeated
        // until the door is up rather than trusting one attempt.
        waitUntil("the lan door binds on a refresh without being toggled") {
            if self.server.listenerStatus.state(of: .lan).bindings.count == 1 { return true }
            self.server.refreshListenerAddresses()
            return false
        }
        XCTAssertEqual(server.port, port, "and the port did not move")
    }

    func testEnablingOneDoorBindsNothingBelongingToAnother() throws {
        let port = try quietPort()
        addresses.withLock { $0 = [Self.lanAddress, Self.tailscaleAddress, Self.vpnAddress] }
        XCTAssertEqual(
            start(RemoteListenerConfiguration(preferredPort: port, doors: [.lan])),
            .listening(port: port)
        )
        waitUntil("the lan door binds") { self.server.listenerStatus.state(of: .lan).bindings.count == 1 }

        let bound = Set(server.requestedBindings.map(\.address))
        XCTAssertEqual(
            bound,
            [RemoteListenerSet.loopbackAddress, Self.lanAddress],
            "choosing this network must not put a listener on the tailnet or the VPN"
        )
        XCTAssertFalse(bound.contains(Self.tailscaleAddress))
        XCTAssertFalse(bound.contains(Self.vpnAddress))
        XCTAssertFalse(
            server.requestedBindings.contains { $0.address.address == "0.0.0.0" },
            "a wildcard bind is the promise being broken quietly"
        )
    }

    func testADoorThisBuildDoesNotBindSaysSoAndBindsNothing() throws {
        let port = try quietPort()
        addresses.withLock { $0 = [Self.lanAddress, Self.tailscaleAddress] }
        XCTAssertEqual(
            start(RemoteListenerConfiguration(preferredPort: port, doors: [.tailscale])),
            .listening(port: port)
        )

        XCTAssertEqual(
            server.listenerStatus.state(of: .tailscale),
            .notReachable(.notAvailableYet)
        )
        XCTAssertEqual(
            server.requestedBindings.map(\.address),
            [RemoteListenerSet.loopbackAddress]
        )
    }

    func testADoorWithNoInterfacesReportsItselfWithoutTakingLoopbackDown() throws {
        let port = try quietPort()
        addresses.withLock { $0 = [] }
        XCTAssertEqual(
            start(RemoteListenerConfiguration(preferredPort: port, doors: [.lan])),
            .listening(port: port),
            "an absent interface is a door's problem, never the server's"
        )

        XCTAssertEqual(server.listenerStatus.state(of: .lan), .notReachable(.noInterface))
        XCTAssertEqual(server.port, port)
        XCTAssertEqual(httpStatus(host: "127.0.0.1", port: port), 200)

        // The interface arrives. The listener set rebuilds from the new enumeration rather than
        // from whatever it read once at start.
        addresses.withLock { $0 = [Self.lanAddress] }
        server.refreshListenerAddresses()
        waitUntil("the lan door binds once its interface appears") {
            self.server.listenerStatus.state(of: .lan).bindings.count == 1
        }

        // And it goes away again.
        addresses.withLock { $0 = [] }
        server.refreshListenerAddresses()
        waitUntil("the lan door reports itself unreachable again") {
            self.server.listenerStatus.state(of: .lan) == .notReachable(.noInterface)
        }
        XCTAssertEqual(httpStatus(host: "127.0.0.1", port: port), 200)
    }

    // MARK: - Advertised endpoints

    func testLanEndpointsAreAdvertisedOnlyWhileTheDoorIsUp() throws {
        let port = try quietPort()
        addresses.withLock { $0 = [Self.lanAddress] }
        XCTAssertEqual(start(RemoteListenerConfiguration(preferredPort: port)), .listening(port: port))

        XCTAssertEqual(
            RemoteAccessCoordinator.doorEndpoints(
                server.listenerStatus,
                advertisedHostname: "",
                localHostname: "example.local"
            ),
            [],
            "an endpoint list must describe what is bound, not what could be"
        )

        server.updateDoors([.lan])
        waitUntil("the lan door binds") { self.server.listenerStatus.state(of: .lan).bindings.count == 1 }

        let endpoints = RemoteAccessCoordinator.doorEndpoints(
            server.listenerStatus,
            advertisedHostname: "mac.example.com",
            localHostname: "example.local"
        )
        XCTAssertEqual(endpoints.map(\.kind), Array(repeating: RemoteHostEndpointKind.lan, count: 3))
        XCTAssertTrue(endpoints.allSatisfy(\.isStable), "a sticky port makes every one of these stable")
        XCTAssertEqual(
            endpoints.map(\.baseURL.absoluteString),
            [
                "https://[::1]:\(port)/",
                "https://example.local:\(port)/",
                "https://mac.example.com:\(port)/"
            ]
        )
        XCTAssertTrue(
            endpoints.allSatisfy(\.expectsPinnedIdentity),
            "every address on this door is the same self-signed certificate, and the phone has "
                + "to be told that rather than infer it from the kind"
        )
        XCTAssertEqual(
            RemoteHostEndpointSelection.ordered(endpoints, policy: .privateOnly).count,
            endpoints.count,
            "a phone under the fail-closed policy now has these to try, which it did not while "
                + "the door spoke cleartext"
        )
    }

    // MARK: - Classification

    func testInterfacesAreClassifiedByWhatAPhoneCouldActuallyUse() {
        let doors = RemoteDoorClassification.doors(for: [
            RemoteNetworkAddress(interfaceName: "en0", address: "192.168.1.181"),
            RemoteNetworkAddress(interfaceName: "en0", address: "fe80::18e1:d645:f077:bbc6"),
            RemoteNetworkAddress(interfaceName: "en1", address: "169.254.10.4"),
            RemoteNetworkAddress(interfaceName: "awdl0", address: "192.168.9.9"),
            RemoteNetworkAddress(interfaceName: "llw0", address: "192.168.9.10"),
            RemoteNetworkAddress(interfaceName: "lo0", address: "127.0.0.1"),
            RemoteNetworkAddress(interfaceName: "utun4", address: "100.65.47.126"),
            RemoteNetworkAddress(interfaceName: "utun4", address: "fd7a:115c:a1e0::cd38:2f7e"),
            RemoteNetworkAddress(interfaceName: "utun1", address: "10.8.0.2"),
            RemoteNetworkAddress(interfaceName: "vmenet0", address: "192.168.64.1")
        ])

        XCTAssertEqual(
            doors[.lan]?.map(\.address),
            ["192.168.1.181"],
            "link-local addresses are not routes, and a self-assigned address means no DHCP"
        )
        XCTAssertEqual(
            doors[.tailscale]?.map(\.address),
            ["100.65.47.126", "fd7a:115c:a1e0::cd38:2f7e"],
            "a tunnel carrying a 100.64.0.0/10 address is the tailnet, addresses and all"
        )
        XCTAssertEqual(doors[.vpn]?.map(\.address), ["10.8.0.2"])
        XCTAssertNil(doors[.loopback], "loopback is a constant, not something enumerated")
        XCTAssertFalse(
            (doors[.lan] ?? []).contains { ["awdl0", "llw0", "vmenet0"].contains($0.interfaceName) },
            "Apple's peer-to-peer radios carry nothing a phone can route to"
        )
    }

    func testThisMacsOwnInterfacesClassifyWithoutBindingAnything() {
        // A tripwire rather than an assertion about this machine: whatever `getifaddrs` reports,
        // no loopback or link-local address may ever reach a door.
        for (door, addresses) in RemoteDoorClassification.doors(for: RemoteNetworkInterfaces.current()) {
            XCTAssertNotEqual(door, .loopback)
            for address in addresses {
                XCTAssertTrue(RemoteDoorClassification.isRoutable(address))
                XCTAssertFalse(address.interfaceName.hasPrefix("lo"))
                XCTAssertFalse(RemoteInterfaceDefaults.excludedInterfaceNames.contains(address.interfaceName))
            }
        }
    }

    // MARK: - Settings

    func testThePortSettingRefusesAPrivilegedPortAndKeepsTheWorkingValue() {
        XCTAssertEqual(appSettings.remoteAccessListenerPort, RemoteAccessDefaults.defaultListenerPort)

        appSettings.remoteAccessListenerPort = 9123
        XCTAssertEqual(appSettings.remoteAccessListenerPort, 9123)

        appSettings.remoteAccessListenerPort = 80
        XCTAssertEqual(
            appSettings.remoteAccessListenerPort,
            9123,
            "a privileged port is refused, not clamped into one nobody chose"
        )
    }

    func testTheDoorSettingIsTheNetworkDoorByDefaultAndDropsWhatItDoesNotKnow() {
        XCTAssertEqual(
            appSettings.remoteAccessDoors,
            [.lan],
            "the network door ships on now that the listener presents a pinned identity"
        )

        // Switching the only door off has to stay off. An empty array used to be stored as an
        // absent key, which handed the read straight back to the registered default.
        appSettings.remoteAccessDoors = []
        XCTAssertEqual(appSettings.remoteAccessDoors, [])

        appSettings.remoteAccessDoors = [.lan]
        XCTAssertEqual(appSettings.remoteAccessDoors, [.lan])

        appSettingsDefaults.set(["lan", "quantum-tunnel", "loopback"], forKey: "remoteAccessDoors")
        XCTAssertEqual(
            appSettings.remoteAccessDoors,
            [.lan],
            "a door nobody knows fails closed, and loopback is not a door anybody selects"
        )
    }

    // MARK: - Firewall hint

    func testTheFirewallHintReadsTheToolAndNeverClaimsReachability() {
        XCTAssertEqual(
            RemoteFirewallProbe.globalState(from: "Firewall is enabled. (State = 1)"),
            .on
        )
        XCTAssertEqual(
            RemoteFirewallProbe.globalState(from: "Firewall is disabled. (State = 0)"),
            .off
        )
        XCTAssertEqual(RemoteFirewallProbe.globalState(from: "something else entirely"), .unknown)
        XCTAssertEqual(RemoteFirewallProbe.globalState(from: nil), .unknown)
        XCTAssertEqual(
            RemoteFirewallProbe.applicationState(from: "Incoming connection to /x is blocked."),
            .blocked
        )
        XCTAssertEqual(
            RemoteFirewallProbe.applicationState(from: "Incoming connection to /x is permitted."),
            .allowed
        )

        let blocked = RemoteFirewallProbe.read(executableURL: URL(fileURLWithPath: "/x")) { _, arguments in
            arguments.first == "--getglobalstate"
                ? "Firewall is enabled. (State = 1)"
                : "Incoming connection to /x is blocked."
        }
        XCTAssertTrue(blocked.mayBlockIncomingConnections)

        let off = RemoteFirewallProbe.read(executableURL: URL(fileURLWithPath: "/x")) { _, _ in
            "Firewall is disabled. (State = 0)"
        }
        XCTAssertFalse(off.mayBlockIncomingConnections)
        XCTAssertEqual(off.globalState, .off)
    }

    // MARK: - Helpers

    @discardableResult
    private func start(_ configuration: RemoteListenerConfiguration) -> RemoteListenerStartOutcome? {
        var result: RemoteListenerStartOutcome?
        let ready = expectation(description: "listener answered")
        server.start(configuration: configuration) { outcome in
            result = outcome
            ready.fulfill()
        }
        wait(for: [ready], timeout: 10)
        return result
    }

    private func quietPort() throws -> UInt16 {
        guard let port = FreeLocalPort.quiet() else {
            throw XCTSkip("No free port in the quiet range")
        }
        return port
    }

    /// Holds `occupying` consecutive ports for real and leaves `keepingFree` above them, so the
    /// fallback walk is tested against what the kernel says rather than what a mock would.
    private func occupiedRun(occupying: Int, keepingFree: Int) throws -> UInt16 {
        for _ in 0..<40 {
            let base = UInt16.random(in: FreeLocalPort.quietRange)
            let span = UInt16(occupying + keepingFree)
            guard UInt16.max - base > span else { continue }
            guard (0..<span).allSatisfy({ isFree(port: base + $0) }) else { continue }

            var held: [NWListener] = []
            for offset in 0..<UInt16(occupying) {
                guard let listener = tryOccupy(port: base + offset) else { break }
                held.append(listener)
            }
            guard held.count == occupying else {
                for listener in held { listener.cancel() }
                continue
            }
            occupied.append(contentsOf: held)
            return base
        }
        throw XCTSkip("No run of \(occupying + keepingFree) free ports in the quiet range")
    }


    private func tryOccupy(port: UInt16) -> NWListener? {
        tryOccupy(host: RemoteAccessDefaults.host, port: port)
    }

    private func tryOccupy(host: String, port: UInt16) -> NWListener? {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters) else { return nil }
        let settled = expectation(description: "occupying \(port)")
        let ready = OSAllocatedUnfairLock<Bool>(initialState: false)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.withLock { $0 = true }
                settled.fulfill()
            case .failed, .waiting:
                settled.fulfill()
            default:
                break
            }
        }
        listener.newConnectionHandler = { $0.cancel() }
        listener.start(queue: .global())
        wait(for: [settled], timeout: 5)
        guard ready.withLock({ $0 }) else {
            listener.cancel()
            return nil
        }
        return listener
    }

    private nonisolated func isFree(port: UInt16) -> Bool { FreeLocalPort.isFree(port: port) }

    private func httpStatus(host: String, port: UInt16) -> Int? {
        var status: Int?
        let done = expectation(description: "GET / on \(host)")
        let request = URLRequest(url: URL(string: "http://\(host):\(port)/")!)
        URLSession.shared.dataTask(with: request) { _, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 5)
        return status
    }

    private func waitUntil(
        _ description: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping () -> Bool
    ) {
        let met = expectation(description: description)
        let poll = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { timer in
            guard condition() else { return }
            timer.invalidate()
            met.fulfill()
        }
        wait(for: [met], timeout: 5)
        poll.invalidate()
        XCTAssertTrue(condition(), description, file: file, line: line)
    }
}
