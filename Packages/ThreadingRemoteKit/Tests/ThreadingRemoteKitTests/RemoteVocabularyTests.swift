import XCTest

@testable import ThreadingRemoteKit

final class RemoteVocabularyTests: XCTestCase {
    func testTerminalActivityUsesItsWireSpellingAndPreservesANewerState() throws {
        XCTAssertEqual(
            String(decoding: try JSONEncoder().encode(RemoteTerminalActivity.working), as: UTF8.self),
            #""working""#
        )

        let future = try JSONDecoder().decode(
            RemoteTerminalActivity.self,
            from: Data(#""multiplexing""#.utf8)
        )
        XCTAssertEqual(future, .unknown("multiplexing"))
        XCTAssertEqual(
            String(decoding: try JSONEncoder().encode(future), as: UTF8.self),
            #""multiplexing""#
        )
    }
}
