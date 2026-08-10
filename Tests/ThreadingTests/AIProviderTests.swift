import XCTest
@testable import Threading

final class AIProviderTests: XCTestCase {

    func testOllamaAcceptsHTTPAndHTTPSOrigins() {
        XCTAssertTrue(OllamaProvider(baseURL: "http://127.0.0.1:11434").isConfigured)
        XCTAssertTrue(OllamaProvider(baseURL: "https://models.example.test").isConfigured)
    }

    func testOllamaRejectsRelativeAndNonNetworkURLsAtConfigurationTime() {
        XCTAssertFalse(OllamaProvider(baseURL: "localhost:11434").isConfigured)
        XCTAssertFalse(OllamaProvider(baseURL: "file:///tmp/ollama.sock").isConfigured)
        XCTAssertFalse(OllamaProvider(baseURL: "not a URL").isConfigured)
    }
}
