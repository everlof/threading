import CryptoKit
import Foundation

/// Xcode's own name for a workspace's folder in the standard DerivedData location:
/// `<name>-<28 lowercase letters>`, the letters an MD5 of the workspace's absolute path written
/// in base 26 — the first 8 bytes as 14 letters, then the last 8 as 14 more.
///
/// It matters because the manifest is not always there. Measured on 2026-10-17: 297 of 315
/// children of `~/Library/Developer/Xcode/DerivedData` had **no `info.plist`**, 15.2 GB of `Logs`,
/// `SourcePackages`, `TestResults` and `Build` that the manifest rule refused forever — 216 of
/// them `Ordus-…`, one per path that project had been built from. The name is the other thing
/// Xcode writes, and it is exact: recomputing it from `WorkspacePath` reproduced the folder name
/// of **16 of 16** hashed manifest-bearing children on that machine (the other two were custom
/// `-derivedDataPath` names, which carry no hash). So a folder can be tied to the workspace it was
/// built for by hashing the paths that workspace could have had, with no manifest at all.
enum XcodeDerivedDataName {

    /// Letters in the hash suffix.
    static let hashLength = 28

    /// The hash suffix Xcode gives a workspace at `path`.
    static func hash(forWorkspace path: String) -> String {
        let digest = Array(Insecure.MD5.hash(data: Data(path.utf8)))
        return base26(digest[0..<8]) + base26(digest[8..<16])
    }

    /// The hash suffix of a folder Xcode named, or nil when the name is not in Xcode's shape —
    /// a custom `-derivedDataPath` such as `Threading-StallVerification`, or a shared cache.
    static func hash(inFolderName name: String) -> String? {
        guard name.count > hashLength + 1 else { return nil }

        let suffix = name.suffix(hashLength)
        let separator = name.dropLast(hashLength).last
        guard separator == "-",
              suffix.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) }) else { return nil }
        return String(suffix)
    }

    // MARK: - Private

    /// Eight bytes, big-endian, as fourteen letters most significant first.
    private static func base26(_ bytes: ArraySlice<UInt8>) -> String {
        var value = bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        var letters = [Character](repeating: "a", count: hashLength / 2)
        for index in letters.indices.reversed() {
            letters[index] = Character(UnicodeScalar(UInt8(ascii: "a") + UInt8(value % 26)))
            value /= 26
        }
        return String(letters)
    }
}
