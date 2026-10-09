import Crypto
import Foundation
import ThreadingRemoteKit
@testable import CoreSlice

@main
struct NativeRemoteContract {
    static func main() throws {
        let certificate = Data("contract certificate".utf8)
        let fingerprint = RemoteHostFingerprint(certificateDER: certificate)
        let pins = RemoteHostPinSet(current: RemoteHostPin(fingerprint: fingerprint))
        precondition(RemoteCertificatePinning.evaluate(certificateDER: nil, against: nil) == .notPinned)
        precondition(RemoteCertificatePinning.evaluate(certificateDER: nil, against: pins) == .rejectedFingerprintMismatch)
        precondition(RemoteCertificatePinning.evaluate(certificateDER: certificate, against: pins) == .accepted)
        precondition(RemoteCertificatePinning.evaluate(certificateDER: Data("other".utf8), against: pins) == .rejectedFingerprintMismatch)
        precondition(RemoteHostPin(pairingCode: fingerprint.pairingCode)?.matches(certificateDER: certificate) == true)

        let phone = P256.KeyAgreement.PrivateKey()
        let secret = Data("secret 日本語".utf8)
        let envelope = try RemoteSecretEnvelope.seal(secret, to: phone.publicKey)
        let opened = try RemoteSecretEnvelope.open(envelope, as: phone.publicKey) {
            try phone.sharedSecretFromKeyAgreement(with: $0)
        }
        precondition(opened == secret)
        let other = P256.KeyAgreement.PrivateKey()
        do {
            _ = try RemoteSecretEnvelope.open(envelope, as: other.publicKey) {
                try other.sharedSecretFromKeyAgreement(with: $0)
            }
            preconditionFailure("wrong recipient decrypted the envelope")
        } catch RemoteSecretEnvelope.Failure.wrongRecipient { }
        var bytes = envelope.sealed
        bytes[bytes.count - 1] ^= 1
        let tampered = RemoteSecretApproval.Envelope(version: envelope.version, recipient: envelope.recipient,
            ephemeral: envelope.ephemeral, sealed: bytes)
        do {
            _ = try RemoteSecretEnvelope.open(tampered, as: phone.publicKey) {
                try phone.sharedSecretFromKeyAgreement(with: $0)
            }
            preconditionFailure("tampered ciphertext was accepted")
        } catch { }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("remote-contract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = Data(String(repeating: "日本語 🧵 café\n", count: 4096).utf8)
        try original.write(to: root.appendingPathComponent("original"))
        guard let gzip = GzipWriter.compress(original) else { preconditionFailure("compressible gzip declined") }
        precondition(gzip.count < original.count)
        try gzip.write(to: root.appendingPathComponent("body.gz"))
        let archive = try ZipArchiveWriter.archive([.init(path: "日本語.txt", data: original)], modified: Date(timeIntervalSince1970: 1_700_000_000))
        precondition(archive.count < original.count)
        try archive.write(to: root.appendingPathComponent("body.zip"))
        let result = try BoundedChildProcess.run(executable: "/usr/bin/python3", arguments: ["-c", """
        import gzip, pathlib, sys, zipfile
        root = pathlib.Path(sys.argv[1])
        original = (root / 'original').read_bytes()
        assert gzip.decompress((root / 'body.gz').read_bytes()) == original
        with zipfile.ZipFile(root / 'body.zip') as archive:
            assert archive.read('日本語.txt') == original
            assert archive.getinfo('日本語.txt').compress_type == zipfile.ZIP_DEFLATED
        print('validated independent gzip and ZIP readers')
        """, root.path], timeout: 5, maximumOutputBytes: 2048)
        precondition(result.termination == .exited(0), String(decoding: result.output, as: UTF8.self))
        print("PASS Linux remote contracts: fail-closed certificate pins, encrypted recipient/tamper checks, and independently decoded Unicode ZIP/gzip")
    }
}
