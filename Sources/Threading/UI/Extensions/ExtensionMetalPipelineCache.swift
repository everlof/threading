import CryptoKit
import Metal

/// Metal pipeline objects are immutable after creation and may be shared across render threads.
struct ExtensionMetalPipeline: @unchecked Sendable {
    let device: MTLDevice
    let state: MTLRenderPipelineState
}

/// Two compilations at once, at most 32 pending distinct sources and 16 retained pipelines.
/// Identical requests share a task; failures are not cached. Neither compiler touches AppKit.
actor ExtensionMetalPipelineCache {
    static let shared = ExtensionMetalPipelineCache()
    private let maximumPending = 32
    private let maximumCached = 16
    private var cached: [String: ExtensionMetalPipeline] = [:]
    private var order: [String] = []
    private var pending: [String: Task<ExtensionMetalPipeline, Error>] = [:]
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    enum Failure: Error { case busy, unavailable, missingFunction }

    func prepare(source: String) async throws -> ExtensionMetalPipeline {
        let key = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        if let value = cached[key] {
            order.removeAll { $0 == key }; order.append(key)
            return value
        }
        if let task = pending[key] { return try await task.value }
        guard pending.count < maximumPending else { throw Failure.busy }
        let task = Task { try await self.compile(source: source) }
        pending[key] = task
        do {
            let value = try await task.value
            pending[key] = nil
            cached[key] = value
            order.append(key)
            while order.count > maximumCached { cached[order.removeFirst()] = nil }
            return value
        } catch {
            pending[key] = nil
            throw error
        }
    }

    private func compile(source: String) async throws -> ExtensionMetalPipeline {
        if active < 2 { active += 1 }
        else { await withCheckedContinuation { waiters.append($0) } }
        defer {
            if waiters.isEmpty { active -= 1 }
            else { waiters.removeFirst().resume() }
        }
        guard let device = MTLCreateSystemDefaultDevice() else { throw Failure.unavailable }
        let library = try await device.makeLibrary(source: source, options: nil)
        guard let vertex = library.makeFunction(name: "threadingHostSurfaceVertex"),
              let fragment = library.makeFunction(name: "threadingHostSurfaceFragment") else {
            throw Failure.missingFunction
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
        let state = try await device.makeRenderPipelineState(descriptor: descriptor)
        return ExtensionMetalPipeline(device: device, state: state)
    }
}
