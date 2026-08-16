import XCTest
@testable import Threading

final class SettingsCatalogueServiceTests: XCTestCase {
    func testOwnsWireShapeAndPreservesAuthoredOrder() throws {
        struct Payload: Decodable {
            struct Page: Decodable {
                struct Setting: Decodable, Equatable {
                    let title: String
                    let section: String?
                }

                let id: String
                let title: String
                let group: String
                let terms: [String]
                let settings: [Setting]
            }

            let pages: [Page]
        }

        let pages = [
            SettingsCataloguePage(
                id: "second",
                title: "Second",
                group: "App",
                terms: ["Beta", "Alpha"],
                settings: [
                    .init(title: "Later row", section: "Section"),
                    .init(title: "Last row", section: nil)
                ]
            ),
            SettingsCataloguePage(
                id: "first",
                title: "First",
                group: "Data",
                terms: [],
                settings: []
            )
        ]

        guard case .success(let text) = SettingsCatalogueService().list(pages: pages) else {
            return XCTFail("The application service refused an encodable catalogue")
        }
        let payload = try JSONDecoder().decode(Payload.self, from: Data(text.utf8))

        XCTAssertEqual(payload.pages.map(\.id), ["second", "first"])
        XCTAssertEqual(payload.pages[0].terms, ["Beta", "Alpha"])
        XCTAssertEqual(
            payload.pages[0].settings,
            [
                .init(title: "Later row", section: "Section"),
                .init(title: "Last row", section: nil)
            ]
        )
        XCTAssertTrue(text.contains("\n"), "the established wire format is pretty-printed")
    }
}
