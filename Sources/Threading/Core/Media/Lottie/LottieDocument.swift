import Foundation

/// A parsed Lottie (bodymovin) document.
///
/// **The engine is carried by the host, in-tree, deliberately.** The alternative considered was
/// vendoring a fifth Swift package; it was declined for this slice because it would add a large
/// unaudited dependency to a build whose other four packages are all forks we maintain, and
/// because the format's real hazards — expressions, external asset references, archive ceilings —
/// are host policy that would have to be enforced *around* such an engine anyway. Carrying a
/// bounded subset here keeps every refusal in one readable place, and the renderer registry means
/// swapping the engine later changes one file rather than the public contract.
///
/// The subset is stated rather than implied: shape layers, solids, nulls, precomps, embedded
/// images, additive masks. Anything outside it is **dropped and reported** through
/// `ExtensionMediaMetadata.notes`, never silently ignored — a document that quietly loses its text
/// layers is indistinguishable from a rendering bug.
struct LottieDocument: Sendable {

    /// What the host declined to honour, in the host's own vocabulary. Published to the extension
    /// as `metadata.notes`; the extension never learns what was in the document that caused it.
    struct Note: Sendable {
        static let expressionsDisabled = "expressions-disabled"
        static let externalAssetsDropped = "external-assets-dropped"
        static let textLayersDropped = "text-layers-dropped"
        static let effectsDropped = "effects-dropped"
        static let mattesDropped = "mattes-dropped"
        static let repeatersDropped = "repeaters-dropped"
        static let unsupportedLayersDropped = "unsupported-layers-dropped"
    }

    let frameRate: Double
    let inPoint: Double
    let outPoint: Double
    let width: Int
    let height: Int
    let layers: [LottieLayer]
    /// Precomposition assets, by id.
    let precomps: [String: [LottieLayer]]
    /// Embedded images, by asset id. A filesystem-relative reference is dropped at parse time.
    let images: [String: LottieImageAsset]
    let markers: [ExtensionMediaMarkerValue]
    let notes: [String]
    /// Every layer in the document and its precomps, so the ceiling counts what will be drawn.
    let totalLayerCount: Int

    var duration: Double {
        frameRate > 0 ? max(0, (outPoint - inPoint) / frameRate) : 0
    }

    var frameCount: Int {
        max(1, Int((outPoint - inPoint).rounded(.up)))
    }
}

/// A marker as a plain value, so the model stays free of the SDK's own types until it is reported.
struct ExtensionMediaMarkerValue: Sendable {
    let name: String
    let time: Double
    let duration: Double
}

struct LottieImageAsset: Sendable {
    let width: Int
    let height: Int
    /// Decoded from the document's own base64. A filesystem path is never resolved.
    let data: Data
}

struct LottieLayer: Sendable {
    enum Content: Sendable {
        case shapes([LottieShapeItem])
        case solid(color: LottieColor, width: Double, height: Double)
        case image(assetID: String)
        case precomp(assetID: String, width: Double, height: Double, timeRemap: LottieScalar?)
        case null
    }

    let index: Int
    let parentIndex: Int?
    let transform: LottieTransform
    let content: Content
    /// Frames, in the composition's own time.
    let inPoint: Double
    let outPoint: Double
    let startTime: Double
    let timeStretch: Double
    let isHidden: Bool
    /// Additive masks, intersected as a clip. Subtractive and other modes are dropped.
    let masks: [LottiePath]
    let blendsWithMatte: Bool
}

struct LottieTransform: Sendable {
    let anchor: LottieVector
    let position: LottieVector
    let scale: LottieVector
    let rotation: LottieScalar
    let opacity: LottieScalar
    let skew: LottieScalar?
    let skewAxis: LottieScalar?

    static let identity = LottieTransform(
        anchor: .constant([0, 0]),
        position: .constant([0, 0]),
        scale: .constant([100, 100]),
        rotation: .constant(0),
        opacity: .constant(100),
        skew: nil,
        skewAxis: nil
    )
}

indirect enum LottieShapeItem: Sendable {
    case group(items: [LottieShapeItem], transform: LottieTransform)
    case path(LottiePath)
    case rectangle(position: LottieVector, size: LottieVector, cornerRadius: LottieScalar)
    case ellipse(position: LottieVector, size: LottieVector)
    case polystar(LottiePolystar)
    case fill(LottieFill)
    case stroke(LottieStroke)
    case gradientFill(LottieGradient)
    /// A stroke painted with a gradient. Drawn by clipping the ramp to the stroke's own outline,
    /// which is what makes a gradient-stroked loading spinner — a common enough idiom that a real
    /// corpus has several — draw at all rather than silently nothing.
    case gradientStroke(LottieGradient, width: LottieScalar, lineCap: Int, lineJoin: Int)
    case trim(start: LottieScalar, end: LottieScalar, offset: LottieScalar, appliesToAll: Bool)
}

struct LottiePolystar: Sendable {
    let isStar: Bool
    let position: LottieVector
    let points: LottieScalar
    let rotation: LottieScalar
    let outerRadius: LottieScalar
    let innerRadius: LottieScalar?
    let outerRoundness: LottieScalar
    let innerRoundness: LottieScalar?
}

struct LottieFill: Sendable {
    let color: LottieColor
    let opacity: LottieScalar
    let isEvenOdd: Bool
}

struct LottieStroke: Sendable {
    let color: LottieColor
    let opacity: LottieScalar
    let width: LottieScalar
    let lineCap: Int
    let lineJoin: Int
    let miterLimit: Double
}

struct LottieGradient: Sendable {
    let isRadial: Bool
    let start: LottieVector
    let end: LottieVector
    let opacity: LottieScalar
    let stopCount: Int
    /// The ramp exactly as bodymovin flattens it: `stopCount` × (location, r, g, b), optionally
    /// followed by (location, alpha) pairs.
    ///
    /// Kept animatable rather than resolved at parse time because **real documents animate it** —
    /// a static read showed a blank rectangle for every gradient whose colours move, which is a
    /// common enough authoring idiom that a corpus of a hundred real files caught it twice.
    /// Componentwise interpolation over the flattened array is exactly what the format means.
    let ramp: LottieVector
}

// MARK: - Animatable values

/// One keyframe and the easing into it.
struct LottieKeyframe<Value: Sendable>: Sendable {
    let time: Double
    let value: Value
    let endValue: Value?
    /// Cubic-bezier control points for the ease out of this keyframe and into the next.
    let outControl: CGPoint?
    let inControl: CGPoint?
    let isHold: Bool
}

/// A property that is either fixed or driven by keyframes.
enum LottieAnimated<Value: Sendable>: Sendable {
    case fixed(Value)
    case keyframes([LottieKeyframe<Value>])
}

typealias LottieScalar = LottieAnimated<Double>
typealias LottieVector = LottieAnimated<[Double]>
typealias LottieColor = LottieAnimated<[Double]>
typealias LottiePath = LottieAnimated<LottieBezier>

extension LottieAnimated {
    static func constant(_ value: Value) -> Self { .fixed(value) }
}

/// A closed or open bezier, in the layer's own coordinate space.
struct LottieBezier: Sendable {
    /// Vertices.
    var vertices: [CGPoint]
    /// In tangents, relative to their vertex.
    var inTangents: [CGPoint]
    /// Out tangents, relative to their vertex.
    var outTangents: [CGPoint]
    var isClosed: Bool

    static let empty = LottieBezier(
        vertices: [],
        inTangents: [],
        outTangents: [],
        isClosed: false
    )
}
