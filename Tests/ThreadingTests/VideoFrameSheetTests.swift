import AVFoundation
import CoreGraphics
import XCTest

@testable import Threading

/// Covers the arithmetic that decides whether a recording arrives readable, and the one
/// end-to-end path that proves the frames are really decoded.
///
/// The numbers asserted here are not preferences. They come from measuring what it cost to
/// answer questions about screen recordings by hand: a six-by-six contact sheet of a phone
/// capture delivers each frame about 120 pixels wide, which is unreadable, and the nine follow-up
/// crops that then became necessary are the reason this type exists.
final class VideoFrameSheetTests: XCTestCase {

    // MARK: - Grids

    private let desktop = CGSize(width: 2_660, height: 1_498)
    private let phone = CGSize(width: 1_206, height: 2_622)

    func testNineCellsOfADesktopRecordingIsThreeByThree() {
        let layout = VideoFrameSheet.grid(cells: 9, frameSize: desktop)
        XCTAssertEqual(layout.columns, 3)
        XCTAssertEqual(layout.rows, 3)
    }

    /// Two columns of five would give a 5% wider cell and leave a hole in the grid. Fewest
    /// empty cells decides first, precisely so that trade is refused.
    func testAFullGridBeatsAMarginallyLargerRaggedOne() {
        let layout = VideoFrameSheet.grid(cells: 9, frameSize: desktop)
        XCTAssertEqual(layout.columns * layout.rows, 9, "a nine-cell sheet must have no holes")
    }

    /// A tall frame and a wide frame want opposite grids for the same cell count, which is why
    /// the column count is solved for rather than taken as the square root.
    func testATallRecordingLaysOutAsAFilmstrip() {
        let layout = VideoFrameSheet.grid(cells: 4, frameSize: phone)
        XCTAssertEqual(layout.rows, 1, "four phone frames read best side by side")
        XCTAssertEqual(layout.columns, 4)

        let wide = VideoFrameSheet.grid(cells: 4, frameSize: desktop)
        XCTAssertEqual(wide.columns, 2)
        XCTAssertEqual(wide.rows, 2)
    }

    /// The whole point of choosing the layout: a sheet is built at the delivered size, so no
    /// pixel is decoded, encoded or sent that the downscale would discard.
    func testASheetNeverExceedsTheDeliverableLongEdge() {
        for size in [desktop, phone, CGSize(width: 1_000, height: 1_000)] {
            for cells in 1...VideoFrameDefaults.maximumCells {
                let layout = VideoFrameSheet.grid(cells: cells, frameSize: size)
                XCTAssertLessThanOrEqual(
                    max(layout.sheetWidth, layout.sheetHeight),
                    VideoFrameDefaults.readableLongEdge,
                    "\(cells) cells of \(size) overflowed the delivery budget"
                )
            }
        }
    }

    /// Fewer cells is the lever the tool description tells callers to pull, so it has to
    /// actually pay: two frames of a phone recording arrive far wider than nine.
    func testFewerCellsBuyABiggerCell() {
        let nine = VideoFrameSheet.grid(cells: 9, frameSize: phone)
        let two = VideoFrameSheet.grid(cells: 2, frameSize: phone)
        XCTAssertGreaterThan(two.deliveredCellWidth, nine.deliveredCellWidth * 2)
    }

    // MARK: - How many frames

    func testTheCellCountIsCappedHoweverManyAreAsked() {
        XCTAssertEqual(
            VideoFrameSheet.cells(requested: 200, windowSeconds: 60, frameRate: 60),
            VideoFrameDefaults.maximumCells
        )
    }

    /// Cost is fixed whatever the clip is: an hour is sampled more sparsely, never more
    /// expensively.
    func testAnHourLongClipCostsTheSameNineDecodes() {
        XCTAssertEqual(
            VideoFrameSheet.cells(requested: nil, windowSeconds: 3_600, frameRate: 60),
            VideoFrameDefaults.maximumCells
        )
    }

    /// A window holding three frames must not be padded out to nine copies of the same picture.
    func testAShortWindowIsNotOversampled() {
        XCTAssertEqual(
            VideoFrameSheet.cells(requested: 9, windowSeconds: 0.1, frameRate: 30),
            3
        )
    }

    // MARK: - Sample times

    func testSamplesSpanTheWindowAndStayInsideIt() {
        let times = VideoFrameSheet.samples(count: 5, start: 1, end: 3, frameRate: 30)
        XCTAssertEqual(times.count, 5)
        XCTAssertEqual(times.first ?? 0, 1, accuracy: 0.0001)
        // The last sample is pulled back one frame: a time exactly at the end decodes to
        // nothing, which reads as a corrupt file rather than as an off-by-one.
        XCTAssertLessThan(times.last ?? 0, 3)
        XCTAssertGreaterThan(times.last ?? 0, 2.9)
        XCTAssertEqual(times, times.sorted())
    }

    func testASingleSampleSitsAtTheStartOfTheWindow() {
        XCTAssertEqual(VideoFrameSheet.samples(count: 1, start: 2, end: 5, frameRate: 30), [2])
    }

    // MARK: - Refusals

    func testAPartialCropIsRefusedRatherThanGuessed() {
        let arguments = VideoFramesArguments(
            path: "/tmp/x.mov",
            crop: VideoCropArguments(x: 10, y: 10)
        )
        let refusal = VideoFrameSheetRequest.refusal(for: arguments)
        XCTAssertNotNil(refusal)
        XCTAssertTrue(refusal?.contains("all four") ?? false, refusal ?? "")
    }

    func testABackwardsWindowIsRefused() {
        let arguments = VideoFramesArguments(path: "/tmp/x.mov", from: 4, to: 1)
        XCTAssertNotNil(VideoFrameSheetRequest.refusal(for: arguments))
    }

    func testACompleteCropIsAccepted() {
        let arguments = VideoFramesArguments(
            path: "/tmp/x.mov",
            crop: VideoCropArguments(x: 10, y: 20, width: 100, height: 50)
        )
        XCTAssertNil(VideoFrameSheetRequest.refusal(for: arguments))
        XCTAssertEqual(
            arguments.crop?.rect,
            CGRect(x: 10, y: 20, width: 100, height: 50)
        )
    }

    func testAMissingPathIsRefusedByName() {
        XCTAssertEqual(
            VideoFrameSheetRequest.refusal(for: VideoFramesArguments()),
            "Missing required argument: path"
        )
    }

    // MARK: - Reading a real movie

    /// The one test that actually decodes. It writes a movie whose frames are known colours in
    /// a known order, then asserts the sheet holds those colours in that order — which is the
    /// only way to catch a sheet that is upside down, since Core Graphics counts up from the
    /// bottom and a contact sheet reads down from the top.
    func testReadsARealMovieIntoASheetInReadingOrder() async throws {
        let colours: [CGColor] = [
            CGColor(red: 1, green: 0, blue: 0, alpha: 1),
            CGColor(red: 0, green: 1, blue: 0, alpha: 1),
            CGColor(red: 0, green: 0, blue: 1, alpha: 1),
            CGColor(red: 1, green: 1, blue: 0, alpha: 1),
        ]
        let url = try await movie(colours: colours, size: CGSize(width: 320, height: 180))
        defer { try? FileManager.default.removeItem(at: url) }

        let sheet = try await VideoFrameSheet.make(
            VideoFrameSheetRequest(url: url, frames: 4)
        )

        XCTAssertEqual(sheet.timestamps.count, 4)
        XCTAssertEqual(sheet.columns, 2)
        XCTAssertEqual(sheet.rows, 2)
        XCTAssertEqual(sheet.source.pixelWidth, 320)
        XCTAssertEqual(sheet.source.pixelHeight, 180)
        XCTAssertFalse(sheet.source.hasAudio)

        let image = try XCTUnwrap(decoded(sheet.pngData))
        XCTAssertEqual(image.width, sheet.sheetPixelWidth)
        XCTAssertEqual(image.height, sheet.sheetPixelHeight)

        // Top left is the first second's colour and the next cell along is the second's:
        // reading order, not draw order. Asserted as "which channel wins" rather than against
        // exact values, because h.264 does not reconstruct a pure primary exactly and a tight
        // tolerance here fails on the codec rather than on the layout.
        let topLeft = try XCTUnwrap(colour(of: image, atCell: 0, in: sheet))
        XCTAssertGreaterThan(topLeft.0, topLeft.1 + 0.3, "top-left cell should be red")

        let next = try XCTUnwrap(colour(of: image, atCell: 1, in: sheet))
        XCTAssertGreaterThan(next.1, next.0 + 0.3, "the cell after it should be green")
    }

    func testACropReadsOnlyTheNamedRegion() async throws {
        let url = try await movie(
            colours: [CGColor(red: 0, green: 0, blue: 1, alpha: 1)],
            size: CGSize(width: 320, height: 180)
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let sheet = try await VideoFrameSheet.make(
            VideoFrameSheetRequest(
                url: url,
                crop: CGRect(x: 0, y: 0, width: 160, height: 90),
                frames: 1
            )
        )
        XCTAssertTrue(sheet.isCropped)
        // The cell keeps the crop's shape, which is what makes a crop worth asking for.
        let aspect = Double(sheet.cellPixelHeight) / Double(sheet.cellPixelWidth)
        XCTAssertEqual(aspect, 90.0 / 160.0, accuracy: 0.02)
    }

    /// A crop nowhere near the frame is a caller's mistake and has to say so, rather than
    /// returning a picture of some other part of the screen.
    func testACropOutsideTheFrameIsRefused() async throws {
        let url = try await movie(
            colours: [CGColor(red: 0, green: 0, blue: 1, alpha: 1)],
            size: CGSize(width: 320, height: 180)
        )
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            _ = try await VideoFrameSheet.make(
                VideoFrameSheetRequest(
                    url: url,
                    crop: CGRect(x: 5_000, y: 5_000, width: 100, height: 100),
                    frames: 1
                )
            )
            XCTFail("a crop outside the frame should not return a sheet")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("outside"),
                error.localizedDescription
            )
        }
    }

    // MARK: - The report

    func testTheReportCarriesTheCellTimesAndTheProbeFacts() async throws {
        let url = try await movie(
            colours: Array(repeating: CGColor(red: 0, green: 0, blue: 1, alpha: 1), count: 4),
            size: CGSize(width: 320, height: 180)
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let sheet = try await VideoFrameSheet.make(VideoFrameSheetRequest(url: url, frames: 4))
        let report = sheet.report(fileName: "clip.mov", destination: "Shown.")

        XCTAssertTrue(report.contains("clip.mov"), report)
        XCTAssertTrue(report.contains("320×180"), report)
        XCTAssertTrue(report.contains("no audio"), report)
        XCTAssertTrue(report.contains("Cell times"), report)
        XCTAssertTrue(report.contains("Grid 2×2"), report)
        // Every cell is accounted for by number, because the number cannot be drawn into the
        // picture on a machine whose ffmpeg has no drawtext filter.
        for cell in 1...4 {
            XCTAssertTrue(report.contains("\(cell): "), "cell \(cell) missing from \(report)")
        }
    }

    /// The advisory exists because this failure looks like success: a sheet arrives, and it is
    /// simply too small to answer the question.
    func testASheetOfThumbnailsSaysSoAndNamesTheWayOut() {
        let layout = VideoFrameSheet.grid(cells: 9, frameSize: phone)
        XCTAssertLessThan(layout.deliveredCellWidth, VideoFrameDefaults.legibleCellWidth)

        let result = VideoFrameSheetResult(
            pngData: Data(),
            source: VideoFrameSource(
                url: URL(fileURLWithPath: "/tmp/x.mov"),
                duration: 4,
                frameRate: 60,
                pixelWidth: 1_206,
                pixelHeight: 2_622,
                hasAudio: false
            ),
            timestamps: [0, 1, 2],
            columns: layout.columns,
            rows: layout.rows,
            cellPixelWidth: layout.cellWidth,
            cellPixelHeight: layout.cellHeight,
            sheetPixelWidth: layout.sheetWidth,
            sheetPixelHeight: layout.sheetHeight,
            windowStart: 0,
            windowEnd: 4,
            deliveredCellWidth: layout.deliveredCellWidth,
            cropRect: nil
        )
        let report = result.report(fileName: "x.mov", destination: "Shown.")
        XCTAssertTrue(report.contains("thumbnail"), report)
        XCTAssertTrue(report.contains("crop"), report)
    }

    // MARK: - The tool

    func testTheToolIsAdvertisedInTheDisplayGroupWithItsRequiredArgument() throws {
        let definition = try XCTUnwrap(MCPTools.definition(for: .videoFrames))
        XCTAssertEqual(definition.name, "video_frames")
        XCTAssertEqual(definition.inputSchema.required, ["path"])
        XCTAssertNotNil(definition.inputSchema.properties["crop"]?.properties?["width"])

        let group = try XCTUnwrap(MCPToolCatalog.groups.first { $0.id == "display" })
        XCTAssertTrue(group.tools.contains { $0.builtInTool == .videoFrames })
        XCTAssertTrue(group.instruction.contains("video_frames"), group.instruction)
    }

    /// The tool exists to stop an agent reaching for the shell, so the description has to say
    /// that in the words the agent would otherwise act on.
    func testTheDescriptionRulesOutShellingOutToFFmpeg() throws {
        let definition = try XCTUnwrap(MCPTools.definition(for: .videoFrames))
        XCTAssertTrue(definition.description.contains("ffmpeg"), definition.description)
        XCTAssertTrue(definition.description.contains(".mov"), definition.description)
    }

    // MARK: - Fixtures

    /// Writes a real movie, one second per colour, so the decode path under test is the one
    /// that runs in production rather than a stub standing in for it.
    private func movie(colours: [CGColor], size: CGSize) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("frame-sheet-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(size.width),
                AVVideoHeightKey: Int(size.height),
            ]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
            ]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let rate: Int32 = 30
        for (index, colour) in colours.enumerated() {
            // One second of identical frames per colour, so a sample anywhere inside a second
            // lands on a known colour whatever the sampler rounds to.
            for frame in 0..<Int(rate) {
                let buffer = try pixelBuffer(colour: colour, size: size)
                let time = CMTime(
                    value: CMTimeValue(index * Int(rate) + frame),
                    timescale: rate
                )
                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
                adaptor.append(buffer, withPresentationTime: time)
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        return url
    }

    private func pixelBuffer(colour: CGColor, size: CGSize) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width),
            Int(size.height),
            kCVPixelFormatType_32ARGB,
            [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary,
            &buffer
        )
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixels),
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixels),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        )
        context?.setFillColor(colour)
        context?.fill(CGRect(origin: .zero, size: size))
        return pixels
    }

    private func decoded(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// The average red and green of one cell's middle, which is enough to tell four primaries
    /// apart without depending on the codec's exact reconstruction.
    private func colour(
        of image: CGImage,
        atCell index: Int,
        in sheet: VideoFrameSheetResult
    ) -> (Double, Double)? {
        let column = index % sheet.columns
        let row = index / sheet.columns
        let x = VideoFrameDefaults.sheetMargin
            + column * (sheet.cellPixelWidth + VideoFrameDefaults.cellGap)
            + sheet.cellPixelWidth / 2
        let y = VideoFrameDefaults.sheetMargin
            + row * (sheet.cellPixelHeight + VideoFrameDefaults.cellGap)
            + sheet.cellPixelHeight / 2

        guard let cropped = image.cropping(to: CGRect(x: x, y: y, width: 2, height: 2)),
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (Double(pixel[0]) / 255, Double(pixel[1]) / 255)
    }
}
