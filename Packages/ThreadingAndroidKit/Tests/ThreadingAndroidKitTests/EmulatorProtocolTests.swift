import CryptoKit
import XCTest
@testable import ThreadingAndroidKit

final class EmulatorProtocolTests: XCTestCase {
    func testTouchEventEncodesAtTheProtoFieldNumbers() throws {
        let bytes = EmulatorRequests.touchEvent([EmulatorTouch(x: 540, y: 1200, identifier: 1, pressure: 0x400)])
        // field 1 (touches), length 11: x=540 (08 9c 04), y=1200 (10 b0 09), id=1 (18 01), pressure=1024 (20 80 08)
        XCTAssertEqual(bytes, [0x0A, 0x0B, 0x08, 0x9C, 0x04, 0x10, 0xB0, 0x09, 0x18, 0x01, 0x20, 0x80, 0x08])
        let lifted = EmulatorRequests.touchEvent([EmulatorTouch(x: 0, y: 0, identifier: 1, pressure: 0)])
        XCTAssertEqual(lifted, [0x0A, 0x02, 0x18, 0x01], "proto3 omits zero fields; pressure 0 lifts the contact")
    }

    func testNegativeInt32IsSignExtendedToTenBytes() throws {
        var writer = ProtobufWriter()
        writer.int32(1, -1)
        XCTAssertEqual(writer.bytes, [0x08, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01])
        XCTAssertEqual(try ProtobufReader.fields(writer.bytes).first?.value.int32, -1)
    }

    func testKeyAndTextRequests() {
        XCTAssertEqual(EmulatorRequests.keyPress("GoHome"), [0x10, 0x02, 0x22, 0x06] + Array("GoHome".utf8))
        XCTAssertEqual(EmulatorRequests.text("hi"), [0x2A, 0x02, 0x68, 0x69])
    }

    func testScreenshotRequestCarriesTheMMAPTransport() throws {
        let request = EmulatorScreenshotRequest(format: .rgba8888, width: 540, height: 1200, mmapHandle: "file:///tmp/x")
        let fields = try ProtobufReader.fields(request.encoded())
        XCTAssertEqual(fields.map(\.field), [1, 3, 4, 6])
        let transport = try ProtobufReader.fields(fields[3].value.bytes)
        XCTAssertEqual(transport[0].value.uint64, 1)
        XCTAssertEqual(transport[1].value.string, "file:///tmp/x")
    }

    func testDecodesAnImageWithItsRotation() throws {
        var rotation = ProtobufWriter()
        rotation.varint(1, 1)
        var format = ProtobufWriter()
        format.varint(1, 1)
        format.message(2, rotation)
        format.varint(3, 2400)
        format.varint(4, 1080)
        var image = ProtobufWriter()
        image.message(1, format)
        image.lengthDelimited(4, [1, 2, 3, 4])
        image.varint(5, 7)
        image.varint(6, 123_456)
        let decoded = try EmulatorImage.decode(image.bytes)
        XCTAssertEqual(decoded, EmulatorImage(
            format: .rgba8888, width: 2400, height: 1080, rotation: .landscape,
            pixels: [1, 2, 3, 4], sequence: 7, timestampMicroseconds: 123_456
        ))
    }

    func testRotationRequestPacksThreeFloats() throws {
        let fields = try ProtobufReader.fields(EmulatorRequests.rotation(x: 0, y: 0, z: -90))
        XCTAssertEqual(fields[0].value.uint64, 1)
        let parameters = try ProtobufReader.fields(fields[1].value.bytes)
        XCTAssertEqual(parameters[0].value.bytes.count, 12)
    }

    func testTokenVerifiesAgainstThePublishedJWK() throws {
        let signer = EmulatorTokenSigner()
        let token = try signer.token(
            issuer: EmulatorTokenSigner.audienceScopedIssuer, methods: [.streamScreenshot, .sendTouch],
            now: Date(timeIntervalSince1970: 1_000)
        )
        let parts = token.split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 3)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(Base64URL.decode(parts[1]))) as? [String: Any])
        XCTAssertEqual(payload["iss"] as? String, "gradle-utp-emulator-control")
        XCTAssertEqual(payload["aud"] as? [String], [
            "/android.emulation.control.EmulatorController/streamScreenshot",
            "/android.emulation.control.EmulatorController/sendTouch",
        ])
        XCTAssertEqual(payload["exp"] as? Int, 1_000 + 3_600)

        let set = try XCTUnwrap(JSONSerialization.jsonObject(with: signer.publicJWK()) as? [String: [[String: String]]])
        let jwk = try XCTUnwrap(set["keys"]?.first)
        XCTAssertEqual(jwk["kid"], signer.keyID)
        let point = Data([0x04]) + (try XCTUnwrap(Base64URL.decode(jwk["x"]!))) + (try XCTUnwrap(Base64URL.decode(jwk["y"]!)))
        let key = try P256.Signing.PublicKey(x963Representation: point)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: XCTUnwrap(Base64URL.decode(parts[2])))
        XCTAssertTrue(key.isValidSignature(signature, for: Data((parts[0] + "." + parts[1]).utf8)))
    }

    func testAllowlistGrantsOnlyThreadingsMethodsAndLeavesNothingUnprotected() throws {
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: EmulatorTokenSigner.allowlist()) as? [String: Any])
        XCTAssertEqual((document["unprotected"] as? [String])?.count, 0)
        let entry = try XCTUnwrap((document["allowlist"] as? [[String: Any]])?.first)
        XCTAssertEqual(entry["iss"] as? String, "threading")
        XCTAssertEqual((entry["allowed"] as? [String])?.count, EmulatorControlMethod.allCases.count)
    }

    func testJWKSetLookup() {
        XCTAssertTrue(EmulatorJWKSet.contains(keyID: "k1", in: Data(#"{"keys":[{"kid":"k0"},{"kid":"k1"}]}"#.utf8)))
        XCTAssertFalse(EmulatorJWKSet.contains(keyID: "k2", in: Data(#"{"keys":[{"kid":"k0"}]}"#.utf8)))
        XCTAssertFalse(EmulatorJWKSet.contains(keyID: "k2", in: Data("not json".utf8)))
    }
}
