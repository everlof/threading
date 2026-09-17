import Darwin
import Foundation
import ThreadingPeerTransport
import XCTest
@testable import Threading

/// A wake or a network change reaches Hosted Direct's control connection.
///
/// A laptop that sleeps, changes Wi-Fi or loses a VPN leaves the control socket dead without a
/// word, and a phone away from home is refused with `hostOffline` until something replaces it. The
/// listener's own keepalive is covered in `PeerHostedHostKeepaliveTests`; these pin what the
/// controller does when told the path may have moved: a waiting reconnect goes now, and nothing
/// runs once Hosted Direct is no longer wanted.
///
/// The service is a closed loopback port, so every connection is refused at once and the
/// controller settles into its reconnect backoff without touching a real network.
@MainActor
final class RemoteHostedConnectivityTests: XCTestCase {
    private static let hostID = "host-connectivity-test"
    private static let targetPort: UInt16 = 9_876
    private static let settleTimeout: TimeInterval = 10

    func testASatisfiedPathChangeStartsAWaitingReconnectAtOnce() async throws {
        let connectivity = RecordingConnectivity()
        let controller = try makeController(connectivity: connectivity)
        defer { controller.stop() }
        controller.start(targetPort: Self.targetPort)

        try await untilWaitingToReconnect(controller)
        controller.connectivityChanged(.networkPath(isSatisfied: true))

        XCTAssertFalse(controller.isWaitingToReconnect)
        XCTAssertEqual(controller.state, .connecting)
    }

    func testAWakeStartsAWaitingReconnectAtOnce() async throws {
        let connectivity = RecordingConnectivity()
        let controller = try makeController(connectivity: connectivity)
        defer { controller.stop() }
        controller.start(targetPort: Self.targetPort)

        try await untilWaitingToReconnect(controller)
        connectivity.deliver(.systemWake)

        XCTAssertFalse(controller.isWaitingToReconnect)
        XCTAssertEqual(controller.state, .connecting)
    }

    func testAPathThatReachesNothingLeavesTheBackoffAlone() async throws {
        let connectivity = RecordingConnectivity()
        let controller = try makeController(connectivity: connectivity)
        defer { controller.stop() }
        controller.start(targetPort: Self.targetPort)

        try await untilWaitingToReconnect(controller)
        controller.connectivityChanged(.networkPath(isSatisfied: false))

        XCTAssertTrue(controller.isWaitingToReconnect)
        XCTAssertEqual(controller.state, .unavailable("service"))
    }

    func testConnectivityIsWatchedOnlyWhileHostedDirectIsWanted() throws {
        let connectivity = RecordingConnectivity()
        let controller = try makeController(connectivity: connectivity)

        XCTAssertFalse(connectivity.isObserving)
        controller.start(targetPort: Self.targetPort)
        XCTAssertTrue(connectivity.isObserving)
        controller.stop()
        XCTAssertFalse(connectivity.isObserving)

        // A change that arrives after the stop, as a wake notification already queued would.
        controller.connectivityChanged(.systemWake)
        XCTAssertEqual(controller.state, .stopped)
        XCTAssertFalse(controller.isWaitingToReconnect)
    }

    func testABuildWithoutAServiceNeverWatches() {
        let connectivity = RecordingConnectivity()
        let controller = RemoteHostedServiceController(
            store: MemoryStore(record: nil),
            endpoint: nil,
            hostID: Self.hostID,
            hostName: "Test Mac",
            localDevelopmentAuthentication: false,
            developmentBrowserAuthentication: false,
            connectivity: connectivity
        )

        controller.start(targetPort: Self.targetPort)

        XCTAssertEqual(controller.state, .notConfigured)
        XCTAssertFalse(connectivity.isObserving)
    }

    // MARK: - Fixtures

    private func makeController(
        connectivity: RecordingConnectivity
    ) throws -> RemoteHostedServiceController {
        let endpoint = try PeerControlPlaneServiceEndpoint(
            XCTUnwrap(URL(string: "http://127.0.0.1:\(try Self.closedLoopbackPort())"))
        )
        return RemoteHostedServiceController(
            store: MemoryStore(record: try Self.record(endpoint: endpoint.baseURL)),
            endpoint: endpoint,
            hostID: Self.hostID,
            hostName: "Test Mac",
            localDevelopmentAuthentication: false,
            developmentBrowserAuthentication: false,
            connectivity: connectivity
        )
    }

    /// Returns in the same main-actor turn that observed the backoff, so the caller's next
    /// statement acts on it before the backoff's own retry can run.
    private func untilWaitingToReconnect(_ controller: RemoteHostedServiceController) async throws {
        let deadline = Date().addingTimeInterval(Self.settleTimeout)
        while !controller.isWaitingToReconnect {
            guard Date() < deadline else {
                XCTFail("The refused connection never settled into its backoff: \(controller.state)")
                throw CancellationError()
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// A loopback port nothing listens on: bound, read and released.
    private static func closedLoopbackPort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EBADF) }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.bind(descriptor, generic, length) == 0
                    && getsockname(descriptor, generic, &length) == 0
            }
        }
        guard bound else { throw POSIXError(.EADDRNOTAVAIL) }
        return UInt16(bigEndian: address.sin_port)
    }

    private static func record(endpoint: URL) throws -> RemoteHostedServiceRecord {
        // Far enough out that neither the session nor the host credential asks the service for
        // renewal first: the only request is the control socket's.
        let future = Date().addingTimeInterval(30 * 24 * 60 * 60)
        return RemoteHostedServiceRecord(
            version: 1,
            endpoint: endpoint,
            session: PeerControlPlaneSession(
                accountID: "account-test",
                accessToken: try PeerControlPlaneBearer("access-token"),
                accessTokenExpiresAt: future,
                refreshToken: try PeerControlPlaneBearer("refresh-token"),
                refreshTokenExpiresAt: future
            ),
            hostCredential: PeerHostServiceCredential(
                hostID: hostID,
                credential: try PeerControlPlaneBearer("host-token"),
                expiresAt: future
            ),
            pendingRevokedDeviceIDs: []
        )
    }
}

@MainActor
private final class RecordingConnectivity: RemoteHostedConnectivityObserving {
    private var onChange: (@MainActor (RemoteHostedConnectivityChange) -> Void)?

    var isObserving: Bool { onChange != nil }

    func start(onChange: @escaping @MainActor (RemoteHostedConnectivityChange) -> Void) {
        self.onChange = onChange
    }

    func stop() {
        onChange = nil
    }

    func deliver(_ change: RemoteHostedConnectivityChange) {
        onChange?(change)
    }
}

private final class MemoryStore: RemoteHostedServicePersisting {
    private var record: RemoteHostedServiceRecord?

    init(record: RemoteHostedServiceRecord?) {
        self.record = record
    }

    func load() throws -> RemoteHostedServiceRecord? { record }
    func save(_ record: RemoteHostedServiceRecord) throws { self.record = record }
    func delete() throws { record = nil }
}
