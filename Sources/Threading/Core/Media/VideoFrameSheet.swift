import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Constants

/// What a recording has to be turned into before a model can answer a question about it.
///
/// These numbers are not taste. An image handed to a model is downscaled to
/// `readableLongEdge` on its long edge before it is ever looked at, so a cell's *delivered*
/// width is the sheet's width divided by its column count — however large the file on disk
/// was. Nine cells is where a phone recording still arrives at roughly half size; a six by
/// six sheet of the same clip delivers each frame about 120 pixels wide, which reads as a
/// thumbnail of a screenshot rather than as a screenshot. That is not hypothetical: it is
/// what made one recording cost nine follow-up crops to answer a single question about a
/// navigation bar.
enum VideoFrameDefaults {

    /// The most cells one sheet may hold, and therefore the most frames ever decoded.
    ///
    /// This is the whole scaling contract: cost is fixed at nine decodes whether the clip is
    /// two seconds or an hour, because a longer clip is sampled more sparsely rather than
    /// more expensively.
    static let maximumCells = 9

    /// The long edge an image is downscaled to before a model sees it.
    ///
    /// The sheet is built at exactly this size rather than larger, so nothing is decoded,
    /// encoded or transferred that the downscale would only throw away.
    static let readableLongEdge = 1_568

    /// Below this, a cell is a thumbnail rather than a screenshot.
    ///
    /// Advisory, not a refusal: full coverage of a long clip is sometimes worth small cells,
    /// and the caller is the one who knows. But it is said out loud, because the failure it
    /// warns about looks exactly like success — a sheet arrives, it is simply too small to
    /// answer the question, and the next twenty minutes go on crops.
    static let legibleCellWidth = 320

    /// Gap between cells, and the border around them. Enough to tell two dark frames of the
    /// same dark UI apart, which is most of what these recordings are.
    static let cellGap = 6
    static let sheetMargin = 6

    /// The plate behind the grid, in the neutral grey both themes read a contact sheet against.
    static let plate = (red: 0.09, green: 0.09, blue: 0.10)

    /// The rate assumed when a recording will not say. Variable-frame-rate screen recordings
    /// report a nominal rate of zero, and a sample count derived from zero is zero.
    static let fallbackFrameRate: Double = 30
}

// MARK: - What the file turned out to be

/// The facts about a recording that a caller would otherwise shell out to `ffprobe` for.
///
/// Deliberately this app's *second* answer to "what is this movie", and deliberately not
/// coupled to the first. `VideoDocumentRenderer` asks the same questions for the player, but it
/// asks them against `MediaDocumentLimits` — ceilings written for a canvas that will hold the
/// decoded frame — and it belongs to a subsystem whose shape is still moving. A tool an agent
/// calls on a file the user just pasted should not fail because the player's limits were
/// retuned. Collapse the two onto one probe once the movie engine has settled; until then this
/// is forty lines that cannot be broken from elsewhere.
struct VideoFrameSource: Sendable {
    let url: URL
    let duration: Double
    let frameRate: Double
    let pixelWidth: Int
    let pixelHeight: Int
    let hasAudio: Bool
}

// MARK: - Request

/// What to read out of one recording.
struct VideoFrameSheetRequest: Sendable {

    let url: URL
    /// The window to sample across, in seconds. `nil` means the whole clip.
    var start: Double?
    var end: Double?
    /// A region of the *presented* frame to keep, in source pixels with the origin top left —
    /// the same corner `ffmpeg`'s `crop` names, so a rectangle read off one tool works in the
    /// other.
    var crop: CGRect?
    /// How many cells to ask for. Clamped to `VideoFrameDefaults.maximumCells`, and further
    /// clamped to the number of frames the window actually holds.
    var frames: Int?
}

// MARK: - Result

/// One sheet, plus everything the caller would otherwise have shelled out to `ffprobe` for.
struct VideoFrameSheetResult: Sendable {

    let pngData: Data
    let source: VideoFrameSource
    /// One entry per cell, in reading order, in seconds from the start of the clip. This is
    /// the answer to "which moment is that" — it travels as text because the obvious
    /// alternative, burning the number into the picture, needs a `drawtext` filter that a
    /// Homebrew `ffmpeg` built without freetype does not have.
    let timestamps: [Double]
    let columns: Int
    let rows: Int
    let cellPixelWidth: Int
    let cellPixelHeight: Int
    let sheetPixelWidth: Int
    let sheetPixelHeight: Int
    let windowStart: Double
    let windowEnd: Double
    /// What a cell is worth once the sheet has been downscaled for delivery. The honest
    /// number: a caller that needs more than this has to narrow the window or crop, not ask
    /// for more cells.
    let deliveredCellWidth: Int

    var isCropped: Bool { cropRect != nil }
    let cropRect: CGRect?
}

// MARK: - Failure

enum VideoFrameSheetFailure: LocalizedError {
    case unreadable
    case notPlayable
    case noVideoTrack
    case noReadableSize
    case emptyWindow
    case undecodable(seconds: Double)
    case cropOutsideFrame(width: Int, height: Int)
    case couldNotEncode

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return "The movie could not be read."
        case .notPlayable:
            return "This movie is in a format this Mac cannot play."
        case .noVideoTrack:
            return "This file carries no video in it."
        case .noReadableSize:
            return "The movie has no readable size."
        case .emptyWindow:
            return "The requested time window contains no frames."
        case .undecodable(let seconds):
            return String(format: "No frame could be decoded at %.2fs.", seconds)
        case .cropOutsideFrame(let width, let height):
            return "The crop lies outside the \(width)×\(height) frame."
        case .couldNotEncode:
            return "The frames could not be encoded as a PNG."
        }
    }
}

// MARK: - Reading

/// Turns a recording into one still a model can read, off the main actor.
///
/// The two-stage shape is deliberate and comes from watching the manual version fail the same
/// way every time: a sheet dense enough to cover a whole clip is too small to read, and frames
/// large enough to read only ever cover a moment. So this tool answers *where* by default and
/// answers *what* when given a window and a crop. Asking it for both at once is the mistake it
/// exists to prevent.
enum VideoFrameSheet {

    static func make(_ request: VideoFrameSheetRequest) async throws -> VideoFrameSheetResult {
        let source = try await probe(request.url)

        let frameRate = source.frameRate > 0
            ? source.frameRate
            : VideoFrameDefaults.fallbackFrameRate
        let duration = source.duration

        let (start, end) = window(for: request, duration: duration)
        guard end >= start else { throw VideoFrameSheetFailure.emptyWindow }

        let cellCount = cells(
            requested: request.frames,
            windowSeconds: end - start,
            frameRate: frameRate
        )
        let times = samples(count: cellCount, start: start, end: end, frameRate: frameRate)

        let bounds = CGRect(x: 0, y: 0, width: source.pixelWidth, height: source.pixelHeight)
        var crop: CGRect?
        if let requested = request.crop {
            let clamped = requested.intersection(bounds)
            guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1 else {
                throw VideoFrameSheetFailure.cropOutsideFrame(
                    width: source.pixelWidth,
                    height: source.pixelHeight
                )
            }
            crop = clamped.integral
        }

        let frameSize = crop?.size ?? bounds.size
        let layout = grid(cells: cellCount, frameSize: frameSize)

        let images = try await decode(
            url: request.url,
            at: times,
            crop: crop,
            maximumCellSize: CGSize(width: layout.cellWidth, height: layout.cellHeight)
        )

        let sheet = try composite(images, layout: layout)
        guard let pngData = png(from: sheet) else {
            throw VideoFrameSheetFailure.couldNotEncode
        }

        return VideoFrameSheetResult(
            pngData: pngData,
            source: source,
            timestamps: times,
            columns: layout.columns,
            rows: layout.rows,
            cellPixelWidth: layout.cellWidth,
            cellPixelHeight: layout.cellHeight,
            sheetPixelWidth: layout.sheetWidth,
            sheetPixelHeight: layout.sheetHeight,
            windowStart: start,
            windowEnd: end,
            deliveredCellWidth: layout.deliveredCellWidth,
            cropRect: crop
        )
    }

    // MARK: Asking the file what it is

    /// Every question goes to the decoder rather than to the file name: a movie is a container
    /// whose contents only a decoder knows, and `.mov` on the end is a claim, not evidence.
    static func probe(_ url: URL) async throws -> VideoFrameSource {
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let isPlayable: Bool
        let assetDuration: CMTime
        let videoTracks: [AVAssetTrack]
        let audioTracks: [AVAssetTrack]
        do {
            isPlayable = try await asset.load(.isPlayable)
            assetDuration = try await asset.load(.duration)
            videoTracks = try await asset.loadTracks(withMediaType: .video)
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw VideoFrameSheetFailure.unreadable
        }
        guard isPlayable else { throw VideoFrameSheetFailure.notPlayable }
        guard let track = videoTracks.first else { throw VideoFrameSheetFailure.noVideoTrack }

        let naturalSize: CGSize
        let transform: CGAffineTransform
        let nominalFrameRate: Float
        do {
            (naturalSize, transform, nominalFrameRate) = try await track.load(
                .naturalSize,
                .preferredTransform,
                .nominalFrameRate
            )
        } catch {
            throw VideoFrameSheetFailure.unreadable
        }

        // The *presented* size, not the stored one. A recording made in portrait stores a
        // landscape frame plus a rotation, and a crop measured against the stored size would
        // name a rectangle of the wrong screen.
        let presented = naturalSize.applying(transform)
        let width = Int(abs(presented.width).rounded())
        let height = Int(abs(presented.height).rounded())
        guard width > 0, height > 0 else { throw VideoFrameSheetFailure.noReadableSize }

        let seconds = assetDuration.isNumeric ? assetDuration.seconds : 0
        return VideoFrameSource(
            url: url,
            duration: seconds.isFinite && seconds > 0 ? seconds : 0,
            frameRate: nominalFrameRate > 0 ? Double(nominalFrameRate) : 0,
            pixelWidth: width,
            pixelHeight: height,
            hasAudio: !audioTracks.isEmpty
        )
    }

    // MARK: The window

    static func window(
        for request: VideoFrameSheetRequest,
        duration: Double
    ) -> (start: Double, end: Double) {
        guard duration > 0 else { return (0, 0) }
        let start = min(max(request.start ?? 0, 0), duration)
        let end = min(max(request.end ?? duration, start), duration)
        return (start, end)
    }

    // MARK: How many

    /// Never more than the ceiling, and never more than the window actually holds — asking a
    /// third of a second for nine frames of a thirty-hertz recording produces nine cells of
    /// which six are the same picture.
    static func cells(requested: Int?, windowSeconds: Double, frameRate: Double) -> Int {
        let ceiling = VideoFrameDefaults.maximumCells
        let asked = min(max(requested ?? ceiling, 1), ceiling)
        let available = max(1, Int((windowSeconds * frameRate).rounded()))
        return min(asked, available)
    }

    /// Evenly spaced, spanning the window rather than sitting inside it, because the first and
    /// last states of a clip are usually half the question. The final sample is pulled one
    /// frame back: a time exactly at the end of an asset decodes to nothing.
    static func samples(
        count: Int,
        start: Double,
        end: Double,
        frameRate: Double
    ) -> [Double] {
        guard count > 1 else { return [start] }
        let lastSafe = max(start, end - 1 / max(frameRate, 1))
        return (0..<count).map { index in
            let progress = Double(index) / Double(count - 1)
            let time = start + (end - start) * progress
            return min(time, lastSafe)
        }
    }

    // MARK: The grid

    struct Layout: Sendable {
        let columns: Int
        let rows: Int
        let cellWidth: Int
        let cellHeight: Int
        let sheetWidth: Int
        let sheetHeight: Int
        let deliveredCellWidth: Int
        let count: Int
    }

    /// Picks the column count that makes a cell largest *after* delivery.
    ///
    /// Not `ceil(sqrt(n))`. A tall phone frame and a wide desktop frame want opposite grids
    /// for the same cell count — three columns of a 1206×2622 recording makes a sheet far
    /// taller than it is wide, and the long edge is what the downscale measures. Trying every
    /// column count and keeping the best is nine comparisons, and it is the only version of
    /// this that is right for both shapes.
    static func grid(cells: Int, frameSize: CGSize) -> Layout {
        let aspect = frameSize.height / max(frameSize.width, 1)
        var best: Layout?

        /// Empty cells, then cell size, then total cells. Lower sorts better.
        func rank(_ layout: Layout) -> (Int, Int, Int) {
            (
                layout.columns * layout.rows - layout.count,
                -layout.deliveredCellWidth,
                layout.columns * layout.rows
            )
        }

        for columns in 1...max(cells, 1) {
            let rows = Int((Double(cells) / Double(columns)).rounded(.up))
            // Solve for the cell width that puts the sheet's long edge exactly on the budget.
            let gaps = VideoFrameDefaults.cellGap
            let margin = VideoFrameDefaults.sheetMargin
            let fixedWidth = Double(2 * margin + (columns - 1) * gaps)
            let fixedHeight = Double(2 * margin + (rows - 1) * gaps)
            let budget = Double(VideoFrameDefaults.readableLongEdge)

            let widthLimited = (budget - fixedWidth) / Double(columns)
            let heightLimited = (budget - fixedHeight) / (Double(rows) * aspect)
            let cellWidth = max(1, min(widthLimited, heightLimited))
            let cellHeight = max(1, cellWidth * aspect)

            let sheetWidth = Int((Double(columns) * cellWidth + fixedWidth).rounded())
            let sheetHeight = Int((Double(rows) * cellHeight + fixedHeight).rounded())

            let candidate = Layout(
                columns: columns,
                rows: rows,
                cellWidth: Int(cellWidth.rounded()),
                cellHeight: Int(cellHeight.rounded()),
                sheetWidth: sheetWidth,
                sheetHeight: sheetHeight,
                deliveredCellWidth: Int(cellWidth.rounded()),
                count: cells
            )
            // Fewest empty cells first, then the largest cell. Not the other way around: a
            // nine-frame sheet of a desktop recording measures 5% wider cells as two columns
            // of five with a hole in it, and a ragged grid costs a reader more than five
            // percent. Zero waste settles it, and only then does size choose between 3×3,
            // 9×1 and 1×9.
            if let incumbent = best {
                if rank(candidate) < rank(incumbent) { best = candidate }
            } else {
                best = candidate
            }
        }

        return best ?? Layout(
            columns: 1,
            rows: 1,
            cellWidth: Int(frameSize.width),
            cellHeight: Int(frameSize.height),
            sheetWidth: Int(frameSize.width),
            sheetHeight: Int(frameSize.height),
            deliveredCellWidth: Int(frameSize.width),
            count: 1
        )
    }

    // MARK: Decoding

    /// Exactly `times.count` decodes, with zero tolerance on either side.
    ///
    /// The tolerance matters more than it looks: a default generator is free to return the
    /// nearest keyframe, and a question about a one-frame flicker asked of keyframes is a
    /// question asked of the wrong pictures.
    private static func decode(
        url: URL,
        at times: [Double],
        crop: CGRect?,
        maximumCellSize: CGSize
    ) async throws -> [CGImage] {
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        // A cropped read has to decode the whole frame before it can keep part of one, so the
        // decoder's own ceiling is only useful in the uncropped case.
        if crop == nil {
            generator.maximumSize = CGSize(
                width: maximumCellSize.width * 2,
                height: maximumCellSize.height * 2
            )
        }

        var images: [CGImage] = []
        images.reserveCapacity(times.count)
        for seconds in times {
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            // The asynchronous generator, not `copyCGImage`: this is a batch of up to nine
            // decodes serving a tool call, not the one synchronous frame Copy Frame owes a
            // menu that has already closed.
            guard let decoded = try? await generator.image(at: time).image else {
                throw VideoFrameSheetFailure.undecodable(seconds: seconds)
            }
            if let crop {
                // The generator applied the track's rotation, so the frame is already in the
                // orientation the crop was measured against.
                guard let cropped = decoded.cropping(to: crop) else {
                    throw VideoFrameSheetFailure.cropOutsideFrame(
                        width: decoded.width,
                        height: decoded.height
                    )
                }
                images.append(cropped)
            } else {
                images.append(decoded)
            }
        }
        return images
    }

    // MARK: Compositing

    private static func composite(_ images: [CGImage], layout: Layout) throws -> CGImage {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: layout.sheetWidth,
                height: layout.sheetHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { throw VideoFrameSheetFailure.couldNotEncode }

        context.setFillColor(
            red: VideoFrameDefaults.plate.red,
            green: VideoFrameDefaults.plate.green,
            blue: VideoFrameDefaults.plate.blue,
            alpha: 1
        )
        context.fill(CGRect(x: 0, y: 0, width: layout.sheetWidth, height: layout.sheetHeight))
        context.interpolationQuality = .high

        for (index, image) in images.enumerated() {
            let column = index % layout.columns
            let row = index / layout.columns
            let x = VideoFrameDefaults.sheetMargin
                + column * (layout.cellWidth + VideoFrameDefaults.cellGap)
            // Core Graphics counts up from the bottom; a contact sheet reads down from the top.
            let topY = VideoFrameDefaults.sheetMargin
                + row * (layout.cellHeight + VideoFrameDefaults.cellGap)
            let y = layout.sheetHeight - topY - layout.cellHeight
            context.draw(
                image,
                in: CGRect(
                    x: CGFloat(x),
                    y: CGFloat(y),
                    width: CGFloat(layout.cellWidth),
                    height: CGFloat(layout.cellHeight)
                )
            )
        }

        guard let sheet = context.makeImage() else {
            throw VideoFrameSheetFailure.couldNotEncode
        }
        return sheet
    }

    private static func png(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
