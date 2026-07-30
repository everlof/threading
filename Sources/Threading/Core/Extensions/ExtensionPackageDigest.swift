import CryptoKit
import Foundation

/// A content hash over every file in an extension package.
///
/// It exists to answer one question exactly: *is this the same package I showed the user?*
/// `ExtensionUpdatePlan` compares manifests, which is what the capability delta is computed
/// from — but a source directory can change its executable while leaving its manifest
/// untouched, and a re-check that only reads the manifest would call that unchanged. The
/// capability model still bounds what the swapped code could do, so this is not a privilege
/// escalation; it is the difference between the re-check meaning what it says and meaning
/// something narrower.
///
/// It is also the primitive any later provenance work needs: a signature signs a digest.
enum ExtensionPackageDigest {
    /// A hexadecimal SHA-256 over the package's files, or nil if it could not be read.
    ///
    /// **Paths are hashed alongside contents, in sorted order.** Hashing contents alone would
    /// give the same digest to a package whose files had been renamed or moved between
    /// directories, and a stable order is what makes the digest reproducible at all — directory
    /// enumeration order is not something to depend on.
    static func compute(
        at root: URL,
        fileManager: FileManager = .default
    ) -> String? {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else {
            return nil
        }

        var entries: [(path: String, url: URL)] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else {
                continue
            }
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(root.path + "/") else { continue }
            entries.append((String(resolved.path.dropFirst(root.path.count + 1)), resolved))
        }
        entries.sort { $0.path < $1.path }

        var hasher = SHA256()
        for entry in entries {
            guard let handle = try? FileHandle(forReadingFrom: entry.url) else { return nil }
            defer { try? handle.close() }

            // The path length is hashed before the path so that two different splits of the
            // same concatenated bytes cannot collide — "ab" + "c" and "a" + "bc" are otherwise
            // the same stream.
            let path = Data(entry.path.utf8)
            hasher.update(data: withUnsafeBytes(of: UInt64(path.count).bigEndian) { Data($0) })
            hasher.update(data: path)

            // Streamed rather than read whole: a package may be up to 256 MiB and there is no
            // reason to hold any of it in memory.
            do {
                while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                    hasher.update(data: chunk)
                }
            } catch {
                // A digest of a readable prefix is not a digest of the package. Returning nil
                // makes callers refuse the operation instead of blessing incomplete evidence.
                return nil
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
