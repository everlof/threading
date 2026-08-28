import XCTest

@testable import Threading

final class RemoteRouterAssetCacheTests: XCTestCase {

    private final class AssetReadProbe {
        private(set) var readsByURL: [URL: Int] = [:]

        func read(_ url: URL) -> Data {
            readsByURL[url, default: 0] += 1
            return Data(url.lastPathComponent.utf8)
        }
    }

    /// Five assets is the fixed schema; requests are the scaling axis. Exercise every path twice
    /// so the regression is a read count rather than a timing assertion that varies by machine.
    func testEachAllowlistedAssetIsReadOnlyOncePerRouter() throws {
        let paths = ["/", "/app.js", "/app.css", "/xterm.js", "/xterm.css"]
        let probe = AssetReadProbe()
        let router = RemoteRouter(bundle: .main, loadAssetData: probe.read)

        XCTAssertTrue(probe.readsByURL.isEmpty, "router construction must not add launch I/O")
        for path in paths + paths {
            XCTAssertEqual(try XCTUnwrap(router.staticResponse(forPath: path)).status, 200)
        }

        XCTAssertEqual(probe.readsByURL.count, paths.count)
        XCTAssertEqual(probe.readsByURL.values.reduce(0, +), paths.count)
        XCTAssertTrue(probe.readsByURL.values.allSatisfy { $0 == 1 })

        XCTAssertNil(router.staticResponse(forPath: "/not-an-asset"))
        XCTAssertEqual(probe.readsByURL.values.reduce(0, +), paths.count)
    }
}
