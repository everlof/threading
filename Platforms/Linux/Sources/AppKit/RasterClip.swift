import Foundation

/// A clip occupies only the device pixels its path can touch. Navigator rows are a few dozen
/// pixels tall inside a much larger window; keeping a full-window CGFloat array for every
/// saved graphics state made their draw cost scale with the whole window.
struct RasterClip {
    let originX: Int
    let originY: Int
    let width: Int
    let height: Int
    let pixels: [CGFloat]

    static let empty = RasterClip(originX: 0, originY: 0, width: 0, height: 0, pixels: [])

    @inline(__always)
    func coverage(x: Int, y: Int) -> CGFloat {
        guard x >= originX, y >= originY, x < originX + width, y < originY + height else { return 0 }
        return pixels[(y - originY) * width + x - originX]
    }
}
