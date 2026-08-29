import SwiftUI
import ThreadingRemoteKit
import UIKit
import XCTest
@testable import ThreadingMobile

/// The connection panel says how this phone reaches the Mac: the way in that answered, the
/// address, the identity check, the request's timings, the other saved ways in, and the phone's
/// own network. The report is a value so that each of those is asserted as words, and so that
/// the one thing the panel must never say — the pairing credential — is asserted as absent.
@MainActor
final class MobileConnectionStatusTests: XCTestCase {

    private enum Fixture {
        static let now = Date(timeIntervalSince1970: 1_800_000_000)
        static let token = "SECRET-BEARER-VALUE"
        static let lanURL = URL(string: "https://192.168.1.42:8760/")!
        static let tailnetURL = URL(string: "https://david-mac.tailnet-demo.ts.net:8443/")!
        static let fingerprint = RemoteHostFingerprint(
            certificateDER: Data("connection panel fixture".utf8)
        )

        static func host(pinned: Bool = true) -> PairedRemoteHost {
            PairedRemoteHost(
                id: "mac",
                hostID: "mac",
                shareID: "my-devices",
                scope: "all",
                name: "David’s MacBook Pro",
                link: RemoteConnectionLink(baseURL: tailnetURL, token: token)!,
                lastConnectedAt: now.addingTimeInterval(-3_600),
                endpoints: [
                    RemoteHostEndpointDTO(kind: .tailscale, baseURL: tailnetURL, isStable: true),
                    RemoteHostEndpointDTO(
                        kind: .lan,
                        baseURL: lanURL,
                        isStable: true,
                        identity: .pinned
                    ),
                ],
                connectionPolicy: .privateOnly,
                activeEndpointKind: .tailscale,
                pinnedFingerprint: pinned ? fingerprint.hex : nil
            )
        }

        static func record(
            kind: RemoteHostEndpointKind = .lan,
            url: URL = lanURL,
            hostID: String = "mac"
        ) -> MobileConnectionRecord {
            MobileConnectionRecord.demo(hostID: hostID, baseURL: url, kind: kind, now: now)
        }

        static let wifi = MobileNetworkInterface(
            name: "en0",
            kind: .wifi,
            ipv4: ["192.168.1.23"],
            ipv6: ["fd12:3456:789a::1c2f"]
        )
        static let wifiPath = MobileNetworkPathSummary(status: .satisfied, usesWiFi: true)
    }

    private func resolve(
        phase: RemoteAppModel.Phase = .online,
        progress: RemoteAppModel.ConnectionProgress? = nil,
        host: PairedRemoteHost? = Fixture.host(),
        record: MobileConnectionRecord? = Fixture.record(),
        discovered: URL? = nil,
        path: MobileNetworkPathSummary? = Fixture.wifiPath,
        interfaces: [MobileNetworkInterface] = [Fixture.wifi],
        verdict: @escaping (String) -> RemoteTrustVerdict? = { _ in .accepted }
    ) -> MobileConnectionReport {
        MobileConnectionReport.resolve(
            phase: phase,
            progress: progress,
            host: host,
            record: record,
            discoveredAddress: discovered,
            path: path,
            interfaces: interfaces,
            verdict: verdict,
            now: Fixture.now
        )
    }

    private func row(
        _ id: String,
        in sectionID: String,
        of report: MobileConnectionReport
    ) -> MobileConnectionReport.Row? {
        report.sections.first { $0.id == sectionID }?.rows.first { $0.id == id }
    }

    // MARK: - Online

    func testOnlineReportNamesTheWayInTheAddressAndTheIdentity() throws {
        let report = resolve()

        XCTAssertEqual(report.headline, MobileL10n.string("Connected over %@", "LAN"))
        XCTAssertEqual(report.detail, "David’s MacBook Pro")
        XCTAssertEqual(report.tone, .positive)
        XCTAssertTrue(report.canCheck)
        XCTAssertEqual(report.sections.map(\.id), ["mac", "request", "routes", "phone"])

        XCTAssertEqual(try XCTUnwrap(row("route", in: "mac", of: report)).title, "Way in")
        XCTAssertEqual(try XCTUnwrap(row("route", in: "mac", of: report)).value, "LAN")
        XCTAssertEqual(
            try XCTUnwrap(row("address", in: "mac", of: report)).value,
            "192.168.1.42:8760"
        )
        let identity = try XCTUnwrap(row("identity", in: "mac", of: report))
        XCTAssertEqual(identity.value, "Pinned and verified")
        XCTAssertEqual(identity.tone, .positive)
        XCTAssertEqual(
            try XCTUnwrap(row("identity-code", in: "mac", of: report)).value,
            Fixture.fingerprint.pairingCode
        )
        XCTAssertEqual(
            try XCTUnwrap(row("protocol", in: "mac", of: report)).value,
            MobileL10n.string(
                "%lld · this app %lld",
                Int64(RemoteProtocol.current),
                Int64(RemoteProtocol.current)
            )
        )
    }

    /// The request that answered is described by what URLSession measured, in the units a
    /// person compares: the protocol's name and milliseconds per stage.
    func testTheLastRequestSectionCarriesTheProtocolAndTimings() throws {
        let report = resolve()

        XCTAssertEqual(try XCTUnwrap(row("protocol", in: "request", of: report)).value, "HTTP/2")
        XCTAssertEqual(try XCTUnwrap(row("cellular", in: "request", of: report)).value, "No")
        XCTAssertEqual(try XCTUnwrap(row("reused", in: "request", of: report)).value, "No")
        XCTAssertEqual(try XCTUnwrap(row("dns", in: "request", of: report)).value, "12 ms")
        XCTAssertEqual(try XCTUnwrap(row("tls", in: "request", of: report)).value, "61 ms")
        XCTAssertEqual(try XCTUnwrap(row("server", in: "request", of: report)).value, "34 ms")
    }

    /// Every saved way in is listed with its address, and exactly the one that answered is
    /// marked. Labels alone were right for the recovery card; this panel is the place a person
    /// comes to see addresses.
    func testWaysInListEveryAdvertisedAddressAndMarkTheOneInUse() throws {
        let report = resolve()
        let routes = try XCTUnwrap(report.sections.first { $0.id == "routes" })

        XCTAssertEqual(routes.rows.map(\.title), ["LAN", "Tailscale"])
        let lan = routes.rows[0]
        XCTAssertEqual(lan.value, "192.168.1.42:8760 · In use")
        XCTAssertEqual(lan.tone, .positive)
        let tailnet = routes.rows[1]
        XCTAssertEqual(tailnet.value, "david-mac.tailnet-demo.ts.net:8443")
        XCTAssertEqual(tailnet.tone, .neutral)
        XCTAssertEqual(routes.footer, "Tried in this order until one answers.")
    }

    /// An address the browse found leads the list, and when it is the one in use the mark is on
    /// it rather than on the advertised copy of the same address.
    func testADiscoveredAddressLeadsTheWaysInAndTakesTheMark() throws {
        let report = resolve(discovered: Fixture.lanURL)
        let routes = try XCTUnwrap(report.sections.first { $0.id == "routes" })

        XCTAssertEqual(routes.rows.map(\.id), ["discovered", "endpoint-0", "endpoint-1"])
        XCTAssertEqual(routes.rows[0].title, "Found on this network")
        XCTAssertEqual(routes.rows[0].value, "192.168.1.42:8760 · In use")
        XCTAssertEqual(routes.rows[1].value, "192.168.1.42:8760")
        XCTAssertEqual(routes.rows[1].tone, .neutral)
    }

    func testTheHostedRouteIsNamedWithoutAnAddress() throws {
        let hosted = MobileConnectionRecord(
            hostID: "mac",
            kind: .hosted,
            baseURL: URL(string: "https://127.0.0.1:49152/")!,
            isHosted: true,
            connectedAt: Fixture.now,
            metrics: nil,
            serverProtocol: nil
        )
        let report = resolve(record: hosted)

        XCTAssertEqual(report.headline, MobileL10n.string("Connected over %@", "Direct"))
        XCTAssertEqual(
            try XCTUnwrap(row("address", in: "mac", of: report)).value,
            "Through Threading’s service"
        )
        XCTAssertNil(report.sections.first { $0.id == "request" })
        XCTAssertFalse(report.copyText.contains("127.0.0.1"))
    }

    // MARK: - Other phases

    func testAnOfflineReportKeepsTheLastRouteWithoutClaimingItIsInUse() throws {
        let report = resolve(
            phase: .offline(.transport(URLError(.timedOut), host: "192.168.1.42"))
        )

        XCTAssertEqual(report.headline, "Not connected")
        XCTAssertEqual(report.tone, .negative)
        XCTAssertEqual(try XCTUnwrap(row("route", in: "mac", of: report)).title, "Last way in")
        XCTAssertEqual(
            try XCTUnwrap(row("address", in: "mac", of: report)).title,
            "Last used address"
        )
        XCTAssertEqual(try XCTUnwrap(row("since", in: "mac", of: report)).title, "Last connected")
        XCTAssertFalse(report.copyText.contains("In use"))
    }

    func testAnAutomaticRetrySaysSoInsteadOfFailure() {
        let report = resolve(
            phase: .offline(.transport(URLError(.timedOut), host: "192.168.1.42")),
            progress: .waitingToRetry(attempt: 1)
        )

        XCTAssertEqual(report.headline, "Trying again…")
        XCTAssertEqual(report.tone, .warning)
    }

    func testAConnectingReportSaysWhatItIsTrying() throws {
        let report = resolve(
            phase: .connecting,
            progress: .tryingRoute(
                kind: .tailscale,
                previousKind: .lan,
                number: 2,
                total: 2
            ),
            record: nil
        )

        XCTAssertEqual(report.headline, MobileL10n.string("Trying %@", "Tailscale"))
        XCTAssertEqual(report.tone, .warning)
        XCTAssertEqual(
            try XCTUnwrap(row("status", in: "mac", of: report)).value,
            "Connecting"
        )
        XCTAssertNil(report.sections.first { $0.id == "request" })
    }

    func testWithoutAMacOnlyThePhoneIsDescribed() {
        let report = resolve(host: nil)

        XCTAssertEqual(report.headline, "Not connected to a Mac")
        XCTAssertFalse(report.canCheck)
        XCTAssertEqual(report.sections.map(\.id), ["phone"])
    }

    /// A record is about one Mac. Switching Macs must not lend the previous Mac's address and
    /// timings to the new one.
    func testAnotherMacsRecordIsNotUsed() throws {
        let report = resolve(record: Fixture.record(hostID: "studio"))

        XCTAssertEqual(report.headline, MobileL10n.string("Connected over %@", "Tailscale"))
        XCTAssertEqual(
            try XCTUnwrap(row("address", in: "mac", of: report)).value,
            "david-mac.tailnet-demo.ts.net:8443"
        )
        XCTAssertNil(report.sections.first { $0.id == "request" })
    }

    // MARK: - Identity

    func testIdentityWordsFollowTheVerdict() throws {
        let unchecked = resolve(verdict: { _ in nil })
        XCTAssertEqual(
            try XCTUnwrap(row("identity", in: "mac", of: unchecked)).value,
            "Pinned, not checked yet"
        )

        let unpinned = resolve(host: Fixture.host(pinned: false), verdict: { _ in nil })
        let unpinnedRow = try XCTUnwrap(row("identity", in: "mac", of: unpinned))
        XCTAssertEqual(unpinnedRow.value, "Not pinned")
        XCTAssertEqual(unpinnedRow.tone, .warning)
        XCTAssertNil(row("identity-code", in: "mac", of: unpinned))

        let refused = resolve(verdict: { _ in .rejectedFingerprintMismatch })
        let refusedRow = try XCTUnwrap(row("identity", in: "mac", of: refused))
        XCTAssertEqual(refusedRow.value, "Refused: certificate mismatch")
        XCTAssertEqual(refusedRow.tone, .negative)

        let publicTrust = resolve(verdict: { _ in .notPinned })
        XCTAssertEqual(
            try XCTUnwrap(row("identity", in: "mac", of: publicTrust)).value,
            "Not pinned, system trust"
        )
    }

    /// The verdict is asked about the address in use, which after a failover is not the one the
    /// record remembers.
    func testTheVerdictIsAskedAboutTheAddressInUse() {
        var asked: [String] = []
        _ = resolve(verdict: { host in
            asked.append(host)
            return .accepted
        })

        XCTAssertEqual(asked, ["192.168.1.42"])
    }

    // MARK: - The phone

    func testThePhoneSectionNamesTheNetworkAndEachInterface() throws {
        let cellular = MobileNetworkInterface(
            name: "pdp_ip0",
            kind: .cellular,
            ipv4: ["10.212.44.7"],
            ipv6: []
        )
        let report = resolve(
            path: MobileNetworkPathSummary(
                status: .satisfied,
                usesWiFi: true,
                isConstrained: true
            ),
            interfaces: [Fixture.wifi, cellular]
        )
        let phone = try XCTUnwrap(report.sections.first { $0.id == "phone" })

        XCTAssertEqual(phone.rows.map(\.id), ["network", "interface-en0", "interface-pdp_ip0"])
        XCTAssertEqual(phone.rows[0].value, "Wi-Fi, Low Data Mode")
        XCTAssertEqual(phone.rows[1].title, "Wi-Fi (en0)")
        XCTAssertEqual(phone.rows[1].value, "192.168.1.23\nfd12:3456:789a::1c2f")
        XCTAssertEqual(phone.rows[2].title, "Cellular (pdp_ip0)")
        XCTAssertEqual(phone.rows[2].value, "10.212.44.7")
    }

    func testNoNetworkIsSaidAsAWarning() throws {
        let report = resolve(path: MobileNetworkPathSummary(status: .unsatisfied), interfaces: [])
        let network = try XCTUnwrap(row("network", in: "phone", of: report))

        XCTAssertEqual(network.value, "No network")
        XCTAssertEqual(network.tone, .warning)
    }

    func testAPathNotYetObservedSaysChecking() throws {
        let report = resolve(path: nil, interfaces: [])

        XCTAssertEqual(try XCTUnwrap(row("network", in: "phone", of: report)).value, "Checking…")
    }

    // MARK: - The pasteboard

    /// The copy carries the same words as the panel and nothing the panel does not show: the
    /// bearer lives in the link, and the link is never in the report.
    func testCopyTextCarriesTheAddressesAndNeverTheCredential() {
        let text = resolve().copyText

        XCTAssertTrue(text.contains("192.168.1.42:8760"))
        XCTAssertTrue(text.contains("192.168.1.23"))
        XCTAssertTrue(text.contains("This iPhone"))
        XCTAssertFalse(text.contains(Fixture.token))
        XCTAssertFalse(text.contains(Fixture.fingerprint.hex))
        XCTAssertFalse(text.contains("#"))
    }

    /// IP addresses are useful in a deliberate copy, but the ordinary pasteboard policy may
    /// relay them over Universal Clipboard. The connection panel's copy is device-local.
    func testCopyDetailsCannotLeaveThePhoneThroughUniversalClipboard() {
        XCTAssertEqual(
            MobileConnectionPasteboard.options[.localOnly] as? Bool,
            true
        )
    }

    // MARK: - Addresses

    func testAddressesReadAsHostAndPort() {
        XCTAssertEqual(
            MobileConnectionAddressFormat.display(URL(string: "https://192.168.1.42:8760/")!),
            "192.168.1.42:8760"
        )
        XCTAssertEqual(
            MobileConnectionAddressFormat.display(URL(string: "https://[fd00::1]:8760/")!),
            "[fd00::1]:8760"
        )
        XCTAssertEqual(
            MobileConnectionAddressFormat.display(URL(string: "https://mac.example.ts.net/")!),
            "mac.example.ts.net"
        )
    }

    /// Even if a corrupt stored route somehow has no host, formatting stays a projection of the
    /// origin instead of falling back to the full URL, where credentials can live.
    func testAnInvalidAddressCannotExposeURLSecrets() {
        let malformed = URL(string: "threading:route?token=SECRET-BEARER-VALUE#credential")!

        XCTAssertEqual(MobileConnectionAddressFormat.display(malformed), "—")
    }

    // MARK: - Interfaces

    func testInterfaceKindsAreReadOffTheirNames() {
        XCTAssertEqual(MobileNetworkInterfaces.kind(forInterfaceNamed: "en0"), .wifi)
        XCTAssertEqual(MobileNetworkInterfaces.kind(forInterfaceNamed: "en2"), .wired)
        XCTAssertEqual(MobileNetworkInterfaces.kind(forInterfaceNamed: "pdp_ip0"), .cellular)
        XCTAssertEqual(MobileNetworkInterfaces.kind(forInterfaceNamed: "utun3"), .vpn)
        XCTAssertEqual(MobileNetworkInterfaces.kind(forInterfaceNamed: "ipsec0"), .vpn)
        for hidden in ["lo0", "awdl0", "llw0", "ap1", "anpi0", "bridge100", "XHC20"] {
            XCTAssertNil(MobileNetworkInterfaces.kind(forInterfaceNamed: hidden), hidden)
        }
    }

    /// Link-local IPv6 is on every interface and says nothing; privacy temporaries would list
    /// one interface half a dozen times; and the list has a ceiling whatever the kernel returns.
    func testInterfacesDropLinkLocalDeduplicateAndStayBounded() {
        typealias Address = MobileNetworkInterfaces.Address
        var addresses: [Address] = [
            Address(interfaceName: "pdp_ip0", family: .ipv4, value: "10.212.44.7"),
            Address(interfaceName: "utun4", family: .ipv6, value: "fd7a:115c:a1e0::1"),
            Address(interfaceName: "en0", family: .ipv6, value: "fe80::1c2f"),
            Address(interfaceName: "en0", family: .ipv4, value: "192.168.1.23"),
            Address(interfaceName: "en0", family: .ipv4, value: "192.168.1.23"),
            Address(interfaceName: "lo0", family: .ipv4, value: "127.0.0.1"),
        ]
        for index in 0..<5 {
            addresses.append(
                Address(interfaceName: "en0", family: .ipv6, value: "fd12::\(index)")
            )
        }
        for index in 0..<10 {
            addresses.append(
                Address(interfaceName: "utun\(10 + index)", family: .ipv4, value: "10.0.\(index).1")
            )
        }

        let interfaces = MobileNetworkInterfaces.interfaces(from: addresses)

        XCTAssertEqual(interfaces.count, MobileNetworkInterfaces.maximumInterfaces)
        XCTAssertEqual(interfaces.prefix(3).map(\.name), ["en0", "pdp_ip0", "utun10"])
        XCTAssertEqual(interfaces[0].ipv4, ["192.168.1.23"])
        XCTAssertEqual(
            interfaces[0].ipv6,
            ["fd12::0", "fd12::1", "fd12::2"],
            "three IPv6 addresses, none of them link-local"
        )
        XCTAssertFalse(interfaces.contains { $0.name == "lo0" })
    }

    /// The accumulator is allowed to retain only a bounded number from one kind, but an
    /// alphabetically earlier interface discovered late must still displace the worst retained
    /// candidate so iteration order cannot change the report.
    func testInterfaceCandidateBoundKeepsThePreferredNames() {
        typealias Address = MobileNetworkInterfaces.Address
        let addresses = (0..<20).reversed().map { index in
            Address(interfaceName: "utun\(index)", family: .ipv4, value: "10.0.\(index).1")
        }

        XCTAssertEqual(
            MobileNetworkInterfaces.interfaces(from: addresses).map(\.name),
            ["utun0", "utun1", "utun10", "utun11", "utun12", "utun13"]
        )
    }

    /// The real walk runs on a simulator too: it must return without error and never a
    /// loopback or link-local entry, which is what the panel would otherwise be full of.
    func testTheLiveInterfaceWalkIsBoundedAndHidesLoopback() {
        let interfaces = MobileNetworkInterfaces.current()

        XCTAssertLessThanOrEqual(interfaces.count, MobileNetworkInterfaces.maximumInterfaces)
        XCTAssertFalse(interfaces.contains { $0.name.hasPrefix("lo") })
        for interface in interfaces {
            XCTAssertLessThanOrEqual(
                interface.ipv6.count,
                MobileNetworkInterfaces.maximumAddressesPerFamily
            )
            XCTAssertFalse(interface.ipv6.contains { $0.hasPrefix("fe80:") }, interface.name)
        }
    }

    // MARK: - The fixture

    func testTheDemoReportIsCompleteAndDeterministic() throws {
        let host = Fixture.host()
        let record = MobileConnectionRecord.demo(
            hostID: host.id,
            baseURL: Fixture.tailnetURL,
            kind: .tailscale,
            now: Fixture.now
        )
        let first = MobileConnectionReport.demo(host: host, record: record)
        let second = MobileConnectionReport.demo(host: host, record: record)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.sections.map(\.id), ["mac", "request", "routes", "phone"])
        XCTAssertEqual(try XCTUnwrap(row("protocol", in: "request", of: first)).value, "HTTP/2")
        XCTAssertEqual(try XCTUnwrap(row("network", in: "phone", of: first)).value, "Wi-Fi")
    }

    // MARK: - The title

    /// Wrapping the title in the button that opens the panel must not move it: the morph's
    /// geometry invariants were bought for the bare title, and the button is asked to add a tap
    /// and nothing else.
    func testTheTappableTitleKeepsTheBareTitlesGeometry() throws {
        let bare = try hostedTitleLabel(tappable: false)
        let tappable = try hostedTitleLabel(tappable: true)

        XCTAssertGreaterThan(bare.bounds.width, 0)
        XCTAssertEqual(bare.bounds.width, tappable.bounds.width, accuracy: 0.5)
        XCTAssertEqual(bare.bounds.height, tappable.bounds.height, accuracy: 0.5)
    }

    private struct TitleHost: View {
        let tappable: Bool

        var body: some View {
            NavigationStack {
                Color.clear
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {} label: { Image(systemName: "chevron.left") }
                        }
                        ToolbarItem(placement: .principal) {
                            if tappable {
                                MobileConnectionStatusButton(
                                    title: "Licensing strategy",
                                    status: "Connected · Tailscale",
                                    statusColor: .green
                                )
                            } else {
                                MobileConnectionNavigationTitle(
                                    title: "Licensing strategy",
                                    status: "Connected · Tailscale",
                                    statusColor: .green
                                )
                            }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {} label: { Image(systemName: "ellipsis") }
                        }
                    }
            }
        }
    }

    private var hostedWindows: [UIWindow] = []

    private func hostedTitleLabel(tappable: Bool) throws -> MobileMorphingTitleLabel {
        let root = UIHostingController(
            rootView: TitleHost(tappable: tappable).environmentObject(RemoteAppModel())
        )
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = root
        window.makeKeyAndVisible()
        hostedWindows.append(window)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        window.layoutIfNeeded()
        let labels = allLabels(in: window)
        return try XCTUnwrap(
            labels.first { $0.stringValue == "Licensing strategy" },
            "no title label in the hosted bar"
        )
    }

    private func allLabels(in view: UIView) -> [MobileMorphingTitleLabel] {
        let current = (view as? MobileMorphingTitleLabel).map { [$0] } ?? []
        return current + view.subviews.flatMap { allLabels(in: $0) }
    }
}
