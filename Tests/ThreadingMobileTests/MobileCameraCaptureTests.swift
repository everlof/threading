import AVFoundation
import ThreadingRemoteKit
import UIKit
import XCTest
@testable import ThreadingMobile

final class MobileCameraCaptureTests: XCTestCase {
    func testPermissionPolicyDoesNotRequestAccessForMissingOrRestrictedCameras() {
        XCTAssertEqual(MobileCameraAccess.resolve(isAvailable: false, authorization: .notDetermined), .unavailable)
        XCTAssertEqual(MobileCameraAccess.resolve(isAvailable: true, authorization: .restricted), .restricted)
        XCTAssertEqual(MobileCameraAccess.resolve(isAvailable: true, authorization: .denied), .denied)
        XCTAssertEqual(MobileCameraAccess.resolve(isAvailable: true, authorization: .authorized), .available)
        XCTAssertEqual(MobileCameraAccess.resolve(isAvailable: true, authorization: .notDetermined), .request)
    }

    func testTheBuiltCameraPurposeCoversPairingAndMessagePhotos() throws {
        let purpose = try XCTUnwrap(Bundle.main.infoDictionary?["NSCameraUsageDescription"] as? String)
        XCTAssertEqual(purpose, "Scan a private Threading pairing code or take a photo to attach to a message.")
        XCTAssertNil(Bundle.main.infoDictionary?["NSPhotoLibraryAddUsageDescription"],
                     "capturing an attachment must not require saving it in Photos")
    }

    func testPortraitCaptureIsAnUprightBoundedJPEG() async throws {
        let image = try makeImage(width: 4032, height: 3024, orientation: .right)
        let prepared = await Task.detached {
            ComposerAttachmentPayload.capturedImage(image, name: "photo-test.jpg")
        }.value
        let payload = try XCTUnwrap(prepared)
        let decoded = try XCTUnwrap(UIImage(data: payload.data))
        let pixels = try XCTUnwrap(decoded.cgImage)
        XCTAssertEqual(payload.type, .jpeg)
        XCTAssertEqual(payload.name, "photo-test.jpg")
        XCTAssertEqual(decoded.imageOrientation, .up)
        XCTAssertEqual(pixels.height, Int(RemoteAttachmentUploadClientDefaults.downscaledMaximumDimension))
        XCTAssertEqual(pixels.width * 4, pixels.height * 3)
        XCTAssertLessThanOrEqual(payload.data.count, RemoteAttachmentUploadLimits.maximumBytesPerFile)
        XCTAssertEqual(payload.thumbnail?.scale, 1)
        XCTAssertFalse(payload.isMovie)
    }

    func testMirroredPhotoIsNormalizedWithoutUpscaling() throws {
        let image = try makeImage(width: 80, height: 40, orientation: .upMirrored)
        let payload = try XCTUnwrap(ComposerAttachmentPayload.capturedImage(image, name: "mirrored.jpg"))
        let decoded = try XCTUnwrap(UIImage(data: payload.data))
        let pixels = try XCTUnwrap(decoded.cgImage)
        XCTAssertEqual(pixels.width, 80)
        XCTAssertEqual(pixels.height, 40)
        XCTAssertEqual(decoded.imageOrientation, .up)

        // The source's red left half must move right, rather than only losing its EXIF flag.
        let colors = try rgbSamples(pixels)
        XCTAssertGreaterThan(colors.leftBlue, colors.leftRed + 100)
        XCTAssertGreaterThan(colors.rightRed, colors.rightBlue + 100)
    }

    /// Opt-in because creating a 48 MP source is itself a large allocation. Fixture manufacture
    /// is outside the worker timing; this measures the shipping normalization/encode function.
    func testCameraPreparationStress() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["THREADING_CAMERA_STRESS"] == "1")
        for width in [4032, 8064] {
            let image = try makeImage(width: width, height: width * 3 / 4, orientation: .right)
            var durations: [Double] = []
            for _ in 0..<3 {
                let result = await Task.detached {
                    let start = CACurrentMediaTime()
                    let payload = ComposerAttachmentPayload.capturedImage(image, name: "stress.jpg")
                    return (payload, (CACurrentMediaTime() - start) * 1_000)
                }.value
                let payload = try XCTUnwrap(result.0)
                XCTAssertLessThanOrEqual(payload.data.count, RemoteAttachmentUploadLimits.maximumBytesPerFile)
                durations.append(result.1)
            }
            durations.sort()
            print("CAMERA_PREP source_width=\(width) median_ms=\(durations[1]) max_ms=\(durations[2])")
        }
    }

    @MainActor
    func testCaptureReservesCapacityAndBlocksSendBeforeEncodingStarts() throws {
        let tray = ComposerAttachmentTray(client: RemoteClient(link: DemoExperience.link), uploadScopeID: UUID().uuidString)
        defer { tray.clear() }
        let image = try makeImage(width: 80, height: 40)
        for _ in 0..<RemoteAttachmentUploadLimits.maximumPerMessage {
            tray.addCapturedImage(image)
        }
        XCTAssertTrue(tray.isSettling)
        XCTAssertTrue(tray.readyUploadIDs.isEmpty)
        XCTAssertFalse(tray.canAcceptMore)
        tray.addCapturedImage(image)
        XCTAssertEqual(tray.items.count, RemoteAttachmentUploadLimits.maximumPerMessage)
        XCTAssertNotNil(tray.notice)
    }

    @MainActor
    func testRemovingACaptureDuringPreparationDoesNotRestoreIt() async throws {
        let tray = ComposerAttachmentTray(client: RemoteClient(link: DemoExperience.link), uploadScopeID: UUID().uuidString)
        let image = try makeImage(width: 4032, height: 3024)
        tray.addCapturedImage(image)
        let id = try XCTUnwrap(tray.items.first?.id)
        await Task.yield()
        tray.remove(id)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(tray.isEmpty)
        XCTAssertFalse(tray.isSettling)
        XCTAssertTrue(tray.readyUploadIDs.isEmpty)
    }

    private func makeImage(width: Int, height: Int, orientation: UIImage.Orientation = .up) throws -> UIImage {
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.blue.setFill()
            context.fill(CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height))
        }
        return UIImage(cgImage: try XCTUnwrap(image.cgImage), scale: 1, orientation: orientation)
    }

    private func rgbSamples(_ image: CGImage) throws -> (leftRed: Int, leftBlue: Int, rightRed: Int, rightBlue: Int) {
        let width = image.width
        var bytes = [UInt8](repeating: 0, count: width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: image.height))
        }
        let left = (image.height / 2 * width + width / 4) * 4
        let right = (image.height / 2 * width + 3 * width / 4) * 4
        return (Int(bytes[left]), Int(bytes[left + 2]), Int(bytes[right]), Int(bytes[right + 2]))
    }
}
