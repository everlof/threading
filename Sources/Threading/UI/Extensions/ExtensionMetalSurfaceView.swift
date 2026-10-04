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
/// command queue, drawable, uniform buffer, frame cadence, transparency and input mapping —
/// and, when the surface names a package picture, the texture and its sampler. No Metal or
/// AppKit object crosses the extension process boundary.
@MainActor
final class ExtensionMetalSurfaceView: MTKView, MTKViewDelegate, ThemeParticleHolding {
    /// Answers one signal for a surface drawn in `context`. The context carries the surface's
    /// own appearance, which is what lets an adaptive theme answer each window for itself.
    typealias SignalProvider = @MainActor (
        ExtensionHostSignal,
        ExtensionHostSignalContext
    ) -> Double?

    private static let maximumInputs = 8
    private static let hostVertexFunction = "threadingHostSurfaceVertex"
    private static let hostFragmentFunction = "threadingHostSurfaceFragment"
    /// Where a textured surface's picture and sampler are bound — the ABI the SDK documents.
    private static let imageTextureIndex = 0
    private static let imageSamplerIndex = 0

    private let specification: ExtensionMetalSurface
    private let signalProvider: SignalProvider
    private let commandQueue: MTLCommandQueue
    private var pipeline: MTLRenderPipelineState?
    private var preparation: Task<Void, Never>?
    private var preparationFailure: Error?

    /// Authoring/render fixtures await readiness; ordinary hosts keep the transparent slot
    /// until compilation finishes and never block their mount on the compiler.
    func waitForPreparation() async throws {
        await preparation?.value
        if let preparationFailure { throw preparationFailure }
    }
    private let beganAt = ProcessInfo.processInfo.systemUptime
    private let audioDemand: AudioSpectrumDemand?
    private var audioViewportObserver: AudioSpectrumViewportObserver?
    /// Held while the surface binds a moment signal and is mounted in a window — what keeps
    /// the moment reader, and through it the mood monitor, listening on this surface's behalf.
    private let momentDemand: ExtensionMomentDemand?
    /// The appearance every signal read is answered for, cached so a frame walks no view
    /// hierarchy. Refreshed when the view's effective appearance or its window changes.
    private var signalContext = ExtensionHostSignalContext.application
    /// The sampler a textured surface's picture is read through; nil without a texture.
    private let imageSampler: MTLSamplerState?
    /// The picture bound at texture index 0: a transparent pixel until `installTexture` lands
    /// the real one. Nil for a surface without a texture.
    private var imageTexture: MTLTexture?
    /// Whether the package picture — not the placeholder — is what the surface samples.
    private(set) var showsTexture = false
    /// Whether the view has decided to hold its frames because nobody could see them.
    ///
    /// Separate from `isPaused` so a test can ask *why* the view is paused, and so the
    /// visibility rule below is the one owner of that flag rather than one of several writers.
    private(set) var isHeldForVisibility = false

    /// `maximumFramesPerSecond` is the host's ceiling for this placement — a contract may state
    /// one below the SDK's 60, and the sidebar backdrop does — clamped here so the view a
    /// surface gets can never outrun the promise its catalogue entry made.
    init(
        specification: ExtensionMetalSurface,
        source: String,
        maximumFramesPerSecond: Int = ExtensionMetalSurface.maximumFramesPerSecond,
        signalProvider: @escaping SignalProvider
    ) throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw ExtensionMetalSurfaceError.metalUnavailable
        }
        self.specification = specification
        let boundSignals = specification.inputs.compactMap { input -> ExtensionHostSignal? in
            if case .signal(let signal, _) = input.value { return signal }
            return nil
        }
        self.audioDemand = boundSignals.contains(where: \.requiresAudioCapture)
            ? AudioSpectrumDemand()
            : nil
        self.momentDemand = boundSignals.contains(where: Self.isMomentSignal)
            ? ExtensionMomentDemand()
            : nil
        self.signalProvider = signalProvider
        self.commandQueue = commandQueue
        if specification.texture != nil {
            guard let sampler = ExtensionSurfaceTexture.sampler(device: device),
                  let placeholder = ExtensionSurfaceTexture.placeholder(device: device) else {
                throw ExtensionMetalSurfaceError.metalUnavailable
            }
            imageSampler = sampler
            imageTexture = placeholder
        } else {
            imageSampler = nil
            imageTexture = nil
        }

        super.init(frame: .zero, device: device)
        delegate = self
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        framebufferOnly = true
        enableSetNeedsDisplay = false
        isPaused = false
        preferredFramesPerSecond = max(
            1,
            min(specification.preferredFramesPerSecond, maximumFramesPerSecond)
        )
        wantsLayer = true
        layer?.isOpaque = false
        setAccessibilityElement(false)
        signalContext = ExtensionHostSignalContext(appearance: effectiveAppearance)
        if audioDemand != nil { ThemeParticleHold.shared.register(self) }
        let completeSource = Self.completeSource(extensionSource: source,
            fragmentFunction: specification.fragmentFunction, isTextured: specification.texture != nil)
        preparation = Task { [weak self] in
            do {
                let compiled = try await ExtensionMetalPipelineCache.shared.prepare(source: completeSource)
                guard let self else { return }
                self.pipeline = compiled.state
                self.updateVisibilityHold()
                self.needsDisplay = true
            } catch {
                ThreadingLogger.extensions.error(
                    "Could not compile Metal surface: \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
                self?.withdraw(after: error)
            }
        }
        updateVisibilityHold()
    }

    /// A shader that will not compile leaves nothing to draw. Before compilation moved off the
    /// main actor the initializer threw and the host skipped the hook; now the mounted surface
    /// withdraws itself to the same effect — hidden, paused, and holding no audio-capture or
    /// moment demand, so a dead surface can never keep the system-audio tap running.
    private func withdraw(after error: Error) {
        preparationFailure = error
        isHidden = true
        isPaused = true
        audioDemand?.setActive(false)
        momentDemand?.setActive(false)
    }

    /// Whether compilation failed and the surface withdrew itself.
    var hasWithdrawn: Bool { preparationFailure != nil }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { false }

    /// Visual surfaces are passive. Controls in the next hook or native view remain hittable.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    // MARK: - Visibility

    /// A surface draws only while somebody could see it. An occluded or miniaturized window, or
    /// a hidden ancestor, holds the frames; the clock keeps running through the hold, so the
    /// animation resumes where time is rather than where it stopped — the media player's rule,
    /// for the same reason. A view in no window is held too, which is what an offscreen fixture
    /// is; `snapshotImage` draws on request regardless.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if audioDemand != nil {
            audioViewportObserver = AudioSpectrumViewportObserver(view: self) { [weak self] in
                self?.updateVisibilityHold()
            }
        }
        NotificationCenter.default.removeObserver(self)
        // Moments are wanted only while somebody has mounted this surface in a window, and only
        // from a surface that can draw them.
        momentDemand?.setActive(window != nil && preparationFailure == nil)
        signalContext = ExtensionHostSignalContext(appearance: effectiveAppearance)
        if let window {
            for name in [
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification
            ] {
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(windowVisibilityChanged),
                    name: name,
                    object: window
                )
            }
        }
        updateVisibilityHold()
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateVisibilityHold()
    }

    /// The theme readings answer for the appearance this surface is drawn in; a window moving
    /// between light and dark, or an ancestor stating its own appearance, changes the answer.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        signalContext = ExtensionHostSignalContext(appearance: effectiveAppearance)
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateVisibilityHold()
    }

    @objc private func windowVisibilityChanged() {
        updateVisibilityHold()
    }

    /// Re-decides the hold from the window and the view's own hidden state. Exposed so a test
    /// can drive it through a posted notification without a display.
    func updateVisibilityHold() {
        let windowVisible = window.map {
            $0.occlusionState.contains(.visible) && !$0.isMiniaturized
        } ?? false
        isHeldForVisibility = !windowVisible || isHiddenOrHasHiddenAncestor
        let holdsAudioMotion = audioDemand != nil && !ThemeParticleHold.motionAllowed
        let wasPaused = isPaused
        isPaused = pipeline == nil || isHeldForVisibility || holdsAudioMotion
            || (audioDemand != nil && !AudioSpectrumViewportObserver.intersectsViewport(self))
        // No capture before the pipeline exists: a surface still compiling, or one that failed,
        // has nothing to draw the reading into.
        audioDemand?.setActive(pipeline != nil && !isHeldForVisibility && ThemeParticleHold.motionAllowed
                               && ThemeParticleHold.isSeen(self)
                               && AudioSpectrumViewportObserver.intersectsViewport(self))
        if holdsAudioMotion, !isHeldForVisibility, !wasPaused { draw() }
    }

    func refreshParticleMotion() { updateVisibilityHold() }

    // MARK: - Texture

    /// Swaps the placeholder for the surface's package picture. Returns false — and keeps the
    /// placeholder, so the surface draws on — when the surface states no texture or the upload
    /// fails. Called on the main actor once a worker has read and decoded the picture.
    @discardableResult
    func installTexture(_ pixels: ExtensionSurfaceTexturePixels) -> Bool {
        guard specification.texture != nil,
              let device,
              let texture = ExtensionSurfaceTexture.make(pixels, device: device) else {
            return false
        }
        imageTexture = texture
        showsTexture = true
        return true
    }

    override func layout() {
        super.layout()
        updateVisibilityHold()
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
        guard commandBuffer.status == .completed else { return nil }

        let bytesPerRow = pixelWidth * Self.snapshotBytesPerPixel
        var bytes = Data(count: bytesPerRow * pixelHeight)
        bytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            texture.getBytes(
                base,
                bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, pixelWidth, pixelHeight),
                mipmapLevel: 0
            )
        }
        // `bgra8Unorm` is one little-endian, alpha-first, premultiplied word per pixel, and that
        // is stated to Core Graphics directly. `NSBitmapImageRep`'s own initializer silently
        // drops `.thirtyTwoBitLittleEndian` and reads the same bytes as big-endian ARGB — an
        // opaque red came back transparent and blue stood in for alpha.
        guard let provider = CGDataProvider(data: bytes as CFData),
              let rendered = CGImage(
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: Self.snapshotBitsPerComponent,
                bitsPerPixel: Self.snapshotBytesPerPixel * Self.snapshotBitsPerComponent,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue
                ),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            return nil
        }
        let representation = NSBitmapImageRep(cgImage: rendered)
        representation.size = size
        let image = NSImage(size: size)
        image.addRepresentation(representation)
        return image
    }

    private static let snapshotBytesPerPixel = 4
    private static let snapshotBitsPerComponent = 8

    private func encode(
        pass: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer,
        size: CGSize,
        time: Float
    ) -> Bool {
        guard let pipeline, let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            return false
        }
        var uniforms = uniformFloats(size: size, time: time)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(
            &uniforms,
            length: uniforms.count * MemoryLayout<Float>.stride,
            index: 0
        )
        if let imageTexture, let imageSampler {
            encoder.setFragmentTexture(imageTexture, index: Self.imageTextureIndex)
            encoder.setFragmentSamplerState(imageSampler, index: Self.imageSamplerIndex)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return true
    }

    private func uniformFloats(size: CGSize, time: Float) -> [Float] {
        var result: [Float] = [
            Float(size.width),
            Float(size.height),
            audioDemand != nil && !ThemeParticleHold.motionAllowed ? 0 : time,
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

    /// `measured` as decoration should answer it (`ThemeReactions`), or nil when the person has
    /// turned activity reactions off and the signal is one. Music scales by strength (its on/off
    /// is capture consent, upstream); counts scale as counts; facts — `audio.available`, the
    /// theme, the clock, the account — pass through.
    static func reacted(_ signal: ExtensionHostSignal, _ measured: Double) -> Double? {
        guard signal.isReactive else { return measured }
        if signal.requiresAudioCapture { return ThemeReactions.scaledMusic(measured) }
        return signal == .workloadWorkingCount
            ? ThemeReactions.activityCount(measured)
            : ThemeReactions.activity(measured)
    }

    private func resolve(_ scalar: ExtensionSurfaceScalar) -> Double {
        switch scalar {
        case .constant(let value):
            return value
        case .signal(let signal, let mapping):
            // Sound and app moments are motion: with motion held they read their fallback, as
            // the surface's clock stops.
            if signal.requiresAudioCapture || Self.isMomentSignal(signal),
               !ThemeParticleHold.motionAllowed {
                return mapping.fallback
            }
            // A reactive reading — agent work, music, a moment — answers through the person's
            // reaction settings before the extension's own mapping sees it; activity reactions
            // turned off read as no reading, the binding's idle fallback.
            guard let measured = signalProvider(signal, signalContext),
                  let raw = Self.reacted(signal, measured) else { return mapping.fallback }
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

    private static func isMomentSignal(_ signal: ExtensionHostSignal) -> Bool {
        ExtensionHostSignal.momentSignals.contains(signal)
    }

    /// The extension's source between the host's vertex stage and the host's fragment wrapper.
    ///
    /// A textured surface's wrapper takes the picture and its sampler at index 0 and passes them
    /// on as the author's third and fourth arguments; an untextured one keeps the two-argument
    /// call every surface written before textures existed was compiled against.
    static func completeSource(extensionSource: String, fragmentFunction: String, isTextured: Bool) -> String {
        ExtensionMetalSource.completeSource(extensionSource: extensionSource,
            fragmentFunction: fragmentFunction, isTextured: isTextured)
    }

}
