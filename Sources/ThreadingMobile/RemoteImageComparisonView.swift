import ImageIO
import SwiftUI
import ThreadingRemoteKit
import UIKit

// MARK: - Mode

/// The ways the phone holds two pictures against each other: the Mac Compare tab's modes, sharing
/// one scrubbed fraction, so switching mode keeps the seam where it was left.
enum MobileImageCompareMode: String, CaseIterable, Identifiable {
    /// A vertical seam dragged left–right: old before it, new after it.
    case wipeHorizontal
    /// A horizontal seam dragged up–down: old above it, new below it.
    case wipeVertical
    /// Both pictures in place, the new one at the scrubbed opacity.
    case fade
    /// Pixel difference — identical areas read as black, changes as light.
    case difference
    /// Both pictures whole, beside or above each other.
    case sideBySide

    var id: String { rawValue }

    /// Whether the mode reads the scrubbed fraction. Difference and side by side have nothing to
    /// scrub, so the slider leaves rather than sitting dead.
    var usesFraction: Bool {
        switch self {
        case .wipeHorizontal, .wipeVertical, .fade: true
        case .difference, .sideBySide: false
        }
    }

    var isWipe: Bool { self == .wipeHorizontal || self == .wipeVertical }

    var title: String {
        switch self {
        case .wipeHorizontal: MobileL10n.string("Wipe ↔")
        case .wipeVertical: MobileL10n.string("Wipe ↕")
        case .fade: MobileL10n.string("Fade")
        case .difference: MobileL10n.string("Difference")
        case .sideBySide: MobileL10n.string("Side by Side")
        }
    }

    /// The Mac chip's symbols, so a mode is recognisably the same one on both.
    var symbol: String {
        switch self {
        case .wipeHorizontal: "rectangle.split.2x1"
        case .wipeVertical: "rectangle.split.1x2"
        case .fade: "circle.lefthalf.filled.inverse"
        case .difference: "circle.circle"
        case .sideBySide: "rectangle.on.rectangle"
        }
    }
}

// MARK: - Layout

/// Where each picture draws, under the Mac's rule (`ImageCompareLayout`): both at **one shared
/// scale** — the union of the two pixel sizes fitted into the room — each centred in the fitted
/// canvas. Fitting each picture on its own would quietly normalise a resized asset into "looks
/// identical", the one thing an image comparison must never say.
struct MobileImageCompareLayout: Equatable {
    let oldRect: CGRect
    let newRect: CGRect
    /// The canvas the seam crosses; the old side's own in side by side.
    let canvas: CGRect
    /// The new side's canvas in side by side, nil whenever the two overlay.
    let secondaryCanvas: CGRect?

    /// Whether the new side sits below the old one rather than beside it, which is where its
    /// caption goes.
    var placesNewBelow: Bool {
        guard let secondaryCanvas else { return false }
        return secondaryCanvas.minY >= canvas.maxY
    }

    static func layout(
        oldSize: CGSize,
        newSize: CGSize,
        in bounds: CGRect,
        mode: MobileImageCompareMode,
        gap: CGFloat
    ) -> Self {
        let union = CGSize(
            width: max(oldSize.width, newSize.width),
            height: max(oldSize.height, newSize.height)
        )
        guard mode == .sideBySide else {
            let canvas = fit(union, into: bounds)
            let scale = scale(of: union, in: canvas)
            return Self(
                oldRect: centre(oldSize, at: scale, in: canvas),
                newRect: centre(newSize, at: scale, in: canvas),
                canvas: canvas,
                secondaryCanvas: nil
            )
        }

        // A phone is usually taller than the pictures it compares are wide, so the split goes
        // whichever way leaves each picture the larger scale.
        let across = halves(of: bounds, gap: gap, stacked: false)
        let stacked = halves(of: bounds, gap: gap, stacked: true)
        let prefersStacked = scale(of: union, in: fit(union, into: stacked.first))
            > scale(of: union, in: fit(union, into: across.first))
        let (first, second) = prefersStacked ? stacked : across
        let oldCanvas = fit(union, into: first)
        let newCanvas = fit(union, into: second)
        let scale = scale(of: union, in: oldCanvas)
        return Self(
            oldRect: centre(oldSize, at: scale, in: oldCanvas),
            newRect: centre(newSize, at: scale, in: newCanvas),
            canvas: oldCanvas,
            secondaryCanvas: newCanvas
        )
    }

    /// The seam's coordinate for a wipe at `fraction`: an x across, a y downwards.
    func seam(for mode: MobileImageCompareMode, at fraction: CGFloat) -> CGFloat {
        let clamped = min(max(fraction, 0), 1)
        return mode == .wipeVertical
            ? canvas.minY + canvas.height * clamped
            : canvas.minX + canvas.width * clamped
    }

    /// The fraction a point on the canvas stands for, for a drag or a tap.
    func fraction(at point: CGPoint, for mode: MobileImageCompareMode) -> CGFloat {
        let value = mode == .wipeVertical
            ? (point.y - canvas.minY) / max(canvas.height, 1)
            : (point.x - canvas.minX) / max(canvas.width, 1)
        return min(max(value, 0), 1)
    }

    private static func fit(_ size: CGSize, into bounds: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else {
            return CGRect(origin: CGPoint(x: bounds.midX, y: bounds.midY), size: .zero)
        }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(
            x: bounds.midX - fitted.width / 2,
            y: bounds.midY - fitted.height / 2,
            width: fitted.width,
            height: fitted.height
        )
    }

    private static func scale(of size: CGSize, in canvas: CGRect) -> CGFloat {
        size.width > 0 ? canvas.width / size.width : 0
    }

    private static func centre(_ size: CGSize, at scale: CGFloat, in canvas: CGRect) -> CGRect {
        CGRect(
            x: canvas.midX - size.width * scale / 2,
            y: canvas.midY - size.height * scale / 2,
            width: size.width * scale,
            height: size.height * scale
        )
    }

    private static func halves(
        of bounds: CGRect,
        gap: CGFloat,
        stacked: Bool
    ) -> (first: CGRect, second: CGRect) {
        if stacked {
            let half = max(0, (bounds.height - gap) / 2)
            return (
                CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: half),
                CGRect(x: bounds.minX, y: bounds.minY + half + gap, width: bounds.width, height: half)
            )
        }
        let half = max(0, (bounds.width - gap) / 2)
        return (
            CGRect(x: bounds.minX, y: bounds.minY, width: half, height: bounds.height),
            CGRect(x: bounds.minX + half + gap, y: bounds.minY, width: half, height: bounds.height)
        )
    }
}

// MARK: - Loading

/// One side of a comparison, decoded for the screen.
///
/// `@unchecked Sendable` because `UIImage` wraps an immutable, fully decoded frame here: it is
/// built once on a worker and only ever read afterwards.
struct RemoteImageComparisonSide: @unchecked Sendable {
    let image: UIImage
    /// The picture's own pixel size, oriented. The layout is computed from it even when the frame
    /// was downsampled, so a downsampled side still draws at the shared scale.
    let pixelSize: CGSize
    let title: String
}

/// Reads a `.comparison` record and the two pictures it names, off the main actor.
enum RemoteImageComparisonLoad {
    enum Failure: Error, Equatable {
        case unreadable
        case undecodable

        var message: String {
            switch self {
            case .unreadable: MobileL10n.string("This comparison could not be read.")
            case .undecodable: MobileL10n.string("A picture in this comparison could not be decoded.")
            }
        }
    }

    /// The longest edge a side is decoded at. The canvas is never wider than the screen and the
    /// comparison is not zoomable, so a 6K screenshot gains nothing from full resolution except
    /// a hundred megabytes per side.
    static let maximumDecodedPixelDimension = 2_560

    static func load(
        manifestData: Data,
        loadSide: @escaping @Sendable (String) async throws -> Data
    ) async throws -> (old: RemoteImageComparisonSide, new: RemoteImageComparisonSide) {
        let manifest = try await Task.detached(priority: .userInitiated) {
            try decodeManifest(manifestData)
        }.value
        async let oldData = loadSide(manifest.old.attachmentID)
        async let newData = loadSide(manifest.new.attachmentID)
        let (old, new) = try await (oldData, newData)
        return try await Task.detached(priority: .userInitiated) {
            (
                try side(from: old, title: manifest.old.title),
                try side(from: new, title: manifest.new.title)
            )
        }.value
    }

    static func decodeManifest(_ data: Data) throws -> RemoteImageComparisonDTO {
        do {
            return try JSONDecoder().decode(RemoteImageComparisonDTO.self, from: data)
        } catch {
            throw Failure.unreadable
        }
    }

    /// Decodes one side at no more than `maximumDecodedPixelDimension`, keeping its true size.
    static func side(from data: Data, title: String) throws -> RemoteImageComparisonSide {
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            throw Failure.undecodable
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), maximumDecodedPixelDimension),
        ]
        guard let frame = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw Failure.undecodable
        }
        // EXIF orientations 5–8 turn the picture a quarter, which the decode above applied.
        let turned = (5...8).contains(properties[kCGImagePropertyOrientation] as? Int ?? 1)
        return RemoteImageComparisonSide(
            image: UIImage(cgImage: frame),
            pixelSize: turned
                ? CGSize(width: height, height: width)
                : CGSize(width: width, height: height),
            title: title
        )
    }
}

// MARK: - View

enum RemoteImageComparisonDefaults {
    /// Room reserved above and below the canvas for the captions, so no title sits on pixels.
    static let captionBand: CGFloat = 22
    /// Between the two pictures in side by side.
    static let sideBySideGap = MobileDesign.Spacing.small
    static let seamWidth: CGFloat = 2
    static let handleDiameter: CGFloat = 32
    /// A VoiceOver swipe on the seam moves it this far.
    static let accessibilityStep: CGFloat = 0.1
}

/// A `.comparison` attachment: the two pictures an agent compared, held against each other the
/// way the Mac's Compare tab holds them.
///
/// The record names both pictures by attachment id and they arrive through the ordinary bounded
/// attachment route, decoded off the main actor. The seam is moved by its handle, by a tap on the
/// canvas, or by the slider; a swipe anywhere else still pages the gallery, which a canvas that
/// claimed every horizontal drag would have stopped doing.
struct RemoteImageComparisonView: View {
    let manifestData: Data
    let loadSide: @Sendable (String) async throws -> Data

    @Environment(\.remoteTheme) private var theme
    @State private var phase: Phase = .loading
    @State private var mode: MobileImageCompareMode = .wipeHorizontal
    @State private var fraction: CGFloat = 0.5

    private enum Phase {
        case loading
        case loaded(old: RemoteImageComparisonSide, new: RemoteImageComparisonSide)
        case failed(String)
    }

    private static let canvasSpace = "comparison.canvas"

    var body: some View {
        Group {
            switch phase {
            case .loading:
                MobileLoadingPlaceholder(MobileL10n.string("Reading comparison…"))
            case .failed(let message):
                ContentUnavailableView(
                    "No preview",
                    systemImage: RemoteAttachmentGlyph.name(for: .comparison),
                    description: Text(message)
                )
            case .loaded(let old, let new):
                comparison(old: old, new: new)
            }
        }
        .background(theme.ground)
        .task(id: manifestData) { await load() }
    }

    private func comparison(
        old: RemoteImageComparisonSide,
        new: RemoteImageComparisonSide
    ) -> some View {
        VStack(spacing: MobileDesign.Spacing.medium) {
            GeometryReader { proxy in
                let bounds = CGRect(origin: .zero, size: proxy.size).insetBy(
                    dx: 0,
                    dy: RemoteImageComparisonDefaults.captionBand
                )
                let layout = MobileImageCompareLayout.layout(
                    oldSize: old.pixelSize,
                    newSize: new.pixelSize,
                    in: bounds,
                    mode: mode,
                    gap: RemoteImageComparisonDefaults.sideBySideGap
                )
                canvas(old: old, new: new, layout: layout, size: proxy.size)
            }
            controls(old: old, new: new)
        }
        .padding(MobileDesign.Spacing.inset)
    }

    // MARK: Canvas

    private func canvas(
        old: RemoteImageComparisonSide,
        new: RemoteImageComparisonSide,
        layout: MobileImageCompareLayout,
        size: CGSize
    ) -> some View {
        ZStack(alignment: .topLeading) {
            picture(old, in: layout.oldRect)
            newSide(new, layout: layout, size: size)
            if mode.isWipe {
                seam(layout: layout)
            }
            captions(old: old, new: new, layout: layout)
        }
        .compositingGroup()
        .frame(width: size.width, height: size.height)
        .coordinateSpace(.named(Self.canvasSpace))
        .contentShape(Rectangle())
        // A tap places the seam. It never competes with the gallery's paging, which a drag
        // anywhere on the canvas would.
        .onTapGesture(coordinateSpace: .named(Self.canvasSpace)) { point in
            guard mode.isWipe else { return }
            fraction = layout.fraction(at: point, for: mode)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(MobileL10n.string("%@ compared with %@", old.title, new.title))
    }

    @ViewBuilder
    private func newSide(
        _ side: RemoteImageComparisonSide,
        layout: MobileImageCompareLayout,
        size: CGSize
    ) -> some View {
        switch mode {
        case .wipeHorizontal:
            let seam = layout.seam(for: mode, at: fraction)
            picture(side, in: layout.newRect).mask {
                Path(CGRect(x: seam, y: 0, width: max(0, size.width - seam), height: size.height))
            }
        case .wipeVertical:
            let seam = layout.seam(for: mode, at: fraction)
            picture(side, in: layout.newRect).mask {
                Path(CGRect(x: 0, y: seam, width: size.width, height: max(0, size.height - seam)))
            }
        case .fade:
            picture(side, in: layout.newRect).opacity(fraction)
        case .difference:
            picture(side, in: layout.newRect).blendMode(.difference)
        case .sideBySide:
            picture(side, in: layout.newRect)
        }
    }

    /// One picture at its rect. Past four points per pixel the pictures are icons being inspected,
    /// and smoothing would smear exactly the pixels the comparison is looking for.
    private func picture(_ side: RemoteImageComparisonSide, in rect: CGRect) -> some View {
        let pointsPerPixel = side.pixelSize.width > 0 ? rect.width / side.pixelSize.width : 1
        return Image(uiImage: side.image)
            .resizable()
            .interpolation(pointsPerPixel > 4 ? .none : .high)
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .accessibilityHidden(true)
    }

    private func seam(layout: MobileImageCompareLayout) -> some View {
        let position = layout.seam(for: mode, at: fraction)
        let canvas = layout.canvas
        let isVertical = mode == .wipeVertical
        let handle = CGPoint(
            x: isVertical ? canvas.midX : position,
            y: isVertical ? position : canvas.midY
        )
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(theme.label)
                .frame(
                    width: isVertical ? canvas.width : RemoteImageComparisonDefaults.seamWidth,
                    height: isVertical ? RemoteImageComparisonDefaults.seamWidth : canvas.height
                )
                .position(
                    x: isVertical ? canvas.midX : position,
                    y: isVertical ? position : canvas.midY
                )
                .allowsHitTesting(false)
            Image(systemName: isVertical ? "arrow.up.and.down" : "arrow.left.and.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.label)
                .frame(
                    width: RemoteImageComparisonDefaults.handleDiameter,
                    height: RemoteImageComparisonDefaults.handleDiameter
                )
                .background(Circle().fill(theme.surface))
                .overlay(Circle().strokeBorder(theme.border, lineWidth: theme.borderWidth))
                .frame(
                    width: MobileDesign.Size.minimumTapTarget,
                    height: MobileDesign.Size.minimumTapTarget
                )
                .contentShape(Rectangle())
                .position(handle)
                // Only the handle takes a drag, so the seam moves under the finger while a swipe
                // anywhere else on the page still reaches the gallery.
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.canvasSpace))
                        .onChanged { drag in
                            fraction = layout.fraction(at: drag.location, for: mode)
                        }
                )
                .accessibilityElement()
                .accessibilityLabel(MobileL10n.string("Comparison position"))
                .accessibilityValue(Text(Double(fraction), format: .percent.precision(.fractionLength(0))))
                .accessibilityAdjustableAction { direction in
                    let step = RemoteImageComparisonDefaults.accessibilityStep
                    switch direction {
                    case .increment: fraction = min(1, fraction + step)
                    case .decrement: fraction = max(0, fraction - step)
                    @unknown default: break
                    }
                }
        }
    }

    /// Each side named in the band beside its pixels — old where a wipe starts, new where it
    /// ends — rather than printed on the picture.
    private func captions(
        old: RemoteImageComparisonSide,
        new: RemoteImageComparisonSide,
        layout: MobileImageCompareLayout
    ) -> some View {
        let band = RemoteImageComparisonDefaults.captionBand
        let canvas = layout.canvas
        let above = { (rect: CGRect) in
            CGRect(x: rect.minX, y: rect.minY - band, width: rect.width, height: band)
        }
        let below = { (rect: CGRect) in
            CGRect(x: rect.minX, y: rect.maxY, width: rect.width, height: band)
        }
        let oldBand: CGRect
        let newBand: CGRect
        let newIsBelow: Bool
        if let second = layout.secondaryCanvas {
            oldBand = above(canvas)
            newIsBelow = layout.placesNewBelow
            newBand = newIsBelow ? below(second) : above(second)
        } else if mode == .wipeVertical {
            oldBand = above(canvas)
            newBand = below(canvas)
            newIsBelow = true
        } else {
            let halves = canvas.divided(atDistance: canvas.width / 2, from: .minXEdge)
            oldBand = above(halves.slice)
            newBand = above(halves.remainder)
            newIsBelow = false
        }
        return ZStack(alignment: .topLeading) {
            caption(old.title, alignment: .leading)
                .frame(width: oldBand.width, height: band, alignment: .bottomLeading)
                .position(x: oldBand.midX, y: oldBand.midY)
            caption(new.title, alignment: newIsBelow ? .leading : .trailing)
                .frame(
                    width: newBand.width,
                    height: band,
                    alignment: newIsBelow ? .topLeading : .bottomTrailing
                )
                .position(x: newBand.midX, y: newBand.midY)
        }
        .allowsHitTesting(false)
    }

    private func caption(_ title: String, alignment: TextAlignment) -> some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(theme.secondaryLabel)
            .multilineTextAlignment(alignment)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    // MARK: Controls

    private func controls(
        old: RemoteImageComparisonSide,
        new: RemoteImageComparisonSide
    ) -> some View {
        VStack(spacing: MobileDesign.Spacing.small) {
            HStack(spacing: MobileDesign.Spacing.small) {
                Text(mode.title)
                    .foregroundStyle(theme.label)
                Spacer(minLength: MobileDesign.Spacing.small)
                if old.pixelSize != new.pixelSize {
                    // Mismatched sizes are said, never quietly normalised.
                    Text(MobileL10n.string(
                        "%@ against %@",
                        Self.dimensions(old.pixelSize),
                        Self.dimensions(new.pixelSize)
                    ))
                    .foregroundStyle(theme.tertiaryLabel)
                    .lineLimit(1)
                }
            }
            .font(.caption)

            Picker(MobileL10n.string("Comparison mode"), selection: $mode) {
                ForEach(MobileImageCompareMode.allCases) { candidate in
                    Image(systemName: candidate.symbol)
                        .accessibilityLabel(candidate.title)
                        .tag(candidate)
                }
            }
            .pickerStyle(.segmented)

            if mode.usesFraction {
                Slider(value: $fraction, in: 0...1) {
                    Text(MobileL10n.string("Comparison position"))
                }
                .tint(theme.accent)
            }
        }
    }

    private static func dimensions(_ size: CGSize) -> String {
        "\(Int(size.width)) × \(Int(size.height))"
    }

    // MARK: Loading

    @MainActor
    private func load() async {
        phase = .loading
        do {
            let sides = try await RemoteImageComparisonLoad.load(
                manifestData: manifestData,
                loadSide: loadSide
            )
            phase = .loaded(old: sides.old, new: sides.new)
        } catch let failure as RemoteImageComparisonLoad.Failure {
            phase = .failed(failure.message)
        } catch {
            // A cancelled page is lifecycle, not a failure: the next appearance asks again.
            guard let message = RemoteAttachmentPreviewFailure.message(for: error) else { return }
            phase = .failed(message)
        }
    }
}
