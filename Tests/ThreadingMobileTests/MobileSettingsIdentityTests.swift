import Foundation
import ThreadingRemoteKit
import XCTest
@testable import ThreadingMobile

/// The identity code, where a person looks at a paired Mac after the pairing.
///
/// It used to be shown once, on the confirmation screen, and once more beside the Mac in a
/// chooser that no longer exists. The comparison it exists for is not a one-time one: the phone
/// compares this certificate on every connection, and the point of printing the code is that a
/// person can check the same thing by eye whenever they want to, against the Mac's own settings
/// page. So it belongs somewhere durable, and what is asserted here is which Macs appear, what
/// each is called, and that the code shown is the one this phone actually pins.
final class MobileSettingsIdentityTests: XCTestCase {

    private static let bearer = String(repeating: "a", count: 43)
    private static let certificate = RemoteHostFingerprint(
        certificateDER: Data("this Mac's certificate".utf8)
    )
    private static let successor = RemoteHostFingerprint(
        certificateDER: Data("the certificate this Mac will present next".utf8)
    )

    // MARK: - The code

    func testAPairedMacPrintsTheCodeItsCertificateHas() throws {
        let host = try pairedHost(pinned: Self.certificate)
        let rows = PairedMacPresentation.rows(hosts: [host], activeHostID: host.id)

        let mac = try XCTUnwrap(rows.first)
        XCTAssertEqual(mac.identityCode, Self.certificate.pairingCode)
        XCTAssertEqual(
            mac.identityCode?.count,
            RemoteHostPinningDefaults.pairingCodeCharacterCount,
            "the code is not the 26 characters the Mac's own settings page prints"
        )
        XCTAssertEqual(mac.title, "Studio Mac")
        XCTAssertTrue(mac.isActive)
    }

    /// The stored fingerprint leads, because it is the one that follows a rotation. A phone that
    /// scanned a code last year and has connected since is holding the certificate the Mac is
    /// presenting *now*, and that is the code beside which the Mac's page is compared.
    func testARotatedCertificatePrintsTheCodeInUseRatherThanTheScannedOne() throws {
        let host = try pairedHost(scanned: Self.certificate, pinned: Self.successor)
        let mac = try XCTUnwrap(
            PairedMacPresentation.rows(hosts: [host], activeHostID: nil).first
        )
        XCTAssertEqual(mac.identityCode, Self.successor.pairingCode)
        XCTAssertNotEqual(mac.identityCode, Self.certificate.pairingCode)
    }

    /// A record that has only ever seen the QR code still has 128 bits to show.
    func testARecordHoldingOnlyTheScannedCodeStillPrintsIt() throws {
        let host = try pairedHost(scanned: Self.certificate)
        let mac = try XCTUnwrap(
            PairedMacPresentation.rows(hosts: [host], activeHostID: nil).first
        )
        XCTAssertEqual(mac.identityCode, Self.certificate.pairingCode)
    }

    /// An older pairing has never been given a certificate to pin, and the row says nothing
    /// rather than inventing a code to show.
    func testAMacWithNothingPinnedPrintsNoCode() throws {
        let host = try pairedHost()
        let mac = try XCTUnwrap(
            PairedMacPresentation.rows(hosts: [host], activeHostID: nil).first
        )
        XCTAssertNil(mac.identityCode)
    }

    // MARK: - The list

    /// Several Macs, in the order the store holds them, with the connected one marked rather
    /// than moved: a row that changes place when you connect is a row you have to find again.
    func testEveryPairedMacAppearsAndOnlyTheActiveOneIsMarked() throws {
        let first = try pairedHost(id: "mac-1", name: "Studio Mac", pinned: Self.certificate)
        let second = try pairedHost(id: "mac-2", name: "Laptop", pinned: Self.successor)
        let rows = PairedMacPresentation.rows(hosts: [first, second], activeHostID: "mac-2")

        XCTAssertEqual(rows.map(\.id), ["mac-1", "mac-2"])
        XCTAssertEqual(rows.map(\.isActive), [false, true])
        XCTAssertEqual(
            rows.map(\.identityCode),
            [Self.certificate.pairingCode, Self.successor.pairingCode],
            "two Macs, and each row carries its own Mac's code"
        )
    }

    /// A one-chat capability is not a Mac of yours, and the section says so in the same words
    /// the Mac chooser uses rather than inventing a second spelling.
    func testASharedChatIsLabelledAsOneRatherThanAsYourMac() throws {
        var host = try pairedHost(pinned: Self.certificate)
        host = PairedRemoteHost(
            id: "mac-1:share:chat",
            hostID: "mac-1",
            shareID: "chat",
            scope: "session",
            name: host.name,
            link: host.link,
            lastConnectedAt: Date()
        )
        let mac = try XCTUnwrap(
            PairedMacPresentation.rows(hosts: [host], activeHostID: nil).first
        )
        XCTAssertEqual(mac.title, host.menuTitle)
        XCTAssertNotEqual(mac.title, host.name, "a shared chat read as a Mac you own")
    }

    /// Nothing paired is no section at all, which the settings screen decides from this list.
    func testNoPairedMacProducesNoRows() {
        XCTAssertTrue(PairedMacPresentation.rows(hosts: [], activeHostID: nil).isEmpty)
    }

    // MARK: - Fixture

    private func pairedHost(
        id: String = "mac-1",
        name: String = "Studio Mac",
        scanned: RemoteHostFingerprint? = nil,
        pinned: RemoteHostFingerprint? = nil
    ) throws -> PairedRemoteHost {
        let link = try XCTUnwrap(RemoteConnectionLink(
            baseURL: try XCTUnwrap(URL(string: "https://192.168.1.42:8760/")),
            token: Self.bearer,
            pinnedFingerprintCode: scanned?.pairingCode
        ))
        return PairedRemoteHost(
            id: id,
            hostID: id,
            shareID: "my-devices",
            scope: "all",
            name: name,
            link: link,
            lastConnectedAt: Date(),
            connectionPolicy: .privateOnly,
            pinnedFingerprint: pinned?.hex
        )
    }
}
