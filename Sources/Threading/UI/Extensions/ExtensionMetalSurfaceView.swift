import AppKit
import MetalKit
import ThreadingExtensionKit

enum ExtensionMetalSurfaceError: LocalizedError {
    case metalUnavailable
    case invalidSourceEncoding
    case missingFunction(String)

    var errorDescription: String? {
        switch self {
        case .metalUnavailable:
            return L10n.string("Metal is unavailable on this Mac.")
        case .invalidSourceEncoding:
            return L10n.string("The extension’s Metal source is not UTF-8.")
        case .missingFunction(let name):
            return L10n.format("The extension’s Metal source does not define “%@”.", name)
        }
    }
}

/// Host-owned execution of an extension-defined fragment surface.
///
/// The extension supplies one pure fragment function. Threading supplies the vertex stage,
/// command queue, drawable, uniform buffer, frame cadence, transparency and input mapping.
/// No Metal or AppKit object crosses the extension process boundary.
@MainActor
final class ExtensionMetalSurfaceView: MTKView, MTKViewDelegate {
    typealias SignalProvider = @MainActor (ExtensionHostSignal) -> Double?

    private static let maximumInputs = 8
    private static let hostVertexFunction = "threadingHostSurfaceVertex"
    private static let hostFragmentFunction = "threadingHostSurfaceFragment"

    private let specification: ExtensionMetalSurface
    private let signalProvider: SignalProvider
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let beganAt = ProcessInfo.processInfo.systemUptime

    init(
        specification: ExtensionMetalSurface,
        source: String,
        signalProvider: @escaping SignalProvider
    ) throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw ExtensionMetalSurfaceError.metalUnavailable
        }
        self.specification = specification
        self.signalProvider = signalProvider
        self.commandQueue = commandQueue

        let library = try device.makeLibrary(
            source: Self.completeSource(
                extensionSource: source,
                fragmentFunction: specification.fragmentFunction
            ),
            options: nil
        )
        guard let vertex = library.makeFunction(name: Self.hostVertexFunction),
              let fragment = library.makeFunction(name: Self.hostFragmentFunction) else {
            throw ExtensionMetalSurfaceError.missingFunction(
                specification.fragmentFunction
            )
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        super.init(frame: .zero, device: device)
        delegate = self
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        framebufferOnly = true
        enableSetNeedsDisplay = false
        isPaused = false
        preferredFramesPerSecond = specification.preferredFramesPerSecond
        wantsLayer = true
        layer?.isOpaque = false
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { false }

    /// Visual surfaces are passive. Controls in the next hook or native view remain hittable.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        guard encode(
            pass: pass,
            commandBuffer: commandBuffer,
            size: view.drawableSize,
            time: Design.Motion.reducesMotion
                ? 0
                : Float(ProcessInfo.processInfo.systemUptime - beganAt)
        ) else { return }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Renders the same pipeline into a CPU-readable texture.
    ///
    /// The inspector and extension authoring preview cannot recover an `MTKView` through
    /// AppKit's `cacheDisplay`, so they use this rather than substituting a fake visual.
    func snapshotImage(size: CGSize, time: Float) -> NSImage? {
        let pixelWidth = max(Int(size.width.rounded(.up)), 1)
        let pixelHeight = max(Int(size.height.rounded(.up)), 1)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: colorPixelFormat,
            width: pixelWidth,
            height: pixelHeight,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let texture = device?.makeTexture(descriptor: descriptor),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return nil
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = clearColor
        guard encode(
            pass: pass,
            commandBuffer: commandBuffer,
            size: CGSize(width: CGFloat(pixelWidth), height: CGFloat(pixelHeight)),
            time: time
        ) else { return nil }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed,
              let representation = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixelWidth,
                pixelsHigh: pixelHeight,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bitmapFormat: [.alphaFirst, .thirtyTwoBitLittleEndian],
                bytesPerRow: pixelWidth * 4,
                bitsPerPixel: 32
              ),
              let bytes = representation.bitmapData else {
            return nil
        }
        texture.getBytes(
            bytes,
            bytesPerRow: pixelWidth * 4,
            from: MTLRegionMake2D(0, 0, pixelWidth, pixelHeight),
            mipmapLevel: 0
        )
        representation.size = size
        let image = NSImage(size: size)
        image.addRepresentation(representation)
        return image
    }

    private func encode(
        pass: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer,
        size: CGSize,
        time: Float
    ) -> Bool {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            return false
        }
        var uniforms = uniformFloats(size: size, time: time)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(
            &uniforms,
            length: uniforms.count * MemoryLayout<Float>.stride,
            index: 0
        )
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return true
    }

    private func uniformFloats(size: CGSize, time: Float) -> [Float] {
        var result: [Float] = [
            Float(size.width),
            Float(size.height),
            time,
            0
        ]
        result.append(contentsOf: specification.inputs.map { input in
            Float(resolve(input.value))
        })
        if result.count < 4 + Self.maximumInputs {
            result.append(contentsOf: repeatElement(
                Float(0),
                count: 4 + Self.maximumInputs - result.count
            ))
        }
        return result
    }

    private func resolve(_ scalar: ExtensionSurfaceScalar) -> Double {
        switch scalar {
        case .constant(let value):
            return value
        case .signal(let signal, let mapping):
            guard let raw = signalProvider(signal) else { return mapping.fallback }
            let position = min(max(
                (raw - mapping.inputMinimum)
                    / (mapping.inputMaximum - mapping.inputMinimum),
                0
            ), 1)
            let curved: Double
            switch mapping.curve {
            case .linear:
                curved = position
            case .easeIn:
                curved = position * position
            case .easeOut:
                curved = 1 - (1 - position) * (1 - position)
            case .easeInOut:
                curved = position * position * (3 - 2 * position)
            }
            return mapping.outputMinimum
                + curved * (mapping.outputMaximum - mapping.outputMinimum)
        }
    }

    private static func completeSource(
        extensionSource: String,
        fragmentFunction: String
    ) -> String {
        """
        #include <metal_stdlib>
        using namespace metal;

        struct ThreadingSurfaceUniforms {
            float2 size;
            float time;
            float _padding;
            float values[\(maximumInputs)];
        };

        struct ThreadingSurfaceVertexOut {
            float4 position [[position]];
            float2 uv;
        };

        vertex ThreadingSurfaceVertexOut \(hostVertexFunction)(uint vertexID [[vertex_id]]) {
            const float2 positions[3] = {
                float2(-1.0, -1.0),
                float2( 3.0, -1.0),
                float2(-1.0,  3.0)
            };
            ThreadingSurfaceVertexOut out;
            out.position = float4(positions[vertexID], 0.0, 1.0);
            out.uv = positions[vertexID] * float2(0.5, -0.5) + 0.5;
            return out;
        }

        \(extensionSource)

        fragment float4 \(hostFragmentFunction)(
            ThreadingSurfaceVertexOut in [[stage_in]],
            constant ThreadingSurfaceUniforms &uniforms [[buffer(0)]]
        ) {
            return \(fragmentFunction)(in.uv, uniforms);
        }
        """
    }
}
