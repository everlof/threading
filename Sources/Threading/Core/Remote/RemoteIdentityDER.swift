import Foundation

/// A DER writer holding exactly the productions a self-signed P-256 certificate and a PKCS#12
/// container need, and nothing else.
///
/// Hand-written for the reason the ES256 JWT in `RemoteNotificationService` is: the alternative is
/// `swift-certificates`, which has no PKCS#12 writer and pulls `swift-asn1` and a BoringSSL-backed
/// `swift-crypto` into a repository that vendors every dependency. The surface here is small,
/// fixed, and pinned to known answers in `RemoteIdentityCryptoTests`; it is a writer only, because
/// nothing in this app has to parse somebody else's ASN.1.
enum RemoteDER {

    enum Tag {
        static let integer: UInt8 = 0x02
        static let bitString: UInt8 = 0x03
        static let octetString: UInt8 = 0x04
        static let null: UInt8 = 0x05
        static let objectIdentifier: UInt8 = 0x06
        static let utf8String: UInt8 = 0x0C
        static let ia5String: UInt8 = 0x16
        static let utcTime: UInt8 = 0x17
        static let sequence: UInt8 = 0x30
        static let set: UInt8 = 0x31
        /// `[n]` constructed, which is how an EXPLICIT context-specific element is written.
        static func contextConstructed(_ number: UInt8) -> UInt8 { 0xA0 | number }
        /// `[n]` primitive, which is how an IMPLICIT one is.
        static func contextPrimitive(_ number: UInt8) -> UInt8 { 0x80 | number }
    }

    /// The only place a length is written. DER's short form is one byte below 128; the long form
    /// is `0x80 | byteCount` followed by the count in minimal big-endian bytes.
    static func length(_ count: Int) -> [UInt8] {
        if count < 0x80 { return [UInt8(count)] }
        var bytes: [UInt8] = []
        var remaining = count
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    static func encode(tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        [tag] + length(content.count) + content
    }

    static func sequence(_ items: [[UInt8]]) -> [UInt8] {
        encode(tag: Tag.sequence, items.flatMap { $0 })
    }

    static func set(_ items: [[UInt8]]) -> [UInt8] {
        encode(tag: Tag.set, items.flatMap { $0 })
    }

    /// An unsigned big-endian value as a DER INTEGER: leading zero bytes are not written, and a
    /// value whose top bit is set gets one back so it cannot read as negative.
    static func integer(bytes: [UInt8]) -> [UInt8] {
        var trimmed = bytes
        while trimmed.count > 1, trimmed[0] == 0 { trimmed.removeFirst() }
        if trimmed.isEmpty { trimmed = [0] }
        if trimmed[0] & 0x80 != 0 { trimmed.insert(0, at: 0) }
        return encode(tag: Tag.integer, trimmed)
    }

    static func integer(_ value: Int) -> [UInt8] {
        precondition(value >= 0, "Every INTEGER this writer produces is non-negative")
        var bytes: [UInt8] = []
        var remaining = value
        repeat {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        } while remaining > 0
        return integer(bytes: bytes)
    }

    static func bitString(_ bytes: [UInt8], unusedBits: UInt8 = 0) -> [UInt8] {
        encode(tag: Tag.bitString, [unusedBits] + bytes)
    }

    static func octetString(_ bytes: [UInt8]) -> [UInt8] {
        encode(tag: Tag.octetString, bytes)
    }

    static func null() -> [UInt8] { [Tag.null, 0x00] }

    /// The first two arcs share a byte (`40 * first + second`); every arc after that is base 128,
    /// most significant group first, with the continuation bit set on all but the last byte.
    static func objectIdentifier(_ arcs: [UInt]) -> [UInt8] {
        precondition(arcs.count >= 2, "An object identifier has at least two arcs")
        var content: [UInt8] = [UInt8(arcs[0] * 40 + arcs[1])]
        for arc in arcs.dropFirst(2) {
            var group: [UInt8] = [UInt8(arc & 0x7F)]
            var remaining = arc >> 7
            while remaining > 0 {
                group.insert(UInt8((remaining & 0x7F) | 0x80), at: 0)
                remaining >>= 7
            }
            content.append(contentsOf: group)
        }
        return encode(tag: Tag.objectIdentifier, content)
    }

    static func utf8String(_ value: String) -> [UInt8] {
        encode(tag: Tag.utf8String, Array(value.utf8))
    }

    static func ia5String(_ value: String) -> [UInt8] {
        encode(tag: Tag.ia5String, Array(value.utf8))
    }

    /// `YYMMDDHHMMSSZ`. Valid until 2049; a certificate minted after that needs GeneralizedTime,
    /// which is why the validity window below is checked rather than assumed.
    static func utcTime(_ date: Date) -> [UInt8] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        return encode(tag: Tag.utcTime, Array(formatter.string(from: date).utf8))
    }

    /// `[number] EXPLICIT`, which wraps a complete encoding rather than replacing its tag.
    static func explicit(_ number: UInt8, _ content: [UInt8]) -> [UInt8] {
        encode(tag: Tag.contextConstructed(number), content)
    }

    /// `[number] IMPLICIT` over a primitive value, which is how `GeneralName` writes its choices.
    static func implicitPrimitive(_ number: UInt8, _ content: [UInt8]) -> [UInt8] {
        encode(tag: Tag.contextPrimitive(number), content)
    }
}

/// The object identifiers this writer names. Values, not opinions: each is from the RFC or
/// standard that defines it.
enum RemoteDEROID {
    /// `2.5.4.3` — common name.
    static let commonName: [UInt] = [2, 5, 4, 3]
    /// `2.5.4.11` — organizational unit, which carries this Mac's own id.
    static let organizationalUnit: [UInt] = [2, 5, 4, 11]
    /// `1.2.840.10045.2.1` — id-ecPublicKey.
    static let ecPublicKey: [UInt] = [1, 2, 840, 10045, 2, 1]
    /// `1.2.840.10045.3.1.7` — prime256v1, which is P-256.
    static let prime256v1: [UInt] = [1, 2, 840, 10045, 3, 1, 7]
    /// `1.2.840.10045.4.3.2` — ecdsa-with-SHA256. **It takes no parameters field at all**, which
    /// is the one thing about this encoding that is easy to get wrong: writing NULL there is what
    /// makes a certificate that parses everywhere except where it matters.
    static let ecdsaWithSHA256: [UInt] = [1, 2, 840, 10045, 4, 3, 2]
    /// `2.5.29.15` — keyUsage.
    static let keyUsage: [UInt] = [2, 5, 29, 15]
    /// `2.5.29.17` — subjectAltName.
    static let subjectAltName: [UInt] = [2, 5, 29, 17]
    /// `2.5.29.19` — basicConstraints.
    static let basicConstraints: [UInt] = [2, 5, 29, 19]
    /// `1.2.840.113549.1.7.1` — PKCS#7 data.
    static let pkcs7Data: [UInt] = [1, 2, 840, 113549, 1, 7, 1]
    /// `1.2.840.113549.1.12.10.1.2` — PKCS#12 pkcs8ShroudedKeyBag.
    static let pkcs8ShroudedKeyBag: [UInt] = [1, 2, 840, 113549, 1, 12, 10, 1, 2]
    /// `1.2.840.113549.1.12.10.1.3` — PKCS#12 certBag.
    static let certBag: [UInt] = [1, 2, 840, 113549, 1, 12, 10, 1, 3]
    /// `1.2.840.113549.1.9.22.1` — x509Certificate, the certBag's own content type.
    static let x509Certificate: [UInt] = [1, 2, 840, 113549, 1, 9, 22, 1]
    /// `1.2.840.113549.1.9.21` — localKeyId, the attribute that pairs the two bags.
    static let localKeyID: [UInt] = [1, 2, 840, 113549, 1, 9, 21]
    /// `1.2.840.113549.1.5.13` — PBES2.
    static let pbes2: [UInt] = [1, 2, 840, 113549, 1, 5, 13]
    /// `1.2.840.113549.1.5.12` — PBKDF2.
    static let pbkdf2: [UInt] = [1, 2, 840, 113549, 1, 5, 12]
    /// `1.2.840.113549.2.9` — hmacWithSHA256, the PBKDF2 pseudorandom function.
    static let hmacWithSHA256: [UInt] = [1, 2, 840, 113549, 2, 9]
    /// `2.16.840.1.101.3.4.1.42` — aes256-CBC.
    static let aes256CBC: [UInt] = [2, 16, 840, 1, 101, 3, 4, 1, 42]
    /// `1.3.14.3.2.26` — SHA-1, which PKCS#12's MacData is defined in terms of.
    static let sha1: [UInt] = [1, 3, 14, 3, 2, 26]
    /// `1.2.840.113549.1.9.20` — friendlyName.
    static let friendlyName: [UInt] = [1, 2, 840, 113549, 1, 9, 20]
}
