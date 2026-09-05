import Compression
import Foundation
import XCTest

@testable import ThreadingRemoteKit

final class RemoteCatalogueRevisionTests: XCTestCase {
    func testTheEntityTagRoundTripsThroughEveryValidatorSpelling() throws {
        let revision = RemoteCatalogueRevisionDTO(epoch: "abc123", revision: 42)

        XCTAssertEqual(revision.entityTag, "\"abc123:42\"")
        XCTAssertEqual(RemoteCatalogueRevisionDTO(entityTag: "\"abc123:42\""), revision)
        XCTAssertEqual(RemoteCatalogueRevisionDTO(entityTag: "W/\"abc123:42\""), revision)
        XCTAssertEqual(RemoteCatalogueRevisionDTO(entityTag: "abc123:42"), revision)
        XCTAssertEqual(RemoteCatalogueRevisionDTO(entityTag: "  \"abc123:42\" "), revision)
    }

    func testAForeignValidatorIsNotOneOfOurs() {
        XCTAssertNil(RemoteCatalogueRevisionDTO(entityTag: "\"deadbeef\""))
        XCTAssertNil(RemoteCatalogueRevisionDTO(entityTag: "\":42\""))
        XCTAssertNil(RemoteCatalogueRevisionDTO(entityTag: "\"abc:forty\""))
        XCTAssertNil(RemoteCatalogueRevisionDTO(entityTag: ""))
    }

    /// A client may list several validators; one matching is enough. `*` matches nothing — a
    /// client that holds no catalogue must be given one — and another epoch is another Mac
    /// launch whose history the client cannot know.
    func testIfNoneMatchIsAListAndAnEpochIsPartOfTheIdentity() {
        let revision = RemoteCatalogueRevisionDTO(epoch: "abc123", revision: 7)

        XCTAssertTrue(revision.matches(ifNoneMatch: "\"abc123:7\""))
        XCTAssertTrue(revision.matches(ifNoneMatch: "\"other:1\", \"abc123:7\""))
        XCTAssertFalse(revision.matches(ifNoneMatch: "\"abc123:6\""))
        XCTAssertFalse(revision.matches(ifNoneMatch: "\"zzz999:7\""))
        XCTAssertFalse(revision.matches(ifNoneMatch: "*"))
        XCTAssertFalse(revision.matches(ifNoneMatch: nil))
    }

    func testTheRevisionRidesOnTheCatalogueAndItsDeltasAndOlderPeersDecodeWithout() throws {
        let revision = RemoteCatalogueRevisionDTO(epoch: "abc123", revision: 3)
        let me = RemoteMeDTO(
            serverProtocol: RemoteProtocolInfo(),
            share: .init(label: "owner", scope: .all, capability: .interact, expiresAt: nil),
            sessions: [],
            revision: revision
        )
        let delta = RemoteSessionsChangedDTO(revision: revision)

        let decodedMe = try JSONDecoder().decode(RemoteMeDTO.self, from: JSONEncoder().encode(me))
        let decodedDelta = try JSONDecoder().decode(
            RemoteSessionsChangedDTO.self,
            from: JSONEncoder().encode(delta)
        )
        XCTAssertEqual(decodedMe.revision, revision)
        XCTAssertEqual(decodedDelta.revision, revision)

        // An older host sends neither field; both stay decodable and read as "unknown".
        let bareMe = Data(#"{"serverProtocol":{"version":1,"minimumSupported":1},"share":{"label":"o","scope":"all","capability":"interact"},"sessions":[]}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(RemoteMeDTO.self, from: bareMe).revision)
        let bareDelta = Data(#"{"type":"sessionsChanged"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(RemoteSessionsChangedDTO.self, from: bareDelta).revision)
    }
}

final class GzipWriterTests: XCTestCase {
    /// The container has to be one `URLSession` and every browser inflate transparently: the
    /// two magic bytes, method 8, and a CRC-32 / length trailer over the original bytes.
    func testACompressibleBodyIsWrappedInAValidGzipContainer() throws {
        let original = Data(String(repeating: "{\"session\":\"row\"},", count: 500).utf8)
        let gzip = try XCTUnwrap(GzipWriter.compress(original))

        XCTAssertLessThan(gzip.count, original.count)
        XCTAssertEqual(Array(gzip.prefix(3)), [0x1f, 0x8b, 0x08])

        let trailer = gzip.suffix(8)
        let crc = trailer.prefix(4).reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let size = trailer.suffix(4).reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        XCTAssertEqual(crc, ZipArchiveWriter.crc32(original))
        XCTAssertEqual(Int(size), original.count)

        let deflated = gzip.dropFirst(10).dropLast(8)
        XCTAssertEqual(inflate(Data(deflated), expecting: original.count), original)
    }

    func testABodyThatWouldNotShrinkIsLeftAlone() {
        XCTAssertNil(GzipWriter.compress(Data()))
        XCTAssertNil(GzipWriter.compress(Data([0x01, 0x02, 0x03])))
        var noise = Data(count: 256)
        for index in noise.indices { noise[index] = UInt8((index &* 197 &+ 31) & 0xFF) }
        XCTAssertNil(GzipWriter.compress(noise), "incompressible bytes must not pay the framing")
    }

    private func inflate(_ deflated: Data, expecting count: Int) -> Data {
        var inflated = Data(count: count)
        let written = inflated.withUnsafeMutableBytes { destination -> Int in
            deflated.withUnsafeBytes { source -> Int in
                compression_decode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!,
                    count,
                    source.bindMemory(to: UInt8.self).baseAddress!,
                    deflated.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        return inflated.prefix(written)
    }
}
