import AppKit
import Metal
import ThreadingExtensionKit
import XCTest
@testable import Threading

/// A Metal surface that names a package picture: the four-argument ABI, the transparent
/// placeholder it draws on until the picture lands, the picture itself in the right place and
/// the right colours, and the bounds the read and decode keep.
@MainActor
final class ExtensionSurfaceTextureTests: XCTestCase {

    // MARK: - Fixtures

    /// Samples the picture and returns it as-is: the shortest shader that proves a pixel came
    /// from the texture.
    private static let sampleSource = """
    float4 threadingExtensionFragment(
        float2 uv,
        constant ThreadingSurfaceUniforms &uniforms,
        texture2d<float> image,
        sampler imageSampler
    ) {
        return image.sample(imageSampler, uv);
    }
    """

    /// The two-argument function every untextured surface uses.
    private static let untexturedSource = """
    float4 threadingExtensionFragment(
        float2 uv,
        constant ThreadingSurfaceUniforms &uniforms
    ) {
        return float4(uniforms.values[0], 0.0, 0.0, 1.0);
    }
    """

    private static let texturedSpecification = ExtensionMetalSurface(
        shaderResource: "Resources/paper.metal",
        preferredFramesPerSecond: 12,
        texture: "Resources/paper.png"
    )

    private func requireMetal() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal is unavailable on this test host.")
        }
    }

    /// A PNG whose rows are the given straight-alpha RGBA pixels, top row first.
    private static func png(width: Int, rows: [[(UInt8, UInt8, UInt8, UInt8)]]) throws -> Data {
        let representation = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: rows.count,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [.alphaNonpremultiplied],
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        ))
        let srgb = try XCTUnwrap(representation.retagging(with: .sRGB))
        let bytes = try XCTUnwrap(srgb.bitmapData)
        for (y, row) in rows.enumerated() {
            for (x, pixel) in row.enumerated() {
                let offset = (y * width + x) * 4
                bytes[offset] = pixel.0
                bytes[offset + 1] = pixel.1
                bytes[offset + 2] = pixel.2
                bytes[offset + 3] = pixel.3
            }
        }
        return try XCTUnwrap(srgb.representation(using: .png, properties: [:]))
    }

    private static let red: (UInt8, UInt8, UInt8, UInt8) = (255, 0, 0, 255)
    private static let blue: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 255, 255)

    private func maximumAlpha(_ image: NSImage) throws -> Double {
        try SurfaceSnapshotPixels.maximumAlpha(in: image)
    }

    func testShaderCacheCoalescesPreparationAndMeasuresMountCost() async throws {
        try requireMetal()
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let specification = ExtensionMetalSurface(shaderResource: "Resources/probe.metal")
        let source = Self.untexturedSource + "\n// mount measurement \(UUID())"
        let complete = ExtensionMetalSurfaceView.completeSource(extensionSource: source,
            fragmentFunction: specification.fragmentFunction, isTextured: false)
        func compileSynchronously() throws {
            let library = try device.makeLibrary(source: complete, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "threadingHostSurfaceVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "threadingHostSurfaceFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            _ = try device.makeRenderPipelineState(descriptor: descriptor)
        }
        let before = ProcessInfo.processInfo.systemUptime
        try compileSynchronously()
        let synchronous = ProcessInfo.processInfo.systemUptime - before
        let mounting = ProcessInfo.processInfo.systemUptime
        let view = try ExtensionMetalSurfaceView(specification: specification, source: source,
            signalProvider: { _, _ in nil })
        let mount = ProcessInfo.processInfo.systemUptime - mounting
        try await view.waitForPreparation()
        let cache = ExtensionMetalPipelineCache()
        async let a = cache.prepare(source: complete)
        async let b = cache.prepare(source: complete)
        let (first, second) = try await (a, b)
        let cached = try await cache.prepare(source: complete)
        XCTAssertTrue(first.state === second.state)
        XCTAssertTrue(first.state === cached.state)
        print("Theme shader cost: synchronous compilation \(synchronous * 1000) ms; mount without compilation \(mount * 1000) ms")
    }

    // MARK: - Pixels

    /// The worker's output is straight-alpha sRGB, top row first — the convention the surface's
    /// own output blends in.
    func testDecodedPixelsAreStraightAlphaTopRowFirst() throws {
        let data = try Self.png(width: 2, rows: [
            [Self.red, (255, 0, 0, 128)],
            [Self.blue, (0, 0, 0, 0)]
        ])
        let pixels = try XCTUnwrap(ExtensionSurfaceTexturePixels.prepared(fromImageData: data))
        XCTAssertEqual(pixels.width, 2)
        XCTAssertEqual(pixels.height, 2)
        XCTAssertEqual(pixels.bytes.count, 2 * 2 * ExtensionSurfaceTexturePixels.bytesPerPixel)
        let bytes = [UInt8](pixels.bytes)
        XCTAssertEqual(Array(bytes[0..<4]), [255, 0, 0, 255], "top-left is the first row's red")
        XCTAssertEqual(bytes[4 + 3], 128)
        XCTAssertEqual(Double(bytes[4]), 255, accuracy: 1, "half-transparent red stays full red")
        XCTAssertEqual(Array(bytes[8..<12]), [0, 0, 255, 255], "the second row starts blue")
        XCTAssertEqual(Array(bytes[12..<16]), [0, 0, 0, 0])
    }

    /// The package image ceilings hold for a surface's picture as for every other image.
    func testThePackageReadRefusesWhatTheImagePolicyRefuses() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("surface-texture-\(UUID().uuidString)", isDirectory: true)
        let resources = root.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Self.png(width: 1, rows: [[Self.red]])
            .write(to: resources.appendingPathComponent("paper.png"))
        let oversized = ExtensionImageResourcePolicy.maximumPixelDimension + 1
        try Self.png(width: oversized, rows: [Array(repeating: Self.red, count: oversized)])
            .write(to: resources.appendingPathComponent("wide.png"))

        let accepted = try XCTUnwrap(ExtensionImageResourcePolicy.validatedData(
            relativePath: "Resources/paper.png",
            packageRootURL: root
        ))
        XCTAssertEqual(ExtensionSurfaceTexturePixels.prepared(fromImageData: accepted)?.width, 1)
        XCTAssertNil(ExtensionImageResourcePolicy.validatedData(
            relativePath: "Resources/wide.png",
            packageRootURL: root
        ), "wider than the package image ceiling")
        XCTAssertNil(ExtensionImageResourcePolicy.validatedData(
            relativePath: "../paper.png",
            packageRootURL: resources
        ), "outside the package")
        XCTAssertNil(ExtensionSurfaceTexturePixels.prepared(fromImageData: Data("not an image".utf8)))
    }

    /// An extension the manager does not know is refused without a worker hop.
    func testAnUnknownExtensionGetsNoPicture() {
        let answer = Answer()
        ExtensionManager.shared.prepareCustomSurfaceTexture(
            relativePath: "Resources/paper.png",
            extensionIdentifier: "com.example.not-installed-\(UUID().uuidString)",
            prepare: { ExtensionSurfaceTexturePixels.prepared(fromImageData: $0) },
            completion: { pixels in
                answer.isAnswered = true
                answer.pixels = pixels
            }
        )
        XCTAssertTrue(answer.isAnswered)
        XCTAssertNil(answer.pixels)
    }

    @MainActor
    private final class Answer {
        var isAnswered = false
        var pixels: ExtensionSurfaceTexturePixels?
    }

    // MARK: - The surface

    /// The placeholder first, then the picture: top rows red, bottom rows blue, exactly where
    /// the image put them.
    func testATexturedSurfaceDrawsThePictureOnceItLands() async throws {
        try requireMetal()
        let surface = try ExtensionMetalSurfaceView(
            specification: Self.texturedSpecification,
            source: Self.sampleSource,
            signalProvider: { _, _ in nil }
        )
        try await surface.waitForPreparation()
        XCTAssertFalse(surface.showsTexture)
        let size = NSSize(width: 8, height: 8)
        let before = try XCTUnwrap(surface.snapshotImage(size: size, time: 0))
        XCTAssertEqual(try maximumAlpha(before), 0, "the placeholder samples transparent")

        let pixels = try XCTUnwrap(ExtensionSurfaceTexturePixels.prepared(fromImageData:
            Self.png(width: 2, rows: [[Self.red, Self.red], [Self.blue, Self.blue]])
        ))
        XCTAssertTrue(surface.installTexture(pixels))
        XCTAssertTrue(surface.showsTexture)

        let after = try XCTUnwrap(surface.snapshotImage(size: size, time: 0))
        let top = try SurfaceSnapshotPixels.rgba(in: after, x: 4, y: 1)
        XCTAssertEqual(top.red, 1, accuracy: 0.02)
        XCTAssertEqual(top.blue, 0, accuracy: 0.02)
        XCTAssertEqual(top.alpha, 1, accuracy: 0.02)
        let bottom = try SurfaceSnapshotPixels.rgba(in: after, x: 4, y: 6)
        XCTAssertEqual(bottom.red, 0, accuracy: 0.02)
        XCTAssertEqual(bottom.blue, 1, accuracy: 0.02)
        XCTAssertEqual(bottom.alpha, 1, accuracy: 0.02)
    }

    /// Stating a texture changes the ABI: a two-argument function no longer compiles against
    /// the wrapper, and a four-argument one does not compile without a texture.
    func testTheTexturedABIIsTheFourArgumentFunction() async throws {
        try requireMetal()
        do {
            let invalid = try ExtensionMetalSurfaceView(
            specification: Self.texturedSpecification,
            source: Self.untexturedSource,
            signalProvider: { _, _ in nil }
            )
            try await invalid.waitForPreparation()
            XCTFail("The incompatible shader ABI compiled")
        } catch {}
        do {
            let invalid = try ExtensionMetalSurfaceView(
            specification: ExtensionMetalSurface(shaderResource: "Resources/paper.metal"),
            source: Self.sampleSource,
            signalProvider: { _, _ in nil }
            )
            try await invalid.waitForPreparation()
            XCTFail("The incompatible shader ABI compiled")
        } catch {}
        let untextured = try ExtensionMetalSurfaceView(
            specification: ExtensionMetalSurface(
                shaderResource: "Resources/paper.metal",
                inputs: [.init(name: "red", value: .constant(1))]
            ),
            source: Self.untexturedSource,
            signalProvider: { _, _ in nil }
        )
        try await untextured.waitForPreparation()
        let pixels = try XCTUnwrap(ExtensionSurfaceTexturePixels.prepared(fromImageData:
            Self.png(width: 1, rows: [[Self.blue]])
        ))
        XCTAssertFalse(untextured.installTexture(pixels), "nothing to bind it to")
        XCTAssertFalse(untextured.showsTexture)
    }

    /// The renderer's attach step installs what the loader hands back, and a picture that never
    /// arrives leaves the surface drawing on its placeholder rather than skipping the hook.
    func testTheRendererInstallsALoadedPictureAndDrawsOnWithoutOne() async throws {
        try requireMetal()
        let pixels = try XCTUnwrap(ExtensionSurfaceTexturePixels.prepared(fromImageData:
            Self.png(width: 1, rows: [[Self.red]])
        ))
        var requested: [String] = []

        let loaded = try ExtensionMetalSurfaceView(
            specification: Self.texturedSpecification,
            source: Self.sampleSource,
            signalProvider: { _, _ in nil }
        )
        try await loaded.waitForPreparation()
        ExtensionCustomSurfaceRenderer.attachTexture(
            "Resources/paper.png",
            to: loaded,
            extensionIdentifier: "com.example.paper",
            loader: { path, identifier, completion in
                requested.append("\(identifier)/\(path)")
                completion(pixels)
            }
        )
        XCTAssertEqual(requested, ["com.example.paper/Resources/paper.png"])
        XCTAssertTrue(loaded.showsTexture)

        let missing = try ExtensionMetalSurfaceView(
            specification: Self.texturedSpecification,
            source: Self.sampleSource,
            signalProvider: { _, _ in nil }
        )
        try await missing.waitForPreparation()
        ExtensionCustomSurfaceRenderer.attachTexture(
            "Resources/paper.png",
            to: missing,
            extensionIdentifier: "com.example.paper",
            loader: { _, _, completion in completion(nil) }
        )
        XCTAssertFalse(missing.showsTexture)
        let drawn = try XCTUnwrap(missing.snapshotImage(size: NSSize(width: 4, height: 4), time: 0))
        XCTAssertEqual(try maximumAlpha(drawn), 0)
    }
}
