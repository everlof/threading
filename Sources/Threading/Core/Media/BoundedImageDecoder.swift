import AppKit
import ImageIO

/// A named memory and file boundary for an image decode.
///
/// Compressed bytes and either pixel dimension alone are insufficient: a narrow image can pass
/// an area limit while a square decompression bomb passes a byte limit. Keeping all four values
/// together makes a caller choose one complete policy rather than remember a sequence of guards.
struct BoundedImageDecodePolicy: Equatable, Sendable {
    let maximumBytes: Int
    let maximumSourcePixelDimension: Int
    let maximumSourcePixelCount: Int
    let maximumRenderedPixelDimension: Int

    static let userMedia = Self(
        maximumBytes: MCPDefaults.maximumImageBytes,
        maximumSourcePixelDimension: MCPDefaults.maximumImagePixelDimension,
        maximumSourcePixelCount: MCPDefaults.maximumImagePixelCount,
        maximumRenderedPixelDimension: MCPDefaults.maximumImagePixelDimension
    )

    static let composerPreview = Self(
        maximumBytes: 32 * 1_024 * 1_024,
        maximumSourcePixelDimension: MCPDefaults.maximumImagePixelDimension,
        maximumSourcePixelCount: MCPDefaults.maximumImagePixelCount,
        maximumRenderedPixelDimension: 4_096
    )

    /// The composer rail never needs inspector-sized pixels. Keeping its own render bound makes
    /// each queued decode cheap enough to hand back to the main actor as one finished frame.
    static let composerAttachmentThumbnail = Self(
        maximumBytes: 32 * 1_024 * 1_024,
        maximumSourcePixelDimension: MCPDefaults.maximumImagePixelDimension,
        maximumSourcePixelCount: MCPDefaults.maximumImagePixelCount,
        maximumRenderedPixelDimension: 512
    )

    /// Private report previews travel as small JPEGs. Decode no more than the backend can use.
    static let issueReportPreview = Self(
        maximumBytes: composerPreview.maximumBytes,
        maximumSourcePixelDimension: MCPDefaults.maximumImagePixelDimension,
        maximumSourcePixelCount: MCPDefaults.maximumImagePixelCount,
        maximumRenderedPixelDimension: 480
    )

    static func thumbnail(maximumPixelDimension: Int) -> Self {
        Self(
            maximumBytes: MCPDefaults.maximumImageBytes,
            maximumSourcePixelDimension: MCPDefaults.maximumImagePixelDimension,
            maximumSourcePixelCount: MCPDefaults.maximumImagePixelCount,
            maximumRenderedPixelDimension: maximumPixelDimension
        )
    }
}

/// Opens an image under a `BoundedImageDecodePolicy` and returns an eagerly decoded frame.
enum BoundedImageDecoder {
    static func image(at url: URL, policy: BoundedImageDecodePolicy) -> NSImage? {
        guard let data = try? BoundedFileReader.read(
            url,
            maximumBytes: policy.maximumBytes
        ), let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = decodedFrame(from: source, policy: policy) else {
            return nil
        }
        return NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )
    }

    /// A list-safe thumbnail path. The decoded allocation is authoritatively bounded by ImageIO's
    /// thumbnail size and the source dimensions are inspected before decode. Its file-size check
    /// is deliberately only a cheap refusal: reading every 64 MiB attachment into `Data` while
    /// building a 32-row rail would turn a memory-safety rule into a predictable UI stall. The
    /// selected/full-size path above performs the one-byte-past authoritative read.
    static func thumbnail(at url: URL, policy: BoundedImageDecodePolicy) -> NSImage? {
        guard let image = thumbnailFrame(at: url, policy: policy) else { return nil }
        return NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )
    }

    /// A worker-safe thumbnail result for callers that must keep ImageIO source inspection and
    /// rasterization off the main actor. `CGImage` is immutable; AppKit wrapping and view
    /// installation remain the caller's main-actor work.
    static func thumbnailFrame(at url: URL, policy: BoundedImageDecodePolicy) -> CGImage? {
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .fileSizeKey]
        ), values.isRegularFile == true,
              (values.fileSize ?? Int.max) <= policy.maximumBytes,
              let source = CGImageSourceCreateWithURL(
                  url as CFURL,
                  [kCGImageSourceShouldCache: false] as CFDictionary
              ) else {
            return nil
        }
        return decodedFrame(from: source, policy: policy)
    }

    /// The same bounded thumbnail decode for bytes a caller has already read and authenticated.
    ///
    /// Baseline-library rows use the store's hash-verifying read before reaching this overload:
    /// going back through the URL would either skip that integrity check or read the screenshot a
    /// second time. ImageIO still owns the rendered-size bound, so an approved full-page capture
    /// cannot become a full-size bitmap merely because it is shown in a list.
    static func thumbnail(_ data: Data, policy: BoundedImageDecodePolicy) -> NSImage? {
        guard let image = thumbnailFrame(data, policy: policy) else { return nil }
        return NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )
    }

    static func thumbnailFrame(_ data: Data, policy: BoundedImageDecodePolicy) -> CGImage? {
        guard data.count <= policy.maximumBytes,
              let source = CGImageSourceCreateWithData(
                  data as CFData,
                  [kCGImageSourceShouldCache: false] as CFDictionary
              ) else {
            return nil
        }
        return decodedFrame(from: source, policy: policy)
    }

    private static func decodedFrame(
        from source: CGImageSource,
        policy: BoundedImageDecodePolicy
    ) -> CGImage? {
        guard CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              accepts(width: width.intValue, height: height.intValue, policy: policy),
              let decoded = CGImageSourceCreateThumbnailAtIndex(
                  source,
                  0,
                  [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize:
                          policy.maximumRenderedPixelDimension
                  ] as CFDictionary
              ) else {
            return nil
        }
        return decoded
    }

    private static func accepts(
        width: Int,
        height: Int,
        policy: BoundedImageDecodePolicy
    ) -> Bool {
        guard width > 0,
              height > 0,
              width <= policy.maximumSourcePixelDimension,
              height <= policy.maximumSourcePixelDimension else {
            return false
        }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        return !overflow && pixels <= policy.maximumSourcePixelCount
    }
}
