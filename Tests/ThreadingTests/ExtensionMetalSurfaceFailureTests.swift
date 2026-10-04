import AppKit
import ThreadingExtensionKit
@testable import Threading
import XCTest

/// A surface whose shader does not compile withdraws itself rather than staying mounted and
/// blank — and above all holds no audio-capture demand, so it cannot keep the system-audio tap
/// running for a picture it will never draw.
@MainActor
final class ExtensionMetalSurfaceFailureTests: XCTestCase {

    func testAShaderThatDoesNotCompileWithdrawsTheSurfaceAndHoldsNoAudioDemand() async throws {
        let consumersBefore = AudioSpectrumService.shared.consumerCount
        let surface = try ExtensionMetalSurfaceView(
            specification: .init(
                shaderResource: "Resources/broken.metal",
                preferredFramesPerSecond: 30,
                inputs: [.init(name: "bass", value: .signal(.audioBass, mapping: .identity))]
            ),
            source: "float4 threadingExtensionFragment( this is not Metal",
            signalProvider: { _, _ in 0.8 }
        )
        do {
            try await surface.waitForPreparation()
            XCTFail("a shader that does not compile must report its failure")
        } catch {}

        XCTAssertTrue(surface.hasWithdrawn)
        XCTAssertTrue(surface.isHidden, "a withdrawn surface is hidden, as a skipped hook would be")
        XCTAssertTrue(surface.isPaused)
        surface.updateVisibilityHold()
        XCTAssertTrue(surface.isPaused, "visibility changes never restart a withdrawn surface")
        XCTAssertEqual(AudioSpectrumService.shared.consumerCount, consumersBefore,
                       "a surface with no pipeline asks for no audio capture")
    }
}
