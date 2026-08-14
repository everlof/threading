import CoreGraphics
import Foundation
import ImageIO

/// Draws one frame of a parsed Lottie document into a bounded bitmap.
///
/// `nonisolated` and free of AppKit on purpose: the whole point of the split is that a frame is
/// prepared **off** the main actor and committed as one image. Nothing here touches a view, a
/// layer or a `CGContext` the window server owns.
struct LottieRasterizer: Sendable {

    /// How deep a precomposition chain may nest. Deep enough for the composition-inside-a-
    /// composition idiom every real document uses; shallow enough that a document referencing
    /// itself is a bounded refusal rather than a stack overflow.
    static let maximumPrecompDepth = 8
    let document: LottieDocument

    /// Draws the composition at `frame` into an image of `pixelSize`, aspect-fit and centred.
    func image(atFrame frame: Double, pixelSize: CGSize) -> CGImage? {
        let width = max(1, Int(pixelSize.width))
        let height = max(1, Int(pixelSize.height))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        let scale = min(
            CGFloat(width) / CGFloat(document.width),
            CGFloat(height) / CGFloat(document.height)
        )
        let drawnWidth = CGFloat(document.width) * scale
        let drawnHeight = CGFloat(document.height) * scale

        context.saveGState()
        // Lottie's origin is top-left with y growing downwards; a bitmap context's is
        // bottom-left. One flip here means every path below is in the document's own space.
        context.translateBy(
            x: (CGFloat(width) - drawnWidth) / 2,
            y: (CGFloat(height) - drawnHeight) / 2 + drawnHeight
        )
        context.scaleBy(x: scale, y: -scale)
        context.interpolationQuality = .high

        draw(
            layers: document.layers,
            in: context,
            atFrame: frame,
            depth: 0
        )
        context.restoreGState()
        return context.makeImage()
    }

    // MARK: - Layers

    private func draw(
        layers: [LottieLayer],
        in context: CGContext,
        atFrame frame: Double,
        depth: Int
    ) {
        guard depth <= Self.maximumPrecompDepth else { return }
        let byIndex = Dictionary(layers.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in
            first
        })

        // Bodymovin lists layers front to back, so they are drawn in reverse.
        for layer in layers.reversed() {
            guard !layer.isHidden else { continue }
            // `ip`/`op` are in the **composition's** time; only property evaluation happens in
            // the layer's own. Testing visibility against the local frame is why a staggered
            // document — four copies of the same precomp at `st` 0, 8, 17, 26 — drew nothing at
            // all: every copy's own start time pushed its in point past the frame being drawn.
            guard frame >= layer.inPoint, frame < layer.outPoint else { continue }
            let stretch = layer.timeStretch == 0 ? 1 : layer.timeStretch
            let localFrame = (frame - layer.startTime) / stretch

            let opacity = LottieEvaluator.value(of: layer.transform.opacity, at: localFrame) / 100
            guard opacity > 0.001 else { continue }

            context.saveGState()
            context.concatenate(matrix(
                for: layer,
                in: byIndex,
                atFrame: localFrame,
                remaining: Self.maximumPrecompDepth
            ))

            if !layer.masks.isEmpty {
                let clip = CGMutablePath()
                for mask in layer.masks {
                    clip.addPath(cgPath(
                        from: LottieEvaluator.bezier(of: mask, at: localFrame)
                    ))
                }
                if !clip.isEmpty {
                    context.addPath(clip)
                    context.clip()
                }
            }

            switch layer.content {
            case .shapes(let items):
                drawShapes(items, in: context, atFrame: localFrame, alpha: opacity)

            case .solid(let color, let width, let height):
                let components = LottieEvaluator.value(of: color, at: localFrame)
                context.setFillColor(cgColor(components, alpha: opacity))
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))

            case .image(let assetID):
                guard let asset = document.images[assetID],
                      let image = decodeImage(asset.data) else { break }
                context.saveGState()
                context.setAlpha(CGFloat(opacity))
                // The bitmap is drawn into the flipped document space, so it needs its own flip
                // back or every embedded image comes out upside down.
                context.translateBy(x: 0, y: CGFloat(asset.height))
                context.scaleBy(x: 1, y: -1)
                context.draw(image, in: CGRect(
                    x: 0,
                    y: 0,
                    width: CGFloat(asset.width),
                    height: CGFloat(asset.height)
                ))
                context.restoreGState()

            case .precomp(let assetID, let width, let height, let timeRemap):
                guard let nested = document.precomps[assetID] else { break }
                context.saveGState()
                if width > 0, height > 0 {
                    context.clip(to: CGRect(x: 0, y: 0, width: width, height: height))
                }
                let nestedFrame = timeRemap.map {
                    LottieEvaluator.value(of: $0, at: localFrame) * document.frameRate
                } ?? localFrame
                draw(
                    layers: nested,
                    in: context,
                    atFrame: nestedFrame,
                    depth: depth + 1
                )
                context.restoreGState()

            case .null:
                break
            }
            context.restoreGState()
        }
    }

    /// A layer's matrix, including its parent chain.
    ///
    /// `remaining` bounds the walk: a document whose layer names itself as its own parent is a
    /// cycle, and a cycle in a transform chain is an infinite loop inside a frame.
    private func matrix(
        for layer: LottieLayer,
        in byIndex: [Int: LottieLayer],
        atFrame frame: Double,
        remaining: Int
    ) -> CGAffineTransform {
        var transform = affineTransform(layer.transform, atFrame: frame)
        if remaining > 0,
           let parentIndex = layer.parentIndex,
           let parent = byIndex[parentIndex],
           parent.index != layer.index {
            transform = transform.concatenating(matrix(
                for: parent,
                in: byIndex,
                atFrame: frame,
                remaining: remaining - 1
            ))
        }
        return transform
    }

    private func affineTransform(
        _ transform: LottieTransform,
        atFrame frame: Double
    ) -> CGAffineTransform {
        let anchor = LottieEvaluator.value(of: transform.anchor, at: frame)
        let position = LottieEvaluator.value(of: transform.position, at: frame)
        let scale = LottieEvaluator.value(of: transform.scale, at: frame)
        let rotation = LottieEvaluator.value(of: transform.rotation, at: frame)

        var matrix = CGAffineTransform.identity
        matrix = matrix.translatedBy(
            x: CGFloat(position.first ?? 0),
            y: CGFloat(position.count > 1 ? position[1] : 0)
        )
        matrix = matrix.rotated(by: CGFloat(rotation * .pi / 180))
        matrix = matrix.scaledBy(
            x: CGFloat((scale.first ?? 100) / 100),
            y: CGFloat((scale.count > 1 ? scale[1] : 100) / 100)
        )
        matrix = matrix.translatedBy(
            x: CGFloat(-(anchor.first ?? 0)),
            y: CGFloat(-(anchor.count > 1 ? anchor[1] : 0))
        )
        return matrix
    }

    // MARK: - Shapes

    /// Geometry accumulates and a style consumes it.
    ///
    /// Bodymovin writes a group as its geometry followed by the styles that paint it, so a style
    /// applies to every path collected before it. Strokes are painted after fills for the same
    /// reason: that is the order the array states, and it is the order every document is authored
    /// against.
    private func drawShapes(
        _ items: [LottieShapeItem],
        in context: CGContext,
        atFrame frame: Double,
        alpha: Double
    ) {
        var geometry = CGMutablePath()

        for item in items {
            switch item {
            case .group(let children, let transform):
                context.saveGState()
                context.concatenate(affineTransform(transform, atFrame: frame))
                let groupOpacity = LottieEvaluator.value(
                    of: transform.opacity,
                    at: frame
                ) / 100
                drawShapes(
                    children,
                    in: context,
                    atFrame: frame,
                    alpha: alpha * min(max(groupOpacity, 0), 1)
                )
                context.restoreGState()

            case .path(let path):
                geometry.addPath(cgPath(from: LottieEvaluator.bezier(of: path, at: frame)))

            case .rectangle(let position, let size, let cornerRadius):
                geometry.addPath(rectanglePath(
                    position: LottieEvaluator.value(of: position, at: frame),
                    size: LottieEvaluator.value(of: size, at: frame),
                    cornerRadius: LottieEvaluator.value(of: cornerRadius, at: frame)
                ))

            case .ellipse(let position, let size):
                let centre = LottieEvaluator.value(of: position, at: frame)
                let extent = LottieEvaluator.value(of: size, at: frame)
                let width = CGFloat(extent.first ?? 0)
                let height = CGFloat(extent.count > 1 ? extent[1] : 0)
                geometry.addEllipse(in: CGRect(
                    x: CGFloat(centre.first ?? 0) - width / 2,
                    y: CGFloat(centre.count > 1 ? centre[1] : 0) - height / 2,
                    width: width,
                    height: height
                ))

            case .polystar(let star):
                geometry.addPath(polystarPath(star, atFrame: frame))

            case .trim(let start, let end, let offset, _):
                geometry = trimmed(
                    geometry,
                    start: LottieEvaluator.value(of: start, at: frame) / 100,
                    end: LottieEvaluator.value(of: end, at: frame) / 100,
                    offset: LottieEvaluator.value(of: offset, at: frame) / 360
                )

            case .fill(let fill):
                guard !geometry.isEmpty else { break }
                let components = LottieEvaluator.value(of: fill.color, at: frame)
                let paint = LottieEvaluator.value(of: fill.opacity, at: frame) / 100
                context.saveGState()
                context.setFillColor(cgColor(components, alpha: alpha * paint))
                context.addPath(geometry)
                if fill.isEvenOdd {
                    context.fillPath(using: .evenOdd)
                } else {
                    context.fillPath(using: .winding)
                }
                context.restoreGState()

            case .gradientFill(let gradient):
                guard !geometry.isEmpty else { break }
                drawGradient(
                    gradient,
                    over: geometry,
                    in: context,
                    atFrame: frame,
                    alpha: alpha
                )

            case .gradientStroke(let gradient, let width, let cap, let join):
                guard !geometry.isEmpty else { break }
                let stroked = geometry.copy(
                    strokingWithWidth: CGFloat(
                        max(LottieEvaluator.value(of: width, at: frame), 0.01)
                    ),
                    lineCap: lineCap(cap),
                    lineJoin: lineJoin(join),
                    miterLimit: 4
                )
                drawGradient(
                    gradient,
                    over: stroked,
                    in: context,
                    atFrame: frame,
                    alpha: alpha
                )

            case .stroke(let stroke):
                guard !geometry.isEmpty else { break }
                let components = LottieEvaluator.value(of: stroke.color, at: frame)
                let paint = LottieEvaluator.value(of: stroke.opacity, at: frame) / 100
                context.saveGState()
                context.setStrokeColor(cgColor(components, alpha: alpha * paint))
                context.setLineWidth(
                    CGFloat(max(LottieEvaluator.value(of: stroke.width, at: frame), 0))
                )
                context.setLineCap(lineCap(stroke.lineCap))
                context.setLineJoin(lineJoin(stroke.lineJoin))
                context.setMiterLimit(CGFloat(stroke.miterLimit))
                context.addPath(geometry)
                context.strokePath()
                context.restoreGState()
            }
        }
    }

    private func drawGradient(
        _ gradient: LottieGradient,
        over path: CGPath,
        in context: CGContext,
        atFrame frame: Double,
        alpha: Double
    ) {
        let ramp = LottieEvaluator.value(of: gradient.ramp, at: frame)
        guard ramp.count >= gradient.stopCount * 4 else { return }

        // Bodymovin writes the colour ramp as (location, r, g, b) tuples and then, optionally,
        // the alpha ramp as (location, alpha) pairs after it.
        var alphaStops: [(Double, Double)] = []
        var index = gradient.stopCount * 4
        while index + 1 < ramp.count {
            alphaStops.append((ramp[index], ramp[index + 1]))
            index += 2
        }

        var colors: [CGColor] = []
        var locations: [CGFloat] = []
        for stop in 0..<gradient.stopCount {
            let base = stop * 4
            let location = ramp[base]
            let stopAlpha = alphaStops.min {
                abs($0.0 - location) < abs($1.0 - location)
            }?.1 ?? 1
            colors.append(CGColor(
                srgbRed: CGFloat(min(max(ramp[base + 1], 0), 1)),
                green: CGFloat(min(max(ramp[base + 2], 0), 1)),
                blue: CGFloat(min(max(ramp[base + 3], 0), 1)),
                alpha: CGFloat(min(max(stopAlpha, 0), 1))
            ))
            locations.append(CGFloat(min(max(location, 0), 1)))
        }
        guard !colors.isEmpty,
              let gradientRamp = CGGradient(
                  colorsSpace: CGColorSpaceCreateDeviceRGB(),
                  colors: colors as CFArray,
                  locations: locations
              ) else { return }

        let start = LottieEvaluator.value(of: gradient.start, at: frame)
        let end = LottieEvaluator.value(of: gradient.end, at: frame)
        let startPoint = CGPoint(
            x: start.first ?? 0,
            y: start.count > 1 ? start[1] : 0
        )
        let endPoint = CGPoint(
            x: end.first ?? 0,
            y: end.count > 1 ? end[1] : 0
        )

        context.saveGState()
        let paint = LottieEvaluator.value(of: gradient.opacity, at: frame) / 100
        context.setAlpha(CGFloat(min(max(alpha * paint, 0), 1)))
        context.addPath(path)
        context.clip()
        if gradient.isRadial {
            let radius = hypot(endPoint.x - startPoint.x, endPoint.y - startPoint.y)
            context.drawRadialGradient(
                gradientRamp,
                startCenter: startPoint,
                startRadius: 0,
                endCenter: startPoint,
                endRadius: radius,
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        } else {
            context.drawLinearGradient(
                gradientRamp,
                start: startPoint,
                end: endPoint,
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }
        context.restoreGState()
    }

    // MARK: - Geometry

    private func cgPath(from bezier: LottieBezier) -> CGPath {
        let path = CGMutablePath()
        guard let first = bezier.vertices.first else { return path }
        path.move(to: first)
        let count = bezier.vertices.count
        guard count > 1 else { return path }

        for index in 1..<count {
            let previous = bezier.vertices[index - 1]
            let current = bezier.vertices[index]
            path.addCurve(
                to: current,
                control1: CGPoint(
                    x: previous.x + bezier.outTangents[index - 1].x,
                    y: previous.y + bezier.outTangents[index - 1].y
                ),
                control2: CGPoint(
                    x: current.x + bezier.inTangents[index].x,
                    y: current.y + bezier.inTangents[index].y
                )
            )
        }
        if bezier.isClosed, let last = bezier.vertices.last {
            path.addCurve(
                to: first,
                control1: CGPoint(
                    x: last.x + bezier.outTangents[count - 1].x,
                    y: last.y + bezier.outTangents[count - 1].y
                ),
                control2: CGPoint(
                    x: first.x + bezier.inTangents[0].x,
                    y: first.y + bezier.inTangents[0].y
                )
            )
            path.closeSubpath()
        }
        return path
    }

    private func rectanglePath(
        position: [Double],
        size: [Double],
        cornerRadius: Double
    ) -> CGPath {
        let width = CGFloat(size.first ?? 0)
        let height = CGFloat(size.count > 1 ? size[1] : 0)
        let rect = CGRect(
            x: CGFloat(position.first ?? 0) - width / 2,
            y: CGFloat(position.count > 1 ? position[1] : 0) - height / 2,
            width: width,
            height: height
        )
        let radius = min(CGFloat(cornerRadius), min(width, height) / 2)
        return radius > 0
            ? CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            : CGPath(rect: rect, transform: nil)
    }

    private func polystarPath(_ star: LottiePolystar, atFrame frame: Double) -> CGPath {
        let path = CGMutablePath()
        let centre = LottieEvaluator.value(of: star.position, at: frame)
        let origin = CGPoint(
            x: centre.first ?? 0,
            y: centre.count > 1 ? centre[1] : 0
        )
        let points = max(3, Int(LottieEvaluator.value(of: star.points, at: frame)))
        let rotation = LottieEvaluator.value(of: star.rotation, at: frame) * .pi / 180
        let outer = CGFloat(LottieEvaluator.value(of: star.outerRadius, at: frame))
        let inner = star.innerRadius.map {
            CGFloat(LottieEvaluator.value(of: $0, at: frame))
        } ?? outer

        let vertexCount = star.isStar ? points * 2 : points
        guard vertexCount > 2 else { return path }
        // Lottie measures a polystar's rotation from straight up, not from the x axis.
        let step = (.pi * 2) / Double(vertexCount)
        for index in 0..<vertexCount {
            let angle = rotation - .pi / 2 + step * Double(index)
            let radius = star.isStar && index % 2 == 1 ? inner : outer
            let point = CGPoint(
                x: origin.x + cos(CGFloat(angle)) * radius,
                y: origin.y + sin(CGFloat(angle)) * radius
            )
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    /// A trimmed copy of `path`, taking the run between two fractions of its total length.
    ///
    /// Flattened rather than solved: arc length along a cubic has no closed form, and a
    /// flattening step of one point is well under the pixel a canvas at any supported size can
    /// show. Bounded by construction — the step is a length, so the work scales with the path's
    /// size rather than with the document's complexity.
    private func trimmed(
        _ path: CGMutablePath,
        start: Double,
        end: Double,
        offset: Double
    ) -> CGMutablePath {
        var lower = min(start, end) + offset
        var upper = max(start, end) + offset
        // A trim outside the path is the path, which is what "no trim applied" looks like.
        if upper - lower >= 1 { return path }
        lower = lower.truncatingRemainder(dividingBy: 1)
        upper = upper.truncatingRemainder(dividingBy: 1)
        if lower < 0 { lower += 1 }
        if upper < 0 { upper += 1 }

        // One dash longer than any path is the platform's own way to ask for a flattened copy;
        // an empty `lengths` array is not a documented flatten and is not worth finding out.
        let flattened = path.copy(
            dashingWithPhase: 0,
            lengths: [.greatestFiniteMagnitude]
        )
        var points: [CGPoint] = []
        flattened.applyWithBlock { element in
            switch element.pointee.type {
            case .moveToPoint, .addLineToPoint:
                points.append(element.pointee.points[0])
            case .addQuadCurveToPoint:
                points.append(element.pointee.points[1])
            case .addCurveToPoint:
                points.append(element.pointee.points[2])
            case .closeSubpath:
                if let first = points.first { points.append(first) }
            @unknown default:
                break
            }
        }
        guard points.count > 1 else { return path }

        var lengths: [CGFloat] = [0]
        var total: CGFloat = 0
        for index in 1..<points.count {
            total += hypot(
                points[index].x - points[index - 1].x,
                points[index].y - points[index - 1].y
            )
            lengths.append(total)
        }
        guard total > 0 else { return path }

        let result = CGMutablePath()
        let ranges: [(CGFloat, CGFloat)] = lower <= upper
            ? [(CGFloat(lower) * total, CGFloat(upper) * total)]
            // A trim that wraps past the end of the path is two runs, not one — the tail and the
            // head — which is what makes a rotating dash read as continuous.
            : [(CGFloat(lower) * total, total), (0, CGFloat(upper) * total)]

        for (from, to) in ranges where to > from {
            var started = false
            for index in 1..<points.count {
                let segmentStart = lengths[index - 1]
                let segmentEnd = lengths[index]
                guard segmentEnd > from, segmentStart < to else { continue }
                let clampedStart = max(segmentStart, from)
                let clampedEnd = min(segmentEnd, to)
                let span = segmentEnd - segmentStart
                guard span > 0 else { continue }
                let a = interpolate(
                    points[index - 1],
                    points[index],
                    (clampedStart - segmentStart) / span
                )
                let b = interpolate(
                    points[index - 1],
                    points[index],
                    (clampedEnd - segmentStart) / span
                )
                if !started {
                    result.move(to: a)
                    started = true
                }
                result.addLine(to: b)
            }
        }
        return result.isEmpty ? path : result
    }

    private func interpolate(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    // MARK: - Primitives

    private func cgColor(_ components: [Double], alpha: Double) -> CGColor {
        let red = components.count > 0 ? components[0] : 0
        let green = components.count > 1 ? components[1] : 0
        let blue = components.count > 2 ? components[2] : 0
        let documentAlpha = components.count > 3 ? components[3] : 1
        return CGColor(
            srgbRed: CGFloat(min(max(red, 0), 1)),
            green: CGFloat(min(max(green, 0), 1)),
            blue: CGFloat(min(max(blue, 0), 1)),
            alpha: CGFloat(min(max(documentAlpha * alpha, 0), 1))
        )
    }

    private func lineCap(_ raw: Int) -> CGLineCap {
        switch raw {
        case 1: .butt
        case 3: .square
        default: .round
        }
    }

    private func lineJoin(_ raw: Int) -> CGLineJoin {
        switch raw {
        case 1: .miter
        case 3: .bevel
        default: .round
        }
    }

    private func decodeImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
