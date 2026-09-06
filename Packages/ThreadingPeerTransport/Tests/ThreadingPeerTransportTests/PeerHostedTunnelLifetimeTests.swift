import Foundation
import XCTest
@testable import ThreadingPeerTransport

/// A hosted tunnel ends when its transport does, and a stopped one refuses a dial at once.
///
/// The 2026-09-06 iOS report dialled a hosted loopback origin every second for as long as its
/// journal reached back, failing in 20 ms each time, because the tunnel behind that origin had
/// ended and nothing on the device had been told. These pin the two halves of the answer: the
/// transport's end reaches a watcher without anyone sending first, and a stopped proxy refuses
/// the next connection rather than accepting a socket that leads nowhere.
final class PeerHostedTunnelLifetimeTests: XCTestCase {
    func testTheWatcherRunsOnceThePeerClosesTheTransport() async throws {
        let configuration = try PeerTransportConfiguration()
        let offerer = try WebRTCPeerTransport(role: .offerer, configuration: configuration)
        let answerer = try WebRTCPeerTransport(role: .answerer, configuration: configuration)
        defer { Task { await offerer.close() } }

        let offer = try await offerer.makeOffer()
        let answer = try await answerer.makeAnswer(to: offer)
        try await offerer.accept(answer: answer)
        async let offererOpen: Void = offerer.waitUntilOpen()
        async let answererOpen: Void = answerer.waitUntilOpen()
        _ = try await (offererOpen, answererOpen)

        let ended = expectation(description: "the offerer's watch runs after the answerer closes")
        let watch = PeerTransportLifetime.whenEnded(offerer) { ended.fulfill() }
        defer { watch.cancel() }

        await answerer.close()
        // The other side closing is seen through the data channel and ICE, not through anything
        // this side sends, and WebRTC takes its own time to say so.
        await fulfillment(of: [ended], timeout: 30)
    }

    func testAWatchOnAClosedTransportRunsAtOnce() async throws {
        let configuration = try PeerTransportConfiguration()
        let transport = try WebRTCPeerTransport(role: .offerer, configuration: configuration)
        await transport.close()

        let ended = expectation(description: "a transport already over ends the watch")
        let watch = PeerTransportLifetime.whenEnded(transport) { ended.fulfill() }
        defer { watch.cancel() }
        await fulfillment(of: [ended], timeout: 5)
    }

    func testAStoppedProxyRefusesTheNextDial() async throws {
        let pair = await InMemoryMessageTransport.makePair()
        let proxy = PeerTunnelLocalProxy(
            multiplexer: PeerTunnelMultiplexer(role: .client, transport: pair.left)
        )
        let origin = try await proxy.start()
        let port = try XCTUnwrap(origin.port.map { UInt16($0) })
        XCTAssertEqual(Self.tcpConnect(port: port), 0, "the listener answers while the proxy stands")

        proxy.stop()
        // The listener is cancelled on the proxy's own queue; give it a bounded moment.
        var refused = false
        for _ in 0 ..< 50 where !refused {
            refused = Self.tcpConnect(port: port) == ECONNREFUSED
            if !refused { try await Task.sleep(for: .milliseconds(20)) }
        }
        XCTAssertTrue(refused, "a stopped proxy's port refuses the connection")

        // What the phone's journal records for that refusal: `url.-1004`, in milliseconds.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: configuration)
        do {
            _ = try await session.data(from: origin)
            XCTFail("a stopped proxy must not answer")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cannotConnectToHost)
        }
        await pair.left.close()
    }

    /// One blocking loopback connect. Returns 0 on success, otherwise `errno`.
    private static func tcpConnect(port: UInt16) -> Int32 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return errno }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0 ? 0 : errno
    }
}
