import Foundation
import XCTest
@testable import Threading

/// Threading ships for Apple silicon only (`docs/architecture/releasing.md`, "Apple silicon
/// only"). The setting that makes it so — `ARCHS[sdk=macosx*] = arm64` at the project level —
/// is one line in the most contended file in the repository, and a build that loses it still
/// runs on every machine that builds it. This reads the Mach-O headers of the executables the
/// host app was built with and refuses a second slice, so losing the setting fails `fast`
/// rather than adding 20 MB to the next release.
///
/// Only the targets this project builds are checked. Prebuilt packages (WebRTC, Sparkle) stay
/// universal in a local build and are thinned by `scripts/thin_app_architectures.sh` on the
/// way to a release, where `release.sh` verifies every binary.
final class ReleaseArchitectureTests: XCTestCase {
    func testTheAppAndItsHelpersAreBuiltForAppleSiliconOnly() throws {
        let contents = Bundle.main.bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let helpers = contents.appendingPathComponent("Helpers", isDirectory: true)
        var executables = [try XCTUnwrap(Bundle.main.executableURL)]
        executables += try FileManager.default.contentsOfDirectory(
            at: helpers,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(
            executables.contains { $0.lastPathComponent == "scc" },
            "the bundled scc helper is part of the product and is checked with it"
        )

        for executable in executables {
            XCTAssertEqual(
                try MachOHeader.architectures(at: executable),
                [.arm64],
                "\(executable.lastPathComponent) must carry exactly one arm64 slice"
            )
        }
    }
}

// MARK: - Mach-O header reading

/// Enough of the Mach-O and fat-header layout to name the slices of a file without `lipo`.
/// The CPU-type constants are literals because `<mach/machine.h>` defines them as macros
/// with arithmetic, which Swift does not import.
private enum MachOHeader {
    enum Architecture: Equatable, CustomStringConvertible {
        case arm64
        case x86_64
        case other(Int32)

        init(cpuType: Int32) {
            switch cpuType {
            case Layout.cpuTypeARM64: self = .arm64
            case Layout.cpuTypeX86_64: self = .x86_64
            default: self = .other(cpuType)
            }
        }

        var description: String {
            switch self {
            case .arm64: return "arm64"
            case .x86_64: return "x86_64"
            case let .other(type): return "cputype \(type)"
            }
        }
    }

    enum Layout {
        static let fatMagic: UInt32 = 0xCAFE_BABE
        static let machMagic64: UInt32 = 0xFEED_FACF
        static let cpuTypeARM64: Int32 = 0x0100_000C
        static let cpuTypeX86_64: Int32 = 0x0100_0007
        /// `struct fat_header` is two big-endian words; each `struct fat_arch` is five.
        static let fatHeaderSize = 8
        static let fatArchSize = 20
        /// A fat header plus every `fat_arch` entry a bundle binary could carry fits well
        /// inside one page; the thin header needs only its first eight bytes.
        static let bytesToRead = 4096
    }

    enum Problem: Error {
        case unrecognisedMagic(UInt32)
        case truncated
    }

    static func architectures(at url: URL) throws -> [Architecture] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: Layout.bytesToRead) ?? Data()
        guard head.count >= Layout.fatHeaderSize else { throw Problem.truncated }

        let magic = head.withUnsafeBytes { $0.load(as: UInt32.self) }
        if UInt32(bigEndian: magic) == Layout.fatMagic {
            let count = Int(UInt32(bigEndian: head.word(at: 4)))
            let needed = Layout.fatHeaderSize + count * Layout.fatArchSize
            guard head.count >= needed else { throw Problem.truncated }
            return (0..<count).map { index in
                let offset = Layout.fatHeaderSize + index * Layout.fatArchSize
                return Architecture(cpuType: Int32(bitPattern: UInt32(bigEndian: head.word(at: offset))))
            }
        }
        if UInt32(littleEndian: magic) == Layout.machMagic64 {
            return [Architecture(cpuType: Int32(bitPattern: UInt32(littleEndian: head.word(at: 4))))]
        }
        throw Problem.unrecognisedMagic(magic)
    }
}

private extension Data {
    /// The raw 32-bit word at `offset`, in file order; the caller applies the endianness.
    func word(at offset: Int) -> UInt32 {
        withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
    }
}
