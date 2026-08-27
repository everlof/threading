import CoreGraphics
import Foundation

/// Turns bodymovin JSON into the bounded value model the rasterizer draws.
///
/// Three format hazards are handled here rather than downstream, because downstream is too late:
///
/// - **Expressions.** Lottie's expression subset is a scripting surface. Any property carrying one
///   is read as its static value and the document is marked `expressions-disabled`.
/// - **External assets.** A bare Lottie may name an image by relative path. An untrusted document
///   from an agent must not become an arbitrary file read, so only an embedded base64 asset is
///   decoded; a filesystem reference is dropped and reported.
/// - **Ceilings.** Layer count, pixel dimensions, frame count and duration are checked before a
///   single path is built.
enum LottieParser {

    static func parse(
        _ data: Data,
        limits: MediaDocumentLimits,
        embeddedImages: [String: Data] = [:]
    ) throws -> LottieDocument {
        guard data.count <= limits.maximumDocumentBytes else {
            throw MediaDocumentFailure.exceedsLimits(L10n.format(
                "The document is larger than the %@ this player accepts.",
                ByteCountFormatter.string(
                    fromByteCount: Int64(limits.maximumDocumentBytes),
                    countStyle: .binary
                )
            ))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            throw MediaDocumentFailure.invalidDocument(
                L10n.string("The animation is not a readable Lottie document.")
            )
        }
        guard let rawLayers = root["layers"] as? [[String: Any]],
              let frameRate = number(root["fr"]), frameRate > 0 else {
            throw MediaDocumentFailure.invalidDocument(
                L10n.string("The animation is missing its frame rate or layers.")
            )
        }

        let width = Int(number(root["w"]) ?? 0)
        let height = Int(number(root["h"]) ?? 0)
        guard width > 0, height > 0 else {
            throw MediaDocumentFailure.invalidDocument(
                L10n.string("The animation has no readable size.")
            )
        }
        guard width <= limits.maximumPixelDimension, height <= limits.maximumPixelDimension else {
            throw MediaDocumentFailure.exceedsLimits(L10n.format(
                "The animation is larger than the %lld-pixel limit on either axis.",
                Int64(limits.maximumPixelDimension)
            ))
        }

        let inPoint = number(root["ip"]) ?? 0
        let outPoint = number(root["op"]) ?? 0
        guard outPoint > inPoint else {
            throw MediaDocumentFailure.invalidDocument(
                L10n.string("The animation's out point is not after its in point.")
            )
        }
        let frameCount = outPoint - inPoint
        guard Int(frameCount.rounded(.up)) <= limits.maximumFrameCount else {
            throw MediaDocumentFailure.exceedsLimits(L10n.format(
                "The animation has more than the %lld frames this player accepts.",
                Int64(limits.maximumFrameCount)
            ))
        }
        guard frameCount / frameRate <= limits.maximumDurationSeconds else {
            throw MediaDocumentFailure.exceedsLimits(L10n.format(
                "The animation is longer than the %lld seconds this player accepts.",
                Int64(limits.maximumDurationSeconds)
            ))
        }

        let assets = (root["assets"] as? [[String: Any]]) ?? []
        var remainingLayerCapacity = limits.maximumLayerCount
        try reserveLayerCapacity(
            rawLayers.count,
            remaining: &remainingLayerCapacity,
            limit: limits.maximumLayerCount
        )
        for asset in assets {
            guard asset["id"] is String,
                  let assetLayers = asset["layers"] as? [[String: Any]] else { continue }
            try reserveLayerCapacity(
                assetLayers.count,
                remaining: &remainingLayerCapacity,
                limit: limits.maximumLayerCount
            )
        }

        var context = Context(limits: limits, embeddedImages: embeddedImages)
        for asset in assets {
            guard let id = asset["id"] as? String else { continue }
            if let assetLayers = asset["layers"] as? [[String: Any]] {
                context.precomps[id] = assetLayers.compactMap { layer(from: $0, into: &context) }
                continue
            }
            if let image = imageAsset(from: asset, into: &context) {
                context.images[id] = image
            }
        }

        let layers = rawLayers.compactMap { layer(from: $0, into: &context) }
        let total = layers.count + context.precomps.values.reduce(0) { $0 + $1.count }
        guard !layers.isEmpty else {
            throw MediaDocumentFailure.invalidDocument(
                L10n.string("The animation has no layers this player can draw.")
            )
        }

        let markers = ((root["markers"] as? [[String: Any]]) ?? [])
            .prefix(ExtensionMediaMarkerLimit.maximumCount)
            .compactMap { marker -> ExtensionMediaMarkerValue? in
                guard let name = marker["cm"] as? String,
                      let time = number(marker["tm"]) else { return nil }
                return ExtensionMediaMarkerValue(
                    name: name,
                    time: time / frameRate,
                    duration: (number(marker["dr"]) ?? 0) / frameRate
                )
            }

        return LottieDocument(
            frameRate: frameRate,
            inPoint: inPoint,
            outPoint: outPoint,
            width: width,
            height: height,
            layers: layers,
            precomps: context.precomps,
            images: context.images,
            markers: Array(markers),
            notes: context.notes.sorted(),
            totalLayerCount: total
        )
    }

    /// Reserves from raw cardinality, before `layer(from:into:)` allocates transforms and paths.
    /// Unsupported layers count too: deciding that they are unsupported is itself parser work.
    private static func reserveLayerCapacity(
        _ count: Int,
        remaining: inout Int,
        limit: Int
    ) throws {
        guard count <= remaining else {
            throw MediaDocumentFailure.exceedsLimits(L10n.format(
                "The animation has more than the %lld layers this player accepts.",
                Int64(limit)
            ))
        }
        remaining -= count
    }

    // MARK: - Context

    private struct Context {
        let limits: MediaDocumentLimits
        let embeddedImages: [String: Data]
        var precomps: [String: [LottieLayer]] = [:]
        var images: [String: LottieImageAsset] = [:]
        var notes: Set<String> = []
    }

    // MARK: - Assets

    private static func imageAsset(
        from asset: [String: Any],
        into context: inout Context
    ) -> LottieImageAsset? {
        let width = Int(number(asset["w"]) ?? 0)
        let height = Int(number(asset["h"]) ?? 0)
        let fileName = asset["p"] as? String ?? ""

        // `e == 1` means the payload is inline. Anything else names a file beside the document,
        // and resolving it is exactly the arbitrary read this refuses: an animation an agent
        // just wrote would otherwise decide what the app opens.
        let isEmbedded = (number(asset["e"]) ?? 0) == 1
        if isEmbedded, let comma = fileName.range(of: ","),
           fileName.hasPrefix("data:"),
           let decoded = Data(base64Encoded: String(fileName[comma.upperBound...])) {
            guard decoded.count <= context.limits.maximumArchiveEntryBytes else {
                context.notes.insert(LottieDocument.Note.externalAssetsDropped)
                return nil
            }
            return LottieImageAsset(width: width, height: height, data: decoded)
        }

        // A `.lottie` container may resolve an image, but only to an entry the archive reader has
        // already validated — never beside the archive and never elsewhere on disk.
        let key = ((asset["u"] as? String) ?? "") + fileName
        if let archived = context.embeddedImages[key] ?? context.embeddedImages[fileName] {
            return LottieImageAsset(width: width, height: height, data: archived)
        }

        context.notes.insert(LottieDocument.Note.externalAssetsDropped)
        return nil
    }

    // MARK: - Layers

    private static func layer(
        from raw: [String: Any],
        into context: inout Context
    ) -> LottieLayer? {
        let type = Int(number(raw["ty"]) ?? -1)
        let index = Int(number(raw["ind"]) ?? 0)
        let isHidden = (raw["hd"] as? Bool) ?? false

        if raw["ef"] != nil {
            context.notes.insert(LottieDocument.Note.effectsDropped)
        }
        let matte = Int(number(raw["tt"]) ?? 0)
        if matte != 0 {
            context.notes.insert(LottieDocument.Note.mattesDropped)
        }

        let content: LottieLayer.Content
        switch type {
        case 0:
            guard let assetID = raw["refId"] as? String else { return nil }
            content = .precomp(
                assetID: assetID,
                width: number(raw["w"]) ?? 0,
                height: number(raw["h"]) ?? 0,
                timeRemap: raw["tm"].flatMap { scalar($0, into: &context) }
            )
        case 1:
            content = .solid(
                color: .fixed(colorComponents(fromHex: raw["sc"] as? String ?? "#000000")),
                width: number(raw["sw"]) ?? 0,
                height: number(raw["sh"]) ?? 0
            )
        case 2:
            guard let assetID = raw["refId"] as? String else { return nil }
            content = .image(assetID: assetID)
        case 3:
            content = .null
        case 4:
            let items = ((raw["shapes"] as? [[String: Any]]) ?? [])
                .compactMap { shapeItem(from: $0, into: &context) }
            guard !items.isEmpty else { return nil }
            content = .shapes(items)
        case 5:
            context.notes.insert(LottieDocument.Note.textLayersDropped)
            return nil
        default:
            context.notes.insert(LottieDocument.Note.unsupportedLayersDropped)
            return nil
        }

        let masks: [LottiePath]
        if let rawMasks = raw["masksProperties"] as? [[String: Any]] {
            masks = rawMasks.compactMap { mask -> LottiePath? in
                // Additive only. A subtract, intersect or difference mask changes what the layers
                // *under* it show, and honouring one of the four while ignoring three would draw
                // a document that is confidently wrong rather than visibly incomplete.
                guard (mask["mode"] as? String) == "a", let value = mask["pt"] else { return nil }
                return path(value, into: &context)
            }
        } else {
            masks = []
        }

        return LottieLayer(
            index: index,
            parentIndex: (raw["parent"] as? NSNumber).map(\.intValue),
            transform: transform(raw["ks"], into: &context),
            content: content,
            inPoint: number(raw["ip"]) ?? 0,
            outPoint: number(raw["op"]) ?? 0,
            startTime: number(raw["st"]) ?? 0,
            timeStretch: number(raw["sr"]) ?? 1,
            isHidden: isHidden,
            masks: masks,
            blendsWithMatte: matte != 0
        )
    }

    private static func transform(
        _ raw: Any?,
        into context: inout Context
    ) -> LottieTransform {
        guard let object = raw as? [String: Any] else { return .identity }
        return LottieTransform(
            anchor: object["a"].map { vector($0, into: &context) } ?? .constant([0, 0]),
            position: positionVector(object, into: &context),
            scale: object["s"].map { vector($0, into: &context) } ?? .constant([100, 100]),
            rotation: object["r"].map { scalar($0, into: &context) } ?? .constant(0),
            opacity: object["o"].map { scalar($0, into: &context) } ?? .constant(100),
            skew: object["sk"].map { scalar($0, into: &context) },
            skewAxis: object["sa"].map { scalar($0, into: &context) }
        )
    }

    /// Position is the one property bodymovin also writes split across `px`/`py`, so a document
    /// exported that way would otherwise sit at the origin.
    private static func positionVector(
        _ object: [String: Any],
        into context: inout Context
    ) -> LottieVector {
        if let combined = object["p"] as? [String: Any], combined["s"] as? Bool != true {
            return vector(combined, into: &context)
        }
        if let split = object["p"] as? [String: Any],
           let xValue = split["x"], let yValue = split["y"] {
            let x = scalar(xValue, into: &context)
            let y = scalar(yValue, into: &context)
            if case .fixed(let xConstant) = x, case .fixed(let yConstant) = y {
                return .fixed([xConstant, yConstant])
            }
            // A split animated position is rebuilt by sampling both channels onto the union of
            // their keyframe times, which is what keeps one animated axis from freezing the other.
            return .keyframes(mergedSplitPosition(x: x, y: y))
        }
        if let value = object["p"] {
            return vector(value, into: &context)
        }
        return .constant([0, 0])
    }

    private static func mergedSplitPosition(
        x: LottieScalar,
        y: LottieScalar
    ) -> [LottieKeyframe<[Double]>] {
        var times: Set<Double> = []
        for channel in [x, y] {
            if case .keyframes(let frames) = channel {
                times.formUnion(frames.map(\.time))
            }
        }
        return times.sorted().map { time in
            LottieKeyframe(
                time: time,
                value: [
                    LottieEvaluator.value(of: x, at: time),
                    LottieEvaluator.value(of: y, at: time)
                ],
                endValue: nil,
                outControl: nil,
                inControl: nil,
                isHold: false
            )
        }
    }

    // MARK: - Shapes

    private static func shapeItem(
        from raw: [String: Any],
        into context: inout Context
    ) -> LottieShapeItem? {
        if (raw["hd"] as? Bool) == true { return nil }
        switch raw["ty"] as? String {
        case "gr":
            let children = (raw["it"] as? [[String: Any]]) ?? []
            var groupTransform = LottieTransform.identity
            var items: [LottieShapeItem] = []
            for child in children {
                if (child["ty"] as? String) == "tr" {
                    groupTransform = transform(child, into: &context)
                    continue
                }
                if let item = shapeItem(from: child, into: &context) { items.append(item) }
            }
            return items.isEmpty ? nil : .group(items: items, transform: groupTransform)

        case "sh":
            guard let value = raw["ks"] else { return nil }
            return .path(path(value, into: &context))

        case "rc":
            return .rectangle(
                position: raw["p"].map { vector($0, into: &context) } ?? .constant([0, 0]),
                size: raw["s"].map { vector($0, into: &context) } ?? .constant([0, 0]),
                cornerRadius: raw["r"].map { scalar($0, into: &context) } ?? .constant(0)
            )

        case "el":
            return .ellipse(
                position: raw["p"].map { vector($0, into: &context) } ?? .constant([0, 0]),
                size: raw["s"].map { vector($0, into: &context) } ?? .constant([0, 0])
            )

        case "sr":
            return .polystar(LottiePolystar(
                isStar: Int(number(raw["sy"]) ?? 1) == 1,
                position: raw["p"].map { vector($0, into: &context) } ?? .constant([0, 0]),
                points: raw["pt"].map { scalar($0, into: &context) } ?? .constant(5),
                rotation: raw["r"].map { scalar($0, into: &context) } ?? .constant(0),
                outerRadius: raw["or"].map { scalar($0, into: &context) } ?? .constant(0),
                innerRadius: raw["ir"].map { scalar($0, into: &context) },
                outerRoundness: raw["os"].map { scalar($0, into: &context) } ?? .constant(0),
                innerRoundness: raw["is"].map { scalar($0, into: &context) }
            ))

        case "fl":
            return .fill(LottieFill(
                color: raw["c"].map { color($0, into: &context) } ?? .constant([0, 0, 0, 1]),
                opacity: raw["o"].map { scalar($0, into: &context) } ?? .constant(100),
                isEvenOdd: Int(number(raw["r"]) ?? 1) == 2
            ))

        case "st":
            return .stroke(LottieStroke(
                color: raw["c"].map { color($0, into: &context) } ?? .constant([0, 0, 0, 1]),
                opacity: raw["o"].map { scalar($0, into: &context) } ?? .constant(100),
                width: raw["w"].map { scalar($0, into: &context) } ?? .constant(1),
                lineCap: Int(number(raw["lc"]) ?? 2),
                lineJoin: Int(number(raw["lj"]) ?? 2),
                miterLimit: number(raw["ml"]) ?? 4
            ))

        case "gf":
            return gradient(from: raw, into: &context).map(LottieShapeItem.gradientFill)

        case "gs":
            guard let ramp = gradient(from: raw, into: &context) else { return nil }
            return .gradientStroke(
                ramp,
                width: raw["w"].map { scalar($0, into: &context) } ?? .constant(1),
                lineCap: Int(number(raw["lc"]) ?? 2),
                lineJoin: Int(number(raw["lj"]) ?? 2)
            )

        case "tm":
            return .trim(
                start: raw["s"].map { scalar($0, into: &context) } ?? .constant(0),
                end: raw["e"].map { scalar($0, into: &context) } ?? .constant(100),
                offset: raw["o"].map { scalar($0, into: &context) } ?? .constant(0),
                appliesToAll: Int(number(raw["m"]) ?? 1) == 1
            )

        case "rp":
            context.notes.insert(LottieDocument.Note.repeatersDropped)
            return nil

        default:
            return nil
        }
    }

    private static func gradient(
        from raw: [String: Any],
        into context: inout Context
    ) -> LottieGradient? {
        guard let colors = raw["g"] as? [String: Any],
              let stopValue = colors["k"] else { return nil }
        let count = Int(number(colors["p"]) ?? 0)
        guard count > 0 else { return nil }

        // `vector` reads both shapes bodymovin writes: a static ramp, and a keyframed one whose
        // frames each carry the whole flattened array.
        let ramp = vector(stopValue, into: &context)
        let sample = LottieEvaluator.value(of: ramp, at: 0)
        guard sample.count >= count * 4 else { return nil }

        return LottieGradient(
            isRadial: Int(number(raw["t"]) ?? 1) == 2,
            start: raw["s"].map { vector($0, into: &context) } ?? .constant([0, 0]),
            end: raw["e"].map { vector($0, into: &context) } ?? .constant([0, 0]),
            opacity: raw["o"].map { scalar($0, into: &context) } ?? .constant(100),
            stopCount: count,
            ramp: ramp
        )
    }

    // MARK: - Animatable values

    private static func scalar(_ raw: Any, into context: inout Context) -> LottieScalar {
        animated(raw, fallback: 0, into: &context) { value in
            if let single = number(value) { return single }
            if let array = value as? [Any], let first = array.first { return number(first) }
            return nil
        }
    }

    private static func vector(_ raw: Any, into context: inout Context) -> LottieVector {
        animated(raw, fallback: [], into: &context) { value in
            if let array = value as? [Any] { return array.compactMap(number) }
            if let single = number(value) { return [single] }
            return nil
        }
    }

    private static func color(_ raw: Any, into context: inout Context) -> LottieColor {
        animated(raw, fallback: [0, 0, 0, 1], into: &context) { value in
            guard let array = value as? [Any] else { return nil }
            var components = array.compactMap(number)
            while components.count < 4 { components.append(1) }
            return components
        }
    }

    private static func path(_ raw: Any, into context: inout Context) -> LottiePath {
        animated(raw, fallback: .empty, into: &context) { value in
            guard let object = value as? [String: Any] else { return nil }
            return bezier(from: object)
        }
    }

    private static func bezier(from object: [String: Any]) -> LottieBezier? {
        guard let vertices = (object["v"] as? [[Any]])?.map(point) else { return nil }
        let inTangents = (object["i"] as? [[Any]])?.map(point) ?? Array(
            repeating: .zero,
            count: vertices.count
        )
        let outTangents = (object["o"] as? [[Any]])?.map(point) ?? Array(
            repeating: .zero,
            count: vertices.count
        )
        guard inTangents.count == vertices.count, outTangents.count == vertices.count else {
            return nil
        }
        return LottieBezier(
            vertices: vertices,
            inTangents: inTangents,
            outTangents: outTangents,
            isClosed: (object["c"] as? Bool) ?? false
        )
    }

    /// The one place expressions are refused, so a property carrying one is read as its static
    /// value everywhere rather than in most places.
    /// `fallback` is what an unreadable property is worth, supplied by the caller because only
    /// the caller knows the type's own zero. A generic "figure it out" version needed a
    /// `fatalError` for the type it could not name, which is not a thing to keep in a parser
    /// whose input arrives from an agent.
    private static func animated<Value: Sendable>(
        _ raw: Any,
        fallback: Value,
        into context: inout Context,
        decode: (Any) -> Value?
    ) -> LottieAnimated<Value> {
        guard let object = raw as? [String: Any] else {
            return .fixed(decode(raw) ?? fallback)
        }
        if object["x"] != nil {
            context.notes.insert(LottieDocument.Note.expressionsDisabled)
        }
        // The `a` flag says whether the property is animated, and **real documents get it
        // wrong**: exporters ship `"a": 0` beside a keyframe array often enough that lottie-ios
        // carries a regression fixture for it. Trusting the flag read those properties as their
        // fallback — a fill whose opacity keyframes start at zero drew nothing, forever. The
        // shape of `k` is the honest signal, so that is what decides.
        let rawFrames = (object["k"] as? [[String: Any]])?.filter { $0["t"] != nil }
        guard let rawFrames, !rawFrames.isEmpty else {
            return .fixed(object["k"].flatMap(decode) ?? fallback)
        }

        var frames: [LottieKeyframe<Value>] = []
        for frame in rawFrames {
            guard let time = number(frame["t"]) else { continue }
            guard let start = frame["s"].flatMap(decode) else { continue }
            frames.append(LottieKeyframe(
                time: time,
                value: start,
                endValue: frame["e"].flatMap(decode),
                outControl: controlPoint(frame["o"]),
                inControl: controlPoint(frame["i"]),
                isHold: (number(frame["h"]) ?? 0) == 1
            ))
        }
        guard !frames.isEmpty else { return .fixed(fallback) }
        return .keyframes(frames.sorted { $0.time < $1.time })
    }

    private static func controlPoint(_ raw: Any?) -> CGPoint? {
        guard let object = raw as? [String: Any] else { return nil }
        return CGPoint(x: firstNumber(object["x"]) ?? 0, y: firstNumber(object["y"]) ?? 0)
    }

    // MARK: - Primitives

    private static func staticValue(_ raw: Any) -> Any? {
        guard let object = raw as? [String: Any] else { return raw }
        if let key = object["k"] { return key }
        return nil
    }

    private static func point(_ raw: [Any]) -> CGPoint {
        CGPoint(
            x: raw.count > 0 ? (number(raw[0]) ?? 0) : 0,
            y: raw.count > 1 ? (number(raw[1]) ?? 0) : 0
        )
    }

    private static func firstNumber(_ raw: Any?) -> Double? {
        if let array = raw as? [Any] { return array.first.flatMap(number) }
        return number(raw)
    }

    static func number(_ raw: Any?) -> Double? {
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        if let value = raw as? NSNumber { return value.doubleValue }
        return nil
    }

    static func colorComponents(fromHex hex: String) -> [Double] {
        var text = hex
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return [0, 0, 0, 1] }
        return [
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255,
            1
        ]
    }
}

enum ExtensionMediaMarkerLimit {
    static let maximumCount = 64
}
