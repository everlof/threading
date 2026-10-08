import Foundation

/// CoreSimulator's screen UI orientation values, confirmed against the active screen properties.
/// The guest framebuffer keeps its native axes even when UIKit presents a landscape scene.
public enum SimulatorScreenOrientation: Int, Codable, CaseIterable, Sendable {
    case portrait = 1
    case portraitUpsideDown = 2
    case landscapeLeft = 3
    case landscapeRight = 4

    public var swapsAxes: Bool { self == .landscapeLeft || self == .landscapeRight }

    /// vImage's number of counterclockwise quarter turns for upright displayed pixels.
    public var counterclockwiseQuarterTurns: UInt8 {
        switch self {
        case .portrait: 0
        case .portraitUpsideDown: 2
        case .landscapeLeft: 3
        case .landscapeRight: 1
        }
    }

    /// A point in the upright display back to the guest's native digitizer coordinate space.
    public func nativePoint(x: Double, y: Double) -> (x: Double, y: Double) {
        switch self {
        case .portrait: (x, y)
        case .portraitUpsideDown: (1 - x, 1 - y)
        case .landscapeLeft: (y, 1 - x)
        case .landscapeRight: (1 - y, x)
        }
    }

    public func uprightPoint(x: Double, y: Double) -> (x: Double, y: Double) {
        switch self {
        case .portrait: (x, y)
        case .portraitUpsideDown: (1 - x, 1 - y)
        case .landscapeLeft: (1 - y, x)
        case .landscapeRight: (y, 1 - x)
        }
    }

    /// Relative aspect difference still read as the same display space. Point sizes are not an
    /// exact division of every framebuffer (a 375×812-point screen on a 1080×2340 buffer).
    private static let accessibilityAspectTolerance = 0.02

    /// UIKit application trees use upright logical axes; a system-owned portrait scene may
    /// still use native axes over a landscape app. Without a quarter turn both spaces share one
    /// set of axes, so the tree is used as it is, whatever its root covers (iPad multitasking,
    /// a missing frame). With one, admit only a root matching a known full display space rather
    /// than guessing from arbitrary element bounds.
    public func accessibilityTransform(rootWidth: Double, rootHeight: Double,
                                       nativeWidth: Double, nativeHeight: Double) -> Self? {
        guard swapsAxes else { return .portrait }
        guard rootWidth > 0, rootHeight > 0, nativeWidth > 0, nativeHeight > 0 else { return nil }
        let root = rootWidth / rootHeight
        let native = nativeWidth / nativeHeight
        func matches(_ aspect: Double) -> Bool {
            abs(root - aspect) / aspect < Self.accessibilityAspectTolerance
        }
        if matches(1 / native) { return .portrait }
        if matches(native) { return self }
        return nil
    }

    /// Native accessibility bounds expressed in the same upright axes as the delivered frame.
    public func uprightRect(x: Double, y: Double, width: Double, height: Double,
                            nativeWidth: Double, nativeHeight: Double) -> (x: Double, y: Double, width: Double, height: Double) {
        switch self {
        case .portrait: (x, y, width, height)
        case .portraitUpsideDown: (nativeWidth - x - width, nativeHeight - y - height, width, height)
        case .landscapeLeft: (nativeHeight - y - height, x, height, width)
        case .landscapeRight: (y, nativeWidth - x - width, height, width)
        }
    }
}

extension SimulatorBridgeInput {
    /// A user may click a raw public fallback frame just before the recovered helper publishes
    /// an upright frame. Preserve the native target instead of interpreting the old point in
    /// the new axes. Agent coordinates already belong to their live snapshot and skip this.
    public func convertingCoordinates(from source: SimulatorScreenOrientation,
                                      to target: SimulatorScreenOrientation) -> Self {
        guard source != target else { return self }
        func point(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
            let native = source.nativePoint(x: x, y: y)
            return target.uprightPoint(x: native.x, y: native.y)
        }
        switch self {
        case .tap(let x, let y):
            let value = point(x, y)
            return .tap(x: value.x, y: value.y)
        case .touch(let phase, let x, let y):
            let value = point(x, y)
            return .touch(phase: phase, x: value.x, y: value.y)
        case .drag(let fromX, let fromY, let toX, let toY, let duration):
            let start = point(fromX, fromY), end = point(toX, toY)
            return .drag(fromX: start.x, fromY: start.y, toX: end.x, toY: end.y, durationMilliseconds: duration)
        case .text, .button: return self
        }
    }
}
