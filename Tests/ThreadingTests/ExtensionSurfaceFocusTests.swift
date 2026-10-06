import AppKit
import Metal
import ThreadingExtensionKit
import XCTest
@testable import Threading

/// `ThreadingSurfaceUniforms.focus`: where the composer's hero and prompt box sit, told to an
/// extension's Metal surface in the fragment's own `uv` space. The struct the shader is compiled
/// against and the floats the Mac uploads agree byte for byte, a shader reading a region draws
/// exactly there, and the composer's backdrop plane hands the regions to whatever surface it
/// mounts — including one that lands after the regions were stated.
@MainActor
final class ExtensionSurfaceFocusTests: XCTestCase {

    // MARK: - Fixtures

    private typealias Layout = ExtensionMetalSource.UniformLayout

    /// Opaque red inside `focus[1]` — the prompt box — and nothing anywhere else, including
    /// inside `focus[0]`. A zero-width region is no region.
    private static let promptBoxSource = """
    float4 threadingExtensionFragment(
        float2 uv,
        constant ThreadingSurfaceUniforms &uniforms
    ) {
        float4 box = uniforms.focus[1];
        if (box.z <= 0.0) { return float4(0.0); }
        bool inside = uv.x >= box.x && uv.x < box.x + box.z
            && uv.y >= box.y && uv.y < box.y + box.w;
        return inside ? float4(1.0, 0.0, 0.0, 1.0) : float4(0.0);
    }
    """

    private static let specification = ExtensionMetalSurface(
        shaderResource: "Resources/focus.metal",
        preferredFramesPerSecond: 30
    )

    private static let source = ComponentCustomizationSource(
        extensionIdentifier: "com.example.focus",
        processGeneration: "one",
        order: 0
    )

    private static let surfaceHook = ExtensionNode.overlay(
        base: .customSurface(.metal(specification), accessibilityLabel: nil),
        overlay: .proceed
    )

    private func requireMetal() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal is unavailable on this test host.")
        }
    }

    private func makeSurface() throws -> ExtensionMetalSurfaceView {
        try ExtensionMetalSurfaceView(
            specification: Self.specification,
            source: Self.promptBoxSource,
            signalProvider: { _, _ in nil }
        )
    }

    /// Asserts the snapshot is opaque red on exactly the pixels whose centres fall inside
    /// `region` (pixel rows counted from the top) and transparent everywhere else.
    private func assertPaints(
        _ image: NSImage,
        width: Int,
        height: Int,
        exactly region: (x: Range<Int>, y: Range<Int>)?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var mismatches: [String] = []
        for y in 0..<height {
            for x in 0..<width {
                let pixel = try SurfaceSnapshotPixels.rgba(in: image, x: x, y: y)
                let expected = region.map { $0.x.contains(x) && $0.y.contains(y) } ?? false
                let painted = pixel.alpha > 0.5 && pixel.red > 0.5
                let clear = pixel.alpha == 0
                if expected ? !painted : !clear { mismatches.append("(\(x), \(y))") }
            }
        }
        XCTAssertTrue(
            mismatches.isEmpty,
            "pixels off the region: \(mismatches.prefix(12).joined(separator: " "))",
            file: file,
            line: line
        )
    }

    private func registry(publishing hook: ExtensionNode?) throws -> ComponentCustomizationRegistry {
        let registry = ComponentCustomizationRegistry()
        for placement in [ExtensionBackdropPlaneView.Placement.composer, .displayPanel] {
            try registry.register(placement.contract)
        }
        if let hook {
            try registry.replacePatches(
                [.init(id: "focus", target: .composerBackdrop(), hook: hook),
                 .init(id: "focus-display", target: .displayBackdrop(), hook: hook)],
                from: Self.source
            )
        }
        return registry
    }

    /// A plane laid out at `size` in a detached host, building its surfaces from the fixture
    /// source and reporting each one it built.
    private func plane(
        _ placement: ExtensionBackdropPlaneView.Placement,
        size: NSSize,
        registry: ComponentCustomizationRegistry,
        built: @escaping (ExtensionMetalSurfaceView) -> Void
    ) -> (host: NSView, plane: ExtensionBackdropPlaneView) {
        let plane = ExtensionBackdropPlaneView(
            placement: placement,
            lookup: registry.customization(for:),
            customSurfaceResolver: { surface, _ in
                guard case .metal(let specification) = surface,
                      let view = try? ExtensionMetalSurfaceView(
                        specification: specification,
                        source: Self.promptBoxSource,
                        maximumFramesPerSecond: placement.maximumFramesPerSecond,
                        signalProvider: { _, _ in nil }
                      ) else { return nil }
                built(view)
                return view
            }
        )
        let host = NSView(frame: NSRect(origin: .zero, size: size))
        host.addSubview(plane)
        plane.pinToEdges(of: host)
        host.layoutSubtreeIfNeeded()
        return (host, plane)
    }

    // MARK: - The ABI

    /// Metal's own reflection of the compiled struct agrees with the layout the SDK states and
    /// with the floats the Mac uploads: 80 bytes, `values` at 16, `focus` at 48 as two float4s.
    func testCompiledStructMatchesTheSwiftMirror() throws {
        try requireMetal()
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        for isTextured in [false, true] {
            let fragment = isTextured
                ? """
                float4 threadingExtensionFragment(float2 uv, constant ThreadingSurfaceUniforms &uniforms,
                                                  texture2d<float> image, sampler imageSampler) {
                    return uniforms.focus[0] + image.sample(imageSampler, uv);
                }
                """
                : Self.promptBoxSource
            let complete = ExtensionMetalSource.completeSource(
                extensionSource: fragment,
                fragmentFunction: ExtensionMetalSurface.defaultFragmentFunction,
                isTextured: isTextured
            )
            let library = try device.makeLibrary(source: complete, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "threadingHostSurfaceVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "threadingHostSurfaceFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            var reflection: MTLRenderPipelineReflection?
            _ = try device.makeRenderPipelineState(
                descriptor: descriptor,
                options: [.bindingInfo, .bufferTypeInfo],
                reflection: &reflection
            )
            let binding = try XCTUnwrap(
                reflection?.fragmentBindings
                    .first { $0.type == .buffer && $0.index == 0 } as? MTLBufferBinding
            )
            XCTAssertEqual(binding.bufferDataSize, Layout.byteCount)
            let members = try XCTUnwrap(binding.bufferStructType)
            XCTAssertEqual(members.memberByName("size")?.offset, 0)
            XCTAssertEqual(members.memberByName("time")?.offset, 2 * MemoryLayout<Float>.size)
            XCTAssertEqual(
                members.memberByName("values")?.offset,
                Layout.valuesOffset * MemoryLayout<Float>.size
            )
            let focus = try XCTUnwrap(members.memberByName("focus"))
            XCTAssertEqual(focus.offset, Layout.focusByteOffset)
            XCTAssertEqual(focus.arrayType()?.arrayLength, Layout.focusRegionCount)
            XCTAssertEqual(focus.arrayType()?.elementType, .float4)
        }

        let surface = try makeSurface()
        let uploaded = surface.uniformFloats(
            size: CGSize(width: 40, height: 20),
            focusBounds: CGRect(x: 0, y: 0, width: 40, height: 20),
            time: 0
        )
        XCTAssertEqual(uploaded.count * MemoryLayout<Float>.stride, Layout.byteCount)
        XCTAssertEqual(Array(uploaded[Layout.focusOffset...]), [Float](repeating: 0, count: 8))
    }

    /// The regions land in the fragment's `uv` space — origin top-left, y down — whichever way
    /// the view's own coordinates run; empty regions and empty bounds are zeros.
    func testRegionsNormalizeIntoTopLeftUV() {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 100)
        let focus = ExtensionSurfaceFocus(
            primary: CGRect(x: 50, y: 60, width: 100, height: 20),
            secondary: CGRect(x: 20, y: 10, width: 60, height: 30)
        )
        XCTAssertEqual(
            focus.uniformValues(in: bounds, isFlipped: false),
            [0.25, 0.2, 0.5, 0.2, 0.1, 0.6, 0.3, 0.3]
        )
        XCTAssertEqual(
            focus.uniformValues(in: bounds, isFlipped: true),
            [0.25, 0.6, 0.5, 0.2, 0.1, 0.1, 0.3, 0.3]
        )
        XCTAssertEqual(
            ExtensionSurfaceFocus(secondary: focus.secondary)
                .uniformValues(in: bounds, isFlipped: false),
            [0, 0, 0, 0, 0.1, 0.6, 0.3, 0.3],
            "a hidden hero is a zero-width region"
        )
        XCTAssertEqual(focus.uniformValues(in: .zero, isFlipped: false), [Float](repeating: 0, count: 8))
        XCTAssertEqual(
            ExtensionSurfaceFocus(primary: CGRect(x: 10, y: 10, width: CGFloat.infinity, height: 4))
                .uniformValues(in: bounds, isFlipped: false),
            [Float](repeating: 0, count: 8)
        )
    }

    // MARK: - Pixels

    /// A shader that paints only inside `focus[1]` paints exactly the prompt box's pixels and
    /// none of the hero's.
    func testAShaderDrawsExactlyInsideThePromptBox() async throws {
        try requireMetal()
        let surface = try makeSurface()
        try await surface.waitForPreparation()
        surface.frame = NSRect(x: 0, y: 0, width: 40, height: 20)
        // In the view's own, bottom-up coordinates: the box's top edge is 10 pt from the top.
        surface.setFocus(ExtensionSurfaceFocus(
            primary: NSRect(x: 0, y: 14, width: 8, height: 6),
            secondary: NSRect(x: 10, y: 4, width: 20, height: 6)
        ))
        let image = try XCTUnwrap(surface.snapshotImage(size: NSSize(width: 40, height: 20), time: 0))
        try assertPaints(image, width: 40, height: 20, exactly: (x: 10..<30, y: 10..<16))
    }

    /// With no regions stated, the same shader paints nothing at all.
    func testZeroFocusPaintsNothing() async throws {
        try requireMetal()
        let surface = try makeSurface()
        try await surface.waitForPreparation()
        surface.frame = NSRect(x: 0, y: 0, width: 40, height: 20)
        let image = try XCTUnwrap(surface.snapshotImage(size: NSSize(width: 40, height: 20), time: 0))
        XCTAssertEqual(try SurfaceSnapshotPixels.maximumAlpha(in: image), 0)
        surface.setFocus(ExtensionSurfaceFocus(primary: NSRect(x: 0, y: 0, width: 40, height: 20)))
        let heroOnly = try XCTUnwrap(surface.snapshotImage(size: NSSize(width: 40, height: 20), time: 0))
        XCTAssertEqual(try SurfaceSnapshotPixels.maximumAlpha(in: heroOnly), 0, "focus[0] is not focus[1]")
    }

    // MARK: - Coordinate spaces

    /// Regions stated in an ancestor's coordinates are read into the surface's own on every
    /// frame, so a surface that layout moves needs no restatement — and one moved out from under
    /// its space reads none.
    func testRegionsFollowTheSurfaceWithinTheSpaceTheyWereStatedIn() throws {
        try requireMetal()
        let space = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let surface = try makeSurface()
        surface.frame = NSRect(x: 10, y: 5, width: 50, height: 40)
        space.addSubview(surface)
        let box = NSRect(x: 30, y: 25, width: 10, height: 10)
        surface.setFocus(ExtensionSurfaceFocus(secondary: box), in: space)
        XCTAssertEqual(surface.focus.secondary, NSRect(x: 20, y: 20, width: 10, height: 10))
        XCTAssertEqual(surface.focus.primary, .zero, "an empty region is not converted into one")

        surface.setFrameOrigin(.zero)
        XCTAssertEqual(surface.focus.secondary, box)

        surface.removeFromSuperview()
        XCTAssertEqual(surface.focus, ExtensionSurfaceFocus())
    }

    // MARK: - The plane

    /// The composer's plane hands its regions to a surface mounted *after* they were stated, in
    /// the surface's coordinates, and the surface draws the prompt box where the plane said.
    func testTheComposerPlaneTellsASurfaceMountedLater() async throws {
        try requireMetal()
        let registry = try registry(publishing: nil)
        var surfaces: [ExtensionMetalSurfaceView] = []
        let (host, plane) = plane(.composer, size: NSSize(width: 40, height: 20), registry: registry) {
            surfaces.append($0)
        }
        XCTAssertFalse(plane.isDressed)
        let stated = ExtensionSurfaceFocus(
            primary: NSRect(x: 0, y: 14, width: 8, height: 6),
            secondary: NSRect(x: 10, y: 4, width: 20, height: 6)
        )
        plane.focus = stated

        try registry.replacePatches(
            [.init(id: "focus", target: .composerBackdrop(), hook: Self.surfaceHook)],
            from: Self.source
        )
        XCTAssertTrue(plane.isDressed)
        let surface = try XCTUnwrap(surfaces.last)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(surface.frame.size, NSSize(width: 40, height: 20))
        XCTAssertEqual(surface.focus, stated, "the surface fills the plane, so the rects carry over")

        try await surface.waitForPreparation()
        let image = try XCTUnwrap(surface.snapshotImage(size: NSSize(width: 40, height: 20), time: 0))
        try assertPaints(image, width: 40, height: 20, exactly: (x: 10..<30, y: 10..<16))

        // A restatement reaches the mounted surface; taking the hero away zeroes its slot.
        plane.focus = ExtensionSurfaceFocus(secondary: NSRect(x: 0, y: 0, width: 4, height: 2))
        XCTAssertEqual(surface.focus.primary, .zero)
        let moved = try XCTUnwrap(surface.snapshotImage(size: NSSize(width: 40, height: 20), time: 0))
        try assertPaints(moved, width: 40, height: 20, exactly: (x: 0..<4, y: 18..<20))
    }

    /// Every other placement tells its surfaces there are no regions, whatever it is handed.
    func testOtherPlacementsStateNoRegions() throws {
        try requireMetal()
        XCTAssertTrue(ExtensionBackdropPlaneView.Placement.composer.statesFocus)
        XCTAssertFalse(ExtensionBackdropPlaneView.Placement.displayPanel.statesFocus)
        XCTAssertFalse(ExtensionBackdropPlaneView.Placement.sidebar.statesFocus)

        let registry = try registry(publishing: Self.surfaceHook)
        var surfaces: [ExtensionMetalSurfaceView] = []
        let (_, plane) = plane(.displayPanel, size: NSSize(width: 40, height: 20), registry: registry) {
            surfaces.append($0)
        }
        XCTAssertTrue(plane.isDressed)
        plane.focus = ExtensionSurfaceFocus(secondary: NSRect(x: 10, y: 4, width: 20, height: 6))
        let surface = try XCTUnwrap(surfaces.last)
        XCTAssertEqual(surface.focus, ExtensionSurfaceFocus())
        let uploaded = surface.uniformFloats(
            size: surface.bounds.size,
            focusBounds: surface.bounds,
            time: 0
        )
        XCTAssertEqual(Array(uploaded[Layout.focusOffset...]), [Float](repeating: 0, count: 8))
    }
}
