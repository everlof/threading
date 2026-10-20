import CryptoKit
import Foundation

guard CommandLine.arguments.count == 4,
      let publicKey = Data(base64Encoded: CommandLine.arguments[1]),
      let signature = Data(base64Encoded: CommandLine.arguments[3]),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
      let payload = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])),
      key.isValidSignature(signature, for: payload) else {
    fputs("signature does not match the app's SUPublicEDKey\n", stderr)
    exit(1)
}
