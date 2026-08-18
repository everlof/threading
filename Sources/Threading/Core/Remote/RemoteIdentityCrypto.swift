import CryptoKit
import Foundation

/// AES-256 in CBC mode, encryption only.
///
/// Hand-written because CryptoKit exposes no block cipher and this container needs one: the only
/// public route from a key and a certificate to a `SecIdentity` is `SecPKCS12Import`, and that
/// importer silently drops an unencrypted key bag. The tables are derived rather than typed in,
/// and the whole thing is pinned to the FIPS-197 known answer, because a transcription error in a
/// 256-entry table produces output that is wrong in a way nothing else here would notice.
///
/// Encryption only, and one use: a one-shot passphrase that is generated per import and never
/// stored. Nothing in this app decrypts anything with it.
enum RemoteAES256 {

    static let blockSize = 16
    static let keySize = 32
    private static let rounds = 14
    private static let keyWords = 8

    /// The AES S-box, derived from its definition: the multiplicative inverse in GF(2^8) put
    /// through the affine transform. Deriving it is what makes it checkable.
    private static let sbox: [UInt8] = {
        var inverse = [UInt8](repeating: 0, count: 256)
        for a in 1...255 {
            for b in 1...255 where multiply(UInt8(a), UInt8(b)) == 1 {
                inverse[a] = UInt8(b)
                break
            }
        }
        return (0...255).map { index -> UInt8 in
            let value = inverse[index]
            return value
                ^ rotateLeft(value, 1)
                ^ rotateLeft(value, 2)
                ^ rotateLeft(value, 3)
                ^ rotateLeft(value, 4)
                ^ 0x63
        }
    }()

    /// CBC with PKCS#7 padding, which is what PBES2 with an AES-CBC scheme means.
    static func encryptCBC(plaintext: Data, key: Data, iv: Data) -> Data? {
        guard key.count == keySize, iv.count == blockSize else { return nil }
        let roundKeys = expand(key: Array(key))
        var previous = Array(iv)
        var output = Data()

        var padded = Array(plaintext)
        let padding = blockSize - (padded.count % blockSize)
        padded.append(contentsOf: [UInt8](repeating: UInt8(padding), count: padding))

        for offset in stride(from: 0, to: padded.count, by: blockSize) {
            var block = Array(padded[offset..<(offset + blockSize)])
            for index in 0..<blockSize { block[index] ^= previous[index] }
            let encrypted = encryptBlock(block, roundKeys: roundKeys)
            output.append(contentsOf: encrypted)
            previous = encrypted
        }
        return output
    }

    // MARK: - Core

    private static func encryptBlock(_ input: [UInt8], roundKeys: [[UInt8]]) -> [UInt8] {
        var state = input
        addRoundKey(&state, roundKeys[0])
        for round in 1..<rounds {
            substitute(&state)
            shiftRows(&state)
            mixColumns(&state)
            addRoundKey(&state, roundKeys[round])
        }
        substitute(&state)
        shiftRows(&state)
        addRoundKey(&state, roundKeys[rounds])
        return state
    }

    private static func addRoundKey(_ state: inout [UInt8], _ roundKey: [UInt8]) {
        for index in 0..<blockSize { state[index] ^= roundKey[index] }
    }

    private static func substitute(_ state: inout [UInt8]) {
        for index in 0..<state.count { state[index] = sbox[Int(state[index])] }
    }

    /// The state is column-major: byte `r + 4c` is row `r` of column `c`.
    private static func shiftRows(_ state: inout [UInt8]) {
        var shifted = state
        for row in 1..<4 {
            for column in 0..<4 {
                shifted[row + 4 * column] = state[row + 4 * ((column + row) % 4)]
            }
        }
        state = shifted
    }

    private static func mixColumns(_ state: inout [UInt8]) {
        for column in 0..<4 {
            let base = 4 * column
            let a0 = state[base], a1 = state[base + 1], a2 = state[base + 2], a3 = state[base + 3]
            state[base] = multiply(a0, 2) ^ multiply(a1, 3) ^ a2 ^ a3
            state[base + 1] = a0 ^ multiply(a1, 2) ^ multiply(a2, 3) ^ a3
            state[base + 2] = a0 ^ a1 ^ multiply(a2, 2) ^ multiply(a3, 3)
            state[base + 3] = multiply(a0, 3) ^ a1 ^ a2 ^ multiply(a3, 2)
        }
    }

    /// AES-256: eight key words, fourteen rounds, and an extra substitution every fourth word.
    private static func expand(key: [UInt8]) -> [[UInt8]] {
        var words: [[UInt8]] = stride(from: 0, to: keySize, by: 4).map { Array(key[$0..<($0 + 4)]) }
        var rcon: UInt8 = 1
        for index in keyWords..<(4 * (rounds + 1)) {
            var temp = words[index - 1]
            if index % keyWords == 0 {
                temp = [
                    sbox[Int(temp[1])] ^ rcon,
                    sbox[Int(temp[2])],
                    sbox[Int(temp[3])],
                    sbox[Int(temp[0])],
                ]
                rcon = multiply(rcon, 2)
            } else if index % keyWords == 4 {
                temp = temp.map { sbox[Int($0)] }
            }
            words.append((0..<4).map { words[index - keyWords][$0] ^ temp[$0] })
        }
        return stride(from: 0, to: words.count, by: 4).map { Array(words[$0..<($0 + 4)].joined()) }
    }

    /// Multiplication in GF(2^8) modulo the AES polynomial `x^8 + x^4 + x^3 + x + 1`.
    private static func multiply(_ lhs: UInt8, _ rhs: UInt8) -> UInt8 {
        var a = lhs
        var b = rhs
        var product: UInt8 = 0
        while b != 0 {
            if b & 1 != 0 { product ^= a }
            let carry = a & 0x80
            a <<= 1
            if carry != 0 { a ^= 0x1B }
            b >>= 1
        }
        return product
    }

    private static func rotateLeft(_ value: UInt8, _ places: UInt8) -> UInt8 {
        (value << places) | (value >> (8 - places))
    }
}

/// PBKDF2 with HMAC-SHA256, which is the key derivation PBES2 names.
///
/// Hand-written for the same reason as the cipher above, and pinned to the RFC 7914 §11 vectors.
enum RemotePBKDF2 {

    static func derive(
        password: Data,
        salt: Data,
        iterations: Int,
        length: Int
    ) -> Data {
        let key = SymmetricKey(data: password)
        var output = Data()
        var block: UInt32 = 1
        while output.count < length {
            var input = salt
            input.append(contentsOf: withUnsafeBytes(of: block.bigEndian) { Array($0) })
            var current = Data(HMAC<SHA256>.authenticationCode(for: input, using: key))
            var accumulated = current
            for _ in 1..<max(iterations, 1) {
                current = Data(HMAC<SHA256>.authenticationCode(for: current, using: key))
                for index in 0..<accumulated.count {
                    accumulated[accumulated.startIndex + index] ^= current[current.startIndex + index]
                }
            }
            output.append(accumulated)
            block += 1
        }
        return output.prefix(length)
    }
}

/// The PKCS#12 key derivation from RFC 7292 Appendix B.2, over SHA-1.
///
/// It exists for one value: the MAC key behind `MacData`. `SecPKCS12Import` refuses a container
/// with no MacData outright, and this is the only KDF that can produce its key, so the modern
/// PBES2 machinery above cannot stand in for it.
enum RemotePKCS12KDF {

    /// SHA-1's output and block sizes, which the specification calls u and v.
    private static let digestLength = 20
    private static let blockLength = 64

    /// The identifier byte that separates the three purposes: 1 key, 2 IV, 3 MAC.
    enum Purpose: UInt8 {
        case key = 1
        case initializationVector = 2
        case mac = 3
    }

    /// The password is a BMPString: UTF-16 big endian with a two-byte terminator. That encoding
    /// is part of the derivation, not a detail of how it is stored.
    static func bmpString(_ password: String) -> Data {
        var bytes = Data()
        for scalar in Array(password.utf16) {
            bytes.append(UInt8(scalar >> 8))
            bytes.append(UInt8(scalar & 0xFF))
        }
        bytes.append(0)
        bytes.append(0)
        return bytes
    }

    static func derive(
        password: String,
        salt: Data,
        iterations: Int,
        purpose: Purpose,
        length: Int
    ) -> Data {
        let diversifier = Data(repeating: purpose.rawValue, count: blockLength)
        let expandedSalt = expand(salt)
        let expandedPassword = expand(bmpString(password))
        var buffer = expandedSalt + expandedPassword

        var output = Data()
        while output.count < length {
            var digest = Data(Insecure.SHA1.hash(data: diversifier + buffer))
            for _ in 1..<max(iterations, 1) {
                digest = Data(Insecure.SHA1.hash(data: digest))
            }
            output.append(digest)
            guard output.count < length else { break }

            // B is the digest repeated to one block, and every block of the working buffer is
            // incremented by it as a big-endian integer. This is the step that makes each
            // iteration of the outer loop produce different bytes.
            let increment = expand(digest, to: blockLength)
            var updated = Data()
            for offset in stride(from: 0, to: buffer.count, by: blockLength) {
                let block = buffer[buffer.startIndex + offset..<buffer.startIndex + offset + blockLength]
                updated.append(add(Data(block), increment))
            }
            buffer = updated
        }
        return output.prefix(length)
    }

    /// Repeats `bytes` to a whole number of blocks, which is what the specification means by
    /// concatenating copies "to a length of v * ceil(n/v)".
    private static func expand(_ bytes: Data, to length: Int? = nil) -> Data {
        guard !bytes.isEmpty else { return Data() }
        let target = length ?? (blockLength * ((bytes.count + blockLength - 1) / blockLength))
        var output = Data()
        while output.count < target {
            output.append(bytes.prefix(min(bytes.count, target - output.count)))
        }
        return output
    }

    /// `(lhs + rhs + 1) mod 2^(8 * count)`, big endian, which is the specification's B.2 step 3.
    private static func add(_ lhs: Data, _ rhs: Data) -> Data {
        var result = [UInt8](repeating: 0, count: lhs.count)
        var carry = 1
        for index in stride(from: lhs.count - 1, through: 0, by: -1) {
            let sum = Int(lhs[lhs.startIndex + index]) + Int(rhs[rhs.startIndex + index]) + carry
            result[index] = UInt8(sum & 0xFF)
            carry = sum >> 8
        }
        return Data(result)
    }
}
