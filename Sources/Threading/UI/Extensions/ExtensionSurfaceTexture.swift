import CoreGraphics
import Foundation
import Metal

/// One package picture prepared for a custom surface: RGBA8 rows, top row first, sRGB-encoded,
/// with straight (not premultiplied) alpha.
///
/// **Why straight alpha.** The surface's pipeline blends its fragment output with
/// `sourceAlpha, oneMinusSourceAlpha`, so a fragment function returns straight colour and the
/// framebuffer ends up premultiplied. A texture sampled and returned as-is must arrive in the
/// same convention, or every translucent edge of a picture would be darkened twice. Core
/// Graphics only draws 8-bit RGBA premultiplied, so the worker divides it back out once.
///
/// **Why sRGB-encoded and `rgba8Unorm`.** The surface renders into a `bgra8Unorm` drawable and
/// every value it is handed — the theme's colours included — is an sRGB-encoded component, so
/// the texture is converted *into* sRGB when it is drawn and sampled without a decode. A Display
/// P3 or grey PNG arrives in the same space as everything else the shader mixes it with.
///
/// Prepared entirely off the main actor: the bounded read and the decode happen on a worker
/// (`ExtensionManager.prepareCustomSurfaceTexture`), and only the upload — at most 4 MiB, once
/// per surface build — runs on the main actor.
struct ExtensionSurfaceTexturePixels: Sendable, Equatable {
    static let bytesPerPixel = 4

    let width: Int
    let height: Int
    /// `width * height * bytesPerPixel` bytes, top row first.
    let bytes: Data

    /// Decodes package image bytes through the shared bounded decode boundary. Call it on a
    /// worker; nothing here touches AppKit.
    nonisolated static func prepared(fromImageData data: Data) -> ExtensionSurfaceTexturePixels? {
        guard let image = ExtensionImageResourceLoader.decodedImage(from: data) else { return nil }
        return pixels(from: image)
    }

    /// Draws `image` into straight-alpha sRGB RGBA8, refusing anything past the package image
    /// pixel ceiling.
    nonisolated static func pixels(from image: CGImage) -> ExtensionSurfaceTexturePixels? {
        let width = image.width
        let height = image.height
        let maximum = ExtensionImageResourcePolicy.maximumPixelDimension
        guard (1...maximum).contains(width),
              (1...maximum).contains(height),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let bytesPerRow = width * bytesPerPixel
        var bytes = Data(count: bytesPerRow * height)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            unpremultiply(buffer.bindMemory(to: UInt8.self))
            return true
        }
        guard drawn else { return nil }
        return ExtensionSurfaceTexturePixels(width: width, height: height, bytes: bytes)
    }

    /// Divides premultiplied RGBA8 back to straight colour, rounding to nearest. A fully
    /// transparent pixel has no colour to recover and stays zero.
    private nonisolated static func unpremultiply(_ pixels: UnsafeMutableBufferPointer<UInt8>) {
        let opaque = Int(UInt8.max)
        var offset = 0
        while offset + bytesPerPixel <= pixels.count {
            let alpha = Int(pixels[offset + 3])
            if alpha != opaque {
                for channel in 0..<3 {
                    let value = alpha == 0
                        ? 0
                        : min((Int(pixels[offset + channel]) * opaque + alpha / 2) / alpha, opaque)
                    pixels[offset + channel] = UInt8(value)
                }
            }
            offset += bytesPerPixel
        }
    }
}

/// The Metal half: the uploaded texture, the placeholder bound until it arrives, and the
/// sampler every textured surface is handed.
@MainActor
enum ExtensionSurfaceTexture {

    /// Uploads prepared pixels as a read-only `rgba8Unorm` texture.
    static func make(_ pixels: ExtensionSurfaceTexturePixels, device: MTLDevice) -> MTLTexture? {
        upload(
            pixels.bytes,
            width: pixels.width,
            height: pixels.height,
            device: device
        )
    }

    /// One transparent pixel: what a textured surface samples before its picture arrives, and
    /// for good when the picture cannot be read. Sampling it reads `float4(0)`.
    static func placeholder(device: MTLDevice) -> MTLTexture? {
        upload(
            Data(count: ExtensionSurfaceTexturePixels.bytesPerPixel),
            width: 1,
            height: 1,
            device: device
        )
    }

    /// Linear filtering, clamped at the edges, no mipmaps — a picture stretched over a plane.
    static func sampler(device: MTLDevice) -> MTLSamplerState? {
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.mipFilter = .notMipmapped
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        return device.makeSamplerState(descriptor: descriptor)
    }

    private static func upload(
        _ bytes: Data,
        width: Int,
        height: Int,
        device: MTLDevice
    ) -> MTLTexture? {
        let bytesPerRow = width * ExtensionSurfaceTexturePixels.bytesPerPixel
        guard bytes.count == bytesPerRow * height else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: bytesPerRow
            )
        }
        return texture
    }
}
