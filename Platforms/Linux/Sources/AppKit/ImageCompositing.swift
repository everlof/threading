import Foundation

extension Bitmap {
    /// Geometry coverage is separate from source alpha: a transparent source-in erases the
    /// covered destination, whereas a transparent source-over leaves it alone.
    func composite(x: Int, y: Int, color: (CGFloat, CGFloat, CGFloat, CGFloat),
                   coverage: CGFloat, operation: NSGraphicsContext.CompositingOperation) {
        let amount = max(0, min(1, coverage))
        let sourceAlpha = max(0, min(1, color.3))
        switch operation {
        case .sourceOver:
            blend(x: x, y: y, red: color.0, green: color.1, blue: color.2,
                  coverage: sourceAlpha * amount)
        case .sourceIn:
            withMutablePixels { pixels in
                let offset = (y * width + x) * 4
                let destinationAlpha = CGFloat(pixels[offset + 3]) / 255
                let incoming = sourceAlpha * destinationAlpha * amount
                let retained = destinationAlpha * (1 - amount)
                let outputAlpha = incoming + retained
                func channel(_ source: CGFloat, _ old: UInt8) -> UInt8 {
                    guard outputAlpha > 0 else { return 0 }
                    let value = (source * incoming + CGFloat(old) / 255 * retained) / outputAlpha
                    return UInt8(max(0, min(255, (value * 255).rounded())))
                }
                pixels[offset] = channel(color.0, pixels[offset])
                pixels[offset + 1] = channel(color.1, pixels[offset + 1])
                pixels[offset + 2] = channel(color.2, pixels[offset + 2])
                pixels[offset + 3] = UInt8(max(0, min(255, (outputAlpha * 255).rounded())))
            }
        case .copy:
            // Copy replaces even an opaque destination with transparent source pixels. Edge
            // coverage remains a geometric mask, so only its uncovered fraction survives.
            withMutablePixels { pixels in
                let offset = (y * width + x) * 4
                let oldAlpha = CGFloat(pixels[offset + 3]) / 255
                let incoming = sourceAlpha * amount
                let retained = oldAlpha * (1 - amount)
                let outputAlpha = incoming + retained
                func channel(_ source: CGFloat, _ old: UInt8) -> UInt8 {
                    guard outputAlpha > 0 else { return 0 }
                    let value = (source * incoming + CGFloat(old) / 255 * retained) / outputAlpha
                    return UInt8(max(0, min(255, (value * 255).rounded())))
                }
                pixels[offset] = channel(color.0, pixels[offset])
                pixels[offset + 1] = channel(color.1, pixels[offset + 1])
                pixels[offset + 2] = channel(color.2, pixels[offset + 2])
                pixels[offset + 3] = UInt8(max(0, min(255, (outputAlpha * 255).rounded())))
            }
        case .plusLighter:
            preconditionFailure("image compositing does not support plusLighter")
        }
    }
}
